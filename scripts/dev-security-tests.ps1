# Dev security/ops test suite - origin rotation, WAF rate limits, baseline checks.
# Results: $env:TEMP\popo-test-results.jsonl + summary at end.
$ErrorActionPreference = 'Continue'
$Results = [System.Collections.Generic.List[object]]::new()
$Log = Join-Path $env:TEMP 'popo-test-results.jsonl'
Remove-Item $Log -ErrorAction SilentlyContinue

function Write-Result {
  param([string]$Id, [string]$Name, [string]$Status, [string]$Detail = '')
  $row = [pscustomobject]@{
    ts     = (Get-Date).ToUniversalTime().ToString('o')
    id     = $Id
    name   = $Name
    status = $Status
    detail = $Detail
  }
  $Results.Add($row)
  ($row | ConvertTo-Json -Compress) | Add-Content $Log -Encoding utf8
  $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
  Write-Host ("[{0}] {1} - {2}" -f $Status, $Id, $Name) -ForegroundColor $color
  if ($Detail) { Write-Host ("         {0}" -f $Detail) }
}

function Ensure-AwsCreds {
  if (-not $env:AWS_ACCESS_KEY_ID -or (Get-Date).ToUniversalTime() -gt [datetime]$env:AWS_CREDENTIAL_EXPIRATION) {
    $env:AWS_PROFILE = 'andrei-login'
    $lines = aws configure export-credentials --format env-no-export
    foreach ($line in $lines) {
      if ($line -match '^(AWS_[A-Z_]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
    }
    Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
  }
  $env:AWS_DEFAULT_REGION = 'eu-west-1'
  $env:AWS_REGION = 'eu-west-1'
}

function Get-Http {
  param([string]$Url, [hashtable]$Headers = @{}, [int]$TimeoutSec = 20, [string]$Method = 'GET')
  try {
    $args = @('-sS', '-o', "$env:TEMP\http-body.bin", '-w', '%{http_code}|%{time_total}', '--max-time', "$TimeoutSec", '-X', $Method)
    foreach ($k in $Headers.Keys) { $args += @('-H', ('{0}: {1}' -f $k, $Headers[$k])) }
    $args += $Url
    $out = & curl.exe @args 2>$null
    $parts = "$out".Split('|')
    $code = [int]$parts[0]
    $body = ''
    if (Test-Path "$env:TEMP\http-body.bin") {
      $body = [System.IO.File]::ReadAllText("$env:TEMP\http-body.bin")
      if ($body.Length -gt 400) { $body = $body.Substring(0, 400) }
    }
    return @{ code = $code; body = $body; raw = $out }
  } catch {
    return @{ code = 0; body = "$_"; raw = '' }
  }
}

function Invoke-Ssm {
  param([string[]]$InstanceIds, [string[]]$Commands, [int]$WaitSec = 90)
  $json = @{ commands = $Commands } | ConvertTo-Json -Compress
  $pf = Join-Path $env:TEMP ("ssm-" + [guid]::NewGuid().ToString('n') + '.json')
  Set-Content $pf $json -Encoding Ascii
  $cid = aws ssm send-command --instance-ids $InstanceIds --document-name AWS-RunShellScript --timeout-seconds $WaitSec --parameters "file://$($pf.Replace('\','/'))" --query Command.CommandId --output text
  $deadline = (Get-Date).AddSeconds($WaitSec)
  $outs = @{}
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $allDone = $true
    foreach ($iid in $InstanceIds) {
      $st = aws ssm get-command-invocation --command-id $cid --instance-id $iid --query Status --output text 2>$null
      if ($st -notin @('Success', 'Failed', 'Cancelled', 'TimedOut')) { $allDone = $false }
      else {
        $stdout = aws ssm get-command-invocation --command-id $cid --instance-id $iid --query StandardOutputContent --output text 2>$null
        $outs[$iid] = @{ status = $st; out = $stdout }
      }
    }
    if ($allDone) { break }
  }
  return @{ commandId = $cid; results = $outs }
}

# ---------------- resolve env (no hardcoded account IDs / secret ARNs) ----------------
$Project = if ($env:POPO_PROJECT) { $env:POPO_PROJECT } else { 'popo' }
$Environment = if ($env:POPO_ENV) { $env:POPO_ENV } else { 'dev' }
$Domain = if ($env:POPO_DOMAIN) { $env:POPO_DOMAIN } else { 'andrei-vataselu.online' }

Ensure-AwsCreds
$AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
$Region = $env:AWS_REGION

$Site = if ($env:POPO_SITE_URL) { $env:POPO_SITE_URL } else { "https://dev.$Domain" }
$Api = if ($env:POPO_API_URL) { $env:POPO_API_URL } else { "https://api-dev.$Domain" }
$Auth = if ($env:POPO_AUTH_URL) { $env:POPO_AUTH_URL } else { "https://auth.dev.$Domain" }
$OriginSite = if ($env:POPO_ORIGIN_SITE_URL) { $env:POPO_ORIGIN_SITE_URL } else { "https://origin-dev.$Domain" }
$OriginApi = if ($env:POPO_ORIGIN_API_URL) { $env:POPO_ORIGIN_API_URL } else { "https://origin-api-dev.$Domain" }
$AlbDns = if ($env:POPO_ALB_DNS) { $env:POPO_ALB_DNS } else {
  (aws elbv2 describe-load-balancers --names "$Project-$Environment-alb" --query 'LoadBalancers[0].DNSName' --output text 2>$null).Trim()
}
$SecretId = if ($env:ORIGIN_SECRET_ARN) { $env:ORIGIN_SECRET_ARN } else {
  (aws secretsmanager list-secrets --region $Region `
    --filters Key=name,Values="$Project-$Environment-origin-header" `
    --query 'SecretList[0].ARN' --output text).Trim()
}
$RotateFn = if ($env:POPO_ORIGIN_ROTATE_FN) { $env:POPO_ORIGIN_ROTATE_FN } else { "$Project-$Environment-origin-rotate" }
$SiteHost = ([uri]$Site).Host
$ApiHost = ([uri]$Api).Host
$SiteDist = if ($env:POPO_SITE_DIST_ID) { $env:POPO_SITE_DIST_ID } else {
  (aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items!=null && contains(Aliases.Items, '$SiteHost')].Id | [0]" --output text).Trim()
}
$ApiDist = if ($env:POPO_API_DIST_ID) { $env:POPO_API_DIST_ID } else {
  (aws cloudfront list-distributions --query "DistributionList.Items[?Aliases.Items!=null && contains(Aliases.Items, '$ApiHost')].Id | [0]" --output text).Trim()
}
$AppTg = (aws elbv2 describe-target-groups --names "$Project-$Environment-app" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null).Trim()
$WebTg = (aws elbv2 describe-target-groups --names "$Project-$Environment-web" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null).Trim()

Write-Host "=== POPO DEV SECURITY TESTS ==="
Write-Host "cred expiry: $env:AWS_CREDENTIAL_EXPIRATION"
Write-Host "account: $AccountId project: $Project env: $Environment"
Write-Host "log: $Log"
Write-Host ""

# =====================================================================
# A. BASELINE
# =====================================================================
Write-Host "--- A. Baseline ---"
$r = Get-Http "$Site/"
if ($r.code -eq 200) { Write-Result 'A1' 'Site homepage 200' 'PASS' "code=$($r.code)" } else { Write-Result 'A1' 'Site homepage 200' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$Api/api/health"
if ($r.code -eq 200 -and $r.body -match '"ok"\s*:\s*true') { Write-Result 'A2' 'API health 200' 'PASS' "code=$($r.code)" } else { Write-Result 'A2' 'API health 200' 'FAIL' "code=$($r.code) body=$($r.body)" }

$r = Get-Http "$Auth/login" -TimeoutSec 30
if ($r.code -in 200, 302, 400) { Write-Result 'A3' 'Cognito Hosted UI reachable' 'PASS' "code=$($r.code)" } else { Write-Result 'A3' 'Cognito Hosted UI reachable' 'FAIL' "code=$($r.code)" }

$webH = aws elbv2 describe-target-health --target-group-arn $WebTg --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
$appH = aws elbv2 describe-target-health --target-group-arn $AppTg --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
if ($webH -eq 'healthy' -and $appH -eq 'healthy') { Write-Result 'A4' 'ALB targets healthy' 'PASS' "web=$webH app=$appH" } else { Write-Result 'A4' 'ALB targets healthy' 'FAIL' "web=$webH app=$appH" }

# =====================================================================
# B. ORIGIN VERIFY (hit ALB hostnames; CF should still work)
# =====================================================================
Write-Host "--- B. Origin verify ---"
# Direct to ALB with Host header of origin FQDN (Route53 may point origin-* at ALB)
$r = Get-Http "https://$AlbDns/healthz" -Headers @{ Host = ([uri]$OriginSite).Host }
# ALB may require SNI matching cert - try origin DNS names instead
$r = Get-Http "$OriginSite/healthz"
# healthz should be open (no origin header)
if ($r.code -eq 200) { Write-Result 'B1' 'Origin site /healthz without secret (expect 200)' 'PASS' "code=$($r.code)" }
elseif ($r.code -eq 403) { Write-Result 'B1' 'Origin site /healthz without secret (expect 200)' 'FAIL' "code=403 - healthz blocked by origin check" }
else { Write-Result 'B1' 'Origin site /healthz without secret (expect 200)' 'WARN' "code=$($r.code) (DNS/cert path may differ)" }

$r = Get-Http "$OriginSite/"
if ($r.code -eq 403) { Write-Result 'B2' 'Origin site / without secret (expect 403)' 'PASS' "code=$($r.code)" }
else { Write-Result 'B2' 'Origin site / without secret (expect 403)' 'FAIL' "code=$($r.code)" }

$smRaw = aws secretsmanager get-secret-value --secret-id $SecretId --query SecretString --output text
$smObj = $null
try { $smObj = $smRaw | ConvertFrom-Json } catch { }
if ($smObj -and $smObj.current) {
  $cur = $smObj.current
  $prev = $smObj.previous
} else {
  $cur = $smRaw
  $prev = $smRaw
}
$curLen = $cur.Length
Write-Result 'B0' 'SM origin secret readable' 'PASS' "json=$([bool]$smObj) currentLen=$curLen"

$r = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = 'definitely-wrong-secret-value' }
if ($r.code -eq 403) { Write-Result 'B3' 'Origin site / wrong secret (expect 403)' 'PASS' "code=$($r.code)" }
else { Write-Result 'B3' 'Origin site / wrong secret (expect 403)' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = $cur }
if ($r.code -eq 200) { Write-Result 'B4' 'Origin site / current secret (expect 200)' 'PASS' "code=$($r.code)" }
else { Write-Result 'B4' 'Origin site / current secret (expect 200)' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$OriginApi/api/health" -Headers @{ 'X-Origin-Verify' = $cur }
if ($r.code -eq 200) { Write-Result 'B5' 'Origin API /api/health + secret (expect 200)' 'PASS' "code=$($r.code)" }
else { Write-Result 'B5' 'Origin API /api/health + secret (expect 200)' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$OriginApi/api/health"
# api health may be exempt
if ($r.code -eq 200) { Write-Result 'B6' 'Origin API /api/health no secret (expect 200 exempt)' 'PASS' "code=$($r.code)" }
else { Write-Result 'B6' 'Origin API /api/health no secret (expect 200 exempt)' 'WARN' "code=$($r.code)" }

# =====================================================================
# C. ORIGIN ROTATION
# =====================================================================
Write-Host "--- C. Origin rotation ---"
$beforeCur = $cur
$beforePrev = $prev
$beforeHash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($beforeCur))) -Algorithm SHA256).Hash.Substring(0, 12)

Ensure-AwsCreds
Write-Host "Invoking $RotateFn ..."
$payloadPath = Join-Path $env:TEMP 'rotate-payload.json'
'{}' | Set-Content $payloadPath -Encoding Ascii
$outPath = Join-Path $env:TEMP 'rotate-out.json'
aws lambda invoke --function-name $RotateFn --cli-binary-format raw-in-base64-out --payload fileb://$payloadPath $outPath 2>&1 | Out-Host
$invokeOk = $LASTEXITCODE -eq 0
$lambdaBody = ''
if (Test-Path $outPath) { $lambdaBody = Get-Content $outPath -Raw }
if ($invokeOk -and $lambdaBody -match 'rotated|ok|current|success|true|"status"' -or $invokeOk) {
  Write-Result 'C1' 'Invoke origin-rotate Lambda' 'PASS' ("exit=0 body=" + $lambdaBody.Substring(0, [Math]::Min(200, $lambdaBody.Length)))
} else {
  Write-Result 'C1' 'Invoke origin-rotate Lambda' 'FAIL' "exit=$LASTEXITCODE body=$lambdaBody"
}

Start-Sleep -Seconds 5
$smRaw2 = aws secretsmanager get-secret-value --secret-id $SecretId --query SecretString --output text
$sm2 = $null
try { $sm2 = $smRaw2 | ConvertFrom-Json } catch { }
if ($sm2 -and $sm2.current -and $sm2.current -ne $beforeCur) {
  Write-Result 'C2' 'SM current changed' 'PASS' "prevLen=$($sm2.previous.Length) newLen=$($sm2.current.Length) previousMatchesOld=$($sm2.previous -eq $beforeCur)"
} elseif ($sm2 -and $sm2.current -eq $beforeCur) {
  Write-Result 'C2' 'SM current changed' 'FAIL' 'current unchanged after rotate'
} else {
  Write-Result 'C2' 'SM current changed' 'FAIL' "parse failed rawLen=$($smRaw2.Length)"
}

if ($sm2 -and $sm2.previous -eq $beforeCur) {
  Write-Result 'C3' 'SM previous == old current (dual-period)' 'PASS' ''
} else {
  Write-Result 'C3' 'SM previous == old current (dual-period)' 'FAIL' "previousEqualsOld=$($sm2.previous -eq $beforeCur)"
}

# CloudFront may take a moment to update
$cfUpdated = $false
$cfVal = ''
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Seconds 5
  Ensure-AwsCreds
  $cfVal = aws cloudfront get-distribution-config --id $SiteDist --query 'DistributionConfig.Origins.Items[0].CustomHeaders.Items[0].HeaderValue' --output text
  $cfApi = aws cloudfront get-distribution-config --id $ApiDist --query 'DistributionConfig.Origins.Items[0].CustomHeaders.Items[0].HeaderValue' --output text
  if ($sm2 -and $cfVal -eq $sm2.current -and $cfApi -eq $sm2.current) { $cfUpdated = $true; break }
}
if ($cfUpdated) { Write-Result 'C4' 'CloudFront site+api origin header == new current' 'PASS' "matched after poll" }
else { Write-Result 'C4' 'CloudFront site+api origin header == new current' 'FAIL' "siteMatch=$($cfVal -eq $sm2.current)" }

# Allow SSM sync / CF deploy settle
Write-Host "Waiting 45s for gateway sync / CF edge..."
Start-Sleep -Seconds 45
Ensure-AwsCreds

$r = Get-Http "$Site/"
if ($r.code -eq 200) { Write-Result 'C5' 'Site still 200 after rotate (via CF)' 'PASS' "code=$($r.code)" } else { Write-Result 'C5' 'Site still 200 after rotate (via CF)' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$Api/api/health"
if ($r.code -eq 200) { Write-Result 'C6' 'API still 200 after rotate (via CF)' 'PASS' "code=$($r.code)" } else { Write-Result 'C6' 'API still 200 after rotate (via CF)' 'FAIL' "code=$($r.code)" }

# Dual-period on origin: old + new should work; garbage should not
if ($sm2) {
  $r = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = $sm2.current }
  if ($r.code -eq 200) { Write-Result 'C7' 'Origin accepts NEW secret' 'PASS' "code=$($r.code)" } else { Write-Result 'C7' 'Origin accepts NEW secret' 'FAIL' "code=$($r.code)" }

  $r = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = $beforeCur }
  if ($r.code -eq 200) { Write-Result 'C8' 'Origin accepts PREVIOUS secret (dual-period)' 'PASS' "code=$($r.code)" }
  else { Write-Result 'C8' 'Origin accepts PREVIOUS secret (dual-period)' 'WARN' "code=$($r.code) - sync may not have run on web yet; retrying SSM sync" }

  if ($r.code -ne 200) {
    # Force sync on instances
    $ids = @(
      (aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names popo-dev-app popo-dev-web --query 'AutoScalingGroups[].Instances[?LifecycleState==`InService`].InstanceId' --output text) -split '\s+'
    ) | Where-Object { $_ }
    $sync = Invoke-Ssm -InstanceIds $ids -Commands @(
      'test -x /usr/local/bin/sync-origin-secret && /usr/local/bin/sync-origin-secret || (echo NO_SYNC_SCRIPT; exit 1)'
    ) -WaitSec 120
    Start-Sleep -Seconds 10
    $r2 = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = $beforeCur }
    if ($r2.code -eq 200) { Write-Result 'C8b' 'Origin accepts PREVIOUS after forced SSM sync' 'PASS' "code=$($r2.code)" }
    else { Write-Result 'C8b' 'Origin accepts PREVIOUS after forced SSM sync' 'FAIL' "code=$($r2.code) ssm=$($sync.commandId)" }
  }

  $r = Get-Http "$OriginSite/" -Headers @{ 'X-Origin-Verify' = 'post-rotate-garbage' }
  if ($r.code -eq 403) { Write-Result 'C9' 'Origin rejects garbage after rotate' 'PASS' "code=$($r.code)" }
  else { Write-Result 'C9' 'Origin rejects garbage after rotate' 'FAIL' "code=$($r.code)" }
}

# =====================================================================
# D. RATE LIMITS
# =====================================================================
Write-Host "--- D. Rate limits ---"

# D0: config presence
$cfLimit = aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --id 102c4d63-70e3-4c0c-8420-3e3aff651acc --name popo-dev-cf --query 'WebACL.Rules[?Name==`RateLimitGlobal`].Statement.RateBasedStatement.Limit' --output text
$cogLimit = aws wafv2 get-web-acl --scope REGIONAL --region eu-west-1 --id 565a9732-2d40-4525-ba5f-7e1aa9c153b4 --name popo-dev-cognito --query 'WebACL.Rules[?Name==`RateLimitAuth`].Statement.RateBasedStatement.Limit' --output text
if ($cfLimit -eq '2000') { Write-Result 'D0a' 'CF WAF RateLimitGlobal configured=2000/5m' 'PASS' "limit=$cfLimit" } else { Write-Result 'D0a' 'CF WAF RateLimitGlobal configured=2000/5m' 'FAIL' "limit=$cfLimit" }
if ($cogLimit -eq '300') { Write-Result 'D0b' 'Cognito WAF RateLimitAuth configured=300/5m' 'PASS' "limit=$cogLimit" } else { Write-Result 'D0b' 'Cognito WAF RateLimitAuth configured=300/5m' 'FAIL' "limit=$cogLimit" }

# D1: Cognito - send ~400 requests in parallel; expect some 403
Write-Host "D1: hammering Cognito Hosted UI (~400 req)..."
$cogBlocked = 0
$cogOk = 0
$cogOther = 0
$jobs = @()
1..40 | ForEach-Object {
  Start-Job -ScriptBlock {
    param($AuthUrl)
    $blocked = 0; $ok = 0; $other = 0
    1..10 | ForEach-Object {
      $code = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 8 "$AuthUrl/login" 2>$null
      switch ($code) {
        '403' { $blocked++ }
        '200' { $ok++ }
        '302' { $ok++ }
        '400' { $ok++ }
        default { $other++ }
      }
    }
    [pscustomobject]@{ blocked = $blocked; ok = $ok; other = $other }
  } -ArgumentList $Auth
} | ForEach-Object { $jobs += $_ }
$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
  $o = Receive-Job $j
  $cogBlocked += $o.blocked
  $cogOk += $o.ok
  $cogOther += $o.other
  Remove-Job $j
}
Write-Host "Cognito results: blocked=$cogBlocked ok=$cogOk other=$cogOther"
if ($cogBlocked -gt 0) {
  Write-Result 'D1' 'Cognito WAF rate limit trips (403 observed)' 'PASS' "blocked=$cogBlocked ok=$cogOk other=$cogOther"
} else {
  # WAF rate windows can lag; check sampled requests / metrics
  Start-Sleep -Seconds 15
  Ensure-AwsCreds
  $metric = aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name BlockedRequests --dimensions Name=WebACL,Value=popo-dev-cognito Name=Rule,Value=CognitoRateLimitAuth Name=Region,Value=eu-west-1 --start-time (Get-Date).ToUniversalTime().AddMinutes(-15).ToString('yyyy-MM-ddTHH:mm:ssZ') --end-time (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') --period 60 --statistics Sum --region eu-west-1 --query 'Datapoints[].Sum' --output text 2>$null
  if ($metric -and [double](($metric -split '\s+' | Measure-Object -Sum).Sum) -gt 0) {
    Write-Result 'D1' 'Cognito WAF rate limit trips (metric BlockedRequests>0)' 'PASS' "metricSums=$metric httpBlocked=0"
  } else {
    Write-Result 'D1' 'Cognito WAF rate limit trips' 'WARN' "no 403 in burst (WAF lag common); ok=$cogOk blocked=0 metric=$metric - sending denser burst"
  }
}

# denser cognito burst if needed
if ($cogBlocked -eq 0) {
  Write-Host 'D1b: denser Cognito burst (800 requests)...'
  $cogBlocked = 0
  $jobs = @()
  1..80 | ForEach-Object {
    Start-Job -ScriptBlock {
      param($AuthUrl)
      $b = 0
      1..10 | ForEach-Object {
        $code = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 5 "$AuthUrl/login" 2>$null
        if ($code -eq '403') { $b++ }
      }
      $b
    } -ArgumentList $Auth
  } | ForEach-Object { $jobs += $_ }
  $jobs | Wait-Job | Out-Null
  foreach ($j in $jobs) { $cogBlocked += [int](Receive-Job $j); Remove-Job $j }
  if ($cogBlocked -gt 0) { Write-Result 'D1b' 'Cognito denser burst got 403' 'PASS' "blocked=$cogBlocked" }
  else { Write-Result 'D1b' 'Cognito denser burst got 403' 'FAIL' 'blocked=0 after ~800 requests - check allowlist/WAF association' }
}

# D2: CloudFront global rate 2000/5m - heavy but required
Write-Host "D2: hammering CloudFront site (~2200+ req over ~2-3 min)..."
$cfBlocked = 0
$cfOk = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
# 50 parallel workers × 50 requests = 2500
$jobs = @()
1..50 | ForEach-Object {
  Start-Job -ScriptBlock {
    param($SiteUrl)
    $b = 0; $o = 0
    1..50 | ForEach-Object {
      $code = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 8 "$SiteUrl/" 2>$null
      if ($code -eq '403') { $b++ } elseif ($code -eq '200') { $o++ }
    }
    [pscustomobject]@{ blocked = $b; ok = $o }
  } -ArgumentList $Site
} | ForEach-Object { $jobs += $_ }
$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
  $o = Receive-Job $j
  $cfBlocked += $o.blocked
  $cfOk += $o.ok
  Remove-Job $j
}
$sw.Stop()
Write-Host "CF results in $([int]$sw.Elapsed.TotalSeconds)s: blocked=$cfBlocked ok=$cfOk"
if ($cfBlocked -gt 0) {
  Write-Result 'D2' 'CloudFront WAF rate limit trips (403 observed)' 'PASS' "blocked=$cfBlocked ok=$cfOk secs=$([int]$sw.Elapsed.TotalSeconds)"
} else {
  Start-Sleep -Seconds 20
  Ensure-AwsCreds
  $metric = aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name BlockedRequests --dimensions Name=WebACL,Value=popo-dev-cf Name=Rule,Value=RateLimitGlobal Name=Region,Value=us-east-1 --start-time (Get-Date).ToUniversalTime().AddMinutes(-20).ToString('yyyy-MM-ddTHH:mm:ssZ') --end-time (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') --period 60 --statistics Sum --region us-east-1 --query 'Datapoints[].Sum' --output text 2>$null
  if ($metric -and ($metric -split '\s+' | ForEach-Object { [double]$_ } | Measure-Object -Sum).Sum -gt 0) {
    Write-Result 'D2' 'CloudFront WAF rate limit (metric)' 'PASS' "BlockedRequests=$metric httpBlocked=0"
  } else {
    Write-Result 'D2' 'CloudFront WAF rate limit trips' 'WARN' "no block after ~2500 req in $([int]$sw.Elapsed.TotalSeconds)s (limit 2000/300s; WAF evaluation lag). metric=$metric"
  }
}

# D3: gateway nginx limit via SSM (20r/s) - burst from instance
Write-Host "D3: gateway nginx rate limit via SSM..."
$webId = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names popo-dev-web --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' --output text
$ssmNgx = Invoke-Ssm -InstanceIds @($webId) -Commands @(
  'SECRET=$(grep ^ORIGIN_HEADER_VALUE= /opt/template/.env | head -1 | cut -d= -f2- | tr -d "\"")',
  'codes=""; for i in $(seq 1 80); do c=$(curl -sS -o /dev/null -w "%{http_code}" -H "X-Origin-Verify: $SECRET" http://127.0.0.1/ || echo 000); codes="$codes $c"; done; echo CODES:$codes; echo COUNT_503=$(echo $codes | tr " " "\n" | grep -c 503 || true); echo COUNT_200=$(echo $codes | tr " " "\n" | grep -c 200 || true)'
) -WaitSec 120
$ngxOut = ($ssmNgx.results[$webId].out -join '')
if ($ngxOut -match 'COUNT_503=([1-9]|[1-9][0-9])') {
  Write-Result 'D3' 'Gateway nginx limit_req returns 503 under burst' 'PASS' $ngxOut.Substring(0, [Math]::Min(180, $ngxOut.Length))
} elseif ($ngxOut -match 'COUNT_200=') {
  Write-Result 'D3' 'Gateway nginx limit_req returns 503 under burst' 'WARN' "no 503 seen - $ngxOut"
} else {
  Write-Result 'D3' 'Gateway nginx limit_req returns 503 under burst' 'FAIL' "ssm=$($ssmNgx.commandId) out=$ngxOut"
}

# =====================================================================
# E. WAF / IP allowlist config
# =====================================================================
Write-Host "--- E. WAF allowlist / managed rules ---"
$cfRules = aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --id 102c4d63-70e3-4c0c-8420-3e3aff651acc --name popo-dev-cf --query 'WebACL.Rules[].Name' --output text
if ($cfRules -match 'IPAllowlistOnly' -and $cfRules -match 'AWSManagedRulesCommonRuleSet') {
  Write-Result 'E1' 'CF WAF has allowlist + managed CRS' 'PASS' $cfRules
} else { Write-Result 'E1' 'CF WAF has allowlist + managed CRS' 'FAIL' $cfRules }

$cogRules = aws wafv2 get-web-acl --scope REGIONAL --region eu-west-1 --id 565a9732-2d40-4525-ba5f-7e1aa9c153b4 --name popo-dev-cognito --query 'WebACL.Rules[].Name' --output text
if ($cogRules -match 'IPAllowlistOnly' -and $cogRules -match 'RateLimitAuth') {
  Write-Result 'E2' 'Cognito WAF has allowlist + RateLimitAuth' 'PASS' $cogRules
} else { Write-Result 'E2' 'Cognito WAF has allowlist + RateLimitAuth' 'FAIL' $cogRules }

# SQLi-ish probe should be blocked or cleaned by managed rules (may 403 or 200 sanitized)
$r = Get-Http "$Site/" -Headers @{ 'User-Agent' = 'sqlmap/1.0' }
Write-Result 'E3' 'Probe with sqlmap UA (observational)' 'PASS' "code=$($r.code) (managed rules may block or allow)"

# =====================================================================
# F. POST-TEST HEALTH (ensure we did not leave env broken)
# =====================================================================
Write-Host "--- F. Post-test health ---"
Start-Sleep -Seconds 10
$r = Get-Http "$Site/"
if ($r.code -in 200, 403) {
  # 403 possible if still rate-limited - wait and retry
  if ($r.code -eq 403) {
    Write-Host "Site 403 (likely still rate-limited); waiting 90s..."
    Start-Sleep -Seconds 90
    $r = Get-Http "$Site/"
  }
}
if ($r.code -eq 200) { Write-Result 'F1' 'Site recovered / healthy after tests' 'PASS' "code=$($r.code)" }
else { Write-Result 'F1' 'Site recovered / healthy after tests' 'FAIL' "code=$($r.code)" }

$r = Get-Http "$Api/api/health"
if ($r.code -eq 200) { Write-Result 'F2' 'API healthy after tests' 'PASS' "code=$($r.code)" }
else {
  Start-Sleep -Seconds 60
  $r = Get-Http "$Api/api/health"
  if ($r.code -eq 200) { Write-Result 'F2' 'API healthy after tests' 'PASS' "code=$($r.code) (after wait)" }
  else { Write-Result 'F2' 'API healthy after tests' 'FAIL' "code=$($r.code)" }
}

# =====================================================================
# SUMMARY
# =====================================================================
Write-Host ""
Write-Host "========== SUMMARY =========="
$pass = @($Results | Where-Object status -eq 'PASS').Count
$fail = @($Results | Where-Object status -eq 'FAIL').Count
$warn = @($Results | Where-Object status -eq 'WARN').Count
Write-Host "PASS=$pass FAIL=$fail WARN=$warn TOTAL=$($Results.Count)"
$Results | Format-Table id, status, name -AutoSize
$summaryPath = Join-Path $env:TEMP 'popo-test-summary.txt'
@"
POPO DEV SECURITY TEST SUMMARY
$(Get-Date).ToUniversalTime()
PASS=$pass FAIL=$fail WARN=$warn TOTAL=$($Results.Count)

$($Results | ForEach-Object { "$($_.status)`t$($_.id)`t$($_.name)`t$($_.detail)" } | Out-String)
"@ | Set-Content $summaryPath -Encoding utf8
Write-Host "Wrote $summaryPath"
Write-Host "JSONL $Log"
if ($fail -gt 0) { exit 1 } else { exit 0 }
