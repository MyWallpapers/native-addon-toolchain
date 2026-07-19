[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepositoryRoot,
  [Parameter(Mandatory = $true)][string]$CompanionRoot,
  [Parameter(Mandatory = $true)][string]$HooksRoot,
  [Parameter(Mandatory = $true)][string]$RepositoryId,
  [Parameter(Mandatory = $true)][string]$RepositoryOwner,
  [Parameter(Mandatory = $true)][string]$RepositoryName,
  [Parameter(Mandatory = $true)][string]$CommitSha,
  [Parameter(Mandatory = $true)][string]$OutputArchive,
  [Parameter(Mandatory = $true)][long]$OperationalMaxFiles,
  [Parameter(Mandatory = $true)][long]$OperationalMaxExpandedBytes,
  [Parameter(Mandatory = $true)][long]$OperationalMaxArchiveBytes,
  [string]$AdmissionMetadataRoot
)

$ErrorActionPreference = 'Stop'
if ($OperationalMaxFiles -le 0) { throw 'OperationalMaxFiles must be positive' }
if ($OperationalMaxExpandedBytes -le 0) { throw 'OperationalMaxExpandedBytes must be positive' }
if ($OperationalMaxArchiveBytes -le 0) { throw 'OperationalMaxArchiveBytes must be positive' }
$Entries = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)

function Add-CheckedInt64([long]$Current, [long]$Increment, [string]$Label) {
  if ($Increment -lt 0 -or $Current -gt ([long]::MaxValue - $Increment)) {
    throw "$Label byte count overflows Int64"
  }
  return [long]($Current + $Increment)
}

function Assert-CanonicalBundlePath([string]$Path) {
  if ([Text.Encoding]::UTF8.GetByteCount($Path) -gt 900 -or $Path.Contains('\') -or $Path.Contains(':')) {
    throw "Bundle path is not portable: $Path"
  }
  foreach ($Segment in $Path.Split('/')) {
    if (
      $Segment.Length -eq 0 -or $Segment.Length -gt 255 -or
      $Segment -in @('.', '..') -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or
      $Segment -notmatch '^[A-Za-z0-9._-]+$'
    ) {
      throw "Bundle path contains a non-canonical segment: $Path"
    }
    $Stem = ($Segment -split '\.', 2)[0].ToUpperInvariant()
    if ($Stem -in @(
      'CON', 'PRN', 'AUX', 'NUL',
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )) { throw "Bundle path contains a reserved Windows name: $Path" }
  }
}

function Resolve-RegularFile([string]$Root, [string]$RelativePath, [string]$Label) {
  Assert-CanonicalBundlePath $RelativePath
  $Root = [IO.Path]::GetFullPath($Root)
  $Candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
  $Prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $Candidate.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escapes its root"
  }
  if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "$Label does not exist: $RelativePath" }
  $Item = Get-Item -LiteralPath $Candidate -Force
  if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label cannot be a symbolic link or reparse point: $RelativePath"
  }
  return $Item.FullName
}

function Add-BundleFile([string]$ArchivePath, [string]$SourcePath, [string]$Label) {
  Assert-CanonicalBundlePath $ArchivePath
  if ($ArchivePath.StartsWith('dist/__mywallpaper/', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Development-only MyWallpaper output cannot be published: $ArchivePath"
  }
  $Item = Get-Item -LiteralPath $SourcePath -Force
  if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label must be a regular file without links: $ArchivePath"
  }
  if ($Entries.ContainsKey($ArchivePath)) {
    if ($Entries[$ArchivePath] -ne $Item.FullName) { throw "Duplicate bundle path: $ArchivePath" }
    return
  }
  if ([long]$Entries.Count -ge $OperationalMaxFiles) {
    throw 'Bundle exhausted the runner operational file budget'
  }
  $Entries[$ArchivePath] = $Item.FullName
}

function Add-Tree([string]$Root, [string]$ArchivePrefix, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
  $Root = (Resolve-Path -LiteralPath $Root).ProviderPath
  $RootItem = Get-Item -LiteralPath $Root -Force
  if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label root cannot be a symbolic link or reparse point: $Root"
  }
  $Pending = [Collections.Generic.Stack[string]]::new()
  $Pending.Push($Root)
  while ($Pending.Count -gt 0) {
    $Directory = $Pending.Pop()
    foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force | Sort-Object Name -Descending)) {
      if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label contains a symbolic link or reparse point: $($Item.FullName)"
      }
      if ($Item.PSIsContainer) {
        $Pending.Push($Item.FullName)
        continue
      }
      if (-not (Test-Path -LiteralPath $Item.FullName -PathType Leaf)) {
        throw "$Label contains a non-regular file: $($Item.FullName)"
      }
      $Relative = $Item.FullName.Substring($Root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
      Add-BundleFile "$ArchivePrefix/$Relative" $Item.FullName $Label
    }
  }
}

function Get-MediaType([string]$Path) {
  if ($Path -ceq 'LICENSE') { return 'text/plain; charset=utf-8' }
  switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.html' { 'text/html; charset=utf-8'; break }
    '.css' { 'text/css; charset=utf-8'; break }
    '.js' { 'text/javascript; charset=utf-8'; break }
    '.mjs' { 'text/javascript; charset=utf-8'; break }
    '.json' { 'application/json'; break }
    '.map' { 'application/json'; break }
    '.webmanifest' { 'application/manifest+json'; break }
    '.txt' { 'text/plain; charset=utf-8'; break }
    '.glsl' { 'text/plain; charset=utf-8'; break }
    '.vert' { 'text/plain; charset=utf-8'; break }
    '.frag' { 'text/plain; charset=utf-8'; break }
    '.wgsl' { 'text/plain; charset=utf-8'; break }
    '.vtt' { 'text/plain; charset=utf-8'; break }
    '.xml' { 'application/xml'; break }
    '.svg' { 'image/svg+xml'; break }
    '.png' { 'image/png'; break }
    '.jpg' { 'image/jpeg'; break }
    '.jpeg' { 'image/jpeg'; break }
    '.webp' { 'image/webp'; break }
    '.avif' { 'image/avif'; break }
    '.gif' { 'image/gif'; break }
    '.ico' { 'image/x-icon'; break }
    '.bmp' { 'image/bmp'; break }
    '.woff' { 'font/woff'; break }
    '.woff2' { 'font/woff2'; break }
    '.wasm' { 'application/wasm'; break }
    '.mp3' { 'audio/mpeg'; break }
    '.ogg' { 'audio/ogg'; break }
    '.wav' { 'audio/wav'; break }
    '.flac' { 'audio/flac'; break }
    '.aac' { 'audio/mp4'; break }
    '.m4a' { 'audio/mp4'; break }
    '.mp4' { 'video/mp4'; break }
    '.webm' { 'video/webm'; break }
    '.ogv' { 'video/ogg'; break }
    '.exe' { 'application/vnd.microsoft.portable-executable'; break }
    '.dll' { 'application/vnd.microsoft.portable-executable'; break }
    default { 'application/octet-stream' }
  }
}

function Get-StringSha256([string]$Text) {
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $Digest = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return (($Digest | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $Hasher.Dispose() }
}

function Get-SortedEntryPaths() {
  $Paths = [string[]]@($Entries.Keys)
  [Array]::Sort($Paths, [StringComparer]::Ordinal)
  return $Paths
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
if ($RepositoryId -notmatch '^[1-9][0-9]*$') { throw 'RepositoryId must be the immutable GitHub numeric repository id' }
if ($RepositoryOwner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') { throw 'RepositoryOwner is invalid' }
if ($RepositoryName -notmatch '^[A-Za-z0-9._-]{1,100}$') { throw 'RepositoryName is invalid' }
if ($CommitSha -notmatch '^[0-9a-f]{40}$') { throw 'CommitSha must be a lowercase full Git commit SHA' }
$ActualCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $ActualCommit -cne $CommitSha) { throw 'Checked out commit does not match CommitSha' }

$ManifestPath = Resolve-RegularFile $RepositoryRoot 'manifest.json' 'manifest'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
Add-BundleFile 'manifest.json' $ManifestPath 'manifest'
$LicensePath = Resolve-RegularFile $RepositoryRoot 'LICENSE' 'license'
$LicenseBytes = [IO.File]::ReadAllBytes($LicensePath)
if ($LicenseBytes.Length -eq 0 -or $LicenseBytes.Length -gt 1MB) {
  throw 'LICENSE must contain between 1 byte and 1 MiB'
}
try {
  $LicenseText = [Text.UTF8Encoding]::new($false, $true).GetString($LicenseBytes)
} catch {
  throw 'LICENSE must be valid UTF-8 text'
}
if ([string]::IsNullOrWhiteSpace($LicenseText) -or $LicenseText.Contains([char]0)) {
  throw 'LICENSE must contain non-empty UTF-8 text without NUL characters'
}
Add-BundleFile 'LICENSE' $LicensePath 'license'
Add-Tree (Join-Path $RepositoryRoot 'dist') 'dist' 'web build'
$ThumbnailRelative = [string]$Manifest.thumbnail
$ThumbnailPath = Resolve-RegularFile $RepositoryRoot $ThumbnailRelative 'thumbnail'
Add-BundleFile $ThumbnailRelative $ThumbnailPath 'thumbnail'
Add-Tree (Join-Path $CompanionRoot 'native/out') 'native/out' 'companion output'
Add-Tree (Join-Path $HooksRoot 'native/out') 'native/out' 'hook output'

if ($Entries.Count -lt 4) { throw 'Bundle must contain manifest, license, web output and thumbnail' }
$ExpandedBytes = 0L
$Inventory = [Collections.Generic.List[object]]::new()
foreach ($ArchivePath in @(Get-SortedEntryPaths)) {
  $SourcePath = [string]$Entries[$ArchivePath]
  $Size = (Get-Item -LiteralPath $SourcePath).Length
  $ExpandedBytes = Add-CheckedInt64 $ExpandedBytes $Size 'Bundle'
  if ($ExpandedBytes -gt $OperationalMaxExpandedBytes) {
    throw 'Bundle exhausted the runner operational expanded-byte budget'
  }
  $Sha256 = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $MediaType = Get-MediaType $ArchivePath
  $Inventory.Add([ordered]@{
    path = $ArchivePath
    size = $Size
    sha256 = "sha256:$Sha256"
    mediaType = $MediaType
  })
}

$TreeInventory = ((& git -C $RepositoryRoot ls-tree -r --full-tree $CommitSha) -join "`n") + "`n"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($TreeInventory)) { throw 'Could not inventory the exact source tree' }
$SourceDigest = Get-StringSha256 $TreeInventory
$OutputArchive = [IO.Path]::GetFullPath($OutputArchive)
$OutputDirectory = Split-Path -Parent $OutputArchive
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$IndexPath = Join-Path $OutputDirectory 'bundle-index.json'
$InventoryPath = Join-Path $OutputDirectory 'bundle-payload-inventory.json'
$Inventory | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $InventoryPath -Encoding utf8NoBOM
$IndexResultJson = & node (Join-Path $PSScriptRoot 'create-addon-bundle-index.mjs') `
  --manifest $ManifestPath `
  --inventory $InventoryPath `
  --repository-id $RepositoryId `
  --repository-owner $RepositoryOwner `
  --repository-name $RepositoryName `
  --commit-sha $CommitSha `
  --source-digest "sha256:$SourceDigest" `
  --output $IndexPath
if ($LASTEXITCODE -ne 0) { throw 'Canonical bundle index generation failed' }
$IndexResult = $IndexResultJson | ConvertFrom-Json
if ($IndexResult.distributionDigest -notmatch '^sha256:[0-9a-f]{64}$') {
  throw 'Canonical bundle index did not return a distribution digest'
}
$ExpandedBytes = Add-CheckedInt64 $ExpandedBytes (Get-Item -LiteralPath $IndexPath).Length 'Bundle'
if ($ExpandedBytes -gt $OperationalMaxExpandedBytes) {
  throw 'Bundle exhausted the runner operational expanded-byte budget'
}
Add-BundleFile 'bundle-index.json' $IndexPath 'bundle index'
if (-not [string]::IsNullOrWhiteSpace($AdmissionMetadataRoot)) {
  $AdmissionMetadataRoot = [IO.Path]::GetFullPath($AdmissionMetadataRoot)
  if (Test-Path -LiteralPath $AdmissionMetadataRoot) {
    throw 'AdmissionMetadataRoot must not already exist'
  }
  New-Item -ItemType Directory -Path $AdmissionMetadataRoot | Out-Null
  Copy-Item -LiteralPath $IndexPath -Destination (Join-Path $AdmissionMetadataRoot 'bundle-index.json')
  Copy-Item -LiteralPath $InventoryPath -Destination (Join-Path $AdmissionMetadataRoot 'bundle-payload-inventory.json')
}
Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression
$FileStream = [IO.File]::Open($OutputArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$PackagingSucceeded = $false
try {
  $Archive = [IO.Compression.ZipArchive]::new($FileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
  try {
    foreach ($ArchivePath in @(Get-SortedEntryPaths)) {
      $Entry = $Archive.CreateEntry($ArchivePath, [IO.Compression.CompressionLevel]::Optimal)
      $Entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $InputStream = [IO.File]::OpenRead([string]$Entries[$ArchivePath])
      $OutputStream = $Entry.Open()
      try { $InputStream.CopyTo($OutputStream) }
      finally { $OutputStream.Dispose(); $InputStream.Dispose() }
      if ($FileStream.Length -gt $OperationalMaxArchiveBytes) {
        throw 'Bundle exhausted the runner operational archive-byte budget'
      }
    }
  } finally { $Archive.Dispose() }
  if ($FileStream.Length -gt $OperationalMaxArchiveBytes) {
    throw 'Bundle exhausted the runner operational archive-byte budget'
  }
  $PackagingSucceeded = $true
} finally {
  $FileStream.Dispose()
  if (-not $PackagingSucceeded) {
    Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
  }
}
Remove-Item -LiteralPath $IndexPath, $InventoryPath -Force

if ((Get-Item -LiteralPath $OutputArchive).Length -gt $OperationalMaxArchiveBytes) {
  Remove-Item -LiteralPath $OutputArchive -Force
  throw 'Bundle exhausted the runner operational archive-byte budget'
}
$ArchiveItem = Get-Item -LiteralPath $OutputArchive
$ArchiveSha256 = (Get-FileHash -LiteralPath $OutputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Created immutable add-on bundle $($IndexResult.distributionDigest) with $($Inventory.Count) payload files"
"distribution-digest=$($IndexResult.distributionDigest)" >> $env:GITHUB_OUTPUT
"archive-sha256=sha256:$ArchiveSha256" >> $env:GITHUB_OUTPUT
"archive-size=$($ArchiveItem.Length)" >> $env:GITHUB_OUTPUT
