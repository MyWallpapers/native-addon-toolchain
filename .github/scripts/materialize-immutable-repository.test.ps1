param(
  [Parameter(Mandatory)]
  [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z')]
  [string]$Repository,

  [Parameter(Mandatory)]
  [ValidatePattern('\A[0-9a-f]{40}\z')]
  [string]$CommitSha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-immutable-checkout-$([Guid]::NewGuid().ToString('N'))"
try {
  $destination = Join-Path $root 'source'
  & "$PSScriptRoot/materialize-immutable-repository.ps1" `
    -Repository $Repository `
    -CommitSha $CommitSha `
    -Destination $destination

  $actual = (& git -C $destination rev-parse HEAD).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $actual -cne $CommitSha) {
    throw 'Immutable checkout integration test resolved the wrong commit'
  }
  $remoteNames = @(& git -C $destination remote)
  if ($LASTEXITCODE -ne 0 -or $remoteNames.Count -ne 1 -or $remoteNames[0] -cne 'origin') {
    throw 'Immutable checkout retained an unexpected Git remote'
  }
  $expectedOrigin = "https://github.com/$Repository.git"
  $originUrls = @(& git -C $destination remote get-url --all origin)
  if ($LASTEXITCODE -ne 0 -or $originUrls.Count -ne 1 -or $originUrls[0] -cne $expectedOrigin) {
    throw 'Immutable checkout did not retain the credential-free canonical public origin'
  }
  $pushUrls = @(& git -C $destination remote get-url --push --all origin)
  if ($LASTEXITCODE -ne 0 -or $pushUrls.Count -ne 1 -or $pushUrls[0] -cne $expectedOrigin) {
    throw 'Immutable checkout retained a non-canonical push URL'
  }
  $credentialHelpers = @(& git -C $destination config --local --get-all credential.helper)
  if ($LASTEXITCODE -eq 0 -and $credentialHelpers.Count -ne 0) {
    throw 'Immutable checkout retained a local credential helper'
  }

  $existingWasRejected = $false
  try {
    & "$PSScriptRoot/materialize-immutable-repository.ps1" `
      -Repository $Repository `
      -CommitSha $CommitSha `
      -Destination $destination
  } catch {
    if (-not $_.Exception.Message.Contains('must not already exist', [StringComparison]::Ordinal)) {
      throw
    }
    $existingWasRejected = $true
  }
  if (-not $existingWasRejected) { throw 'An existing checkout destination was accepted' }
} finally {
  if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

Write-Output 'immutable credential-free checkout and public provenance contract is intact'
