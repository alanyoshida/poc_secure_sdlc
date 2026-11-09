# Proposal

## Why

O MR hoje passa apenas pelo gate de secrets (gitleaks) — não há revisão de
**qualidade do código** no fluxo. O [OpenCodeReview](https://github.com/alibaba/open-code-review)
(`ocr`, CLI da Alibaba, Go, 49k+ estrelas, Apache-2.0) faz code review com
LLM sobre o diff do MR: arquitetura híbrida (pipeline determinístico de
seleção/agrupamento de arquivos + agente LLM), comentários com precisão de
linha, provedor OpenAI-compatível ou Anthropic, e example oficial de
integração com GitLab CI (incluindo o `post_review.py` que publica
discussões inline no MR). Encaixa-se no barramento existente: o evento de MR
que já dispara o security gate passa a disparar também o review da LLM.

## What Changes

- Sensor `secrets-gate-mr` ganha um **segundo trigger** (mesmo evento
  filtrado): em vez de um, o MR agora dispara **dois** Workflows em paralelo
  — o gitleaks (gate bloqueante) e o review da LLM
- Novo WorkflowTemplate **`mr-code-review`**: clona o repo (mesmo Secret de
  leitura), instala o `ocr` (versão fixada), executa
  `ocr review --from main --to <branch-do-MR>` (modo merge-base, exatamente
  o escopo do diff do MR) com o LLM configurado via Secret, publica o
  resultado como **discussões inline no MR** (comentários por linha + nota
  resumo) usando o `post_review.py` oficial vendido para este repo, e
  **falha quando um achado de severidade critical** é reportado
  (`OCR_FAIL_ON_SEVERITY=critical`) — os demais níveis são consultivos
- Novos parâmetros no trigger: `source_branch` e `project_id` (payload do
  GitLab)
- Novo Secret **`ocr-llm`** (URL do endpoint OpenAI-compatível, chave e
  modelo) — **preenchido pelo usuário**; sem o Secret o workflow falha com
  mensagem clara
- Novo PAT dedicado `mr-review-poster` (escopo `api`, só para postar o
  review) criado pelo bootstrap — o token de clone (`read_repository`) não
  pode postar, e o admin não deve ser exposto ao fluxo
- `post_review.py` vendido para o repo de plataforma (a partir de
  `examples/gitlab_ci` do upstream) e usado pelo workflow

Não muda: o security gate (gitleaks) continua bloqueando exatamente como
hoje; o Sensor, EventBus, EventSource e webhook do GitLab permanecem; nada
de configuração do GitLab precisa mudar (o token novo usa a mesma API).

## Capabilities

### New Capabilities

- `mr-llm-review`: code review automático de MRs por LLM (OpenCodeReview)
  disparado pelo mesmo webhook do security gate, publicado como discussões
  inline no MR, bloqueando apenas em severidade critical

### Modified Capabilities

(nenhuma — o gate de secrets e o fluxo de MR existentes seguem com seus
requisitos atuais)

## Impact

- **Novos artefatos**: WorkflowTemplate `mr-code-review`
  (`manifests/cicd/mr-code-review.yaml`), segundo trigger no Sensor
  `secrets-gate-mr`, `post_review.py` vendido (`scripts/post_review.py`),
  PAT `mr-review-poster` (script de tokens) e Secret `ocr-llm` (usuário)
- **Dependência externa nova**: imagem `node:22-alpine` (npm para instalar
  o ocr) e acesso de saída ao endpoint do LLM informado pelo usuário
- **Custo**: cada review consome tokens do provedor configurado
- **Sem E2E completo até a chave existir**: o Secret `ocr-llm` é do usuário;
  o mecanismo (falha clara sem Secret, disparo paralelo, geração do JSON)
  é testável sem ele
