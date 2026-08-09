#!/bin/bash
# Runs on an EC2 instance via SSM. Resolves the origin secret by env / name prefix
# (no hardcoded account IDs or secret ARNs).
set -u
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
PROJECT="${PROJECT_NAME:-popo}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SECRET_ARN="${ORIGIN_SECRET_ARN:-}"

if [ -z "$SECRET_ARN" ] && [ -x /usr/local/bin/sync-origin-secret ]; then
  # Baked by user_data: SECRET_ARN="arn:..."
  SECRET_ARN=$(sed -n 's/^SECRET_ARN="\(.*\)"/\1/p' /usr/local/bin/sync-origin-secret | head -1)
fi
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" \
    --filters Key=name,Values="${PROJECT}-${ENVIRONMENT}-origin-header" \
    --query 'SecretList[0].ARN' --output text)
fi
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  echo "ERROR: could not resolve origin secret ARN (set ORIGIN_SECRET_ARN or PROJECT_NAME/ENVIRONMENT)" >&2
  exit 1
fi

if [ -x /usr/local/bin/sync-origin-secret ]; then
  /usr/local/bin/sync-origin-secret || echo "sync-origin-secret exited $?"
fi

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
if [ -f "$ENVF" ]; then
  grep -v '^ORIGIN_HEADER_VALUE' "$ENVF" > "$ENVF.tmp" || true
  echo "ORIGIN_HEADER_VALUE=$CUR" >> "$ENVF.tmp"
  echo "ORIGIN_HEADER_VALUE_PREV=$PREV" >> "$ENVF.tmp"
  mv "$ENVF.tmp" "$ENVF"
  cp "$ENVF" /opt/template/deploy/.env 2>/dev/null || true
  cd /opt/template/deploy
  docker compose --env-file "$ENVF" up -d gateway --force-recreate --no-deps
  sleep 4
fi

echo "--- curls ---"
curl -sS -m 3 -o /dev/null -w 'nohdr:%{http_code}\n' http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'healthz:%{http_code}\n' http://127.0.0.1/healthz || true
curl -sS -m 3 -o /dev/null -w 'wrong:%{http_code}\n' -H 'X-Origin-Verify: wrong' http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'current:%{http_code}\n' -H "X-Origin-Verify: $CUR" http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'previous:%{http_code}\n' -H "X-Origin-Verify: $PREV" http://127.0.0.1/ || true
curl -sS -m 3 -o /dev/null -w 'apihealth:%{http_code}\n' http://127.0.0.1/api/health || true
hostname
grep GATEWAY_MODE /opt/template/.env || true
docker ps --format '{{.Names}} {{.Status}}' || true
