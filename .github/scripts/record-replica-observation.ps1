[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet(1, 2)]
  [int]$Replica,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$WorkflowSha,
  [Parameter(Mandatory = $true)]
  [string]$ToolchainRoot,
  [Parameter(Mandatory = $true)]
  [string]$CanonicalCliRoot,
  [Parameter(Mandatory = $true)]
  [string]$HooksOutputRoot,
  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$ToolchainRoot = (Resolve-Path -LiteralPath $ToolchainRoot).ProviderPath
$CanonicalCliRoot = (Resolve-Path -LiteralPath $CanonicalCliRoot).ProviderPath
$HooksOutputRoot = (Resolve-Path -LiteralPath $HooksOutputRoot).ProviderPath
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

function Get-CleanLine([object]$Value, [string]$Label) {
  $Text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($Text) -or $Text -cne $Text.Trim() -or
      $Text -match '[\x00-\x1f\x7f]') {
    throw "$Label is unavailable or non-canonical"
  }
  return $Text
}

function Get-Sha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Observed executable is missing: $Path"
  }
  return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Executable([string]$Name) {
  $Command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
  return (Resolve-Path -LiteralPath $Command.Source).ProviderPath
}

function Invoke-Version(
  [string]$Path,
  [string[]]$Arguments,
  [string]$Label,
  [int[]]$AcceptedExitCodes = @(0)
) {
  $Lines = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
  $ExitCode = $LASTEXITCODE
  if ($AcceptedExitCodes -notcontains $ExitCode) {
    throw "$Label version command failed with exit code $ExitCode"
  }
  $Text = (($Lines -join "`n") -replace "`r", '').Trim()
  if ([string]::IsNullOrWhiteSpace($Text) -or
      $Text -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
    throw "$Label returned an invalid version observation"
  }
  return $Text
}

function Get-ExecutableObservation(
  [string]$Path,
  [string[]]$Arguments,
  [string]$Label
) {
  return [ordered]@{
    sha256 = Get-Sha256 $Path
    version = Invoke-Version $Path $Arguments $Label
  }
}

foreach ($Variable in @(
  'ImageOS', 'ImageVersion', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
  'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'RUNNER_ARCH', 'RUNNER_TEMP'
)) {
  Get-CleanLine ([Environment]::GetEnvironmentVariable($Variable)) $Variable | Out-Null
}
if ($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:RUNNER_ARCH -cne 'X64') {
  throw 'Replica observation requires the reviewed GitHub-hosted Windows X64 runner contract'
}
if ($env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or
    $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$') {
  throw 'GitHub workflow attempt identity is invalid'
}
if (Test-Path -LiteralPath $OutputPath) { throw 'Replica observation output already exists' }
$OutputParent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $OutputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputParent | Out-Null
}

# These are observations of the hosted runner's default available Rust tools.
# They are deliberately collected from the trusted toolchain checkout rather
# than a caller-controlled directory that could select a different rustup
# override. Committed companion commands and lockfiles remain separate source
# inputs and the two produced byte trees must still be identical.
Push-Location $ToolchainRoot
try {
  $RustcCommand = Get-Executable 'rustc.exe'
  $CargoCommand = Get-Executable 'cargo.exe'
  $RustcVersion = Invoke-Version $RustcCommand @('-vV') 'rustc'
  $CargoVersion = Invoke-Version $CargoCommand @('-Vv') 'cargo'
  $RustSysroot = (Invoke-Version $RustcCommand @('--print', 'sysroot') 'rustc sysroot').Trim()
  $ResolvedRustc = Join-Path $RustSysroot 'bin/rustc.exe'
  $ResolvedCargo = Join-Path $RustSysroot 'bin/cargo.exe'
  if (-not (Test-Path -LiteralPath $ResolvedRustc -PathType Leaf)) { $ResolvedRustc = $RustcCommand }
  if (-not (Test-Path -LiteralPath $ResolvedCargo -PathType Leaf)) { $ResolvedCargo = $CargoCommand }
} finally {
  Pop-Location
}

$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $VsWhere -PathType Leaf)) { throw 'vswhere.exe is unavailable' }
$VsInstallation = (& $VsWhere -latest -products '*' `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  -property installationPath).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($VsInstallation)) {
  throw 'A Visual C++ x64 toolchain is unavailable on the hosted runner'
}
$ToolsetVersionPath = Join-Path $VsInstallation 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
$ToolsetVersion = Get-CleanLine ((Get-Content -LiteralPath $ToolsetVersionPath -Raw).Trim()) 'MSVC toolset version'
if ($ToolsetVersion -cnotmatch '^[0-9]+(?:\.[0-9]+){1,3}$') {
  throw 'MSVC toolset version is invalid'
}
$MsvcLinker = Join-Path $VsInstallation "VC/Tools/MSVC/$ToolsetVersion/bin/Hostx64/x64/link.exe"
$MsvcVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($MsvcLinker)
$MsvcProductVersion = Get-CleanLine $MsvcVersionInfo.ProductVersion 'MSVC linker product version'
$MsvcVersionMatch = [regex]::Match($MsvcProductVersion, '([0-9]+(?:\.[0-9]+){1,3})')
if (-not $MsvcVersionMatch.Success) { throw 'MSVC linker version could not be parsed' }
$MsvcFileVersion = Get-CleanLine `
  $MsvcVersionInfo.FileVersion `
  'MSVC linker file version'

$WindowsKitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$WindowsSdkVersions = @()
$WindowsSdkIncludeRoot = Join-Path $WindowsKitsRoot 'Include'
if (Test-Path -LiteralPath $WindowsSdkIncludeRoot -PathType Container) {
  $WindowsSdkVersions = @(Get-ChildItem -LiteralPath $WindowsSdkIncludeRoot -Directory | ForEach-Object {
    if ($_.Name -cmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'um/Windows.h') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $WindowsKitsRoot "Lib/$($_.Name)/um/x64/Kernel32.Lib") -PathType Leaf)) {
      $_.Name
    }
  })
}
$WindowsSdkVersions = [string[]]@($WindowsSdkVersions | Select-Object -Unique)
[Array]::Sort($WindowsSdkVersions, [StringComparer]::Ordinal)
if ($WindowsSdkVersions.Count -eq 0) { throw 'No complete Windows SDK was observed' }

$WindhawkLockPath = Join-Path $CanonicalCliRoot 'cli/dist/windhawk/windhawk-v1.lock.json'
$WindhawkLock = Get-Content -LiteralPath $WindhawkLockPath -Raw | ConvertFrom-Json
if ($WindhawkLock.schemaVersion -ne 2 -or $WindhawkLock.runtime -cne 'windhawk-v1' -or
    [string]$WindhawkLock.upstream.commit -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$WindhawkLock.toolchainArchive.sha256 -cnotmatch '^[0-9a-f]{64}$') {
  throw 'Canonical Windhawk toolchain lock is invalid'
}
$EmptyHooks = Test-Path -LiteralPath (Join-Path $HooksOutputRoot '.empty') -PathType Leaf
$WindhawkClang = $null
$WindhawkLinker = $null
if (-not $EmptyHooks) {
  $CompilerRoots = @(Get-ChildItem -LiteralPath $env:RUNNER_TEMP -Directory -Filter 'windhawk-v1-*')
  if ($CompilerRoots.Count -ne 1) {
    throw 'Exactly one verified Windhawk toolchain must back a non-empty hook build'
  }
  $MarkerPath = Join-Path $CompilerRoots[0].FullName 'mywallpaper-toolchain.json'
  $Marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
  $ExpectedMarkerFields = @('abi', 'archiveSha256', 'schemaVersion', 'sdkHeaderSha256', 'windhawkCommit')
  $ActualMarkerFields = @($Marker.PSObject.Properties.Name | Sort-Object)
  if (@(Compare-Object $ExpectedMarkerFields $ActualMarkerFields -SyncWindow 0).Count -ne 0 -or
      $Marker.schemaVersion -ne 2 -or $Marker.abi -cne 'windhawk-v1' -or
      $Marker.windhawkCommit -cne [string]$WindhawkLock.upstream.commit -or
      $Marker.archiveSha256 -cne [string]$WindhawkLock.toolchainArchive.sha256) {
    throw 'Observed Windhawk toolchain marker differs from the canonical lock'
  }
  $ClangPath = Join-Path $CompilerRoots[0].FullName 'bin/clang++.exe'
  $LldPath = Join-Path $CompilerRoots[0].FullName 'bin/ld.lld.exe'
  $WindhawkClang = Get-ExecutableObservation $ClangPath @('--version') 'Windhawk clang'
  $WindhawkLinker = Get-ExecutableObservation $LldPath @('--version') 'Windhawk linker'
}

$NodeVersion = Get-CleanLine ((& node --version).Trim()) 'Node.js version'
if ($LASTEXITCODE -ne 0) { throw 'Node.js version could not be observed' }
$PowerShellVersion = Get-CleanLine $PSVersionTable.PSVersion.ToString() 'PowerShell version'
$Observation = [ordered]@{
  schemaVersion = 1
  contract = 'github-hosted-windows-build-observation-v1'
  replica = $Replica
  run = [ordered]@{
    id = [string]$env:GITHUB_RUN_ID
    attempt = [string]$env:GITHUB_RUN_ATTEMPT
  }
  workflowSha = $WorkflowSha
  runner = [ordered]@{
    environment = [string]$env:RUNNER_ENVIRONMENT
    label = 'windows-2025'
    operatingSystem = [string]$env:RUNNER_OS
    architecture = [string]$env:RUNNER_ARCH
    imageOs = [string]$env:ImageOS
    imageVersion = [string]$env:ImageVersion
  }
  tools = [ordered]@{
    node = [ordered]@{ version = $NodeVersion }
    powershell = [ordered]@{ version = $PowerShellVersion }
    rust = [ordered]@{
      rustc = [ordered]@{ sha256 = Get-Sha256 $ResolvedRustc; version = $RustcVersion }
      cargo = [ordered]@{ sha256 = Get-Sha256 $ResolvedCargo; version = $CargoVersion }
    }
    msvc = [ordered]@{
      toolsetVersion = $ToolsetVersion
      linker = [ordered]@{
        sha256 = Get-Sha256 $MsvcLinker
        version = $MsvcVersionMatch.Groups[1].Value
        fileVersion = $MsvcFileVersion
      }
    }
    windowsSdk = [ordered]@{ availableVersions = $WindowsSdkVersions }
    windhawk = [ordered]@{
      used = -not $EmptyHooks
      windhawkCommit = [string]$WindhawkLock.upstream.commit
      archiveSha256 = 'sha256:' + [string]$WindhawkLock.toolchainArchive.sha256
      clang = $WindhawkClang
      linker = $WindhawkLinker
    }
  }
}

$RawPath = "$OutputPath.raw-$([Guid]::NewGuid().ToString('N'))"
try {
  $Observation | ConvertTo-Json -Depth 16 -Compress |
    Set-Content -LiteralPath $RawPath -Encoding utf8NoBOM
  node (Join-Path $ToolchainRoot '.github/scripts/write-runner-observation.mjs') `
    --input $RawPath --output $OutputPath
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw 'Replica runner observation validation failed'
  }
} finally {
  Remove-Item -LiteralPath $RawPath -Force -ErrorAction SilentlyContinue
}
