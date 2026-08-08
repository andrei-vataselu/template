# Bootstrap log — what we did (reproducible)

**Date of this bootstrap:** 2026-08-08 / 2026-08-09  
**Purpose:** Exact record of work completed so far, live AWS inventory, and the ordered **next steps**.  
**Companion docs:** [`CHECKLIST.md`](CHECKLIST.md) · [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md) · [`SECURITY_CHECK.md`](SECURITY_CHECK.md) · [`README.md`](README.md)

---

## 0. Facts (this account / project)

| Item | Value |
|---|---|
| AWS account | `072160582391` |
| Region | `eu-west-1` |
| CLI profile | `andrei-login` |
| Identity in use | **root** (`arn:aws:iam::072160582391:root`) — temporary; replace with IAM/Identity Center admin |
| Domain | `andrei-vataselu.online` (Namecheap) |
| GitHub repo | https://github.com/andrei-vataselu/template.git (**public**) |
| Alert email | `andreivataselu42@gmail.com` |
| Dev IP allowlist | `81.196.154.44/32` |
| Project / app tags | `Project=popo`, `Application=template` |
| Terraform | `1.10.4` (CI pinned); local also 1.10.x |
| Expected cost **now** | ~**$0.50–2/mo** (global only) |
| Expected cost **after dev apply** | ~**$52–55/mo** |
| Expected cost **after prod apply** | ~**$110+/mo** — do not apply until needed |

---

## 1. What exists on AWS right now

### Created by this project (`infra/global` apply)

| Resource | ID / name | Notes |
|---|---|---|
| S3 state bucket | `popo-tfstate-072160582391` | Versioned, encrypted, TLS-only policy |
| S3 CloudTrail bucket | `popo-cloudtrail-072160582391` | Lifecycle configured |
| CloudTrail | `popo-management` | Multi-region management events |
| Route 53 hosted zone | `Z02037213FFF9DHKNUAT1` | `andrei-vataselu.online` |
| Nameservers | see §4 | Set at Namecheap → Custom DNS |
| SNS (eu-west-1) | `popo-root-usage-alerts` | Root API alerts |
| SNS (us-east-1) | `popo-root-usage-alerts` | Root console sign-in alerts |
| EventBridge rules | `popo-root-api-usage`, `popo-root-console-signin` | → SNS |
| Access Analyzer | `popo-external-access` | Account analyzer |
| IAM OIDC provider | `token.actions.githubusercontent.com` | Imported (already existed) |
| IAM role | `popo-github-terraform` | Trusts GitHub repo `andrei-vataselu/template:*`; `AdministratorAccess` attached |
| Terraform state object | `s3://popo-tfstate-072160582391/global/terraform.tfstate` | Migrated from local |

### Explicitly **not** created yet

- Dev / prod VPC, ALB, ASG, EC2, RDS, Cognito, WAF, ACM, budgets from this stack
- GuardDuty detector (`enable_guardduty = false` — see §6)
- App at `https://dev.andrei-vataselu.online`

### Unrelated leftovers already in the account (not this stack)

- CloudFront `E2IUT3HBCCCMLG` → origin `gaming-shop-backend-alb-…eu-north-1…` (old project)
- Budgets named `30 dollars spent`, `60 bucks spent` (pre-existing)

---

## 2. What exists on GitHub right now

| Item | Status |
|---|---|
| Repo visibility | Public |
| Actions Variables | Set (see §5) |
| Environments | `dev`, `prod` (no required reviewers on prod yet) |
| Workflow on **remote** | **Missing** — `.github/workflows/terraform.yml` is local only until commit + push |
| Most infra/docs changes | **Uncommitted / unpushed** on `main` |

---

## 3. Prerequisites already done (manual)

1. **Cost allocation tags** activated in Billing: `Application`, `Environment` (Active as of 2026-08-08).
2. **Local tfvars filled** (gitignored — do not commit):
   - `infra/global/terraform.tfvars`
   - `infra/environments/dev/terraform.tfvars`
   - (prod tfvars may exist locally; do not apply yet)
3. **AWS CLI login profile** configured:
   ```powershell
   aws login --profile andrei-login
   aws sts get-caller-identity --profile andrei-login
   ```
4. Domain registered at Namecheap; NS switched to Route 53 (verified on `8.8.8.8` / `1.1.1.1`).

---

## 4. Reproduce: global stack (account bootstrap)

> First apply cannot use the S3 backend (bucket does not exist yet). Use **local** backend → apply → switch to **s3** → migrate.

### 4.1 Windows credential quirk (required for Terraform)

`aws login` works for the AWS CLI, but the Terraform AWS provider often **does not** read that session. Export keys each shell:

```powershell
$env:AWS_PROFILE = "andrei-login"
$raw = aws configure export-credentials --profile andrei-login --format process
$creds = $raw | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID     = $creds.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $creds.SecretAccessKey
$env:AWS_SESSION_TOKEN     = $creds.SessionToken
$env:AWS_REGION            = "eu-west-1"
Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue

aws sts get-caller-identity   # must succeed before terraform
```

### 4.2 Local `terraform.tfvars` for global

Create `infra/global/terraform.tfvars` (gitignored):

```hcl
aws_region         = "eu-west-1"
project_name       = "popo"
application_name   = "template"
alert_email        = "andreivataselu42@gmail.com"
enable_guardduty   = false   # true only after GuardDuty works in console
domain_name        = "andrei-vataselu.online"
github_repository  = "andrei-vataselu/template"
enable_github_oidc = true
```

### 4.3 First apply with local backend

In `infra/global/versions.tf`, temporarily use:

```hcl
backend "local" {}
```

Then:

```powershell
cd e:\popo\infra\global
Remove-Item -Recurse -Force .terraform -ErrorAction SilentlyContinue
terraform init -input=false -reconfigure
terraform apply -input=false -auto-approve
```

### 4.4 Fixes applied during our first run (if recreating from scratch, skip unless they recur)

1. **GuardDuty** failed with `SubscriptionRequiredException` → set `enable_guardduty = false` and re-apply.
2. **GitHub OIDC provider** already existed → import then finish apply:
   ```powershell
   terraform import 'aws_iam_openid_connect_provider.github[0]' `
     'arn:aws:iam::072160582391:oidc-provider/token.actions.githubusercontent.com'
   terraform apply -input=false -auto-approve
   ```

### 4.5 Capture outputs (ours)

```text
tfstate_bucket          = popo-tfstate-072160582391
cloudtrail_bucket       = popo-cloudtrail-072160582391
zone_id                 = Z02037213FFF9DHKNUAT1
github_actions_role_arn = arn:aws:iam::072160582391:role/popo-github-terraform
guardduty_enabled       = false
name_servers = [
  ns-1444.awsdns-52.org
  ns-1914.awsdns-47.co.uk
  ns-214.awsdns-26.com
  ns-809.awsdns-37.net
]
```

### 4.6 Point Namecheap at Route 53

Namecheap → Domain List → `andrei-vataselu.online` → Nameservers → **Custom DNS** → paste the four `awsdns-*` values above.

Verify (public resolvers; your ISP cache may lag):

```powershell
nslookup -type=NS andrei-vataselu.online 8.8.8.8
nslookup -type=NS andrei-vataselu.online 1.1.1.1
```

### 4.7 Migrate global state to S3

1. Set `infra/global/versions.tf` back to `backend "s3" {}`.
2. Write `infra/backends/global.hcl` (gitignored):

```hcl
bucket       = "popo-tfstate-072160582391"
key          = "global/terraform.tfstate"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true
```

3. Migrate (use absolute path on Windows; from `infra/global`, relative is `../backends/global.hcl` — **not** `../../backends`):

```powershell
cd e:\popo\infra\global
terraform init "-backend-config=e:/popo/infra/backends/global.hcl" -migrate-state -force-copy -input=false
aws s3 ls s3://popo-tfstate-072160582391/global/
```

Optional helper (Git Bash / WSL, with AWS creds exported):

```bash
./scripts/tf-backend.sh migrate global
```

### 4.8 Confirm SNS

Check Gmail for **two** AWS SNS confirmation emails (eu-west-1 + us-east-1 root-usage topics) and click Confirm.

---

## 5. Reproduce: GitHub Actions wiring

### 5.1 Variables (already set)

```powershell
$gh = "C:\Program Files\GitHub CLI\gh.exe"   # add to PATH or use full path
cd e:\popo

& $gh variable set AWS_ACCOUNT_ID --body "072160582391"
& $gh variable set AWS_ROLE_ARN   --body "arn:aws:iam::072160582391:role/popo-github-terraform"
& $gh variable set ALERT_EMAIL    --body "andreivataselu42@gmail.com"
& $gh variable set DOMAIN_NAME    --body "andrei-vataselu.online"
& $gh variable set APP_GIT_URL    --body "https://github.com/andrei-vataselu/template.git"
& $gh variable list
```

### 5.2 Environments (already created)

```powershell
& $gh api -X PUT repos/andrei-vataselu/template/environments/dev
& $gh api -X PUT repos/andrei-vataselu/template/environments/prod
```

Add **required reviewers** on `prod` before first prod apply (GitHub UI → Settings → Environments → prod).

### 5.3 Workflow behavior (local file)

File: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)

- Trigger: **`workflow_dispatch` only** (no PR/push)
- Inputs: `environment` = `dev`|`prod`, `action` = `plan`|`apply`
- Auth: OIDC → `vars.AWS_ROLE_ARN`
- State: `s3://popo-tfstate-${AWS_ACCOUNT_ID}/{dev|prod}/terraform.tfstate`
- Global stack is **not** in this workflow (account bootstrap stays local)

**Until you commit + push**, Actions will not show this workflow.

---

## 6. GuardDuty note

Enable later:

1. Open https://eu-west-1.console.aws.amazon.com/guardduty/ once (accept / activate).
2. Set `enable_guardduty = true` in `infra/global/terraform.tfvars`.
3. `terraform apply` in `infra/global` (with exported creds + S3 backend).

Adds roughly **~$1–4/mo** after free trial.

---

## 7. Dev tfvars already prepared (local, gitignored)

`infra/environments/dev/terraform.tfvars`:

```hcl
aws_region             = "eu-west-1"
project_name           = "popo"
application_name       = "template"
environment            = "dev"
cost_center            = "cc-dev-sandbox"
alert_email            = "andreivataselu42@gmail.com"
monthly_budget_usd     = 55
instance_type          = "t4g.micro"
db_instance_class      = "db.t4g.micro"
root_volume_gb         = 30
db_storage_gb          = 20
backup_retention_days  = 3
db_multi_az            = false
db_deletion_protection = false
db_skip_final_snapshot = true
vpc_cidr               = "10.20.0.0/16"
app_git_url            = "https://github.com/andrei-vataselu/template.git"
domain_name            = "andrei-vataselu.online"
allowed_ip_cidrs       = ["81.196.154.44/32"]
asg_min_size           = 1
asg_desired_capacity   = 1
asg_max_size           = 2
```

Update `allowed_ip_cidrs` if your public IP changes (`curl https://checkip.amazonaws.com`).

---

## 8. Next steps (ordered)

### Done in prep (2026-08-09) — no Terraform apply yet

| # | Item | Status |
|---|---|---|
| 3 | Dev apply **prep** (backend `dev.hcl`, tfvars ready, cost gate linked) | ✅ ready — **not applied** |
| 4 | CloudFront Free + health-check **runbook** written (§10) | ✅ docs |
| 5 | Stop using root — IAM admin path (§9) | ✅ prepared — **deferred** (keep `andrei-login`) |
| 6 | Prod **prep** (tfvars, `prod.hcl`, GitHub Environment required reviewer) | ✅ ready — **do not apply** |

### Still before first `terraform apply` on dev

1. Confirm SNS root-usage emails in Gmail (both regions), if not already.
2. **Commit + push** workflow/infra/docs (optional for local apply; required for Actions).

> IAM switch to `andrei-cli` is **deferred** — keep using `andrei-login` / root session + §4.1 export for Terraform.

### Apply dev (~$52–55/mo)

```powershell
# Export AWS creds as in §4.1 (profile andrei-login)

cd e:\popo\infra\environments\dev
terraform init "-backend-config=e:/popo/infra/backends/dev.hcl" -input=false
terraform plan -input=false
# Read infra/COST_GATE.txt first
terraform apply -input=false
```

Or after push: **Actions → Terraform → Run workflow** → `environment=dev` → `action=plan`, then `apply`.

### After dev apply — follow §10

### Prod later (~$110+/mo) — follow §11

---

## 9. Stop using root (IAM) — prepared, **deferred**

Optional later. Day-to-day can stay on `andrei-login` until you choose otherwise.

| Control | Status |
|---|---|
| Root MFA | ✅ enabled (`nana-s26-fe`) |
| Root access keys | ✅ none |
| Account password policy | ✅ min 14, complexity, 90d rotate, reuse 5 |

### Created / changed 2026-08-09

| Item | Detail |
|---|---|
| IAM group `popo-admins` | `AdministratorAccess` |
| User `andrei-cli` | In `popo-admins`; console login profile created; **password reset required** |
| Policy `popo-RequireMFA` | Attached to `andrei-cli` — API denied without MFA (MFA setup actions allowed) |
| `cli-user` access key `…DVAP` | **Inactivated** (was long-lived Admin key) |

Console: https://072160582391.signin.aws.amazon.com/console  
Username: `andrei-cli`  
Temp password: shown once in the chat when created — change it on first login.

### Optional later (when you want to leave root)

1. Sign in as `andrei-cli` → set a new password.
2. Security credentials → **Assign MFA device** → authenticator app → name it `andrei-cli`.
3. Sign out of **root**. Use root only for account recovery / rare break-glass.
4. CLI: `aws login --profile andrei-cli` then export creds (§4.1).
5. Optional cleanup: delete inactive `cli-user` key; review `github-actions-gaming-shop` key.

---

## 10. After first **dev** apply — CloudFront Free + health (runbook)

Do **not** skip the Free plan or edge costs stay pay-as-you-go.

1. Confirm budget / alarm SNS emails in Gmail.
2. AWS Console → **CloudFront** → open the new distribution for `dev.andrei-vataselu.online`.
3. Attach **CloudFront Free** flat-rate plan (Billing / pricing plan UI for that distribution).
4. Wait until distribution status is **Deployed** and ACM certs are **Issued** (viewer + regional origin).
5. From an IP in `allowed_ip_cidrs` (`81.196.154.44/32`):

```powershell
curl.exe -sI https://dev.andrei-vataselu.online
curl.exe -s  https://dev.andrei-vataselu.online/api/health
# expect {"ok":true} (or your health JSON)
```

6. App-only redeploys later: `./scripts/deploy.sh dev` (ASG instance refresh) — not a full infra re-apply.

---

## 11. Prod prep (ready — do not apply)

| Prep | Status |
|---|---|
| Local `infra/environments/prod/terraform.tfvars` | ✅ filled (gitignored) |
| `infra/backends/prod.hcl` | ✅ `popo-tfstate-072160582391` / `prod/terraform.tfstate` |
| GitHub Environment `prod` | ✅ **required reviewer** = `andrei-vataselu` |
| CloudFront **Pro** (~$15/mo) | Attach only after prod apply |
| Expected cost | ~$110+/mo — apply only when needed |

When ready:

```powershell
cd e:\popo\infra\environments\prod
terraform init "-backend-config=e:/popo/infra/backends/prod.hcl" -input=false
terraform plan -input=false
# Prefer Actions: environment=prod, action=plan then apply (needs your GitHub approval)
```

After apply: attach CloudFront **Pro**; wire app DB user to RDS; monthly restore drill.

---

## 12. Code / docs created or changed in this effort (local tree)

High-signal items (not an exhaustive `git status` dump):

| Path | Role |
|---|---|
| `infra/global/*` | Account stack + OIDC role + backends support |
| `infra/backends/*.hcl.example` | Partial S3 backend templates |
| `infra/environments/{dev,prod}/*` | Env stacks (ALB + ASG + edge + DB …) |
| `infra/modules/{compute,edge,security_groups,observability,…}` | Shared modules |
| `deploy/gateway/nginx.conf.template` | Origin secret + health path hardening |
| `.github/workflows/terraform.yml` | Manual-only plan/apply for dev|prod |
| `scripts/tf-backend.sh` | Bootstrap / migrate / init helper |
| `scripts/deploy.sh` | App deploy via ASG refresh |
| `CHECKLIST.md` | Go-live checklist |
| `COST_PREDICTABILITY.md` / `infra/COST_GATE.txt` | Cost model |
| `SECURITY_CHECK.md` | Security status |
| `BOOTSTRAP.md` | This file |

Deleted / superseded: `GO_LIVE_CHECKLIST.md`, `WHATS_LEFT.md` (content folded into CHECKLIST + companions).

---

## 13. Verify current state (commands)

```powershell
# Creds: §4.1 (prefer andrei-cli after MFA)
aws s3 ls
aws route53 list-hosted-zones --query "HostedZones[].Name"
aws iam get-role --role-name popo-github-terraform --query "Role.Arn"
aws s3 ls s3://popo-tfstate-072160582391/global/
nslookup -type=NS andrei-vataselu.online 8.8.8.8

# Expect empty for app stack until dev apply:
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName"
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
```

---

## 14. Cost snapshot

| Stage | ~/mo |
|---|---|
| **Now (global only)** | ~$0.50–2 (Route 53 + S3/CloudTrail) |
| **+ GuardDuty** | +~$1–4 |
| **+ Dev** | ~$52–55 (ALB is the large jump) |
| **+ Prod** | ~$110+ |

Budgets warn; they do not hard-stop spend. Scale only by changing `asg_desired_capacity` and applying — no CPU autoscaling.
