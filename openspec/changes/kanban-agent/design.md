# Design

## Context

Todas as peças existem e foram validadas nas changes anteriores: plataforma
(kind + GitLab + gates no MR via webhook), disciplina OpenSpec com
adaptadores nativos para opencode (`.opencode/skills/` + `/opsx:*`) e o
Kanzo — kanban "for humans and agents" com MCP HTTP (`:4242/mcp`), CLI e
vinculo nativo projeto↔repo (`link_repo`/`list_projects`). Decisões tomadas
na exploração: colunas como papéis; `/aprovado` literal; agente em pod no
cluster; critical no MR → humano intervém (v1); repo dedicado
`root/agent-workspace`; board em NodePort; mapeamento nativo (sem config
externa); 1 board com N projetos; modelo do agente = o mesmo flash do
`.env`; falha volta ao backlog; archive com commit direto na main
(docs-only).

## Goals / Non-Goals

**Goals:**
- Card em todo vira change proposta, comentada no card; `/aprovado` vira
  apply; MR passa pelos gates automáticos; merge vira archive
- Humano com três portas de controle: criar o card, `/aprovado`, merge
- Bootstrap reproduz tudo; agente stateless (estado no board + git)

**Non-Goals:**
- Auto-correção do agente nos comentários de review do próprio MR (fase 2)
- Processamento paralelo de cards (v1 sequencial, um agente)
- Notificações externas (Slack/e-mail); UI própria (a do Kanzo basta)
- Boards múltiplos/instâncias separadas (1 board, N projetos)

## Decisions

### D1: Colunas como papéis, tags desambiguando

`backlog` (nativo, agentes ignoram) → `todo` (requisição) → `review`
(aguardando `/aprovado`) → `doing` (apply) → `review` (MR) → `done` (arquivo).
As duas passagens por review são distinguidas por tags no card
(`proposta-publicada` antes do MR, `mr-aberto` depois). Justificativa: o
filtro nativo do Kanzo (`project:`, `tag:`, `status:`) resolve o loop sem
colunas extras, e a coluna review tem semântica nativa de agents
("comment how to resume its session").

### D2: Loop shell fora do opencode, opencode por fase

O loop é um script shell (pod, poll 30s) que consulta o MCP/CLI do Kanzo e
invoca `opencode run "<prompt da fase>"` por transição — cada fase é uma
sessão opencode curta e auditável, não um agente permanente. O loop nunca
delega decisões de estado ao LLM: transições são determinísticas (tags,
comentários, estado do MR via API). Prompts por fase instruem o opencode a
usar as skills `/opsx:*` e as ferramentas MCP do Kanzo (comentar, mover,
setar url).

### D3: Kanzo como Deployment com PVC + NodePort

Uma réplica, binário do GitHub Releases instalado em initContainer (imagem
base mínima), SQLite no PVC, Service NodePort para o board do humano e o
MCP HTTP (`:4242/mcp`) exposto in-cluster ao pod do agente via Service
ClusterIP (dois Services sobre o mesmo Deployment). O pod do agente usa o
MCP HTTP (não stdio) porque roda em outro pod.

### D4: Vínculo projeto↔repo nativo, semeado com URL interna

O bootstrap semeia, via MCP: criação do projeto no board + `link_repo` com a
URL **interna** do GitLab (`http://gitlab-webservice-default.gitlab.svc:8181/<grupo>/<repo>.git`)
— o clone do agente no cluster resolve direto. O loop descobre a URL de
clone com `list_projects` (retorna projeto + repos). Sem ConfigMap nem
repos.yaml: o Kanzo é a fonte única, e o humano gerencia vínculos pela UI.

### D5: Workspace repo semeado com disciplina OpenSpec

`root/agent-workspace` é criado pelo bootstrap com: `openspec` inicializado
(estrutura de changes/specs), skills/adaptadores `.opencode/` copiados do
repositório de plataforma, webhook de MR registrado (gate + LLM review
disparam nos MRs do agente) e projeto correspondente no board vinculado via
`link_repo`. A main protegida (default do GitLab). Novos projetos/repos
seguem o procedimento documentado no README (repo no GitLab + `link_repo`),
sem tocar no agente.

### D6: Credenciais e modelo

PAT dedicado `kanban-agent` (escopos api + write_repository, criado via
rails como os demais, Secret no cluster) — push de branch, MR, leitura de
comentários; sem escopo admin. O opencode usa o modelo flash do `.env`
via OpenRouter (mesma chave, Secret próprio `agent-llm` reutilizando a
leitura do `.env` no bootstrap). Tokens nunca em código ou logs.

### D7: Falha escalada ao backlog

Erro em propose/apply (timeout, change inválida, push falha): o agente
comenta o erro no card, move o card para o backlog com tag
`falhou:<motivo>` e encerra a sessão. Sem reprocessamento automático — o
humano decide quando re-priorizar. Timeouts por fase (propose 5min, apply
30min) viram o mesmo tratamento. `/aprovado` já consumido ganha trava
(idempotência: o loop marca processado antes de aplicar).

### D8: Commit direto na main apenas para archive

O código do card vai sempre pela branch `card/<id>-<slug>` e MR (gates +
merge humano). Após o merge detectado (API do GitLab: MR state=merged), o
archive produz mudança **docs-only** (moves em `openspec/changes/archive/` +
spec sincronizado) — commitada e pushada direto na main. Princípio
explícito: código nunca vai direto; documentação de spec arquivada, sim.

### D9: v1 sequencial e auditável

Um card por vez; timeouts por fase; cada transição comentada no card pelo
agente (propose feito, tasks concluídas, MR aberto, archive feito) — o card
é o log. Restart do pod não perde estado (tudo no board + git + GitLab).

## Arquitetura

```
HUMANO (browser)                KIND CLUSTER
==============                  ==================================================
board Kanzo <-------- NodePort - KANZO (Deployment, PVC)
  cria card, /aprovado,                     ^ MCP HTTP :4242/mcp
  mergeia no GitLab                         | take/comment/move/link_repo
                                            |
navegador GitLab <-- MR <--- AGENTE (pod) --+
  revisa e mergeia           loop 30s + opencode run por fase
                             + openspec CLI + git + PAT kanban-agent
                                    | branch card/<id> + push + MR
                                    v
                             GITLAB root/agent-workspace
                                    | MR: gitleaks gate + LLM review (auto)
                                    | humano mergeia
                                    v
                             agente: archive + commit main (docs-only)
```

## Risks / Trade-offs

- [Modelo flash pode produzir propostas/código imprecisos] → a proposta é
  aprovada pelo humano ANTES do apply; MR passa por gate + LLM review;
  falha escalada ao backlog
- [Loop re-processa card (idempotência)] → tags trava e transições
  determinísticas fora do LLM
- [MCP do Kanzo indisponível (pod reinicia)] → loop apenas reporta e
  continua no próximo poll; nenhum estado se perde (SQLite no PVC)
- [Agente com PAT amplo (api + write_repository)] → sem escopo admin;
  main protegida; código só via MR com gates
- [Dependência do registry npm/binário do Kanzo no initContainer] → versões
  fixadas; download falho derruba o pod visivelmente (fail visível)

## Open Questions

- Nenhum aberto; defaults de implementação (poll 30s, timeouts 5min/30min,
  sequencial) registrados nas tasks e ajustáveis sem mudar o design.
