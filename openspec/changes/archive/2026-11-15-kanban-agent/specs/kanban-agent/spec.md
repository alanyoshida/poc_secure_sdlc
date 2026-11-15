# Spec Delta

## Purpose

Agente autônomo que traduz o ciclo de vida de cards do Kanzo em mudanças
OpenSpec: card em todo vira requisição de change (propose publicado como
comentário no card), comentário `/aprovado` do humano autoriza o apply, o
código vai por MR (passando pelos gates automáticos existentes), o merge
humano autoriza o archive, e falhas voltam ao backlog escaladas ao humano.

## ADDED Requirements

### Requirement: Board e agente no cluster

O sistema SHALL prover o Kanzo como Deployment no cluster (dados em PVC,
board acessível via NodePort) e o agente como pod com loop de polling,
opencode e openspec CLI, conversando com o Kanzo pelo endpoint MCP HTTP.

#### Scenario: Board acessível ao humano

- **WHEN** o bootstrap conclui
- **THEN** o board do Kanzo responde na porta NodePort documentada

#### Scenario: Agente enxerga apenas todo em diante

- **WHEN** existem cards em backlog e em todo
- **THEN** o agente processa somente os cards de todo em diante (backlog é
  ignorado nativamente pelo Kanzo)

### Requirement: Card em todo dispara proposta

O agente SHALL detectar cards em todo, interpretar o card como requisição de
change, executar o propose com opencode e publicar o resumo da proposta como
comentário no card, marcando-a com tag de proposta-publicada e movendo o
card para review.

#### Scenario: Proposta publicada no card

- **WHEN** um card é movido para todo
- **THEN** o agente cria a change OpenSpec correspondente e comenta no card
  o resumo da proposta (proposal + escopo), com tag de proposta-publicada e
  card movido para review

#### Scenario: Card ambíguo é escalado

- **WHEN** o propose falha ou produz change inválida
- **THEN** o agente comenta o erro no card e o move de volta ao backlog com
  tag `falhou:<motivo>`

### Requirement: Aprovação da proposta por comentário

O agente SHALL iniciar o apply apenas quando o card em review receber um
comentário do humano iniciado por `/aprovado`, com trava de idempotência que
impede reprocessamento.

#### Scenario: Aprovado move para doing

- **WHEN** um card em review com proposta-publicada recebe comentário
  iniciado por `/aprovado`
- **THEN** o agente move o card para doing e executa o apply da change

#### Scenario: Comandos não repetem

- **WHEN** um segundo `/aprovado` chega ao mesmo card
- **THEN** nenhum novo apply é iniciado (trava de idempotência)

### Requirement: Apply gera MR revisado pelos agentes

O agente SHALL implementar a change na fase doing (openspec apply), criar
branch `card/<id>-<slug>`, abrir MR no GitLab, registrar a URL do MR no card
e movê-lo para review; o MR SHALL receber automaticamente o gate de secrets
e o code review por LLM já especificados.

#### Scenario: MR aberto e analisado

- **WHEN** o apply conclui e o MR é aberto
- **THEN** o MR recebe o gate de secrets e o code review por LLM sem ação
  manual, e o card aponta para o MR

#### Scenario: Aplicação escalada ao humano em critical

- **WHEN** o review por LLM do MR do agente reporta achado critical
- **THEN** nenhum auto-fix é executado na v1: o humano intervém no MR

### Requirement: Merge humano conclui o card

O agente SHALL detectar o merge do MR, mover o card para done, executar o
archive da change e commitar diretamente na main o resultado (mudança
docs-only: change arquivada e spec sincronizado).

#### Scenario: Merge fecha o ciclo

- **WHEN** o MR do card é mergeado
- **THEN** o agente move o card para done, arquiva a change e faz push do
  commit de archive direto na main

#### Scenario: Código nunca vai direto para a main

- **WHEN** o agente envia código do card
- **THEN** ele vai sempre pela branch do MR; o commit direto na main contém
  apenas documentação de spec arquivada

### Requirement: Vínculo projeto-repo nativo do Kanzo

O mapeamento projeto do board para repositório GitLab SHALL usar os recursos
nativos do Kanzo (`link_repo` para semear, `list_projects` para o loop
descobrir a URL de clone), com links semeados apontando para a URL interna
do GitLab.

#### Scenario: Loop descobre o repo pelo projeto

- **WHEN** o loop encontra um card de um projeto
- **THEN** ele obtém a URL de clone do repo vinculado ao projeto via
  list_projects, sem repositório de configuração externo

#### Scenario: Projeto novo entra pelo mesmo fluxo

- **WHEN** um novo projeto é criado no board e vinculado a um novo repo
  GitLab
- **THEN** os cards desse projeto fluem pelo mesmo ciclo de vida sem nova
  configuração do agente

### Requirement: Provisionamento pelo bootstrap

O bootstrap SHALL provisionar Kanzo, agente, PAT dedicado do agente,
workspace repo semeado e o vínculo inicial projeto-repo de forma
idempotente; a ausência da chave do LLM SHALL ser reportada como ação
pendente do usuário.

#### Scenario: Bootstrap prepara o agente

- **WHEN** `make bootstrap` roda
- **THEN** board, agente, PAT, workspace e vínculo projeto-repo existem e o
  agente está no ar, com a chave do LLM reportada se ausente
