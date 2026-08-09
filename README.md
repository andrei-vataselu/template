# popo

Secure, cost-predictable AWS hosting for a **React + Vite** frontend and a **Node.js + TypeScript** API. Docker on private EC2 behind CloudFront + WAF, shared ALB, split ASGs, encrypted RDS, Cognito auth.

**Domain:** `andrei-vataselu.online`

| | Site | API | Auth |
|---|---|---|---|
| Dev | `https://dev.andrei-vataselu.online` | `https://api-dev.andrei-vataselu.online` | `https://auth.dev.andrei-vataselu.online` |
| Prod | `https://andrei-vataselu.online` (+ `www`) | `https://api.andrei-vataselu.online` | `https://auth.andrei-vataselu.online` |

Origins (`origin-dev.` / `origin-api-dev.` / `origin.` / `origin-api.`) hit a shared ALB over HTTPS with host-based routing.

| Doc | Purpose |
|---|---|
| [`CHECKLIST.md`](CHECKLIST.md) | Bootstrap, go-live, day-2 ops |
| [`SECURITY_CHECK.md`](SECURITY_CHECK.md) | Controls and open gaps |
| [`EXPLOIT_PATHS.md`](EXPLOIT_PATHS.md) | How open gaps can be abused |
| [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md) | Monthly cost model |
| [`infra/COST_GATE.txt`](infra/COST_GATE.txt) | Line-item cost gate |

---

## Architecture

```text
User
  → CloudFront ×2 (site + api) + CLOUDFRONT WAF
  → Cognito Hosted UI (auth.*) + REGIONAL WAF
    → shared ALB :443 (public; SG = CloudFront prefix list only)
      ├─ host origin-api-* / path /api/*  → ASG -app (private + NAT)
      └─ everything else                  → ASG -web (private + NAT)
        → RDS PostgreSQL (private) as role `app` — API only

Automated (no manual steps after first apply):
  • Weekly origin-secret rotation: SM → SSM gateway sync → CloudFront → ASG refresh
  • Per-minute cron backup sync on instances
  • ensure-app Lambda provisions DB role `app` on apply
  • Push to main auto-deploys FE/BE to the matching ASG
```

| Layer | What |
|---|---|
| Edge | CloudFront ×2 + CLOUDFRONT WAF; Cognito Hosted UI + REGIONAL WAF |
| Origin | Shared ALB (public) + dual-period `X-Origin-Verify` (**fully auto-rotated**) |
| Compute | ASG `-app` / `-web` in **private** subnets; 1× NAT Gateway (single AZ) |
| Data | RDS Postgres 16; runtime user `app`; master only in ensure-app Lambda |
| Auth | Cognito (invite-only, PKCE); CORS locked to site origin |
| Images | Base images pinned by digest (`node`, `nginx`, `postgres`) |
| Account | `infra/global`: state, CloudTrail, GuardDuty toggle, Route 53, GitHub OIDC |
| CI | Actions: Terraform · Deploy FE/BE · destroy-dev |

**App deploy:** push to `main` (auto) or `./scripts/deploy.sh <env> api|web|all`  
**Infra:** Actions → Terraform (`dev`/`prod` × `plan`/`apply`)  
**Scale:** `asg_desired_capacity` / `web_asg_desired_capacity` (capped; no CPU autoscaling)

---

## Capacity (CRUD estimates)

| Env | Concurrent | Light MAU | Notes |
|---|---|---|---|
| Dev (`t4g.micro` + `t4g.nano` + `db.t4g.micro`) | ~50–150 | ~500–2,000 | RAM-bound |
| Prod (`t4g.small` + `t4g.micro` + `db.t4g.small`) | ~150–400 | ~2,000–10,000 | Scale ASG; RDS ceilings first |

---

## Cost

| | Dev | Prod |
|---|---|---|
| Expected | **~$92–96/mo** | **~$157–172/mo** |
| Budget alert | $100 | $175 |

Details: [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md)

---

## Layout

```text
apps/backend|frontend     Node API + React SPA
deploy/                   docker-compose + nginx gateway (what EC2 runs)
infra/global              account stack
infra/environments/*      dev / prod
infra/backends/           S3 backend .hcl (gitignored)
infra/modules/*           networking, compute, edge, database, origin_rotate, cognito, …
scripts/deploy.sh         zero-downtime ASG refresh
scripts/tf-backend.sh     bootstrap / migrate / init S3 state
.github/workflows/        Terraform + deploy FE/BE
```

| Config | File |
|---|---|
| Account / domain / OIDC | `infra/global/terraform.tfvars` (gitignored) |
| Dev / prod sizes | `infra/environments/*/terraform.tfvars` |
| Local Docker | `deploy/.env` |

Use `*.tfvars.example` as templates. Never commit real tfvars.

---

## Quick start

```bash
# Local
cd deploy && cp .env.example .env && docker compose up --build

# AWS (full sequence in CHECKLIST.md)
aws login --profile andrei-login
./scripts/tf-backend.sh bootstrap-global
./scripts/tf-backend.sh migrate global
cd infra/global && terraform output name_servers   # → registrar NS
./scripts/tf-backend.sh init dev
# Prefer: Actions → Terraform → dev × apply
```
