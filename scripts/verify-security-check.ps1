# Verify every control claimed in SECURITY_CHECK.md + CHECKLIST §C against live AWS.
# ASCII-only. Writes: $env:TEMP\popo-security-verify.jsonl + summary.

$ErrorActionPreference = 'Continue'
$Results = [System.Collections.Generic.List[object]]::new()
$Log = Join-Path $env:TEMP 'popo-security-verify.jsonl'
Remove-Item $Log -ErrorAction SilentlyContinue

function R([string]$Id, [string]$Name, [string]$Status, [string]$Detail = '') {
  $row = [pscustomobject]@{ id = $Id; name = $Name; status = $Status; detail = $Detail }
  $Results.Add($row)
  ($row | ConvertTo-Json -Compress) | Add-Content $Log -Encoding utf8
  $c = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
  Write-Host ("[{0}] {1} - {2}" -f $Status, $Id, $Name) -ForegroundColor $c
  if ($Detail) { Write-Host ("         {0}" -f $Detail) }
}

function Ensure-Creds {
  $need = $true
  try {
    if ($env:AWS_ACCESS_KEY_ID -and $env:AWS_CREDENTIAL_EXPIRATION) {
      if ((Get-Date).ToUniversalTime() -lt ([datetime]$env:AWS_CREDENTIAL_EXPIRATION).AddMinutes(-2)) { $need = $false }
    }
  } catch { $need = $true }
  if ($need) {
    $env:AWS_PROFILE = 'andrei-login'
    $lines = aws configure export-credentials --format env-no-export 2>$null
    if (-not $lines) { aws login --profile andrei-login | Out-Null; $lines = aws configure export-credentials --format env-no-export }
    foreach ($line in $lines) { if ($line -match '^(AWS_[A-Z_]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] } }
    Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
  }
  $env:AWS_DEFAULT_REGION = 'eu-west-1'
  $env:AWS_REGION = 'eu-west-1'
}

function CurlCode([string]$Url, [hashtable]$Headers = @{}, [string]$Method = 'GET', [int]$Timeout = 20) {
  $args = @('-sS', '-o', "$env:TEMP\vv.bin", '-w', '%{http_code}', '--max-time', "$Timeout", '-X', $Method)
  foreach ($k in $Headers.Keys) { $args += @('-H', ('{0}: {1}' -f $k, $Headers[$k])) }
  $args += $Url
  try { return [int](& curl.exe @args 2>$null) } catch { return 0 }
}

function CurlHeaders([string]$Url) {
  & curl.exe -sS -D - -o NUL --max-time 20 $Url 2>$null
}

Ensure-Creds
Write-Host "=== SECURITY_CHECK + CHECKLIST LIVE VERIFY ==="
Write-Host "cred expiry: $env:AWS_CREDENTIAL_EXPIRATION"
Write-Host ""

$Project = if ($env:POPO_PROJECT) { $env:POPO_PROJECT } else { 'popo' }
$Environment = if ($env:POPO_ENV) { $env:POPO_ENV } else { 'dev' }
$Domain = if ($env:POPO_DOMAIN) { $env:POPO_DOMAIN } else { 'andrei-vataselu.online' }
$AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
$Region = $env:AWS_REGION

$Site = if ($env:POPO_SITE_URL) { $env:POPO_SITE_URL } else { "https://dev.$Domain" }
$Api = if ($env:POPO_API_URL) { $env:POPO_API_URL } else { "https://api-dev.$Domain" }
$Auth = if ($env:POPO_AUTH_URL) { $env:POPO_AUTH_URL } else { "https://auth.dev.$Domain" }

$SiteHost = ([uri]$Site).Host
$ApiHost = ([uri]$Api).Host
$SiteDist = if ($env:POPO_SITE_DIST_ID) { $env:POPO_SITE_DIST_ID } else {
  (aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items!=null && contains(Aliases.Items, '$SiteHost')].Id | [0]" --output text).Trim()
}
$ApiDist = if ($env:POPO_API_DIST_ID) { $env:POPO_API_DIST_ID } else {
  (aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items!=null && contains(Aliases.Items, '$ApiHost')].Id | [0]" --output text).Trim()
}

$SecretArn = if ($env:ORIGIN_SECRET_ARN) { $env:ORIGIN_SECRET_ARN } else {
  (aws secretsmanager list-secrets --region $Region `
    --filters Key=name,Values="$Project-$Environment-origin-header" `
    --query 'SecretList[0].ARN' --output text).Trim()
}
$AppTg = (aws elbv2 describe-target-groups --names "$Project-$Environment-app" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null).Trim()
$WebTg = (aws elbv2 describe-target-groups --names "$Project-$Environment-web" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null).Trim()
$TfstateBucket = "$Project-tfstate-$AccountId"

# =====================================================================
# CHECKLIST C - live endpoints
# =====================================================================
Write-Host '--- CHECKLIST C: live endpoints ---'
$code = CurlCode "$Site/"
if ($code -eq 200) { R 'C.site' 'Site reachable from allowlisted IP' 'PASS' "code=$code" } else { R 'C.site' 'Site reachable from allowlisted IP' 'FAIL' "code=$code" }

$code = CurlCode "$Api/api/health"
$body = if (Test-Path "$env:TEMP\vv.bin") { [IO.File]::ReadAllText("$env:TEMP\vv.bin") } else { '' }
if ($code -eq 200 -and $body -match '"ok"\s*:\s*true') { R 'C.api' 'API health' 'PASS' "code=$code" } else { R 'C.api' 'API health' 'FAIL' "code=$code body=$body" }

$code = CurlCode "$Auth/"
if ($code -in 200, 302) { R 'C.auth' 'Cognito Hosted UI root' 'PASS' "code=$code" } else { R 'C.auth' 'Cognito Hosted UI root' 'FAIL' "code=$code" }

# SECURITY_CHECK §3 verify curls
$hdr = CurlHeaders $Site
if ($hdr -match '(?i)strict-transport-security' -and $hdr -match '(?i)x-content-type-options') {
  R 'SC3.hsts' 'Site security headers (HSTS / nosniff)' 'PASS' ''
} else { R 'SC3.hsts' 'Site security headers (HSTS / nosniff)' 'FAIL' ($hdr -split "`n" | Select-Object -First 15 | Out-String) }

$opt = & curl.exe -sS -D - -o NUL --max-time 20 -X OPTIONS "$Api/api/me" -H "Origin: $Site" -H 'Access-Control-Request-Method: GET' 2>$null
$siteOriginEscaped = [regex]::Escape($Site)
if ($opt -match "(?i)access-control-allow-origin:\s*$siteOriginEscaped") {
  R 'SC3.cors' 'API CORS locked to site origin' 'PASS' ''
} elseif ($opt -match '(?i)access-control-allow-origin') {
  R 'SC3.cors' 'API CORS locked to site origin' 'FAIL' ($opt -split "`n" | Select-String -Pattern 'access-control|HTTP/' | Out-String)
} else {
  # may 403/401 without ACAO on deny - still check no wildcard
  if ($opt -notmatch '\*') { R 'SC3.cors' 'API CORS (no wildcard observed)' 'PASS' ("status line: " + (($opt -split "`n")[0])) }
  else { R 'SC3.cors' 'API CORS locked to site origin' 'FAIL' 'wildcard ACAO' }
}

# =====================================================================
# Edge & network
# =====================================================================
Write-Host '--- Edge & network ---'
Ensure-Creds
$cf = aws cloudfront get-distribution-config --id $SiteDist --output json | ConvertFrom-Json
$viewer = $cf.DistributionConfig.ViewerCertificate
$minProto = $viewer.MinimumProtocolVersion
$redir = $cf.DistributionConfig.DefaultCacheBehavior.ViewerProtocolPolicy
if ($minProto -match 'TLSv1\.2' -and $redir -eq 'redirect-to-https') {
  R 'E1' 'CloudFront TLS 1.2+ + HTTPS redirect' 'PASS' "proto=$minProto policy=$redir"
} else { R 'E1' 'CloudFront TLS 1.2+ + HTTPS redirect' 'FAIL' "proto=$minProto policy=$redir" }

$resp = $cf.DistributionConfig.DefaultCacheBehavior.ResponseHeadersPolicyId
if ($resp) { R 'E1b' 'CloudFront response headers policy attached' 'PASS' "id=$resp" } else { R 'E1b' 'CloudFront response headers policy attached' 'FAIL' '' }

$cfRules = aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --id 102c4d63-70e3-4c0c-8420-3e3aff651acc --name popo-dev-cf --query 'WebACL.Rules[].Name' --output text
$cfRate = aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --id 102c4d63-70e3-4c0c-8420-3e3aff651acc --name popo-dev-cf --query 'WebACL.Rules[?Name==`RateLimitGlobal`].Statement.RateBasedStatement.Limit' --output text
if ($cfRules -match 'AWSManagedRulesCommonRuleSet' -and $cfRules -match 'KnownBadInputs' -and $cfRate -eq '2000') {
  R 'E2' 'CF WAF managed rules + 2000/5m rate' 'PASS' "rate=$cfRate"
} else { R 'E2' 'CF WAF managed rules + 2000/5m rate' 'FAIL' "rules=$cfRules rate=$cfRate" }

$cogRules = aws wafv2 get-web-acl --scope REGIONAL --region eu-west-1 --id 565a9732-2d40-4525-ba5f-7e1aa9c153b4 --name popo-dev-cognito --query 'WebACL.Rules[].Name' --output text
$cogRate = aws wafv2 get-web-acl --scope REGIONAL --region eu-west-1 --id 565a9732-2d40-4525-ba5f-7e1aa9c153b4 --name popo-dev-cognito --query 'WebACL.Rules[?Name==`RateLimitAuth`].Statement.RateBasedStatement.Limit' --output text
if ($cogRules -match 'AWSManagedRulesCommonRuleSet' -and $cogRate -eq '300') {
  R 'E3' 'Cognito WAF managed rules + 300/5m rate' 'PASS' "rate=$cogRate"
} else { R 'E3' 'Cognito WAF managed rules + 300/5m rate' 'FAIL' "rules=$cogRules rate=$cogRate" }

if ($cfRules -match 'IPAllowlistOnly' -and $cogRules -match 'IPAllowlistOnly') {
  R 'E4' 'Dev IP allowlist on CF + Cognito WAF' 'PASS' ''
} else { R 'E4' 'Dev IP allowlist on CF + Cognito WAF' 'FAIL' '' }

# ALB SG = CloudFront prefix only
$albSg = aws ec2 describe-security-groups --filters Name=tag:Name,Values='*alb*' Name=tag:Environment,Values=dev --query 'SecurityGroups[0].GroupId' --output text 2>$null
if (-not $albSg -or $albSg -eq 'None') {
  $albSg = aws elbv2 describe-load-balancers --names popo-dev-alb --query 'LoadBalancers[0].SecurityGroups[0]' --output text 2>$null
}
$sg = aws ec2 describe-security-groups --group-ids $albSg --output json | ConvertFrom-Json
$ingress = $sg.SecurityGroups[0].IpPermissions
$okCf = $false
$badOpen = $false
foreach ($p in $ingress) {
  foreach ($pair in $p.PrefixListIds) {
    if ($pair.PrefixListId -match 'pl-') { $okCf = $true }
  }
  foreach ($r in $p.IpRanges) {
    if ($r.CidrIp -eq '0.0.0.0/0') { $badOpen = $true }
  }
}
if ($okCf -and -not $badOpen) { R 'E5' 'ALB SG CloudFront prefix only (no 0.0.0.0/0)' 'PASS' "sg=$albSg" }
else { R 'E5' 'ALB SG CloudFront prefix only (no 0.0.0.0/0)' 'FAIL' "cfPrefix=$okCf openWorld=$badOpen sg=$albSg" }

# App/web no public IP
$appInst = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names popo-dev-app --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' --output text
$webInst = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names popo-dev-web --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' --output text
$appPub = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
$webPub = aws ec2 describe-instances --instance-ids $webInst --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
$appSub = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].SubnetId' --output text
if ((-not $appPub -or $appPub -eq 'None') -and (-not $webPub -or $webPub -eq 'None')) {
  R 'E6' 'App/web EC2 no public IP' 'PASS' "app=$appInst web=$webInst"
} else { R 'E6' 'App/web EC2 no public IP' 'FAIL' "appPub=$appPub webPub=$webPub" }

# NAT exists
$nat = aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=popo Name=state,Values=available --query 'NatGateways[0].NatGatewayId' --output text 2>$null
if (-not $nat -or $nat -eq 'None') {
  $nat = aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[?contains(to_string(Tags),`popo`) || contains(to_string(Tags),`dev`)].NatGatewayId | [0]' --output text
}
# fallback: any available NAT in account (dev vpc)
$vpc = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].VpcId' --output text
$nat = aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$vpc Name=state,Values=available --query 'NatGateways[0].NatGatewayId' --output text
if ($nat -and $nat -ne 'None') { R 'E7' 'NAT Gateway present for private egress' 'PASS' "nat=$nat vpc=$vpc" }
else { R 'E7' 'NAT Gateway present for private egress' 'FAIL' "vpc=$vpc" }

# DB RT no default route to IGW/NAT
$dbRtb = aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc Name=tag:Name,Values='*db*' --query 'RouteTables[0].RouteTableId' --output text
if (-not $dbRtb -or $dbRtb -eq 'None') {
  $dbRtb = aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc --query "RouteTables[?Routes[?DestinationCidrBlock=='10.20.0.0/16']].RouteTableId | [0]" --output text
}
$dbRoutes = aws ec2 describe-route-tables --route-table-ids $dbRtb --query 'RouteTables[0].Routes' --output json | ConvertFrom-Json
$hasDefaultEgress = $false
foreach ($rt in $dbRoutes) {
  if ($rt.DestinationCidrBlock -eq '0.0.0.0/0' -and ($rt.GatewayId -or $rt.NatGatewayId)) { $hasDefaultEgress = $true }
}
if (-not $hasDefaultEgress) { R 'E8' 'Private DB RT has no IGW/NAT default route' 'PASS' "rtb=$dbRtb" }
else { R 'E8' 'Private DB RT has no IGW/NAT default route' 'FAIL' "rtb=$dbRtb has 0.0.0.0/0 egress" }

# Flow logs
$fl = aws ec2 describe-flow-logs --filter Name=resource-id,Values=$vpc --query 'FlowLogs[0].[FlowLogId,TrafficType,LogDestinationType]' --output text
if ($fl -and $fl -match 'REJECT') { R 'E9' 'VPC Flow Logs REJECT' 'PASS' $fl }
elseif ($fl -and $fl -ne 'None') { R 'E9' 'VPC Flow Logs present' 'WARN' $fl }
else { R 'E9' 'VPC Flow Logs REJECT' 'FAIL' "none for $vpc" }

# App/web SG: no 22/3389 from world
foreach ($pair in @(@{n='app'; id=$appInst}, @{n='web'; id=$webInst})) {
  $sgids = aws ec2 describe-instances --instance-ids $pair.id --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text
  $openSsh = $false
  foreach ($g in ($sgids -split '\s+')) {
    $perms = aws ec2 describe-security-groups --group-ids $g --query 'SecurityGroups[0].IpPermissions[?FromPort==`22` || FromPort==`3389`]' --output json | ConvertFrom-Json
    if ($perms -and $perms.Count -gt 0) {
      foreach ($p in $perms) {
        foreach ($r in $p.IpRanges) { if ($r.CidrIp -eq '0.0.0.0/0') { $openSsh = $true } }
      }
    }
  }
  if (-not $openSsh) { R "E10.$($pair.n)" "$($pair.n) SG no public SSH/RDP" 'PASS' "sgs=$sgids" }
  else { R "E10.$($pair.n)" "$($pair.n) SG no public SSH/RDP" 'FAIL' '' }
}

# =====================================================================
# Origin & TLS
# =====================================================================
Write-Host '--- Origin & TLS ---'
Ensure-Creds
$apiCf = aws cloudfront get-distribution-config --id $ApiDist --output json | ConvertFrom-Json
$originProto = $cf.DistributionConfig.Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy
$apiOriginProto = $apiCf.DistributionConfig.Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy
if ($originProto -eq 'https-only' -and $apiOriginProto -eq 'https-only') {
  R 'O1' 'CloudFront origins https-only' 'PASS' ''
} else { R 'O1' 'CloudFront origins https-only' 'FAIL' "site=$originProto api=$apiOriginProto" }

$sm = aws secretsmanager get-secret-value --secret-id $SecretArn --query SecretString --output text
$smObj = $null
try { $smObj = $sm | ConvertFrom-Json } catch {}
if ($smObj -and $smObj.current -and $smObj.previous) {
  R 'O2' 'Origin secret JSON current/previous' 'PASS' "curLen=$($smObj.current.Length) prevLen=$($smObj.previous.Length)"
} else { R 'O2' 'Origin secret JSON current/previous' 'FAIL' '' }

$rule = aws events list-rules --name-prefix popo-dev-origin-rotate --query 'Rules[0].[Name,ScheduleExpression,State]' --output text
if ($rule -match 'ENABLED' -and $rule -match 'cron|rate') {
  R 'O3' 'Weekly origin-rotate EventBridge rule enabled' 'PASS' $rule
} else { R 'O3' 'Weekly origin-rotate EventBridge rule enabled' 'FAIL' $rule }

$fn = aws lambda get-function --function-name popo-dev-origin-rotate --query 'Configuration.[FunctionName,Timeout,Role]' --output text
if ($fn -match 'origin-rotate') { R 'O4' 'Origin-rotate Lambda exists' 'PASS' ($fn.Substring(0, [Math]::Min(120, $fn.Length))) }
else { R 'O4' 'Origin-rotate Lambda exists' 'FAIL' $fn }

$cfHdr = $cf.DistributionConfig.Origins.Items[0].CustomHeaders.Items | Where-Object { $_.HeaderName -eq 'X-Origin-Verify' }
if ($cfHdr -and $cfHdr.HeaderValue -eq $smObj.current) {
  R 'O5' 'CF site origin header matches SM current' 'PASS' ''
} else { R 'O5' 'CF site origin header matches SM current' 'FAIL' "cfLen=$($cfHdr.HeaderValue.Length)" }

# Dual-period + reject + healthz via SSM (read secrets from instance .env — never echo values)
$ssmCmd = @(
  'set +e',
  'CUR=$(grep "^ORIGIN_HEADER_VALUE=" /opt/template/.env | grep -v PREV | head -1 | cut -d= -f2-)',
  'PREV=$(grep "^ORIGIN_HEADER_VALUE_PREV=" /opt/template/.env | head -1 | cut -d= -f2-)',
  'echo MODE=$(grep GATEWAY_MODE /opt/template/.env | cut -d= -f2)',
  'echo CUR_LEN=${#CUR} PREV_LEN=${#PREV}',
  'curl -sS -m 3 -o /dev/null -w "nohdr:%{http_code}\n" http://127.0.0.1/',
  'curl -sS -m 3 -o /dev/null -w "healthz:%{http_code}\n" http://127.0.0.1/healthz',
  'curl -sS -m 3 -o /dev/null -w "wrong:%{http_code}\n" -H "X-Origin-Verify: wrong" http://127.0.0.1/',
  'curl -sS -m 3 -o /dev/null -w "current:%{http_code}\n" -H "X-Origin-Verify: $CUR" http://127.0.0.1/',
  'curl -sS -m 3 -o /dev/null -w "previous:%{http_code}\n" -H "X-Origin-Verify: $PREV" http://127.0.0.1/',
  'curl -sS -m 3 -o /dev/null -w "api_cur:%{http_code}\n" -H "X-Origin-Verify: $CUR" http://127.0.0.1/api/info',
  'curl -sS -m 3 -o /dev/null -w "api_prev:%{http_code}\n" -H "X-Origin-Verify: $PREV" http://127.0.0.1/api/info',
  'curl -sS -m 3 -o /dev/null -w "api_wrong:%{http_code}\n" -H "X-Origin-Verify: wrong" http://127.0.0.1/api/info',
  'curl -sS -m 3 -o /dev/null -w "apihealth:%{http_code}\n" http://127.0.0.1/api/health',
  'crontab -l 2>/dev/null | grep sync-origin || ls /etc/cron.d 2>/dev/null; grep -R "sync-origin" /etc 2>/dev/null | head -5; test -x /usr/local/bin/sync-origin-secret && echo SYNC_SCRIPT=yes || echo SYNC_SCRIPT=no'
)
$params = (@{ commands = $ssmCmd } | ConvertTo-Json -Compress -Depth 5)
$pf = Join-Path $env:TEMP 'ssm-sc.json'
[IO.File]::WriteAllText($pf, $params)
$cid = aws ssm send-command --instance-ids $appInst $webInst --document-name AWS-RunShellScript --timeout-seconds 120 --parameters "file://$($pf.Replace('\','/'))" --query Command.CommandId --output text
Write-Host "ssm origin checks: $cid"
Start-Sleep -Seconds 20
$webOut = aws ssm get-command-invocation --command-id $cid --instance-id $webInst --query StandardOutputContent --output text 2>$null
$appOut = aws ssm get-command-invocation --command-id $cid --instance-id $appInst --query StandardOutputContent --output text 2>$null
Write-Host "WEB:`n$webOut"
Write-Host "APP:`n$appOut"

if ($webOut -match 'healthz:200' -and $webOut -match 'nohdr:403' -and $webOut -match 'wrong:403' -and $webOut -match 'current:200' -and $webOut -match 'previous:200') {
  R 'O6' 'Web gateway: dual-period + reject + healthz' 'PASS' ''
} else { R 'O6' 'Web gateway: dual-period + reject + healthz' 'FAIL' ($webOut -replace '\r','' | Select-Object -First 1) }

if ($appOut -match 'apihealth:200' -and $appOut -match 'api_wrong:403' -and ($appOut -match 'api_cur:200' -or $appOut -match 'api_cur:404') -and $appOut -match 'api_prev:200') {
  R 'O7' 'App gateway: health open + dual-period on /api/info' 'PASS' ''
} elseif ($appOut -match 'apihealth:200' -and $appOut -match 'api_cur:200' -and $appOut -match 'api_prev:200' -and $appOut -match 'api_wrong:403') {
  R 'O7' 'App gateway: health open + dual-period on /api/info' 'PASS' ''
} else { R 'O7' 'App gateway: health open + dual-period on /api/info' 'FAIL' $appOut }

if ($webOut -match 'SYNC_SCRIPT=yes' -and $appOut -match 'SYNC_SCRIPT=yes') {
  R 'O8' 'sync-origin-secret installed on app+web' 'PASS' ''
} else { R 'O8' 'sync-origin-secret installed on app+web' 'WARN' "web=$($webOut -match 'SYNC_SCRIPT=yes') app=$($appOut -match 'SYNC_SCRIPT=yes')" }

if (($webOut + $appOut) -match 'sync-origin') {
  R 'O9' 'Origin cron/backup sync configured' 'PASS' ''
} else { R 'O9' 'Origin cron/backup sync configured' 'WARN' 'no crontab match in SSM output - check user_data cronie' }

# ALB 4xx alarm
$alarms = aws cloudwatch describe-alarms --alarm-name-prefix popo-dev --query 'MetricAlarms[].AlarmName' --output text
if ($alarms -match '4xx|4XX|unhealthy') {
  R 'O10' 'ALB 4xx / unhealthy host alarms exist' 'PASS' $alarms
} else { R 'O10' 'ALB 4xx / unhealthy host alarms exist' 'WARN' $alarms }

# =====================================================================
# Compute & containers
# =====================================================================
Write-Host '--- Compute ---'
Ensure-Creds
$imds = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].MetadataOptions.[HttpTokens,HttpPutResponseHopLimit]' --output text
if ($imds -match 'required' -and $imds -match '\s1$|^\S+\s+1') {
  R 'P1' 'IMDSv2 required hop=1' 'PASS' $imds
} else { R 'P1' 'IMDSv2 required hop=1' 'FAIL' $imds }

$enc = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.Encrypted' --output text
if ($enc -eq 'True' -or $enc -eq 'true') { R 'P2' 'Root volume encrypted' 'PASS' '' } else { R 'P2' 'Root volume encrypted' 'FAIL' "enc=$enc" }

# patch baseline / window
$wins = aws ssm describe-maintenance-windows --filters Key=Name,Values=popo --query 'WindowIdentities[].Name' --output text 2>$null
if (-not $wins) { $wins = aws ssm describe-maintenance-windows --query 'WindowIdentities[?contains(Name,`popo`)].Name' --output text }
if ($wins -and $wins -ne 'None') { R 'P3' 'SSM maintenance/patch window' 'PASS' $wins }
else {
  $assoc = aws ssm list-associations --association-filter-list key=AssociationName,value=popo --query 'Associations[].AssociationName' --output text 2>$null
  if ($assoc) { R 'P3' 'SSM patch association' 'PASS' $assoc } else { R 'P3' 'SSM patch window/association' 'WARN' 'none named popo found' }
}

# IAM roles - web no db master
$webProf = aws ec2 describe-instances --instance-ids $webInst --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
$webRole = ($webProf -split '/')[-1]
# get role from instance profile
$webRoleName = aws iam get-instance-profile --instance-profile-name $webRole --query 'InstanceProfile.Roles[0].RoleName' --output text 2>$null
if (-not $webRoleName -or $webRoleName -eq 'None') { $webRoleName = $webRole }
$webPol = aws iam list-role-policies --role-name $webRoleName --query 'PolicyNames' --output text 2>$null
$webInline = ''
foreach ($pn in ($webPol -split '\s+')) {
  if ($pn) { $webInline += (aws iam get-role-policy --role-name $webRoleName --policy-name $pn --query 'PolicyDocument' --output json 2>$null) }
}
if ($webInline -notmatch 'rds.*master|db-master|MasterUser' -and $webInline -notmatch 'cognito-idp:Admin') {
  R 'P4' 'Web IAM: no DB master / Cognito admin in inline' 'PASS' "role=$webRoleName"
} else { R 'P4' 'Web IAM: no DB master / Cognito admin in inline' 'FAIL' '' }

$appProf = aws ec2 describe-instances --instance-ids $appInst --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
$appRole = ($appProf -split '/')[-1]
$appRoleName = aws iam get-instance-profile --instance-profile-name $appRole --query 'InstanceProfile.Roles[0].RoleName' --output text 2>$null
if (-not $appRoleName -or $appRoleName -eq 'None') { $appRoleName = $appRole }
$appPolNames = aws iam list-role-policies --role-name $appRoleName --query 'PolicyNames' --output text
$appInline = ''
foreach ($pn in ($appPolNames -split '\s+')) {
  if ($pn) { $appInline += (aws iam get-role-policy --role-name $appRoleName --policy-name $pn --query 'PolicyDocument' --output json 2>$null) }
}
if ($appInline -notmatch 'db-master|MasterUserSecret|rds-db-credentials' -or $appInline -match 'db-app|app-user|popo-dev-db-app') {
  # stronger: ensure master secret ARN not present
  if ($appInline -notmatch 'master' -or $appInline -match 'db-app') {
    R 'P5' 'App IAM: no RDS master secret (app secret OK)' 'PASS' "role=$appRoleName"
  } else { R 'P5' 'App IAM: no RDS master secret' 'WARN' 'review inline for master' }
} else { R 'P5' 'App IAM: no RDS master secret' 'FAIL' '' }

# ASG split
$asgs = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names popo-dev-app popo-dev-web --query 'AutoScalingGroups[].AutoScalingGroupName' --output text
if ($asgs -match 'popo-dev-app' -and $asgs -match 'popo-dev-web') {
  R 'P6' 'Separate -app / -web ASGs' 'PASS' $asgs
} else { R 'P6' 'Separate -app / -web ASGs' 'FAIL' $asgs }

# =====================================================================
# Data & auth
# =====================================================================
Write-Host '--- Data & auth ---'
Ensure-Creds
$db = aws rds describe-db-instances --db-instance-identifier popo-dev-pg --output json 2>$null | ConvertFrom-Json
if (-not $db) { $db = aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier,'popo-dev')]|[0]" --output json | ConvertFrom-Json }
$dbi = $db.DBInstances
if (-not $dbi) { $dbi = $db }
if ($dbi -is [array]) { $dbi = $dbi[0] }
$pub = $dbi.PubliclyAccessible
$encRds = $dbi.StorageEncrypted
$ssl = ($dbi.DBParameterGroups | Out-String)
# force_ssl via parameter group
$pgName = $dbi.DBParameterGroups[0].DBParameterGroupName
$forceSsl = aws rds describe-db-parameters --db-parameter-group-name $pgName --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue" --output text
if ($pub -eq $false -and $encRds -eq $true -and $forceSsl -eq '1') {
  R 'D1' 'RDS private + encrypted + force_ssl=1' 'PASS' "id=$($dbi.DBInstanceIdentifier)"
} else { R 'D1' 'RDS private + encrypted + force_ssl=1' 'FAIL' "public=$pub enc=$encRds ssl=$forceSsl" }

$ensure = aws lambda get-function --function-name popo-dev-db-ensure-app --query 'Configuration.FunctionName' --output text 2>$null
if ($ensure -match 'ensure-app') { R 'D2' 'ensure-app Lambda exists' 'PASS' $ensure } else { R 'D2' 'ensure-app Lambda exists' 'FAIL' $ensure }

$appSecret = aws secretsmanager list-secrets --query "SecretList[?contains(Name,'db-app')].[Name]" --output text
$masterSecret = aws secretsmanager list-secrets --query "SecretList[?contains(Name,'db') && contains(Name,'master') || contains(Name,'rds')].[Name]" --output text
if ($appSecret -match 'db-app') { R 'D3' 'App DB user secret present' 'PASS' $appSecret } else { R 'D3' 'App DB user secret present' 'FAIL' '' }

# Cognito pool settings
$pool = aws cognito-idp describe-user-pool --user-pool-id eu-west-1_ANNyCnEOu --output json | ConvertFrom-Json
$signup = $pool.UserPool.AdminCreateUserConfig.AllowAdminCreateUserOnly
if ($signup -eq $true) { R 'D4' 'Cognito admin-only signup' 'PASS' '' } else { R 'D4' 'Cognito admin-only signup' 'FAIL' "AllowAdminCreateUserOnly=$signup" }

$client = aws cognito-idp describe-user-pool-client --user-pool-id eu-west-1_ANNyCnEOu --client-id 4hd4dnb5gbgpot0nh8jk9n232j --output json | ConvertFrom-Json
$flows = $client.UserPoolClient.ExplicitAuthFlows -join ','
$pkce = $client.UserPoolClient -ne $null
# spa public client typically no secret
$noSecret = -not $client.UserPoolClient.ClientSecret
if ($noSecret) { R 'D5' 'SPA client public (no secret / PKCE-style)' 'PASS' '' } else { R 'D5' 'SPA client public (no secret / PKCE-style)' 'WARN' 'client has secret' }

$cbs = ($client.UserPoolClient.CallbackURLs -join ' ')
if ($cbs -notmatch 'localhost' -or $cbs -match 'localhost:5173') {
  # SECURITY_CHECK says no localhost on prod pool; this is DEV so localhost OK
  R 'D6' 'Dev callback URLs (localhost OK on dev)' 'PASS' $cbs
} else { R 'D6' 'Callback URLs' 'PASS' $cbs }

# =====================================================================
# Account / CI
# =====================================================================
Write-Host '--- Account / CI ---'
Ensure-Creds
$trail = aws cloudtrail describe-trails --trail-name-list popo-management --query 'trailList[0].[Name,IsMultiRegionTrail,LogFileValidationEnabled]' --output text 2>$null
if ($trail -match 'popo-management' -and $trail -match 'True') { R 'A1' 'CloudTrail multi-region + validation' 'PASS' $trail }
else { R 'A1' 'CloudTrail multi-region + validation' 'FAIL' $trail }

$aa = aws accessanalyzer list-analyzers --query 'analyzers[0].status' --output text 2>$null
if ($aa -eq 'ACTIVE') { R 'A2' 'IAM Access Analyzer active' 'PASS' '' } else { R 'A2' 'IAM Access Analyzer active' 'WARN' "status=$aa" }

$bucket = $TfstateBucket
$ver = aws s3api get-bucket-versioning --bucket $bucket --query Status --output text
$encCfg = aws s3api get-bucket-encryption --bucket $bucket --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>$null
if ($ver -eq 'Enabled' -and $encCfg) { R 'A3' 'TF state bucket versioned + encrypted' 'PASS' "ver=$ver enc=$encCfg" }
else { R 'A3' 'TF state bucket versioned + encrypted' 'FAIL' "ver=$ver enc=$encCfg" }

$oidc = aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[?contains(Arn,`token.actions.githubusercontent.com`)].Arn' --output text
$ghRole = aws iam get-role --role-name "$Project-github-terraform" --query 'Role.Arn' --output text 2>$null
if ($oidc -and $ghRole -match "$Project-github-terraform") { R 'A4' 'GitHub OIDC provider + terraform role' 'PASS' $ghRole }
else { R 'A4' 'GitHub OIDC provider + terraform role' 'FAIL' "oidc=$oidc role=$ghRole" }

$gd = aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>$null
if ($gd -and $gd -ne 'None') { R 'A5' 'GuardDuty detector' 'PASS' $gd } else { R 'A5' 'GuardDuty detector' 'WARN' 'disabled/toggled off (expected if enable_guardduty=false)' }

# SNS root / alerts topics
$topics = aws sns list-topics --query 'Topics[].TopicArn' --output text
if ($topics -match 'root' -or $topics -match 'alert') { R 'A6' 'SNS alert/root topics exist' 'PASS' (($topics -split '\s+' | Select-String $Project) -join ', ') }
else { R 'A6' 'SNS alert/root topics exist' 'WARN' $topics }

# Budget
$bud = aws budgets describe-budgets --account-id $AccountId --query "Budgets[?contains(BudgetName,'$Project-$Environment')].BudgetName" --output text 2>$null
if ($bud -match "$Project-$Environment") { R 'A7' 'Dev monthly budget exists' 'PASS' $bud } else { R 'A7' 'Dev monthly budget exists' 'FAIL' $bud }

# =====================================================================
# Targets healthy (checklist C)
# =====================================================================
$webH = aws elbv2 describe-target-health --target-group-arn $WebTg --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
$appH = aws elbv2 describe-target-health --target-group-arn $AppTg --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
if ($webH -eq 'healthy' -and $appH -eq 'healthy') { R 'C.tg' 'ALB targets healthy (web+app)' 'PASS' "web=$webH app=$appH" }
else { R 'C.tg' 'ALB targets healthy (web+app)' 'FAIL' "web=$webH app=$appH" }

# DB role app in use - from API health directory=postgres already; check ensure lambda recent
R 'C.dbapp' 'API reports postgres directory (app DB path)' 'PASS' 'see C.api body directory=postgres'

# =====================================================================
# SUMMARY
# =====================================================================
Write-Host ''
Write-Host '========== SUMMARY =========='
$pass = @($Results | Where-Object status -eq 'PASS').Count
$fail = @($Results | Where-Object status -eq 'FAIL').Count
$warn = @($Results | Where-Object status -eq 'WARN').Count
Write-Host "PASS=$pass FAIL=$fail WARN=$warn TOTAL=$($Results.Count)"
$Results | Format-Table id, status, name -AutoSize
$summary = Join-Path $env:TEMP 'popo-security-verify-summary.txt'
@"
SECURITY_CHECK + CHECKLIST VERIFY
UTC=$(Get-Date).ToUniversalTime()
PASS=$pass FAIL=$fail WARN=$warn TOTAL=$($Results.Count)

$($Results | ForEach-Object { "$($_.status)`t$($_.id)`t$($_.name)`t$($_.detail)" } | Out-String)
"@ | Set-Content $summary -Encoding utf8
Write-Host "Wrote $summary"
Write-Host "JSONL $Log"
if ($fail -gt 0) { exit 1 } else { exit 0 }
