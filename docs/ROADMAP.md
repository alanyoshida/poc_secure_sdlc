# Roadmap pós-PoC

Evoluções planejadas para a PoC de SDLC seguro, fora do escopo da change
atual (ver `openspec/changes/setup-secure-sdlc-poc/design.md`, decisões D7 e D8).

## 1. Assinatura de imagens com cosign — IMPLEMENTADO

Ver change `image-signing-enforcement` (specs em
`openspec/specs/image-signing-enforcement/`). A versão implementada
difere da ideia original deste roadmap: a assinatura acontece
**incondicionalmente após o push** (estágio `sign` no próprio pipeline),
não disparada por webhook do Harbor condicionado ao resultado do Trivy
limpo. Kyverno faz o enforcement, restrito ao namespace `webapps`. Ver
README (seção "Assinatura de imagens") para o funcionamento atual.

Evolução ainda não feita, registrada aqui: condicionar a assinatura ao
resultado do scan do Trivy (webhook do Harbor → Argo Events → só assina
se `Total == 0` vulnerabilidades) — hoje o Trivy continua informativo,
sem bloquear nada.

O desenho já prevê o encaixe: o Argo Events é o barramento de eventos da
plataforma; o novo fluxo apenas adiciona um EventSource + Sensor + Template.

## 2. Ingress-nginx no lugar de NodePort/port-forward

Hoje: GitLab e Harbor via NodePort; Argo UI via `kubectl port-forward`
(design D7). Evolução:

- Instalar `ingress-nginx` no bootstrap (chart oficial, `kind` roteia via
  `extraPortMappings` 80/443 no kind.yaml)
- Entradas: `gitlab.local`, `harbor.local`, `argo.local` em `/etc/hosts`
  do host
- TLS: cert-manager com issuer local (self-signed/CA local) — a PoC atual
  roda Harbor em HTTP restrito ao cluster; com ingress, avaliar terminação
  TLS no ingress mantendo o tráfego interno em HTTP
- O `externalURL` do Harbor passa a ser `http://harbor.local`; o realm de
  token do registry precisa acompanhar (avaliar manter o FQDN interno para
  o data path de push/pull e usar o ingress só para a UI/API)

## 3. Outras evoluções naturais

- **Política de severidades no gate de imagem**: hoje o scan do Trivy é
  informativo; o roadmap pode bloquear o deploy de imagens com Critical/High
  (webhook → Argo Events → workflow que aplica label/quarantine no projeto)
- **Rotação automática dos PATs** (`gitlab-admin-token`, `gitlab-repo-read`
  hoje vencem em 30 dias e são recriados a cada bootstrap)
- **Cache de charts e imagens**: proxy de registry (ex.: Harbor como
  pull-through) para reduzir dependência de internet no bootstrap
- **GitOps do próprio ambiente** (Argo CD) e pipelines para o próprio
  repositório de plataforma
