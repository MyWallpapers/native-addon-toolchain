[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BuildRoot,
  [Parameter(Mandatory = $true)][string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).ProviderPath
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$Destinations = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)

function Test-ContainsPath([string]$Root, [string]$Candidate) {
  $RootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
    $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

if ((Test-ContainsPath $BuildRoot $RepositoryRoot) -or (Test-ContainsPath $RepositoryRoot $BuildRoot)) {
  throw 'Build output and repository must be separate, non-overlapping trees'
}

function Assert-CanonicalSegment([string]$Segment, [string]$Label) {
  $Stem = ($Segment -split '\.', 2)[0].ToUpperInvariant()
  if (
    $Segment.Length -eq 0 -or $Segment.Length -gt 255 -or
    $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or
    $Segment -notmatch '^[A-Za-z0-9._-]+$' -or
    $Stem -in @(
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )
  ) { throw "$Label contains a non-canonical Windows path segment: $Segment" }
}

function Assert-RealDirectory([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label is missing" }
  $Item = Get-Item -LiteralPath $Path -Force
  if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label cannot be a link, junction, or reparse point"
  }
}

function Register-File([string]$Source, [string]$RelativeDestination, [string]$Label) {
  foreach ($Segment in $RelativeDestination.Split('/')) { Assert-CanonicalSegment $Segment $Label }
  if ($RelativeDestination.StartsWith('dist/__mywallpaper/', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Development-only MyWallpaper output cannot enter a release: $RelativeDestination"
  }
  if ($Destinations.ContainsKey($RelativeDestination)) {
    throw "Build outputs collide at $RelativeDestination"
  }
  $Item = Get-Item -LiteralPath $Source -Force
  if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label must contain only regular files: $Source"
  }
  $Destinations.Add($RelativeDestination, $Item.FullName)
}

function Register-Tree([string]$SourceRoot, [string]$DestinationPrefix, [string]$Label, [bool]$Required) {
  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    if ($Required) { throw "$Label is missing" }
    return
  }
  Assert-RealDirectory $SourceRoot $Label
  $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
  $Pending = [Collections.Generic.Stack[string]]::new()
  $Pending.Push($SourceRoot)
  $Count = 0
  while ($Pending.Count -gt 0) {
    $Directory = $Pending.Pop()
    foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force | Sort-Object Name -Descending)) {
      Assert-CanonicalSegment $Item.Name $Label
      if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label contains a link, junction, or reparse point: $($Item.FullName)"
      }
      if ($Item.PSIsContainer) {
        $Pending.Push($Item.FullName)
        continue
      }
      $Relative = $Item.FullName.Substring($SourceRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
      Register-File $Item.FullName "$DestinationPrefix/$Relative" $Label
      $Count++
    }
  }
  if ($Required -and $Count -eq 0) { throw "$Label is empty" }
}

Assert-RealDirectory $BuildRoot 'build output'
$BuildFiles = 0
$BuildBytes = 0L
$PendingBuildDirectories = [Collections.Generic.Stack[string]]::new()
$PendingBuildDirectories.Push($BuildRoot)
while ($PendingBuildDirectories.Count -gt 0) {
  $Directory = $PendingBuildDirectories.Pop()
  foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Build output contains a link, junction, or reparse point: $($Item.FullName)"
    }
    if ($Item.PSIsContainer) {
      $PendingBuildDirectories.Push($Item.FullName)
      continue
    }
    $Relative = $Item.FullName.Substring($BuildRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    $Allowed = $Relative.StartsWith('web/dist/', [StringComparison]::OrdinalIgnoreCase) -or
      $Relative.StartsWith('companion/native/out/', [StringComparison]::OrdinalIgnoreCase) -or
      $Relative.StartsWith('hooks/native/out/', [StringComparison]::OrdinalIgnoreCase) -or
      $Relative -cin @('companion/.empty', 'hooks/.empty')
    if (-not $Allowed) { throw "Build artifact contains an unexpected file: $Relative" }
    $BuildFiles++
    $BuildBytes += $Item.Length
    if ($BuildFiles -gt 1200 -or $BuildBytes -gt 192MB) {
      throw 'Build artifact exceeds the verifier input limit'
    }
  }
}
Register-Tree (Join-Path $BuildRoot 'web/dist') 'dist' 'web build' $true
Register-Tree (Join-Path $BuildRoot 'companion/native/out') 'native/out' 'companion build' $false
Register-Tree (Join-Path $BuildRoot 'hooks/native/out') 'native/out' 'hook build' $false

$AllowedMarkerPaths = @('companion/.empty', 'hooks/.empty')
foreach ($Marker in $AllowedMarkerPaths) {
  $MarkerPath = Join-Path $BuildRoot $Marker.Replace('/', [IO.Path]::DirectorySeparatorChar)
  if (Test-Path -LiteralPath $MarkerPath) {
    $Item = Get-Item -LiteralPath $MarkerPath -Force
    if ($Item.PSIsContainer -or $Item.Length -ne 0 -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Invalid empty output marker: $Marker"
    }
  }
}

foreach ($DerivedPath in @('dist', 'native/out', 'native/generated')) {
  $Target = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $DerivedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
  $Prefix = $RepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $Target.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Derived path escapes repository root: $DerivedPath"
  }
  Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($RelativeDestination in @($Destinations.Keys | Sort-Object)) {
  $Destination = Join-Path $RepositoryRoot $RelativeDestination.Replace('/', [IO.Path]::DirectorySeparatorChar)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
  Copy-Item -LiteralPath $Destinations[$RelativeDestination] -Destination $Destination
}

Write-Host "Materialized $($Destinations.Count) verified build output files"
