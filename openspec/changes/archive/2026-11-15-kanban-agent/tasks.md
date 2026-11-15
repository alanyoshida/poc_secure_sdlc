# Tasks

## 1. Kanzo no cluster

- [x] 1.1 Criar `manifests/cicd/kanzo.yaml`: Deployment (initContainer instala o binário fixado do GitHub Releases, PVC para `~/kanzo` SQLite, 1 réplica) + Service ClusterIP (board/MCP interno) + Service NodePort (board do humano); verificar pod Ready e board respondendo na NodePort
- [x] 1.2 Habilitar a coluna Backlog e criar o projeto inicial via MCP (`http://kanzo.cicd.svc:4242/mcp`) ou CLI, vinculado ao workspace repo com `link_repo` (URL interna); verificar via `list_projects`

## 2. Credenciais e workspace

- [x] 2.1 Criar o PAT dedicado `kanban-agent` (api + write_repository) via rails e o Secret correspondente no cluster, sem imprimir o valor; verificar validade via API
- [x] 2.2 Criar `scripts/agent-workspace-setup.sh` (idempotente, chamado pelo bootstrap): cria o projeto GitLab `root/agent-workspace`, semeia `openspec` inicializado + adaptadores `.opencode/` copiados do repositório de plataforma + README, registra o webhook de MR e vincula o repo ao projeto do board via `link_repo`; verificar dupla execução sem duplicar

## 3. Agente (pod + loop)

- [x] 3.1 Criar o loop `scripts/kanban-agent-loop.sh`: poll de 30s no MCP/CLI do Kanzo; transições determinísticas (todo com novo card -> fase propose; review + proposta-publicada + `/aprovado` -> fase apply; review + mr-aberto + MR merged -> fase archive) com trava de idempotência por card; falhas comentam o erro e movem para backlog com `falhou:<motivo>`
- [x] 3.2 Criar o manifest do agente `manifests/cicd/kanban-agent.yaml`: pod/Deployment com o loop, opencode, openspec CLI e git instalados, PAT e chave do LLM via Secrets (aviso claro se ausentes), MCP do Kanzo configurado no opencode, timeouts por fase (propose 5min, apply 30min); verificar pod Running
- [x] 3.3 Escrever os prompts por fase (propose: card -> `/opsx:propose` + comentário de resumo + mover; apply: `/aprovado` -> `/opsx:apply` + branch/MR + url no card + mover; archive: merged -> `/opsx:archive` + commit na main + mover) versionados junto ao loop

## 4. Bootstrap e documentação

- [x] 4.1 Incorporar ao bootstrap: apply dos manifests (Kanzo, agente), criação do PAT/Secrets, execução do seed do workspace e aviso explícito se a chave do LLM estiver ausente; verificar dupla execução sem duplicar nem reprocessar
- [x] 4.2 Documentar no README: arquitetura do agente, máquina de estados card↔OpenSpec, como criar cards, aprovar (`/aprovado`) e acompanhar; procedimento para novo projeto/repo; limitações da v1 (sequencial, critical escalado ao humano)

## 5. Verificação ponta a ponta

- [x] 5.1 Fase propose: criar card em todo e verificar change criada, resumo comentado no card, tag proposta-publicada e card em review; card de teste ambíguo (texto vazio) escalado ao backlog com `falhou:<motivo>`
- [x] 5.2 Fase apply: comentar `/aprovado` e verificar card em doing, implementação na branch `card/<id>-<slug>`, MR aberto passando pelo gate + LLM review, card.url apontando para o MR e card em review; segundo `/aprovado` não reexecuta
- [x] 5.3 Fase archive: merge do MR pelo humano e verificar card em done, change arquivada e commit de archive direto na main (docs-only), workspace atualizado
- [x] 5.4 Falha no meio: forçar erro de apply (card com requisito impossível) e verificar volta ao backlog com `falhou:<motivo>` e sem MR órfão

## Workflow follow-up

- Arquivar a change após revisão e implementação (spec sincroniza para `openspec/specs/`).
- Fase 2 (fora do escopo): auto-correção do agente nos comentários de review do próprio MR; processamento paralelo.
