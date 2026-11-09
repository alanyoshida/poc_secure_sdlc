#!/bin/sh
# Poll do gate de secrets (design.md D4). Fail-closed: timeout ou erro
# de infraestrutura tambem reprova o pipeline.
# Copia canonica; a copia versionada no repositorio de aplicacao exemplo
# (ci/gate-poll.sh) e a que os jobs de CI executam.
# Uso: gate-poll.sh <repo_url> <sha>
#
# Env opcionais:
#   GATE_WEBHOOK_URL    endpoint do EventSource do Argo Events
#   GATE_NAMESPACE      namespace dos Workflows (default: cicd)
#   GATE_POLL_INTERVAL  intervalo do poll em segundos (default: 10)
#   GATE_POLL_TIMEOUT   timeout total em segundos (default: 300)
set -eu

REPO_URL="${1:?uso: gate-poll.sh <repo_url> <sha>}"
SHA="${2:?uso: gate-poll.sh <repo_url> <sha>}"
WEBHOOK_URL="${GATE_WEBHOOK_URL:-http://secrets-gate-eventsource-svc.cicd.svc.cluster.local:12000/gate}"
NAMESPACE="${GATE_NAMESPACE:-cicd}"
INTERVAL="${GATE_POLL_INTERVAL:-10}"
TIMEOUT="${GATE_POLL_TIMEOUT:-300}"

TOKEN_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token
CA_FILE=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
WORKFLOWS_API="https://kubernetes.default.svc/apis/argoproj.io/v1alpha1/namespaces/${NAMESPACE}/workflows"

echo "[gate] disparando scan: repo=${REPO_URL} sha=${SHA}"
if ! curl -sf -X POST "${WEBHOOK_URL}" -H 'Content-Type: application/json' \
     -d "{\"repo_url\":\"${REPO_URL}\",\"sha\":\"${SHA}\"}" >/dev/null; then
  echo "[gate] FALHA ao chamar o webhook - reprova (fail-closed)"
  exit 1
fi

echo "[gate] aguardando veredito (intervalo=${INTERVAL}s, timeout=${TIMEOUT}s)"
start=$(date +%s)
while :; do
  wf_name=$(curl -sf --cacert "${CA_FILE}" \
      -H "Authorization: Bearer $(cat "${TOKEN_FILE}")" "${WORKFLOWS_API}" \
      | jq -r --arg sha "${SHA}" '
        [ .items[]
        | select(any(.spec.arguments.parameters[]?; .name == "sha" and .value == $sha)) ]
        | sort_by(.metadata.creationTimestamp)
        | last
        | .metadata.name // empty')
  if [ -n "${wf_name}" ]; then
    phase=$(curl -sf --cacert "${CA_FILE}" \
        -H "Authorization: Bearer $(cat "${TOKEN_FILE}")" \
        "${WORKFLOWS_API}/${wf_name}" | jq -r '.status.phase // "Pending"')
    echo "[gate] workflow ${wf_name}: ${phase}"
    case "${phase}" in
      Succeeded)
        echo "[gate] APROVADO"
        exit 0
        ;;
      Failed|Error)
        echo "[gate] REPROVADO (secrets encontrados ou erro no scan)"
        exit 1
        ;;
    esac
  fi
  now=$(date +%s)
  if [ $((now - start)) -ge "${TIMEOUT}" ]; then
    echo "[gate] TIMEOUT apos ${TIMEOUT}s sem veredito - reprova (fail-closed)"
    exit 1
  fi
  sleep "${INTERVAL}"
done
