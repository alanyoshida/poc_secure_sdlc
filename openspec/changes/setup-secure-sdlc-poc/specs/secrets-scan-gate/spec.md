# Spec Delta

## Purpose

Gate de segurança bloqueante no início do pipeline de CI: um scan de secrets (gitleaks) executado como Argo Workflow, disparado via webhook do Argo Events, que reprova o pipeline antes de qualquer build caso encontre secrets no repositório.

## ADDED Requirements

### Requirement: Disparo do scan via webhook no início do pipeline

O pipeline SHALL iniciar com um job de gate que chama o webhook do Argo Events informando o repositório e o commit a escanear, e aguarda o veredito antes de prosseguir.

#### Scenario: Webhook dispara workflow de scan

- **WHEN** o job de gate envia uma requisição ao endpoint webhook do Argo Events com a URL do repositório e o SHA do commit
- **THEN** um Workflow do Argo Workflows é criado para executar o scan de secrets

#### Scenario: Gate aguarda conclusão do scan

- **WHEN** o workflow de scan está em execução
- **THEN** o job de gate permanece aguardando (poll do status) até o workflow concluir ou estourar o timeout configurado

### Requirement: Bloqueio do pipeline ao encontrar secrets

Se o scan encontrar secrets no repositório, o pipeline SHALL falhar no job de gate e nenhum build ou push de imagem SHALL ocorrer.

#### Scenario: Secret detectado

- **WHEN** o gitleaks encontra ao menos um secret no repositório escaneado
- **THEN** o workflow falha, o job de gate falha e o pipeline é interrompido sem executar o job de build

#### Scenario: Repositório limpo

- **WHEN** o gitleaks não encontra nenhum secret
- **THEN** o workflow conclui com sucesso e o pipeline avança para o job de build

### Requirement: Clonagem autenticada do repositório

O workflow de scan SHALL clonar o repositório usando credenciais de leitura armazenadas como Secret do Kubernetes, sem tokens embutidos em código ou logs.

#### Scenario: Clone com credencial de Secret

- **WHEN** o workflow de scan inicia
- **THEN** ele obtém a credencial do Secret do Kubernetes e clona o repositório no commit informado pelo evento

#### Scenario: Credencial não vaza em logs

- **WHEN** o workflow de scan executa e conclui
- **THEN** os logs do workflow não contêm o token de acesso ao repositório

### Requirement: Resiliência a falha do scan

Se o workflow de scan falhar por erro de infraestrutura ou timeout, o pipeline SHALL falhar fechado (não prossegue para build).

#### Scenario: Timeout do scan

- **WHEN** o workflow de scan não conclui dentro do timeout configurado no job de gate
- **THEN** o job de gate falha e o pipeline é interrompido sem executar o build
