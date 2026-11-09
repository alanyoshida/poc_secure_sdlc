#!/usr/bin/env bash
# Tokens do GitLab usados pela plataforma (salvos como Secrets no ns cicd):
#  - gitlab-admin-token: PAT root com api (bootstrap, CI vars, repos)
#  - gitlab-repo-read:   PAT root com read_repository (clone no workflow do gate)
# Idempotente: reutiliza o token existente se ainda valido; caso contrario
# revoga e recria.
set -euo pipefail
cd "$(dirname "$0")/.."

create_pat() { # $1=nome $2=scopes(ruby) $3=dias
  local POD RUBY_B64
  POD=$(kubectl get pod -n gitlab -l app=toolbox -o jsonpath='{.items[0].metadata.name}')
  # heredoc sem delimitador quotado: $1/$2/$3 sao expandidos pelo shell,
  # mas #{...} (interpolação ruby) passa intacto
  RUBY_B64=$(cat <<RUBYEOF | base64 -w0
u = User.find_by(username: 'root')
old = u.personal_access_tokens.where(name: '$1', revoked: false).order(:created_at).last
old&.revoke!
t = u.personal_access_tokens.create!(name: '$1', scopes: $2, expires_at: $3.days.from_now)
puts "TOKEN:#{t.token}"
RUBYEOF
)
  kubectl exec "$POD" -n gitlab -- sh -c "echo $RUBY_B64 | base64 -d | gitlab-rails runner -" 2>/dev/null \
    | grep '^TOKEN:' | head -1 | cut -d: -f2-
}

token_valid() { # $1=token $2=scope_esperado_exposto_em_headers
  local HTTP
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $1" \
    http://127.0.0.1:8181/api/v4/user 2>/dev/null || echo 000)
  [ "$HTTP" = "200" ]
}

secret_value() { # $1=secret $2=chave
  kubectl get secret "$1" -n cicd -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d
}

kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT

# --- admin (api) ---
if ADMIN=$(secret_value gitlab-admin-token token) && [ -n "$ADMIN" ] && token_valid "$ADMIN"; then
  echo "gitlab-admin-token: reutilizando PAT valido"
else
  echo "gitlab-admin-token: criando PAT"
  ADMIN=$(create_pat 'platform-bootstrap' "['api', 'write_repository', 'read_repository']" 30)
  [ -n "$ADMIN" ] || { echo "falha ao criar PAT admin"; exit 1; }
  kubectl create secret generic gitlab-admin-token -n cicd \
    --from-literal=token="$ADMIN" --from-literal=user=root \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# --- read_repository (clone do workflow do gate) ---
if READ=$(secret_value gitlab-repo-read token) && [ -n "$READ" ] && token_valid "$READ"; then
  echo "gitlab-repo-read: reutilizando PAT valido"
else
  echo "gitlab-repo-read: criando PAT"
  READ=$(create_pat 'read-repository' "['read_repository']" 30)
  [ -n "$READ" ] || { echo "falha ao criar PAT read_repository"; exit 1; }
  kubectl create secret generic gitlab-repo-read -n cicd \
    --from-literal=user=oauth2 --from-literal=token="$READ" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
echo "tokens do GitLab prontos"
