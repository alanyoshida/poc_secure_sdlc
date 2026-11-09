#!/usr/bin/env bash
# Gera a variante da imagem do buildkitd com newuidmap/newgidmap setuid
# (root-owned) dentro do filesystem da imagem, via crane append, e envia
# ao Harbor. O rootlesskit do buildkitd exige newuidmap setuid para montar
# o mapa multi-faixa de subuids; volumes k8s sao nosuid, entao o ajuste
# precisa estar na imagem. Ver manifests/cicd/buildkitd.yaml e README.
# Idempotente: pula se a tag ja existe no Harbor.
set -euo pipefail
cd "$(dirname "$0")/.."

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' poc-secure-sdlc-control-plane)
API="http://$NODE_IP:30002/api/v2.0"
AUTH="admin:Harbor12345"
IMAGE_TAG="v0.34.2-rootless-idtools"

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" \
  "$API/projects/apps/repositories/buildkitd/artifacts/$IMAGE_TAG" 2>/dev/null || echo 000)
if [ "$HTTP" = "200" ]; then
  echo "imagem apps/buildkitd:$IMAGE_TAG ja existe no Harbor, pulando"
  exit 0
fi
[ "$HTTP" = "404" ] || { echo "resposta inesperada da API do Harbor (HTTP $HTTP)"; exit 1; }

echo "gerando apps/buildkitd:$IMAGE_TAG (crane append com camada setuid)"
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: buildkit-image-patch
  namespace: cicd
spec:
  restartPolicy: Never
  initContainers:
  - name: make-layer
    image: moby/buildkit:v0.34.2-rootless
    command: ["sh","-c"]
    args:
    - |
      set -e
      mkdir -p /out/layer/usr/bin
      cp /usr/bin/newuidmap /out/layer/usr/bin/newuidmap
      cp /usr/bin/newgidmap /out/layer/usr/bin/newgidmap
      chown 0:0 /out/layer/usr/bin/newuidmap /out/layer/usr/bin/newgidmap
      chmod 4755 /out/layer/usr/bin/newuidmap /out/layer/usr/bin/newgidmap
      tar -C /out/layer -cf /out/layer.tar usr
      echo LAYER_OK
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: work
      mountPath: /out
  - name: crane-append
    image: gcr.io/go-containerregistry/crane:debug
    command: ["sh","-c"]
    args:
    - |
      set -e
      U=$(cat /creds/username); P=$(cat /creds/password)
      crane auth login --insecure harbor.harbor.svc.cluster.local -u "$U" -p "$P"
      crane append --insecure \
        -b docker.io/moby/buildkit:v0.34.2-rootless \
        -f /out/layer.tar \
        -t harbor.harbor.svc.cluster.local/apps/buildkitd:v0.34.2-rootless-idtools \
        --platform linux/amd64
      echo PUSH_OK
    env:
    - name: HOME
      value: /tmp
    volumeMounts:
    - name: work
      mountPath: /out
    - name: creds
      mountPath: /creds
      readOnly: true
  containers:
  - name: done
    image: busybox:1.36
    command: ["sh","-c","echo PATCH_DONE"]
    volumeMounts:
    - name: work
      mountPath: /out
  volumes:
  - name: work
    persistentVolumeClaim:
      claimName: buildkitd-cache
  - name: creds
    secret:
      secretName: harbor-robot
      items:
      - key: username
        path: username
      - key: password
        path: password
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/buildkit-image-patch -n cicd --timeout=10m
kubectl logs buildkit-image-patch -n cicd -c crane-append 2>&1 | tail -2
kubectl delete pod buildkit-image-patch -n cicd --wait=true >/dev/null 2>&1
echo "imagem apps/buildkitd:$IMAGE_TAG publicada"
