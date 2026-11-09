# image-registry-scanning Specification

## Purpose

Armazenamento centralizado das imagens de container no Harbor com scan automático de vulnerabilidades (Trivy) a cada push, controle de acesso por projeto e visibilidade dos resultados via interface web.

## Requirements

### Requirement: Scan automático de vulnerabilidades no push

O Harbor SHALL executar automaticamente um scan de vulnerabilidades (Trivy) em toda imagem publicada, sem ação manual.

#### Scenario: Scan após push

- **WHEN** uma imagem é publicada no Harbor pelo pipeline
- **THEN** um scan de vulnerabilidades é iniciado automaticamente e seu resultado fica associado à tag da imagem

#### Scenario: Resultado visível na UI

- **WHEN** o scan de uma imagem conclui
- **THEN** a UI do Harbor exibe o resumo de vulnerabilidades por severidade para aquela tag

### Requirement: Acesso ao registry com autenticação

O Harbor SHALL exigir autenticação para push e pull de imagens, com conta de robô dedicada para uso do pipeline de CI.

#### Scenario: Push autenticado pelo pipeline

- **WHEN** o job de build autentica no Harbor com a robot account do projeto
- **THEN** o push da imagem é aceito

#### Scenario: Push anônimo rejeitado

- **WHEN** uma tentativa de push é feita sem credenciais válidas
- **THEN** o Harbor rejeita a operação

### Requirement: Comunicação interna sem TLS no escopo da PoC

O acesso ao Harbor a partir de componentes internos do cluster (builds e pulls) SHALL ocorrer via Service interno, aceitando HTTP restrito ao tráfego que não sai do cluster.

#### Scenario: Pull interno pelo cluster

- **WHEN** um nó do cluster precisa da imagem publicada
- **THEN** o pull ocorre via endereço interno do Harbor sem que o tráfego saia do cluster

#### Scenario: UI acessível do host

- **WHEN** o usuário acessa a porta exposta do Harbor a partir do navegador do host
- **THEN** a tela de login do Harbor é exibida
