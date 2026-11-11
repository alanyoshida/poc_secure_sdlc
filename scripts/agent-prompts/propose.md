Voce esta no repositorio /workspace (agent-workspace). Um humano criou o card __CARD_ID__ no kanban como REQUISICAO DE CHANGE OpenSpec.

Titulo do card: __CARD_TITLE__

Descricao do card:
---
__CARD_DESC__
---

Execute o workflow de propose do OpenSpec:
1. Crie a change com o nome EXATO __CHANGE_NAME__ (openspec new change).
2. Preencha proposal.md, specs/ e design.md e tasks.md com base na descricao do card. Se a descricao for vaga ou insuficiente para uma change com senso, FALHE explicitamente: escreva "/falhou: <o que falta decidir>" na saida e nao crie artefatos sem sentido.
3. NAO implemente nada (so artefatos de planejamento; nada de codigo de aplicacao).
4. Ao final: git add openspec/changes/__CHANGE_NAME__ && git commit -m "propoe __CHANGE_NAME__ (card __CARD_ID__)" && git push origin main.

Regras: commit APENAS dos artefatos da change; nao mexa em outro caminho.
