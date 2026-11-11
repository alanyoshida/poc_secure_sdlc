#!/usr/bin/env bash
# Loop do agente kanban (change kanban-agent).
# Transicoes de estado sao DETERMINISTICAS (tags/comentarios/estado do MR via
# API) — o LLM nunca decide estado; opencode executa apenas o trabalho de repo
# (propose/apply/archive) dentro do clone em /workspace.
# v1 sequencial: um card por vez; falha em qualquer fase move o card ao
# backlog com tag falhou:<fase> e o loop segue.
set -u

AGENT_DIR=${AGENT_DIR:-/agent}
WORKSPACE=${WORKSPACE:-/workspace}
KANZO_MCP_URL=${KANZO_MCP_URL:-http://kanzo.cicd.svc:4242/mcp}
GITLAB_URL=${GITLAB_URL:-http://gitlab-webservice-default.gitlab.svc.cluster.local:8181}
PROJECT_SLUG=${PROJECT_SLUG:-agent-workspace}
POLL_INTERVAL=${POLL_INTERVAL:-30}
MODEL=${AGENT_MODEL:-}
PROPOSE_TIMEOUT=${PROPOSE_TIMEOUT:-600}
APPLY_TIMEOUT=${APPLY_TIMEOUT:-1800}

mcp() {
  local _out _rc _i
  for _i in 1 2 3; do
    _out=$(python3 "$AGENT_DIR/mcp-kanzo.py" "$@" 2>/dev/null)
    _rc=$?
    if [ -n "$_out" ] && [ "$_rc" = "0" ]; then
      printf '%s' "$_out"
      return 0
    fi
    sleep 5
  done
  return "$_rc"
}

log() { echo "[agent $(date -u +%H:%M:%S)] $*"; }
fail_card() { # $1=card id, $2=fase, $3=descricao sanitizada
  log "FALHA ($2) no $1: $3"
  mcp_add_comment "$1" "**/falhou:$2** $3"
  mcp update_task "{\"id\":\"$1\",\"status\":\"backlog\",\"tags\":\"falhou:$2\"}" >/dev/null
}

# ---------- preparo do ambiente (a cada partida) ----------
export PATH="/tools/bin:$PATH"
mkdir -p ~/.local/share/opencode ~/.config/opencode
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  # credencial do provedor usada pelo opencode (mesma chave do .env)
  printf '{"openrouter":{"type":"api","key":"%s"}}' "$OPENROUTER_API_KEY" \
    > ~/.local/share/opencode/auth.json
  chmod 600 ~/.local/share/opencode/auth.json
else
  log "AVISO: OPENROUTER_API_KEY ausente - o opencode nao tera modelo"
fi
if [ -n "$MODEL" ]; then
  # permissões allow: o pod é o sandbox e o opencode roda sem humano para
  # aprovar tool calls (modo run auto-rejeita sem isso)
  printf '{"model":"%s","permission":{"edit":"allow","bash":"allow","webfetch":"allow","external_directory":"allow"}}' \
    "$MODEL" > ~/.config/opencode/opencode.json
fi
mkdir -p "$WORKSPACE"
if [ ! -d "$WORKSPACE/.git" ]; then
  log "clonando workspace..."
  git clone --quiet "http://oauth2:$GITLAB_TOKEN@${GITLAB_URL#*://}/${REPO_PATH}.git" "$WORKSPACE"
fi
git -C "$WORKSPACE" config user.name "kanban-agent"
git -C "$WORKSPACE" config user.email "kanban-agent@poc.local"
git -C "$WORKSPACE" checkout main >/dev/null 2>&1 || true
log "agente no ar (projeto $PROJECT_SLUG, modelo ${MODEL:-indefinido})"

# ---------- helpers ----------
REPO_PATH=${REPO_PATH:-root/$PROJECT_SLUG}
export REPO_PATH GITLAB_URL GITLAB_TOKEN
PROJECT_ID=$(python3 - <<'PY'
import json, os, urllib.parse, urllib.request
base = os.environ["GITLAB_URL"]
path = urllib.parse.quote(os.environ["REPO_PATH"], safe="")
req = urllib.request.Request(f"{base}/api/v4/projects/{path}")
req.add_header("PRIVATE-TOKEN", os.environ["GITLAB_TOKEN"])
print(json.load(urllib.request.urlopen(req))["id"])
PY
)
export PROJECT_ID

gl() { curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4$1"; }
gl_post() { curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Content-Type: application/json" \
  -X POST "$GITLAB_URL/api/v4$1" -d "${2:-\{\}}"; }

oc() { # $1=timeout, $2=prompt file (placeholders via python: descricao
       # multilinha quebraria sed)
  local PROMPT
  PROMPT=$(python3 - "$AGENT_DIR/prompts/$2.md" "$CARD_ID" "$CARD_TITLE" "$CHANGE_NAME" "$BRANCH" "${CARD_DESC:-}" <<'PYPATCH'
import sys
tpl = open(sys.argv[1], encoding="utf-8").read()
out = (tpl.replace("__CARD_ID__", sys.argv[2])
          .replace("__CARD_TITLE__", sys.argv[3])
          .replace("__CHANGE_NAME__", sys.argv[4])
          .replace("__BRANCH__", sys.argv[5])
          .replace("__CARD_DESC__", sys.argv[6]))
sys.stdout.write(out)
PYPATCH
)
  cd "$WORKSPACE" && timeout "$1" opencode run "$PROMPT"
}
render_desc() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("description",""))' "$1"; }

slug_of() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40; }

card_has_tag() { echo "$CARD_TAGS" | tr ',{}' '\n' | grep -qxF "$1"; }
card_commented() {
  # corpo de comentario no formato "- autor, data: /aprovado..."; o texto
  # "/aprovado" dentro de outros comentarios (ex.: o aviso do proprio
  # agente) NAO conta
  printf '%s\n' "$CARD_TEXT" | grep -qE '^- .*: */aprovado'
}

mcp_add_comment() { # $1=card id, $2=corpo (payload montado com json.dumps)
  CARD_BODY="$2" python3 - "$AGENT_DIR/mcp-kanzo.py" "$1" <<'PYPATCH'
import json, os, subprocess, sys
helper, cid = sys.argv[1], sys.argv[2]
args = json.dumps({"id": cid, "body": os.environ.get("CARD_BODY", ""), "author": "kanban-agent"})
subprocess.run(["python3", helper, "add_comment", args], check=True)
PYPATCH
}
sanitize() { printf '%s' "$1" | tr '\n' ' ' | tr -d '"' | tr '\\' ' ' | cut -c1-300; }

# ---------- loop ----------
CARD_ID="" CARD_TITLE="" CARD_TAGS="" CARD_TEXT="" CARD_DESC="" CHANGE_NAME="" BRANCH=""
while true; do
  # sincroniza main local e limpa sujeira de ciclos anteriores
  git -C "$WORKSPACE" checkout main >/dev/null 2>&1 || true
  git -C "$WORKSPACE" pull origin main >/dev/null 2>&1 || true
  git -C "$WORKSPACE" reset --hard origin/main >/dev/null 2>&1 || true
  git -C "$WORKSPACE" clean -fd >/dev/null 2>&1 || true

  ######################## FASE 1: propose (todo -> review) ########################
  CARDS=$(mcp list_tasks "{\"status\":\"todo\",\"project\":\"$PROJECT_SLUG\"}")
  log "scan todo: [$CARDS]"
  for CARD_ID in $(printf '%s\n' "$CARDS" | awk '$1 ~ /#/ {print $1}'); do
    CARD_LINE=$(printf '%s\n' "$CARDS" | grep "^$CARD_ID ")
    CARD_TITLE=$(printf '%s' "$CARD_LINE" | sed -E 's/^([^ ]+) \[[^]]*\] //; s/ \{[^}]*\}$//; s/ \([0-9]+ comments?\)$//')
    CARD_TEXT=$(mcp get_task "{\"id\":\"$CARD_ID\"}")
    CARD_TAGS=$(printf '%s' "$CARD_LINE" | grep -oE '\{[^}]*\}' | tr -d '{}' | head -1)
    card_has_tag "proposta-publicada" && continue
    CARD_DESC="$CARD_TEXT"  # contexto completo: titulo, descricao e comentarios
    NUM=${CARD_ID##*#}
    CHANGE_NAME="card-$NUM-$(slug_of "$CARD_TITLE")"
    log "propose: $CARD_ID -> $CHANGE_NAME"
    set +e
    oc "$PROPOSE_TIMEOUT" propose > /tmp/phase.log 2>&1
    OC_EXIT=$?
    set -u
    git -C "$WORKSPACE" fetch origin main >/dev/null 2>&1 || true
    if [ "$OC_EXIT" != "0" ] || ! git -C "$WORKSPACE" cat-file -e "origin/main:openspec/changes/$CHANGE_NAME/proposal.md" 2>/dev/null; then
      MSG=$(sanitize "$(tail -2 /tmp/phase.log)")
      fail_card "$CARD_ID" "propose" "$MSG"
      continue
    fi
    RESUMO=$(sanitize "$(head -30 "$WORKSPACE/openspec/changes/$CHANGE_NAME/proposal.md" 2>/dev/null)")
    mcp_add_comment "$CARD_ID" "**Proposta [$CHANGE_NAME]**\\n\\n$RESUMO\\n\\nComente **/aprovado** para autorizar a implementacao."
    mcp update_task "{\"id\":\"$CARD_ID\",\"status\":\"review\",\"tags\":\"proposta-publicada,change:$CHANGE_NAME\"}" >/dev/null
    log "proposta publicada no $CARD_ID ($CHANGE_NAME)"
  done

  ######################## FASE 2: apply (review -> doing -> review) ########################
  CARDS=$(mcp list_tasks "{\"status\":\"review\",\"project\":\"$PROJECT_SLUG\"}")
  log "scan review: [$CARDS]"
  for CARD_ID in $(printf '%s\n' "$CARDS" | awk '$1 ~ /#/ {print $1}'); do
    CARD_LINE=$(printf '%s\n' "$CARDS" | grep "^$CARD_ID ")
    CARD_TAGS=$(printf '%s' "$CARD_LINE" | grep -oE '\{[^}]*\}' | tr -d '{}' | head -1)
    card_has_tag "proposta-publicada" || continue
    card_has_tag "mr-aberto" && continue
    CARD_TEXT=$(mcp get_task "{\"id\":\"$CARD_ID\"}")
    card_commented || continue
    CHANGE_NAME=$(printf '%s' "$CARD_TAGS" | tr ',' '\n' | grep '^ *change:' | cut -d: -f2-)
    [ -n "$CHANGE_NAME" ] || continue
    NUM=${CARD_ID##*#}
    BRANCH="card/$NUM-$(slug_of "$CHANGE_NAME")"
    log "apply: $CARD_ID -> $CHANGE_NAME (branch $BRANCH)"
    # trava de idempotencia ANTES de executar
    mcp update_task "{\"id\":\"$CARD_ID\",\"tags\":\"proposta-publicada,aplicacao-iniciada,change:$CHANGE_NAME\"}" >/dev/null
    set +e
    oc "$APPLY_TIMEOUT" apply > /tmp/phase.log 2>&1
    OC_EXIT=$?
    set -u
    git -C "$WORKSPACE" fetch origin >/dev/null 2>&1 || true
    if [ "$OC_EXIT" != "0" ] || ! git -C "$WORKSPACE" ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
      MSG=$(sanitize "$(tail -2 /tmp/phase.log)")
      fail_card "$CARD_ID" "apply" "$MSG"
      continue
    fi
    git -C "$WORKSPACE" push -u origin "$BRANCH" >/dev/null 2>&1 \
      || { fail_card "$CARD_ID" "apply" "push da branch falhou"; continue; }
    MR=$(gl_post "/projects/$PROJECT_ID/merge_requests" "{\"source_branch\":\"$BRANCH\",\"target_branch\":\"main\",\"title\":\"card $CARD_ID: $CHANGE_NAME\",\"remove_source_branch\":true}")
    MR_URL=$(printf '%s' "$MR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("web_url",""))')
    MR_IID=$(printf '%s' "$MR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("iid",""))')
    mcp_add_comment "$CARD_ID" "**MR aberto: $MR_URL** (gate de secrets + code review por LLM rodam automaticamente). Comente no MR para discutir; faca o merge para concluir o card."
    mcp update_task "{\"id\":\"$CARD_ID\",\"url\":\"$MR_URL\",\"status\":\"review\",\"tags\":\"mr-aberto,change:$CHANGE_NAME,mr-iid:$MR_IID\"}" >/dev/null
    log "MR !$MR_IID aberto para $CARD_ID"
  done

  ######################## FASE 3: archive (review -> done) ########################
  CARDS=$(mcp list_tasks "{\"status\":\"review\",\"project\":\"$PROJECT_SLUG\"}")
  log "scan review: [$CARDS]"
  for CARD_ID in $(printf '%s\n' "$CARDS" | awk '$1 ~ /#/ {print $1}'); do
    CARD_LINE=$(printf '%s\n' "$CARDS" | grep "^$CARD_ID ")
    CARD_TAGS=$(printf '%s' "$CARD_LINE" | grep -oE '\{[^}]*\}' | tr -d '{}' | head -1)
    card_has_tag "mr-aberto" || continue
    CHANGE_NAME=$(printf '%s' "$CARD_TAGS" | tr ',' '\n' | grep '^ *change:' | cut -d: -f2-)
    MR_IID=$(printf '%s' "$CARD_TAGS" | tr ',' '\n' | grep '^ *mr-iid:' | cut -d: -f2-)
    [ -n "$MR_IID" ] || continue
    MR_STATE=$(gl "/projects/$PROJECT_ID/merge_requests/$MR_IID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
    [ "$MR_STATE" = "merged" ] || continue
    NUM=${CARD_ID##*#}
    BRANCH="card/$NUM-$(slug_of "$CHANGE_NAME")"
    log "archive: $CARD_ID (MR !$MR_IID merged)"
    set +e
    oc "$PROPOSE_TIMEOUT" archive > /tmp/phase.log 2>&1
    OC_EXIT=$?
    set -u
    git -C "$WORKSPACE" fetch origin main >/dev/null 2>&1 || true
    if [ "$OC_EXIT" != "0" ] \
       || [ -n "$(git -C "$WORKSPACE" ls-tree "origin/main" "openspec/changes/$CHANGE_NAME" 2>/dev/null)" ] \
       || ! git -C "$WORKSPACE" ls-tree -r "origin/main" "openspec/changes/archive/" 2>/dev/null | grep -q "$CHANGE_NAME"; then
      MSG=$(sanitize "$(tail -2 /tmp/phase.log)")
      fail_card "$CARD_ID" "archive" "$MSG"
      continue
    fi
    mcp update_task "{\"id\":\"$CARD_ID\",\"status\":\"done\",\"tags\":\"arquivada,change:$CHANGE_NAME\"}" >/dev/null
    mcp_add_comment "$CARD_ID" "**Concluido**: change $CHANGE_NAME arquivada e spec sincronizado (commit na main)."
    log "$CARD_ID concluido"
  done

  sleep "$POLL_INTERVAL"
done
