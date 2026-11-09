#!/usr/bin/env bash
# Bootstrap completo da PoC de SDLC seguro (design.md D1).
# Idempotente: componentes existentes sao detectados e atualizados.
# Ordem: repos helm -> GitLab -> tokens -> Runner -> Harbor -> robot/secrets
#        -> imagem do buildkitd -> Argo (CRDs + charts + CRs) -> demo-app.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { echo; echo "==> $*"; }

GITLAB_CHART_VER=9.11.16
RUNNER_CHART_VER=0.94.3
HARBOR_CHART_VER=1.19.4
ARGO_WORKFLOWS_CHART_VER=2.0.18
ARGO_EVENTS_CHART_VER=2.4.27

step "1/9 repos helm"
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

step "2/9 GitLab CE (boot leva varios minutos)"
# namespaces explicitos: os secrets do passo 3 (cicd) precedem o helm do runner
for ns in gitlab cicd harbor; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
helm upgrade --install gitlab gitlab/gitlab --version "$GITLAB_CHART_VER" \
  -n gitlab -f helm/gitlab-values.yaml
kubectl rollout status deploy/gitlab-webservice-default -n gitlab --timeout=20m
kubectl rollout status deploy/gitlab-toolbox -n gitlab --timeout=10m

step "3/9 tokens do GitLab (admin + read_repository)"
./scripts/gitlab-tokens.sh

step "4/9 GitLab Runner (kubernetes executor)"
ADMIN_TOKEN=$(kubectl get secret gitlab-admin-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
kubectl -n gitlab port-forward svc/gitlab-webservice-default 8181:8181 >/dev/null 2>&1 &
PF=$!
sleep 4
trap 'kill $PF 2>/dev/null || true' EXIT
RUNNER_TOKEN=$(curl -sf -H "PRIVATE-TOKEN: $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -X POST http://127.0.0.1:8181/api/v4/user/runners \
  -d '{"runner_type":"instance_type","description":"poc-kubernetes","run_untagged":true,"locked":false}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
helm upgrade --install gitlab-runner gitlab/gitlab-runner --version "$RUNNER_CHART_VER" \
  -n cicd --create-namespace -f helm/runner-values.yaml --set runnerToken="$RUNNER_TOKEN"
kubectl rollout status deploy/gitlab-runner -n cicd --timeout=5m
kubectl apply -f manifests/cicd/job-rbac.yaml

step "5/9 Harbor"
helm upgrade --install harbor harbor/harbor --version "$HARBOR_CHART_VER" \
  -n harbor --create-namespace -f helm/harbor-values.yaml
kubectl rollout status statefulset/harbor-database -n harbor --timeout=10m
kubectl rollout status statefulset/harbor-redis -n harbor --timeout=10m
kubectl rollout status statefulset/harbor-trivy -n harbor --timeout=10m
kubectl wait --for=condition=Available deployments --all -n harbor --timeout=10m
make node-hosts

step "6/9 Harbor: projeto, robot account e secrets"
./scripts/harbor-setup.sh

step "7/9 imagem do buildkitd (idtools setuid)"
# aplica primeiro: o pod de geracao usa o PVC de cache do buildkitd
kubectl apply -f manifests/cicd/buildkitd.yaml
./scripts/buildkit-image.sh
kubectl rollout status deploy/buildkitd -n cicd --timeout=15m

step "8/9 Argo Workflows + Argo Events"
# CRDs do argo-workflows ficam em files/crds (nao sao auto-instaladas pelo helm)
rm -rf /tmp/aw-chart && mkdir -p /tmp/aw-chart
helm pull argo/argo-workflows --version "$ARGO_WORKFLOWS_CHART_VER" -d /tmp >/dev/null
tar xzf /tmp/argo-workflows-*.tgz -C /tmp/aw-chart
kubectl apply -f /tmp/aw-chart/argo-workflows/files/crds/minimal/ >/dev/null
helm upgrade --install argo-workflows argo/argo-workflows --version "$ARGO_WORKFLOWS_CHART_VER" \
  -n cicd -f helm/argo-workflows-values.yaml
helm upgrade --install argo-events argo/argo-events --version "$ARGO_EVENTS_CHART_VER" \
  -n cicd
kubectl rollout status deploy/argo-workflows-workflow-controller -n cicd --timeout=10m
kubectl rollout status deploy/argo-workflows-server -n cicd --timeout=10m
kubectl rollout status deploy/argo-events-controller-manager -n cicd --timeout=10m
kubectl apply -f manifests/cicd/eventbus.yaml
kubectl apply -f manifests/cicd/argo-events-rbac.yaml
kubectl apply -f manifests/cicd/workflow-rbac.yaml
kubectl apply -f manifests/cicd/gitleaks-workflowtemplate.yaml
kubectl apply -f manifests/cicd/secrets-gate-eventsource.yaml
kubectl apply -f manifests/cicd/secrets-gate-sensor.yaml
kubectl wait --for=condition=Ready pods -l eventsource-name=secrets-gate -n cicd --timeout=5m
kubectl wait --for=condition=Ready pods -l sensor-name=secrets-gate -n cicd --timeout=5m

step "9/9 repositorio de aplicacao exemplo + variaveis de CI"
./scripts/demo-app-setup.sh

kill $PF 2>/dev/null || true
echo
echo "==> Bootstrap concluido. Acessos:"
make urls
