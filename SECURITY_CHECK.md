# Security check

Controls this stack enforces, remaining gaps, and how to verify.

| | Dev | Prod |
|---|---|---|
| **Grade** | **9 / 10** | **8.5 / 10** |

Dev scores higher: WAF IP allowlist on CloudFront + Cognito. Prod is public and shares the account with dev.

See also [`README.md`](README.md) · [`CHECKLIST.md`](CHECKLIST.md) · [`EXPLOIT_PATHS.md`](EXPLOIT_PATHS.md) · [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md).

---

## 1. Controls in place

### Edge & network

| Control | Status |
|---|---|
| CloudFront TLS 1.2+, HTTPS redirect, HSTS + security headers | ✅ |
| CLOUDFRONT WAF: Common + KnownBadInputs (block) + 2000/5 min rate | ✅ |
| REGIONAL WAF on Cognito Hosted UI: same managed rules + 300/5 min rate | ✅ |
| Dev WAF IP allowlist (`allowed_ip_cidrs` + Cognito `allowed_ipv6_cidrs`) on CF + Cognito | ✅ |
| ALB SG: CloudFront prefix list only (80/443) | ✅ |
| App/web SG: ALB only on :80 — no SSH/RDP | ✅ |
| DB SG: app SG + ensure-app Lambda only on :5432; **zero egress** | ✅ |
| App/web EC2 in **private** subnets (no public IP); 1× NAT egress | ✅ |
| Private DB RT has no IGW/NAT default route | ✅ |
| VPC Flow Logs (REJECT only, 14d) | ✅ |
| GitHub OIDC pinned to `main` + Environments; CI deny self-escalation; deploy role separate | ✅ |
| Web IAM: origin secret ARN only; App IAM: origin + db-app ARNs (deny `rds!*`) | ✅ |

### Origin & TLS

| Control | Status |
|---|---|
| CloudFront → ALB **https-only** (with domain) | ✅ |
| Regional ACM on ALB (`origin-*.domain`) | ✅ |
| Viewer ACM on CloudFront | ✅ |
| Origin secret in Secrets Manager (JSON `current`/`previous`) | ✅ |
| Weekly origin-secret rotation (fully auto: SM → SSM sync → CF → ASG refresh) | ✅ |
| Gateway accepts current **and** previous header (dual-period) | ✅ |
| Instance cron syncs origin secret every **1 minute** (backup) | ✅ |
| ALB target 4xx spike alarm (SNS) | ✅ |
| Gateway rejects bad/missing `X-Origin-Verify` | ✅ |
| `/api/health` open for ALB health checks only | ✅ |

### Compute & containers

| Control | Status |
|---|---|
| IMDSv2 required, hop limit 1 | ✅ |
| Encrypted gp3; SSM only (no SSH) | ✅ |
| Weekly SSM patch window (app + web ASGs) | ✅ |
| Hardened containers (`cap_drop`, mem/pid limits, RO API FS) | ✅ (repo compose; boot prefers it) |
| ASG rolling refresh = zero-downtime deploys | ✅ |
| FE / BE on separate instances (`-web` / `-app`) | ✅ |
| Web IAM: origin secret ARN only — no DB / Cognito admin | ✅ |
| App IAM: origin + db-app ARNs only; deny `rds!*` master | ✅ |
| Base images pinned by digest (`node`, `nginx`, `postgres`) | ✅ |
| GitHub OIDC: `main` + Environments; CI deny self-escalation; separate deploy role | ✅ |
| Invite cannot mint `admin`; last-admin guards; opaque `/api/health` | ✅ |

### Data & auth

| Control | Status |
|---|---|
| RDS private, encrypted, `rds.force_ssl=1` | ✅ |
| RDS TLS verified against RDS CA bundle | ✅ |
| Master password in Secrets Manager (ensure-app Lambda / break-glass only) | ✅ |
| VPC Lambda ensures Postgres role `app` on apply / password rotate | ✅ |
| API runtime DB user `app` + ARN-scoped secret | ✅ |
| Cognito: PKCE + token revocation; prod invite-only (dev may allow self-signup) | ✅ |
| No `localhost` redirect URIs on the prod pool | ✅ |
| No first-user-becomes-admin fallback | ✅ |
| API CORS locked to site origin (`ALLOWED_ORIGINS`) | ✅ |
| Rate limit keyed on real client IP (`TRUST_PROXY_HOPS`) | ✅ |

### Account / CI

| Control | Status |
|---|---|
| CloudTrail management events (multi-region, validation) | ✅ |
| Root usage → SNS email | ✅ |
| Root MFA; no root access keys; password policy | ✅ |
| IAM Access Analyzer | ✅ |
| GuardDuty | Toggle via `enable_guardduty` |
| S3 state: versioned, encrypted, TLS-only, lockfile | ✅ |
| GitHub Actions OIDC (no long-lived AWS keys) | ✅ |
| Cost allocation tags in Billing | Required before apply |

---

## 2. Open gaps

| # | Gap | Severity | Fix |
|---|---|---|---|
| 1 | ALB is internet-facing; shared CloudFront prefix list (origin secret is the gate) | Low (accepted) | Auto weekly rotate + SSM sync + ASG refresh + 4xx alarm. Full close = VPC origin (~$200/mo) |
| 2 | Daily CLI on root instead of IAM + MFA | Medium (ops) | Use IAM admin daily |
| 3 | CI role PowerUser + `popo-*` IAM (self-escalation **denied** on CI roles; OIDC pinned to main/envs; deploy role separate) | Low | Permissions boundary / separate account still recommended |
| 4 | Prod shares account with dev | Medium | Separate account + SCPs later |
| 5 | MFA optional on Cognito pools | Low | `require_mfa = true` when UX allows |
| 6 | Single-AZ NAT — AZ failure loses private egress | Low (accepted) | Second NAT (~+$32/mo) |

---

## 3. Verify after deploy

```bash
curl -sI https://dev.<domain> | head
curl -s https://api-dev.<domain>/api/health
curl -sI https://auth.dev.<domain>/login | head
curl -s -X OPTIONS https://api-dev.<domain>/api/me \
  -H "Origin: https://dev.<domain>" \
  -H "Access-Control-Request-Method: GET" -i | head
```

---

## 4. Path upward

- **→ 9.5:** stop daily root; tighten CI IAM
- **→ 10:** private VPC origin + separate prod account
