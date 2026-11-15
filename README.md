# PoC: Secure SDLC Local

Prova de conceito de um **SDLC seguro de ponta a ponta** rodando inteiramente num cluster Kubernetes local (kind): do push do código até uma imagem de container escaneada, com gate bloqueante de secrets antes do build.

**Status: implementado e verificado** — `make bootstrap` sobe o ambiente completo do zero; o pipeline ponta a ponta (push limpo passa, push com secret falha) está validado em `root/demo-app`.

## O fluxo

```
push --> GitLab CI --> security-gate --> webhook --> Argo Events --> Workflow gitleaks
                          | aprovado                     | reprovado: pipeline morre
                          v
                       buildx --> BuildKit (rootless) --> push no Harbor
                                                                |
                                                          Trivy scan (auto)
```

A narrativa de segurança em camadas:

- **Secrets no código** — gitleaks como gate bloqueante antes de qualquer build (fail-closed, scan do histórico completo do repo)
- **Build sem privilégios** — BuildKit rootless, sem Docker-in-Docker (Kaniko foi descontinuado pelo Google em jun/2025)
- **Vulnerabilidades no artefato** — Trivy embutido no Harbor, scan automático a cada push (scanOnPush)
- **Proveniência (roadmap)** — webhook do Trivy → Argo Events → assinatura da imagem com cosign

## Stack

| Componente | Papel | Versão fixada |
|---|---|---|
| kind | Cluster Kubernetes local em Docker | k8s 1.34 |
| GitLab CE (enxuto) | Repositórios + CI/CD | chart 9.11.16 (GitLab 18.11) |
| GitLab Runner | Executor de jobs como pods (kubernetes executor) | chart 0.94.3 |
| Argo Workflows + Events | Workflows disparados por webhook (gate de segurança) | 2.0.18 / 2.4.27 |
| Gitleaks | Scan de secrets no repositório | v8.24.3 |
| BuildKit (rootless) | Build de imagens sem privilégios, cache em PVC | v0.34.2 |
| Harbor | Registry com RBAC + Trivy (scan de vulnerabilidades) | chart 1.19.4 (Harbor 2.15) |
| ArgoCD | GitOps: sincroniza deploys a partir do repo `root/gitops` | chart 10.17.0 |
| ChartMuseum | Repositório Helm dos charts publicados pelo pipeline | chart 3.10.4 |
| cosign | Assinatura das imagens publicadas no Harbor | pacote Alpine `cosign-2.2.1-r5` |
| Kyverno | Admission controller: só admite em `webapps` imagens assinadas | chart 3.9.2 (Kyverno v1.19.2) |

## Requisitos

- Linux com **Docker** e ~**16 GB de RAM livres** (a stack consome ~10-14 GB dentro do cluster; o boot do GitLab é a parte mais pesada)
- CLI: `kind`, `kubectl`, `helm` (v3.14+), `docker`; `argo` CLI opcional para debug dos workflows
- Acesso à internet (charts helm, imagens de containers)

## Uso

```bash
make bootstrap   # cria o cluster e instala TODA a plataforma (idempotente)
make status      # panorama de nós e pods
make urls        # endereços de acesso (GitLab, Harbor, Argo)
make node-hosts  # mapeia os FQDNs do Harbor no /etc/hosts do nó kind (o bootstrap já roda)
make teardown    # destrói o cluster inteiro
```

O `make bootstrap` é idempotente: num ambiente já provisionado ele atualiza
componentes sem duplicar nada. O primeiro boot do GitLab leva vários minutos.

## Acessos e credenciais

| Serviço | Endereço | Credenciais |
|---|---|---|
| GitLab | NodePort do webservice — ver `make urls` | `root` / senha em `secret/gitlab-gitlab-initial-root-password` (ns `gitlab`) |
| Harbor | NodePort 30002 do nó kind — ver `make urls` | `admin` / `Harbor12345` (fixada em `helm/harbor-values.yaml`) |
| Argo Workflows | NodePort 30006 do nó kind — ver `make urls` | sem login (authMode `server`) |
| ArgoCD | NodePort 30005 do nó kind (HTTP, `server.insecure`) — ver `make urls` | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |

Credenciais de máquina ficam em **Secrets do Kubernetes** (ns `cicd`) — nunca
em código, manifests commitados ou logs:

| Secret | Conteúdo |
|---|---|
| `gitlab-admin-token` | PAT root (escopo `api`) usado pelo bootstrap e pelo setup de CI |
| `gitlab-repo-read` | PAT root (escopo `read_repository`) usado pelo Workflow do gate para clonar |
| `gitops-writer-token` | PAT root (escopo `api`+`write_repository`) usado pelo pipeline para comitar a subida de versão em `root/gitops` e pelo ArgoCD para ler o repo |
| `harbor-robot` | credenciais da robot account do pipeline |
| `harbor-pull` | imagePullSecret (dockerconfigjson) para pods puxarem imagens privadas |
| `harbor-pull-webapps` (ns `webapps`, cópia em `kyverno`) | imagePullSecret do Harbor para os deploys do GitOps e para o Kyverno ler assinaturas |
| `cosign-key-pair` | par de chaves cosign (`cosign.key`/`cosign.pub`/`cosign.password`) usado para assinar imagens e para o Kyverno verificar |

No GitLab, o repositório `root/demo-app` usa as variáveis de CI
`HARBOR_REGISTRY` e `HARBOR_REGISTRY_AUTH` (base64 de `usuario:senha`,
**mascarada**) — o base64 evita a interpolação do `$` do nome da robot
(`robot$...`) pelo runner/shell.

## Como o pipeline funciona

Repositório de aplicação exemplo: **`root/demo-app`** (fonte canônico em
[`example-app/`](example-app/), sincronizado pelo bootstrap).

1. **`security-gate`** — [`ci/gate-poll.sh`](example-app/ci/gate-poll.sh) faz
   POST no webhook do Argo Events com `{repo_url, sha}`; o Sensor instancia o
   WorkflowTemplate `gitleaks-scan`, que clona o repo no SHA informado (token
   de `gitlab-repo-read` montado como Secret) e roda `gitleaks git` com
   regras default sobre o **histórico completo**; o job faz poll do status
   via API do Kubernetes com a ServiceAccount do próprio pod (Role `get/list`
   em `workflows.argoproj.io`), intervalo 10s, timeout 5min. **Fail-closed**:
   timeout ou erro de infra também reprova.
2. **`build`** — `docker buildx --driver remote` contra o buildkitd rootless
   (`tcp://buildkitd.cicd.svc.cluster.local:1234`), sem DinD e sem pods
   privilegiados; export `cacheonly` (o cache de camadas fica no PVC do
   buildkitd e é reaproveitado pelo push).
3. **`push`** — mesmo builder com `--push` para
   `harbor.harbor.svc.cluster.local/apps/demo-app:$CI_COMMIT_SHORT_SHA`; o
   Harbor dispara o scan Trivy automaticamente (projeto `apps` com
   `auto_scan`).
4. **`sign`** — assina a tag recém-publicada com cosign (ver
   [Assinatura de imagens](#assinatura-de-imagens-cosign-e-enforcement-kyverno)).

O pull interno das imagens por pods do cluster usa o mirror HTTP configurado
no containerd do kind (`containerdConfigPatches` em [`kind.yaml`](kind.yaml))
+ `imagePullSecrets` (`harbor-pull`).

### Validação de Merge Requests (webhook do GitLab)

Abrir, reabrir ou atualizar um MR no GitLab dispara automaticamente o mesmo
scan de secrets **fora do pipeline**: o webhook do projeto (eventos de
merge request) chama o endpoint `/mr` do Argo Events, e o Sensor
`secrets-gate-mr` (que filtra apenas essas ações) instancia o Workflow
`gitleaks-scan` no SHA do último commit do branch de origem — com o `mr_iid`
nos parâmetros para correlação. O clone é feito pela URL interna do GitLab
(construída a partir de `project.path_with_namespace`), independente da URL
externa do projeto.

- **Onde ver o veredito**: Argo UI (`make urls`) ou
  `kubectl get workflows -n cicd` — o run do MR carrega `mr_iid=<número>`
  nos parâmetros; o scan é rápido (~20s).
- **Limitação atual**: o veredito não é postado de volta no MR (commit
  status/nota) — o fluxo de scan usa somente o token `read_repository`
  (privilégio mínimo); publicar resultados está no roadmap
  ([`docs/ROADMAP.md`](docs/ROADMAP.md)) junto da assinatura com cosign.
- Eventos `merge`, `close` e `approval` não disparam scan.

### Code review de MR por LLM (OpenCodeReview)

O mesmo evento de MR também dispara em paralelo o Workflow **`mr-code-review`**:
o [OpenCodeReview](https://github.com/alibaba/open-code-review) (`ocr`,
versão fixada) revisa o diff do MR (`--from origin/main --to <sha>`, modo
merge-base) com um LLM **OpenAI-compatível** e publica o resultado direto no
MR — **discussões inline por linha do diff + nota resumo** (via
`post_review.py` oficial, vendido em `scripts/post_review.py`).

Configuração necessária (Secret com o endpoint do LLM):

```bash
kubectl create secret generic ocr-llm -n cicd \
  --from-literal=llm_url=https://openrouter.ai/api/v1/chat/completions \
  --from-literal=auth_token=<sua-chave> \
  --from-literal=model=<modelo> \
  --from-literal=use_anthropic=false
```

- Alternativa: coloque as chaves `llm_url`, `llm_api_key`, `llm_model`,
  `llm_provider` num `.env` na raiz do repo — o bootstrap cria o Secret a
  partir dele (a URL recebe o sufixo `/chat/completions` automaticamente).
  O `.env` está no `.gitignore` — **nunca commitado**.
- **Política de bloqueio**: o workflow falha apenas quando o review reporta
  achado `critical` (`OCR_FAIL_ON_SEVERITY`); demais severidades são
  consultivas.
- **Credenciais segregadas**: LLM no Secret `ocr-llm`; publicação usa o PAT
  dedicado `mr-review-poster` (escopo `api`, recriado pelo bootstrap); o
  clone continua no token `read_repository`.
- **Custo**: cada review consome tokens do provedor configurado; reviews só
  disparam em eventos relevantes de MR (mesmo filtro do gate).
- Sem o Secret, o workflow falha rápido com o comando de criação no log.

### Agente kanban (Kanzo + opencode)

O [Kanzo](https://github.com/emanuele-em/kanzo) roda no cluster (board em
PVC + MCP HTTP) e um agente (`opencode` + `openspec` CLI em pod próprio)
executa o mecânico do OpenSpec a partir de cards:

```
backlog (ideias, agente ignora) --mover--> todo --propose--> review
   review + /aprovado --> doing --apply + MR--> review
   MR (gate + LLM review automaticos) --merge humano--> done
   done = archive da change + commit direto na main (docs-only)
```

- **Acesso ao board**: `kubectl -n cicd port-forward deploy/kanzo 4242:4242`
  → http://localhost:4242 (o Kanzo valida o header Host — anti
  DNS-rebinding — então o acesso é via port-forward, não NodePort)
- **Para pedir uma change**: crie um card no projeto `agent-workspace` e
  mova para **todo**; o agente comenta a proposta no card em ~5min
- **Para aprovar**: comente `/aprovado` no card; o agente aplica e abre o MR
  (que passa pelo gate + LLM review); **mergeie** para o agente arquivar
- **Card↔repo**: cada projeto do board é vinculado a um repo GitLab
  (`link_repo`, URL interna) — cards herdam o repo do projeto
- Falhas (propose/apply/archive) movem o card de volta ao **backlog** com
  tag `falhou:<fase>` e comentário de erro; v1 processa um card por vez e
  achados critical no MR são escalados ao humano (sem auto-fix)

### Entrega contínua GitOps (ArgoCD + ChartMuseum)

Depois do merge, a aplicação exemplo **`root/webapp`** (fonte canônico em
[`example-webapp/`](example-webapp/)) completa o ciclo até o deploy no
próprio kind, sem ação manual:

```
merge na main do webapp
  -> pipeline: gate -> build (push no Harbor) -> sign (cosign)
             -> chart (bump de versão + helm package + push no ChartMuseum)
             -> gitops (commit atualizando targetRevision em root/gitops)
  -> ArgoCD detecta o commit (app-of-apps "root" observa root/gitops/apps/)
  -> Application "webapp" sincroniza a nova versão do chart
  -> pod nginx fica Ready no namespace webapps, com a imagem assinada
```

- **Acompanhar o deploy**: UI do ArgoCD (acesso na tabela acima) mostra o
  app-of-apps `root` e o Application filho `webapp`, com status de sync e
  health; ou `kubectl get applications -n argocd`
- **Criar uma nova app GitOps**: adicione um manifesto `Application` em
  `apps/<nome>.yaml` no repositório `root/gitops` (mesmo formato de
  [`example-gitops/apps/webapp.yaml`](example-gitops/apps/webapp.yaml)) — o
  app-of-apps adota automaticamente, sem reconfigurar o ArgoCD
- **Drift**: o `syncPolicy.automated.selfHeal: true` reverte qualquer edição
  manual nos recursos deployados, de volta ao estado do repositório GitOps
- Repositório GitOps semeado pelo bootstrap a partir de
  [`example-gitops/`](example-gitops/) (mesmo mecanismo de sincronização de
  `example-app`/`example-webapp`)

### Assinatura de imagens (cosign) e enforcement (Kyverno)

Toda imagem publicada pelos pipelines (`demo-app` e `webapp`) é assinada
pelo estágio `sign` logo após o push, com a chave do Secret
`cosign-key-pair` (ns `cicd`):

```bash
cosign sign --key k8s://cicd/cosign-key-pair --allow-http-registry --yes \
  harbor.harbor.svc.cluster.local/apps/<nome>:<tag>
```

- **Ver a assinatura no Harbor**: a tag assinada mostra o accessory
  `signature.cosign` na UI (aba da tag) ou via API:
  `GET /api/v2.0/projects/apps/repositories/<nome>/artifacts?with_accessory=true`
- **Onde é exigida**: uma `ClusterPolicy` do Kyverno
  ([`manifests/cosign-verify-policy.yaml`](manifests/cosign-verify-policy.yaml))
  só admite pods no namespace **`webapps`** cuja imagem (`apps/*`) verifique
  contra a chave pública do mesmo Secret — mutação automática fixa a
  imagem por digest. Fora de `webapps` (GitLab, Harbor, ArgoCD,
  ChartMuseum, BuildKit, etc.) nada é verificado — são imagens de
  terceiros, não assinadas por este pipeline
- **Diagnosticar um pod rejeitado**: o evento de admissão (ex.:
  `kubectl describe replicaset -n webapps <nome>` ou o próprio erro do
  `kubectl apply`/ArgoCD) mostra o motivo exato
  (`failed to verify image ...: no signatures found`, por exemplo)
- **Harbor fala HTTPS também (porta 443, cert self-signed)**: só porque o
  verificador do Kyverno exige TLS para resolver a imagem — build, push e
  o próprio `cosign sign` continuam em HTTP puro (porta 80), sem mudança
  nenhuma. `scripts/harbor-dual-scheme.sh` mantém as duas portas
  funcionando após cada `helm upgrade` do Harbor (ver Notas de
  implementação)
- **Depende de internet**: tanto a assinatura (`cosign sign`) quanto a
  verificação pelo Kyverno usam o transparency log público do Sigstore
  (`rekor.sigstore.dev`) — sem essa dependência, o Kyverno 3.9.2 não tem
  como verificar uma assinatura por chave estática. Sem internet, novos
  pods em `webapps` ficam bloqueados (fail-closed) até a conexão voltar

## Notas de implementação

- **Imagem do buildkitd**: `apps/buildkitd:v0.34.2-rootless-idtools` é uma
  variante de `moby/buildkit:v0.34.2-rootless` com `newuidmap`/`newgidmap`
  **setuid root** (camada anexada via `crane append`; ver
  [`scripts/buildkit-image.sh`](scripts/buildkit-image.sh)). O rootlesskit
  exige o mapa multi-faixa de subuids e o `newuidmap` precisa de setuid
  efetivo; volumes k8s são montados `nosuid`, então o ajuste tem que estar
  no filesystem da imagem. O modo rootless funciona (pod uid 1000, sem
  `privileged`, sem socket de runtime) — o fallback buildah não foi preciso.
- **Harbor em HTTP (+ HTTPS self-signed para o Kyverno)**: build/push/pull
  seguem em HTTP puro, tráfego restrito ao cluster (design D6 de
  `setup-secure-sdlc-poc`). O nome `harbor.harbor.svc.cluster.local` é
  resolvido no nó via `/etc/hosts` (`make node-hosts`) porque o containerd
  não usa CoreDNS. A robot account é de sistema (`robot$ci`, escopo
  projeto `apps`, somente push+pull) e é recriada a cada bootstrap para
  girar o secret. O chart do Harbor, com `expose.tls.enabled: true`
  (adicionado pela change `image-signing-enforcement` — só para o Kyverno
  verificar assinatura, ver design D6/D7 dessa change), redireciona a
  porta HTTP para HTTPS por padrão, sem nenhum value para desligar isso;
  `scripts/harbor-dual-scheme.sh` reescreve o ConfigMap `harbor-nginx`
  (fora do Helm) para restaurar as duas portas em paralelo — precisa ser
  chamado de novo depois de qualquer `helm upgrade harbor` manual (o
  bootstrap já faz isso).
- **Kyverno bloqueia upgrade do próprio chart com `ClusterPolicy` legada
  já aplicada** (mesmo na mesma versão 3.9.2): `helm upgrade --install
  kyverno` precisa de `--set
  upgrade.acknowledgeLegacyPoliciesNotEnforced=true` a partir da segunda
  execução do bootstrap, senão falha.
- **Scan de histórico**: o gate roda `gitleaks git` no clone completo — um
  secret removido do HEAD ainda reprova o pipeline (comportamento desejado).
  Repos de teste com secrets falsos precisam da história reescrita para
  voltar a passar.
- Este build do Harbor (2.15.4) não expõe `POST /robots/{id}/secret` nem
  listagem de robots de projeto — por isso a robot é de sistema e é
  recriada no bootstrap.

## Planejamento e roadmap

- Artefatos OpenSpec: [`openspec/changes/archive/`](openspec/changes/archive/) (uma pasta por change implementada — proposal, design, specs, tasks); change em andamento, se houver, em [`openspec/changes/`](openspec/changes/)
- Roadmap pós-PoC: [`docs/ROADMAP.md`](docs/ROADMAP.md)
