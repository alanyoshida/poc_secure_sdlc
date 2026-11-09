# Tasks

## 1. Argo (trigger + WorkflowTemplate)

- [x] 1.1 Adicionar ao Sensor `secrets-gate-mr` o segundo trigger `mr-code-review` (mesmo filtro de dependency) extraindo também `source_branch` (`body.object_attributes.source_branch`) e `project_id` (`body.project.id`); verificar que o pod do Sensor reconcilia
- [x] 1.2 Criar o WorkflowTemplate `mr-code-review` (`manifests/cicd/mr-code-review.yaml`): init container de clone (padrão do gitleaks-scan), container principal `node:22-alpine` que falha com mensagem clara se `secret/ocr-llm` não existir, instala o `ocr` com versão fixada, configura o LLM via `ocr config set` a partir do Secret, executa `ocr review --from main --to <source_branch> --format json`, publica com `post_review.py` e falha em achado critical; verificar o reconciliamento do template

## 2. Credenciais e publicação

- [x] 2.1 Criar o PAT dedicado `mr-review-poster` (escopo `api`) via rails e o Secret `gitlab-mr-poster` (script de tokens, idempotente), sem imprimir o valor
- [x] 2.2 Vendir o `post_review.py` do upstream (`examples/gitlab_ci`) para `scripts/post_review.py` e verificar que ele roda (sintaxe + `--help`/dry-run local) com python3 puro
- [x] 2.3 Documentar o Secret `ocr-llm` (chaves `llm_url`, `auth_token`, `model`, `use_anthropic`) no README, com comando `kubectl create secret` pronto para o usuário preencher

## 3. Bootstrap e documentação

- [x] 3.1 Incorporar ao bootstrap: apply do WorkflowTemplate + Sensor atualizado, criação do PAT/Secret de publicação e aviso explícito quando `secret/ocr-llm` estiver ausente (sem inventar credencial); verificar dupla execução sem duplicar
- [x] 3.2 Documentar o fluxo no README (segundo trigger, onde ver o review, política de bloqueio em critical, custo de tokens) e a referência ao upstream

## 4. Verificação ponta a ponta

- [x] 4.1 Sem o Secret do LLM: abrir MR e verificar que o Workflow `mr-code-review` é criado em paralelo ao gitleaks e falha rápido com a mensagem de configuração ausente (mecanismo de falha clara)
- [x] 4.2 Com o Secret do LLM preenchido pelo usuário (endpoint OpenAI-compatível): MR com mudança de código real → review executado, JSON gerado e discussões inline + nota resumo publicadas no MR
- [x] 4.3 Verificar a política de bloqueio: com `OCR_FAIL_ON_SEVERITY=critical` configurado, um achado critical falha o Workflow e achados menores o deixam Succeeded (testar o mecanismo de gating do `post_review.py`/workflow)

## Workflow follow-up

- Arquivar a change após revisão e implementação (specs sincronizam para `openspec/specs/`).
- E2E completo (4.2/4.3 com LLM real) depende do Secret `ocr-llm` preenchido pelo usuário.
