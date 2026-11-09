# container-build-pipeline Specification

## Purpose

Build de imagens de container a partir do GitLab CI usando BuildKit rootless dentro do cluster — sem Docker-in-Docker e sem containers privilegiados — com push das imagens no Harbor, executando somente após a aprovação do gate de secrets.

## Requirements

### Requirement: Build sem privilégios via BuildKit remoto

O job de build SHALL executar como pod não privilegiado no cluster, delegando o build a um daemon BuildKit rootless acessível via Service interno.

#### Scenario: Build remoto bem-sucedido

- **WHEN** o job de build envia o contexto e o Dockerfile ao buildkitd via cliente buildx com driver remoto
- **THEN** a imagem é construída pelo daemon sem que o pod do job possua privilégios ou acesso a socket de container runtime

#### Scenario: Job sem privilégio

- **WHEN** o pod do job de build é inspecionado
- **THEN** seu securityContext não é privilegiado e não há montagem de socket do container runtime

### Requirement: Push da imagem no Harbor

Após o build, a imagem SHALL ser enviada ao Harbor dentro do cluster, tagueada com identificação do commit do pipeline.

#### Scenario: Push após build

- **WHEN** o build conclui com sucesso
- **THEN** a imagem fica disponível no projeto correspondente do Harbor com tag derivada do SHA do commit

#### Scenario: Imagem puxável pelo cluster

- **WHEN** a imagem foi publicada no Harbor
- **THEN** um pod no cluster consegue ser criado a partir dessa imagem

### Requirement: Build condicionado ao gate de secrets

O job de build SHALL executar apenas quando o job de gate de secrets tiver concluído com sucesso.

#### Scenario: Gate aprovado

- **WHEN** o job de gate de secrets conclui com sucesso
- **THEN** o job de build é iniciado

#### Scenario: Gate reprovado

- **WHEN** o job de gate de secrets falha
- **THEN** o job de build não é executado e nenhuma imagem nova aparece no Harbor

### Requirement: Cache de build persistente

O daemon BuildKit SHALL manter cache de camadas em volume persistente, de forma que builds recorrentes do mesmo projeto sejam significativamente mais rápidos que o build inicial.

#### Scenario: Cache quente

- **WHEN** um segundo build do mesmo projeto é executado sem alteração nas dependências
- **THEN** as camadas cacheadas são reutilizadas e o build conclui em tempo substancialmente menor que o primeiro build
