# Proposal

## Why

O SDLC da PoC hoje termina no merge: a imagem é construída e pushada ao
Harbor, mas **nada a entrega no cluster** — o deploy é manual. Falta o
último elo: **entrega contínua GitOps**. Com ArgoCD (deploy declarativo
observável, com rollback nativo) e ChartMuseum (repositório Helm próprio),
o ciclo de vida de um card fecha de ponta a ponta: card → proposta →
implementação → MR mergeado → **nova versão do chart no ChartMuseum →
commit no repositório GitOps → deploy automático no próprio kind**.

## What Changes

- **ArgoCD no cluster** (chart `argo/argo-cd` fixado, namespace `argocd`,
  HTTP na PoC, UI via port-forward; repositório GitLab `root/gitops`
  registrado com PAT dedicado; ChartMuseum registrado como helm repo)
- **ChartMuseum no cluster** (chart fixado, PVC para os charts, API sem
  autenticação — tráfego in-cluster; push pelo CI via `/api/charts`)
- **Nova aplicação `root/webapp`** — servidor web nginx (página própria) com
  Dockerfile e **chart Helm próprio** contendo **liveness e readiness
  probes HTTP apontando para o nginx**, e o **pipeline completo** já
  construído: `security-gate` → `build` (push da imagem
  `apps/webapp:<sha>` no Harbor) → `chart` (bump de versão do Chart.yaml,
  atualização da tag da imagem, `helm package` e push ao ChartMuseum) →
  `gitops` (commit da nova versão no repositório GitOps)
- **Repositório GitOps `root/gitops`**: contém o Application raiz
  (app-of-apps apontando para o diretório `apps/`) e os manifests de
  Application por app (ex.: `apps/webapp.yaml`, referenciando o chart do
  ChartMuseum com `targetRevision` da versão); o pipeline comita nele a
  subida de versão e o ArgoCD detecta e sincroniza
- **Aplicação raiz no ArgoCD** apontando para `root/gitops` (app-of-apps):
  Applications novos no repo são adotados automaticamente
- Bootstrap atualizado para provisionar ArgoCD, ChartMuseum, PAT do GitOps,
  os dois repositórios e os vínculos

Não muda: os fluxos anteriores (gate no pipeline e no MR, LLM review,
kanban-agent, Harbor robot accounts) — o pipeline da webapp **reutiliza**
os mesmos componentes (gate, buildx remoto, robot do projeto `apps`).

## Capabilities

### New Capabilities

- `gitops-deploy`: entrega contínua GitOps no cluster — ArgoCD +
  ChartMuseum + repositório GitOps com Applications; o pipeline da
  aplicação publica nova versão do chart (com a imagem nova) no
  ChartMuseum e comita a subida de versão no repositório GitOps, e o
  ArgoCD detecta e faz o deploy no próprio kind, com probes de
  liveness/readiness no nginx garantidos pelo chart

### Modified Capabilities

(nenhuma)

## Impact

- **Novos componentes no cluster**: ArgoCD (~1GB RAM) e ChartMuseum
  (~100MB) — dentro da folga da máquina
- **Novos artefatos**: `manifests/argocd.yaml` (secrets/repos/helm config),
  `manifests/chartmuseum.yaml`, `manifests/argocd-root-app.yaml`,
  `example-webapp/` (app nginx + chart + pipeline), `scripts/webapp-setup.sh`
  e `scripts/gitops-setup.sh`
- **Nova credencial**: PAT `gitops-writer` (api + write_repository) para o
  pipeline commitar no repositório GitOps
- **Riscos**: ChartMuseum sem auth é aceito na PoC (in-cluster); sync
  automático do ArgoCD com `selfHeal` ligado — mudanças manuais no cluster
  são revertidas (é o objetivo do GitOps)
