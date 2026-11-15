# Proposal

## Why

Hoje qualquer imagem publicada no Harbor pode ser deployada no cluster, sem
garantia de que veio do pipeline de CI da PoC (gate de secrets + build sem
privilégios) e não foi substituída ou adulterada entre o push e o pull pelo
ArgoCD/kubelet. Assinar a imagem no build e verificar a assinatura na
admissão do pod fecha essa lacuna: só roda no cluster o que foi
efetivamente construído pelo nosso pipeline.

## What Changes

- **Assinatura da imagem no build**: novo estágio `sign` nos pipelines que
  publicam imagem (`example-app` e `example-webapp`), assinando a tag
  recém-publicada com `cosign` (chave assimétrica dedicada, guardada como
  Secret do Kubernetes) imediatamente após o push no Harbor
- **Visibilidade no Harbor**: a assinatura cosign é publicada como artefato
  OCI associado à imagem; a UI do Harbor (suporte nativo a accessories na
  versão em uso) passa a exibir a tag como assinada
- **Enforcement na admissão**: Kyverno instalado no cluster (novo
  componente) com uma `ClusterPolicy` de `verifyImages` restrita ao
  namespace `webapps`, usando a chave pública do mesmo par de chaves;
  pods com imagem não assinada (ou assinada por outra chave) são
  rejeitados na admissão
- Bootstrap atualizado para provisionar: o par de chaves cosign, o
  RBAC que permite ao job de CI ler a chave privada, a instalação do
  Kyverno e a aplicação da policy

Não muda: o gate de secrets, o build sem privilégios via BuildKit, o scan
de vulnerabilidades do Trivy no Harbor (fluxos já especificados) — a
assinatura é um passo adicional após o push, independente do resultado do
Trivy (que continua assíncrono/informativo, sem ser um gate).

## Capabilities

### New Capabilities

- `image-signing-enforcement`: assinatura de imagens com cosign no build,
  visibilidade da assinatura no Harbor e enforcement via Kyverno na
  admissão de pods no namespace `webapps`

### Modified Capabilities

(nenhuma — os requisitos de `container-build-pipeline` e
`image-registry-scanning` permanecem os mesmos; a assinatura é um
requisito novo e aditivo, não uma mudança no comportamento já
especificado de build/push/scan)

## Impact

- **Novo componente no cluster**: Kyverno (~100-200MB RAM), namespace
  próprio
- **Nova credencial**: par de chaves cosign (privada + pública), Secret no
  namespace `cicd`; RBAC (Role/RoleBinding) dando ao ServiceAccount
  `gitlab-runner-job` permissão de leitura apenas desse Secret
- **Pipelines alterados**: `example-app/.gitlab-ci.yml` e
  `example-webapp/.gitlab-ci.yml` ganham o estágio `sign`
- **Novos artefatos**: manifest do Kyverno (chart) e da `ClusterPolicy`,
  script de bootstrap para o par de chaves cosign e o RBAC
- **Risco de transição**: imagens já publicadas/deployadas antes desta
  change não estão assinadas; o rollout precisa re-publicar (novo push)
  a versão corrente de `apps/webapp` antes de a policy do Kyverno entrar
  em vigor no namespace `webapps`, para não quebrar o deploy existente
  (detalhado em design.md)
- **Risco aceito na PoC**: comunicação com o Harbor via HTTP interno
  (mesma postura já aceita para build/push/pull); a chave privada cosign
  fica em um único Secret, sem rotação automatizada
