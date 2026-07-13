[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Destination,
  [string]$LockPath,
  [string]$SdkHeader
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LockPath)) {
  $LocalLock = Join-Path $PSScriptRoot "windhawk-v1.lock.json"
  $LockPath = if (Test-Path -LiteralPath $LocalLock -PathType Leaf) {
    $LocalLock
  } else {
    Join-Path $PSScriptRoot "../../components/windhawk-host/runtime/windhawk-v1.lock.json"
  }
}
if ([string]::IsNullOrWhiteSpace($SdkHeader)) {
  $LocalSdk = Join-Path $PSScriptRoot "mywallpaper_windhawk.hpp"
  $SdkHeader = if (Test-Path -LiteralPath $LocalSdk -PathType Leaf) {
    $LocalSdk
  } else {
    Join-Path $PSScriptRoot "../../components/windhawk-host/sdk/mywallpaper_windhawk.hpp"
  }
}
$LockPath = (Resolve-Path -LiteralPath $LockPath).ProviderPath
$SdkHeader = (Resolve-Path -LiteralPath $SdkHeader).ProviderPath
$Destination = [IO.Path]::GetFullPath($Destination)
$Lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
if (
  $Lock.schemaVersion -ne 1 -or
  $Lock.runtime -ne "windhawk-v1" -or
  [string]$Lock.upstream.commit -notmatch '^[0-9a-f]{40}$'
) {
  throw "Windhawk toolchain lock is invalid"
}

$TemporaryRoot = Join-Path $env:TEMP "mywallpaper-windhawk-toolchain-$PID"
$CompilerArchive = Join-Path $TemporaryRoot "compiler.7z"
$CompilerExtract = Join-Path $TemporaryRoot "compiler"
$WinrtArchive = Join-Path $TemporaryRoot "winrt.7z"
$WinrtExtract = Join-Path $TemporaryRoot "winrt"
$WindhawkArchive = Join-Path $TemporaryRoot "windhawk.zip"
$WindhawkExtract = Join-Path $TemporaryRoot "windhawk"

function Get-VerifiedFile([object]$Dependency, [string]$Output, [string]$Label) {
  $Url = [string]$Dependency.url
  if ([string]::IsNullOrWhiteSpace($Url)) {
    $Url = [string]$Dependency.archiveUrl
  }
  $Expected = ([string]$Dependency.sha256).ToLowerInvariant()
  if ($Url -notmatch '^https://' -or $Expected -notmatch '^[0-9a-f]{64}$') {
    throw "$Label is not pinned to a valid HTTPS URL and SHA-256"
  }
  curl.exe -L --fail --silent --show-error -o $Output $Url
  if ($LASTEXITCODE -ne 0) {
    throw "$Label download failed with exit code $LASTEXITCODE"
  }
  $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Output).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) {
    throw "$Label SHA-256 mismatch: expected $Expected, got $Actual"
  }
  if ($null -ne $Dependency.size -and (Get-Item -LiteralPath $Output).Length -ne [long]$Dependency.size) {
    throw "$Label size does not match the locked size"
  }
}

function Expand-WithTar([string]$Archive, [string]$Output, [string]$Label) {
  New-Item -ItemType Directory -Path $Output -Force | Out-Null
  tar.exe -xf $Archive -C $Output
  if ($LASTEXITCODE -ne 0) {
    throw "$Label extraction failed with exit code $LASTEXITCODE"
  }
}

Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
try {
  Get-VerifiedFile $Lock.buildDependencies.compiler $CompilerArchive "Windhawk compiler"
  Get-VerifiedFile $Lock.buildDependencies.winrtHeaders $WinrtArchive "Windhawk WinRT headers"
  Get-VerifiedFile $Lock.upstream.sourceArchive $WindhawkArchive "Windhawk source"
  Expand-WithTar $CompilerArchive $CompilerExtract "Windhawk compiler"
  Expand-WithTar $WinrtArchive $WinrtExtract "Windhawk WinRT headers"
  Expand-WithTar $WindhawkArchive $WindhawkExtract "Windhawk source"

  Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  Copy-Item -Path (Join-Path $CompilerExtract "*") -Destination $Destination -Recurse -Force

  $Include = Join-Path $Destination "include"
  New-Item -ItemType Directory -Path $Include -Force | Out-Null
  $WindhawkRoot = Join-Path $WindhawkExtract "windhawk-$($Lock.upstream.commit)"
  $EngineRoot = Join-Path $WindhawkRoot "src/windhawk/engine"
  Copy-Item -LiteralPath (Join-Path $EngineRoot "mods_api.h") -Destination (Join-Path $Include "windhawk_api.h") -Force
  Copy-Item -LiteralPath (Join-Path $EngineRoot "mods_api_internal.h") -Destination (Join-Path $Include "mods_api_internal.h") -Force
  Copy-Item -LiteralPath (Join-Path $EngineRoot "_exports.def") -Destination (Join-Path $Destination "windhawk_exports.def") -Force
  Copy-Item -LiteralPath $SdkHeader -Destination (Join-Path $Include "mywallpaper_windhawk.hpp") -Force
  Get-VerifiedFile $Lock.buildDependencies.windhawkUtils (Join-Path $Include "windhawk_utils.h") "Windhawk utilities header"

  Remove-Item -LiteralPath (Join-Path $Include "winrt") -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path (Join-Path $Include "winrt") -Force | Out-Null
  Copy-Item -Path (Join-Path $WinrtExtract "*") -Destination (Join-Path $Include "winrt") -Recurse -Force

  $FoundationHeader = Join-Path $Include "windows.foundation.h"
  $FoundationText = Get-Content -LiteralPath $FoundationHeader -Raw
  $FoundationText = $FoundationText.Replace(
    "ABI::Windows::Foundation::IReference<boolean >",
    "ABI::Windows::Foundation::IReference<bool >"
  ).Replace(
    "IReference<boolean > : IReference_impl<boolean >",
    "IReference<bool > : IReference_impl<bool >"
  )
  Set-Content -LiteralPath $FoundationHeader -Encoding ASCII -Value $FoundationText

  $Required = @(
    "bin/clang++.exe",
    "bin/ld.lld.exe",
    "include/windhawk_api.h",
    "include/mods_api_internal.h",
    "include/windhawk_utils.h",
    "include/mywallpaper_windhawk.hpp",
    "include/winrt/base.h",
    "include/winrt/Windows.UI.Xaml.h",
    "include/winrt/Windows.UI.Xaml.Hosting.h",
    "windhawk_exports.def",
    "x86_64-w64-mingw32/bin/libc++.dll",
    "x86_64-w64-mingw32/bin/libunwind.dll"
  )
  foreach ($RelativePath in $Required) {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $RelativePath) -PathType Leaf)) {
      throw "Verified Windhawk toolchain is missing $RelativePath"
    }
  }
  @{
    schemaVersion = 1
    abi = "windhawk-v1"
    windhawkCommit = [string]$Lock.upstream.commit
    lockSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $LockPath).Hash.ToLowerInvariant()
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination "mywallpaper-toolchain.json") -Encoding UTF8
} finally {
  Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Installed verified Windhawk toolchain at $Destination"
