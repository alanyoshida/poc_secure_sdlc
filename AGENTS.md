# AGENTS.md

Guia para agentes de IA trabalhando neste repositório.

## O que é este projeto

PoC de SDLC seguro local: cluster kind contendo GitLab CE, GitLab Runner, Argo Workflows/Events, Harbor e BuildKit rootless, com pipeline que bloqueia builds quando o gitleaks encontra secrets. Ver `README.md` para a visão geral e o fluxo.

## Estado atual

**Fase de planejamento.** Não existe código de implementação ainda — apenas os artefatos OpenSpec da change `setup-secure-sdlc-poc`. A implementação deve seguir o checklist em `openspec/changes/setup-secure-sdlc-poc/tasks.md`.

## Workflow OpenSpec

Este repositório usa OpenSpec (schema `spec-driven`). Comandos essenciais:

```bash
openspec list                  # changes em andamento
openspec list --specs          # capabilities já especificadas
openspec status --change <nome>
openspec validate <nome>
```

- **Novo trabalho** começa com uma change (proposal + specs + design + tasks) — nunca implemente direto sem change.
- **Implementar** é o workflow de apply: seguir `tasks.md`, marcar checkboxes conforme conclui.
- **Arquivar** a change ao concluir, sincronizando os specs para `openspec/specs/`.
- Skills disponíveis nos diretórios de agentes (`.kimi-code/skills/`, `.claude/skills/`, etc.): `openspec-propose`, `openspec-explore`, `openspec-apply-change`, `openspec-archive-change`, `openspec-sync-specs`, `openspec-update-change`.

## Decisões de arquitetura (não reabrir sem discussão)

Consolidadas em `openspec/changes/setup-secure-sdlc-poc/design.md`:

- Tudo dentro do kind — **docker compose eliminado**; bootstrap via Makefile
- **BuildKit rootless** para builds — Kaniko foi descontinuado (arquivado pelo Google em jun/2025), não usar
- **Harbor** como registry (não `registry:2`) — Trivy scanOnPush, robot accounts
- Gate de secrets **bloqueante antes do build**, fail-closed
- GitLab CE enxuto (sem Prometheus/Grafana/KAS)
- NodePort/port-forward na PoC; ingress-nginx e cosign são roadmap, não escopo atual

## Convenções

- Artefatos OpenSpec e documentação em **português (pt-BR)**; mensagens de commit em português
- Nomes de changes e capabilities em kebab-case inglês (ex.: `setup-secure-sdlc-poc`, `secrets-scan-gate`)
- Branch principal: `main`

## Ao implementar

- Toda task concluída deve ter sua verificação executada (cada task em `tasks.md` declara como verificar)
- Credenciais e tokens sempre em Secrets do Kubernetes ou variáveis de CI mascaradas — nunca em código, manifests commitados ou logs
- Não introduzir componentes fora do cluster kind sem atualizar o design antes
