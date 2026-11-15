# Tasks

## 1. Chave cosign e RBAC

- [x] 1.1 Criar `scripts/cosign-setup.sh` (idempotente, chamado pelo bootstrap): gera o par de chaves com `cosign generate-key-pair k8s://cicd/cosign-key-pair` se o Secret `cosign-key-pair` ainda não existir; verificar que o Secret existe com as chaves `cosign.key`/`cosign.pub`/`cosign.password`
- [x] 1.2 Criar o `Role`/`RoleBinding` no namespace `cicd` concedendo `get` apenas no Secret `cosign-key-pair` ao ServiceAccount `gitlab-runner-job`; verificar com `kubectl auth can-i get secret/cosign-key-pair --as=system:serviceaccount:cicd:gitlab-runner-job -n cicd` retornando `yes`, e que nenhum outro Secret do namespace fica acessível a esse ServiceAccount

## 2. Kyverno instalado (sem policy ainda)

- [x] 2.1 Instalar o Kyverno (`helm/kyverno-values.yaml`, chart `kyverno/kyverno` versão fixada 3.9.2/v1.19.2 — ver D5 do design, namespace `kyverno`, só admission-controller habilitado) e aplicar; verificar os pods do Kyverno Ready
- [x] 2.2 Documentado no README: tabela Stack (chart 3.9.2 / Kyverno v1.19.2) e seção "Assinatura de imagens" (namespace `kyverno`, escopo da policy)

## 3. Estágio de assinatura nos pipelines

- [x] 3.1 Adicionar o estágio `sign` em `example-app/.gitlab-ci.yml` (após `push`), executando `cosign sign --key k8s://cicd/cosign-key-pair --allow-http-registry --tlog-upload=false --yes "$HARBOR_REGISTRY/apps/demo-app:$CI_COMMIT_SHORT_SHA"` em `alpine:3.20` com `apk add cosign`; verificado rodando o pipeline (job `sign` com sucesso, sem contato com o Rekor público)
- [x] 3.2 Adicionar o estágio `sign` em `example-webapp/.gitlab-ci.yml` (entre `build` e `chart`, mesmo padrão do demo-app) assinando `$HARBOR_REGISTRY/apps/webapp:$CI_COMMIT_SHORT_SHA`; verificado rodando o pipeline da webapp com sucesso (todos os 5 estágios)
- [x] 3.3 Verificar na UI do Harbor (ou via `GET /api/v2.0/projects/apps/repositories/.../artifacts/.../accessories`) que a tag recém-publicada de `apps/demo-app` e de `apps/webapp` aparece com a assinatura cosign associada

## 4. Deploy assinado via GitOps antes do enforcement

- [x] 4.1 Disparar um push na webapp (nova versão) com o estágio `sign` já ativo e verificar o fluxo completo: chart publicado, commit no repo GitOps, ArgoCD sincroniza, pod novo fica Ready no namespace `webapps` rodando a imagem assinada — **antes** de aplicar a `ClusterPolicy` da task 5

## 5. Enforcement via Kyverno

- [x] 5.1 Criar `manifests/cosign-verify-policy.yaml` (`ClusterPolicy` com regra `verifyImages`, `match.any[].resources.namespaces: ["webapps"]`, imagens `harbor.harbor.svc.cluster.local/apps/*`, chave pública via `attestors[].entries[].keys.publicKeys: "k8s://cicd/cosign-key-pair"`, RBAC do admission-controller para ler esse Secret) e aplicar; Kyverno fixado em 3.9.2/v1.19.2 (3.10.0/v1.20.0 removeu a execução de `ClusterPolicy` legada para `verifyImages`); verificado `kubectl get clusterpolicy` com `READY: True`
- [x] 5.2 Verificar cenário positivo: pod de teste em `webapps` com `apps/webapp:<tag-assinada>` admitido (imagem reescrita por digest via `mutateDigest`); o rollout real do ArgoCD com a mesma imagem também passou
- [x] 5.3 Verificar cenário negativo: pod em `webapps` com `apps/webapp:<tag-anterior-a-assinatura>` (imagem do mesmo path, sem assinatura — `alpine:3.20` não serve de teste porque nem casa com `imageReferences`) rejeitado com `no signatures found` visível no erro
- [x] 5.4 Verificar que outros namespaces não são afetados: a mesma imagem não assinada foi admitida sem problema em `cicd`; pods de `cicd`/`gitlab`/`harbor`/`argocd` seguem `Running` normalmente

## 6. Bootstrap e documentação

- [x] 6.1 Incorporado ao `scripts/bootstrap.sh` (steps 9/13 e 10/13): além de cosign+Kyverno+policy, também as peças do `gitops-deploy` que nunca tinham sido de fato incorporadas (ArgoCD, ChartMuseum, `webapp-setup.sh`, `argocd-root-app.yaml` — achado durante esta implementação, corrigido junto por decisão do usuário); Harbor ganhou `harbor-dual-scheme.sh` no step 5. Reaplicação em sequência contra o cluster já provisionado não duplicou Secret/RBAC/recursos (só o helm bump de revision, esperado); corrigido um bug real de idempotência: `helm upgrade kyverno` falhava na 2ª execução porque o chart bloqueia upgrade com `ClusterPolicy` legada já existente — `--set upgrade.acknowledgeLegacyPoliciesNotEnforced=true`
- [x] 6.2 Documentado no README: seção "Assinatura de imagens (cosign) e enforcement (Kyverno)" (o que é assinado, como ver no Harbor, escopo em `webapps`, como diagnosticar rejeição, dependência do Rekor e do TLS dual-scheme) + seção "Entrega contínua GitOps" (gap do `gitops-deploy` nunca documentado, corrigido junto) + Stack/Acessos/Notas de implementação atualizados + `docs/ROADMAP.md` item 1 marcado como implementado

## Workflow follow-up

- Arquivar a change após revisão e implementação (spec sincroniza para `openspec/specs/`).
