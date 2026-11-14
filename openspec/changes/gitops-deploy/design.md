# Design

## Context

O pipeline fecha até o push da imagem no Harbor (gate → build → push) e os
agentes de análise cobrem MRs. Falta o deploy. A spec pede ArgoCD +
ChartMuseum + repo GitOps, com o chart da app contendo liveness/readiness
do nginx. Decisões do usuário já tomadas na exploração anterior: ArgoCD
observa repositório GitOps (repo-driven), ChartMuseum publica os charts,
app nginx nova dedicada.

## Goals / Non-Goals

**Goals:**
- Merge na main da webapp → imagem no Harbor → chart no ChartMuseum →
  commit no repo GitOps → ArgoCD sincroniza o kind — sem ação manual
- Probes de liveness/readiness HTTP no nginx garantidas pelo chart
- Bootstrap reproduz tudo (repos, PAT, apps, componentes)

**Non-Goals:**
- Autenticação no ChartMuseum (in-cluster, PoC) e TLS no ArgoCD
- Argo Rollouts/canary; múltiplos ambientes (staging/prod)
- Integração do deploy com o kanban (o card fecha no merge do MR; o deploy
  é consequência automática pós-merge)
- Webhook do GitLab para o ArgoCD (poll de 3min do ArgoCD basta na PoC)

## Decisions

### D1: ArgoCD via chart fixado, HTTP e admin gerado

Chart `argo/argo-cd` versão fixada, namespace `argocd`, `configs.params`
com `server.insecure: true` (sem TLS na PoC) e UI via **port-forward**
(padrão do ambiente — o ArgoCD valida cookies de sessão por host; com
port-forward o host é localhost e funciona sem configuração extra). Admin:
password gerada pelo chart em `secret/argocd-initial-admin-secret`
(recuperação documentada no README). O repositório `root/gitops` é
registrado nas `configs.repositories` com o PAT `gitops-writer`, e o
ChartMuseum nas `configs.helm.repositories` (sem auth).

### D2: ChartMuseum com PVC e API aberta in-cluster

Chart `chartmuseum/chartmuseum` fixado, PVC 1Gi, `DISABLE_API=false` (o
push do CI usa POST /api/charts) e Service ClusterIP `chartmuseum.cicd.svc`
porta 8080. Sem auth: qualquer pod do cluster pode publicar — postura
aceita da PoC (mesmo nível do registry HTTP e do webhook sem token).

### D3: Aplicação raiz (app-of-apps) apontando para root/gitops

Um Application `root` no ArgoCD com source `root/gitops` (path `apps`,
Directory) e destination in-cluster namespace `webapps`: os YAMLs em
`apps/*.yaml` viram Applications filhos. Application novo no repo é adotado
automaticamente; o sync do `root` fica **automático + selfHeal + prune
desligado** (prune off evita que um erro de template apague recursos; o
filho de app controla o próprio sync).

### D4: Application da webapp referenciando o ChartMuseum por versão

`apps/webapp.yaml`: Application com `spec.sources[0]` Helm:
`repoURL: http://chartmuseum.cicd.svc:8080`, `chart: webapp`,
`targetRevision: "<versão>"` — a versão é atualizada pelo pipeline. O
chart, por sua vez, referencia a imagem do Harbor por tag do SHA. Duas
fontes encadeadas (chart do museum + tag no Chart.yaml/values do chart) —
o commit do pipeline atualiza o `targetRevision` no repo GitOps ✓ spec.

### D5: Pipeline da webapp — estágios `chart` e `gitops`

Após o push da imagem, o job `chart`: extrai a versão do `Chart.yaml`
(semver patch++ via script determinístico), atualiza `values.yaml`
(image.tag = $CI_COMMIT_SHORT_SHA), `helm package`, `curl --data-binary`
para o ChartMuseum. O job `gitops`: clona `root/gitops` com o PAT
`gitops-writer`, atualiza `targetRevision` em `apps/webapp.yaml`, commit
mensagem `release webapp <versão>` e push na main. Ambos idempotentes por
SHA (a mesma versão do chart não é republicada; commit vazio é pulado).

### D6: Chart webapp com probes

Chart mínimo (Deployment + Service + probes): `livenessProbe`/`readinessProbe`
HTTP GET `/` porta 80 (o nginx responde na raiz). `image.repository`
default `harbor.harbor.svc.cluster.local/apps/webapp` e `image.tag` passado
pelo pipeline. O ArgoCD faz o pull da imagem do Harbor — a robot account do
projeto `apps` é registrada como `imagePullSecret` no namespace `webapps`
(via bootstrap) para o pull autenticado.

### D7: Namespace `webapps` para os deploys do GitOps

Os Applications filhos deployam no namespace `webapps` (criado pelo
bootstrap, com o imagePullSecret do Harbor). Separação clara: `cicd` =
ferramentas, `webapps` = workloads GitOps.

### D8: PAT dedicado gitops-writer

Novo PAT `gitops-writer` (api + write_repository) para o pipeline commitar
no repo GitOps — o PAT do kanban-agent ficaria acoplado ao fluxo do board.
Criado pelo bootstrap (rails), Secret no cluster, exposto à CI como
variável mascarada GITOPS_TOKEN.

## Arquitetura

```
merge na main da webapp
  -> pipeline: gate -> build (Harbor apps/webapp:<sha>)
             -> chart (bump + package + push ChartMuseum v0.x.y)
             -> gitops (commit targetRevision=v0.x.y em root/gitops)
  -> ArgoCD (auto-sync, app-of-apps) detecta o commit
  -> Application webapp -> ChartMuseum v0.x.y -> Deployment nginx (probes)
  -> pod Ready com a nova imagem no namespace webapps (kind)
```

## Risks / Trade-offs

- [Sync automático + selfHeal reverte ajustes manuais] → é o objetivo do
  GitOps; na PoC os recursos são do namespace webapps apenas
- [ChartMuseum sem auth: qualquer pod publica charts] → in-cluster, PoC;
  evolução: auth básica + TLS
- [ArgoCD ~1GB de RAM] → folga da máquina (46GB) comporta
- [Rollout do nginx com probes mal calibrados derruba o pod] → probes
  conservadores (initialDelaySeconds 10, failureThreshold 3) e a página é
  estática
- [Duas fontes encadeadas (chart + tag)] → o commit do pipeline atualiza o
  targetRevision que aponta para a versão exata do chart que contém a tag
  do mesmo SHA — atomicidade garantida pelo pipeline em dois estágios
  distintos e idempotentes

## Open Questions

- Nenhum aberto; nomes/ports/versões fixados nas tasks.
