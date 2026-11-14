# webapp

Servidor web nginx da PoC. O fonte canonico vive no repositorio de
plataforma (`example-webapp/`). Pipeline completo:

1. `security-gate` - gitleaks via Argo (bloqueante)
2. `build` - imagem `apps/webapp:$CI_COMMIT_SHORT_SHA` no Harbor (buildx remoto)
3. `chart` - bump de versao + publish do chart (com a nova tag) no ChartMuseum
4. `gitops` - commit da nova versao em root/gitops; o ArgoCD detecta e deploya

O chart (`chart/webapp/`) tem liveness e readiness HTTP GET / na porta 80.
