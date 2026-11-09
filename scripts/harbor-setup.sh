#!/usr/bin/env bash
# Setup do Harbor para a PoC (design.md D6):
#  - projeto privado "apps" com auto_scan (scanOnPush)
#  - robot account "ci" (system-level, escopo projeto apps, pull+push)
#  - secrets no ns cicd: harbor-robot (creds crua) e harbor-pull (dockerconfigjson)
# Idempotente: projeto criado/atualizado; robot recriada a cada bootstrap
# para obter um secret novo (a API desta versao nao expõe refresh).
set -euo pipefail
cd "$(dirname "$0")/.."

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-secure-sdlc-control-plane)
API="http://$NODE_IP:30002/api/v2.0"
# senha do admin fixada em helm/harbor-values.yaml (ambiente local de PoC)
AUTH="admin:Harbor12345"

echo "aguardando API do Harbor..."
for _ in $(seq 1 60); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' "$API/ping" 2>/dev/null || echo 000)
  [ "$HTTP" = "200" ] && break
  sleep 5
done
[ "$HTTP" = "200" ] || { echo "Harbor API nao respondeu"; exit 1; }

# --- projeto apps (privado + scanOnPush) ---
HTTP=$(curl -s -o /tmp/hproj.out -w '%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
  -X POST "$API/projects" \
  -d '{"project_name":"apps","public":false,"metadata":{"auto_scan":"true","public":"false"}}')
if [ "$HTTP" = "409" ]; then
  echo "projeto apps: ja existe, garantindo privado + auto_scan"
  HTTP2=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
    -X PUT "$API/projects/apps" -d '{"metadata":{"auto_scan":"true","public":"false"}}')
  [ "$HTTP2" = "200" ] || { echo "PUT projeto apps falhou (HTTP $HTTP2)"; exit 1; }
elif [ "$HTTP" != "201" ]; then
  echo "criacao do projeto apps falhou (HTTP $HTTP)"; cat /tmp/hproj.out; exit 1
else
  echo "projeto apps: criado (privado, auto_scan)"
fi

# --- robot account "ci" (system-level, escopo projeto apps) ---
# system-level porque este build do Harbor lista/apaga so robots de sistema
# via /robots (robots de projeto nao aparecem na listagem).
ROBOT_BODY='{"name":"ci","description":"robot do pipeline CI da PoC","duration":-1,"level":"system","permissions":[{"kind":"project","namespace":"apps","access":[{"resource":"repository","action":"pull"},{"resource":"repository","action":"push"}]}]}'
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
  -X POST "$API/robots" -d "$ROBOT_BODY")
HTTP=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$HTTP" = "409" ]; then
  # ja existe: apaga e recria (secret novo)
  RID=$(curl -s -u "$AUTH" "$API/robots?query=level%3Dsystem&page_size=100" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((r["id"] for r in d if r["name"]=="robot$ci"), ""))')
  [ -n "$RID" ] || { echo "robot ci existe mas nao foi listada"; exit 1; }
  curl -s -o /dev/null -u "$AUTH" -X DELETE "$API/robots/$RID"
  RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/robots" -d "$ROBOT_BODY")
  HTTP=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')
fi
[ "$HTTP" = "201" ] || { echo "criacao da robot ci falhou (HTTP $HTTP)"; echo "$BODY"; exit 1; }
ROBOT_NAME=$(echo "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
ROBOT_SECRET=$(echo "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')
echo "robot account: $ROBOT_NAME"

# --- secrets no ns cicd ---
kubectl create secret generic harbor-robot -n cicd \
  --from-literal=registry=harbor.harbor.svc.cluster.local \
  --from-literal=username="$ROBOT_NAME" \
  --from-literal=password="$ROBOT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret docker-registry harbor-pull -n cicd \
  --docker-server=harbor.harbor.svc.cluster.local \
  --docker-username="$ROBOT_NAME" --docker-password="$ROBOT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "secrets harbor-robot e harbor-pull atualizados no ns cicd"
