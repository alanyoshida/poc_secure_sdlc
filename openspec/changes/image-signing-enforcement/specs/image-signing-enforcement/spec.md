# Spec Delta

## Purpose

Garantir que só rodam no cluster, no namespace `webapps`, imagens
assinadas pelo próprio pipeline de CI: a imagem é assinada com cosign
imediatamente após o push no Harbor, a assinatura fica visível na UI do
Harbor, e o Kyverno rejeita na admissão qualquer pod cuja imagem não
verifique contra a chave pública esperada.

## ADDED Requirements

### Requirement: Assinatura da imagem após o push

O pipeline SHALL assinar com cosign, usando uma chave dedicada, toda
imagem publicada no Harbor pelos jobs de build (`apps/demo-app` e
`apps/webapp`), imediatamente após o push, antes de qualquer estágio
subsequente que dependa da imagem.

#### Scenario: Imagem assinada após o push

- **WHEN** o job de build publica a imagem no Harbor
- **THEN** o estágio de assinatura executa e a assinatura cosign da tag
  publicada fica disponível no Harbor

#### Scenario: Falha na assinatura reprova o pipeline

- **WHEN** o estágio de assinatura não consegue assinar a imagem
  publicada (erro de acesso à chave ou ao registry)
- **THEN** o pipeline falha e os estágios seguintes que dependem da
  imagem assinada não executam

### Requirement: Assinatura visível no Harbor

A UI do Harbor SHALL exibir a assinatura cosign associada à tag da imagem
como um artefato/accessory vinculado, sem configuração adicional além da
versão do Harbor já em uso.

#### Scenario: Accessory visível na tag

- **WHEN** uma imagem assinada é inspecionada na UI do Harbor
- **THEN** a assinatura cosign aparece listada como accessory daquela tag

### Requirement: Admissão de pods restrita a imagens assinadas no namespace webapps

O cluster SHALL rejeitar, via política do Kyverno restrita ao namespace
`webapps`, a criação de qualquer pod cuja imagem não possua assinatura
cosign válida contra a chave pública provisionada; a verificação não se
aplica a outros namespaces do cluster.

#### Scenario: Pod com imagem assinada é admitido

- **WHEN** um pod é criado no namespace `webapps` referenciando uma
  imagem assinada com a chave esperada
- **THEN** o Kyverno admite o pod normalmente

#### Scenario: Pod com imagem não assinada é rejeitado

- **WHEN** um pod é criado no namespace `webapps` referenciando uma
  imagem sem assinatura válida (não assinada, ou assinada por outra
  chave)
- **THEN** o Kyverno rejeita a criação do pod e o motivo da rejeição é
  visível no evento do objeto que tentou criá-lo

#### Scenario: Outros namespaces não são afetados

- **WHEN** um pod é criado em um namespace diferente de `webapps`
  (por exemplo `cicd`, `gitlab`, `harbor`, `argocd`)
- **THEN** a policy de verificação de assinatura não se aplica e a
  criação do pod segue sem a verificação do Kyverno

### Requirement: Provisionamento pelo bootstrap

O bootstrap SHALL provisionar de forma idempotente: o par de chaves
cosign (Secret no namespace `cicd`), o RBAC que permite ao
ServiceAccount dos jobs de CI ler apenas esse Secret, a instalação do
Kyverno no cluster e a aplicação da `ClusterPolicy` de verificação de
assinatura.

#### Scenario: Bootstrap prepara a assinatura e o enforcement

- **WHEN** `make bootstrap` roda
- **THEN** o par de chaves cosign existe, o RBAC de leitura da chave
  privada existe, o Kyverno está no ar e a policy de verificação está
  aplicada no cluster
