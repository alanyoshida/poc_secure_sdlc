#!/usr/bin/env bash
# Cria/atualiza o repositorio de aplicacao exemplo (root/demo-app) e as
# variaveis de CI do pipeline (HARBOR_REGISTRY + HARBOR_REGISTRY_AUTH).
# Idempotente: so commita quando algum arquivo muda de conteudo.
# Requer secret/gitlab-admin-token e secret/harbor-robot no ns cicd.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_TOKEN=$(kubectl get secret gitlab-admin-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
ROBOT_USER=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.username}' | base64 -d)
ROBOT_PASS=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.password}' | base64 -d)
AUTH_B64=$(printf '%s:%s' "$ROBOT_USER" "$ROBOT_PASS" | base64 -w0)

kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT

python3 - "$ADMIN_TOKEN" "$AUTH_B64" <<'PYEOF'
import base64, hashlib, json, os, sys, urllib.request, urllib.error

token, auth_b64 = sys.argv[1], sys.argv[2]
BASE = "http://127.0.0.1:8181/api/v4"

def api(method, path, payload=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("PRIVATE-TOKEN", token)
    req.add_header("Content-Type", "application/json")
    data = json.dumps(payload).encode() if payload is not None else None
    try:
        with urllib.request.urlopen(req, data) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        body = e.read()
        return e.code, (json.loads(body) if body else {})

# --- projeto ---
st, r = api("POST", "/projects", {"name": "demo-app", "visibility": "private", "default_branch": "main"})
if st == 201:
    print("projeto root/demo-app: criado")
elif st == 409 or (st == 400 and "already been taken" in json.dumps(r)):
    print("projeto root/demo-app: ja existe")
else:
    print("criacao do projeto falhou:", st, r); sys.exit(1)
pid = api("GET", "/projects/root%2Fdemo-app")[1]["id"]

# --- variaveis de CI ---
for key, val, masked in [
    ("HARBOR_REGISTRY", "harbor.harbor.svc.cluster.local", False),
    ("HARBOR_REGISTRY_AUTH", auth_b64, True),
]:
    st, r = api("POST", f"/projects/{pid}/variables", {"key": key, "value": val, "masked": masked, "protected": False})
    if st in (409, 400) and "already been taken" in json.dumps(r):
        st, r = api("PUT", f"/projects/{pid}/variables/{key}", {"value": val, "masked": masked, "protected": False})
    if st not in (200, 201):
        print(f"variavel {key}: falhou HTTP {st}: {r}")
        sys.exit(1)
    print(f"variavel {key}: HTTP {st}")

# --- arquivos (create se novo, update se mudou) ---
src = "example-app"
files = [
    ("README.md", None),
    ("hello.sh", None),
    ("Dockerfile", None),
    (".gitlab-ci.yml", None),
    ("ci/gate-poll.sh", None),
]
existing = {}
st, tree = api("GET", f"/projects/{pid}/repository/tree?recursive=true&per_page=100")
if st == 200:
    for e in tree:
        if e["type"] == "blob":
            existing[e["path"]] = e

actions = []
for path, _ in files:
    content = open(os.path.join(src, path)).read()
    if path in existing:
        # conteudo bruto (nao JSON): busca via raw e compara direto
        req = urllib.request.Request(
            BASE + f"/projects/{pid}/repository/files/{urllib.request.quote(path, safe='')}/raw?ref=main")
        req.add_header("PRIVATE-TOKEN", token)
        with urllib.request.urlopen(req) as rr:
            remote = rr.read().decode()
        if remote == content:
            continue
        actions.append({"action": "update", "file_path": path, "content": content})
    else:
        actions.append({"action": "create", "file_path": path, "content": content})

if not actions:
    print("demo-app: arquivos sem alteracoes, commit pulado")
    sys.exit(0)

st, r = api("POST", f"/projects/{pid}/repository/commits", {
    "branch": "main",
    "commit_message": "sincroniza arquivos do bootstrap (example-app)",
    "actions": actions,
})
if st == 201:
    print("demo-app: commit", r.get("short_id"), "- pipeline sera disparado")
else:
    print("commit falhou:", st, r); sys.exit(1)
PYEOF
