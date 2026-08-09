# Cost predictability

Know next month’s bill within a few dollars. Pay more only when **you** change a tfvars knob — never because traffic triggered autoscaling.

| | Dev | Prod |
|---|---|---|
| **Expected** | **~$92–96 / mo** | **~$157–172 / mo** |
| **Budget alert** | $100 | $175 |
| **Grade** | **9 / 10** | **9 / 10** |

Raw line items: [`infra/COST_GATE.txt`](infra/COST_GATE.txt)  
See also [`README.md`](README.md) · [`CHECKLIST.md`](CHECKLIST.md) · [`SECURITY_CHECK.md`](SECURITY_CHECK.md).

---

## 1. Why the bill is predictable

| Design choice | Effect |
|---|---|
| Fixed instance types | No surprise families |
| ASG `desired` in tfvars; **no CPU target-tracking** | Scale = deliberate apply |
| `asg_max_size` / `web_asg_max_size` hard caps | Cannot runaway-scale |
| **1× NAT Gateway** (single AZ) | Fixed ~$32/mo; private EC2 (no public IPs) |
| CloudFront Free/Pro **flat-rate** (attach in console) | Edge cost capped |
| RDS fixed storage (no `max_allocated_storage`) | Disk cannot silently grow |
| CW logs 14d + Docker log rotate 10MB×3 | Logs stay bounded |
| Budgets + anomaly detection + SNS | Warns (does not hard-stop spend) |

AWS Budgets lag 8–12h. Cost allocation tags can take ~24h to appear in Cost Explorer.

REGIONAL Cognito WAF request charges are usually cents at this scale (not modeled as a separate line).

---

## 2. Monthly breakdown

### Account (`infra/global`) — ~$1.50–5.50/mo

| Item | ~/mo |
|---|---|
| State + CloudTrail S3 | ~$0–1 |
| Route 53 hosted zone | $0.50 |
| GuardDuty | ~$1–4 (`enable_guardduty = false` to skip) |

### Dev (desired=1 each ASG) — ~$92–96/mo

| Item | ~/mo |
|---|---|
| CloudFront Free flat-rate | $0 |
| NAT Gateway (1 AZ) + EIP | ~$32 |
| ALB + public IPv4 (2 AZs) | ~$23.50 |
| EC2 app `t4g.micro` + 30 GB EBS | ~$9 |
| EC2 web `t4g.nano` + EBS | ~$5 |
| RDS `db.t4g.micro` + 20 GB | ~$14 |
| Secrets / CW / Cognito / NAT data | ~$4–6 |

Ensure-app + origin-rotate Lambdas run on a schedule / apply only — pennies. Weekly ASG refreshes from origin rotation briefly run +1 instance (same as a normal deploy).

Rolling deploy briefly runs +1 instance → pennies. Instances have **no** public IPv4 charges.

### Prod (desired=1 each ASG) — ~$157–172/mo

CloudFront Pro $15 · NAT ~$32 · ALB+IPs ~$24 · EC2 small + micro ~$25 · RDS Multi-AZ ~$48 · misc ~$8

---

## 3. What changes the bill

| You change | Impact |
|---|---|
| `asg_desired_capacity` +1 (app) | Dev ~+$9/mo; prod ~+$16/mo (+ NAT data) |
| `web_asg_desired_capacity` +1 | Dev ~+$5/mo; prod ~+$9/mo |
| Larger `instance_type` / `db_instance_class` | Step change — read COST_GATE first |
| Create **prod** while unused | Full ~$157–172 |
| Second NAT for multi-AZ HA | +~$32/mo |
| `enable_guardduty = false` | −$1–4 |

Traffic alone does **not** add ASG instances.

---

## 4. Pipeline

GitHub Actions applies the same fixed-size modules. No autoscaling policies are introduced by CI. Keep prod apply behind a GitHub Environment approval ([CHECKLIST §G](CHECKLIST.md)).
