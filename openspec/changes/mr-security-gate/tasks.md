# Tasks

## 1. Argo Events (rota + Sensor + Template)

- [ ] 1.1 Adicionar a rota `secrets-gate-mr` (endpoint `/mr`, POST, porta 12000) no EventSource `secrets-gate` e verificar que o pod do EventSource reconcilia com o Service inalterado
- [ ] 1.2 Adicionar o parâmetro opcional `mr_iid` (default vazio) ao WorkflowTemplate `gitleaks-scan` sem alterar o comportamento do scan; verificar com `argo submit` que o run aceita os dois formatos (com e sem `mr_iid`)
- [ ] 1.3 Criar o Sensor `secrets-gate-mr` (dependency no evento `secrets-gate-mr` com filtro `object_kind=merge_request` e `action in (open, reopen, update)`, trigger do WorkflowTemplate com `sha` via `dataKey body.object_attributes.last_commit.id`, `repo_url` via `dataTemplate` a partir de `body.project.path_with_namespace`, `mr_iid` via `dataKey`) e verificar que o pod do Sensor sobe Ready

## 2. GitLab (setting + webhook)

- [ ] 2.1 Habilitar o setting admin `allow_local_requests_from_web_hooks_and_integrations` via API e verificar com `GET /application/settings`
- [ ] 2.2 Registrar o webhook do projeto `root/demo-app` (eventos de merge request, URL `http://secrets-gate-eventsource-svc.cicd.svc.cluster.local:12000/mr`) de forma idempotente e verificar que o hook responde ao teste manual (payload de push não dispara scan; resposta do endpoint em "Recent deliveries")

## 3. Bootstrap e documentação

- [ ] 3.1 Incorporar setting + webhook ao setup idempotente (script chamado pelo `scripts/bootstrap.sh`, reutilizando o PAT admin do Secret) e verificar que rodar o bootstrap duas vezes não duplica o hook
- [ ] 3.2 Documentar o fluxo de MR no README (disparo, onde ver o veredito, limitação sem callback de resultado)

## 4. Verificação ponta a ponta

- [ ] 4.1 Criar branch limpo com mudança trivial, abrir MR via API e verificar: webhook entregue (Recent deliveries 200), Workflow criado com `mr_iid` e SHA do source branch, Workflow conclui Succeeded
- [ ] 4.2 Empurrar secret falso na branch do MR (ex.: webhook do Slack), atualizar o MR e verificar: Workflow falha (gitleaks exit 1, findings redacionados); eventos de merge/close do MR não disparam Workflow
- [ ] 4.3 Limpar o histórico da branch do teste (sem secrets) e verificar que um MR limpo volta a concluir Succeeded, deixando o ambiente em estado verde

## Workflow follow-up

- Arquivar a change após revisão dos artefatos e da implementação (junto com `setup-secure-sdlc-poc`).
- Verificar os specs arquivados em `openspec/specs/`.
