#!/usr/bin/env bash
# Cria/semeia o workspace repo do agente kanban (change kanban-agent):
#  - projeto GitLab root/agent-workspace (privado)
#  - openspec inicializado (config) + adaptadores .opencode/ da plataforma
#  - pipeline de seguranca + Dockerfile (example-workspace/)
#  - webhook de MR registrado (gate + LLM review)
#  - CI variables do Harbor
#  - projeto no board do Kanzo vinculado ao repo via link_repo (URL interna)
#  - coluna backlog do board habilitada (nativa do Kanzo, agentes ignoram)
# Idempotente: so commita quando algum arquivo muda; nunca duplica.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_TOKEN=$(kubectl get secret kanban-agent-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
KANZO_MCP_URL=${KANZO_MCP_URL:-http://localhost:4242/mcp}
ROBOT_USER=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.username}' | base64 -d)
ROBOT_PASS=$(kubectl get secret harbor-robot -n cicd -o jsonpath='{.data.password}' | base64 -d)
AUTH_B64=$(printf '%s:%s' "$ROBOT_USER" "$ROBOT_PASS" | base64 -w0)

kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT

python3 - "$ADMIN_TOKEN" "$AUTH_B64" <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

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
        try:
            return e.code, (json.loads(body) if body else {})
        except json.JSONDecodeError:
            return e.code, {"raw": body.decode(errors="replace")}

# --- projeto ---
st, r = api("POST", "/projects", {"name": "agent-workspace", "visibility": "private", "default_branch": "main"})
if st == 201:
    print("projeto root/agent-workspace: criado")
elif st in (409, 400) and "already been taken" in json.dumps(r):
    print("projeto root/agent-workspace: ja existe")
else:
    print("criacao do projeto falhou:", st, r); sys.exit(1)
pid = api("GET", "/projects/root%2Fagent-workspace")[1]["id"]

# --- variaveis de CI do Harbor ---
for key, val, masked in [
    ("HARBOR_REGISTRY", "harbor.harbor.svc.cluster.local", False),
    ("HARBOR_REGISTRY_AUTH", auth_b64, True),
]:
    st, r = api("POST", f"/projects/{pid}/variables", {"key": key, "value": val, "masked": masked, "protected": False})
    if st in (409, 400) and "already been taken" in json.dumps(r):
        st, r = api("PUT", f"/projects/{pid}/variables/{key}", {"value": val, "masked": masked, "protected": False})
    if st not in (200, 201):
        print(f"variavel {key}: falhou HTTP {st}: {r}"); sys.exit(1)
    print(f"variavel {key}: HTTP {st}")

# --- webhook de MR ---
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

# --- arquivos semeados (conteudo resolvido de example-workspace/ e da plataforma) ---
seeds = {
    "README.md": "# agent-workspace\n\nRepositorio de trabalho do agente kanban. O fonte canonico "
                 "deste seed vive no repositorio de plataforma (`example-workspace/`).\n\n"
                 "Pipeline: security-gate (gitleaks via Argo) -> build (buildx remoto) -> push "
                 "(`apps/agent-workspace:$CI_COMMIT_SHORT_SHA` no Harbor).\n",
    "AGENTS.md": "# AGENTS.md\n\nRepositorio de trabalho do agente kanban.\n"
                 "Mudancas seguem o workflow OpenSpec: propose -> aprovacao -> apply -> MR -> archive.\n",
    "openspec/config.yaml": None,
    "openspec/README.md": "# openspec\n\nChanges do agente kanban (propose -> apply -> archive).\n",
}
ws_root = "example-workspace"
for root, _, fnames in os.walk(ws_root):
    if "__pycache__" in root:
        continue
    for f in fnames:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, ws_root)
        seeds[rel] = open(full, encoding="utf-8").read()
opencode_root = ".opencode"
for root, _, files in os.walk(opencode_root):
    for f in files:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, opencode_root).replace(os.sep, "/")
        seeds[os.path.join(".opencode", rel)] = open(full, encoding="utf-8").read()

# estado atual do repo
st, tree = api("GET", f"/projects/{pid}/repository/tree?recursive=true&per_page=100")
existing = set()
if st == 200:
    existing = {e["path"] for e in tree if e["type"] == "blob"}

def remote_content(path):
    req = urllib.request.Request(
        BASE + f"/projects/{pid}/repository/files/{urllib.request.quote(path, safe='')}/raw?ref=main")
    req.add_header("PRIVATE-TOKEN", token)
    with urllib.request.urlopen(req) as r:
        return r.read().decode()

actions = []
for path, content in sorted(seeds.items()):
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
        "commit_message": "sincroniza arquivos do bootstrap (example-workspace)",
        "actions": actions})
    if st != 201:
        print("commit falhou:", st, r); sys.exit(1)
    print("workspace semeado: commit", r.get("short_id"))
else:
    print("workspace: arquivos sem alteracoes, commit pulado")
PYEOF

# --- coluna backlog do board (nativa do Kanzo, na meta do SQLite; o
# --- agente ignora backlog por construcao) ---
printf '%s\n' "INSERT OR REPLACE INTO meta(key,value) VALUES('backlog','1');" > /tmp/backlog.sql
kubectl exec -i deploy/kanzo -c kanzo -n cicd -- sh -c \
  'apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 /data/kanzo/kanzo.db' < /tmp/backlog.sql >/dev/null
rm -f /tmp/backlog.sql
kubectl rollout restart deploy/kanzo -n cicd >/dev/null
kubectl rollout status deploy/kanzo -n cicd --timeout=180s >/dev/null
echo "coluna backlog: habilitada"

# --- projeto no board do Kanzo + link_repo (MCP, com handshake de sessao) ---
python3 - "$KANZO_MCP_URL" <<'PYEOF'
import json, sys, urllib.request

kanzo_mcp = sys.argv[1]

def post(payload, session=None):
    req = urllib.request.Request(kanzo_mcp, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    req.add_header("Host", "localhost:4242")
    if session:
        req.add_header("mcp-session-id", session)
    with urllib.request.urlopen(req, json.dumps(payload).encode(), timeout=30) as r:
        sid = r.headers.get("mcp-session-id")
        return sid, r.read().decode()

def parse(raw):
    for line in raw.splitlines():
        if line.startswith("data:") and '"result"' in line:
            d = json.loads(line[5:].strip())
            return "\n".join(c.get("text", "") for c in d.get("result", {}).get("content", []) if c.get("type") == "text")
    return raw

def mcp(tool, args):
    sid, raw = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "agent-workspace-setup", "version": "1.0"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, raw = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": tool, "arguments": args}}, sid)
    return parse(raw)

projects = mcp("list_projects", {})
if "agent-workspace" in projects:
    print("projeto no board agent-workspace: ja existe")
else:
    print(mcp("create_project", {"slug": "agent-workspace", "name": "Agent Workspace",
                                 "repo": "root/agent-workspace"}))
    print("projeto no board: criado e vinculado ao repo interno")
PYEOF
echo "workspace do agente pronto"
