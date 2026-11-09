# Design

## Context

A change `setup-secure-sdlc-poc` deixou no ar o gate de secrets para o
pipeline de CI: EventSource webhook `secrets-gate` (porta 12000, endpoint
`/gate`), Sensor que instancia o WorkflowTemplate `gitleaks-scan`
(parâmetros `repo_url` + `sha`, extraídos de `body.*` do payload), EventBus
jetstream e o Secret `gitlab-repo-read` (token read_repository) para o
clone. O usuário quer que a abertura/atualização de um MR dispare o mesmo
scan automaticamente, via webhook do GitLab.

## Goals / Non-Goals

**Goals:**
- MR aberto/reaberto/atualizado → Workflow gitleaks no SHA do último commit
  do branch de origem, sem intervenção manual
- Reuso máximo do que existe (mesmo WorkflowTemplate, EventBus, Service do
  EventSource); zero componentes novos no cluster
- Bootstrap reproduz tudo (100% do ambiente continua subindo do zero)

**Non-Goals:**
- Publicar o veredito de volta no GitLab (commit status / nota no MR):
  exigiria token com escopo `api` no fluxo de scan, contra a postura de
  privilégio mínimo (o workflow usa somente `read_repository`). Fica como
  evolução no roadmap.
- Scan apenas do delta do MR (source vs target): o comportamento padrão é
  o mesmo do gate de CI (histórico completo do branch), mantendo
  consistência entre "branch reprova" e "pipeline reprova".
- Eventos outros de MR (merge, close, approval), webhooks de push do GitLab
  (o pipeline de CI já cobre push), e autenticação do endpoint webhook
  (mesma postura da change anterior: tráfego in-cluster).

## Decisions

### D1: Segunda rota no EventSource existente (endpoint `/mr`)

O EventSource `secrets-gate` ganha um segundo webhook (`secrets-gate-mr`,
endpoint `/mr`, mesma porta 12000/serviço) em vez de um EventSource novo.
Rota separada do `/gate` porque o payload do GitLab é totalmente diferente
do payload `{repo_url, sha}` do job de CI — separar os endpoints mantém
cada Sensor com um contrato de payload único. Custo zero de infraestrutura
(mesmo pod/serviço).

### D2: Sensor dedicado com filtro de ações

Sensor `secrets-gate-mr` com dependency expression filter: `object_kind ==
merge_request` e `action in (open, reopen, update)`. Sem o filtro, eventos
irrelevantes (merge, close, approval, atualizações de título) disparariam
scans inúteis. O filter é aplicado no Sensor (não no EventSource) — o
EventSource webhook é um transporte genérico.

### D3: Mapeamento do payload do GitLab

O webhook EventSource embrulha o body do GitLab em `{header, body, metadata}`
(e o body do GitLab é JSON cru — `*json.RawMessage`). Mapeamento:

- `sha` ← `body.object_attributes.last_commit.id` (gjson path, via
  `dataKey`)
- `repo_url` ← construído no Sensor com `dataTemplate`:
  `http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/{{ .Input.body.project.path_with_namespace }}.git`
  — constrói a URL de clone **interna** (o workflow clona in-cluster; o
  `git_http_url` do payload aponta para a URL externa nip.io que não
  resolve dentro do cluster) e funciona para qualquer projeto, não só o
  demo-app
- `mr_iid` ← `body.object_attributes.iid` (rastreabilidade)

O WorkflowTemplate ganha o parâmetro opcional `mr_iid` (default vazio): não
altera o scan, aparece nos parâmetros do run (`argo get`/UI) para correlação
com o MR.

### D4: GitLab webhook + setting de rede local

O webhook do projeto aponta para
`http://secrets-gate-eventsource-svc.cicd.svc.cluster.local:12000/mr`
(ClusterIP — o GitLab roda no mesmo cluster e resolve o FQDN via CoreDNS).
O GitLab bloqueia por padrão webhooks para redes locais; habilitar o setting
admin `allow_local_requests_from_web_hooks_and_integrations` via API
(`PUT /application/settings`, PAT admin do secret `gitlab-admin-token`).
Ambos (hook + setting) idempotentes via API, chamados pelo bootstrap.

### D5: Sem callback de resultado nesta change

O veredito fica visível no Argo (UI/CLI). Postar status no MR/natificar o
autor exigiria credencial com escopo `api` no fluxo do scan — contradiz a
decisão de segurança da change anterior (token mínimo, fail-closed). A
evolução (assinatura com cosign + notificação) já está no roadmap e pode
introduzir um fluxo separado com a credencial adequada.

## Arquitetura

```
MR aberto/atualizado no GitLab
  -> webhook (project hook, eventos de MR)
  -> http://secrets-gate-eventsource-svc.cicd.svc:12000/mr
  -> EventSource secrets-gate (rota /mr) -> EventBus jetstream
  -> Sensor secrets-gate-mr (filtra object_kind=merge_request,
                             action in open/reopen/update)
  -> Workflow gitleaks-scan (repo_url interno, sha do source branch, mr_iid)
  -> veredito no Argo (Succeeded/Failed)
```

## Risks / Trade-offs

- [Eventos de update do MR podem disparar vários scans em sequência (um por
  push na branch)] → aceito na PoC: cada scan é rápido (~20s) e o filtro
  elimina os eventos irrelevantes; deduplicação fica para o roadmap
- [Webhook falha silenciosamente se o GitLab não conseguir resolver/alcçar o
  service (setting de rede local desligado)] → verificação explícita nos
  tasks: "Recent deliveries" do hook deve registrar sucesso no teste E2E
- [Payload do GitLab grande (MR com muitos commits)] → o EventSource
  transmite o body inteiro; irrelevante na PoC (payloads de MR ficam em
  dezenas de KB)

## Open Questions

- Nenhum aberto: comportamento e encaixe são determinísticos dado o payload
  documentado do GitLab e o webhook EventSource já validado na change
  anterior.
