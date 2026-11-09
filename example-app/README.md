# demo-app

Aplicacao exemplo da PoC de SDLC seguro local. O fonte canônico destes
arquivos vive no repositorio de plataforma (`example-app/` do stack_sdlc);
este repositorio e recriado/sincronizado pelo bootstrap.

Pipeline (`.gitlab-ci.yml`):

1. `security-gate` - dispara o webhook do Argo Events e faz poll do
   Workflow gitleaks (intervalo 10s, timeout 5min, fail-closed)
2. `build` - build via `docker buildx --driver remote` no buildkitd
3. `push` - publica `harbor.harbor.svc.cluster.local/apps/demo-app:$CI_COMMIT_SHORT_SHA`

O push dispara o scan Trivy automatico no Harbor.
