# Proposal

## Why

Hoje o security gate (gitleaks) roda apenas dentro do pipeline de CI: o job
`security-gate` chama o webhook do Argo Events em pushes. Não existe nenhum
fluxo que dispare automaticamente o scan quando um **Merge Request** é aberto
ou atualizado — o revisor não tem o veredito do gate no contexto do MR e a
validação depende do pipeline da branch. O Argo Events já é o barramento de
eventos da plataforma (design D8 da change anterior previa exatamente esse
tipo de encaixe), e o WorkflowTemplate `gitleaks-scan` é reutilizável
tal-como-está; falta apenas a ponta GitLab → webhook → Sensor.

## What Changes

- Nova rota de webhook no EventSource `secrets-gate` existente (endpoint
  `/mr`, mesmo serviço/porta 12000) para receber eventos do GitLab
- Novo Sensor `secrets-gate-mr` que filtra eventos `object_kind=merge_request`
  (ações `open`, `reopen`, `update`) e instancia o WorkflowTemplate
  `gitleaks-scan` no SHA do último commit do branch de origem do MR
- WorkflowTemplate `gitleaks-scan` ganha o parâmetro opcional `mr_iid`
  (rastreabilidade do run no Argo; não altera o comportamento do scan)
- Webhook registrado no projeto GitLab `root/demo-app` apontando para o
  endpoint in-cluster do EventSource, com o setting admin do GitLab que
  permite webhooks para URLs de rede local
- Bootstrap (`scripts/bootstrap.sh` e helpers) atualizado para reproduzir
  tudo do zero

Não muda: o gate do pipeline de CI (fluxo `/gate` atual segue igual), o
EventBus, o WorkflowTemplate de scan (mesmo clone autenticado + gitleaks
default sobre o histórico) e nenhum componente de plataforma.

## Capabilities

### New Capabilities

- `mr-gate-webhook`: disparo automático do security gate (Workflow gitleaks
  no Argo) a partir de webhooks do GitLab em eventos de Merge Request,
  com filtragem de ações relevantes e mapeamento do payload do GitLab para
  os parâmetros do scan

### Modified Capabilities

(nenhuma — o gate do pipeline de CI permanece com os requisitos atuais da
capability `secrets-scan-gate`)

## Impact

- **Novos artefatos**: rota no EventSource
  (`manifests/cicd/secrets-gate-eventsource.yaml`), novo Sensor
  (`manifests/cicd/secrets-gate-mr-sensor.yaml`), parâmetro `mr_iid` no
  WorkflowTemplate (`manifests/cicd/gitleaks-workflowtemplate.yaml`),
  registro do webhook + setting admin via API (script de setup, chamado
  pelo bootstrap)
- **Sem novos componentes no cluster**: reusa EventSource, EventBus,
  WorkflowTemplate e Service já existentes
- **Risco baixo**: o endpoint do webhook é in-cluster (GitLab → cicd), sem
  exposição externa; o workflow continua usando somente o token
  `read_repository` (postura fail-closed da change anterior)
- **Evolução futura (fora desta change)**: publicar o veredito de volta no
  MR (commit status/nota) — exigiria token com escopo `api` no fluxo de
  scan, contrapondo a postura de privilégio mínimo atual
