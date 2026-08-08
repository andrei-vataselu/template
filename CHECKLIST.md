# Checklist — go live

Ordered manual steps. Check boxes as you finish them.

**Companion docs:** [`README.md`](README.md) · [`BOOTSTRAP.md`](BOOTSTRAP.md) · [`SECURITY_CHECK.md`](SECURITY_CHECK.md) · [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md)

---

## A. Before any apply

- [x] **Cost allocation tags** — `Application` + `Environment` are **Active** (Billing, Aug 8 2026)
- [x] **`alert_email`** = `andreivataselu42@gmail.com` (global + dev + prod tfvars)
- [x] **Repo public** — `andrei-vataselu/template` (no PAT needed in `app_git_url`)
- [ ] **Stop using root** — deferred (optional). `andrei-cli` exists; keep using `andrei-login` for now. See [`BOOTSTRAP.md`](BOOTSTRAP.md) §9 when you want it
- [x] **Re-auth AWS CLI** — `aws login --profile andrei-login`

---

## B. Account stack + remote state + DNS

```bash
aws login --profile andrei-login

# Creates state bucket, CloudTrail, GuardDuty, Route 53, GitHub OIDC role
./scripts/tf-backend.sh bootstrap-global

# Move global state into S3
./scripts/tf-backend.sh migrate global

cd infra/global
terraform output name_servers
terraform output github_actions_role_arn
terraform output tfstate_bucket
```

- [x] **Global stack applied** — state bucket, CloudTrail, Route 53, GitHub OIDC role (GuardDuty off until AWS activates it)
- [x] Namecheap → Domain → **Nameservers → Custom DNS** → Route 53 `awsdns-*` (verified via 8.8.8.8 / 1.1.1.1)
- [ ] Verify from your PC: `nslookup -type=NS andrei-vataselu.online` shows `awsdns` (local ISP cache may lag)
- [ ] Confirm SNS emails for **root-usage** topics (eu-west-1 + us-east-1) — check Gmail
- [x] Save for GitHub Variables (§G): account `072160582391`, role `arn:aws:iam::072160582391:role/popo-github-terraform`

---

## C. Dev environment

**Prep done:** `infra/backends/dev.hcl` + local `terraform.tfvars` ready. **Not applied yet** (~$52–55/mo).

```powershell
# aws login --profile andrei-login + export creds (BOOTSTRAP §4.1)
cd infra/environments/dev
terraform init "-backend-config=../../backends/dev.hcl" -input=false
terraform plan
terraform apply   # only when you intentionally start paying ~$52–55/mo
```

Or: Actions → Terraform → `dev` + `plan`/`apply` (after commit+push).

- [ ] Confirm SNS email for **budget / alarms** (after apply)
- [ ] CloudFront console → attach **Free** flat-rate plan (see BOOTSTRAP §10)
- [ ] `https://dev.andrei-vataselu.online` loads; `/api/health` → `{"ok":true}`

---

## D. Day-2 operations

| Task | How |
|---|---|
| Local run | `cd deploy && cp .env.example .env && docker compose up --build` |
| Zero-downtime **app** deploy | Push to git → `./scripts/deploy.sh dev` |
| **Infra** via pipeline | GitHub → Actions → **Terraform** → Run workflow → pick **dev** or **prod** + plan/apply |
| Scale (predictable) | Edit `asg_desired_capacity` (≤ `asg_max_size`) → apply |
| Shell | SSM Session Manager (no SSH) |
| Rotate origin secret | `terraform apply -replace=random_password.origin_header` then `./scripts/deploy.sh` |
| Tear down dev | `terraform destroy` in `infra/environments/dev` |

---

## E. Before prod

**Prep done:** local prod `terraform.tfvars`, `infra/backends/prod.hcl`, GitHub Environment `prod` with required reviewer `andrei-vataselu`. **Do not apply** until needed (~$110+/mo).

- [x] GitHub Environment `prod` + required reviewers
- [ ] Attach CloudFront **Pro** after prod apply (~$15/mo)
- [ ] Wire API → RDS (app DB user + secret tagged `Application` / `Environment`)
- [ ] Monthly RDS restore drill
- [x] Do **not** apply prod until needed (~$110+/mo)

---

## F. Still owed (non-blocking)

- [ ] CloudWatch agent for container logs (optional)
- [ ] Pin Docker image digests in CI (optional)
- [ ] Separate AWS account for prod (later)
- [ ] Tighten GitHub Terraform role below `AdministratorAccess`

---

## G. GitHub Actions setup (after global apply)

Repo → **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
|---|---|
| `AWS_ACCOUNT_ID` | `072160582391` ✅ set |
| `AWS_ROLE_ARN` | `arn:aws:iam::072160582391:role/popo-github-terraform` ✅ set |
| `ALERT_EMAIL` | `andreivataselu42@gmail.com` ✅ set |
| `DOMAIN_NAME` | `andrei-vataselu.online` ✅ set |
| `APP_GIT_URL` | `https://github.com/andrei-vataselu/template.git` ✅ set |

Environments: `dev` + `prod` (prod has **required reviewer** `andrei-vataselu`).

**Blocker:** commit + push `.github/workflows/terraform.yml` (and infra) before Actions can run — still local-only unless you already pushed.

Workflow: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml) — **manual only**.

| Input | Options |
|---|---|
| `environment` | `dev` · `prod` |
| `action` | `plan` (dry-run) · `apply` (create/update) |

How: Actions → **Terraform** → **Run workflow** → choose env + action.

State: `s3://popo-tfstate-<ACCOUNT_ID>/{dev,prod}/terraform.tfstate` (global is local/account bootstrap, not this workflow).
