[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourcePath,
  [Parameter(Mandatory = $true)][ValidateSet('bundle', 'materials')][string]$Kind,
  [Parameter(Mandatory = $true)][string]$ExpectedDigest,
  [Parameter(Mandatory = $true)][long]$ExpectedSize,
  [Parameter(Mandatory = $true)][string]$OutputRoot,
  [Parameter(Mandatory = $true)][long]$PartSizeBytes,
  [Parameter(Mandatory = $true)][int]$OperationalMaxParts
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')

if ($ExpectedDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'ExpectedDigest is invalid' }
if ($ExpectedSize -le 0) { throw 'ExpectedSize must be positive' }
if ($PartSizeBytes -le 0 -or $PartSizeBytes -ge 2147483648L) {
  throw 'PartSizeBytes must be positive and strictly smaller than 2 GiB'
}
if ($OperationalMaxParts -lt 1 -or $OperationalMaxParts -gt 1000) {
  throw 'OperationalMaxParts must be between 1 and GitHub release maximum 1000'
}
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Logical release artifact is missing' }
$source = Get-Item -LiteralPath $SourcePath -Force
if (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'Logical release artifact cannot be a link or reparse point'
}
if ($source.Length -ne $ExpectedSize) { throw 'Logical release artifact size differs from the verified value' }
$partCount = [long][Math]::Floor(($source.Length - 1L) / $PartSizeBytes) + 1L
if ($partCount -gt $OperationalMaxParts) { throw 'Logical release artifact exceeds its operational part budget' }

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must not already exist' }
$partsRoot = Join-Path $OutputRoot 'parts'
$created = $false
try {
  New-Item -ItemType Directory -Path $partsRoot -Force | Out-Null
  $created = $true
  $parts = [Collections.Generic.List[object]]::new()
  $temporaryParts = [Collections.Generic.List[object]]::new()
  $input = [IO.File]::Open($source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $rootHash = [Security.Cryptography.IncrementalHash]::CreateHash(
    [Security.Cryptography.HashAlgorithmName]::SHA256
  )
  try {
    $buffer = [byte[]]::new(1MB)
    for ($index = 0; $index -lt $partCount; $index++) {
      $remainingArtifact = $source.Length - $input.Position
      $targetSize = [Math]::Min($PartSizeBytes, $remainingArtifact)
      $temporaryPath = Join-Path $partsRoot ".part-$index.tmp"
      $output = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      $partHash = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
      )
      $written = 0L
      try {
        while ($written -lt $targetSize) {
          $requested = [int][Math]::Min([long]$buffer.Length, $targetSize - $written)
          $read = $input.Read($buffer, 0, $requested)
          if ($read -le 0) { throw 'Logical release artifact ended while splitting a part' }
          $output.Write($buffer, 0, $read)
          $partHash.AppendData($buffer, 0, $read)
          $rootHash.AppendData($buffer, 0, $read)
          $written += $read
        }
        $output.Flush($true)
        $partHex = [Convert]::ToHexString($partHash.GetHashAndReset()).ToLowerInvariant()
      } finally {
        $partHash.Dispose()
        $output.Dispose()
      }
      $temporaryParts.Add([pscustomobject]@{
        Index = [long]$index
        Path = $temporaryPath
        Size = [long]$written
        Digest = "sha256:$partHex"
      })
    }
    if ($input.Position -ne $source.Length -or $input.ReadByte() -ne -1) {
      throw 'Logical release artifact changed while it was split'
    }
    $rootDigest = 'sha256:' + [Convert]::ToHexString($rootHash.GetHashAndReset()).ToLowerInvariant()
  } finally {
    $rootHash.Dispose()
    $input.Dispose()
  }
  if ($rootDigest -cne $ExpectedDigest) { throw 'Logical release artifact digest differs from the verified value' }
  $rootName = Get-ReleaseArtifactRootName $Kind $rootDigest
  foreach ($part in $temporaryParts) {
    $name = "$rootName.part-$($part.Index)-sha256-$($part.Digest.Substring(7))"
    $destination = Join-Path $partsRoot $name
    Move-Item -LiteralPath $part.Path -Destination $destination
    $parts.Add([ordered]@{
      index = [long]$part.Index
      name = $name
      sizeBytes = [long]$part.Size
      sha256 = [string]$part.Digest
    })
  }
  $manifest = [ordered]@{
    schemaVersion = 1
    artifact = [ordered]@{
      name = $rootName
      sizeBytes = [long]$source.Length
      sha256 = $rootDigest
      parts = $parts
    }
  }
  $manifestPath = Join-Path $OutputRoot 'artifact.json'
  [IO.File]::WriteAllBytes(
    $manifestPath,
    [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress))
  )
  $validated = Read-ReleaseArtifactManifest $manifestPath $Kind $OperationalMaxParts
  if ([string]$validated.Artifact.sha256 -cne $ExpectedDigest) {
    throw 'Canonical release artifact manifest changed the logical root digest'
  }
  [ordered]@{
    manifest = $manifestPath
    partCount = $parts.Count
    rootName = $rootName
    rootDigest = $rootDigest
    rootSizeBytes = $source.Length
  } | ConvertTo-Json -Compress
} catch {
  if ($created) { Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue }
  throw
}
