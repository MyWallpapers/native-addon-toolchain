function Get-MyWallpaperRetryAfterSeconds {
  [CmdletBinding()]
  param(
    [AllowNull()][object]$Headers,
    [Parameter(Mandatory)][ValidateRange(1, 60)][int]$DefaultSeconds,
    [Parameter(Mandatory)][ValidateRange(1, 60)][int]$MaximumSeconds
  )

  if ($null -eq $Headers) {
    return $DefaultSeconds
  }

  $typedRetryAfter = $Headers.PSObject.Properties['RetryAfter']
  if ($null -ne $typedRetryAfter -and $null -ne $typedRetryAfter.Value) {
    $value = $typedRetryAfter.Value
    if ($null -ne $value.Delta) {
      return [int][Math]::Min(
        $MaximumSeconds,
        [Math]::Max(1, [Math]::Ceiling($value.Delta.TotalSeconds))
      )
    }
    if ($null -ne $value.Date) {
      return [int][Math]::Min(
        $MaximumSeconds,
        [Math]::Max(
          1,
          [Math]::Ceiling(($value.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
        )
      )
    }
  }

  $rawValues = @()
  try {
    foreach ($entry in $Headers.GetEnumerator()) {
      if ([string]::Equals(
          [string]$entry.Key,
          'Retry-After',
          [StringComparison]::OrdinalIgnoreCase
        )) {
        $rawValues = @($entry.Value)
        break
      }
    }
  } catch {
    return $DefaultSeconds
  }
  if ($rawValues.Count -eq 0) {
    return $DefaultSeconds
  }

  $seconds = 0
  if ([int]::TryParse([string]$rawValues[0], [ref]$seconds)) {
    return [int][Math]::Min($MaximumSeconds, [Math]::Max(1, $seconds))
  }
  $date = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse(
      [string]$rawValues[0],
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal,
      [ref]$date
    )) {
    return [int][Math]::Min(
      $MaximumSeconds,
      [Math]::Max(
        1,
        [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds)
      )
    )
  }
  return $DefaultSeconds
}

function Invoke-MyWallpaperIdempotentJsonPost {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
    [Parameter(Mandatory)][ValidateNotNull()][hashtable]$Headers,
    [Parameter(Mandatory)][ValidateNotNull()][byte[]]$Body,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Audience,
    [ValidateNotNull()][string[]]$PendingStates = @(),
    [ValidateRange(1, 60)][int]$PendingDelaySec = 5,
    [ValidateRange(1, 120)][int]$TimeoutSec = 20,
    [ValidateRange(1, 3600)][int]$RetryHorizonSec = 120,
    [ValidateRange(1, 512)][int]$MaxAttempts = 6,
    [AllowEmptyString()][string]$PendingPublicationRequestId = ''
  )

  Set-StrictMode -Version Latest

  $idempotencyKey = [string]$Headers['Idempotency-Key']
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) {
    throw "$Operation requires one stable idempotency key"
  }
  if ($Headers.ContainsKey('Authorization')) {
    throw "$Operation must mint a fresh GitHub OIDC token for every request"
  }
  if ($PendingStates.Count -gt 0 -and
      $PendingPublicationRequestId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw "$Operation requires the canonical publication request identity while polling"
  }
  if ([string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -or
      [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)) {
    throw "$Operation requires GitHub's OIDC request environment"
  }
  $tokenEndpoint = $null
  if (-not [Uri]::TryCreate(
      $env:ACTIONS_ID_TOKEN_REQUEST_URL,
      [UriKind]::Absolute,
      [ref]$tokenEndpoint
    ) -or $tokenEndpoint.Scheme -cne 'https') {
    throw "$Operation requires an HTTPS GitHub OIDC request endpoint"
  }

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($RetryHorizonSec)
  for ($attempt = 0; $attempt -lt $MaxAttempts; $attempt++) {
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
      break
    }
    $httpResponse = $null
    try {
      $encodedAudience = [Uri]::EscapeDataString($Audience)
      $separator = if ($env:ACTIONS_ID_TOKEN_REQUEST_URL.Contains('?')) { '&' } else { '?' }
      $tokenUri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)$($separator)audience=$encodedAudience"
      if (-not $tokenUri.EndsWith(
          "$($separator)audience=$encodedAudience",
          [StringComparison]::Ordinal
        )) {
        throw 'GitHub OIDC audience query construction failed'
      }
      $tokenResponse = Invoke-RestMethod `
        -Method Get `
        -Headers @{ Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" } `
        -Uri $tokenUri `
        -MaximumRedirection 0 `
        -TimeoutSec 20
      if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.value)) {
        throw 'GitHub did not issue an OIDC token'
      }

      $requestHeaders = @{}
      foreach ($entry in $Headers.GetEnumerator()) {
        $requestHeaders[$entry.Key] = $entry.Value
      }
      $requestHeaders['Authorization'] = "Bearer $($tokenResponse.value)"
      $httpResponse = Invoke-WebRequest `
        -Method Post `
        -Uri $Uri `
        -MaximumRedirection 0 `
        -TimeoutSec $TimeoutSec `
        -Headers $requestHeaders `
        -ContentType 'application/json' `
        -Body $Body `
        -UseBasicParsing
      $status = [int]$httpResponse.StatusCode
      $response = try {
        $httpResponse.Content | ConvertFrom-Json
      } catch {
        throw "$Operation returned invalid JSON"
      }
      if ($status -eq 200 -or $status -eq 201) {
        return $response
      }
      $responseKeys = @($response.PSObject.Properties.Name | Sort-Object)
      $expectedPendingKeys = @('publicationRequestId', 'state') | Sort-Object
      if ($status -ne 202 -or
          $PendingStates.Count -eq 0 -or
          ($responseKeys -join "`n") -cne ($expectedPendingKeys -join "`n") -or
          [string]$response.publicationRequestId -cne $PendingPublicationRequestId -or
          [string]$response.state -cnotin $PendingStates) {
        throw "$Operation returned unexpected HTTP status $status"
      }

      $delaySeconds = Get-MyWallpaperRetryAfterSeconds `
        -Headers $httpResponse.Headers `
        -DefaultSeconds $PendingDelaySec `
        -MaximumSeconds 30
      if ($attempt + 1 -ge $MaxAttempts -or
          [DateTimeOffset]::UtcNow.AddSeconds($delaySeconds) -ge $deadline) {
        break
      }
      Start-Sleep -Seconds $delaySeconds
      continue
    } catch {
      $responseProperty = $_.Exception.PSObject.Properties['Response']
      $errorResponse = if ($null -ne $responseProperty) {
        $responseProperty.Value
      } else { $null }
      $status = if ($null -ne $errorResponse -and $null -ne $errorResponse.StatusCode) {
        [int]$errorResponse.StatusCode
      } else { 0 }
      $transportFailure = $false
      $exception = $_.Exception
      while ($null -ne $exception) {
        $exceptionType = $exception.GetType().FullName
        if ($exception -is [TimeoutException] -or
            $exception -is [System.Threading.Tasks.TaskCanceledException] -or
            $exceptionType -ceq 'System.Net.Http.HttpRequestException' -or
            $exception -is [System.Net.WebException] -or
            $exception -is [System.IO.IOException] -or
            $exception -is [System.Net.Sockets.SocketException]) {
          $transportFailure = $true
          break
        }
        $exception = $exception.InnerException
      }
      $retryable = $status -eq 408 -or
        $status -eq 425 -or
        $status -eq 429 -or
        ($status -ge 500 -and $status -le 599) -or
        ($status -eq 0 -and $transportFailure)
      if ($retryable -and $attempt + 1 -lt $MaxAttempts) {
        $delaySeconds = [int][Math]::Min(16, [Math]::Pow(2, $attempt))
        $headersProperty = if ($null -ne $errorResponse) {
          $errorResponse.PSObject.Properties['Headers']
        } else { $null }
        $responseHeaders = $null
        if ($null -ne $headersProperty -and
            $null -ne $headersProperty.Value) {
          # Assign outside an expression pipeline so HttpResponseHeaders is not
          # unrolled into its first KeyValuePair by PowerShell.
          $responseHeaders = $headersProperty.Value
        }
        $delaySeconds = Get-MyWallpaperRetryAfterSeconds `
          -Headers $responseHeaders `
          -DefaultSeconds $delaySeconds `
          -MaximumSeconds 16
        if ([DateTimeOffset]::UtcNow.AddSeconds($delaySeconds) -ge $deadline) {
          break
        }
        Start-Sleep -Seconds $delaySeconds
        continue
      }
      $errorDetailsProperty = $_.PSObject.Properties['ErrorDetails']
      $errorDetails = if ($null -ne $errorDetailsProperty) {
        $errorDetailsProperty.Value
      } else { $null }
      $errorMessageProperty = if ($null -ne $errorDetails) {
        $errorDetails.PSObject.Properties['Message']
      } else { $null }
      $errorMessage = if ($null -ne $errorMessageProperty) {
        [string]$errorMessageProperty.Value
      } else { '' }
      $detail = if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $_.Exception.Message
      } else { $errorMessage }
      throw "$Operation failed: $detail"
    }
  }

  throw "$Operation exhausted its bounded retry horizon"
}
