# What's Left — final review, grades, and remaining work

Date of review: 2026-07-26. Companion docs: `README.md` (architecture + security
scorecard), `GO_LIVE_CHECKLIST.md` (step-by-step go-live), `infra/COST_GATE.txt`
(cost ceiling per stack).

---

## 1. Final grades

|  | **DEV** | **PROD** |
|---|---|---|
| **Security** | **9 / 10** | **8 / 10** |
| **Cost predictability** | **9 / 10** (~$28–30/mo, all fixed-size) | **9 / 10** (~$88+/mo, all fixed-size) |

Grades assume the stacks are applied with `andrei-vataselu.online` delegated to
Route 53 (nameserver switch at Namecheap — see `GO_LIVE_CHECKLIST.md` §2).

The former #1 gap — plain HTTP between CloudFront and the origin — is **closed**:
the domain gives CloudFront an ACM cert for viewers (`dev.<domain>`, apex+`www`),
and the instance gets a Let's Encrypt cert (DNS-01, auto-renewed) for
`origin-dev.<domain>` / `origin.<domain>`, with the CloudFront origin set to
`https-only`. Prod's Cognito localhost callback URLs are gone too.

### Why dev scores higher than prod
Dev is **locked to your IP** (`81.196.154.44/32`) at the WAF, so the entire
application surface is unreachable for the rest of the internet. Prod is
necessarily public and shares the AWS account with dev (no blast-radius
isolation, no SCPs).

### What keeps the scores where they are
- The EC2 NIC has a **public IP** (inherent to the lower-cost design; only the
  ~$200/mo CloudFront Business private VPC origin removes it).
- You still operate as the **root user** (alerted on now, but not retired).
- State not yet migrated to the encrypted S3 backend (one command, see below).
- Prod: `app_git_url` empty — it would serve the bootstrap page, not your app.

### Paths upward
- **Dev → 9.5 / Prod → 8.5**: retire root + migrate state (near-zero effort/cost).
- **Beyond**: CloudFront Business private VPC origin (~$200/mo) and a separate
  prod account under Organizations. Not worth it before you have users.

---

## 2. Remaining TODO (ordered)

### Must do before first deploy
| # | Task | Effort |
|---|---|---|
| 1 | Create an IAM admin with MFA, stop using root (`GO_LIVE_CHECKLIST.md` §1.1) | 15 min |
| 2 | Activate `Environment` + `Application` cost allocation tags in Billing — **budget alerts track $0 until this is done** (§1.2) | 2 min + 24h wait |
| 3 | Set `alert_email` in `infra/global/terraform.tfvars` AND `infra/environments/dev/terraform.tfvars` (both are placeholders) | 1 min |
| 4 | Apply `infra/global` (state bucket, CloudTrail, root alerts, GuardDuty, Route 53 zone) | 5 min |
| 5 | **Switch Namecheap nameservers** to the 4 values in the global `name_servers` output (Domain List → Nameservers → Custom DNS). Verify with `nslookup -type=NS andrei-vataselu.online` before continuing | 5 min + propagation |
| 6 | Apply `infra/environments/dev`, then confirm all 3 SNS emails | 20 min |
| 7 | Attach the CloudFront **Free** flat-rate plan to the dev distribution (console-only) | 2 min |
| 8 | Migrate state: uncomment `backend "s3"` in `versions.tf`, `terraform init -migrate-state`, delete local state files | 5 min |

### Before prod goes live
| # | Task | Notes |
|---|---|---|
| 1 | Set `app_git_url` in prod tfvars | Otherwise prod serves the bootstrap placeholder page |
| 2 | Attach CloudFront **Pro** plan to the prod distribution | ~$15/mo, included in the $88 estimate |
| 3 | Wire the API to RDS with an **app-specific DB user** whose secret is tagged `Application`/`Environment` | The instance role cannot read the untagged RDS master secret — intentional |
| 4 | Monthly restore drill: restore latest RDS snapshot to a temp instance, verify, delete same day | The only proof backups work |

Done since first draft: ~~buy a domain~~ (`andrei-vataselu.online`, wired end to
end: Route 53 zone, ACM viewer cert, `https-only` origin with auto-renewed
Let's Encrypt, real Cognito URLs — prod's localhost callbacks removed).

### Optional / later
- CloudWatch agent to ship container logs off-instance (the `/popo/<env>/app` log group exists but is unused).
- Pin Docker base images by digest when you add CI.
- Consolidate the duplicate account-wide cost anomaly monitors (dev + prod each create one → duplicate emails).
- Harden the bootstrap gateway in `user_data.sh.tftpl` (plain nginx, no rate limits) — low value since it only runs until `app_git_url` is set, and the origin-secret check is still enforced.
- Separate AWS account for prod under Organizations with SCP guardrails.

---

## 3. Security review findings (this pass)

Fixed now:
- **DNS egress tightened** — the app SG allowed UDP/53 to `0.0.0.0/0`. The VPC's
  Route 53 Resolver bypasses SG filtering anyway, so the wide rule only enabled
  DNS exfiltration to external resolvers. Now restricted to the VPC CIDR.
- `terraform.tfvars.example` (dev) was missing `allowed_ip_cidrs`, so a fresh
  clone would deploy dev **open to the internet** without noticing.

Reviewed and OK (worth knowing):
- **IMDS hop limit = 1** means Docker containers cannot reach the instance
  metadata service (one extra network hop). This is intentional and good — the
  host fetches the origin secret, containers get it via env file.
- `apply_immediately = true` on RDS means parameter/tier changes restart the DB
  immediately, including in prod. Acceptable now; revisit when prod has users.
- Bootstrap page and the React app pull Google Fonts from `fonts.googleapis.com`
  — a third-party dependency that would also complicate a future strict CSP.
  Self-host the fonts when you care.
- DB SG remains zero-egress; stateful replies still flow. Verified unchanged.

Accepted trade-offs (unchanged, documented in README §2): public EC2 NIC,
HTTP CloudFront→origin, single AWS account.

## 4. Cost review findings (this pass)

The architecture is already fixed-cost by design (no NAT, no autoscaling, no
per-request services beyond the flat CloudFront plan). What's left:

| Idea | Saves | Verdict |
|---|---|---|
| **Stop dev outside working hours** (EC2 + RDS stop; RDS auto-restarts after 7 days) | up to ~$9–12/mo of the $18 compute/DB share | Worth it if dev sits idle most days; EIP + storage (~$9/mo) still bill while stopped |
| Drop dev RDS entirely until the API actually uses Postgres | ~$14/mo → dev lands **under the $25 budget** | Strongest single lever; re-apply the module when needed |
| Shrink dev root volume 30 → 20 GB | ~$0.90/mo | Marginal; 30 GB gives headroom for Docker build layers |
| `enable_guardduty = false` in `infra/global` | ~$1–4/mo | Keep it on; it's the only paid detection you have |
| Skip the prod Pro plan until prod launches | $15/mo | Don't create the prod stack at all until needed — $0 is cheaper than $88 |

Non-findings: CloudWatch retention is already bounded (14d), logs are rotated on
disk, budgets/anomaly detection are already in place, and every instance size is
pinned. No hidden per-request cost paths were found.
