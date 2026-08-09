# Security check

Controls this stack enforces, remaining gaps, and how to verify.

|           | Dev        | Prod       |
| --------- | ---------- | ---------- |
| **Grade** | **9 / 10** | **8 / 10** |

Dev scores higher: WAF IP allowlist locks the site to your IP. Prod is public and shares the AWS account with dev.

**Companion docs:** [`README.md`](README.md) · [`CHECKLIST.md`](CHECKLIST.md) · [`BOOTSTRAP.md`](BOOTSTRAP.md) · [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md)

---

## Your progress

|     | Item                                                                               |
| --- | ---------------------------------------------------------------------------------- |
| ✅  | Cost allocation tags `Application` + `Environment` → **Active**                    |
| ✅  | Alert email `andreivataselu42@gmail.com`                                           |
| ✅  | GitHub repo **public**                                                             |
| ✅  | Global applied; state in S3; Namecheap NS → Route 53                               |
| ✅  | GitHub Variables + Environments; prod required reviewer                            |
| ✅  | Root MFA on; no root access keys; password policy; `andrei-cli` admin + RequireMFA |
| ✅  | Commit + push workflow; Actions workflow **Terraform** is active                   |
| ✅  | Dev apply via Actions succeeded                                                    |
| ⬜  | CloudFront Free + site/health verify                                               |
| ⬜  | Finish `andrei-cli` MFA + stop daily root _(deferred — optional)_                  |

---

## 1. Controls in place

### Edge & network

| Control                                                       | Status |
| ------------------------------------------------------------- | ------ |
| CloudFront TLS 1.2+, HTTPS redirect, HSTS + security headers  | ✅     |
| WAF managed rules (Common + KnownBadInputs) in **block** mode | ✅     |
| WAF per-IP rate limit (2000 req / 5 min)                      | ✅     |
| Dev WAF IP allowlist (`allowed_ip_cidrs`)                     | ✅     |
| ALB SG: CloudFront prefix list only (80/443)                  | ✅     |
| App SG: ALB only on :80 — no SSH/RDP                          | ✅     |
| DB SG: app SG only on :5432; **zero egress**                  | ✅     |
| No NAT; private DB RT has no IGW                              | ✅     |
| VPC Flow Logs (REJECT only, 14d)                              | ✅     |
| DNS egress limited to VPC CIDR                                | ✅     |

### Origin & TLS

| Control                                             | Status |
| --------------------------------------------------- | ------ |
| CloudFront → ALB **https-only** (with domain)       | ✅     |
| Regional ACM on ALB (`origin-*.domain`)             | ✅     |
| Viewer ACM on CloudFront (`dev.` / apex+`www`)      | ✅     |
| Origin secret in Secrets Manager (not in user-data) | ✅     |
| Gateway rejects bad/missing `X-Origin-Verify`       | ✅     |
| `/api/health` open for ALB health checks only       | ✅     |

### Compute & containers

| Control                                                     | Status |
| ----------------------------------------------------------- | ------ |
| IMDSv2 required, hop limit 1                                | ✅     |
| Encrypted gp3; SSM only (no SSH)                            | ✅     |
| Weekly SSM patch window                                     | ✅     |
| Hardened containers (`cap_drop`, mem/pid limits, RO API FS) | ✅     |
| ASG rolling refresh = zero-downtime deploys                 | ✅     |

### Data & auth

| Control                                                 | Status |
| ------------------------------------------------------- | ------ |
| RDS private, encrypted, `rds.force_ssl=1`               | ✅     |
| Master password in Secrets Manager                      | ✅     |
| Cognito: admin-only signup, MFA, PKCE, token revocation | ✅     |

### Account / CI

| Control                                                 | Status                                                  |
| ------------------------------------------------------- | ------------------------------------------------------- |
| CloudTrail management events (multi-region, validation) | ✅                                                      |
| Root usage → SNS email                                  | ✅                                                      |
| Root MFA; no root access keys; password policy          | ✅                                                      |
| IAM Access Analyzer                                     | ✅                                                      |
| GuardDuty                                               | ⬜ off (`SubscriptionRequiredException` — BOOTSTRAP §6) |
| S3 state: versioned, encrypted, TLS-only, lockfile      | ✅ in S3                                                |
| GitHub Actions OIDC (no long-lived AWS keys)            | ✅                                                      |
| Cost allocation tags activated in Billing               | ✅ **done by you**                                      |

---

## 2. Gaps that still cost points

Ops items (dev apply, commit/push) live in [`CHECKLIST.md`](CHECKLIST.md) / [`BOOTSTRAP.md`](BOOTSTRAP.md) — not scored here.

| #   | Gap                                                                      | Severity        | Fix                                                 |
| --- | ------------------------------------------------------------------------ | --------------- | --------------------------------------------------- |
| 1   | EC2 has a **public IP** (no NAT design)                                  | High (accepted) | CloudFront Business + private VPC origin (~$200/mo) |
| 2   | Daily CLI on **root** (`andrei-login`) — `andrei-cli` ready but deferred | Medium (ops)    | Optional: BOOTSTRAP §9                              |
| 3   | CI role = `AdministratorAccess`                                          | Medium          | Scope down after first green pipeline               |
| 4   | No WAF on Cognito hosted UI                                              | Low             | Optional                                            |
| 5   | Images pinned by tag, not digest                                         | Low             | Pin digests in CI                                   |
| 6   | Prod shares account with dev                                             | Medium          | Separate account + SCPs later                       |

---

## 3. Verify after deploy

```bash
curl -sI https://dev.andrei-vataselu.online | head
curl -s https://dev.andrei-vataselu.online/api/health
```

---

## 4. Path upward

- **→ 9.5:** first green pipeline plan + (optional) stop daily root
- **→ 10:** private VPC origin + separate prod account + scope CI role
