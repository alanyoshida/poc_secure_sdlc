# Design

## Context

O webhook de MR já flui: GitLab → EventSource `/mr` → Sensor
`secrets-gate-mr` (filtro de ações) → Workflow gitleaks. O
[OpenCodeReview](https://github.com/alibaba/open-code-review) (`ocr`) é uma
CLI Go (npm `@alibaba-group/open-code-review`, binários no GitHub Releases)
que faz code review por LLM sobre o diff (`ocr review --from main --to
<branch>`, modo merge-base) e publica o resultado via `post_review.py`
(example oficial `examples/gitlab_ci`), que cria discussões inline no MR a
partir do JSON (`--format json`). Decisões do usuário: LLM **OpenAI-
compatível** (URL + chave + modelo), resultado **inline no MR**, e
**bloqueio em severity critical** (demais níveis consultivos).

## Goals / Non-Goals

**Goals:**
- Um evento de MR dispara dois Workflows em paralelo: gitleaks (bloqueante)
  e code review da LLM (bloqueante só em critical)
- Reuso máximo: mesmo Sensor/filtro, mesmo Secret de clone, mesmo padrão de
  init container
- Credenciais segregadas: LLM em Secret próprio; PAT dedicado (escopo api)
  para publicar; token de clone permanece read_repository

**Non-Goals:**
- Bloquear o merge no próprio GitLab (a PoC não integra GitLab approvals/
  status checks — o bloqueio é o status do Workflow no Argo)
- Imagem dedicada com o `ocr` embutido (instalação per-run com versão
  fixada; bake de imagem fica como otimização)
- Escolha múltipla de modelos/roteamento, cache de reviews, ou Métricas de
  qualidade da LLM

## Decisions

### D1: Segundo trigger no mesmo Sensor

O Sensor `secrets-gate-mr` ganha um segundo item em `triggers` (mesmo
filtro de ações, aplicado no nível da dependency): um dispara o gitleaks,
outro o `mr-code-review`. Vantagem: um único ponto de filtragem — os dois
fluxos ficam sempre em sincronia quanto a "que evento importa". O trigger
do review extrai `source_branch` (`body.object_attributes.source_branch`) e
`project_id` (`body.project.id`) além de `repo_url`/`mr_iid`.

### D2: WorkflowTemplate dedicado (`mr-code-review`), não um step do gitleaks

Motivos: (a) ciclo de vida e retry independentes — o review é lento (LLM,
minutos) e o gate rápido; (b) secrets diferentes (LLM + PAT de postagem vs
token de clone); (c) o review NÃO deve falhar o gate nem vice-versa: são
requisitos de capabilities distintas (`mr-gate-webhook` vs `mr-llm-review`).

### D3: Instalação do `ocr` per-run com versão fixada

O workflow usa imagem `node:22-alpine` e instala
`@alibaba-group/open-code-review@<versão-fixada>` via npm no próprio pod
(~30-60s). Alternativa (imagem dedicada com o binário embutido via crane
append) ficou de fora para não acoplar o fluxo ao Harbor antes do primeiro
E2E; otimização futura documentada. Git do alpine (2.43+) atende o
pré-requisito (>= 2.41).

### D4: Configuração do LLM via Secret `ocr-llm`, escrita com `ocr config set`

O Secret (chaves: `llm_url`, `auth_token`, `model`, `use_anthropic="false"`)
é montado no pod; o workflow executa `ocr config set llm.*` a partir dos
valores (mesmo mecanismo do example oficial de GitLab CI, que usa as
variáveis `OCR_LLM_URL/OCR_LLM_AUTH_TOKEN/OCR_LLM_MODEL`). Sem o Secret, o
template falha **antes** de instalar nada, com mensagem apontando o Secret
ausente (spec: falha clara). A chave nunca vai para log (montada como
arquivo/env de Secret, não variável de CI).

### D5: Publicação com `post_review.py` vendido + PAT dedicado

`scripts/post_review.py` (cópia de `examples/gitlab_ci/post_review.py` do
upstream, stdlib-only) publica o JSON do review como discussões inline +
nota resumo. Publicação usa PAT dedicado `mr-review-poster` (escopo `api`,
criado no bootstrap via rails, Secret `gitlab-mr-poster`) — o token de
clone não pode postar e o admin não deve circular no fluxo de review. O
script recebe `GITLAB_API_URL` interno e `MR_IID`/`PROJECT_ID` como env do
workflow. Bloqueio: `OCR_FAIL_ON_SEVERITY=critical` — o script sinaliza e o
workflow falha quando há achado critical.

### D6: Escopo do review = merge-base com a main

`ocr review --from main --to <source_branch>` revisa exatamente o diff que
o MR propõe (commits desde a divergência), sem varrer o histórico inteiro
— coerente com o gate de secrets (que avalia o SHA avaliado) e barato em
tokens.

## Arquitetura

```
webhook MR (open/reopen/update)
  -> Sensor secrets-gate-mr (filtro de acoes)
       |-- trigger 1 -> Workflow gitleaks-scan     (gate bloqueante)
       |-- trigger 2 -> Workflow mr-code-review
            init: clone (gitlab-repo-read)
            main: npm i ocr@fixado -> ocr config set (Secret ocr-llm)
                  -> ocr review --from main --to <branch> --format json
                  -> post_review.py -> discussoes inline + resumo no MR
                  -> exit != 0 se achado critical
```

## Risks / Trade-offs

- [LLM pode apontar falsos positivos] → bloqueio restrito a critical;
  demais níveis consultivos; o revisor julga no MR
- [Review depende de acesso de saída ao endpoint do LLM] → o pod já tem
  saída externa (npm); endpoint interno corporativo exigiria egress
  específico (fora da PoC)
- [Custo por review] → ocr otimiza tokens (~1/9 vs agente genérico, claim
  do upstream); versão fixada e `--concurrency` default; revisão só em
  eventos relevantes (filtro existente)
- [Instalação per-run do npm adiciona latência e dependência do registry
  npm] → aceito na PoC; otimização: imagem dedicada
- [Secret do LLM ausente] → workflow falha rápido com mensagem clara;
  bootstrap reporta a pendência sem inventar credencial

## Open Questions

- Qual endpoint/modelo o usuário vai usar (Secret `ocr-llm`) — resolvido no
  momento do E2E pelo próprio usuário
