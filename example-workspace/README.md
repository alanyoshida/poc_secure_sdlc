# agent-workspace

Repositorio de trabalho do agente kanban. O fonte canonico deste seed vive
no repositorio de plataforma (`example-workspace/` do stack_sdlc).

Pipeline: security-gate (gitleaks via Argo) -> build (buildx remoto) ->
push (`harbor.harbor.svc.cluster.local/apps/agent-workspace:$CI_COMMIT_SHORT_SHA`).
O push dispara o scan Trivy automatico.
