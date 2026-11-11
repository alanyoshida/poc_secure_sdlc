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
| Argo Workflows | `kubectl -n cicd port-forward svc/argo-workflows-server 2746:2746` → http://127.0.0.1:2746 | sem login (authMode `server`) |

Credenciais de máquina ficam em **Secrets do Kubernetes** (ns `cicd`) — nunca
em código, manifests commitados ou logs:

| Secret | Conteúdo |
|---|---|
| `gitlab-admin-token` | PAT root (escopo `api`) usado pelo bootstrap e pelo setup de CI |
| `gitlab-repo-read` | PAT root (escopo `read_repository`) usado pelo Workflow do gate para clonar |
| `harbor-robot` | credenciais da robot account do pipeline |
| `harbor-pull` | imagePullSecret (dockerconfigjson) para pods puxarem imagens privadas |

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

## Notas de implementação

- **Imagem do buildkitd**: `apps/buildkitd:v0.34.2-rootless-idtools` é uma
  variante de `moby/buildkit:v0.34.2-rootless` com `newuidmap`/`newgidmap`
  **setuid root** (camada anexada via `crane append`; ver
  [`scripts/buildkit-image.sh`](scripts/buildkit-image.sh)). O rootlesskit
  exige o mapa multi-faixa de subuids e o `newuidmap` precisa de setuid
  efetivo; volumes k8s são montados `nosuid`, então o ajuste tem que estar
  no filesystem da imagem. O modo rootless funciona (pod uid 1000, sem
  `privileged`, sem socket de runtime) — o fallback buildah não foi preciso.
- **Harbor em HTTP**: tráfego restrito ao cluster (design D6). O nome
  `harbor.harbor.svc.cluster.local` é resolvido no nó via `/etc/hosts`
  (`make node-hosts`) porque o containerd não usa CoreDNS. A robot account é
  de sistema (`robot$ci`, escopo projeto `apps`, somente push+pull) e é
  recriada a cada bootstrap para girar o secret.
- **Scan de histórico**: o gate roda `gitleaks git` no clone completo — um
  secret removido do HEAD ainda reprova o pipeline (comportamento desejado).
  Repos de teste com secrets falsos precisam da história reescrita para
  voltar a passar.
- Este build do Harbor (2.15.4) não expõe `POST /robots/{id}/secret` nem
  listagem de robots de projeto — por isso a robot é de sistema e é
  recriada no bootstrap.

## Planejamento e roadmap

- Artefatos OpenSpec: [`openspec/changes/setup-secure-sdlc-poc/`](openspec/changes/setup-secure-sdlc-poc/) (proposal, design D1–D8, specs, tasks)
- Roadmap pós-PoC: [`docs/ROADMAP.md`](docs/ROADMAP.md)
