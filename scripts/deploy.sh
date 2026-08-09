#!/usr/bin/env bash
# Zero-downtime deploy: pin app git SHA in SSM, then roll the ASG (new instance healthy before old dies).
# Usage: deploy.sh [env] [api|web|all]   (default: dev api)
set -euo pipefail

ENV="${1:-dev}"
COMPONENT="${2:-api}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/environments/$ENV"
PROJECT_NAME="${PROJECT_NAME:-popo}"

if [[ ! -d "$TF_DIR" ]]; then
  echo "Unknown env: $ENV (expected infra/environments/$ENV)" >&2
  exit 1
fi

REGION="$(cd "$TF_DIR" && terraform output -raw aws_region 2>/dev/null || echo eu-west-1)"
GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"

# user_data reads this at boot (H3). Deploy workflows do the same before ASG rolls.
echo "Pinning app git SHA $GIT_SHA -> /$PROJECT_NAME/$ENV/app-git-sha"
aws ssm put-parameter \
  --name "/$PROJECT_NAME/$ENV/app-git-sha" \
  --value "$GIT_SHA" \
  --type String \
  --overwrite \
  --region "$REGION" >/dev/null

roll() {
  local asg="$1"
  if [[ -z "$asg" ]]; then
    echo "Could not read ASG name from $TF_DIR — apply Terraform first." >&2
    exit 1
  fi
  echo "Starting instance refresh on $asg ($REGION)..."
  echo "  Strategy: Rolling, MinHealthyPercentage=100 (zero downtime while max_size allows +1)"
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$asg" \
    --region "$REGION" \
    --preferences MinHealthyPercentage=100,InstanceWarmup=600,SkipMatching=false \
    --query 'InstanceRefreshId' \
    --output text
  echo "Watch progress:"
  echo "  aws autoscaling describe-instance-refreshes --auto-scaling-group-name $asg --region $REGION"
}

API_ASG="$(cd "$TF_DIR" && terraform output -raw asg_name 2>/dev/null || true)"
WEB_ASG="$(cd "$TF_DIR" && terraform output -raw web_asg_name 2>/dev/null || true)"

case "$COMPONENT" in
  api) roll "$API_ASG" ;;
  web) roll "$WEB_ASG" ;;
  all)
    roll "$API_ASG"
    roll "$WEB_ASG"
    ;;
  *)
    echo "Unknown component: $COMPONENT (expected api|web|all)" >&2
    exit 1
    ;;
esac
