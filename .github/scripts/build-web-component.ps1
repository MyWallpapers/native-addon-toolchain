[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepositoryRoot,
  [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'Web output must be a fresh directory' }
$Manifest = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'manifest.json') -Raw | ConvertFrom-Json
$HasWeb = -not [string]::IsNullOrWhiteSpace([string]$Manifest.entry) -or
  -not [string]::IsNullOrWhiteSpace([string]$Manifest.services.entry)
New-Item -ItemType Directory -Path "$OutputRoot/web" -Force | Out-Null
if (-not $HasWeb) {
  if ($Manifest.runtime -cne 'native-v1') { throw 'Only native-v1 may omit all Web entry points' }
  New-Item -ItemType File -Path "$OutputRoot/web/.empty" | Out-Null
  return
}
Push-Location $RepositoryRoot
try {
  corepack enable pnpm
  if ($LASTEXITCODE -ne 0) { throw 'Could not enable the pinned pnpm package manager' }
  pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) { throw 'The frozen JavaScript dependency install failed' }
  pnpm run --if-present typecheck
  if ($LASTEXITCODE -ne 0) { throw 'Add-on typecheck failed' }
  pnpm build
  if ($LASTEXITCODE -ne 0) { throw 'Add-on web build failed' }
  pnpm run --if-present test
  if ($LASTEXITCODE -ne 0) { throw 'Add-on test suite failed' }
} finally { Pop-Location }
Copy-Item -LiteralPath "$RepositoryRoot/dist" -Destination "$OutputRoot/web/dist" -Recurse
