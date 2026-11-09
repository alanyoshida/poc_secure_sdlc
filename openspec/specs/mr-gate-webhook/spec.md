# mr-gate-webhook Specification

## Purpose

Validação automática de Merge Requests pelo security gate: webhooks do
GitLab em eventos de MR disparam o Workflow gitleaks no Argo, permitindo que
o revisor acompanhe o veredito do scan do código proposto sem depender do
pipeline da branch.

## Requirements

### Requirement: Registro do webhook de MR no GitLab

O projeto GitLab da aplicação SHALL ter um webhook registrado para eventos
de Merge Request, apontando para o endpoint de webhook do Argo Events, e o
GitLab SHALL permitir o envio para URLs de rede local (endpoint in-cluster).

#### Scenario: MR aberto dispara o webhook

- **WHEN** um Merge Request é aberto, reaberto ou atualizado no projeto
- **THEN** o GitLab envia o payload do evento ao endpoint do Argo Events

#### Scenario: Outros eventos não disparam

- **WHEN** o GitLab emite eventos de MR que não são abertura/reabertura/
  atualização (ex.: merge, close, approval)
- **THEN** nenhum Workflow de scan é criado

### Requirement: Disparo do scan a partir do payload do MR

O sistema SHALL transformar o payload do webhook em um Workflow gitleaks
escaneando o branch de origem do MR, sem intervenção manual.

#### Scenario: Payload mapeado para o scan

- **WHEN** o webhook de MR é recebido pelo Argo Events
- **THEN** um Workflow é criado com o SHA do último commit do branch de
  origem do MR e com a URL de clone interna do projeto

#### Scenario: Run rastreável ao MR

- **WHEN** o Workflow é criado a partir de um MR
- **THEN** os parâmetros do Workflow identificam o MR que o originou

### Requirement: Veredito do scan do MR

O scan do MR SHALL aplicar as mesmas regras do gate de secrets (gitleaks
default sobre o histórico do branch de origem), falhando se encontrar
secrets.

#### Scenario: Branch de origem limpo

- **WHEN** o gitleaks não encontra secrets no branch de origem do MR
- **THEN** o Workflow conclui com sucesso

#### Scenario: Branch de origem com secret

- **WHEN** o gitleaks encontra secrets no branch de origem do MR
- **THEN** o Workflow falha

### Requirement: Reprodução do setup via bootstrap

O webhook, o setting de rede local e os recursos da Argo (rota de
EventSource, Sensor, WorkflowTemplate) SHALL ser criados pelo bootstrap
idempotente da plataforma.

#### Scenario: Bootstrap do zero reproduz o fluxo

- **WHEN** `make bootstrap` roda num ambiente sem os recursos
- **THEN** o webhook do MR e o fluxo de validação ficam funcionando sem
  passos manuais
