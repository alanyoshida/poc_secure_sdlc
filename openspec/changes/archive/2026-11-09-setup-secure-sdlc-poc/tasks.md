# Tasks

## 1. Bootstrap do cluster kind

- [x] 1.1 Criar `kind.yaml` (config do cluster com `containerdConfigPatches` para registry HTTP interno do Harbor) e verificar que `kind create cluster --config kind.yaml` sobe o cluster e `kubectl get nodes` reporta Ready
- [x] 1.2 Criar `Makefile` com targets `bootstrap` e `teardown` e verificar que `make teardown` remove o cluster (`kind get clusters` vazio) e `make bootstrap` o recria do zero

## 2. GitLab CE + Runner

- [x] 2.1 Adicionar values enxutos do chart `gitlab/gitlab` (sem Prometheus/Grafana/KAS, 1 réplica, minio, sem registry embutido, serviço NodePort) em `helm/gitlab-values.yaml` e instalar; verificar com `kubectl get pods -n gitlab` que não há pods de prometheus/grafana/kas e que o webservice fica Ready
- [x] 2.2 Expor o GitLab via NodePort e verificar no navegador do host que a tela de login responde na porta configurada
- [x] 2.3 Registrar o GitLab Runner (kubernetes executor, namespace `cicd`, ServiceAccount com Role `get/list` em `workflows.argoproj.io`) e verificar na UI do GitLab (Admin > Runners) que o runner aparece online; rodar um pipeline trivial (`echo ok`) e confirmar que o job executa como pod no cluster
- [x] 2.4 Criar o token `read_repository` e o Secret correspondente no namespace `cicd`; verificar com um clone de teste dentro de um pod que a credencial funciona e não aparece nos logs

## 3. Harbor

- [x] 3.1 Adicionar values do chart `goharbor/harbor` (Trivy habilitado, scanOnPush, exposição NodePort, sem TLS no escopo da PoC) em `helm/harbor-values.yaml` e instalar; verificar `kubectl get pods -n harbor` saudáveis e login na UI via navegador do host
- [x] 3.2 Criar projeto e robot account para o pipeline via UI/API e verificar push/pull autenticado de uma imagem de teste com `docker`/`crictl` usando a robot account
- [x] 3.3 Verificar que o push da imagem de teste dispara scan automático do Trivy e que o resultado por severidade aparece na UI da tag

## 4. Argo Workflows + Events (gate de secrets)

- [x] 4.1 Instalar Argo Workflows e Argo Events (namespace `cicd`); verificar UI do Argo acessível via `kubectl port-forward` e `argo list` funcional
- [x] 4.2 Criar WorkflowTemplate do gitleaks (clone do repo no SHA informado usando o Secret da task 2.4, scan com regras default) e verificar com `argo submit --watch` contra um repo limpo que o workflow conclui com sucesso
- [x] 4.3 Criar EventSource (webhook) e Sensor que instanciam o WorkflowTemplate a partir do payload `{repo_url, sha}`; verificar com `curl` no endpoint do EventSource que um Workflow é criado com os parâmetros corretos
- [x] 4.4 Testar o caminho negativo: commitar um secret falso num repo de teste, disparar o webhook e verificar que o Workflow falha

## 5. BuildKit rootless

- [x] 5.1 Criar Deployment rootless do `moby/buildkit` com PVC de cache e Service interno no namespace `cicd`; verificar que o pod fica Ready sem `privileged` e que `buildctl --addr tcp://<service> debug workers` responde
- [x] 5.2 Validar build remoto a partir de um pod cliente com `docker buildx --driver remote`: build de um Dockerfile de exemplo e push no Harbor com a robot account; verificar imagem visível na UI do Harbor
- [x] 5.3 Verificar cache: rodar o mesmo build uma segunda vez sem alterações e confirmar reutilização de camadas (`CACHED` nos logs / tempo reduzido); documentar o fallback (buildah com vfs) no README se o modo rootless falhar no host

## 6. Pipeline de exemplo ponta a ponta

- [x] 6.1 Criar repositório de aplicação exemplo no GitLab (app mínima + Dockerfile) e `.gitlab-ci.yml` com stages `security-gate` → `build` (buildx remote) → `push`, incluindo o script de poll do gate (intervalo 10s, timeout 5min, fail-closed); verificar num push com código limpo que o pipeline completo passa e a imagem tagueada com o SHA aparece no Harbor
- [x] 6.2 Verificar o gate bloqueante: push com secret falso e confirmar que o pipeline morre no `security-gate`, o job de build não executa e nenhuma imagem nova aparece no Harbor
- [x] 6.3 Verificar que o scan do Trivy roda automaticamente na imagem publicada pelo pipeline e que um pod de teste no cluster consegue usar a imagem (pull interno)

## 7. Documentação e verificação final

- [x] 7.1 Escrever README do ambiente (requisitos: ~16GB RAM livres, Docker/kind/kubectl/helm; comandos `make bootstrap`/`make teardown`; endereços e credenciais de acesso; diagrama do fluxo) e verificar que cada comando documentado executa como escrito
- [x] 7.2 Documentar o roadmap pós-PoC (webhook do Trivy → Argo Events → assinatura cosign; ingress-nginx) no README ou doc dedicada
- [x] 7.3 Executar teardown + bootstrap do zero e repetir o pipeline ponta a ponta (push limpo passa, push com secret falha) para validar reprodutibilidade completa do ambiente

## Workflow follow-up

- Arquivar a change após revisão dos artefatos e da implementação.
- Verificar o resultado arquivado (specs sincronizados em `openspec/specs/`).
