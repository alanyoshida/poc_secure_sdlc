#!/usr/bin/env bash
# Cria/semeia o workspace repo do agente kanban (change kanban-agent):
#  - projeto GitLab root/agent-workspace (privado)
#  - openspec inicializado (config + specs/changes vazios) + adaptadores
#    .opencode/ copiados do repositorio de plataforma
#  - webhook de MR registrado (gate + LLM review disparam nos MRs do agente)
#  - projeto no board do Kanzo vinculado ao repo via link_repo (URL interna)
# Idempotente: so commita quando algum arquivo muda; webhook e projeto do
# board sao atualizados, nunca duplicados.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_TOKEN=$(kubectl get secret kanban-agent-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
KANZO_MCP_URL=${KANZO_MCP_URL:-http://localhost:4242/mcp}

kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT

python3 - "$ADMIN_TOKEN" "$KANZO_MCP_URL" <<'PYEOF'
import base64, hashlib, json, os, shutil, sys, urllib.request, urllib.error

token, kanzo_mcp = sys.argv[1], sys.argv[2]
BASE = "http://127.0.0.1:8181/api/v4"
HOOK_URL = "http://secrets-gate-eventsource-svc.cicd.svc.cluster.local:12000/mr"
REPO_URL = "http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/agent-workspace.git"

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

# --- projeto GitLab ---
st, r = api("POST", "/projects", {"name": "agent-workspace", "visibility": "private", "default_branch": "main"})
if st == 201:
    print("projeto root/agent-workspace: criado")
elif st in (409, 400) and "already been taken" in json.dumps(r):
    print("projeto root/agent-workspace: ja existe")
else:
    print("criacao do projeto falhou:", st, r); sys.exit(1)
pid = api("GET", "/projects/root%2Fagent-workspace")[1]["id"]

# --- webhook de MR ---
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

# --- arquivos semeados (create/update por conteudo) ---
def read_platform(rel):
    return open(os.path.join(".", rel), encoding="utf-8").read()

seeds = {
    "README.md": "# agent-workspace\n\nRepositorio de trabalho do agente kanban "
                 "(change kanban-agent). Cards do Kanzo viram changes OpenSpec "
                 "aqui, implementadas em branchs `card/<id>-<slug>` e revisadas "
                 "por MR (gate de secrets + code review por LLM).\n",
    "AGENTS.md": "# AGENTS.md\n\nRepositorio de trabalho do agente kanban.\n"
                 "Mudancas seguem o workflow OpenSpec: propose -> aprovacao -> "
                 "apply -> MR -> archive.\n",
}
# openspec config + project.md da plataforma
for rel in ("openspec/config.yaml", "openspec/project.md"):
    if os.path.exists(rel):
        seeds[rel] = read_platform(rel)
# adaptadores opencode (skills + commands)
opencode_root = ".opencode"
for root, _, files in os.walk(opencode_root):
    for f in files:
        src = os.path.join(root, f)
        seeds[src] = read_platform(src)

# estado atual do repo (via tree, se existir)
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
        "commit_message": "semeia workspace do agente (openspec + skills opencode)",
        "actions": actions})
    if st != 201:
        print("commit falhou:", st, r); sys.exit(1)
    print("workspace semeado: commit", r.get("short_id"))
else:
    print("workspace: arquivos sem alteracoes, commit pulado")

# --- coluna backlog do board (nativa do Kanzo, guardada na meta do SQLite;
# --- o agente ignora backlog por construcao) ---
kubectl exec deploy/kanzo -c kanzo -n cicd -- sh -c \
  'apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 /data/kanzo/kanzo.db \
   "INSERT OR REPLACE INTO meta(key,value) VALUES('"'"'backlog'"'"','"'"'1'"'"');" >/dev/null
kubectl rollout restart deploy/kanzo -n cicd >/dev/null
kubectl rollout status deploy/kanzo -n cicd --timeout=180s >/dev/null
echo "coluna backlog: habilitada (restart do kanzo para reler o cache de colunas)"

# --- projeto no board do Kanzo + link_repo (MCP, com handshake de sessao) ---
def mcp(tool, args):
    def post(payload, session=None):
        req = urllib.request.Request(kanzo_mcp, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if session:
            req.add_header("mcp-session-id", session)
        with urllib.request.urlopen(req, json.dumps(payload).encode(), timeout=30) as r:
            sid = r.headers.get("mcp-session-id")
            return sid, r.read().decode()
    sid, raw = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "agent-workspace-setup", "version": "1.0"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, raw = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": tool, "arguments": args}}, sid)
    for line in raw.splitlines():
        if line.startswith("data:") and '"result"' in line:
            d = json.loads(line[5:].strip())
            return "\n".join(c.get("text", "") for c in d.get("result", {}).get("content", []) if c.get("type") == "text")
    return raw

projects = mcp("list_projects", {})
if "agent-workspace" in projects:
    print("projeto no board agent-workspace: ja existe")
else:
    print(mcp("create_project", {"slug": "agent-workspace", "name": "Agent Workspace", "repo": REPO_URL}))
    print("projeto no board: criado e vinculado ao repo interno")
PYEOF
