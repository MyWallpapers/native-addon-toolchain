[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TransportRoot,
  [Parameter(Mandatory = $true)][ValidateSet('bundle', 'materials')][string]$Kind,
  [Parameter(Mandatory = $true)][string]$ExpectedDigest,
  [Parameter(Mandatory = $true)][long]$ExpectedSize,
  [Parameter(Mandatory = $true)][int]$OperationalMaxParts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')

if ($ExpectedDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'ExpectedDigest is invalid' }
if ($ExpectedSize -le 0) { throw 'ExpectedSize must be positive' }
$TransportRoot = (Resolve-Path -LiteralPath $TransportRoot).ProviderPath
$rootItem = Get-Item -LiteralPath $TransportRoot -Force
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'TransportRoot must be a regular directory without links'
}
$manifestPath = Join-Path $TransportRoot 'artifact.json'
$partsRoot = Join-Path $TransportRoot 'parts'
$topLevel = @(Get-ChildItem -LiteralPath $TransportRoot -Force)
if ($topLevel.Count -ne 2 -or
    -not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $partsRoot -PathType Container)) {
  throw 'Release artifact transport must contain only artifact.json and parts'
}
$partsRootItem = Get-Item -LiteralPath $partsRoot -Force
if (($partsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'Release artifact parts directory cannot be a link or reparse point'
}
$validated = Read-ReleaseArtifactManifest $manifestPath $Kind $OperationalMaxParts
$artifact = $validated.Artifact
if ([string]$artifact.sha256 -cne $ExpectedDigest -or [long]$artifact.sizeBytes -ne $ExpectedSize) {
  throw 'Release artifact root differs from the verified logical archive'
}
$files = @(Get-ChildItem -LiteralPath $partsRoot -Force)
if ($files.Count -ne @($artifact.parts).Count -or @($files | Where-Object { $_.PSIsContainer }).Count -ne 0) {
  throw 'Release artifact parts directory has an unexpected entry count or directory'
}
$byName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($file in $files) {
  if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      -not (Test-Path -LiteralPath $file.FullName -PathType Leaf) -or
      $byName.ContainsKey($file.Name)) {
    throw 'Release artifact transport contains an invalid or duplicate part file'
  }
  $byName.Add($file.Name, $file)
}
$rootHash = [Security.Cryptography.IncrementalHash]::CreateHash(
  [Security.Cryptography.HashAlgorithmName]::SHA256
)
$total = 0L
try {
  $buffer = [byte[]]::new(1MB)
  foreach ($part in @($artifact.parts)) {
    $name = [string]$part.name
    if (-not $byName.ContainsKey($name)) { throw "Release artifact part file is missing: $name" }
    $file = $byName[$name]
    if ($file.Length -ne [long]$part.sizeBytes) { throw "Release artifact part size changed: $name" }
    if ($total -gt ([long]::MaxValue - $file.Length)) { throw 'Release artifact size overflows Int64' }
    $total += $file.Length
    $partHash = [Security.Cryptography.IncrementalHash]::CreateHash(
      [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $partHash.AppendData($buffer, 0, $read)
        $rootHash.AppendData($buffer, 0, $read)
      }
      $partDigest = 'sha256:' + [Convert]::ToHexString($partHash.GetHashAndReset()).ToLowerInvariant()
    } finally {
      $stream.Dispose()
      $partHash.Dispose()
    }
    if ($partDigest -cne [string]$part.sha256) { throw "Release artifact part digest changed: $name" }
  }
  $rootDigest = 'sha256:' + [Convert]::ToHexString($rootHash.GetHashAndReset()).ToLowerInvariant()
} finally {
  $rootHash.Dispose()
}
if ($total -ne $ExpectedSize -or $rootDigest -cne $ExpectedDigest) {
  throw 'Concatenated release artifact parts do not reproduce the logical root'
}
[ordered]@{
  manifest = $manifestPath
  partCount = @($artifact.parts).Count
  rootName = $artifact.name
  rootDigest = $rootDigest
  rootSizeBytes = $total
} | ConvertTo-Json -Compress
