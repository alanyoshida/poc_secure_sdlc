#!/usr/bin/env bash
# Cria/semeia os repos do fluxo GitOps (change gitops-deploy):
#  - root/webapp: app nginx + chart (probes) + pipeline completo
#  - root/gitops: apps/*.yaml (Applications que o ArgoCD observa)
#  - namespace webapps + imagePullSecret do Harbor
# Requer: PAT kanban-agent (root do token), GitOps ja com main semeada pelo
# gitops-setup (na ordem do bootstrap).
# Idempotente: so commita quando algum arquivo muda.
set -euo pipefail
cd "$(dirname "$0")/.."

AGENT_TOKEN=$(kubectl get secret kanban-agent-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
GITOPS_TOKEN=$(kubectl get secret gitops-writer-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
ROBOT_USER=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.username}' | base64 -d)
ROBOT_PASS=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.password}' | base64 -d)
AUTH_B64=$(printf '%s:%s' "$ROBOT_USER" "$ROBOT_PASS" | base64 -w0)

kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT

seed_repo() { # $1=nome  $2=diretorio fonte  $3=vars-extra(json)
  local NAME="$1" SRC="$2" EXTRA_VARS="$3"
  python3 - "$AGENT_TOKEN" "$NAME" "$SRC" "$EXTRA_VARS" <<'PYSEED'
import json, os, sys, urllib.request, urllib.error

token, name, src, extra_vars = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
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
        try:
            return e.code, (json.loads(body) if body else {})
        except json.JSONDecodeError:
            return e.code, {"raw": body.decode(errors="replace")}

path_ns = urllib.parse.quote(f"root/{name}", safe="")
st, r = api("POST", "/projects", {"name": name, "visibility": "private", "default_branch": "main"})
if st == 201:
    print(f"projeto root/{name}: criado")
elif st in (409, 400) and "already been taken" in json.dumps(r):
    print(f"projeto root/{name}: ja existe")
else:
    print(f"criacao do projeto falhou: {st} {r}"); sys.exit(1)
pid = api("GET", f"/projects/{path_ns}")[1]["id"]

for key, val, masked in extra_vars:
    st, r = api("POST", f"/projects/{pid}/variables", {"key": key, "value": val, "masked": masked, "protected": False})
    if st in (409, 400) and "already been taken" in json.dumps(r):
        st, r = api("PUT", f"/projects/{pid}/variables/{key}", {"value": val, "masked": masked, "protected": False})
    if st not in (200, 201):
        print(f"variavel {key}: falhou HTTP {st}: {r}"); sys.exit(1)
    print(f"variavel {key}: HTTP {st}")

HOOK_URL = "http://secrets-gate-eventsource-svc.cicd.svc.cluster.local:12000/mr"
st, hooks = api("GET", f"/projects/{pid}/hooks")
hook = next((h for h in hooks if h["url"] == HOOK_URL), None)
if hook:
    api("PUT", f"/projects/{pid}/hooks/{hook['id']}", {
        "url": HOOK_URL, "merge_requests_events": True,
        "push_events": False, "enable_ssl_verification": False})
    print("webhook de MR: atualizado")
else:
    api("POST", f"/projects/{pid}/hooks", {
        "url": HOOK_URL, "merge_requests_events": True,
        "push_events": False, "enable_ssl_verification": False,
        "description": "security gate + LLM review via Argo Events"})
    print("webhook de MR: criado")

existing = set()
st, tree = api("GET", f"/projects/{pid}/repository/tree?recursive=true&per_page=100")
if st == 200:
    existing = {e["path"] for e in tree if e["type"] == "blob"}

def remote_content(path):
    req = urllib.request.Request(
        BASE + f"/projects/{pid}/repository/files/{urllib.request.quote(path, safe='')}/raw?ref=main")
    req.add_header("PRIVATE-TOKEN", token)
    with urllib.request.urlopen(req) as r:
        return r.read().decode()

actions = []
for root, _, fnames in os.walk(src):
    for f in fnames:
        full = os.path.join(root, f)
        path = os.path.relpath(full, src).replace(os.sep, "/")
        content = open(full, encoding="utf-8").read()
        if path in existing:
            try:
                if remote_content(path) == content:
                    continue
            except urllib.error.HTTPError:
                pass
            actions.append({"action": "update", "file_path": path, "content": content})
        else:
            actions.append({"action": "create", "file_path": path, "content": content})

if actions:
    st, r = api("POST", f"/projects/{pid}/repository/commits", {
        "branch": "main",
        "commit_message": f"sincroniza arquivos do bootstrap ({src})",
        "actions": actions})
    if st != 201:
        print("commit falhou:", st, r); sys.exit(1)
    print(f"repo {name} semeado: commit", r.get("short_id"))
else:
    print(f"repo {name}: arquivos sem alteracoes, commit pulado")
PYSEED
}

seed_repo "webapp" "example-webapp" '[["HARBOR_REGISTRY","harbor.harbor.svc.cluster.local",false],["HARBOR_REGISTRY_AUTH","'"$AUTH_B64"'",true],["GITOPS_TOKEN","'"$GITOPS_TOKEN"'",true]]'
seed_repo "gitops" "example-gitops" '[]'

# --- namespace webapps + pull secret do Harbor ---
kubectl create ns webapps --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n webapps create secret docker-registry harbor-pull-webapps \
  --docker-server=harbor.harbor.svc.cluster.local \
  --docker-username="$ROBOT_USER" --docker-password="$ROBOT_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "namespace webapps + pull secret prontos"
