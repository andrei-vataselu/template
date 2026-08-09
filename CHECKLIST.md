# Checklist

Ordered ops. See also [`README.md`](README.md) · [`SECURITY_CHECK.md`](SECURITY_CHECK.md) · [`EXPLOIT_PATHS.md`](EXPLOIT_PATHS.md) · [`COST_PREDICTABILITY.md`](COST_PREDICTABILITY.md).

---

## A. Before any apply

- [ ] Cost allocation tags `Application` + `Environment` **Active** (Billing)
- [ ] `alert_email` set in global + env tfvars
- [ ] AWS CLI: `aws login --profile andrei-login` (prefer IAM + MFA over root for daily use)
- [ ] Copy `*.tfvars.example` → `*.tfvars` (domain, git URL, IP allowlist, budgets)

---

## B. Account stack + DNS

```bash
aws login --profile andrei-login
./scripts/tf-backend.sh bootstrap-global
./scripts/tf-backend.sh migrate global
cd infra/global
terraform output name_servers
terraform output github_actions_role_arn
terraform output tfstate_bucket
```

- [ ] Global applied (state bucket, CloudTrail, Route 53, GitHub OIDC)
- [ ] Registrar NS → Route 53 `awsdns-*`
- [ ] Confirm SNS subscription emails (root-usage topics)
- [ ] GitHub Actions Variables (§G)

---

## C. Dev

- [ ] Apply via Actions → Terraform → `dev` × `apply`
- [ ] Confirm budget / alarm / origin-rotate SNS emails
- [ ] CloudFront console → attach **Free** flat-rate plan to the site distribution *(one-time manual AWS console step)*
- [ ] From allowlisted IP: site, API health, and Cognito Hosted UI (`auth.dev.<domain>`) work
- [ ] `-web` / `-app` ASGs private; ALB public; NAT OK; DB role `app` in use

After this apply, **origin secret rotation is fully automatic** (no further action from you).

---

## D. Day-2 (what runs by itself)

| Automation | What happens |
|---|---|
| Origin secret (weekly) | EventBridge → Lambda: write SM `{current,previous}` → SSM sync on all ASG instances (recreates gateway) → update CloudFront headers → start rolling ASG refreshes → SNS email |
| Origin secret (backup) | Cron every **1 minute** on each instance re-pulls SM and recreates gateway if changed |
| App DB role | Terraform apply / password replace → ensure-app Lambda creates/updates Postgres `app` |
| App deploys | Push to `main` touching `apps/frontend/**` or `apps/backend/**` → Actions roll the matching ASG |
| Health / 4xx / CPU / RDS | CloudWatch alarms → SNS |

| You still do (ops) | How |
|---|---|
| Local | `cd deploy && cp .env.example .env && docker compose up --build` |
| Infra change | Actions → Terraform → `plan`/`apply` |
| Scale | Edit `asg_desired_capacity` / `web_asg_*` → apply |
| Shell | SSM Session Manager |
| Tear down **dev** | Actions → destroy-dev |

---

## E. Before prod

Prod is ~$157–172/mo — do not apply until needed.

- [ ] GitHub Environment `prod` with required reviewers
- [ ] Apply via Actions (approval gate)
- [ ] Attach CloudFront **Pro** (~$15/mo) *(one-time console)*
- [ ] Monthly RDS restore drill

Origin rotation, DB `app` role ensure, FE/BE deploys on `main`, and alarms stay automatic in prod the same as dev.

---

## F. Optional later

- [ ] CloudWatch agent for container logs
- [ ] Separate AWS account for prod
- [ ] `require_mfa = true` on Cognito when UX allows
- [ ] Second NAT for multi-AZ egress HA (~+$32/mo)
- [ ] Re-pin image digests when bumping base images

---

## G. GitHub Actions

Repo → **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example |
|---|---|
| `AWS_ACCOUNT_ID` | account id |
| `AWS_ROLE_ARN` | `arn:aws:iam::<account>:role/popo-github-terraform` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<account>:role/popo-github-deploy` (FE/BE ASG roll) |
| `ALERT_EMAIL` | ops inbox |
| `DOMAIN_NAME` | apex domain |
| `APP_GIT_URL` | `https://github.com/<org>/<repo>.git` |

Environments: `dev`, `prod` (prod = required reviewer).

| Workflow | Use |
|---|---|
| [Terraform](.github/workflows/terraform.yml) | `dev`/`prod` × `plan`/`apply` |
| [Deploy frontend](.github/workflows/deploy-frontend.yml) | Auto on `main` for `apps/frontend/**`; manual for prod |
| [Deploy backend](.github/workflows/deploy-backend.yml) | Auto on `main` for `apps/backend/**`; manual for prod |
| [Terraform destroy (dev only)](.github/workflows/terraform-destroy-dev.yml) | Type `destroy-dev` |

`main` deploys target **dev**. Prod stays `workflow_dispatch` + Environment approval.

State: `s3://popo-tfstate-<ACCOUNT_ID>/{dev,prod}/terraform.tfstate`
