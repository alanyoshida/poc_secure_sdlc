# AGENTS.md

Guia para agentes de IA trabalhando neste repositório.

## O que é este projeto

PoC de SDLC seguro local: cluster kind contendo GitLab CE, GitLab Runner, Argo Workflows/Events, Harbor, BuildKit rootless, ArgoCD, ChartMuseum, Kyverno e um agente kanban (Kanzo + opencode). O pipeline bloqueia builds quando o gitleaks encontra secrets, assina as imagens com cosign e entrega via GitOps; o Kyverno só admite em `webapps` imagens assinadas. Ver `README.md` para a visão geral e o fluxo.

## Estado atual

**PoC implementada e validada.** Changes concluídas e arquivadas (specs
sincronizados em `openspec/specs/`):

- `setup-secure-sdlc-poc` — ambiente completo: kind + GitLab CE + Runner +
  Argo + Harbor + BuildKit rootless, pipeline com gate de secrets
- `mr-security-gate` — validação de MRs via webhook do GitLab
- `mr-llm-code-review` — code review de MR por LLM via OpenCodeReview,
  publicado inline no MR, reprovando em critical
- `kanban-agent` — cards do Kanzo viram changes OpenSpec e MRs, executados
  por um agente (opencode + OpenSpec CLI)

Changes implementadas (todas as tasks marcadas), **ainda não arquivadas**
em `openspec/changes/`:

- `gitops-deploy` — ArgoCD (app-of-apps sobre `root/gitops`) + ChartMuseum +
  webapp nginx entregue no namespace `webapps`
- `image-signing-enforcement` — estágio `sign` com cosign após o push +
  `ClusterPolicy` do Kyverno exigindo assinatura em `webapps`

O ambiente sobe do zero com `make bootstrap` (idempotente) e é destruído com
`make teardown`. Ver `README.md` para acessos, credenciais e notas de
implementação. **Novo trabalho** começa com uma change nova (proposal +
specs + design + tasks).

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

Consolidadas em `openspec/changes/archive/2026-11-09-setup-secure-sdlc-poc/design.md`
(e nos `design.md` das changes posteriores):

- Tudo dentro do kind — **docker compose eliminado**; bootstrap via Makefile
- **BuildKit rootless** para builds — Kaniko foi descontinuado (arquivado pelo Google em jun/2025), não usar
- **Harbor** como registry (não `registry:2`) — Trivy scanOnPush, robot accounts
- Gate de secrets **bloqueante antes do build**, fail-closed
- GitLab CE enxuto (sem Prometheus/Grafana/KAS)
- NodePort/port-forward na PoC; ingress-nginx é roadmap, não escopo atual
- Assinatura **incondicional após o push** (cosign, chave em `cosign-key-pair`); enforcement pelo Kyverno restrito ao namespace `webapps`
- Deploy apenas via GitOps (ArgoCD lendo `root/gitops`), sem `kubectl apply` manual de aplicações

## Convenções

- Artefatos OpenSpec e documentação em **português (pt-BR)**; mensagens de commit em português
- Nomes de changes e capabilities em kebab-case inglês (ex.: `setup-secure-sdlc-poc`, `secrets-scan-gate`)
- Branch principal: `main`

## Ao implementar

- Toda task concluída deve ter sua verificação executada (cada task em `tasks.md` declara como verificar)
- Credenciais e tokens sempre em Secrets do Kubernetes ou variáveis de CI mascaradas — nunca em código, manifests commitados ou logs
- Não introduzir componentes fora do cluster kind sem atualizar o design antes
