"""Fully automated origin-secret rotation.

Order (zero downtime with short dual-period gateway accept):
1. Write Secrets Manager {current: NEW, previous: OLD}
2. SSM Run Command → sync-origin-secret on all ASG instances (recreates gateway)
3. Update CloudFront custom headers to NEW
4. Wait until both distributions are Deployed (+ short POP buffer)
5. Clear previous to sentinel __none__ (gateways reject it as a real secret value
   once synced; cron/SSM picks this up within ~1 min)
6. Start ASG instance refreshes (non-blocking) so next boots match SM
"""

from __future__ import annotations

import json
import os
import secrets
import time

import boto3
from botocore.exceptions import ClientError

PREVIOUS_SENTINEL = "__none__"


def _parse(raw: str) -> tuple[str, str]:
    try:
        obj = json.loads(raw)
        current = obj.get("current") or ""
        previous = obj.get("previous") or current
        if current:
            return current, previous
    except Exception:
        pass
    return raw, raw


def _asg_instance_ids(asg, names: list[str]) -> list[str]:
    ids: list[str] = []
    names = [n for n in names if n]
    if not names:
        return ids
    resp = asg.describe_auto_scaling_groups(AutoScalingGroupNames=names)
    for group in resp.get("AutoScalingGroups", []):
        for inst in group.get("Instances", []):
            if inst.get("LifecycleState") == "InService" and inst.get("InstanceId"):
                ids.append(inst["InstanceId"])
    return ids


def _ssm_sync(ssm, instance_ids: list[str], timeout_s: int = 120) -> dict:
    """Run /usr/local/bin/sync-origin-secret on instances; return status summary."""
    if not instance_ids:
        return {"attempted": 0, "success": 0, "skipped": "no-instances"}

    # Only target instances that are SSM-online
    online: list[str] = []
    for i in range(0, len(instance_ids), 50):
        chunk = instance_ids[i : i + 50]
        info = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": chunk}]
        )
        for item in info.get("InstanceInformationList", []):
            if item.get("PingStatus") == "Online":
                online.append(item["InstanceId"])

    if not online:
        return {"attempted": 0, "success": 0, "skipped": "no-ssm-online"}

    cmd = ssm.send_command(
        InstanceIds=online,
        DocumentName="AWS-RunShellScript",
        TimeoutSeconds=60,
        Parameters={
            "commands": [
                "set -euo pipefail",
                "test -x /usr/local/bin/sync-origin-secret",
                "/usr/local/bin/sync-origin-secret",
            ]
        },
    )
    command_id = cmd["Command"]["CommandId"]
    deadline = time.time() + timeout_s
    success = 0
    failed = 0
    pending = set(online)
    while pending and time.time() < deadline:
        done = []
        for iid in list(pending):
            try:
                inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=iid)
            except ClientError:
                continue
            status = inv.get("Status")
            if status in ("Success",):
                success += 1
                done.append(iid)
            elif status in ("Cancelled", "TimedOut", "Failed", "Cancelling"):
                failed += 1
                done.append(iid)
        for iid in done:
            pending.discard(iid)
        if pending:
            time.sleep(3)

    return {
        "attempted": len(online),
        "success": success,
        "failed": failed,
        "pending": len(pending),
        "command_id": command_id,
    }


def _update_distribution(cf, distribution_id: str, header_name: str, header_value: str) -> None:
    if not distribution_id:
        return
    for _ in range(3):
        got = cf.get_distribution_config(Id=distribution_id)
        cfg = got["DistributionConfig"]
        etag = got["ETag"]
        for origin in cfg.get("Origins", {}).get("Items", []):
            custom = origin.setdefault("CustomHeaders", {"Quantity": 0, "Items": []})
            items = list(custom.get("Items") or [])
            found = False
            for item in items:
                if item.get("HeaderName") == header_name:
                    item["HeaderValue"] = header_value
                    found = True
                    break
            if not found:
                items.append({"HeaderName": header_name, "HeaderValue": header_value})
            custom["Items"] = items
            custom["Quantity"] = len(items)
        try:
            cf.update_distribution(Id=distribution_id, IfMatch=etag, DistributionConfig=cfg)
            return
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "PreconditionFailed":
                raise
            time.sleep(2)
    raise RuntimeError(f"failed to update CloudFront {distribution_id}")


def _wait_distributions_deployed(cf, distribution_ids: list[str], timeout_s: int = 600) -> None:
    """Block until CF edge config is Deployed — clearing previous before this causes 403s."""
    ids = [d for d in distribution_ids if d]
    if not ids:
        return
    deadline = time.time() + timeout_s
    pending = set(ids)
    while pending and time.time() < deadline:
        done = []
        for dist_id in list(pending):
            status = cf.get_distribution(Id=dist_id)["Distribution"]["Status"]
            if status == "Deployed":
                done.append(dist_id)
        for dist_id in done:
            pending.discard(dist_id)
        if pending:
            time.sleep(15)
    if pending:
        raise RuntimeError(f"CloudFront still deploying after {timeout_s}s: {sorted(pending)}")


def _start_refresh(asg, name: str) -> str | None:
    if not name:
        return None
    try:
        resp = asg.start_instance_refresh(
            AutoScalingGroupName=name,
            Strategy="Rolling",
            Preferences={
                "MinHealthyPercentage": 100,
                "InstanceWarmup": 2100,
            },
        )
        return resp.get("InstanceRefreshId")
    except ClientError as exc:
        # Already running is fine
        code = exc.response["Error"]["Code"]
        if code in ("InstanceRefreshInProgress", "ValidationError"):
            return f"skipped:{code}"
        raise


def handler(_event, _context):
    secret_arn = os.environ["ORIGIN_SECRET_ARN"]
    header_name = os.environ.get("ORIGIN_HEADER_NAME", "X-Origin-Verify")
    site_id = os.environ.get("SITE_DISTRIBUTION_ID", "")
    api_id = os.environ.get("API_DISTRIBUTION_ID", "")
    sns_topic = os.environ.get("ALERT_TOPIC_ARN", "")
    app_asg = os.environ.get("APP_ASG_NAME", "")
    web_asg = os.environ.get("WEB_ASG_NAME", "")
    sync_wait = int(os.environ.get("SYNC_FALLBACK_WAIT_SECONDS", "90"))

    sm = boto3.client("secretsmanager")
    cf = boto3.client("cloudfront")
    asg = boto3.client("autoscaling")
    ssm = boto3.client("ssm")

    raw = sm.get_secret_value(SecretId=secret_arn)["SecretString"]
    old_current, _old_prev = _parse(raw)
    new_current = secrets.token_urlsafe(32)
    payload = {"current": new_current, "previous": old_current}
    sm.put_secret_value(SecretId=secret_arn, SecretString=json.dumps(payload))

    instance_ids = _asg_instance_ids(asg, [app_asg, web_asg])
    sync_result = _ssm_sync(ssm, instance_ids)

    # If SSM could not sync (cold boot / no agent yet), wait for cron backup
    if sync_result.get("success", 0) == 0:
        time.sleep(sync_wait)

    _update_distribution(cf, site_id, header_name, new_current)
    _update_distribution(cf, api_id, header_name, new_current)

    # CF update is async — keep previous accepted until edges actually send NEW.
    # Clearing earlier left /api/info (and anything without a health bypass) on 403.
    _wait_distributions_deployed(cf, [site_id, api_id])
    # Brief buffer for POP cache convergence after Status=Deployed
    time.sleep(int(os.environ.get("CF_POP_BUFFER_SECONDS", "30")))

    # Dual-period window ends here: CloudFront only sends NEW; drop OLD so a
    # leaked previous cannot be replayed via foreign CloudFront.
    sm.put_secret_value(
        SecretId=secret_arn,
        SecretString=json.dumps({"current": new_current, "previous": PREVIOUS_SENTINEL}),
    )
    clear_sync = _ssm_sync(ssm, instance_ids, timeout_s=60)

    refreshes = {
        "app": _start_refresh(asg, app_asg),
        "web": _start_refresh(asg, web_asg),
    }

    msg = (
        f"Origin secret rotated for {os.environ.get('APP_LABEL', 'app')}.\n"
        f"SSM sync (dual): {json.dumps(sync_result)}\n"
        f"SSM sync (clear previous): {json.dumps(clear_sync)}\n"
        f"ASG refreshes started: {json.dumps(refreshes)}\n"
        "CloudFront headers updated to the new current value; previous cleared to __none__.\n"
        "No manual action required."
    )
    if sns_topic:
        boto3.client("sns").publish(
            TopicArn=sns_topic,
            Subject=f"[{os.environ.get('APP_LABEL', 'app')}] origin secret rotated (auto)",
            Message=msg,
        )

    return {
        "ok": True,
        "sync": sync_result,
        "clear_sync": clear_sync,
        "refreshes": refreshes,
        "distributions": [site_id, api_id],
    }
