# Security hostility report

**Date:** 2026-08-09  
**Scope:** Live-oriented review of `E:\popo` — Terraform infra, deploy/gateway overlays, GitHub OIDC/CI, Cognito, and React/Node app authz.  
**Method:** Four parallel deep-dive agents (edge/WAF, auth/RBAC, compute/IAM/CI, app exploit hunt) plus a branch-diff security review. Claims in `SECURITY_CHECK.md` / `EXPLOIT_PATHS.md` were checked against code, not trusted.

**Overall:** Stack is stronger than a typical CRUD template (private ASGs, IMDSv2, JWT checks, dual-period origin rotate, Cognito regional WAF). Highest residual risk remains **account takeover if GitHub is poisoned** (mitigated 2026-08-09: OIDC pin + deny self-escalation + deploy role) and **foreign-CloudFront + origin secret** (accepted design). Docs/boot mismatch for container hardening is **fixed in code** (prefer repo compose).

### Remediation progress (2026-08-09)

| ID | Status |
|---|---|
| C1 OIDC `repo:*` | **Fixed** — trust `main` + `environment:dev\|prod` only |
| C2 CI self-escalation | **Fixed** — explicit Deny on CI role mutation; `popo-github-deploy` added |
| H4 Boot overlay clobber | **Fixed** — prefer repo hardened deploy/; overlay keeps cap_drop/XFF/limits |
| H5 XFF / trust proxy | **Mitigated** — overlay + templates set `$proxy_add_x_forwarded_for` |
| H6 Origin-rotate `*` IAM | **Fixed** — CF ARNs + tagged SSM + named ASG refresh |
| H7 `app_git_url` injection | **Mitigated** — URL allowlist + reject shell metacharacters |
| H8 Web/app secrets tags | **Fixed** — ARN-scoped; deny `rds!*` on app |
| M3/M4 Admin mint / last-admin | **Fixed** — invite/API cannot assign admin; last-admin guards |
| M9 Viewer directory list | **Fixed** — viewer has no `users:read` |
| M10 Health fingerprint | **Fixed** — `{ok:true}` only |
| M11 SKIP_ORIGIN default | **Fixed** — compose default `0` |
| H1–H3 foreign CF / git tip / dual-period | **Open** — needs VPC origin / ECR immutability (larger change) |

| Severity | Count (deduped) |
|---|---|
| Critical | 2 |
| High | 8 |
| Medium | 14 |
| Low / Info | 12 |

---

## Critical

### C1 — GitHub OIDC trusts any ref (`repo:ORG/REPO:*`)
**Attack path:** Any branch/tag/PR workflow that hardcodes `arn:aws:iam::<account>:role/popo-github-terraform` can `AssumeRoleWithWebIdentity`. Environment approvals only gate jobs that *opt into* Environments — they do not constrain the IAM trust policy.

**Evidence:** `infra/global/main.tf` (`StringLike` `sub` = `repo:${var.github_repository}:*` plus nID wildcard). Deploy + Terraform workflows all assume `vars.AWS_ROLE_ARN`.

**Remediation:** Pin trust to `ref:refs/heads/main` and/or `environment:dev` / `environment:prod`. Separate roles per env and per purpose (plan / apply / deploy).

### C2 — CI role can self-escalate to admin-equivalent
**Attack path:** Assumed CI role → `iam:PutRolePolicy` / `AttachRolePolicy` on `popo-*` (includes `popo-github-terraform` itself) → attach `*` → full account (secrets, ASGs, RDS, IAM).

**Evidence:** `PowerUserAccess` + `ProjectIamLifecycle` in `infra/global/main.tf`. Documented in `EXPLOIT_PATHS.md` §3 as “Low”; impact is Critical if CI is poisoned.

**Remediation:** Permissions boundary forbidding self-mutation; deny IAM write on the CI role ARN; replace PowerUser with least-privilege custom policies; split deploy-only role (ASG refresh only).

---

## High

### H1 — Foreign CloudFront bypasses *your* WAF / IP allowlist
ALB is public and allows the **shared** CloudFront origin-facing prefix list. An attacker’s distribution pointed at `origin-dev.*` / `origin-api-dev.*` never hits your CLOUDFRONT WAF. Tenant gate becomes `X-Origin-Verify` only (accepted design residual, but allowlist is **not** origin protection).

**Evidence:** `infra/modules/security_groups`, public origin Route53 aliases, `SECURITY_CHECK` / `EXPLOIT_PATHS` §1.

**Remediation:** Private ALB / CloudFront VPC origin; treat origin secret + rotation as mandatory; do not advertise origin hostnames.

### H2 — Origin secret (+ dual-period) = full app via foreign CF
Leak of `current` or `previous` (state, CF config API, instance `.env`, logs) + foreign CF → SPA/API without your allowlist/rate limits until that value ages out of both periods (~up to ~2 weeks with weekly rotate).

**Remediation:** Private origin; shorten dual-period; incident force-rotate; scope who can `GetDistributionConfig` / read SM.

### H3 — Unpinned `git clone` tip is the real deploy
CI builds images then only ASG-refreshes. Instances `git clone --depth 1 "${app_git_url}"` and rebuild. Compromised default branch of `app_git_url` = fleet RCE with app DB secret + Cognito admin on `-app`.

**Evidence:** `infra/modules/compute/user_data.sh.tftpl`; `.github/workflows/deploy-*.yml`.

**Remediation:** Immutable digests from ECR/GHCR; pin commit SHA; CI as sole build authority.

### H4 — Boot overlay drops claimed container / nginx hardening
`SECURITY_CHECK` claims `cap_drop`, RO API FS, mem/pid limits, nginx `limit_req`. Repo `deploy/` has them; **user_data overwrites** compose + nginx with a minimal overlay (no `cap_drop` / `read_only` / `limit_req`; weak XFF). Live ASGs match overlay, not the repo templates.

**Evidence:** `user_data.sh.tftpl`, `scripts/ssm-patch-gateway.sh`.

**Remediation:** Stop clobbering; run repo `deploy/docker-compose.yml` + `nginx.*.conf.template` as-is.

### H5 — `TRUST_PROXY_HOPS=3` + overlay nginx → rate-limit IP spoofing
Overlay does not rewrite `X-Forwarded-For` with `$proxy_add_x_forwarded_for`. Viewer-controlled XFF can become Express `req.ip` → bypass API / invite rate limits.

**Evidence:** `apps/backend/src/config.ts`, user_data overlay vs `deploy/gateway/nginx.api.conf.template`.

**Remediation:** Restore proper XFF at nginx; pin hops to real chain; rate-limit admin invites by Cognito `sub` after auth.

### H6 — Origin-rotate IAM is account-wide for CF + SSM
Compromise of rotate role → `cloudfront:UpdateDistribution` / `ssm:SendCommand` on `*` → any distribution / any managed instance.

**Evidence:** `infra/modules/origin_rotate/main.tf`.

**Remediation:** Scope to named distribution ARNs and tagged ASG instances; document `AWS-RunShellScript` only.

### H7 — Terraform / CI injection via `app_git_url` and Actions `sed` into tfvars
Untrusted `APP_GIT_URL` / variable content interpolated into shell `git clone` and double-quoted `sed` can break out to root on boot or corrupt HCL.

**Evidence:** `user_data.sh.tftpl`; `.github/workflows/terraform.yml`.

**Remediation:** Strict URL allowlist; never shell-interpolate Actions vars; signed tfvars artifacts.

### H8 — Web IAM can read all env-tagged secrets (incl. DB app)
Docs say web has no DB secret. Code grants web the same tag-conditioned `secretsmanager:GetSecretValue` on `Resource = "*"` as app.

**Evidence:** `infra/modules/compute/main.tf` `web_secrets_read` vs `secrets_read`.

**Remediation:** ARN-scope web to origin secret only; ARN-scope app to origin + `db-app`; deny master/`rds!db-*`.

---

## Medium

| ID | Finding | Notes |
|---|---|---|
| M1 | Dev Cognito `allow_self_signup = true` | Contradicts “invite-only” docs/comments; SPA exposes signup. Prod correctly `false`. Enabled by operator request 2026-08-09. |
| M2 | Auto-provision local user on any valid access token | Bypass of invite-only directory at app layer (`users.ts` / `middleware.ts`). |
| M3 | Invite/role APIs can mint `admin` | No privilege ceiling / step-up; frontend defaults member but API does not. |
| M4 | No last-admin / self-delete guards | Compromised admin can lock out the plane. |
| M5 | Persistent `BOOTSTRAP_ADMIN_EMAILS` | Re-grants admin on first local create after wipe / orphan Cognito user. |
| M6 | MFA optional (dev + prod) | Password spray / phish → full session. |
| M7 | Access JWT usable until expiry after disable | ~1h residual; revocation not checked by API. |
| M8 | OIDC `nonce` never validated | ID token only base64-decoded for display claims. |
| M9 | `viewer` can list full user directory | Cognito sub, roles, permissions. |
| M10 | Open `/api/health` (+ metadata) via foreign CF | No origin secret; fingerprints env/auth/directory. |
| M11 | Compose default `SKIP_ORIGIN_CHECK=1` | Safe on AWS user_data (`0`); footgun for any other deploy. |
| M12 | TF state bucket TLS-only, no principal lock | CI PowerUser can read state → secrets. |
| M13 | `ensure_app` grants `CREATE` + `ALL` on `public` | Broader than “DML-only” claim. |
| M14 | Unauthenticated compose binary curl fallback | No checksum on boot path. |
| M15 | Floating AL2023 AMI SSM parameter | Not pinned. |
| M16 | GuardDuty off in global tfvars | Detection gap. |
| M17 | Deploy workflows reuse Terraform PowerUser role | CD = account-wide power. |
| M18 | Cognito IPv6 `/64` allowlist is wide | Shared residential prefix can reach Hosted UI. |

---

## Low / Info

- Public origin DNS eases ALB targeting (H1).
- WAF lacks AmazonIpReputation / AnonymousIP / SQLi groups (worse on public prod).
- No CF / ALB / WAF access logging in Terraform.
- Account ID + origin secret **ARN** hardcoded in `scripts/*` (recon).
- Empty `previous` sentinel is brittle (currently mitigated with `__none__`).
- Latent `requireGroups` Cognito bridge unused — dangerous if wired later.
- `/api/info` hardcodes misleading MFA / invite-only strings.
- Prod SPA still shows signup CTA while Cognito blocks it.
- Secrets `recovery_window_in_days = 0`.
- Patch window reboot on desired=1 → availability / delayed CVE close.
- sessionStorage holds tokens; CloudFront CSP exists when domain set — XSS still ATO.
- JWT issuer / JWKS / `token_use` / `client_id` checks — **OK**.
- First-user-becomes-admin removed — **OK**.
- IMDSv2 hop=1, no SSH, DB private + `force_ssl` — **OK**.
- Prod Cognito no localhost callbacks / no self-signup — **OK**.

---

## Accepted risks (already documented — still real)

1. Internet-facing ALB + shared CloudFront prefix list; origin secret is the tenant gate.  
2. Daily root CLI (ops).  
3. Prod shares AWS account with dev.  
4. Optional Cognito MFA.  
5. Single-AZ NAT.

---

## What held up under review

- Access JWT validation (issuer, RS256 JWKS, `token_use=access`, audience/`client_id`).
- Admin routes behind `requireAuth` + permission checks (no anonymous admin API).
- PKCE S256 + OAuth `state` check on SPA.
- AWS path forces `SKIP_ORIGIN_CHECK=0`.
- App IAM does not receive RDS master by ARN (ensure-app only) — residual is tag footgun (H8/M).
- Private app/web subnets, DB SG limited to app + ensure-app, DB zero egress.
- Digest-pinned Node/nginx base images in Dockerfiles.
- Cognito REGIONAL WAF + CF managed rules + rate limits (on *your* edge only).

---

## Priority remediation (ROI order)

1. **OIDC trust + CI IAM** — pin `sub`; kill self-`PutRolePolicy`; split deploy vs Terraform roles; permissions boundary.  
2. **Immutable deploys** — stop tip `git clone`; promote digests from registry.  
3. **Stop user_data clobber** — restore hardened compose/nginx (cap_drop, RO FS, limit_req, XFF).  
4. **Least-privilege secrets** — ARN-scope web vs app; deny master tags.  
5. **Origin path** — private VPC origin when budget allows; until then shorten dual-period + force-rotate runbook; slim `/api/health`.  
6. **Auth posture** — decide invite-only vs self-signup and align Cognito + SPA + `users.ts` sync; enable MFA in prod; last-admin guards; forbid API `roles:["admin"]` without step-up.  
7. **Observability** — GuardDuty on; CF/ALB/WAF logs; state bucket principal lock.

---

## Agent map

| Agent | Focus |
|---|---|
| [Edge/WAF](b84454a8-a59b-460b-9b2f-144f94c16a0a) | CloudFront, ALB, origin secret, nginx, WAF |
| [Auth/RBAC](640a959a-3b80-4c90-966f-d92d8a08b4f7) | Cognito, JWT, admin APIs, CORS, tokens |
| [Compute/IAM/CI](59cdd44f-e418-49fe-8c56-cffd9e8be391) | user_data, OIDC, secrets, Lambda, state |
| [App exploit hunt](73cd28a3-aedc-48b1-a110-2264b9156227) | Cross-check docs vs code, deploy gaps |
| [Diff security review](d753a9bc-2597-4257-a9b1-ab85544e0119) | Branch/local change security review |

---

## Notes

- This report did **not** run live offensive traffic against production (none applied). Dev was previously exercised for origin rotate, WAF rate limits, and Cognito IPv6 allowlist.  
- Dev currently has **self-signup on** (operator request). Treat M1 as intentional until flipped back.  
- Do not commit secrets; this report intentionally omits origin-header values.
