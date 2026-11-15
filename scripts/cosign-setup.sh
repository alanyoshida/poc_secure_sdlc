#!/usr/bin/env bash
# Par de chaves cosign para assinatura de imagens (change image-signing-enforcement).
# Gerado dentro do cluster via Job com a imagem oficial do cosign (evita
# baixar/executar binario no host) usando o provider k8s:// do cosign, que
# grava a chave privada/publica/senha direto como Secret - nunca toca disco
# no host. Idempotente: reutiliza o Secret se ja existir.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=cicd
SECRET_NAME=cosign-key-pair
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v2.4.1"
JOB_NAME=cosign-keygen-setup

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "$SECRET_NAME: reutilizando par de chaves existente"
  exit 0
fi

echo "$SECRET_NAME: gerando par de chaves via Job no cluster"

kubectl create serviceaccount cosign-setup -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cosign-setup
  namespace: $NAMESPACE
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cosign-setup
  namespace: $NAMESPACE
subjects:
  - kind: ServiceAccount
    name: cosign-setup
    namespace: $NAMESPACE
roleRef:
  kind: Role
  name: cosign-setup
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: cosign-setup
      restartPolicy: Never
      containers:
        - name: cosign
          image: $COSIGN_IMAGE
          env:
            - name: COSIGN_PASSWORD
              value: ""
          command: ["cosign", "generate-key-pair", "k8s://$NAMESPACE/$SECRET_NAME"]
EOF

kubectl wait --for=condition=complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout=120s

kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' | python3 -c "
import sys, json
keys = sorted(json.load(sys.stdin).keys())
expected = ['cosign.key', 'cosign.password', 'cosign.pub']
assert keys == expected, f'chaves inesperadas no Secret: {keys}'
print('Secret OK, chaves:', keys)
"

kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl delete rolebinding cosign-setup -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl delete role cosign-setup -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl delete serviceaccount cosign-setup -n "$NAMESPACE" --ignore-not-found >/dev/null

echo "$SECRET_NAME: par de chaves criado"
