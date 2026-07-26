# Go-Live Checklist — what YOU still have to do

Everything code-side is done and locally verified (see §4). The items below are the
manual/account-level steps that Terraform cannot do for you, in the order you should
do them.

---

## 1. Before `terraform apply`

### 1.1 Stop using the root account (highest-impact item)
Every apply so far ran as `arn:aws:iam::<account>:root`. Do this once:

1. AWS Console → IAM → create a user (or IAM Identity Center user) named e.g. `admin-you`.
2. Attach `AdministratorAccess` (tighten later).
3. Enable **MFA** on both this user **and** on root.
4. Create an access key for the new user, then run `aws configure --profile popo-admin`.
5. Use `$env:AWS_PROFILE = "popo-admin"` for all future Terraform/CLI work.
6. Delete any root access keys. Root is for billing/account recovery only from now on.

### 1.2 Activate cost allocation tags (budget alerts do NOT work without this)
The budget in `modules/observability` filters on the `Environment` tag. AWS ignores
tags in billing until they are activated:

1. Console → **Billing & Cost Management → Cost allocation tags**.
2. Activate `Environment` and `Application` as user-defined cost allocation tags.
3. Wait up to 24h for them to appear in billing data.

Until then the budget tracks **$0** and the $25 alert will never fire.

### 1.3 Fill in `terraform.tfvars`
In `infra/global/terraform.tfvars` **and** `infra/environments/dev/terraform.tfvars`:

- `alert_email` — replace `REPLACE_ME@example.com` with a real inbox.
- `app_git_url` — leave `""` for the bootstrap UI, or set your repo URL (must be
  clonable from the instance, i.e. public or with a deploy token) to run the full
  React/Node stack from `apps/` + `deploy/`.
- `allowed_ip_cidrs` — dev is pre-set to your IP (`81.196.154.44/32`); only that IP
  gets past the WAF. If your ISP rotates your IP and the site starts returning 403,
  run `curl https://checkip.amazonaws.com`, update the value, `terraform apply`
  (WAF ipset updates in ~1 min, no instance restart). Set `[]` to open it up.

`*.tfvars` is gitignored — keep a copy somewhere safe.

## 2. Apply

```powershell
# 1. Account-level stack FIRST (state bucket, CloudTrail, root alerts,
#    GuardDuty, Route 53 zone for andrei-vataselu.online)
cd infra/global
terraform init
terraform apply   # ~$1.50-5.50/mo, mostly GuardDuty (enable_guardduty = false to skip)

# 2. SWITCH NAMESERVERS AT NAMECHEAP (manual, required before step 3):
#    terraform output name_servers   -> copy the 4 values
#    Namecheap -> Domain List -> andrei-vataselu.online -> Nameservers
#    -> Custom DNS -> paste all 4 -> save. Propagation: minutes to a few hours.
#    Verify before continuing:  nslookup -type=NS andrei-vataselu.online
#    (must return awsdns-* servers, otherwise ACM validation and Let's
#    Encrypt in step 3 will hang/fail)

# 3. The dev environment
cd ../environments/dev
terraform init
terraform plan    # review: ~45 resources, no surprises
terraform apply   # ACM cert validation takes a few minutes after NS switch

# 4. Migrate dev state to the S3 bucket the global stack just created:
#    - versions.tf: uncomment backend "s3", replace ACCOUNT_ID
#      (bucket name is in the global stack's `tfstate_bucket` output)
terraform init -migrate-state
#    - then delete the local terraform.tfstate* files
```

## 3. Immediately after `apply`

| # | Step | Where |
|---|------|-------|
| 1 | Confirm **ALL SNS subscription emails** — you'll get three: budget/alarms (dev), root alerts eu-west-1, root alerts us-east-1. Alerts are silently dropped until you click each link | Your inbox |
| 2 | Attach the **CloudFront Free flat-rate plan** to the new distribution (dev). Prod later gets Pro/Business | Console → CloudFront → Distributions → *popo-dev* → Plan |
| 3 | Open `https://dev.andrei-vataselu.online` (also in `terraform output site_url`) and check the site loads and `/api/health` returns `{"ok":true}` | Browser |
| 4 | Verify direct-to-EC2 access is refused: `curl http://<ec2_public_dns>` from your machine should time out (SG allows only CloudFront IPs) | Terminal |
| 5 | Shell access when needed: **SSM Session Manager** (Console → EC2 → Connect → Session Manager). There is no SSH key on purpose | Console |

## 4. What was verified locally (2026-07-26)

Full Docker stack (`deploy/docker-compose.yml` — identical to what EC2 runs):

| Test | Result |
|------|--------|
| `GET /` via gateway → React app HTML | 200 |
| `GET /api/health`, `/api/info` via gateway | 200, correct JSON |
| API 404 handling | 404 `{"ok":false,"error":"Not found"}` |
| CORS: foreign `Origin` gets no `Access-Control-Allow-Origin`; whitelisted origin (via `ALLOWED_ORIGINS`) gets it | pass |
| Helmet security headers on API + gateway headers (`nosniff`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`) on all responses | pass |
| Disallowed HTTP method (`TRACE`) | 405 |
| Per-IP rate limit: 60-request burst on `/api/health` | 28 rejected with 503 |
| Origin secret enforcement (`SKIP_ORIGIN_CHECK=0`): no/wrong `X-Origin-Verify` → 403, correct value → 200 | pass |
| API container health check | healthy |

`terraform validate` passes for both dev and prod.

## 5. Known gaps you accepted or still owe (also in README)

Ordered by what I'd do first:

1. **Cost allocation tags** — §1.2 above; alerts are dead until done.
2. **Root account retirement** — §1.1 above.
3. **Nameserver switch at Namecheap** — §2 step 2 above. Everything domain-related
   (ACM validation, Let's Encrypt on the instance, the site itself) depends on it.
4. **State migration** — §2 step 3 above; the bucket exists after the global apply,
   the migration itself is one `terraform init -migrate-state` per env.
5. **Wiring the API to RDS** — the API doesn't talk to Postgres yet. When you do:
   create an **app-specific DB user** and store its credentials in a Secrets Manager
   secret **tagged** `Application=template`, `Environment=dev` — the EC2 role can only
   read secrets with those tags, and the RDS-managed master secret is *not* tagged, so
   the instance intentionally cannot read the master password.
6. **Log shipping** — the CloudWatch log group `/popo/dev/app` exists but nothing
   ships to it yet; container logs stay on the instance (now rotated, max ~30MB per
   container). Optional: install the CloudWatch agent via user_data.
7. **Cost anomaly monitors overlap** — dev and prod each create an account-wide
   SERVICE monitor, so you may get duplicate anomaly emails. Harmless; consolidate to
   one env if it annoys you.
8. **Image digests** — Docker base images are pinned by tag, not digest. Pin digests
   when you set up CI.

Resolved since the last revision (now in Terraform): ~~CloudTrail/GuardDuty~~
(`infra/global`), ~~patching cadence~~ (weekly SSM patch window, Sun 03:00 UTC),
~~VPC flow logs~~ (REJECT-only, 14d), ~~remote state bucket~~ (`infra/global`).

## 6. Routine operations

| Task | How |
|------|-----|
| Run the stack locally | `cd deploy && copy .env.example .env && docker compose up --build` → http://localhost |
| Deploy app changes to EC2 | Push to the repo in `app_git_url`, then `terraform apply -replace=module.compute.aws_instance.app` (stateless instance rebuilds itself in ~5 min) |
| Shell on the instance | SSM Session Manager, never SSH |
| Rotate the origin secret | `terraform apply -replace=random_password.origin_header` (updates Secrets Manager + CloudFront; replace the instance after so nginx picks it up) |
| Tear down dev | `terraform destroy` in `infra/environments/dev` (RDS final snapshot is skipped in dev by design) |
| Monthly restore drill (prod) | Restore the latest RDS snapshot to a temp instance, check the data, delete it same day |
