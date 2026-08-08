# Cost predictability

Know next month’s bill within a few dollars. Pay more only when **you** change a tfvars knob — never because traffic triggered autoscaling.

| | Dev | Prod |
|---|---|---|
| **Expected** | **~$52–55 / mo** | **~$110+ / mo** |
| **Budget alert** | $55 | $120 |
| **Grade** | **9 / 10** | **9 / 10** |

Raw line items: [`infra/COST_GATE.txt`](infra/COST_GATE.txt)  
**Companion docs:** [`README.md`](README.md) · [`CHECKLIST.md`](CHECKLIST.md) · [`SECURITY_CHECK.md`](SECURITY_CHECK.md)

---

## Your progress

| | Item |
|---|---|
| ✅ | Cost allocation tags `Application` + `Environment` → **Active** |
| ✅ | Alert email set (`andreivataselu42@gmail.com`) for budgets / SNS |
| ✅ | Dev/prod backends + tfvars prepared; prod GitHub approval on |
| ⬜ | Confirm SNS subscription emails after first apply |
| ⬜ | Apply **dev** then attach CloudFront **Free** flat-rate plan |
| ⬜ | Do not create **prod** until needed (~$110+/mo) |

Tag activation can take up to ~24h before Cost Explorer / budgets filter on them. You do **not** need to wait to keep applying Terraform.

---

## 1. Why the bill is predictable

| Design choice | Effect |
|---|---|
| Fixed instance types (`t4g.micro` / `t4g.small`) | No surprise families |
| ASG `desired` in tfvars; **no CPU target-tracking** | Scale = deliberate apply |
| `asg_max_size` hard cap (dev=2, prod=3) | Cannot runaway-scale |
| No NAT gateway | Avoids ~$32+/mo + data fees |
| CloudFront Free/Pro **flat-rate** (attach in console) | Edge cost capped |
| RDS fixed storage (no `max_allocated_storage`) | Disk cannot silently grow |
| CW logs 14d + Docker log rotate 10MB×3 | Logs stay bounded |
| Budgets + anomaly detection + SNS | Warns (does not hard-stop spend) |

AWS Budgets lag 8–12h.

---

## 2. Monthly breakdown

### Account (`infra/global`) — ~$1.50–5.50/mo
| Item | ~/mo |
|---|---|
| State + CloudTrail S3 | ~$0–1 |
| Route 53 hosted zone | $0.50 |
| GuardDuty | ~$1–4 (`enable_guardduty = false` to skip) |

### Dev (desired=1) — ~$52–55/mo
| Item | ~/mo |
|---|---|
| CloudFront Free flat-rate | $0 |
| ALB | ~$16.20 |
| ALB public IPv4 (2 AZs) | ~$7.30 |
| EC2 `t4g.micro` + public IPv4 + 30 GB EBS | ~$12.60 |
| RDS `db.t4g.micro` + 20 GB | ~$14 |
| Secrets / CW / Cognito | ~$2–3 |

Rolling deploy briefly runs 2 instances → pennies, not dollars.

### Prod (desired=1) — ~$110+/mo
CloudFront Pro $15 · ALB+IPs ~$24 · EC2 small ~$20 · RDS Multi-AZ ~$48 · misc ~$5

---

## 3. What changes the bill

| You change | Impact |
|---|---|
| `asg_desired_capacity` +1 | Dev ~+$13/mo; prod ~+$20/mo |
| Larger `instance_type` / `db_instance_class` | Step change — read COST_GATE first |
| Create **prod** stack while unused | Full ~$110 |
| `enable_guardduty = false` | −$1–4 |

Traffic alone does **not** add ASG instances.

---

## 4. Pipeline

GitHub Actions applies the **same** fixed-size modules. No autoscaling policies are introduced by CI. Keep prod apply behind a GitHub Environment approval ([CHECKLIST §G](CHECKLIST.md)).
