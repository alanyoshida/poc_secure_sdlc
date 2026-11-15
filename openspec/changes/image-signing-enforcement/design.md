# Design

## Context

Os pipelines de `example-app` e `example-webapp` hoje terminam em
`push`/`chart` com a imagem publicada no Harbor (ver
`container-build-pipeline` e `gitops-deploy`). O Harbor está na versão
1.19.4 do chart (Harbor 2.15.4), que já suporta exibir artefatos OCI
associados a uma tag (accessories) sem configuração extra — é o mecanismo
que o cosign usa nativamente para publicar uma assinatura. O
GitLab Runner executa jobs como pods no namespace `cicd` com o
ServiceAccount `gitlab-runner-job` (`helm/runner-values.yaml`), sem
acesso a outros Secrets do namespace por padrão. Kyverno ainda não existe
no cluster (ver proposal.md - Why).

**Atualização pós-implementação**: o Harbor precisou ganhar TLS (ver D6)
e a assinatura precisou voltar a subir ao Rekor público (ver D3) —
nenhum dos dois estava previsto neste design original; ambos foram
decisões tomadas com o usuário durante a implementação, quando o
`verifyImages` do Kyverno se mostrou incompatível com um registry
HTTP-only e com verificação de chave estática sem transparency log. Os
detalhes e o porquê estão em D3 e D6.

## Goals / Non-Goals

**Goals:**
- Toda imagem publicada pelos pipelines da PoC é assinada com cosign
  logo após o push, sem ação manual
- A assinatura é visível na UI do Harbor sem configuração adicional
- Pods no namespace `webapps` só são admitidos se a imagem verificar
  contra a chave pública do par cosign da plataforma
- Bootstrap reproduz tudo (chave, RBAC, Kyverno, policy) de forma
  idempotente

**Non-Goals:**
- Assinatura keyless (Sigstore Fulcio/Rekor públicos como identidade) —
  exigiria um provedor OIDC; fora do escopo de um cluster kind local.
  **Atualizado**: a assinatura continua por chave estática, mas precisa
  subir uma entrada ao Rekor público mesmo assim — ver D3; a PoC já
  depende de internet para pull de charts/imagens, então isso não é uma
  dependência nova de rede, só um serviço externo adicional
- Rotação automatizada da chave cosign, ou múltiplas chaves por
  ambiente/projeto
- TLS real (CA confiável, hostname verificável) no Harbor para uso
  geral — o certificado self-signed adicionado (D6) serve só para o
  Kyverno conseguir falar HTTPS; build/push/pull continuam em HTTP puro
- Gate de assinatura condicionado ao resultado do scan do Trivy (ideia
  registrada como roadmap em `setup-secure-sdlc-poc`/D8); aqui a
  assinatura é incondicional, após o push — ligar isso ao Trivy é
  evolução futura, não desta change
- Enforcement do Kyverno fora do namespace `webapps` (decisão do
  usuário: os demais namespaces rodam imagens de terceiros não
  assinadas por este pipeline — GitLab, Harbor, ArgoCD, ChartMuseum,
  BuildKit, etc.)

## Decisions

### D1: Par de chaves cosign via KMS do Kubernetes

`cosign generate-key-pair k8s://cicd/cosign-key-pair` cria o Secret
`cosign-key-pair` no namespace `cicd` com as chaves `cosign.key`
(privada, cifrada com uma senha também armazenada no Secret) e
`cosign.pub` (pública). O job de assinatura referencia a chave como
`k8s://cicd/cosign-key-pair` — o cosign lê o Secret diretamente via API
do Kubernetes, sem nunca gravar a chave privada em disco no job.
Alternativa descartada: gerar a chave fora do cluster e importar via CI
variable (mais um segredo em texto para transportar, sem ganho — o
Secret nativo já é a fonte de verdade do projeto para credenciais).

### D2: RBAC mínimo para o job de CI ler a chave

Novo `Role`/`RoleBinding` no namespace `cicd` concedendo `get` **apenas**
no Secret `cosign-key-pair` ao ServiceAccount `gitlab-runner-job` (o
mesmo usado por todos os jobs do runner). Sem esse RBAC, o provider
`k8s://` do cosign falha ao tentar ler o Secret via API — o job de
assinatura é o único a precisar desse acesso; nenhum outro Secret do
namespace é exposto.

### D3: Estágio `sign` nos pipelines, por tag (não por digest explícito)

Novo stage `sign` após `push` (example-app) / dentro do job `build`
existente, como passo adicional (example-webapp) — mesma ordem lógica:
assinar imediatamente após o push, antes de qualquer estágio que use a
imagem. Comando: `cosign sign --key k8s://cicd/cosign-key-pair --yes
"$HARBOR_REGISTRY/apps/<nome>:$CI_COMMIT_SHORT_SHA"`. O cosign resolve a
tag para o digest no momento da assinatura (assinaturas são sempre por
digest internamente); não é preciso capturar o digest manualmente no
script. A imagem oficial do cosign (`ghcr.io/sigstore/cosign/cosign`) é
distroless/sem shell — o executor kubernetes do GitLab Runner precisa de
`sh` para rodar os scripts do job (estratégia "attach"), então o job usa
`alpine:3.20` com `apk add cosign` (pacote `cosign-2.2.1-r5` do repo
community do Alpine 3.20), mesma base já usada nos outros jobs leves do
pipeline. O push da imagem continua em HTTP puro (porta 8080 do Harbor,
ver D6); a flag confirmada é `cosign sign --allow-http-registry`. Por
padrão o cosign sobe uma entrada ao Rekor **público**
(transparency log hospedado pelo Sigstore na internet) mesmo em
assinatura por chave — a primeira versão deste design desligava isso
com `--tlog-upload=false`, mas o verificador do Kyverno (D5) rejeita
assinatura por chave estática sem entrada no Rekor ("no matching
signatures: signature not found in transparency log"), sem nenhuma
opção na API do `ClusterPolicy` para pular essa checagem nesta versão
(3.9.2). Decisão, confirmada com o usuário: manter o upload ao Rekor
público ligado (comportamento padrão do cosign) — é o único jeito de o
Kyverno verificar a assinatura nesta versão.

### D4: Visibilidade no Harbor é automática, sem configuração

O cosign publica a assinatura como um manifesto OCI referenciando o
digest da imagem (`cosign-images/sigstore` schema). Harbor 2.12+
reconhece esse padrão nativamente e lista a assinatura na aba
"Accessories" da tag — não há chart value ou configuração adicional a
mudar em `helm/harbor-values.yaml`.

### D5: Kyverno instalado via chart, policy restrita a `webapps`

Kyverno (chart `kyverno/kyverno`, versão **3.9.2** / app v1.19.2, fixada)
instalado em namespace próprio (`kyverno`). Versão escolhida
deliberadamente: a 3.10.0/v1.20.0 (a mais recente no momento) **removeu**
a execução de `ClusterPolicy` legada do tipo `verifyImages` — só aceita
a nova `ImageValidatingPolicy` (CEL, API `policies.kyverno.io`); 3.9.2 é
a última linha que ainda executa o `ClusterPolicy` legado usado aqui.
Uma `ClusterPolicy` com regra `verifyImages` casando
`harbor.harbor.svc.cluster.local/apps/*` e `match.any[].resources.namespaces:
["webapps"]`, usando a chave pública lida do mesmo Secret
`cosign-key-pair` via `attestors[].entries[].keys.publicKeys:
"k8s://cicd/cosign-key-pair"` (mesmo formato `k8s://` do próprio cosign,
lê o campo `cosign.pub`) — exige RBAC (`Role`/`RoleBinding`) dando ao
ServiceAccount `kyverno-admission-controller` (ns `kyverno`) permissão
`get` nesse único Secret do namespace `cicd`.
Modo de falha: `webhookConfiguration.failurePolicy: Fail` (fail-closed,
consistente com o gate de secrets, e já o default do Kyverno) apenas
dentro do escopo casado pelo `match`; fora de `webapps` a regra nem
avalia o recurso. `ClusterPolicy` (não `Policy`) porque o Kyverno exige
policy cluster-scoped para `verifyImages` legado, mas o
efeito prático fica limitado pelo `match` ao namespace `webapps`.

Três ajustes adicionais descobertos ao testar, nenhum documentado
claramente pelo chart/CRD:
- `webhookConfiguration.timeoutSeconds: 30` — o default (10s) não é
  suficiente para o Kyverno resolver o cosign (TUF + busca da
  assinatura no Harbor); 30s é o máximo aceito pela API do Kubernetes
- `verifyImages[].imageRegistryCredentials.allowInsecureRegistry: true`
  — **não é o mesmo** flag global `--allowInsecureRegistry` do Helm
  (esse só pula validação de certificado); sem este campo por-regra, o
  verificador do cosign só tenta HTTPS e nunca cai para HTTP mesmo
  quando a conexão falha
- `verifyImages[].imageRegistryCredentials.secrets: ["harbor-pull-webapps"]`
  — sem credencial explícita o Kyverno tenta acesso anônimo ao Harbor
  (que exige autenticação para pull, ver `image-registry-scanning`) e
  falha com `UNAUTHORIZED`; o nome sem prefixo de namespace busca o
  Secret no namespace do próprio Kyverno (por isso uma cópia do Secret
  `harbor-pull-webapps` existe também em `kyverno`, além do original em
  `webapps` usado pelos pods) — exige RBAC equivalente nesse namespace
- `helm upgrade --install kyverno` (mesma versão 3.9.2, re-execução
  idempotente do bootstrap) falha depois que a `ClusterPolicy` já
  existe: o próprio chart bloqueia upgrade/reinstalação quando detecta
  qualquer policy legada no cluster, mesmo permanecendo na mesma versão
  que ainda a executa — flag `--set
  upgrade.acknowledgeLegacyPoliciesNotEnforced=true` (sugerida pelo
  próprio erro do chart) necessária para o bootstrap voltar a ser
  idempotente
- `mutateDigest` (reescreve a imagem do recurso admitido para a forma
  por digest) **não é opcional** aqui: desligá-lo (`false`) quebra a
  verificação em recursos controller-owned (Deployment, via regra
  "autogen" que o Kyverno gera automaticamente a partir da regra
  casando `Pod`) com erro `missing digest for ...` — a verificação em
  si depende do digest já resolvido. Isso por sua vez entra em conflito
  direto com o ArgoCD: o Deployment live fica com `image:
  ...@sha256:...` enquanto o manifesto desejado (chart) declara só a
  tag, e isso nunca converge — `selfHeal: true` reaplicaria o manifesto
  a cada poll (~3min), e o Kyverno re-mutaria de volta no mesmo
  admission, reiniciando o pod indefinidamente. Resolvido do lado do
  ArgoCD, não do Kyverno: `ignoreDifferences` no Application
  (`example-gitops/apps/webapp.yaml`) ignorando
  `/spec/template/spec/containers/0/image` para `Deployment` — o
  `managedFieldsManagers` do ArgoCD (alternativa mais "correta" em
  teoria) não serve aqui porque o Kyverno edita o payload da requisição
  de admissão antes de persistir, sem aparecer como um field manager
  próprio nos `managedFields` do objeto (fica atribuído a quem
  originalmente fez a requisição, o `argocd-controller`)

### D6: TLS self-signed no Harbor, só para o Kyverno conseguir verificar

Descoberta central da implementação: o verificador de imagem do Kyverno
(tanto a API legada `ClusterPolicy` quanto a nova `ImageValidatingPolicy`
em CEL — mesma biblioteca por baixo) **sempre tenta HTTPS** ao resolver
o manifest/digest da imagem antes de verificar a assinatura; não há
fallback automático para HTTP quando a conexão falha (nem por timeout,
nem por "connection refused"), e o flag `allowInsecureRegistry` só
desliga a validação do certificado, não troca o esquema. Isso conflita
com a decisão "Harbor em HTTP" de `setup-secure-sdlc-poc`/`gitops-deploy`.

Alternativas descartadas antes desta:
- Sidecar TLS-terminating só para o Kyverno: exigiria editar o
  Deployment do `harbor-nginx` (gerenciado pelo Helm, sem hook de
  sidecar exposto nos values) ou arriscar round-robin quebrado
  misturando endpoints com/sem o sidecar no mesmo Service — rejeitado
  por fragilidade
- Deixar a `ClusterPolicy` em `failureAction: Audit` (não bloqueia) —
  rejeitado pelo usuário por não cumprir o objetivo real da change

Decisão: habilitar `expose.tls` nativo do chart do Harbor
(`certSource: auto`, cert self-signed, `commonName:
harbor.harbor.svc.cluster.local`), nodePort https em 30004 (30003 já
usado pelo `kanzo-board`). O Kyverno aceita o cert self-signed via
`allowInsecureRegistry` (D5) — não precisa de CA confiável.

Efeito colateral descoberto: o template do chart do Harbor, com TLS
habilitado, **sempre** redireciona a porta HTTP (8080) para HTTPS com
um `return 301` fixo no `nginx.conf` — sem nenhum value para desligar
isso. Isso quebraria build/push (buildkitd configurado para falar HTTP
puro com este host, `manifests/cicd/buildkitd.yaml`) e o próprio
`cosign sign` (`--allow-http-registry`), que devem continuar em HTTP
puro deliberadamente. `scripts/harbor-dual-scheme.sh` reescreve
diretamente o ConfigMap `harbor-nginx` após o `helm upgrade`,
substituindo esse bloco de redirect pelo `proxy_pass` normal (copiado
do próprio template do chart, usado quando TLS está desligado) —
restaura as duas portas (8080 HTTP pleno + 8443 HTTPS) funcionando em
paralelo. Precisa ser reaplicado a cada `helm upgrade harbor` (o chart
sempre regenera o redirect); chamado pelo bootstrap logo após o passo
do Harbor.

### D7: Rollout sem quebrar o deploy existente

A imagem `apps/webapp` atualmente rodando no namespace `webapps` (de
antes desta change) não está assinada. Se a `ClusterPolicy` entrar em
vigor antes de existir uma versão assinada, o pod existente continua
rodando (o Kyverno só valida em **admissão**, não remove pods já
rodando), mas qualquer novo rollout do ArgoCD falha a partir daí. Ordem
de aplicação no bootstrap/tasks: (1) chave + RBAC, (2) Kyverno
instalado, (3) pipelines com o estágio `sign` publicados e **um push
disparado** (nova versão assinada sobe e o ArgoCD sincroniza com
sucesso), (4) só então a `ClusterPolicy` é aplicada. A ordem é
verificada como task explícita, não deixada implícita no bootstrap.

## Risks / Trade-offs

- [Chave privada cosign é um ponto único de comprometimento — quem a lê
  pode assinar qualquer imagem] → RBAC restrito a um único
  ServiceAccount e um único Secret; mitigação suficiente para a PoC,
  rotação fica como evolução futura
- [`ClusterPolicy` com `failurePolicy: Fail` mal configurada pode
  bloquear criação de pods em `webapps` por erro de rede ao verificar a
  assinatura, não só por assinatura ausente] → risco aceito na PoC
  (mesma postura fail-closed do gate de secrets); documentar no README
  como diagnosticar (`kubectl describe` do pod/ReplicaSet mostra o
  motivo da rejeição do Kyverno)
- [Kyverno consome ~100-200MB de RAM adicionais] → dentro da folga da
  máquina (mesma folga usada para ArgoCD/ChartMuseum em `gitops-deploy`)
- [Harbor não exibir o accessory se a versão do chart mudar no futuro] →
  comportamento nativo da versão atual (1.19.4); reavaliar se o chart
  for atualizado
- [Dependência nova do Rekor público (D3): se o cluster perder acesso à
  internet, `cosign sign` falha no pipeline e o Kyverno não consegue
  verificar imagens já assinadas sem o registro de transparência
  acessível, bloqueando novos pods em `webapps`] → aceito pelo usuário;
  é o único jeito do Kyverno 3.9.2 verificar chave estática; mitigação
  futura seria migrar para `ImageValidatingPolicy` (CEL) se essa API
  expuser uma forma de pular a checagem
- [`scripts/harbor-dual-scheme.sh` reescreve um ConfigMap gerado pelo
  Helm, fora do controle do chart — fica dessincronizado até o
  bootstrap rodar de novo após qualquer `helm upgrade harbor` manual]
  → mitigado por ser chamado automaticamente pelo bootstrap (D6/D7,
  idempotente) logo após o passo do Harbor
- [Certificado self-signed do Harbor (D6) não é validado por nenhum
  cliente — qualquer um que fale com `harbor.harbor.svc.cluster.local:443`
  aceita esse certificado] → aceito, é só para o Kyverno verificar
  assinatura dentro do cluster; nunca exposto fora dele

## Migration Plan

1. Bootstrap cria o Secret `cosign-key-pair` e o RBAC (idempotente)
2. Bootstrap habilita TLS no Harbor (`helm/harbor-values.yaml`) e roda
   `scripts/harbor-dual-scheme.sh` para restaurar a porta HTTP (D6)
3. Bootstrap instala o Kyverno (idempotente), **sem** aplicar a
   `ClusterPolicy` ainda
4. Pipelines (`example-app`, `example-webapp`) ganham o estágio `sign`;
   um push de verificação confirma que a imagem sai assinada (com
   entrada no Rekor) e visível no Harbor
5. Deploy do app via GitOps é verificado funcionando normalmente com a
   imagem assinada (ArgoCD sincroniza, pod fica Ready)
6. Só então a `ClusterPolicy` é aplicada (manifesto separado, último
   passo do bootstrap para este fluxo)
7. Rollback: `kubectl delete clusterpolicy <nome>` remove o enforcement
   imediatamente, sem afetar os pods já admitidos; `helm uninstall
   kyverno` remove o componente por completo; reverter
   `expose.tls.enabled` para `false` no Harbor remove o TLS (não
   precisa do `harbor-dual-scheme.sh` nesse caso, o chart volta ao
   comportamento original)

## Open Questions

- Nenhuma aberta. Resolvido na implementação, na ordem em que apareceu:
  cosign via `apk add cosign` em `alpine:3.20` (a imagem oficial
  distroless não tem shell para o executor do runner); flag
  `--allow-http-registry` para o push/sign HTTP; Kyverno fixado em
  3.9.2/v1.19.2 (3.10.0 removeu `verifyImages` legado); TLS self-signed
  no Harbor + `scripts/harbor-dual-scheme.sh` (D6, único jeito do
  Kyverno alcançar o registry); `imageRegistryCredentials` com
  `allowInsecureRegistry` e `secrets` por-regra (D5, diferente do flag
  global); `webhookConfiguration.timeoutSeconds: 30` (D5); upload ao
  Rekor público reabilitado (D3, Kyverno exige para chave estática).
