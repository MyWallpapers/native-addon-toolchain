[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ArtifactRoot,
  [Parameter(Mandatory = $true)][string]$Destination
)

$ErrorActionPreference = 'Stop'
$ArtifactRoot = (Resolve-Path -LiteralPath $ArtifactRoot).ProviderPath
$LockPath = Join-Path $ArtifactRoot 'canonical-cli.lock.json'
$Lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
$ExpectedKeys = @('schemaVersion', 'sourceRepository', 'sourceCommit', 'archive', 'size', 'sha256')
$ActualKeys = @($Lock.PSObject.Properties.Name | Sort-Object)
if (($ActualKeys -join "`n") -cne (($ExpectedKeys | Sort-Object) -join "`n")) {
  throw 'canonical-cli.lock.json contains an unexpected field'
}
$LockSize = 0L
$HasLockSize = [long]::TryParse([string]$Lock.size, [ref]$LockSize)
if (
  $Lock.schemaVersion -ne 1 -or
  $Lock.sourceRepository -cne 'MyWallpapers/MyWallpaper' -or
  $Lock.sourceCommit -notmatch '^[0-9a-f]{40}$' -or
  $Lock.archive -cne 'mywallpaper-cli.zip' -or
  -not $HasLockSize -or $LockSize -le 0 -or $LockSize -gt 32MB -or
  $Lock.sha256 -notmatch '^sha256:[0-9a-f]{64}$'
) { throw 'canonical-cli.lock.json is invalid' }

$ArchivePath = Join-Path $ArtifactRoot $Lock.archive
$ArchiveItem = Get-Item -LiteralPath $ArchivePath -Force
if ($ArchiveItem.PSIsContainer -or ($ArchiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'Canonical release validator artifact must be a regular file'
}
if ($ArchiveItem.Length -ne $LockSize) { throw 'Canonical release validator artifact size does not match its lock' }
$ActualDigest = 'sha256:' + (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualDigest -cne [string]$Lock.sha256) { throw 'Canonical release validator artifact digest does not match its lock' }

$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Canonical release validator destination must not already exist' }
New-Item -ItemType Directory -Path $Destination | Out-Null
$DestinationPrefix = $Destination.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$ExpandedBytes = 0L
$ForbiddenValidatorPaths = @(
  '^cli/dist/(?:cli|index|process-supervisor)(?:\..+)?$',
  '^cli/dist/commands/(?:init|dev|dev-preview|doctor(?:-[A-Za-z0-9_-]+)?|hook-builder|hook-watch)(?:\..+)?$'
)

function Assert-CanonicalArtifactSegment([string]$Segment, [string]$Path) {
  $Stem = ($Segment -split '\.', 2)[0].ToUpperInvariant()
  if (
    $Segment.Length -eq 0 -or $Segment.Length -gt 255 -or
    $Segment -in @('.', '..') -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or
    $Segment -notmatch '^[A-Za-z0-9@._-]+$' -or
    $Stem -in @(
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )
  ) { throw "Canonical release validator artifact contains a non-canonical path: $Path" }
}

Add-Type -AssemblyName System.IO.Compression
$Input = [IO.File]::OpenRead($ArchivePath)
try {
  $Archive = [IO.Compression.ZipArchive]::new($Input, [IO.Compression.ZipArchiveMode]::Read, $false)
  try {
    if ($Archive.Entries.Count -eq 0 -or $Archive.Entries.Count -gt 1000) {
      throw 'Canonical release validator artifact has an invalid file count'
    }
    foreach ($Entry in $Archive.Entries) {
      $Path = $Entry.FullName
      if (
        [string]::IsNullOrWhiteSpace($Entry.Name) -or $Path.Contains('\') -or $Path.Contains(':') -or
        [Text.Encoding]::UTF8.GetByteCount($Path) -gt 900
      ) { throw "Canonical release validator artifact contains an invalid path: $Path" }
      foreach ($ForbiddenPattern in $ForbiddenValidatorPaths) {
        if ($Path -match $ForbiddenPattern) {
          throw "Canonical release validator contains a forbidden CLI artifact: $Path"
        }
      }
      foreach ($Segment in $Path.Split('/')) { Assert-CanonicalArtifactSegment $Segment $Path }
      $UnixKind = ($Entry.ExternalAttributes -shr 16) -band 0xF000
      if ($UnixKind -eq 0xA000) { throw "Canonical release validator artifact contains a symbolic link: $Path" }
      if (-not $Seen.Add($Path)) { throw "Canonical release validator artifact contains a duplicate path: $Path" }
      $ExpandedBytes += $Entry.Length
      if ($Entry.Length -gt 24MB -or $ExpandedBytes -gt 32MB) {
        throw 'Canonical release validator artifact exceeds its expanded size limit'
      }
      $Output = [IO.Path]::GetFullPath((Join-Path $Destination $Path.Replace('/', [IO.Path]::DirectorySeparatorChar)))
      if (-not $Output.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Canonical release validator artifact escapes its destination: $Path"
      }
      New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
      $SourceStream = $Entry.Open()
      $OutputStream = [IO.File]::Open($Output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try { $SourceStream.CopyTo($OutputStream) }
      finally { $OutputStream.Dispose(); $SourceStream.Dispose() }
    }
  } finally { $Archive.Dispose() }
} finally { $Input.Dispose() }

foreach ($Required in @(
  'cli/package.json',
  'cli/dist/bin.js',
  'cli/dist/windhawk/build-native-hooks.ps1',
  'cli/dist/windhawk/install-windhawk-toolchain.ps1',
  'cli/dist/windhawk/mywallpaper_windhawk.hpp',
  'cli/dist/windhawk/windhawk-v1.lock.json',
  'cli/node_modules/@mywallpaper/sdk/package.json',
  'cli/node_modules/@mywallpaper/sdk/dist/addon-schema/index.js',
  'cli/node_modules/@mywallpaper/sdk/dist/protocol/index.js',
  'cli/node_modules/@mywallpaper/sdk/dist/generated/addon-manifest-validator.generated.js',
  'cli/node_modules/sharp/package.json',
  'cli/node_modules/@img/sharp-win32-x64/package.json',
  'cli/node_modules/@img/colour/package.json',
  'cli/node_modules/detect-libc/package.json',
  'cli/node_modules/semver/package.json',
  'provenance.json'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $Destination $Required.Replace('/', [IO.Path]::DirectorySeparatorChar)) -PathType Leaf)) {
    throw "Canonical release validator artifact is incomplete: $Required"
  }
}

$ValidatorPackagePath = Join-Path $Destination 'cli/package.json'
$ValidatorPackage = Get-Content -LiteralPath $ValidatorPackagePath -Raw | ConvertFrom-Json
$ValidatorPackageKeys = @($ValidatorPackage.PSObject.Properties.Name | Sort-Object)
if (
  ($ValidatorPackageKeys -join "`n") -cne ((@('name', 'private', 'type') | Sort-Object) -join "`n") -or
  $ValidatorPackage.name -cne '@mywallpaper/release-validator' -or
  $ValidatorPackage.private -ne $true -or
  $ValidatorPackage.type -cne 'module'
) { throw 'Canonical release validator package identity is invalid' }

$ProvenancePath = Join-Path $Destination 'provenance.json'
$Provenance = Get-Content -LiteralPath $ProvenancePath -Raw | ConvertFrom-Json
$ProvenanceKeys = @($Provenance.PSObject.Properties.Name | Sort-Object)
if (($ProvenanceKeys -join "`n") -cne ((@('sourceRepository', 'sourceCommit') | Sort-Object) -join "`n")) {
  throw 'Canonical release validator provenance contains an unexpected field'
}
if (
  $Provenance.sourceRepository -cne $Lock.sourceRepository -or
  $Provenance.sourceCommit -cne $Lock.sourceCommit
) { throw 'Canonical release validator provenance does not match its lock' }

$ExpectedRuntimePackages = [ordered]@{
  '@mywallpaper/sdk' = '0.1.0'
  'sharp' = '0.35.3'
  '@img/sharp-win32-x64' = '0.35.3'
  '@img/colour' = '1.1.0'
  'detect-libc' = '2.1.2'
  'semver' = '7.8.5'
}
foreach ($PackageName in $ExpectedRuntimePackages.Keys) {
  $PackagePath = Join-Path $Destination "cli/node_modules/$PackageName/package.json"
  $Package = Get-Content -LiteralPath $PackagePath -Raw | ConvertFrom-Json
  if ($Package.name -cne $PackageName -or $Package.version -cne $ExpectedRuntimePackages[$PackageName]) {
    throw "Canonical release validator contains an unexpected $PackageName package"
  }
}

Write-Host "Verified canonical release validator from $($Lock.sourceRepository)@$($Lock.sourceCommit)"
