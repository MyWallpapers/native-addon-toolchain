[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z')]
  [string]$Repository,

  [Parameter(Mandatory)]
  [ValidatePattern('\A[0-9a-f]{40}\z')]
  [string]$CommitSha,

  [Parameter(Mandatory)]
  [ValidateNotNullOrEmpty()]
  [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-IsolatedGit {
  param([Parameter(Mandatory)][string[]]$Arguments)

  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Isolated Git command failed: git $($Arguments[0])"
  }
}

$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
  throw 'Immutable checkout destination must not already exist'
}
$parent = Split-Path -Parent $destinationPath
if ([string]::IsNullOrWhiteSpace($parent)) {
  throw 'Immutable checkout destination has no parent directory'
}
New-Item -ItemType Directory -Path $parent -Force | Out-Null

$savedEnvironment = @{}
foreach ($name in @('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_TERMINAL_PROMPT')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }

try {
  $env:GIT_CONFIG_GLOBAL = $nullDevice
  $env:GIT_CONFIG_NOSYSTEM = '1'
  $env:GIT_TERMINAL_PROMPT = '0'

  Invoke-IsolatedGit @('init', '--quiet', '--template=', $destinationPath)
  $hooksPath = Join-Path $destinationPath '.git/mywallpaper-disabled-hooks'
  New-Item -ItemType Directory -Path $hooksPath | Out-Null
  Invoke-IsolatedGit @('-C', $destinationPath, 'config', 'core.hooksPath', $hooksPath)
  Invoke-IsolatedGit @(
    '-C', $destinationPath,
    'remote', 'add', 'origin', "https://github.com/$Repository.git"
  )
  Invoke-IsolatedGit @(
    '-C', $destinationPath,
    '-c', 'credential.helper=',
    '-c', 'http.followRedirects=false',
    '-c', 'protocol.version=2',
    'fetch', '--quiet', '--no-tags', '--depth=1', 'origin', $CommitSha
  )
  Invoke-IsolatedGit @(
    '-C', $destinationPath,
    '-c', 'filter.lfs.smudge=',
    '-c', 'filter.lfs.required=false',
    'checkout', '--quiet', '--detach', '--force', 'FETCH_HEAD'
  )
  $actual = (& git -C $destinationPath rev-parse HEAD).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $actual -cne $CommitSha) {
    throw 'Immutable checkout resolved to a different commit'
  }
  $changes = @(& git -C $destinationPath status --porcelain=v1 --untracked-files=no)
  if ($LASTEXITCODE -ne 0 -or $changes.Count -ne 0) {
    throw 'Immutable checkout is not a clean representation of the requested commit'
  }
  Invoke-IsolatedGit @('-C', $destinationPath, 'remote', 'remove', 'origin')
} finally {
  foreach ($name in $savedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
  }
}
