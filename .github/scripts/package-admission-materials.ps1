[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$EvidenceRoot,
  [Parameter(Mandatory = $true)][string]$OutputArchive,
  [Parameter(Mandatory = $true)][long]$OperationalMaxFiles,
  [Parameter(Mandatory = $true)][long]$OperationalMaxExpandedBytes,
  [Parameter(Mandatory = $true)][long]$OperationalMaxArchiveBytes
)

$ErrorActionPreference = 'Stop'
if ($OperationalMaxFiles -le 0) { throw 'OperationalMaxFiles must be positive' }
if ($OperationalMaxExpandedBytes -le 0) { throw 'OperationalMaxExpandedBytes must be positive' }
if ($OperationalMaxArchiveBytes -le 0) { throw 'OperationalMaxArchiveBytes must be positive' }

function Add-CheckedInt64([long]$Current, [long]$Increment, [string]$Label) {
  if ($Increment -lt 0 -or $Current -gt ([long]::MaxValue - $Increment)) {
    throw "$Label byte count overflows Int64"
  }
  return [long]($Current + $Increment)
}

function Assert-PortablePath([string]$Path) {
  if ([Text.Encoding]::UTF8.GetByteCount($Path) -gt 900 -or $Path.Contains('\') -or $Path.Contains(':')) {
    throw "Admission evidence path is not portable: $Path"
  }
  foreach ($segment in $Path.Split('/')) {
    if (
      $segment.Length -eq 0 -or $segment.Length -gt 255 -or
      $segment -in @('.', '..') -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
      $segment -notmatch '^[A-Za-z0-9._-]+$'
    ) { throw "Admission evidence path is not canonical: $Path" }
  }
}

$EvidenceRoot = (Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath
$RootItem = Get-Item -LiteralPath $EvidenceRoot -Force
if (-not $RootItem.PSIsContainer -or ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'EvidenceRoot must be a regular directory without links'
}
$OutputArchive = [IO.Path]::GetFullPath($OutputArchive)
$rootPrefix = $EvidenceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($OutputArchive.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'OutputArchive must be outside EvidenceRoot'
}

$files = [Collections.Generic.List[object]]::new()
$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($EvidenceRoot)
$expandedBytes = 0L
while ($pending.Count -gt 0) {
  $directory = $pending.Pop()
  foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name -Descending)) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Admission evidence contains a link or reparse point: $($item.FullName)"
    }
    if ($item.PSIsContainer) {
      $pending.Push($item.FullName)
      continue
    }
    if (-not (Test-Path -LiteralPath $item.FullName -PathType Leaf)) {
      throw "Admission evidence contains a non-regular file: $($item.FullName)"
    }
    $relative = $item.FullName.Substring($EvidenceRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    Assert-PortablePath $relative
    if ([long]$files.Count -ge $OperationalMaxFiles) {
      throw 'Admission evidence exhausted the runner operational file budget'
    }
    $expandedBytes = Add-CheckedInt64 $expandedBytes $item.Length 'Admission evidence'
    if ($expandedBytes -gt $OperationalMaxExpandedBytes) {
      throw 'Admission evidence exhausted the runner operational expanded-byte budget'
    }
    $files.Add([pscustomobject]@{ Path = $relative; Source = $item.FullName })
  }
}
if ($files.Count -eq 0) { throw 'Admission evidence must not be empty' }
$paths = [string[]]@($files.Path)
[Array]::Sort($paths, [StringComparer]::Ordinal)
$byPath = @{}
foreach ($file in $files) { $byPath[$file.Path] = $file.Source }

$required = @(
  'admission-subject-v1.json',
  'author-inventory.json',
  'bundle-index.json',
  'environment.json',
  'lockfiles.json',
  'payload-inventory.json',
  'provenance.intoto.json',
  'replica-inventories.json',
  'sbom.cdx.json',
  'source-git-tree.txt'
)
foreach ($path in $required) {
  if (-not $byPath.ContainsKey($path)) { throw "Admission evidence is missing $path" }
}
if ($files.Count -ne $required.Count) {
  throw 'Admission evidence contains files outside the versioned materials contract'
}

$outputDirectory = Split-Path -Parent $OutputArchive
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($OutputArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$packagingSucceeded = $false
try {
  $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    foreach ($path in $paths) {
      $entry = $archive.CreateEntry($path, [IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $input = [IO.File]::OpenRead([string]$byPath[$path])
      $output = $entry.Open()
      try { $input.CopyTo($output) }
      finally { $output.Dispose(); $input.Dispose() }
      if ($stream.Length -gt $OperationalMaxArchiveBytes) {
        throw 'Admission materials exhausted the runner operational archive-byte budget'
      }
    }
  } finally { $archive.Dispose() }
  if ($stream.Length -gt $OperationalMaxArchiveBytes) {
    throw 'Admission materials exhausted the runner operational archive-byte budget'
  }
  $packagingSucceeded = $true
} finally {
  $stream.Dispose()
  if (-not $packagingSucceeded) {
    Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
  }
}

$archiveItem = Get-Item -LiteralPath $OutputArchive
if ($archiveItem.Length -le 0) {
  Remove-Item -LiteralPath $OutputArchive -Force
  throw 'Admission materials archive is empty'
}
if ($archiveItem.Length -gt $OperationalMaxArchiveBytes) {
  Remove-Item -LiteralPath $OutputArchive -Force
  throw 'Admission materials exhausted the runner operational archive-byte budget'
}
$digest = (Get-FileHash -LiteralPath $OutputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
"materials-sha256=sha256:$digest" >> $env:GITHUB_OUTPUT
"materials-size=$($archiveItem.Length)" >> $env:GITHUB_OUTPUT
