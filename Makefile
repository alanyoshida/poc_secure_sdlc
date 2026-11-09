CLUSTER_NAME := poc-secure-sdlc
NODE := $(CLUSTER_NAME)-control-plane

.PHONY: bootstrap teardown cluster node-hosts status urls

## Sobe o ambiente completo (idempotente)
bootstrap: cluster
	./scripts/bootstrap.sh

## Cria o cluster kind se nao existir
cluster:
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "==> Cluster '$(CLUSTER_NAME)' ja existe, pulando criacao"; \
	else \
		kind create cluster --config kind.yaml; \
	fi
	@kubectl wait --for=condition=Ready node/$(NODE) --timeout=180s

## Destroi o ambiente completamente
teardown:
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		kind delete cluster --name $(CLUSTER_NAME); \
	else \
		echo "==> Cluster '$(CLUSTER_NAME)' nao existe, nada a fazer"; \
	fi

## Mapeia os FQDNs do Harbor no /etc/hosts do no (containerd nao usa CoreDNS)
## harbor: endpoint nginx de push/pull; harbor-core: realm do token de auth
## Uso: make node-hosts (apos instalar o Harbor)
node-hosts:
	@HARBOR_IP=$$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	CORE_IP=$$(kubectl get svc harbor-core -n harbor -o jsonpath='{.spec.clusterIP}' 2>/dev/null); \
	if [ -z "$$HARBOR_IP" ] || [ -z "$$CORE_IP" ]; then echo "==> Services do Harbor nao encontrados (Harbor instalado?)"; exit 1; fi; \
	docker exec $(NODE) sh -c "grep -v 'harbor.*.harbor.svc.cluster.local' /etc/hosts > /tmp/hosts.tmp; cat /tmp/hosts.tmp > /etc/hosts; echo '$$HARBOR_IP harbor.harbor.svc.cluster.local' >> /etc/hosts; echo '$$CORE_IP harbor-core.harbor.svc.cluster.local' >> /etc/hosts"; \
	echo "==> No $(NODE):"; \
	echo "    harbor.harbor.svc.cluster.local      -> $$HARBOR_IP"; \
	echo "    harbor-core.harbor.svc.cluster.local -> $$CORE_IP"

## Panorama do ambiente
status:
	@kubectl get nodes
	@echo
	@kubectl get pods -A --field-selector=status.phase!=Succeeded 2>/dev/null | grep -v Completed || true

## URLs de acesso a partir do host (IP do no kind + NodePorts)
urls:
	@NODE_IP=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(NODE)); \
	GL_PORT=$$(kubectl get svc gitlab-webservice-default -n gitlab -o jsonpath='{.spec.ports[?(@.port==8181)].nodePort}' 2>/dev/null); \
	H_PORT=$$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null); \
	echo "GitLab:  http://$$NODE_IP:$$GL_PORT  (root / senha: kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d)"; \
	echo "Harbor:  http://$$NODE_IP:$$H_PORT  (admin / Harbor12345)"; \
	echo "Argo UI: kubectl -n cicd port-forward svc/argo-workflows-server 2746:2746"
