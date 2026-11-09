# Design

## Context

Greenfield: o repositório hoje contém apenas a estrutura OpenSpec — não existe código nem ambiente. A motivação está em proposal.md. Restrições relevantes: máquina alvo Linux com 46GB RAM (~21GB disponíveis) e Docker; a PoC deve ser auto-contida e reproduzível; o Kaniko, escolha inicial para o build, foi arquivado pelo Google em jun/2025 e não pode ser usado.

## Goals / Non-Goals

**Goals:**
- Toda a plataforma dentro de um único cluster kind; comunicação 100% via DNS de Services do Kubernetes
- Bootstrap e teardown reproduzíveis por comando único (Makefile)
- Pipeline com gate de secrets bloqueante **antes** do build (fail-closed)
- Build de imagens sem privilégios e sem Docker-in-Docker
- Registry com scan automático de vulnerabilidades e RBAC

**Non-Goals:**
- Alta disponibilidade, TLS/pki real, hardening para produção — é PoC local
- Ingress controller (evolução futura; PoC usa NodePort/port-forward)
- Assinatura de imagens com cosign (roadmap documentado, fora desta change)
- Docker compose (eliminado da arquitetura)
- GitOps do próprio cluster (Argo CD) — a PoC usa Argo Workflows/Events apenas

## Decisions

### D1: Tudo dentro do kind; docker compose eliminado

Arquitetura inicial considerada era docker compose orquestrando GitLab + registry fora do cluster. Descartada porque o kind cria rede Docker própria e a comunicação compose↔kind exigiria gambiarras (redes externas compartilhadas, `host.docker.internal`). Com tudo no cluster, toda comunicação vira DNS de Service (`http://gitlab.gitlab.svc`, `http://harbor-harbor-registry.harbor.svc:5000`). O compose não teria função residual; o bootstrap vira um Makefile com `kind create cluster --config kind.yaml` + `helm install/upgrade`.

### D2: GitLab CE enxuto via chart oficial

Chart `gitlab/gitlab` com values reduzidos: `prometheus.install=false`, `grafana.enabled=false`, `gitlab.kas.enabled=false`, `minio` como object storage, 1 réplica por componente, sem registry embutido (usamos Harbor). Boot esperado de vários minutos — aceito e documentado. Alternativa considerada: Gitea (~500MB), descartada porque GitLab CE era desejo explícito e a máquina comporta.

### D3: GitLab Runner com kubernetes executor

Cada job do pipeline vira um pod efêmero no cluster. Consequência de design importante: o job de gate usa a **ServiceAccount do próprio pod** para consultar o status do Workflow via API do Kubernetes — sem tokens adicionais, sem expor a API do Argo. Requer um Role/RoleBinding mínimo (`get` em `workflows.argoproj.io` no namespace de CI).

### D4: Gate de secrets bloqueante antes do build

Sequência: `security-gate` → `build` → `push`. O job de gate:
1. Faz `curl` no EventSource webhook do Argo Events com payload `{repo_url, sha}` e o token de clone lido de um Secret montado no job (variável de CI mascarada)
2. O Sensor correspondente cria um Workflow a partir de um WorkflowTemplate que clona o repo (credencial `read_repository` em Secret) e roda gitleaks
3. O job faz poll (`kubectl wait`/API, intervalo ~10s, timeout ~5min) e falha se o workflow falhar — fail-closed: timeout ou erro de infra também reprova o gate

Alternativa considerada: scan assíncrono após o push. Descartada porque permitiria imagem de código comprometido no registry. O gate antes do build garante que nada contaminado é publicado.

### D5: BuildKit rootless no lugar do Kaniko (descontinuado)

Kaniko foi arquivado pelo Google em jun/2025; o fork da Chainguard não publica imagens de container. Comparado com Buildah (daemonless, build dentro do job), o BuildKit venceu por: cache nativo e persistente (PVC no `buildkitd`) — crítico para a experiência de iteração da PoC — e manutenção ativa (é o motor do `docker build`). Forma: Deployment rootless de 1 réplica no namespace `cicd` + PVC de cache; os jobs usam `docker buildx --driver remote` apontando para o Service interno. Custo aceito: mais um componente stateful; perda do PVC implica apenas rebuild frio.

### D6: Harbor no lugar do registry:2 standalone

O Harbor agrega ao tema da PoC: Trivy embutido scaneia toda imagem no push (segunda camada de segurança — gitleaks olha o código, Trivy olha o artefato), RBAC com robot account para o pipeline, UI web e emissão de webhooks. Custo: ~1-2GB RAM e mais um chart; irrelevante com 46GB disponíveis. Configurado com `scanOnPush` e robot account por projeto para o CI. Comunicação in-cluster sem TLS (tráfego nunca sai do cluster); o containerd do kind precisa de config para registry HTTP inseguro (`containerdConfigPatches` no kind config apontando para o endereço interno).

### D7: NodePort/port-forward agora, ingress depois

Acesso do host via NodePort (GitLab) e `kubectl port-forward` (Argo UI, Harbor). Ingress-nginx + `/etc/hosts` (`gitlab.local`, `harbor.local`) fica como evolução — evita uma dependência a mais durante a depuração inicial da PoC.

### D8: Roadmap pós-PoC (documentado, não implementado)

Webhook do Harbor emitido quando o scan do Trivy conclui limpo → Argo Events → workflow que assina a imagem com cosign. O desenho já prevê esse encaixe (Argo Events como barramento), mas a implementação fica fora desta change.

## Arquitetura alvo

```
HOST (Docker, kind, kubectl, helm)
 |
 |  make bootstrap / make teardown
 v
+------------------------------------------------------------------+
|  KIND CLUSTER                                                    |
|                                                                  |
|  ns: gitlab                    ns: cicd                          |
|  +--------------------------+  +------------------------------+  |
|  | GitLab CE (enxuto)       |  | Argo Workflows               |  |
|  | NodePort -> host         |  | Argo Events                  |  |
|  +--------------------------+  |  EventSource webhook         |  |
|  | GitLab Runner            |  |  Sensor -> Workflow gitleaks |  |
|  |  (kubernetes executor)   |  +------------------------------+  |
|  +-------------+------------+  | buildkitd rootless + PVC     |  |
|                | jobs como pods+------------------------------+  |
|  ns: harbor    |                     ^        |                  |
|  +-------------v------------+        | buildx | push             |
|  | Harbor + Trivy           |<-------+        v                  |
|  |  scanOnPush              |   harbor-harbor-registry:5000      |
|  +--------------------------+                                     |
+------------------------------------------------------------------+

Fluxo do pipeline:
push -> security-gate -> (webhook) Argo Events -> Workflow gitleaks
     <- poll status via ServiceAccount <-
     | aprovado                          | reprovado: pipeline morre
     v
buildx --driver remote -> buildkitd -> push Harbor -> Trivy scan (auto)
```

## Risks / Trade-offs

- [Boot lento do GitLab (vários minutos) irrita em ciclos de subir/derrubar] → Documentar no README; `make status` mostrando progresso dos pods; manter o cluster vivo entre iterações
- [GitLab enxuto ainda consome ~6-8GB e pode falhar em máquinas menores] → Documentar requisito mínimo (~16GB RAM livres); máquina alvo tem folga
- [Harbor em HTTP exige desligar validações e configurar containerd do kind] → `containerdConfigPatches` no kind config desde o início; escopo restrito a tráfego interno; TLS fica como evolução
- [Poll do gate adiciona complexidade ao `.gitlab-ci.yml`] → Encapsular o poll num script versionado no repo de plataforma; timeout e intervalo parametrizáveis
- [BuildKit rootless em kind pode esbarrar em limites de userns/fuse em alguns hosts] → Validar no início da implementação (primeira task); fallback documentado: buildah com vfs
- [Token do GitLab para clone do repo no workflow] → Secret dedicado com escopo `read_repository`, criado no bootstrap; rotação manual documentada

## Open Questions

- Versões exatas dos charts (`gitlab/gitlab`, `goharbor/harbor`, argo) e pin da imagem `moby/buildkit` — fixar na implementação
- Config do gitleaks: regras default vs `.gitleaks.toml` customizado no repositório exemplo
- Intervalo/timeout finais do poll do gate (default proposto: 10s / 5min)
