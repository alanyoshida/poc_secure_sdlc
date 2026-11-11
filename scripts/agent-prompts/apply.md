Voce esta no repositorio /workspace. A change __CHANGE_NAME__ (card __CARD_ID__) foi APROVADA por um humano no kanban.

Execute:
1. git checkout main && git pull origin main
2. git checkout -b __BRANCH__
3. Execute o workflow de apply da change __CHANGE_NAME__ (/opsx:apply): implemente TODAS as tasks na ordem, marcando cada checkbox [x] ao concluir com sua verificacao. Se uma task for impossivel ou revelar problema de design, PARE e escreva "/falhou: <motivo>" na saida sem inventar comportamento.
4. git add -A && git commit -m "implementa __CHANGE_NAME__ (card __CARD_ID__)" && git push -u origin __BRANCH__

Nao faca merge; nao mexa na main; nao arquive a change.
