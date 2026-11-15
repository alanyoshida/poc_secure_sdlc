#!/usr/bin/env bash
# Bootstrap completo da PoC de SDLC seguro (design.md D1).
# Idempotente: componentes existentes sao detectados e atualizados.
# Ordem: repos helm -> GitLab -> tokens -> Runner -> Harbor -> robot/secrets
#        -> imagem do buildkitd -> Argo (CRDs + charts + CRs) -> GitOps
#        (ArgoCD + ChartMuseum + webapp) -> assinatura de imagens (cosign
#        + Kyverno) -> demo-app -> kanban agent.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { echo; echo "==> $*"; }

GITLAB_CHART_VER=9.11.16
RUNNER_CHART_VER=0.94.3
HARBOR_CHART_VER=1.19.4
ARGO_WORKFLOWS_CHART_VER=2.0.18
ARGO_EVENTS_CHART_VER=2.4.27
ARGOCD_CHART_VER=10.17.0
CHARTMUSEUM_CHART_VER=3.10.4
KYVERNO_CHART_VER=3.9.2

step "1/13 repos helm"
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add chartmuseum https://chartmuseum.github.io/charts >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null

step "2/13 GitLab CE (boot leva varios minutos)"
# namespaces explicitos: os secrets do passo 3 (cicd) precedem o helm do runner
for ns in gitlab cicd harbor; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
helm upgrade --install gitlab gitlab/gitlab --version "$GITLAB_CHART_VER" \
  -n gitlab -f helm/gitlab-values.yaml
kubectl rollout status deploy/gitlab-webservice-default -n gitlab --timeout=20m
kubectl rollout status deploy/gitlab-toolbox -n gitlab --timeout=10m

step "3/13 tokens do GitLab (admin + read_repository)"
./scripts/gitlab-tokens.sh

step "4/13 GitLab Runner (kubernetes executor)"
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

step "5/13 Harbor"
helm upgrade --install harbor harbor/harbor --version "$HARBOR_CHART_VER" \
  -n harbor --create-namespace -f helm/harbor-values.yaml
kubectl rollout status statefulset/harbor-database -n harbor --timeout=10m
kubectl rollout status statefulset/harbor-redis -n harbor --timeout=10m
kubectl rollout status statefulset/harbor-trivy -n harbor --timeout=10m
kubectl wait --for=condition=Available deployments --all -n harbor --timeout=10m
make node-hosts
./scripts/harbor-dual-scheme.sh

step "6/13 Harbor: projeto, robot account e secrets"
./scripts/harbor-setup.sh

step "7/13 imagem do buildkitd (idtools setuid)"
# aplica primeiro: o pod de geracao usa o PVC de cache do buildkitd
kubectl apply -f manifests/cicd/buildkitd.yaml
./scripts/buildkit-image.sh
kubectl rollout status deploy/buildkitd -n cicd --timeout=15m

step "8/13 Argo Workflows + Argo Events"
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
kubectl apply -f manifests/cicd/secrets-gate-mr-sensor.yaml
kubectl apply -f manifests/cicd/mr-code-review.yaml
kubectl create configmap mr-review-glue -n cicd \
  --from-file=post_review.py=scripts/post_review.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl wait --for=condition=Ready pods -l eventsource-name=secrets-gate -n cicd --timeout=5m
kubectl wait --for=condition=Ready pods -l sensor-name=secrets-gate -n cicd --timeout=5m
kubectl wait --for=condition=Ready pods -l sensor-name=secrets-gate-mr -n cicd --timeout=5m
kubectl wait --for=condition=Ready pods -l sensor-name=secrets-gate-mr -n cicd --timeout=5m

step "9/13 GitOps: ArgoCD + ChartMuseum + repos webapp/gitops"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
GITOPS_TOKEN=$(kubectl get secret gitops-writer-token -n cicd -o jsonpath='{.data.token}' | base64 -d)
kubectl create secret generic argocd-gitops-auth -n argocd \
  --from-literal=token="$GITOPS_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VER" \
  -n argocd -f helm/argocd-values.yaml
helm upgrade --install chartmuseum chartmuseum/chartmuseum --version "$CHARTMUSEUM_CHART_VER" \
  -n cicd -f helm/chartmuseum-values.yaml
kubectl rollout status deploy/argocd-server -n argocd --timeout=10m
kubectl rollout status deploy/argocd-repo-server -n argocd --timeout=10m
kubectl rollout status deploy/chartmuseum -n cicd --timeout=10m
./scripts/webapp-setup.sh
kubectl apply -f manifests/argocd-root-app.yaml
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/root -n argocd --timeout=5m

step "10/13 assinatura de imagens: chave cosign + Kyverno"
./scripts/cosign-setup.sh
kubectl apply -f manifests/cicd/job-rbac.yaml
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VER" \
  -n kyverno --create-namespace -f helm/kyverno-values.yaml \
  --set upgrade.acknowledgeLegacyPoliciesNotEnforced=true
kubectl rollout status deploy/kyverno-admission-controller -n kyverno --timeout=5m
# o Kyverno le credenciais do registry por nome-simples no seu proprio
# namespace (manifests/cosign-verify-policy.yaml) - copia do Secret que
# webapp-setup.sh ja criou em webapps, sem credencial nova
kubectl get secret harbor-pull-webapps -n webapps -o json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'apiVersion':'v1','kind':'Secret','type':d['type'],'metadata':{'name':'harbor-pull-webapps','namespace':'kyverno'},'data':d['data']}))" \
  | kubectl apply -f -
kubectl apply -f manifests/cosign-verify-policy.yaml

step "11/13 repositorio de aplicacao exemplo + variaveis de CI"
./scripts/demo-app-setup.sh

step "12/13 agente kanban (Kanzo + agente + workspace)"
kubectl apply -f manifests/cicd/kanzo.yaml
kubectl rollout status deploy/kanzo -n cicd --timeout=300s
kubectl create configmap kanban-agent-loop -n cicd \
  --from-file=kanban-agent-loop.sh=scripts/kanban-agent-loop.sh \
  --from-file=mcp-kanzo.py=scripts/mcp-kanzo.py \
  --from-file=propose.md=scripts/agent-prompts/propose.md \
  --from-file=apply.md=scripts/agent-prompts/apply.md \
  --from-file=archive.md=scripts/agent-prompts/archive.md \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f manifests/cicd/kanban-agent.yaml
kubectl rollout status deploy/kanban-agent -n cicd --timeout=600s
kubectl -n cicd port-forward svc/kanzo 4242:4242 >/dev/null 2>&1 &
KANZO_PF=$!
sleep 4
./scripts/agent-workspace-setup.sh
kill $KANZO_PF 2>/dev/null || true

step "13/13 Secrets do LLM (review de MR + agente)"
if kubectl get secret ocr-llm -n cicd >/dev/null 2>&1; then
  echo "Secret ocr-llm: ja presente"
elif [ -f .env ]; then
  echo "Secret agent-llm (agente kanban): criando a partir do .env local"
  python3 - <<'PY' | kubectl apply -f -
import json
vals = {}
for line in open(".env", encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k.strip()] = v.strip().strip('"').strip("'")
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "agent-llm", "namespace": "cicd"}, "type": "Opaque",
    "stringData": {"auth_token": vals.get("llm_api_key", ""),
                   "model": vals.get("llm_model", "")},
}))
PY
  echo "Secret ocr-llm: criando a partir do .env local"
  python3 - <<'PY' | kubectl apply -f -
import json
vals = {}
for line in open(".env", encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k.strip()] = v.strip().strip('"').strip("'")
url = vals.get("llm_url", "")
if url and not url.rstrip("/").endswith("/chat/completions"):
    url = url.rstrip("/") + "/chat/completions"
provider = vals.get("llm_provider", "")
data = {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "ocr-llm", "namespace": "cicd"}, "type": "Opaque",
    "stringData": {
        "llm_url": url,
        "auth_token": vals.get("llm_api_key", ""),
        "model": vals.get("llm_model", ""),
        "use_anthropic": "true" if "anthropic" in provider.lower() else "false",
        "provider": provider,
    },
}
missing = [k for k, v in data["stringData"].items() if not v and k != "provider"]
if missing:
    print("# ERRO: chaves ausentes no .env:", missing); raise SystemExit(1)
print(json.dumps(data))
PY
else
  echo "AVISO: Secret ocr-llm ausente e sem .env local - o review de MR e o"
  echo "agente kanban vao"
  echo "falhar ate voce cria-lo:"
  echo "  kubectl create secret generic ocr-llm -n cicd \\"
  echo "    --from-literal=llm_url=<endpoint>/chat/completions \\"
  echo "    --from-literal=auth_token=<chave> --from-literal=model=<modelo>"
fi

kill $PF 2>/dev/null || true
echo
echo "==> Bootstrap concluido. Acessos:"
make urls
