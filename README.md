# popo — Secure, Cost-Predictable AWS Hosting Template

React + Vite + Tailwind frontend, Node.js + TypeScript API, everything in Docker on a single EC2 instance behind CloudFront + WAF, with a private encrypted RDS PostgreSQL. Built to follow `aws_secure_predictable_hosting_guide.md` using its **lower-cost compromise** (public EC2 origin locked to CloudFront) because the guide's preferred private VPC origin requires the ~$200/mo CloudFront Business plan.

> **Before deploying, read `GO_LIVE_CHECKLIST.md`** — the manual account-level steps (IAM admin, cost allocation tags, SNS confirmation, CloudFront plan) that Terraform cannot do, plus everything that was locally verified.
> **`WHATS_LEFT.md`** has the final review: per-environment grades (dev 8.5/10, prod 7.5/10), remaining TODOs, and cost levers.

```text
User → https://dev.andrei-vataselu.online (ACM cert, Route 53)
  → CloudFront (WAF block mode, TLS, rate limits, security headers)
    → EC2 :443 https-only (SG: CloudFront prefix list only + secret origin header)
      → host nginx (Let's Encrypt via DNS-01, auto-renewed)
        → Docker: gateway nginx (rate limits, method filter)
          → web (React, unprivileged nginx) + api (Node, non-root, read-only fs)
            → RDS PostgreSQL (private subnets, encrypted, SSL forced)
```

Domain: `andrei-vataselu.online` — dev at `dev.<domain>`, prod at apex + `www`, origins at `origin-dev.<domain>` / `origin.<domain>`. Set `domain_name = ""` in tfvars to fall back to `*.cloudfront.net` with an HTTP origin.

---

## 1. Where to write your configuration

| What | File | Notes |
|---|---|---|
| **Account-level stack** (state bucket, CloudTrail, root alerts, GuardDuty, **Route 53 zone**) | `infra/global/terraform.tfvars` | **Apply this first, once per account** — set `alert_email`; then point Namecheap NS at the `name_servers` output |
| **Custom domain per env** | `domain_name` in each env's `terraform.tfvars` | Pre-set to `andrei-vataselu.online`; requires the NS switch first |
| **Dev environment** (email, sizes, budget, git URL) | `infra/environments/dev/terraform.tfvars` | **Set `alert_email` before apply** — budget/alarm emails go there |
| **Prod environment** | `infra/environments/prod/terraform.tfvars` | Same keys; bigger tiers, Multi-AZ, deletion protection on |
| **Local Docker run** | `deploy/.env` (copy from `deploy/.env.example`) | `SKIP_ORIGIN_CHECK=1` for localhost only |
| **App code** | `apps/backend/`, `apps/frontend/` | API routes in `apps/backend/src/index.ts` |
| **Deploy from git on EC2** | `app_git_url` in `terraform.tfvars` | Empty = bootstrap placeholder UI; set it to run the real apps |
| **Cognito callback/logout URLs** | `infra/environments/<env>/main.tf` (`module "cognito"`) | Replace localhost entries when you have a domain |
| **WAF rules / rate limits** | `infra/modules/edge/main.tf` | Managed rules in block mode; 2000 req/5min per IP |
| **Who can open the site** | `allowed_ip_cidrs` in `terraform.tfvars` | Dev is locked to your IP; `[]` = public. Update when your IP changes |
| **Gateway rate limits / proxy rules** | `deploy/gateway/nginx.conf.template` | Second defence layer behind WAF |
| **API CORS whitelist** | `ALLOWED_ORIGINS` env (compose / `deploy/.env`) | Empty = same-origin only (default, safest) |
| **Cost ceiling reference** | `infra/COST_GATE.txt` | Read before every apply |

Key `terraform.tfvars` fields:

```hcl
alert_email        = "you@example.com"   # REQUIRED — replace placeholder
monthly_budget_usd = 25                  # alert threshold, not a hard cap
app_git_url        = ""                  # git repo with apps/ + deploy/ for real app
instance_type      = "t4g.micro"
db_instance_class  = "db.t4g.micro"
```

Never put AWS keys, passwords, or tokens in `.tf`/`.tfvars` files. The RDS master password is managed by AWS Secrets Manager automatically; the CloudFront origin secret also lives in Secrets Manager and is fetched by the instance at boot; AWS credentials come from your CLI session.

---

## 2. Security score: **dev 9 / 10, prod 8 / 10** (once applied with the domain delegated)

Solid fundamentals for a budget deployment. All free/cheap hardening is now in Terraform, including account-level detection (CloudTrail, GuardDuty, root-usage alerts), ongoing patching, and flow logs. The remaining gaps are either operational (root account usage), require a custom domain (TLS to origin), or cost real money (private VPC origin).

### What earns points

| Control | Status |
|---|---|
| Origin locked to CloudFront managed prefix list, no SSH/RDP anywhere | ✅ |
| Secret origin header verified by nginx (CloudFront bypass rejected with 403) | ✅ |
| Origin secret stored in **Secrets Manager**, fetched at boot by the instance role (not baked into user-data) | ✅ |
| SSM Session Manager instead of SSH keys | ✅ |
| IMDSv2 required, encrypted gp3, fixed instance (no autoscaling) | ✅ |
| RDS: private subnets, not publicly accessible, encrypted, `rds.force_ssl=1`, SG-to-SG only | ✅ |
| RDS master password in Secrets Manager (never in Terraform vars) | ✅ |
| SG least privilege: **DB has zero egress rules**; app egress limited to 443/53 + 5432-to-DB | ✅ |
| No NAT gateway, no public DB route, private route table has no IGW | ✅ |
| WAF managed rules (Common + KnownBadInputs) in **block mode** + per-IP rate limit | ✅ |
| CloudFront: TLS 1.2+, HTTPS redirect, HSTS + full security-headers policy | ✅ |
| Gateway nginx second layer: per-IP rate limits, connection caps, HTTP method filtering, timeouts | ✅ |
| Containers: `cap_drop: ALL`, `no-new-privileges`, memory/pid limits, read-only API filesystem, unprivileged nginx images | ✅ |
| Elastic IP on the origin — CloudFront keeps working across instance stop/start | ✅ |
| Docker log rotation on EC2 (`daemon.json`, 10MB×3 per container) — no disk-fill outage | ✅ |
| Gateway adds security headers (`nosniff`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`) as defence-in-depth below CloudFront's policy | ✅ |
| API: non-root user, helmet, bounded JSON body (100kb), CORS same-origin by default (`ALLOWED_ORIGINS` opt-in) | ✅ |
| Cognito: admin-only signup, PKCE, no client secret in SPA, **MFA required (TOTP)**, token revocation, user-existence errors hidden, deletion protection in prod | ✅ |
| Budgets at 50/80/100% + forecast, Cost Anomaly Detection, CPU/storage alarms | ✅ |
| IAM: instance role scoped, secrets read gated by `Application`/`Environment` tags | ✅ |
| Reproducible builds: `npm ci` with committed lockfiles, multi-stage Dockerfiles | ✅ |
| Optional per-IP site lock: WAF allowlist (`allowed_ip_cidrs`) — dev is restricted to your IP | ✅ |
| **CloudTrail** management events (all regions, log validation, 90-day S3 retention) | ✅ `infra/global` |
| **Root-usage email alerts** — console sign-in + API calls by root trigger SNS | ✅ `infra/global` |
| **GuardDuty** threat detection + **IAM Access Analyzer** (external access, free tier) | ✅ `infra/global` |
| **VPC Flow Logs** on REJECTed traffic (14-day retention) — records scans/SG blocks | ✅ |
| **Weekly OS patching** via SSM maintenance window (Sun 03:00 UTC, reboots if needed) | ✅ |
| **Remote encrypted state** — S3 bucket (versioned, SSE-KMS, TLS-only, native locking) ready; migration is one `terraform init -migrate-state` | ✅ scaffolded |
| **Custom domain + ACM cert** on CloudFront (`dev.`/apex+`www`), TLS 1.2+, Route 53 alias records | ✅ |
| **CloudFront → origin is HTTPS-only** — Let's Encrypt cert on the instance (DNS-01, auto-renewed twice daily), host nginx terminates TLS in front of the Docker gateway | ✅ |
| Real Cognito callback URLs on the domain (prod no longer whitelists localhost) | ✅ |

### What costs points

| # | Gap | Severity |
|---|---|---|
| 1 | **EC2 has a public IP** — inherent to the lower-cost design; the NIC is internet-reachable even though the SG filters it. Only CloudFront Business + private VPC origin (~$200/mo) removes this | High (accepted trade-off) |
| 2 | **You operate AWS as the root user** (`arn:...:root` in every apply). Root usage now triggers email alerts, but you still need to create an IAM admin with MFA and retire root for daily work | High (operational) |
| 3 | State migration to the S3 backend is pending — uncomment the `backend "s3"` block in each env's `versions.tf` and run `terraform init -migrate-state` after applying `infra/global` | Medium (one command) |
| 4 | Budget alerts require **activating cost allocation tags** in the Billing console first (see `GO_LIVE_CHECKLIST.md` §1.2) — until then the tag-filtered budget tracks $0 | Medium (one-time manual step) |
| 5 | No WAF in front of Cognito endpoints | Low |
| 6 | Docker base images pinned by tag, not digest | Low |

**Path to 9–10/10**: custom domain + TLS to origin (#2), CloudFront Business private VPC origin (#1), separate prod AWS account with SCPs, immutable AMI deployments.

---

## 3. Remaining improvements (ordered)

Implemented and moved to §2: ~~remote state~~, ~~CloudTrail + root alerts~~, ~~VPC flow logs~~, ~~ongoing patching~~, ~~GuardDuty + Access Analyzer~~, ~~custom domain + TLS to origin~~ — ~$1.50–5.50/mo total on top of the env costs.

1. **Stop using root** — IAM admin + MFA, temporary sessions for Terraform. Nothing in this repo can fix this; it's an account-level action (root usage at least emails you now).
2. **Migrate state** — apply `infra/global`, uncomment the backend block in each env's `versions.tf`, `terraform init -migrate-state`.
3. **Switch Namecheap nameservers to Route 53** (global output `name_servers`) — cert validation and Let's Encrypt both depend on it.
4. **CloudFront Business + private VPC origin** (~$200/mo) — removes the public NIC, the single biggest remaining risk.
5. **Separate AWS account for prod** under Organizations with SCP guardrails (deny NAT, public IPs, region sprawl, Marketplace).

---

## 4. Runbook

```powershell
# Local development (no AWS needed)
cd deploy
copy .env.example .env
docker compose up --build          # http://localhost

# One-time account setup (state bucket, CloudTrail, root alerts, GuardDuty)
cd infra\global
terraform init
terraform apply                    # set alert_email in terraform.tfvars first

# Deploy dev to AWS (after setting alert_email in terraform.tfvars)
cd ..\environments\dev
terraform init
terraform plan                     # review carefully — check ..\..\COST_GATE.txt
terraform apply
# then: uncomment backend "s3" in versions.tf and run terraform init -migrate-state

# Shell into EC2 (no SSH)
aws ssm start-session --target <instance-id> --region eu-west-1

# Tear down dev
terraform destroy
```

After first apply:
1. Confirm the SNS subscription email (budget/alarm alerts won't arrive until you do).
2. Attach the CloudFront **Free** flat-rate plan to the distribution in the console (not Terraformable yet).
3. Browse the `cloudfront_domain` output — direct EC2 access returns 403.

## 5. Cost expectations

| Environment | Expected | Notes |
|---|---|---|
| global (account) | ~$1–5/mo | CloudTrail/state/flow logs ≈ $0; GuardDuty $1–4 (toggleable) |
| dev | **~$28–30/mo** | $25 budget alert **will** fire — intentional early warning |
| prod (same architecture, bigger tiers) | ~$88+/mo | Pro plan + t4g.small + Multi-AZ RDS |
| prod (guide-preferred private VPC origin) | ~$245+/mo | Not implemented in this repo |

Full breakdown: `infra/COST_GATE.txt`. AWS Budgets lags 8–12h — it warns, it does not stop spend.
