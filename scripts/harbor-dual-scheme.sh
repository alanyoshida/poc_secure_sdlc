#!/usr/bin/env bash
# Harbor com TLS habilitado (change image-signing-enforcement, ver
# helm/harbor-values.yaml) ganha, por padrao do chart, um redirect fixo
# 301 http->https na porta 8080 sem nenhum value que desative isso - o
# que quebraria build/push/pull/cosign sign, que continuam falando HTTP
# puro deliberadamente (so o Kyverno precisa de HTTPS, ver design.md D5
# da change). Este script reescreve o ConfigMap harbor-nginx trocando
# esse bloco de redirect pelo proxy_pass normal (copiado do template
# "configmap-http.yaml" do chart, usado quando TLS esta desligado),
# restaurando as duas portas (8080 HTTP pleno + 8443 HTTPS) funcionando
# em paralelo. Idempotente: sai sem fazer nada se o proxy_pass ja esta
# presente. Precisa ser reaplicado depois de toda `helm upgrade harbor`
# (o template do chart sempre gera o redirect; chamado pelo bootstrap).
set -euo pipefail

python3 - <<'PYEOF'
import subprocess
import sys

NS = "harbor"
CM = "harbor-nginx"

current = subprocess.run(
    ["kubectl", "get", "cm", CM, "-n", NS, "-o", "jsonpath={.data['nginx\\.conf']}"],
    capture_output=True, text=True, check=True,
).stdout

OLD_BLOCK = """    server {
      listen 8080;
      listen [::]:8080;
      #server_name harbordomain.com;
      return 301 https://$host$request_uri;
  }
}"""

NEW_BLOCK = """  server {
    listen 8080;
    listen [::]:8080;
    server_tokens off;
    client_max_body_size 0;
    add_header X-Frame-Options DENY;
    add_header Content-Security-Policy "frame-ancestors 'none'";

    location / {
      proxy_pass http://portal/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /api/ {
      proxy_pass http://core/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /c/ {
      proxy_pass http://core/c/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /v1/ {
      return 404;
    }

    location /v2/ {
      proxy_pass http://core/v2/;
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_send_timeout 900;
      proxy_read_timeout 900;
    }

    location /service/ {
      proxy_pass http://core/service/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $x_forwarded_proto;
      proxy_buffering off;
      proxy_request_buffering off;
    }

    location /service/notifications {
      return 404;
    }
  }
}"""

if "return 301 https" not in current:
    print("harbor-nginx: porta 8080 ja fala HTTP pleno, nada a fazer")
    sys.exit(0)

if OLD_BLOCK not in current:
    print("harbor-nginx: bloco de redirect esperado nao encontrado - verifique o template do chart manualmente")
    sys.exit(1)

new_conf = current.replace(OLD_BLOCK, NEW_BLOCK)

patch = {"data": {"nginx.conf": new_conf}}
import json
subprocess.run(
    ["kubectl", "patch", "cm", CM, "-n", NS, "--type=merge", "-p", json.dumps(patch)],
    check=True,
)
subprocess.run(["kubectl", "rollout", "restart", "deploy/harbor-nginx", "-n", NS], check=True)
subprocess.run(["kubectl", "rollout", "status", "deploy/harbor-nginx", "-n", NS, "--timeout=120s"], check=True)
print("harbor-nginx: porta 8080 restaurada para HTTP pleno (8443 continua TLS)")
PYEOF
