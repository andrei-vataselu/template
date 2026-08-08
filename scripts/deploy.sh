#!/usr/bin/env bash
# Zero-downtime deploy: push code, then roll the ASG (new instance healthy before old dies).
set -euo pipefail

ENV="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/environments/$ENV"

if [[ ! -d "$TF_DIR" ]]; then
  echo "Unknown env: $ENV (expected infra/environments/$ENV)" >&2
  exit 1
fi

ASG_NAME="$(cd "$TF_DIR" && terraform output -raw asg_name 2>/dev/null || true)"
REGION="$(cd "$TF_DIR" && terraform output -raw aws_region 2>/dev/null || echo eu-west-1)"

if [[ -z "$ASG_NAME" ]]; then
  echo "Could not read asg_name from $TF_DIR — apply Terraform first." >&2
  exit 1
fi

echo "Starting instance refresh on $ASG_NAME ($REGION)..."
echo "  Strategy: Rolling, MinHealthyPercentage=100 (zero downtime while max_size allows +1)"
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --preferences MinHealthyPercentage=100,InstanceWarmup=600,SkipMatching=false \
  --query 'InstanceRefreshId' \
  --output text

echo "Watch progress:"
echo "  aws autoscaling describe-instance-refreshes --auto-scaling-group-name $ASG_NAME --region $REGION"
