# Spec Delta

## Purpose

Provisionamento reproduzível de toda a plataforma local da PoC: um cluster kind contendo GitLab CE, GitLab Runner, Argo Workflows/Events, Harbor e BuildKit, instalados de forma automatizada e acessíveis a partir da máquina host.

## ADDED Requirements

### Requirement: Provisionamento do cluster via comando único

O sistema SHALL prover um comando de bootstrap único (Makefile/script) que cria o cluster kind e instala todos os componentes da plataforma sem intervenção manual intermediária.

#### Scenario: Bootstrap do zero

- **WHEN** o usuário executa o comando de bootstrap numa máquina com Docker, kind, kubectl e helm instalados
- **THEN** ao final o cluster kind está rodando com GitLab CE, GitLab Runner, Argo Workflows, Argo Events, Harbor e buildkitd saudáveis

#### Scenario: Bootstrap idempotente

- **WHEN** o usuário executa o comando de bootstrap sobre um ambiente já provisionado
- **THEN** o comando detecta os componentes existentes e não quebra nem duplica a instalação

### Requirement: Teardown do ambiente

O sistema SHALL prover um comando que remove completamente o ambiente (cluster kind e recursos associados).

#### Scenario: Teardown completo

- **WHEN** o usuário executa o comando de teardown
- **THEN** o cluster kind é destruído e não restam containers ou redes do ambiente no Docker do host

### Requirement: Instalação enxuta do GitLab

O GitLab CE SHALL ser instalado sem Prometheus, Grafana e KAS, com réplicas mínimas, de forma a reduzir consumo de recursos e tempo de boot.

#### Scenario: Componentes desabilitados

- **WHEN** o bootstrap instala o GitLab CE
- **THEN** os pods de Prometheus, Grafana e KAS não existem no namespace do GitLab e o webservice responde com status saudável

### Requirement: Acesso do host via NodePort ou port-forward

Os serviços GitLab, Harbor e Argo Workflows SHALL ser acessíveis a partir do host via NodePort ou `kubectl port-forward`, sem dependência de ingress controller.

#### Scenario: Acesso ao GitLab pelo navegador

- **WHEN** o usuário acessa a porta exposta do GitLab a partir do navegador do host
- **THEN** a tela de login do GitLab é exibida

#### Scenario: Acesso à UI do Argo

- **WHEN** o usuário executa o port-forward documentado para o Argo Workflows
- **THEN** a UI do Argo responde no endereço local informado
