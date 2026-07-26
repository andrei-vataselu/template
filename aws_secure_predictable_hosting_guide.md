# Secure and Cost-Predictable AWS Website Hosting

**Last verified:** 26 July 2026  
**Target region:** `eu-west-1` for the application, with `us-east-1` where CloudFront requires global resources  
**Objective:** Build a production website whose traffic-related AWS costs cannot grow unexpectedly, while maintaining a strong security posture.

> [!IMPORTANT]
> No internet-facing system can be guaranteed to be **100% secure**, **100% available**, or billed to exactly the same amount every month.
>
> The practical objective is to:
>
> 1. remove uncapped traffic and scaling costs;
> 2. make all remaining variable charges small, visible, and bounded;
> 3. fail safely by throttling or becoming temporarily unavailable instead of automatically increasing capacity and cost;
> 4. reduce the probability and impact of security incidents.

---

## 1. Recommended architecture

```text
Domain registrar
  |
  | Registrar MFA, transfer lock, auto-renewal
  v
Route 53 public hosted zone
  |
  | ALIAS A/AAAA records
  v
CloudFront Business flat-rate plan
  |
  |-- AWS WAF
  |-- DDoS protection
  |-- TLS certificate
  |-- rate limits
  |-- security headers
  |-- static-content caching
  |
  v
CloudFront VPC origin
  |
  v
Private EC2 application instance
  |-- no public IPv4 address
  |-- no SSH/RDP ingress
  |-- Nginx/reverse proxy
  |-- frontend and backend
  |-- Systems Manager access
  |
  v
Private RDS PostgreSQL Multi-AZ
  |-- encrypted
  |-- not publicly accessible
  |-- automated backups and PITR
  |-- deletion protection
  |
  +--> Secrets Manager
  +--> CloudWatch logs and alarms
  +--> SNS security/cost alerts

Users authenticate through:
Cognito User Pool
  |-- managed login or application login
  |-- OAuth 2.0 authorization-code flow with PKCE
  |-- TOTP/passkey MFA
  |-- separate regional WAF if required
```

### Why CloudFront Business

The current CloudFront flat-rate tiers are:

| Tier | Monthly price | Requests | Transfer | Private VPC origin |
|---|---:|---:|---:|---:|
| Free | $0 | 1 million | 100 GB | No |
| Pro | $15 | 10 million | 50 TB | No |
| Business | $200 | 125 million | 50 TB | Yes |
| Premium | $1,000 | 500 million | 50 TB | Yes |

The allowances are performance baselines rather than hard limits. AWS states that there are no overage charges for traffic spikes or attacks, although sustained excessive usage can eventually cause delivery-performance adjustments.

For the strongest origin protection, use **Business** because it supports a private VPC origin. The cheaper Pro tier requires a public origin or another supported public origin arrangement.

### Lower-cost compromise

A lower-cost design is possible:

```text
CloudFront Pro -> public EC2 origin restricted to CloudFront
```

Controls would include:

- EC2 security-group ingress only from the CloudFront managed prefix list;
- a secret origin header validated by Nginx;
- no SSH;
- WAF in front of the distribution;
- direct-origin hostname not advertised.

This is less secure than a VPC origin because the EC2 network interface remains publicly reachable. Use it only when the $200 Business plan is not affordable.

---

## 2. Security and predictability principles

### 2.1 Security principles

- Use defence in depth; no single control is sufficient.
- Keep the origin and database private.
- Give every identity and workload only the permissions it needs.
- Use temporary credentials instead of long-lived access keys.
- Authenticate users with Cognito, but perform authorisation again in the backend.
- Encrypt data in transit and at rest.
- Patch operating systems, application dependencies, and database engines.
- Centralise logs, but never retain logs indefinitely.
- Test backup restoration rather than only confirming that backups exist.
- Treat Terraform state as sensitive data.
- Assume that application-code vulnerabilities can bypass infrastructure controls.

### 2.2 Cost-predictability principles

- Use a CloudFront flat-rate plan for viewer traffic.
- Use fixed-size compute and database capacity.
- Disable automatic compute and storage scaling.
- Avoid services priced primarily per request or per GB for the main request path.
- Do not use a NAT Gateway.
- Avoid public IPv4 addresses.
- Bound log, backup, snapshot, image, and artifact retention.
- Use service quotas, IAM restrictions, and SCPs to prevent accidental expensive resources.
- Prefer throttling and graceful degradation over automatic expansion.
- Alert early, but never rely on AWS Budgets as a real-time hard stop.
- Keep the production workload in a separate AWS account.

---

## 3. Domain and DNS security

The domain can be purchased from any registrar. DNS can still be hosted in Route 53.

### Registrar checklist

- [ ] Enable phishing-resistant MFA or, at minimum, TOTP MFA.
- [ ] Use a unique password stored in a password manager.
- [ ] Enable registrar/transfer lock.
- [ ] Enable automatic renewal.
- [ ] Keep the payment method valid.
- [ ] Use an independent recovery email, not an address hosted only on the same domain.
- [ ] Verify the registrant email and contact information.
- [ ] Enable WHOIS privacy when supported.
- [ ] Record the renewal price, not only the first-year promotional price.
- [ ] Set a calendar reminder 30 and 60 days before renewal.
- [ ] Consider registry lock for a high-value domain.
- [ ] Limit registrar account access to the smallest possible number of people.

### Route 53 checklist

- [ ] Use one production hosted zone and avoid duplicates.
- [ ] Point the apex and `www` names to CloudFront with ALIAS A and AAAA records.
- [ ] Do not point any public DNS record directly to EC2 or RDS.
- [ ] Restrict permissions to change hosted zones and records.
- [ ] Enable CloudTrail management-event logging.
- [ ] Consider DNSSEC where justified.
- [ ] Treat Route 53 health checks and query logging as optional paid features.
- [ ] Attach the eligible hosted zone to the CloudFront flat-rate plan when supported by the plan configuration.

### DNSSEC caution

DNSSEC can reduce DNS-spoofing risks but adds operational complexity. A bad key rotation or delegation configuration can make the domain unreachable. Route 53 DNSSEC also uses KMS resources that may add small charges.

---

## 4. AWS account security

### Root account

- [ ] Enable at least two MFA devices where practical.
- [ ] Prefer a passkey or hardware security key.
- [ ] Do not create root access keys.
- [ ] Delete any existing root access keys.
- [ ] Do not use root for routine administration.
- [ ] Store root recovery information securely.
- [ ] Configure security, billing, and operations alternate contacts.
- [ ] Alert on root-account usage through CloudTrail/EventBridge.

### Administrator access

- [ ] Use IAM Identity Center or external identity federation.
- [ ] Require MFA.
- [ ] Use temporary role sessions.
- [ ] Do not create ordinary IAM users with permanent access keys unless unavoidable.
- [ ] Use separate roles for read-only, operations, security, billing, and Terraform deployment.
- [ ] Restrict who can change billing, WAF, CloudFront, Route 53, Cognito, KMS, IAM, and CloudTrail.
- [ ] Review unused access every month.
- [ ] Set maximum session durations appropriate to each role.
- [ ] Use IAM Access Analyzer to detect public and cross-account access.
- [ ] Use permission boundaries for delegated administration.

### Separate AWS account

Run the website in its own AWS account under AWS Organizations.

Benefits:

- spending is isolated;
- budgets and anomaly alerts are clearer;
- an application compromise has a smaller blast radius;
- an SCP can deny expensive or unsafe services;
- production permissions are easier to audit.

### Suggested SCP guardrails

Deny or tightly restrict:

- creating NAT Gateways;
- assigning public IPv4 addresses;
- making RDS publicly accessible;
- creating Auto Scaling groups with an approved maximum above one or two;
- enabling RDS storage autoscaling;
- launching unapproved EC2/RDS instance classes;
- creating resources outside `eu-west-1` and required global regions;
- disabling CloudTrail;
- deleting security logs;
- removing encryption;
- opening security groups to `0.0.0.0/0` or `::/0`, except approved edge resources;
- creating expensive Marketplace subscriptions;
- creating EKS clusters, OpenSearch domains, Redshift clusters, SageMaker endpoints, or other unapproved services;
- detaching the required WAF from CloudFront;
- cancelling the flat-rate plan without an approved break-glass role.

> [!WARNING]
> Test SCPs in a non-production account first. An incorrect deny policy can block legitimate recovery actions.

---

## 5. CloudFront configuration

### Required settings

- [ ] Use the Business flat-rate plan for a private VPC origin.
- [ ] Redirect HTTP to HTTPS.
- [ ] Use TLS 1.2 or newer.
- [ ] Use an ACM certificate in `us-east-1`.
- [ ] Enable IPv6 unless there is a documented reason not to.
- [ ] Attach the required CloudFront-scoped WAF.
- [ ] Configure the EC2 instance or private load balancer as a VPC origin.
- [ ] Ensure the origin has no public route or public IP.
- [ ] Use HTTPS from CloudFront to the origin.
- [ ] Allow only required HTTP methods per path.
- [ ] Enable compression for safe content types.
- [ ] Set sensible origin connection and response timeouts.
- [ ] Do not expose internal error details in custom error pages.
- [ ] Configure standard access logs only when required.
- [ ] Apply a finite retention policy to log storage.

### Cache behaviours

Recommended starting point:

| Path | Allowed methods | Cache | Authentication data |
|---|---|---|---|
| `/assets/*` | GET, HEAD | Long TTL | None |
| `/images/*` | GET, HEAD | Long TTL | None |
| `/public/*` | GET, HEAD | Moderate TTL | None |
| `/api/*` | Required API methods | Disabled | Forward required auth headers/cookies |
| `/login*` | GET, POST as required | Disabled | Forward required values |
| `/logout*` | GET, POST as required | Disabled | Forward required values |
| `/oauth2/*` | Required methods | Disabled | Forward required values |
| `/account/*` | Required methods | Disabled | Forward required values |
| `/admin/*` | Required methods | Disabled | Forward required values |

### Critical cache rule

Do not cache user-specific, authenticated, personalised, or permission-sensitive responses unless the full identity-dependent context is deliberately part of the cache key and the behaviour has been security-tested.

A dangerous configuration is:

```text
User A requests /account
CloudFront ignores the session cookie or Authorization header in its cache key
CloudFront stores User A's response
User B requests /account
CloudFront returns User A's cached response
```

The safest default for authenticated API routes is:

```text
minimum TTL = 0
default TTL = 0
maximum TTL = 0
```

### Response security headers

Use a CloudFront response-headers policy or application middleware for:

- `Strict-Transport-Security`
- `Content-Security-Policy`
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy`
- `Permissions-Policy`
- frame protection through CSP `frame-ancestors`
- secure cache-control directives for sensitive responses

Do not enable HSTS preload until HTTPS works reliably on every required subdomain and the consequences are understood.

### Flat-rate plan operational risks

- [ ] Monitor allowance notifications at 50%, 80%, and 100%.
- [ ] Document who can upgrade or downgrade the plan.
- [ ] Alert on pricing-plan subscription changes.
- [ ] Remember that disabling a distribution does not automatically cancel the plan.
- [ ] Remember that cancelling a paid plan takes effect at the end of the billing cycle.
- [ ] After cancellation, usage switches to pay-as-you-go pricing.
- [ ] Do not use unsupported CloudFront/WAF features without verifying plan compatibility.
- [ ] Confirm that the WAF remains associated; the flat-rate plan requires it.
- [ ] Confirm that any plan-associated resources are not shared in unsupported ways.

---

## 6. AWS WAF

WAF is essential but does not fix insecure application logic.

### Baseline rule strategy

Start new managed rules in **count** mode, review false positives, and then move them to **block**.

Suggested rule order:

1. emergency IP deny list;
2. admin-area IP allow list, when feasible;
3. request-size limits;
4. invalid method or path rules;
5. IP reputation rules;
6. known bad input rules;
7. SQL injection and XSS managed rules;
8. rate limit for authentication endpoints;
9. rate limit for expensive API endpoints;
10. broad per-IP rate limit;
11. default allow.

### Rate-limit separately

Use different rate limits for:

- `/login`
- `/signup`
- `/forgot-password`
- `/reset-password`
- `/oauth2/token`
- search endpoints
- export endpoints
- upload endpoints
- AI/LLM-backed endpoints
- database-heavy reporting endpoints
- admin endpoints

A single global rate limit is not sufficient. Expensive endpoints need stricter controls.

### Additional controls

- [ ] Block unexpected countries only when business requirements permit.
- [ ] Use CAPTCHA or challenge actions for suspicious public authentication traffic.
- [ ] Limit request body size.
- [ ] Reject unexpected content types.
- [ ] Reject unusual or unsupported HTTP methods.
- [ ] Log blocked requests with sensitive fields redacted.
- [ ] Alarm on sudden changes in allowed and blocked traffic.
- [ ] Test WAF bypass attempts against the origin.
- [ ] Keep an emergency rule ready to restrict the whole site.

### WAF limitations

WAF cannot reliably detect or prevent:

- broken object-level authorisation;
- insecure role checks;
- business-logic abuse;
- weak password-reset flows;
- leaked API keys;
- insecure direct object references;
- malicious actions performed by a legitimate authenticated user;
- data returned by an insecure query;
- vulnerable application dependencies.

---

## 7. Cognito security and cost controls

### Recommended Cognito resources

- User Pool
- SPA/public app client
- optional confidential server app client
- managed login/custom domain
- user groups or application roles
- resource server and scopes where useful
- regional WAF association where required
- CloudWatch log delivery where justified

A Cognito Identity Pool is **not required** unless browser users must receive temporary AWS credentials. For a normal website, users should call the backend rather than access AWS services directly.

### Recommended user-pool settings

- [ ] Disable self-registration for a private or invite-only website.
- [ ] Use email as the sign-in identifier where appropriate.
- [ ] Make usernames case-insensitive where supported.
- [ ] Require verified email addresses.
- [ ] Require MFA for administrators and privileged users.
- [ ] Prefer passkeys or TOTP.
- [ ] Avoid SMS MFA where possible.
- [ ] Enable token revocation.
- [ ] Prevent user-existence errors.
- [ ] Configure a strong password policy when passwords are used.
- [ ] Prevent password reuse when the selected Cognito tier supports it.
- [ ] Use exact callback and logout URLs.
- [ ] Do not use wildcard callbacks.
- [ ] Separate development, staging, and production user pools or app clients.
- [ ] Use separate administrator roles for Cognito management.
- [ ] Review dormant and unconfirmed users.
- [ ] Avoid storing unnecessary personal attributes.

### SPA OAuth configuration

For a React/Vue/browser SPA:

- use OAuth 2.0 authorization-code grant;
- use PKCE;
- set `generate_secret = false`;
- do not embed a client secret in browser code;
- disable implicit grant;
- use short access-token and ID-token lifetimes;
- use a limited refresh-token lifetime;
- request only required scopes.

### Backend token validation

The backend must validate:

- JWT signature against the correct Cognito JWKS;
- token issuer;
- token expiration;
- token type;
- app client/audience;
- required scopes;
- expected user-pool region and ID;
- nonce/state where the application flow requires them.

Do not trust a role or user ID sent separately in a request body. Derive identity from the validated token.

### Authorisation

Authentication answers **who the user is**. Authorisation answers **what the user may do**.

- [ ] Enforce permissions in the backend.
- [ ] Check resource ownership for every object-level operation.
- [ ] Do not rely solely on hidden frontend buttons.
- [ ] Map Cognito groups to a small, documented role model.
- [ ] Use deny-by-default authorisation.
- [ ] Test horizontal and vertical privilege escalation.
- [ ] Audit administrator actions.

### Cognito cost risks

Cognito is not a fixed-price service.

Potential variable charges include:

- monthly active users;
- higher user-pool tiers;
- SAML/OIDC-federated users;
- machine-to-machine token requests;
- SMS messages;
- SES email messages;
- the separate WAF attached to Cognito;
- Cognito-trigger Lambda functions;
- CloudWatch log storage and analysis.

Cost controls:

- [ ] Use Lite or Essentials unless Plus features are justified.
- [ ] Disable public sign-up when not required.
- [ ] Prefer TOTP/passkeys over SMS.
- [ ] Add Cognito WAF rate limits and challenges.
- [ ] Alert on authentication-volume anomalies.
- [ ] Limit password reset and verification attempts.
- [ ] Avoid unnecessary Lambda triggers.
- [ ] Delete test user pools and domains.
- [ ] Monitor MAU counts and federation type.

---

## 8. VPC and network configuration

### Subnets

Recommended layout:

```text
Availability Zone A
  application-private-a
  database-private-a

Availability Zone B
  application-private-b
  database-private-b
```

Initially, only one application subnet needs an EC2 instance. Two database subnets are required for an RDS DB subnet group and support Multi-AZ.

### Required controls

- [ ] EC2 has no public IPv4 address.
- [ ] RDS is not publicly accessible.
- [ ] No route from private subnets to an Internet Gateway.
- [ ] The VPC can have an Internet Gateway attached when required by CloudFront VPC origins, but private route tables must not route through it.
- [ ] Security groups reference other security groups instead of broad CIDR ranges where possible.
- [ ] EC2 accepts only CloudFront-origin traffic on the required port.
- [ ] RDS accepts PostgreSQL traffic only from the application security group.
- [ ] VPC endpoints accept HTTPS only from the application security group.
- [ ] No inbound SSH or RDP.
- [ ] Network ACLs remain simple unless there is a concrete requirement.
- [ ] Reject traffic logging is enabled only if useful and retention is bounded.

### No NAT Gateway

A NAT Gateway creates:

- a fixed hourly charge;
- per-GB processing charges;
- additional data-transfer opportunities;
- an easy route for compromised workloads to contact the internet.

Avoid it for this architecture.

### VPC endpoints

Possible private endpoints:

- Systems Manager `ssm`
- Systems Manager messages `ssmmessages`
- EC2 messages where applicable
- Secrets Manager
- CloudWatch Logs
- KMS, only when direct API access is required
- ECR API and ECR Docker, only when pulling containers
- S3 gateway endpoint

Interface endpoints are billed per endpoint per Availability Zone per hour and per GB processed. Add only endpoints that are actually required.

### Endpoint cost optimisation

- Use endpoints only in the Availability Zones containing workloads.
- Do not automatically deploy every available endpoint.
- Use an S3 gateway endpoint where applicable instead of an S3 interface endpoint.
- Remove endpoints for services no longer used.
- Tag endpoints and alert on unexpected creations.
- Avoid cross-region endpoint use.
- Review endpoint data processing monthly.

### Operating-system updates without NAT

A private instance without internet egress may be unable to contact public package repositories.

Safer options:

1. build a patched machine image in a controlled build environment;
2. replace the production instance with the new image;
3. keep the production instance immutable;
4. store deployment artifacts in S3 or ECR and access them through private endpoints.

Avoid creating a temporary NAT Gateway unless an automated process guarantees its deletion. A forgotten NAT Gateway is a common surprise charge.

---

## 9. EC2 security

### Instance configuration

- [ ] Use a current, supported operating system.
- [ ] Use a fixed instance type.
- [ ] Use encrypted gp3 EBS.
- [ ] Require IMDSv2.
- [ ] Disable public IPv4.
- [ ] Do not configure SSH ingress.
- [ ] Use Systems Manager Session Manager.
- [ ] Run the application as a non-root user.
- [ ] Run only required services.
- [ ] Disable unused ports and daemons.
- [ ] Use a host firewall as a secondary control.
- [ ] Set file and directory permissions strictly.
- [ ] Keep application secrets out of environment dumps and user data.
- [ ] Do not place durable application data only on the root disk.
- [ ] Set disk, inode, memory, CPU, and process-count alarms.
- [ ] Enable automatic recovery where supported.
- [ ] Patch by replacing the instance from a tested image.
- [ ] Scan images and dependencies before deployment.
- [ ] Do not expose an instance metadata proxy to application users.

### Burstable instance hidden cost

EC2 T-family instances can use burst CPU credits. In unlimited mode, sustained CPU usage can produce surplus-credit charges.

For stronger cost predictability:

- prefer a fixed-performance M, C, or equivalent instance family; or
- explicitly use standard credit mode where EC2 supports it and accept CPU throttling.

For RDS, burstable T classes can also produce CPU-credit-related charges. A fixed-performance DB class is safer when strict predictability matters.

### EBS configuration

- use gp3;
- set fixed capacity;
- keep IOPS and throughput at fixed approved values;
- alert before the disk fills;
- delete unattached volumes;
- expire old snapshots;
- review AMIs because AMIs can retain billable snapshots.

### Systems Manager

Session Manager reduces the need for:

- inbound port 22;
- bastion hosts;
- long-lived SSH keys;
- public administration endpoints.

Restrict Session Manager actions through IAM. Log interactive sessions when the connection mode supports logging, and protect the log destination.

---

## 10. Container security, if Docker is used

- [ ] Use minimal, supported base images.
- [ ] Pin image versions or digests.
- [ ] Scan images for vulnerabilities.
- [ ] Run as a non-root user.
- [ ] Use a read-only root filesystem where practical.
- [ ] Drop unnecessary Linux capabilities.
- [ ] Do not use privileged containers.
- [ ] Do not mount the Docker socket into the application container.
- [ ] Set CPU, memory, process, and file limits.
- [ ] Store images in a private ECR repository.
- [ ] Apply an ECR lifecycle policy.
- [ ] Never place secrets in image layers.
- [ ] Sign and verify images when the threat model justifies it.
- [ ] Replace containers through deployment rather than patching them manually.

Remember that ECR storage, scans, data transfer, and unused image layers can add charges.

---

## 11. Nginx/reverse-proxy controls

- [ ] Listen only on the required origin port.
- [ ] Use TLS from CloudFront to the origin.
- [ ] Disable server-version disclosure.
- [ ] Set maximum request-body size.
- [ ] Set connection, request, and upstream timeouts.
- [ ] Limit concurrent connections.
- [ ] Limit request rate as a second layer behind WAF.
- [ ] Reject unknown `Host` headers.
- [ ] Reject unexpected methods.
- [ ] Configure secure proxy headers.
- [ ] Do not trust arbitrary client-supplied forwarding headers.
- [ ] Return generic error pages.
- [ ] Rotate logs and cap retained size.
- [ ] Do not log access tokens, passwords, cookies, or personal data.
- [ ] Separate static and API routes.
- [ ] Disable directory listing.
- [ ] Use a restrictive content security policy.

---

## 12. Application security

Infrastructure security cannot compensate for an insecure application.

### Authentication and sessions

- [ ] Use Cognito standards-based flows.
- [ ] Validate tokens server-side.
- [ ] Use short-lived access tokens.
- [ ] Store browser tokens using a design that minimises XSS exposure.
- [ ] Use `Secure`, `HttpOnly`, and appropriate `SameSite` settings for cookies.
- [ ] Rotate sessions after login and privilege changes.
- [ ] Invalidate sessions after password reset where supported.
- [ ] Rate-limit authentication and recovery.
- [ ] Protect state-changing cookie-authenticated requests against CSRF.
- [ ] Do not put secrets or tokens in URLs.

### Authorisation

- [ ] Use deny-by-default checks.
- [ ] Check access to each record, file, tenant, and administrative action.
- [ ] Never use frontend visibility as an access-control mechanism.
- [ ] Test another user's IDs against every resource endpoint.
- [ ] Log high-risk authorisation failures.
- [ ] Separate admin routes and roles.

### Input and output handling

- [ ] Use parameterised database queries.
- [ ] Validate input using schemas.
- [ ] Enforce length, type, range, and format limits.
- [ ] Encode output correctly for HTML, JavaScript, URLs, and SQL contexts.
- [ ] Sanitize rich text.
- [ ] Prevent path traversal.
- [ ] Restrict outbound URLs to prevent SSRF.
- [ ] Disable unsafe deserialisation.
- [ ] Reject oversized JSON and nested inputs.
- [ ] Set database statement and transaction timeouts.

### File uploads

When uploads are required:

- [ ] store files in a private bucket;
- [ ] enforce maximum file size;
- [ ] validate file type by content, not only extension;
- [ ] rename files;
- [ ] prevent executable files from being served as active content;
- [ ] scan files for malware;
- [ ] use separate upload and download permissions;
- [ ] expire abandoned uploads;
- [ ] do not allow arbitrary bucket keys;
- [ ] never make the upload bucket public;
- [ ] consider signed URLs with short expirations.

S3 requests, storage, scanning, and transfer can create variable charges, so impose per-user quotas and retention rules.

### Dependency and supply-chain security

- [ ] Pin dependencies.
- [ ] Commit lock files.
- [ ] Run dependency vulnerability scanning.
- [ ] Use secret scanning.
- [ ] Use static analysis.
- [ ] Protect the main branch.
- [ ] Require code review.
- [ ] Sign releases where practical.
- [ ] Restrict CI/CD permissions.
- [ ] Use OIDC from CI to AWS instead of stored AWS keys.
- [ ] Review third-party actions and packages.
- [ ] Maintain a software bill of materials for higher-assurance workloads.

---

## 13. RDS PostgreSQL security

### Network and encryption

- [ ] `publicly_accessible = false`
- [ ] database subnets are private;
- [ ] inbound port 5432 only from the application security group;
- [ ] storage encryption enabled;
- [ ] application-to-database TLS required;
- [ ] certificate validation enabled where supported;
- [ ] no direct developer access from the internet.

### Credentials

- [ ] Let RDS manage the master password in Secrets Manager.
- [ ] Do not use the master account from the application.
- [ ] Create a separate application database user.
- [ ] Grant only required schema/table permissions.
- [ ] Create separate migration and read-only users where useful.
- [ ] Rotate credentials.
- [ ] Do not put passwords in Terraform variables, source code, CI logs, or user data.
- [ ] Restrict secret access to the EC2 workload role.

### Availability and recovery

- [ ] Use Multi-AZ for production private data when the budget permits.
- [ ] Enable automated backups.
- [ ] Set an explicit backup-retention period.
- [ ] Enable point-in-time recovery.
- [ ] Enable deletion protection.
- [ ] Require a final snapshot before deletion.
- [ ] Copy or retain backups only according to a documented policy.
- [ ] Perform periodic restoration tests.
- [ ] Document recovery-time and recovery-point objectives.
- [ ] Alarm on replication/failover/database events.

### Capacity controls

- [ ] Choose a fixed instance class.
- [ ] Choose a fixed gp3 storage size.
- [ ] Do not configure `max_allocated_storage` when strict cost predictability is required.
- [ ] Alarm at 20%, 15%, and 10% free storage.
- [ ] Set connection-pool limits.
- [ ] Set query timeouts.
- [ ] Set transaction timeouts.
- [ ] Monitor long-running queries.
- [ ] Avoid unbounded audit or application tables.
- [ ] Archive or delete old data according to policy.

> [!WARNING]
> Disabling storage autoscaling converts an unexpected bill into an availability risk. If storage fills, the database can fail. Alarms and an operational response procedure are mandatory.

### Snapshot cost risks

Charges can persist for:

- manual snapshots;
- retained automated backups;
- snapshots left after deleting an instance;
- cross-region copies;
- exports to S3;
- old test databases;
- restored temporary databases.

Tag every backup and apply a retention policy.

---

## 14. Secrets and KMS

### Secrets Manager

Use Secrets Manager for:

- database credentials;
- third-party API keys;
- application signing secrets;
- OAuth confidential-client secrets;
- integration credentials.

Controls:

- [ ] do not expose secrets through Terraform output;
- [ ] restrict secret access by ARN and role;
- [ ] rotate secrets where supported;
- [ ] log access through CloudTrail;
- [ ] do not include secret values in CloudWatch logs;
- [ ] remove old secret versions when safe;
- [ ] delete unused secrets after an appropriate recovery window.

Secrets Manager charges per secret and API usage. Do not create a separate secret for every trivial value without a reason.

### KMS

AWS-managed keys simplify cost and operations. Customer-managed KMS keys provide more control but add:

- monthly key charges;
- API request charges;
- key-policy complexity;
- lockout risk;
- rotation and deletion procedures.

Use customer-managed keys only when policy, compliance, or separation-of-duties requirements justify them.

---

## 15. Logging and monitoring

### Minimum logs

- CloudTrail management events;
- CloudFront access logs when justified;
- CloudFront WAF logs;
- Cognito security/authentication logs where available and required;
- application security and error logs;
- operating-system logs;
- RDS events and selected database logs;
- Session Manager activity;
- cost and plan-subscription changes.

### Log-safety controls

- [ ] redact tokens, cookies, passwords, API keys, and sensitive personal data;
- [ ] use structured logs;
- [ ] include request/correlation IDs;
- [ ] limit who can read logs;
- [ ] encrypt logs;
- [ ] set an explicit retention period;
- [ ] prevent security-log deletion by ordinary operators;
- [ ] avoid verbose debug logging in production;
- [ ] limit stack traces returned to users;
- [ ] archive only logs required by policy.

### Hidden logging costs

CloudFront flat-rate plans include specified log ingestion associated with the plan, but other charges can remain, including:

- CloudWatch log storage;
- CloudWatch Logs Insights queries;
- application log ingestion;
- Route 53 query-log delivery;
- VPC Flow Logs;
- GuardDuty and Security Hub;
- S3 log storage and requests;
- cross-account or cross-region log delivery.

### Suggested alarms

#### Security

- root-user activity;
- console login without MFA;
- IAM, KMS, WAF, CloudFront, Route 53, or Cognito changes;
- CloudTrail stopped or modified;
- security-group rule opened broadly;
- public EC2/RDS configuration;
- WAF allowed or blocked traffic spike;
- Cognito failed-login spike;
- unusual password-reset volume;
- secret access from an unexpected role;
- unusual outbound traffic.

#### Availability

- EC2 status-check failure;
- high CPU;
- low memory;
- low disk space or inode capacity;
- application health-check failure;
- elevated CloudFront 5xx rate;
- elevated origin 5xx rate;
- high application latency;
- RDS CPU, connections, or free-memory pressure;
- low RDS storage;
- RDS failover or maintenance event.

#### Cost

- 50%, 80%, and 100% of monthly budget;
- forecasted budget breach;
- Cost Anomaly Detection alert;
- new NAT Gateway;
- new public IPv4 address;
- new load balancer;
- new interface endpoint;
- new or resized EC2/RDS instance;
- snapshot growth;
- log ingestion spike;
- Cognito MAU/authentication spike;
- Marketplace subscription;
- flat-rate plan cancellation or downgrade.

---

## 16. AWS Budgets is not a hard real-time cap

AWS states that Budgets data is updated up to three times per day, typically 8–12 hours apart.

Therefore:

- a budget alert can arrive after spend has already happened;
- a budget action can run late;
- a budget must not be the only defence against unexpected charges;
- resource and IAM guardrails must prevent the charge before it exists.

Use Budgets for warning and governance, not as an instantaneous circuit breaker.

Recommended thresholds:

| Threshold | Action |
|---:|---|
| 50% actual | Informational email |
| 70% forecast | Investigate forecast |
| 80% actual | Operations and owner alert |
| 90% actual | Restrict non-production deployments |
| 100% actual | Emergency review and approved actions |

Do not automatically destroy production databases in response to a budget threshold.

---

## 17. Cost-classification table

| Component | Cost behaviour | Main surprise risk | Control |
|---|---|---|---|
| CloudFront Business plan | Fixed monthly | Plan cancelled/detached | Alert on plan changes |
| CloudFront viewer traffic | No overage under plan | Sustained excess can affect performance | Monitor allowances |
| CloudFront unsupported features | May force pay-as-you-go | Feature enabled accidentally | Terraform validation and policy |
| Route 53 hosted zone | Small monthly cost | Duplicate zones, health checks, logs | One zone; inventory controls |
| Domain | Annual/renewal cost | Promotional renewal increase | Record renewal price |
| EC2 | Mostly fixed hourly | Resize, extra instances, T CPU credits | Fixed class; deny autoscaling |
| Public IPv4 | Hourly | Accidentally attached | Deny public IPs |
| EBS | Fixed provisioned size | Old volumes/snapshots | Lifecycle and inventory |
| RDS | Mostly fixed hourly | Resize, Multi-AZ changes, T credits | Fixed class; change approval |
| RDS storage | Fixed provisioned | Autoscaling or retained snapshots | Disable autoscaling; retention |
| VPC interface endpoints | Hourly per AZ plus data | Too many endpoints/AZs | Minimal endpoint set |
| S3 gateway endpoint | No endpoint hourly charge | S3 requests/storage remain | Retention and request controls |
| NAT Gateway | Hourly plus per-GB | Forgotten NAT and traffic | Do not deploy |
| Application Load Balancer | Hourly plus LCU | Traffic-driven LCU | Omit initially |
| Cognito | Usage-based | MAU, SMS, federation, bots | WAF; no SMS; no public sign-up |
| Cognito WAF | Usage-based unless otherwise covered | Bot traffic | Rate limits/challenge |
| Secrets Manager | Per secret and API | Too many secrets/calls | Consolidate reasonably/cache safely |
| KMS | Keys and API requests | Unnecessary customer keys | Use AWS-managed keys where suitable |
| CloudWatch | Ingestion/storage/queries | Debug log flood | Retention and sampling |
| CloudTrail | Trail storage/delivery extras | Data events enabled broadly | Scope carefully |
| GuardDuty/Security Hub | Usage-based | Unexpected analysed volume | Enable with cost monitoring |
| S3 uploads | Requests/storage/transfer | Abuse and abandoned files | Quotas and lifecycle |
| ECR | Image storage/scanning | Old images | Lifecycle policy |
| Cross-AZ transfer | Usage-based | Chatty app-to-DB traffic | Co-locate where practical |
| Cross-region transfer | Usage-based | Replication or endpoints | Keep single-region |
| Backups | Retention/storage | Old manual backups | Automated lifecycle |
| AWS Support | Monthly/percentage | Plan upgraded | Restrict billing permissions |
| Marketplace | Subscription/usage | Accidental product purchase | SCP deny |

---

## 18. Strict predictability configuration

Use these settings when avoiding unexpected spend is more important than automatic scale.

### Compute

- one fixed EC2 instance;
- no Auto Scaling group;
- no automatic instance-size changes;
- fixed-performance instance family where affordable;
- fixed encrypted gp3 disk;
- no public IPv4;
- no NAT Gateway;
- no ALB initially.

### Database

- fixed RDS class;
- fixed gp3 storage;
- no storage autoscaling;
- no read replicas;
- no RDS Proxy initially;
- explicit backup retention;
- explicit snapshot retention;
- Multi-AZ only when availability requirements justify its known additional cost.

### Edge

- CloudFront Business flat-rate;
- WAF included for the associated distribution;
- no real-time logs if incompatible with the plan;
- no unsupported shared associations;
- static content cached aggressively;
- authenticated API responses not cached.

### Authentication

- Cognito Lite or Essentials;
- no SMS MFA;
- no public sign-up unless required;
- no machine-to-machine flows unless required;
- separate rate limits for authentication operations;
- monitor MAUs.

### Observability

- finite log retention;
- no indefinite debug logging;
- limited VPC Flow Logs;
- limited CloudTrail data events;
- controlled log queries;
- monthly log-cost review.

---

## 19. What happens during traffic spikes

### Static-content spike

CloudFront serves cached assets. Origin impact should remain small. The flat-rate plan prevents viewer transfer and request overages covered by the plan.

### Dynamic legitimate traffic spike

The fixed EC2/RDS capacity can become saturated. Possible outcomes:

- slower responses;
- `429 Too Many Requests`;
- `502`, `503`, or `504` errors;
- database connection exhaustion;
- temporary outage.

This is the intended trade-off: **availability degrades before infrastructure costs automatically grow**.

### Malicious traffic spike blocked by WAF

Blocked traffic should not reach the origin. AWS states that blocked WAF requests and blocked DDoS attacks do not count against the CloudFront plan allowance.

### Malicious traffic that looks legitimate

It may pass WAF and consume application/database capacity. Use:

- endpoint-specific rate limits;
- per-account limits;
- concurrency limits;
- database timeouts;
- queues only where their cost is bounded;
- CAPTCHA/challenge;
- application abuse detection.

### Cognito abuse

Public sign-up, verification, password recovery, SMS, and authentication flows can be abused separately from the main website origin. Protect Cognito with its own configuration and, where justified, a regional WAF.

---

## 20. Availability trade-offs

### Single EC2 instance

Advantages:

- simple;
- fixed cost;
- no load balancer;
- no automatic scaling.

Risks:

- host failure;
- operating-system crash;
- bad deployment;
- disk-full outage;
- Availability Zone outage;
- maintenance interruption.

Mitigations:

- immutable replacement;
- tested AMI;
- automatic recovery;
- health checks;
- regular backups of durable data;
- documented rebuild procedure.

### RDS Single-AZ versus Multi-AZ

Single-AZ:

- cheaper;
- predictable;
- longer outage risk during infrastructure failure.

Multi-AZ:

- higher known baseline cost;
- automatic standby and failover;
- brief interruptions still occur;
- possible cross-AZ effects after failover;
- does not protect against application-level data deletion.

For sensitive production data, Multi-AZ is recommended when the known additional cost is acceptable.

### Fixed capacity versus high availability

It is difficult to maximise all three simultaneously at low cost:

1. exact fixed cost;
2. very high availability;
3. unlimited capacity.

Choose and document the priority order.

---

## 21. Deployment and Terraform security

### Terraform state

- [ ] store remote state in a private S3 bucket;
- [ ] enable versioning;
- [ ] enable encryption;
- [ ] block all public access;
- [ ] use state locking;
- [ ] restrict state read access;
- [ ] log state-bucket access;
- [ ] never commit state files;
- [ ] never put user passwords or ordinary user records in Terraform;
- [ ] avoid placing raw secrets in Terraform variables;
- [ ] review Terraform outputs for sensitive values;
- [ ] back up and test state recovery.

### CI/CD

- [ ] use GitHub/GitLab/Azure DevOps OIDC to assume an AWS role;
- [ ] do not store long-lived AWS access keys;
- [ ] require protected branches;
- [ ] require plan review;
- [ ] separate plan and apply permissions;
- [ ] restrict production applies to approved branches/environments;
- [ ] scan Terraform for security and cost risks;
- [ ] pin Terraform and provider versions;
- [ ] review provider upgrades;
- [ ] run `terraform plan` regularly to detect drift;
- [ ] import or revert manual changes;
- [ ] prevent destructive applies without approval.

### Terraformable resource matrix

| Area | Resource | Terraform | Example AWS provider resource |
|---|---|---:|---|
| DNS | Hosted zone | Yes | `aws_route53_zone` |
| DNS | Records | Yes | `aws_route53_record` |
| TLS | ACM certificate | Yes | `aws_acm_certificate` |
| TLS | Certificate validation | Yes | `aws_acm_certificate_validation` |
| Edge | CloudFront distribution | Yes | `aws_cloudfront_distribution` |
| Edge | CloudFront VPC origin | Yes | `aws_cloudfront_vpc_origin` |
| Edge | Cache policy | Yes | `aws_cloudfront_cache_policy` |
| Edge | Origin request policy | Yes | `aws_cloudfront_origin_request_policy` |
| Edge | Response headers policy | Yes | `aws_cloudfront_response_headers_policy` |
| Edge | Flat-rate plan subscription | Not natively confirmed | Console/API step; track provider support |
| WAF | Web ACL | Yes | `aws_wafv2_web_acl` |
| WAF | IP sets | Yes | `aws_wafv2_ip_set` |
| WAF | Logging | Yes | `aws_wafv2_web_acl_logging_configuration` |
| Cognito | User Pool | Yes | `aws_cognito_user_pool` |
| Cognito | App client | Yes | `aws_cognito_user_pool_client` |
| Cognito | Domain | Yes | `aws_cognito_user_pool_domain` |
| Cognito | Groups | Yes | `aws_cognito_user_group` |
| Cognito | Resource server | Yes | `aws_cognito_resource_server` |
| Cognito | Identity provider | Yes | `aws_cognito_identity_provider` |
| Cognito | WAF association | Yes | `aws_wafv2_web_acl_association` |
| Network | VPC | Yes | `aws_vpc` |
| Network | Subnets | Yes | `aws_subnet` |
| Network | Route tables | Yes | `aws_route_table` |
| Network | Internet Gateway | Yes | `aws_internet_gateway` |
| Network | Security groups | Yes | `aws_security_group` |
| Network | VPC endpoints | Yes | `aws_vpc_endpoint` |
| Compute | EC2 | Yes | `aws_instance` |
| Compute | IAM role | Yes | `aws_iam_role` |
| Compute | Instance profile | Yes | `aws_iam_instance_profile` |
| Storage | EBS | Yes | `aws_ebs_volume` |
| Database | RDS PostgreSQL | Yes | `aws_db_instance` |
| Database | DB subnet group | Yes | `aws_db_subnet_group` |
| Database | Parameter group | Yes | `aws_db_parameter_group` |
| Secrets | Application secret metadata | Yes | `aws_secretsmanager_secret` |
| Encryption | KMS key | Yes | `aws_kms_key` |
| Logging | CloudWatch log groups | Yes | `aws_cloudwatch_log_group` |
| Monitoring | Metric alarms | Yes | `aws_cloudwatch_metric_alarm` |
| Alerts | SNS topic | Yes | `aws_sns_topic` |
| Cost | Budget | Yes | `aws_budgets_budget` |
| Cost | Budget action | Yes | `aws_budgets_budget_action` |
| Cost | Anomaly monitor | Yes | `aws_ce_anomaly_monitor` |
| Audit | CloudTrail | Yes | `aws_cloudtrail` |
| Security | Access Analyzer | Yes | `aws_accessanalyzer_analyzer` |
| Security | GuardDuty | Yes | `aws_guardduty_detector` |
| Organisation | SCP | Yes, management account | `aws_organizations_policy` |
| Account | Root MFA | No | Manual |
| Alerts | SNS email confirmation | Partly | Recipient must confirm |
| Domain | Registrar purchase/lock | Usually no | Registrar-specific/manual |

### Manual steps to document

- create the AWS account;
- secure root credentials and MFA;
- configure alternate contacts;
- purchase and lock the domain;
- update registrar nameservers;
- bootstrap Terraform state;
- confirm SNS email subscriptions;
- attach/manage the CloudFront flat-rate plan if provider support is unavailable;
- create initial application administrators through a controlled workflow;
- perform go-live security tests;
- perform a database restore test.

---

## 22. Services to avoid initially

Avoid these unless a documented requirement outweighs their cost or complexity:

| Service/feature | Reason |
|---|---|
| NAT Gateway | Hourly and per-GB charges |
| Public EC2 | Direct attack and origin-bypass risk |
| Public RDS | Severe data exposure risk |
| Application Load Balancer | Hourly and traffic-related LCU charges |
| Auto Scaling | Capacity and cost can grow automatically |
| RDS storage autoscaling | Storage cost can grow automatically |
| Aurora Serverless | Capacity varies |
| API Gateway main backend | Request-priced |
| Lambda main backend | Request and execution priced |
| Lambda@Edge | Additional variable execution cost |
| RDS Proxy | Additional cost |
| Cognito SMS MFA | SMS-pumping risk |
| Cognito Identity Pool | Unnecessary browser AWS credentials |
| EKS/Kubernetes | High fixed cost and complexity |
| OpenSearch | Expensive for a small application |
| Cross-region replication | Transfer and replicated-resource costs |
| Real-time logs | Cost and potential plan incompatibility |
| Marketplace products | Subscription and usage surprises |

---

## 23. Backup and disaster-recovery plan

Define:

- **RPO:** maximum acceptable data loss;
- **RTO:** maximum acceptable recovery time;
- backup retention;
- snapshot retention;
- restore-test frequency;
- who may restore or delete backups;
- where recovery credentials are stored;
- how DNS is changed during recovery;
- what happens if Cognito is unavailable;
- what happens if the AWS account is compromised.

### Minimum recovery tests

- [ ] restore RDS to a new instance;
- [ ] verify application connectivity;
- [ ] verify database integrity;
- [ ] rebuild EC2 from the approved image;
- [ ] retrieve required secrets;
- [ ] recreate CloudFront/WAF configuration from Terraform;
- [ ] restore Terraform state from an earlier version;
- [ ] verify registrar and Route 53 access;
- [ ] record the real recovery duration.

Backups that have never been restored are unproven.

---

## 24. Incident response

Prepare runbooks for:

### Suspected AWS-account compromise

1. use a known-clean administrator session;
2. disable or revoke suspicious credentials;
3. review CloudTrail;
4. restrict IAM and network access;
5. rotate affected secrets;
6. preserve logs;
7. identify unauthorised resources;
8. check billing and Marketplace subscriptions;
9. contact AWS Support when appropriate.

### Application attack

1. enable emergency WAF restrictions;
2. lower endpoint-specific rate limits;
3. disable affected features;
4. protect login and password reset;
5. preserve logs;
6. patch or roll back;
7. rotate compromised secrets;
8. review affected data and notification obligations.

### Unexpected cost

1. inspect Cost Explorer and anomaly details;
2. look for new NAT Gateways, public IPv4 addresses, endpoints, logs, snapshots, Marketplace items, resized compute, and Cognito/SMS activity;
3. disable or remove the cost source safely;
4. avoid deleting evidence or production data;
5. update IAM/SCP/Terraform controls so it cannot recur.

### Database full

1. stop nonessential writes;
2. identify log, audit, session, and temporary-table growth;
3. safely delete/archive data where permitted;
4. increase storage through an approved Terraform change if necessary;
5. do not enable open-ended autoscaling as an emergency shortcut without approval.

---

## 25. Go-live security tests

### External tests

- [ ] only CloudFront is reachable;
- [ ] direct EC2 origin access is impossible;
- [ ] RDS is not publicly reachable;
- [ ] TLS configuration is strong;
- [ ] HTTP redirects to HTTPS;
- [ ] security headers are present;
- [ ] unknown hostnames are rejected;
- [ ] unexpected HTTP methods are rejected;
- [ ] WAF rate limits work;
- [ ] WAF managed rules do not block valid traffic;
- [ ] sensitive responses are not cached;
- [ ] authenticated content is never shared between users;
- [ ] admin routes require the correct role;
- [ ] password reset does not reveal whether a user exists;
- [ ] file-upload restrictions work.

### Internal tests

- [ ] EC2 has no public IP;
- [ ] no inbound SSH/RDP rules;
- [ ] IMDSv2 is required;
- [ ] RDS accepts only the application security group;
- [ ] secrets are not stored in code, images, user data, or Terraform outputs;
- [ ] CloudTrail is enabled;
- [ ] log retention is finite;
- [ ] backups and deletion protection are enabled;
- [ ] RDS restore succeeds;
- [ ] budget and security alerts arrive;
- [ ] Cost Anomaly Detection is enabled;
- [ ] SCPs prevent unauthorised regions/services;
- [ ] Terraform plan shows no unexplained drift.

---

## 26. Monthly operational checklist

### Security

- [ ] review IAM and Identity Center access;
- [ ] remove unused roles and credentials;
- [ ] review root and administrator activity;
- [ ] review WAF trends and false positives;
- [ ] review Cognito authentication anomalies;
- [ ] patch and replace the EC2 image;
- [ ] update application dependencies;
- [ ] review vulnerability scans;
- [ ] test an alarm and an operational runbook;
- [ ] verify backups and perform scheduled restore tests;
- [ ] review public and cross-account Access Analyzer findings.

### Cost

- [ ] compare actual spend with the baseline;
- [ ] review Cost Anomaly Detection;
- [ ] confirm the CloudFront plan is active;
- [ ] review CloudFront allowance usage;
- [ ] review Cognito MAUs and messaging;
- [ ] review VPC endpoints;
- [ ] review public IPv4 addresses;
- [ ] confirm there is no NAT Gateway;
- [ ] delete unattached EBS volumes;
- [ ] delete expired snapshots and AMIs;
- [ ] review RDS storage growth;
- [ ] review CloudWatch ingestion, storage, and query costs;
- [ ] review S3/ECR lifecycle results;
- [ ] review cross-AZ and cross-region transfer;
- [ ] review Marketplace and Support plan charges.

---

## 27. Cost worksheet

Fill this with the selected region and exact instance classes.

```text
CloudFront flat-rate plan                    $________
EC2 instance, 730 hours                     $________
EC2 EBS gp3                                 $________
RDS instance / Multi-AZ                     $________
RDS gp3 storage                             $________
RDS backup storage above allowance          $________
VPC interface endpoints                     $________
Route 53 hosted zone                        $________
Domain renewal / 12                         $________
Cognito expected MAUs                       $________
Cognito/SNS/SES messaging                   $________
Cognito regional WAF                        $________
Secrets Manager                             $________
KMS                                         $________
CloudWatch logs, metrics, and alarms         $________
CloudTrail/S3 log storage                    $________
GuardDuty/Security Hub, if enabled           $________
S3/ECR storage and requests                  $________
AWS Support plan                             $________
Tax/currency/payment adjustments             $________
-----------------------------------------------------
Expected monthly total                       $________
Approved contingency                         $________
Hard internal budget                         $________
```

### Baseline-versus-variable classification

```text
Known baseline:
  CloudFront plan
  fixed EC2 hours
  fixed RDS hours
  fixed provisioned EBS/RDS storage
  hosted zone
  planned VPC endpoint hours

Bounded variable:
  Cognito MAUs
  Cognito/SES/SNS messages
  logs and metrics
  Secrets Manager and KMS requests
  S3/ECR usage
  backup growth
  cross-AZ transfer

Must be prevented:
  NAT Gateway
  public IPv4
  autoscaling
  RDS storage autoscaling
  unapproved instance resizing
  accidental extra regions
  Marketplace subscriptions
  unlimited logs
  unbounded snapshots
  flat-rate plan cancellation
```

---

## 28. Final recommended decisions

For a private production website containing sensitive user information:

- **CloudFront:** Business flat-rate plan;
- **WAF:** CloudFront-scoped web ACL with managed rules and endpoint-specific limits;
- **Origin:** private EC2 through CloudFront VPC origin;
- **Compute:** one fixed-performance instance initially;
- **Administration:** Systems Manager, no SSH;
- **Database:** private encrypted RDS PostgreSQL, Multi-AZ when availability warrants it;
- **Authentication:** Cognito User Pool, PKCE, TOTP/passkeys, no SMS;
- **Networking:** no NAT Gateway, no public IPv4, minimal VPC endpoints;
- **Scaling:** no automatic compute or storage scaling;
- **Storage:** fixed gp3 sizes with early alarms;
- **Secrets:** RDS-managed master secret and least-privilege application secrets;
- **IaC:** Terraform with remote encrypted state and OIDC deployment role;
- **Governance:** separate AWS account, budgets, anomaly detection, low quotas, and SCPs;
- **Operations:** immutable deployments, finite retention, restore testing, and incident runbooks.

The explicit trade-off is:

> When legitimate or malicious demand exceeds fixed backend capacity, the application may throttle or become unavailable instead of automatically scaling and increasing the bill.

That behaviour should be intentional, tested, monitored, and explained to stakeholders.

---

## 29. Official references

- [AWS CloudFront flat-rate pricing plans](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html)
- [AWS Flat-Rate Plans User Guide](https://docs.aws.amazon.com/PricingPlanManager/latest/UserGuide/plans.html)
- [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
- [CloudFront cache keys and policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/controlling-the-cache-key.html)
- [AWS WAF rate-based rules](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based.html)
- [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/)
- [AWS IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS root-user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Cognito security best practices](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-security-best-practices.html)
- [Cognito pricing](https://aws.amazon.com/cognito/pricing/)
- [RDS storage autoscaling](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.Autoscaling.html)
- [RDS automated backups](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html)
- [RDS and Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
- [AWS Budgets update frequency](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [Route 53 pricing](https://aws.amazon.com/route53/pricing/)
- [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)
- [Terraform AWS Provider flat-rate plan feature request](https://github.com/hashicorp/terraform-provider-aws/issues/45450)

---

## 30. Review rule

Review this document:

- before the first production deployment;
- after any AWS architecture change;
- after any security incident;
- after any unexpected charge;
- every three months;
- whenever AWS changes CloudFront flat-rate plans or Cognito pricing.

AWS services, pricing, feature compatibility, and Terraform support change over time. Reverify the official documentation before applying the architecture.
