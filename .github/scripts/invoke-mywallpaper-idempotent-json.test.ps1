Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Get-Location).Path
} else { $PSScriptRoot }
$helperPath = Join-Path $scriptDirectory 'invoke-mywallpaper-idempotent-json.ps1'
if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  . ([scriptblock]::Create((Get-Content -LiteralPath $helperPath -Raw)))
} else {
  . $helperPath
}

$env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.invalid/oidc?job=publisher'
$env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-token'
$script:sleeps = @()
function Start-Sleep {
  param([int]$Seconds)
  if ($Seconds -lt 1 -or $Seconds -gt 30) {
    throw 'Retry delay escaped the reviewed bound'
  }
  $script:sleeps += $Seconds
}

function New-TestHttpResponseHeaders([string]$retryAfter) {
  $response = [System.Net.Http.HttpResponseMessage]::new()
  if (-not $response.Headers.TryAddWithoutValidation('Retry-After', $retryAfter)) {
    throw 'Could not create typed Retry-After test headers'
  }
  return ,$response.Headers
}

$script:tokenCount = 0
function Invoke-RestMethod {
  param(
    [string]$Method,
    [hashtable]$Headers,
    [string]$Uri,
    [int]$MaximumRedirection,
    [int]$TimeoutSec
  )
  if ($Method -cne 'Get' -or $MaximumRedirection -ne 0 -or $TimeoutSec -ne 20 -or
      $Headers.Authorization -cne 'Bearer runner-token' -or
      $Uri -cne 'https://token.actions.invalid/oidc?job=publisher&audience=test-audience') {
    throw 'OIDC request escaped the reviewed contract'
  }
  $script:tokenCount += 1
  return [pscustomobject]@{ value = "fresh-token-$script:tokenCount" }
}

$headers = @{
  'Idempotency-Key' = 'stable-test-key'
  'X-Request-ID' = 'stable-test-key'
}
$body = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1}')
$script:callCount = 0
$script:observedHeaders = @()
$script:observedBodies = @()
function Invoke-WebRequest {
  param(
    [string]$Method,
    [string]$Uri,
    [int]$MaximumRedirection,
    [int]$TimeoutSec,
    [hashtable]$Headers,
    [string]$ContentType,
    [byte[]]$Body,
    [switch]$UseBasicParsing
  )
  if ($Method -cne 'Post' -or $MaximumRedirection -ne 0 -or
      $TimeoutSec -ne 20 -or $ContentType -cne 'application/json' -or
      -not $UseBasicParsing) {
    throw 'HTTP request escaped the reviewed callback contract'
  }
  $script:callCount += 1
  $script:observedHeaders += ,$Headers
  $script:observedBodies += ,$Body
  if ($script:callCount -eq 1) {
    return [pscustomobject]@{
      StatusCode = 202
      Headers = New-TestHttpResponseHeaders '5'
      Content = '{"publicationRequestId":"00000000-0000-4000-8000-000000000001","state":"queued"}'
    }
  }
  if ($script:callCount -eq 2) {
    return [pscustomobject]@{
      StatusCode = 202
      Headers = @{ 'Retry-After' = '5' }
      Content = '{"publicationRequestId":"00000000-0000-4000-8000-000000000001","state":"processing"}'
    }
  }
  return [pscustomobject]@{
    StatusCode = 201
    Headers = @{}
    Content = '{"state":"available"}'
  }
}

$result = Invoke-MyWallpaperIdempotentJsonPost `
  -Uri 'https://example.invalid/idempotent' `
  -Headers $headers `
  -Body $body `
  -Operation 'test callback' `
  -Audience 'test-audience' `
  -PendingStates @('queued', 'processing') `
  -PendingPublicationRequestId '00000000-0000-4000-8000-000000000001'
if ($result.state -cne 'available' -or $script:callCount -ne 3 -or
    $script:tokenCount -ne 3 -or ($script:sleeps -join ',') -cne '5,5') {
  throw 'Durable enqueue and polling did not reach the canonical result'
}
if ($headers.ContainsKey('Authorization')) {
  throw 'The caller headers were mutated with a bearer token'
}
for ($index = 0; $index -lt $script:observedHeaders.Count; $index++) {
  $observed = $script:observedHeaders[$index]
  if ($observed.Authorization -cne "Bearer fresh-token-$($index + 1)" -or
      $observed['Idempotency-Key'] -cne 'stable-test-key' -or
      $observed['X-Request-ID'] -cne 'stable-test-key') {
    throw 'A poll did not bind one fresh OIDC token to the exact operation'
  }
}
foreach ($observed in $script:observedBodies) {
  if (-not [object]::ReferenceEquals($observed, $body)) {
    throw 'A retry changed the callback body bytes'
  }
}

$script:callCount = 0
$script:tokenCount = 0
$script:sleeps = @()
function Invoke-WebRequest {
  $script:callCount += 1
  return [pscustomobject]@{
    StatusCode = 202
    Headers = @{}
    Content = '{"publicationRequestId":"00000000-0000-4000-8000-000000000002","state":"queued"}'
  }
}
$mismatchedPendingRejected = $false
try {
  Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/mismatched-pending' `
    -Headers $headers `
    -Body $body `
    -Operation 'mismatched pending callback' `
    -Audience 'test-audience' `
    -PendingStates @('queued', 'processing') `
    -PendingPublicationRequestId '00000000-0000-4000-8000-000000000001' | Out-Null
} catch {
  if ($_.Exception.Message.IndexOf(
      'unexpected HTTP status 202',
      [StringComparison]::Ordinal
    ) -lt 0) {
    throw
  }
  $mismatchedPendingRejected = $true
}
if (-not $mismatchedPendingRejected -or $script:callCount -ne 1 -or
    $script:tokenCount -ne 1 -or $script:sleeps.Count -ne 0) {
  throw 'A pending response from a different publication request was accepted or retried'
}

foreach ($transientStatus in @(408, 425, 429, 503)) {
  $script:callCount = 0
  $script:tokenCount = 0
  $script:sleeps = @()
  $script:transientStatus = $transientStatus
  function Invoke-WebRequest {
    param(
      [string]$Method,
      [string]$Uri,
      [int]$MaximumRedirection,
      [int]$TimeoutSec,
      [hashtable]$Headers,
      [string]$ContentType,
      [byte[]]$Body,
      [switch]$UseBasicParsing
    )
    $script:callCount += 1
    if ($script:callCount -eq 1) {
      $exception = [InvalidOperationException]::new('simulated transient response')
      $errorResponse = [System.Net.Http.HttpResponseMessage]::new(
        [System.Enum]::ToObject(
          [System.Net.HttpStatusCode],
          $script:transientStatus
        )
      )
      if (-not $errorResponse.Headers.TryAddWithoutValidation('Retry-After', '7')) {
        throw 'Could not create typed transient Retry-After test headers'
      }
      $exception | Add-Member -NotePropertyName Response -NotePropertyValue $errorResponse
      throw $exception
    }
    return [pscustomobject]@{
      StatusCode = 200
      Headers = @{}
      Content = '{"state":"available"}'
    }
  }
  $result = Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/transient' `
    -Headers $headers `
    -Body $body `
    -Operation "transient $transientStatus callback" `
    -Audience 'test-audience'
  if ($result.state -cne 'available' -or $script:callCount -ne 2 -or
      $script:tokenCount -ne 2 -or ($script:sleeps -join ',') -cne '7') {
    throw "HTTP $transientStatus did not retry once with Retry-After and a fresh token"
  }
}

$script:callCount = 0
$script:tokenCount = 0
$script:sleeps = @()
function Invoke-WebRequest {
  param(
    [string]$Method,
    [string]$Uri,
    [int]$MaximumRedirection,
    [int]$TimeoutSec,
    [hashtable]$Headers,
    [string]$ContentType,
    [byte[]]$Body,
    [switch]$UseBasicParsing
  )
  $script:callCount += 1
  return [pscustomobject]@{
    StatusCode = 202
    Headers = @{ 'Retry-After' = '1' }
    Content = '{"publicationRequestId":"00000000-0000-4000-8000-000000000001","state":"processing"}'
  }
}
$exhausted = $false
try {
  Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/exhausted' `
    -Headers $headers `
    -Body $body `
    -Operation 'exhausted callback' `
    -Audience 'test-audience' `
    -PendingStates @('queued', 'processing') `
    -PendingPublicationRequestId '00000000-0000-4000-8000-000000000001' `
    -MaxAttempts 2 | Out-Null
} catch {
  if ($_.Exception.Message.IndexOf(
      'bounded retry horizon',
      [StringComparison]::Ordinal
    ) -lt 0) {
    throw
  }
  $exhausted = $true
}
if (-not $exhausted -or $script:callCount -ne 2 -or $script:tokenCount -ne 2 -or
    ($script:sleeps -join ',') -cne '1') {
  throw 'A perpetually pending operation escaped its bounded polling budget'
}

$script:callCount = 0
$script:tokenCount = 0
function Invoke-WebRequest {
  $script:callCount += 1
  throw [InvalidOperationException]::new('permanent rejection')
}
$rejected = $false
try {
  Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/permanent' `
    -Headers $headers `
    -Body $body `
    -Operation 'permanent callback' `
    -Audience 'test-audience' | Out-Null
} catch {
  if ($_.Exception.Message.IndexOf(
      'permanent rejection',
      [StringComparison]::Ordinal
    ) -lt 0) {
    throw
  }
  $rejected = $true
}
if (-not $rejected -or $script:callCount -ne 1 -or $script:tokenCount -ne 1) {
  throw 'A permanent failure was retried'
}

$missingKeyRejected = $false
try {
  Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/no-key' `
    -Headers @{} `
    -Body $body `
    -Operation 'unkeyed callback' `
    -Audience 'test-audience' | Out-Null
} catch {
  if ($_.Exception.Message.IndexOf(
      'stable idempotency key',
      [StringComparison]::Ordinal
    ) -lt 0) {
    throw
  }
  $missingKeyRejected = $true
}
if (-not $missingKeyRejected) {
  throw 'An unkeyed callback was accepted'
}

$staleTokenRejected = $false
try {
  Invoke-MyWallpaperIdempotentJsonPost `
    -Uri 'https://example.invalid/stale-token' `
    -Headers @{
      Authorization = 'Bearer stale-token'
      'Idempotency-Key' = 'stable-test-key'
    } `
    -Body $body `
    -Operation 'stale-token callback' `
    -Audience 'test-audience' | Out-Null
} catch {
  if ($_.Exception.Message.IndexOf(
      'fresh GitHub OIDC token',
      [StringComparison]::Ordinal
    ) -lt 0) {
    throw
  }
  $staleTokenRejected = $true
}
if (-not $staleTokenRejected) {
  throw 'Caller-provided reusable bearer token was accepted'
}
