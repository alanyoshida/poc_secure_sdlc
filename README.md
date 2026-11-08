# PoC: Secure SDLC Local

Prova de conceito de um **SDLC seguro de ponta a ponta** rodando inteiramente num cluster Kubernetes local (kind): do push do código até uma imagem de container escaneada, com gate bloqueante de secrets antes do build.

## O fluxo

```
push --> GitLab CI --> security-gate --> webhook --> Argo Events --> Workflow gitleaks
                          | aprovado                     | reprovado: pipeline morre
                          v
                       buildx --> BuildKit (rootless) --> push no Harbor
                                                                |
                                                          Trivy scan (auto)
```

A narrativa de segurança em camadas:

- **Secrets no código** — gitleaks como gate bloqueante antes de qualquer build (fail-closed)
- **Build sem privilégios** — BuildKit rootless, sem Docker-in-Docker (Kaniko foi descontinuado pelo Google em jun/2025)
- **Vulnerabilidades no artefato** — Trivy embutido no Harbor, scan automático a cada push
- **Proveniência (roadmap)** — webhook do Trivy → Argo Events → assinatura da imagem com cosign

## Stack

| Componente | Papel |
|---|---|
| kind | Cluster Kubernetes local em Docker |
| GitLab CE (enxuto) | Repositórios + CI/CD |
| GitLab Runner | Executor de jobs como pods (kubernetes executor) |
| Argo Workflows + Events | Workflows disparados por webhook (gate de segurança) |
| Gitleaks | Scan de secrets no repositório |
| BuildKit (rootless) | Build de imagens sem privilégios, com cache persistente |
| Harbor | Registry com RBAC + Trivy (scan de vulnerabilidades) |
| Helm | Instalação dos componentes |
| Makefile | Bootstrap/teardown do ambiente |

## Status

Fase de **planejamento** — a implementação ainda não começou. Os artefatos de planejamento estão em [`openspec/changes/setup-secure-sdlc-poc/`](openspec/changes/setup-secure-sdlc-poc/):

- [`proposal.md`](openspec/changes/setup-secure-sdlc-poc/proposal.md) — porquê e o quê
- [`design.md`](openspec/changes/setup-secure-sdlc-poc/design.md) — decisões técnicas (D1–D8), arquitetura, riscos
- [`specs/`](openspec/changes/setup-secure-sdlc-poc/specs/) — contratos de comportamento (4 capabilities)
- [`tasks.md`](openspec/changes/setup-secure-sdlc-poc/tasks.md) — checklist de implementação (20 tasks)

## Requisitos (quando implementado)

- Linux com ~16GB RAM livres
- Docker, kind, kubectl, helm

```bash
make bootstrap   # sobe o ambiente completo
make teardown    # destrói tudo
```

## Roadmap pós-PoC

- Assinatura de imagens com cosign (disparada pelo webhook do Trivy quando o scan passa limpo)
- Ingress-nginx + `/etc/hosts` (`gitlab.local`, `harbor.local`) no lugar de NodePort/port-forward
