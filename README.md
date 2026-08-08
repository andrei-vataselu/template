# README — what this is

Secure, cost-predictable AWS hosting for a **React + Vite + Tailwind** frontend and a **Node.js + TypeScript** API. Everything runs in Docker behind CloudFront + WAF, with an ALB and Auto Scaling Group in front of EC2, and a private encrypted RDS PostgreSQL.

**Domain:** `andrei-vataselu.online`  
- Dev: `https://dev.andrei-vataselu.online`  
- Prod: `https://andrei-vataselu.online` (+ `www`)  
- Origins: `origin-dev.` / `origin.` → ALB (HTTPS)

| Doc | Purpose |
|---|---|
| [`CHECKLIST.md`](CHECKLIST.md) | Go-live steps — what is done vs left |
| [`BOOTSTRAP.md`](BOOTSTRAP.md) | Detailed log of what we did + how to reproduce + next steps |
| [`SECURITY_CHECK.md`](SECURITY_CHECK.md) | Security controls, gaps, grades |
| [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md) | Monthly cost + what can surprise you |
| [`infra/COST_GATE.txt`](infra/COST_GATE.txt) | Raw line-item cost gate |
| [`aws_secure_predictable_hosting_guide.md`](aws_secure_predictable_hosting_guide.md) | Full theory guide (this repo = lower-cost path) |

---

## Your progress

| Done | Item |
|---|---|
| ✅ | Cost allocation tags `Application` + `Environment` **Active** |
| ✅ | `alert_email` = `andreivataselu42@gmail.com` |
| ✅ | GitHub repo **public** (`andrei-vataselu/template`) |
| ✅ | Global stack applied + state in S3 (`popo-tfstate-072160582391`) |
| ✅ | Namecheap NS → Route 53 (`awsdns-*`) |
| ✅ | GitHub Variables + Environments `dev`/`prod` (prod requires reviewer) |
| ✅ | IAM: `andrei-cli` + `popo-admins` + RequireMFA; root MFA already on |
| ✅ | Commit + push — Terraform workflow active on GitHub |
| ✅ | Apply **dev** via Actions (run [31280171042](https://github.com/andrei-vataselu/template/actions/runs/31280171042)) |
| ⬜ | Attach CloudFront **Free** plan + verify site/health |
| ⬜ | Switch to `andrei-cli` MFA *(deferred — optional)* |

---

## Architecture

```text
User
  → CloudFront (WAF block mode, TLS, rate limits, security headers)
    → ALB :443 (ACM, SG: CloudFront prefix list only)
      → ASG EC2 :80 (Docker Compose: gateway → web + api)
        → RDS PostgreSQL (private, encrypted, SSL forced)
```

| Layer | What |
|---|---|
| Edge | CloudFront + WAFv2 (Common + KnownBadInputs, block mode) |
| Origin | Application Load Balancer + regional ACM |
| Compute | ASG + launch template, Docker Compose |
| Data | RDS Postgres 16, Secrets Manager master password |
| Auth | Cognito (admin-only signup, MFA required, PKCE) |
| Account | `infra/global`: state bucket, CloudTrail, GuardDuty, Route 53, GitHub OIDC |
| State | S3 backend (versioned, SSE-KMS, lockfile) after bootstrap |
| CI | Manual Actions: Terraform plan/apply · Deploy FE/BE · destroy-dev |

**Zero-downtime app deploy:** `./scripts/deploy.sh dev`  
**Infra:** Actions → Terraform (dev/prod × plan/apply)  
**App:** Actions → Deploy frontend / Deploy backend (ASG rolling refresh)  
**Tear down dev:** Actions → Terraform destroy (dev only) → type `destroy-dev`
**Scale:** set `asg_desired_capacity` (capped by `asg_max_size`; no CPU autoscaling)

---

## Capacity — normal CRUD

Estimates for a typical authenticated CRUD API (small JSON, light indexes). Not an SLA.

| Env | Concurrent users | Light MAU | Notes |
|---|---|---|---|
| Dev (`t4g.micro` + `db.t4g.micro`) | ~50–150 | ~500–2,000 | 1 GB RAM is the limit |
| Prod (`t4g.small` + `db.t4g.small`) | ~150–400 | ~2,000–10,000 | Scale ASG up to max=3; **RDS ceilings first** |

---

## Cost & grades

| | Dev | Prod |
|---|---|---|
| Expected | **~$52–55/mo** | **~$110+/mo** |
| Budget alert | $55 | $120 |
| Security | **9 / 10** | **8 / 10** |
| Cost predictability | **9 / 10** | **9 / 10** |

---

## Repo layout

```text
apps/backend|frontend     Node API + React SPA
deploy/                   docker-compose + gateway (what EC2 runs)
infra/global              account stack (state, Trail, GuardDuty, DNS, OIDC)
infra/environments/*      dev / prod
infra/backends/           S3 backend .hcl examples (*.hcl gitignored)
infra/modules/*           networking, compute (ALB+ASG), edge, database, …
scripts/deploy.sh         zero-downtime ASG instance refresh
scripts/tf-backend.sh     bootstrap / migrate / init S3 state
.github/workflows/        Terraform pipeline
```

## Config (local)

| What | File |
|---|---|
| Account email / domain / OIDC | `infra/global/terraform.tfvars` (gitignored) |
| Dev sizes, IP allowlist, git URL | `infra/environments/dev/terraform.tfvars` |
| Prod sizes | `infra/environments/prod/terraform.tfvars` |
| Local Docker | `deploy/.env` |

Use `*.tfvars.example` as templates. Never commit real tfvars.

---

## Quick start

```bash
# Local app
cd deploy && cp .env.example .env && docker compose up --build

# AWS — see CHECKLIST.md for the full sequence
aws login --profile andrei-login
./scripts/tf-backend.sh bootstrap-global
./scripts/tf-backend.sh migrate global
cd infra/global && terraform output name_servers   # → Namecheap
./scripts/tf-backend.sh init dev
cd infra/environments/dev && terraform apply
```
