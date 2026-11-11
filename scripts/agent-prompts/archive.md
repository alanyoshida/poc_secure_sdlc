Voce esta no repositorio /workspace. O MR da branch __BRANCH__ (card __CARD_ID__, change __CHANGE_NAME__) foi MERGEADO por um humano.

Execute:
1. git checkout main && git pull origin main
2. Execute o archive da change __CHANGE_NAME__ (/opsx:archive): move a change para openspec/changes/archive/ e sincroniza o spec para openspec/specs/.
3. git add -A && git commit -m "arquiva __CHANGE_NAME__ (card __CARD_ID__)" && git push origin main

Se a change ja foi arquivada, apenas faca o push se houver algo pendente; caso contrario diga ARCHIVE_JA_FEITO.
