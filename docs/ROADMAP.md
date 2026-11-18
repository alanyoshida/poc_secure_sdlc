# Roadmap pós-PoC

Evoluções planejadas para a PoC de SDLC seguro, fora do escopo da change
atual (ver `openspec/changes/archive/2026-11-09-setup-secure-sdlc-poc/design.md`,
decisões D7 e D8).

## 1. Assinatura de imagens com cosign — IMPLEMENTADO

Ver change `image-signing-enforcement` (specs em
`openspec/changes/image-signing-enforcement/specs/`, sincronizados para
`openspec/specs/` quando a change for arquivada). A versão implementada
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

Hoje: GitLab, Harbor, ArgoCD (30005) e Argo Workflows (30006) via
NodePort; Kanzo via `kubectl port-forward` (valida o header Host). Evolução:

- Instalar `ingress-nginx` no bootstrap (chart oficial, `kind` roteia via
  `extraPortMappings` 80/443 no kind.yaml)
- Entradas: `gitlab.local`, `harbor.local`, `argo.local`, `argocd.local`,
  `kanzo.local` em `/etc/hosts`
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
- **Rotação automática dos PATs** (`gitlab-admin-token`, `gitlab-repo-read`,
  `gitlab-mr-poster`, `kanban-agent-token`, `gitops-writer-token` hoje
  vencem em 30 dias e são recriados a cada bootstrap)
- **Cache de charts e imagens**: proxy de registry (ex.: Harbor como
  pull-through) para reduzir dependência de internet no bootstrap
- **GitOps do próprio ambiente**: o ArgoCD já entrega as aplicações
  (`root/gitops`); falta gerir os componentes da plataforma por ele em vez
  do `bootstrap.sh`, e ter pipelines para o próprio repositório de
  plataforma
