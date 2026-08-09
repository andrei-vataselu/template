#!/usr/bin/env bash
# Shared ASG rolling refresh that preserves zero downtime.
# Usage: asg-roll.sh <asg-name> <aws-region> [target-group-name]
set -euo pipefail

ASG="${1:?asg name}"
REGION="${2:?region}"
TG_NAME="${3:-}"

echo "Target ASG=$ASG region=$REGION"

# NEVER cancel an in-progress refresh — that terminates the old healthy
# instance before the new one is ready and causes 502 downtime.
for i in $(seq 1 180); do
  CUR=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" \
    --region "$REGION" \
    --max-records 1 \
    --query 'InstanceRefreshes[0].Status' --output text 2>/dev/null || echo "None")
  case "$CUR" in
    InProgress|Pending|Cancelling)
      echo "  wait $i: prior refresh still $CUR (preserving zero-downtime)"
      sleep 20
      ;;
    *)
      echo "  clear to start (last status=$CUR)"
      break
      ;;
  esac
done

# InstanceWarmup must exceed cold-boot docker builds on t4g.micro (~15–25m).
# ASG ELB grace can treat a booting instance as healthy before /api/health works;
# short warmup then kills the old healthy box → 502.
REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG" \
  --region "$REGION" \
  --preferences MinHealthyPercentage=100,InstanceWarmup=2100,SkipMatching=false \
  --query InstanceRefreshId --output text)
echo "InstanceRefreshId=$REFRESH_ID"

TG_ARN=""
if [[ -n "$TG_NAME" ]]; then
  TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
fi

# Wait until refresh finishes AND at least one TG target is healthy.
for i in $(seq 1 240); do
  STATUS=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" \
    --region "$REGION" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].Status' --output text)
  PCT=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" \
    --region "$REGION" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].PercentageComplete' --output text)
  REASON=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" \
    --region "$REGION" \
    --instance-refresh-ids "$REFRESH_ID" \
    --query 'InstanceRefreshes[0].StatusReason' --output text 2>/dev/null || echo "")

  HEALTHY="n/a"
  if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
    HEALTHY=$(aws elbv2 describe-target-health \
      --target-group-arn "$TG_ARN" \
      --region "$REGION" \
      --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  fi

  echo "  wait $i: refresh=$STATUS pct=$PCT tg_healthy=$HEALTHY ${REASON:+reason=$REASON}"

  case "$STATUS" in
    Successful)
      if [[ -z "$TG_ARN" || "$TG_ARN" == "None" || "$HEALTHY" -ge 1 ]]; then
        echo "Roll complete with healthy target(s)."
        exit 0
      fi
      echo "  refresh done but TG not healthy yet; waiting..."
      ;;
    Failed|Cancelled|RollbackFailed|RollbackSuccessful)
      echo "Instance refresh ended with status=$STATUS" >&2
      exit 1
      ;;
  esac
  sleep 20
done

echo "Timed out waiting for instance refresh $REFRESH_ID" >&2
exit 1
