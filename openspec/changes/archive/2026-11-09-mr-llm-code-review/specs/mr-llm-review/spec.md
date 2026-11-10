# Spec Delta

## Purpose

Code review automático de Merge Requests por LLM (OpenCodeReview), disparado
pelo mesmo webhook do security gate: o diff do MR (merge-base com a main) é
revisado pela LLM configurada pelo usuário e o resultado é publicado como
discussões inline no MR, com bloqueio apenas em severidade critical.

## ADDED Requirements

### Requirement: Disparo paralelo ao security gate

O mesmo evento de Merge Request que dispara o security gate SHALL disparar
também o Workflow de code review, com o branch de origem e o identificador
do projeto extraídos do payload.

#### Scenario: MR aberto dispara os dois fluxos

- **WHEN** um MR é aberto, reaberto ou atualizado
- **THEN** além do Workflow de gitleaks, um Workflow de code review é criado
  com o branch de origem e o id do projeto do MR

#### Scenario: Eventos irrelevantes não disparam review

- **WHEN** o webhook recebe eventos que não são de abertura/reabertura/
  atualização de MR
- **THEN** nenhum Workflow de code review é criado

### Requirement: Review do diff do MR pela LLM

O Workflow SHALL executar o OpenCodeReview sobre o diff do MR (merge-base
entre a branch de origem e a main), usando o LLM configurado em Secret do
Kubernetes, sem credenciais em código ou logs.

#### Scenario: Review executado com LLM configurado

- **WHEN** o Secret do LLM existe com endpoint, chave e modelo
- **THEN** o review roda sobre o diff do MR e gera resultado estruturado

#### Scenario: LLM não configurado

- **WHEN** o Secret do LLM não existe ou está incompleto
- **THEN** o Workflow falha com mensagem clara indicando a configuração
  ausente

### Requirement: Publicação inline no MR

O resultado do review SHALL ser publicado no MR como discussões do GitLab
(comentários inline por linha do diff quando mapeável e nota resumo para o
resto), usando token dedicado de escopo api distinto do token de clone.

#### Scenario: Discussões publicadas no MR

- **WHEN** o review conclui com achados
- **THEN** o MR recebe as discussões inline e a nota resumo do review

#### Scenario: Token de publicação dedicado

- **WHEN** o fluxo publica o review
- **THEN** usa o PAT dedicado de escopo api (não o token de clone nem o
  token admin)

### Requirement: Política de bloqueio por severidade

O Workflow SHALL falhar apenas quando o review reportar achado de
severidade critical; achados de outras severidades são consultivos e não
afetam o resultado do Workflow.

#### Scenario: Achado critical falha o review

- **WHEN** o review reporta ao menos um achado critical
- **THEN** o Workflow conclui Failed

#### Scenario: Achados não-critical não bloqueiam

- **WHEN** o review reporta apenas achados de severidade abaixo de critical
- **THEN** o Workflow conclui Succeeded, independentemente da quantidade

### Requirement: Bootstrap do fluxo de review

O bootstrap SHALL criar o PAT de publicação dedicado e aplicar os recursos
da Argo (trigger e WorkflowTemplate); o Secret do LLM SHALL ser fornecido
pelo usuário e o bootstrap SHALL reportar sua ausência sem inventar
credenciais.

#### Scenario: Bootstrap prepara tudo exceto a chave do LLM

- **WHEN** `make bootstrap` roda
- **THEN** o PAT de publicação, o trigger e o WorkflowTemplate existem, e a
  ausência do Secret do LLM é reportada como ação pendente do usuário
