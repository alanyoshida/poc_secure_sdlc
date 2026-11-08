# Proposal

## Why

Queremos demonstrar localmente um SDLC seguro de ponta a ponta — do push do código até uma imagem de container escaneada — como prova de conceito para práticas de segurança em pipelines (shift-left de secrets, build sem privilégios, scan de vulnerabilidades no registry). Hoje não existe nenhum ambiente no projeto; tudo será criado do zero num cluster kind local, com máquina de sobra (46GB RAM) para comportar a stack completa.

## What Changes

- Provisionar um cluster Kubernetes local com **kind**, contendo toda a plataforma (sem docker compose):
  - **GitLab CE** (instalação enxuta: sem Prometheus, Grafana, KAS; réplicas mínimas) + **GitLab Runner** com kubernetes executor
  - **Argo Workflows** e **Argo Events** (EventSource webhook + Sensor)
  - **Harbor** como registry, com Trivy embutido para scan de vulnerabilidades no push
  - **BuildKit** rodando como daemon rootless (`buildkitd` + PVC de cache)
- Criar um pipeline GitLab CI de exemplo com gate bloqueante de segurança:
  1. Job `security-gate` chama o webhook do Argo Events, que dispara um Workflow com **gitleaks** escaneando o repositório; o job faz poll do resultado via API do Kubernetes (ServiceAccount do próprio pod) e falha o pipeline se secrets forem encontrados
  2. Somente com o gate aprovado, o job de build usa `docker buildx --driver remote` contra o buildkitd e faz push da imagem no Harbor
  3. No push, o Trivy do Harbor escaneia a imagem automaticamente
- Bootstrap via Makefile/script (`kind create cluster` + helm installs) — docker compose eliminado da arquitetura
- Acesso do host via NodePort/port-forward na PoC (ingress-nginx fica como evolução futura)
- Roadmap documentado (fora do escopo desta change): webhook do Trivy → Argo Events → workflow que assina a imagem com **cosign**; ingress-nginx

## Capabilities

### New Capabilities

- `platform-bootstrap`: provisionamento reproduzível do cluster kind e de todos os componentes da plataforma (GitLab, Runner, Argo Workflows/Events, Harbor, BuildKit) via scripts e helm, incluindo acesso do host via NodePort/port-forward
- `secrets-scan-gate`: gate bloqueante de segurança no início do pipeline — webhook no Argo Events dispara workflow gitleaks que escaneia o repositório e reprova o pipeline antes de qualquer build
- `container-build-pipeline`: build de imagens via BuildKit rootless (sem DinD/privilégios) a partir do GitLab CI e push no Harbor, executando apenas após o gate de secrets
- `image-registry-scanning`: armazenamento de imagens no Harbor com scan automático de vulnerabilidades (Trivy) a cada push e RBAC básico de acesso

### Modified Capabilities

(nenhuma — greenfield, não há specs existentes)

## Impact

- **Novo código/artefatos**: kind config, Makefile/scripts de bootstrap, values de charts Helm (GitLab, Harbor, Argo), manifests de EventSource/Sensor/WorkflowTemplate do Argo, `.gitlab-ci.yml` de exemplo, repositório de aplicação exemplo com Dockerfile
- **Dependências externas**: Docker, kind, kubectl, helm na máquina do usuário; charts `gitlab/gitlab`, `goharbor/harbor`, `argo` e imagem `moby/buildkit` rootless
- **Recursos**: ~10-14GB RAM para a stack completa dentro do kind (máquina alvo tem 46GB)
- **Nota de stack**: Kaniko foi considerado e descartado por ter sido arquivado/descontinuado pelo Google (jun/2025); BuildKit rootless é o substituto. Registry `registry:2` standalone foi descartado em favor do Harbor (Trivy embutido, RBAC, webhooks)
