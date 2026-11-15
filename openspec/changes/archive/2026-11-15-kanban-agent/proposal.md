# Proposal

## Why

O SDLC da PoC ainda depende de um humano executando cada etapa manualmente:
rodar `/opsx:propose` quando surge uma ideia, rodar `/opsx:apply`, abrir o MR,
arquivar a change. Sobrou disciplina mecânica onde deveria haver só julgamento.
A ideia: um **agente autônomo** (opencode) ligado a um kanban
([Kanzo](https://github.com/emanuele-em/kanzo) — MCP server + CLI + board num
binário Rust de 4.7 MB, feito para "humans and agents") que executa o
trabalho mecânico do OpenSpec, mantendo o humano nos pontos de controle:
criar o card, aprovar a proposta, mergeiar o MR.

## What Changes

- **Kanzo no cluster**: Deployment (1 réplica, binário + PVC para o SQLite),
  board acessível via NodePort; MCP HTTP do Kanzo (`:4242/mcp`) como
  interface do agente
- **Agente no cluster**: pod com loop de polling (30s) + `opencode run` +
  CLI openspec + git; estado do fluxo vive no board e no git, o pod é
  stateless
- **Máquina de estados card ↔ OpenSpec** (colunas como papéis, tags de
  desambiguação):
  `todo` (requisição) → propose + comentário no card → `review` (aguardando
  `/aprovado`) → `doing` (openspec apply + branch `card/<id>` + MR) →
  `review` (MR sob análise: gate gitleaks + LLM review, automáticos) →
  humano mergeia → `done` (openspec archive + commit direto na main,
  docs-only)
- **Vínculo projeto ↔ repo nativo do Kanzo** (`link_repo`/`list_projects`
  via MCP, semeados com a URL interna do GitLab) — cards herdam o repo do
  projeto; múltiplos projetos = múltiplos repos no mesmo board
- **Workspace repo semeado**: `root/agent-workspace` criado pelo bootstrap
  (openspec inicializado, skills `.opencode/`, webhook de MR registrado)
- **Falha escalada**: erro em propose/apply move o card de volta ao backlog
  com tag `falhou:<motivo>` (sem loop infinito; humano decide)
- **Credenciais segregadas**: PAT dedicado do agente (api +
  write_repository); modelo do opencode = o mesmo flash do `.env`
  (OpenRouter)
- Bootstrap atualizado para provisionar tudo; v1 sequencial (um card por
  vez)

Não muda: os gates existentes (gitleaks bloqueante no pipeline de CI,
webhook de MR com gate + LLM review), nenhuma capability já especificada.

## Capabilities

### New Capabilities

- `kanban-agent`: agente autônomo que traduz o ciclo de vida de cards do
  Kanzo em mudanças OpenSpec (propose → aprovação por comentário → apply →
  MR → merge → archive), executado em pod no cluster com opencode, e que
  escala falhas ao humano pelo próprio board

### Modified Capabilities

(nenhuma)

## Impact

- **Novos artefatos**: manifest do Kanzo (`manifests/cicd/kanzo.yaml`),
  manifest + loop do agente (`manifests/cicd/kanban-agent.yaml`,
  `scripts/kanban-agent-loop.sh`), seed do workspace
  (`scripts/agent-workspace-setup.sh`)
- **Novas credenciais**: PAT `kanban-agent` (api + write_repository) via
  rails, Secret no cluster
- **Dependência externa nova**: binário do Kanzo (GitHub Releases/crates.io)
  e imagem do opencode no pod
- **Riscos aceitos na v1**: modelo flash escreve specs/código (propensa a
  imprecisão — mitigado pela aprovação da proposta e pelos gates no MR);
  processamento sequencial; sem auto-correção do agente no MR (humano
  intervém em critical)
