# Tasks

## 1. ChartMuseum no cluster

- [x] 1.1 Criar `manifests/cicd/chartmuseum.yaml`: Deployment + PVC (1Gi) + Service ClusterIP 8080 (chart `chartmuseum/chartmuseum` versão fixada, `DISABLE_API=false`, `STORAGE` local no PVC); verificar pod Ready e API respondendo in-cluster
- [x] 1.2 Registrar o ChartMuseum como helm repo do ArgoCD e testar o ciclo publish/consume: `helm package` de um chart de teste + `curl --data-binary` no `/api/charts` + o chart aparece em `GET /api/charts`

## 2. ArgoCD no cluster

- [x] 2.1 Criar `manifests/argocd.yaml` (chart `argo/argo-cd` fixado, namespace `argocd`, `server.insecure`, configs de repositories/helm apontando para root/gitops e ChartMuseum) + Service ClusterIP; verificar pod Ready e UI respondendo via port-forward com login admin
- [x] 2.2 Registrar o repo `root/gitops` no ArgoCD com o PAT `gitops-writer` (via `configs.repositories` no values) e verificar que o ArgoCD lista o repo

## 3. Repos webapp e GitOps

- [x] 3.1 Criar `scripts/webapp-setup.sh` (idempotente, chamado pelo bootstrap): projeto GitLab `root/webapp`, seed do `example-webapp/` (app nginx + chart com probes + `.gitlab-ci.yml` com os estágios gate/build/chart/gitops), CI variables do Harbor + GITOPS_TOKEN, e projeto `root/gitops` semeado com a Application raiz + `apps/webapp.yaml` (targetRevision da versão inicial)
- [x] 3.2 Criar o PAT `gitops-writer` (api + write_repository) via rails + Secret/CI variable GITOPS_TOKEN, sem imprimir o valor
- [x] 3.3 Criar `example-webapp/`: `index.html`, `Dockerfile` (nginx), `chart/webapp/` (Chart.yaml, values, templates com liveness/readiness HTTP GET / na porta 80), `.gitlab-ci.yml` (gate/build/chart/gitops) e `ci/` (glue)
- [x] 3.4 Criar os manifests do ArgoCD root app (`manifests/argocd-root-app.yaml`: Application apontando para root/gitops, path apps, namespace webapps, syncPolicy automatic com selfHeal e prune off) e aplicar
- [x] 3.5 Criar o imagePullSecret do Harbor no namespace `webapps` (via bootstrap) para o pull das imagens privadas

## 4. Bootstrap e documentação

- [x] 4.1 Incorporar ao bootstrap: apply de chartmuseum.yaml, argocd.yaml, argocd-root-app.yaml; execução de webapp-setup.sh e gitops-setup; aviso se a chave do LLM estiver ausente (fluxos anteriores) sem afetar este fluxo; verificar dupla execução sem duplicar
- [x] 4.2 Documentar no README: arquitetura GitOps (ChartMuseum, repo GitOps, app-of-apps), como acompanhar o deploy na UI do ArgoCD, como criar uma nova app GitOps, e os acessos

## 5. Verificação ponta a ponta

- [x] 5.1 Fluxo v1: pipeline da webapp roda os 4 estágios (gate, build, chart, gitops) e verifica: imagem `apps/webapp:<sha>` no Harbor, chart `<versão>` no ChartMuseum, commit de release no repo GitOps, ArgoCD sincroniza e o pod nginx fica Ready no namespace webapps com probes funcionando
- [ ] 5.2 Fluxo v2 (nova versão): mudança na página + merge → pipeline publica v+1 → ArgoCD faz rollout (nova imagem no pod) sem ação manual
- [x] 5.3 Drift: editar manualmente um recurso do deploy no cluster e verificar o ArgoCD reverte para o estado do repo GitOps
- [ ] 5.4 Falha: card ambíguo no kanban ou pipeline com gate reprovado não gera chart nem deploy (verificar que nenhum commit de release acontece)

## Workflow follow-up

- Arquivar a change após revisão e implementação (spec sincroniza para `openspec/specs/`).
