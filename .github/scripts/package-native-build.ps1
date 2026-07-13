[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$CompanionRoot,
  [Parameter(Mandatory = $true)]
  [string]$HooksRoot,
  [Parameter(Mandatory = $true)]
  [string]$OutputArchive
)

$ErrorActionPreference = "Stop"
$MaxExpandedBytes = 128MB
$MaxArchiveBytes = 64MB
$MaxFileBytes = 64MB
$MaxFiles = 1000
$Entries = @{}

function Assert-CanonicalNativePath([string]$Path) {
  if (-not $Path.StartsWith("native/out/", [StringComparison]::Ordinal)) {
    throw "Native output path is outside native/out: $Path"
  }
  if ([Text.Encoding]::UTF8.GetByteCount($Path) -gt 900) {
    throw "Native output path exceeds the 900-byte limit: $Path"
  }
  $Reserved = @(
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
  )
  foreach ($Segment in $Path.Split("/")) {
    if (
      $Segment.Length -eq 0 -or
      $Segment.Length -gt 255 -or
      $Segment.EndsWith(".") -or
      $Segment.EndsWith(" ") -or
      $Segment -notmatch '^[A-Za-z0-9._-]+$'
    ) {
      throw "Native output path is not canonical for Windows: $Path"
    }
    $Stem = ($Segment -split '\.', 2)[0].ToUpperInvariant()
    if ($Reserved -contains $Stem) {
      throw "Native output path contains a reserved Windows name: $Path"
    }
  }
}

function Add-NativeFiles([string]$Root, [string[]]$AllowedPrefixes, [string]$Label) {
  $NativeOut = Join-Path $Root "native/out"
  if (-not (Test-Path -LiteralPath $NativeOut -PathType Container)) {
    return
  }
  foreach ($Item in Get-ChildItem -LiteralPath $NativeOut -File -Recurse -Force) {
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$Label output contains a symbolic link or reparse point: $($Item.FullName)"
    }
    $Relative = $Item.FullName.Substring($NativeOut.Length).TrimStart([char[]]@('\', '/')).Replace("\", "/")
    $ArchivePath = "native/out/$Relative"
    Assert-CanonicalNativePath $ArchivePath
    $Allowed = $false
    foreach ($Prefix in $AllowedPrefixes) {
      if ($ArchivePath.StartsWith($Prefix, [StringComparison]::Ordinal)) {
        $Allowed = $true
        break
      }
    }
    if (-not $Allowed) {
      throw "$Label output is outside its isolated native directories: $ArchivePath"
    }
    if ($Entries.ContainsKey($ArchivePath)) {
      throw "Duplicate native output: $ArchivePath"
    }
    $Entries[$ArchivePath] = $Item.FullName
  }
}

Add-NativeFiles $CompanionRoot @("native/out/windows-x86_64/", "native/out/windows-aarch64/") "companion"
Add-NativeFiles $HooksRoot @("native/out/hooks/") "hook"

if ($Entries.Count -eq 0) {
  throw "Native build produced no declared outputs"
}
if ($Entries.Count -gt $MaxFiles) {
  throw "Native build exceeds $MaxFiles files"
}
$ExpandedBytes = 0L
foreach ($Path in $Entries.Values) {
  $FileBytes = (Get-Item -LiteralPath $Path).Length
  if ($FileBytes -gt $MaxFileBytes) {
    throw "Native build contains a file larger than 64 MiB"
  }
  $ExpandedBytes += $FileBytes
}
if ($ExpandedBytes -gt $MaxExpandedBytes) {
  throw "Native build exceeds the 128 MiB expanded limit"
}

$OutputArchive = [IO.Path]::GetFullPath($OutputArchive)
$OutputDirectory = Split-Path -Parent $OutputArchive
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression
$FileStream = [IO.File]::Open($OutputArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  $Archive = [IO.Compression.ZipArchive]::new($FileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    foreach ($ArchivePath in @($Entries.Keys | Sort-Object)) {
      $Entry = $Archive.CreateEntry($ArchivePath, [IO.Compression.CompressionLevel]::Optimal)
      $Entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $InputStream = [IO.File]::OpenRead($Entries[$ArchivePath])
      $OutputStream = $Entry.Open()
      try {
        $InputStream.CopyTo($OutputStream)
      } finally {
        $OutputStream.Dispose()
        $InputStream.Dispose()
      }
    }
  } finally {
    $Archive.Dispose()
  }
} finally {
  $FileStream.Dispose()
}

if ((Get-Item -LiteralPath $OutputArchive).Length -gt $MaxArchiveBytes) {
  Remove-Item -LiteralPath $OutputArchive -Force
  throw "Native build exceeds the 64 MiB archive limit"
}
Write-Host "Created deterministic native package with $($Entries.Count) files"
