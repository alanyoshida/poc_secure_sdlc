# Spec Delta

## Purpose

Entrega contínua GitOps no cluster kind: o pipeline da aplicação publica o
chart Helm (com a nova imagem) no ChartMuseum e comita a subida de versão no
repositório GitOps; o ArgoCD detecta e faz o deploy no próprio cluster,
com o chart garantindo probes de liveness/readiness no nginx.

## ADDED Requirements

### Requirement: ArgoCD e ChartMuseum provisionados no cluster

O bootstrap SHALL instalar o ArgoCD (UI acessível via port-forward,
repositório GitOps registrado com credencial e ChartMuseum registrado como
helm repo) e o ChartMuseum (dados em PVC, API acessível in-cluster para
push pelo CI e consumo pelo ArgoCD).

#### Scenario: Componentes saudáveis

- **WHEN** o bootstrap conclui
- **THEN** ArgoCD e ChartMuseum estão rodando e acessíveis nos endereços
  internos documentados

#### Scenario: UI do ArgoCD

- **WHEN** o usuário abre o endereço via port-forward documentado
- **THEN** a UI do ArgoCD responde com as applications visíveis

### Requirement: Aplicação web nginx com probes

A aplicação web SHALL ser empacotada em chart Helm cujo Deployment sirva o
nginx e contenha probes de liveness e readiness HTTP apontando para o
servidor web.

#### Scenario: Pod saudável com probes

- **WHEN** o ArgoCD faz o deploy da aplicação
- **THEN** o pod do nginx fica Ready e os probes HTTP respondem no caminho
  configurado

#### Scenario: Falha de saúde reinicia

- **WHEN** o endpoint do nginx deixa de responder ao liveness probe
- **THEN** o kubelet reinicia o container

### Requirement: Pipeline publica versão no ChartMuseum

O pipeline da aplicação SHALL, após o push da imagem no Harbor, empacotar o
chart com a nova versão e a nova tag de imagem, publicá-lo no ChartMuseum e
comitar a subida de versão no repositório GitOps.

#### Scenario: Nova versão publicada

- **WHEN** o pipeline roda na main após um merge
- **THEN** uma nova versão do chart fica disponível no ChartMuseum com a
  imagem apontando para a tag do commit, e o repositório GitOps recebe o
  commit de subida de versão

### Requirement: ArgoCD detecta e deploya no kind

O ArgoCD SHALL detectar a subida de versão (commit no repositório GitOps)
e sincronizar o deploy da nova versão no próprio cluster kind, sem ação
manual.

#### Scenario: Deploy automático da nova versão

- **WHEN** o commit de subida de versão chega ao repositório GitOps
- **THEN** o ArgoCD sincroniza e o pod da aplicação passa a rodar a nova
  versão da imagem

#### Scenario: Drift revertido

- **WHEN** uma mudança manual é feita no recurso deployado no cluster
- **THEN** o ArgoCD reverte para o estado declarado no repositório GitOps

### Requirement: Provisionamento pelo bootstrap

O bootstrap SHALL criar os dois repositórios (webapp e GitOps) semeados com
os conteúdos da plataforma, o PAT dedicado do GitOps e as CI variables do
Harbor na aplicação; a ausência da chave do LLM não afeta este fluxo.

#### Scenario: Bootstrap prepara o fluxo GitOps

- **WHEN** `make bootstrap` roda
- **THEN** os repos webapp e GitOps existem semeados, o PAT existe e os
  components ArgoCD/ChartMuseum estão no ar
