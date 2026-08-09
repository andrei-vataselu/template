#!/bin/bash
# Runs on an EC2 instance via SSM. Resolves the origin secret by env / name prefix
# (no hardcoded account IDs or secret ARNs).
set -u
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
PROJECT="${PROJECT_NAME:-popo}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SECRET_ARN="${ORIGIN_SECRET_ARN:-}"

if [ -z "$SECRET_ARN" ] && [ -x /usr/local/bin/sync-origin-secret ]; then
  # Baked by user_data as SECRET_ARN="arn:..."
  SECRET_ARN=$(sed -n 's/^SECRET_ARN="\(.*\)"/\1/p' /usr/local/bin/sync-origin-secret | head -1)
fi
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" \
    --filters Key=name,Values="${PROJECT}-${ENVIRONMENT}-origin-header" \
    --query 'SecretList[0].ARN' --output text 2>/dev/null || true)
fi
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  echo "ERROR: could not resolve origin secret ARN (set ORIGIN_SECRET_ARN or PROJECT_NAME/ENVIRONMENT)" >&2
  exit 1
fi

MODE=$(grep '^GATEWAY_MODE=' /opt/template/.env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo api)
case "$MODE" in web|api|all) ;; *) MODE=api ;; esac

RAW=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query SecretString --output text)
eval "$(printf '%s' "$RAW" | python3 -c '
import json,sys,shlex
raw=sys.stdin.read().strip()
try:
    o=json.loads(raw)
    cur=o.get("current") or ""
    prev=o.get("previous") or cur
except Exception:
    cur=prev=raw
if not prev:
    prev="__none__"
print("CUR="+shlex.quote(cur))
print("PREV="+shlex.quote(prev))
')"

ENVF=/opt/template/.env
grep -vE '^ORIGIN_HEADER_VALUE=|^ORIGIN_HEADER_VALUE_PREV=' "$ENVF" > "$ENVF.tmp" || true
echo "ORIGIN_HEADER_VALUE=$CUR" >> "$ENVF.tmp"
echo "ORIGIN_HEADER_VALUE_PREV=$PREV" >> "$ENVF.tmp"
mv "$ENVF.tmp" "$ENVF"
cp "$ENVF" /opt/template/deploy/.env

mkdir -p /opt/template/deploy/gateway
if [ "$MODE" = "web" ]; then
cat >/opt/template/deploy/gateway/nginx.conf.template <<'NGX'
limit_req_zone $binary_remote_addr zone=general:10m rate=20r/s;
server {
  listen 8080;
  server_tokens off;
  set $origin_ok 0;
  if ($http_x_origin_verify = "${ORIGIN_HEADER_VALUE}") { set $origin_ok 1; }
  if ($http_x_origin_verify = "${ORIGIN_HEADER_VALUE_PREV}") { set $origin_ok 1; }
  if ($request_uri = "/healthz") { set $origin_ok 1; }
  if ($origin_ok = 0) { return 403; }
  location = /healthz {
    access_log off;
    default_type application/json;
    return 200 '{"ok":true,"service":"gateway-web"}';
  }
  location / {
    proxy_pass http://web:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
NGX
else
cat >/opt/template/deploy/gateway/nginx.conf.template <<'NGX'
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
server {
  listen 8080;
  server_tokens off;
  set $origin_ok 0;
  if ($http_x_origin_verify = "${ORIGIN_HEADER_VALUE}") { set $origin_ok 1; }
  if ($http_x_origin_verify = "${ORIGIN_HEADER_VALUE_PREV}") { set $origin_ok 1; }
  if ($request_uri = "/api/health") { set $origin_ok 1; }
  if ($request_uri = "/healthz") { set $origin_ok 1; }
  if ($origin_ok = 0) { return 403; }
  location = /healthz {
    access_log off;
    default_type application/json;
    return 200 '{"ok":true,"service":"gateway-api"}';
  }
  location /api/ {
    proxy_pass http://api:3000/api/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
  location / { return 404; }
}
NGX
fi

# Compose may select templates / templates-web / templates-api / templates-all
cat >/opt/template/deploy/gateway/Dockerfile <<'DF'
FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY nginx.conf.template /etc/nginx/templates-api/default.conf.template
COPY nginx.conf.template /etc/nginx/templates-web/default.conf.template
COPY nginx.conf.template /etc/nginx/templates-all/default.conf.template
ENV ORIGIN_HEADER_VALUE=changeme
ENV ORIGIN_HEADER_VALUE_PREV=__none__
ENV SKIP_ORIGIN_CHECK=0
EXPOSE 8080
DF

cd /opt/template/deploy
# Ensure PREV is in compose env if tip predates dual-period
if ! grep -q 'ORIGIN_HEADER_VALUE_PREV' docker-compose.yml 2>/dev/null; then
  sed -i '/ORIGIN_HEADER_VALUE:/a\      ORIGIN_HEADER_VALUE_PREV: ${ORIGIN_HEADER_VALUE_PREV:-__none__}' docker-compose.yml || true
fi

docker compose --env-file "$ENVF" up -d --build gateway
docker compose --env-file "$ENVF" up -d
sleep 4

echo "MODE=$MODE"
echo "--- curls ---"
curl -sS -m 3 -o /dev/null -w 'nohdr:%{http_code}\n' http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'healthz:%{http_code}\n' http://127.0.0.1/healthz || true
curl -sS -m 3 -o /dev/null -w 'wrong:%{http_code}\n' -H 'X-Origin-Verify: wrong' http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'current:%{http_code}\n' -H "X-Origin-Verify: $CUR" http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'previous:%{http_code}\n' -H "X-Origin-Verify: $PREV" http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'apihealth:%{http_code}\n' http://127.0.0.1/api/health || true
docker ps --format '{{.Names}} {{.Status}}'
