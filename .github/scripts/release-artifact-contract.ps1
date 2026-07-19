function Get-ReleaseArtifactRootName([string]$Kind, [string]$Digest) {
  if ($Digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw 'Release artifact root digest is invalid'
  }
  switch ($Kind) {
    'bundle' { $prefix = 'mywallpaper-addon-bundle' }
    'materials' { $prefix = 'mywallpaper-admission-materials' }
    default { throw 'Release artifact kind must be bundle or materials' }
  }
  return "$prefix-sha256-$($Digest.Substring(7)).zip"
}

function Assert-ExactJsonProperties([object]$Value, [string[]]$Expected, [string]$Label) {
  if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw "$Label must be a JSON object" }
  $actual = [string[]]@($Value.PSObject.Properties.Name)
  $actualSorted = [string[]]@($actual)
  $expectedSorted = [string[]]@($Expected)
  [Array]::Sort($actualSorted, [StringComparer]::Ordinal)
  [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
  if (($actualSorted -join "`n") -cne ($expectedSorted -join "`n")) {
    throw "$Label has fields outside the versioned contract"
  }
}

function ConvertTo-CanonicalJsonInteger([object]$Value, [long]$Minimum, [long]$Maximum, [string]$Label) {
  if ($Value -isnot [int] -and $Value -isnot [long]) { throw "$Label must be a JSON integer" }
  $result = [long]$Value
  if ($result -lt $Minimum -or $result -gt $Maximum) { throw "$Label is outside its allowed range" }
  return $result
}

function Read-ReleaseArtifactManifest(
  [string]$Path,
  [string]$Kind,
  [int]$OperationalMaxParts = 1000
) {
  if ($OperationalMaxParts -lt 1 -or $OperationalMaxParts -gt 1000) {
    throw 'OperationalMaxParts must be between 1 and GitHub release maximum 1000'
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Release artifact manifest is missing' }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Release artifact manifest cannot be a link or reparse point'
  }
  if ($item.Length -le 0 -or $item.Length -gt 1MB) {
    throw 'Release artifact manifest has an invalid size'
  }
  $bytes = [IO.File]::ReadAllBytes($item.FullName)
  try {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $manifest = $text | ConvertFrom-Json
  } catch {
    throw 'Release artifact manifest must be strict UTF-8 JSON'
  }
  Assert-ExactJsonProperties $manifest @('schemaVersion', 'artifact') 'Release artifact manifest'
  $schemaVersion = ConvertTo-CanonicalJsonInteger $manifest.schemaVersion 1 1 'Manifest schemaVersion'
  Assert-ExactJsonProperties $manifest.artifact @('name', 'sizeBytes', 'sha256', 'parts') 'Release artifact root'
  $rootDigest = [string]$manifest.artifact.sha256
  if ($rootDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Release artifact root digest is invalid' }
  $rootName = Get-ReleaseArtifactRootName $Kind $rootDigest
  if ([string]$manifest.artifact.name -cne $rootName) {
    throw 'Release artifact root name is not content-addressed by its digest'
  }
  $rootSize = ConvertTo-CanonicalJsonInteger `
    $manifest.artifact.sizeBytes 1 ([long]::MaxValue) 'Release artifact root sizeBytes'
  $parts = @($manifest.artifact.parts)
  if ($parts.Count -lt 1 -or $parts.Count -gt $OperationalMaxParts) {
    throw 'Release artifact part count is outside its operational budget'
  }
  $canonicalParts = [Collections.Generic.List[object]]::new()
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $sum = 0L
  for ($position = 0; $position -lt $parts.Count; $position++) {
    $part = $parts[$position]
    Assert-ExactJsonProperties $part @('index', 'name', 'sizeBytes', 'sha256') "Release artifact part $position"
    $index = ConvertTo-CanonicalJsonInteger $part.index 0 999 "Release artifact part $position index"
    if ($index -ne $position) { throw 'Release artifact part index must equal its zero-based position' }
    $partDigest = [string]$part.sha256
    if ($partDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "Release artifact part $position digest is invalid" }
    $partSize = ConvertTo-CanonicalJsonInteger `
      $part.sizeBytes 1 2147483647 "Release artifact part $position sizeBytes"
    $partName = "$rootName.part-$position-sha256-$($partDigest.Substring(7))"
    if ([string]$part.name -cne $partName -or -not $names.Add($partName)) {
      throw 'Release artifact part name is duplicate or not content-addressed'
    }
    if ($sum -gt ([long]::MaxValue - $partSize)) { throw 'Release artifact size overflows Int64' }
    $sum += $partSize
    $canonicalParts.Add([ordered]@{
      index = [long]$index
      name = $partName
      sizeBytes = [long]$partSize
      sha256 = $partDigest
    })
  }
  if ($sum -ne $rootSize) { throw 'Release artifact part sizes do not equal the logical root size' }
  $canonical = [ordered]@{
    schemaVersion = [long]$schemaVersion
    artifact = [ordered]@{
      name = $rootName
      sizeBytes = [long]$rootSize
      sha256 = $rootDigest
      parts = $canonicalParts
    }
  }
  $canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    ($canonical | ConvertTo-Json -Depth 8 -Compress)
  )
  if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($canonicalBytes)) {
    throw 'Release artifact manifest is not canonical JSON'
  }
  return [pscustomobject]@{
    ManifestPath = $item.FullName
    Artifact = $canonical.artifact
  }
}

function Read-ReleaseArtifactDescriptor(
  [string]$Path,
  [string]$Kind,
  [int]$OperationalMaxParts = 1000
) {
  if ($OperationalMaxParts -lt 1 -or $OperationalMaxParts -gt 1000) {
    throw 'OperationalMaxParts must be between 1 and GitHub release maximum 1000'
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Release artifact descriptor is missing' }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      $item.Length -le 0 -or $item.Length -gt 1MB) {
    throw 'Release artifact descriptor must be a bounded regular file'
  }
  $bytes = [IO.File]::ReadAllBytes($item.FullName)
  try {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $artifact = $text | ConvertFrom-Json
  } catch {
    throw 'Release artifact descriptor must be strict UTF-8 JSON'
  }
  Assert-ExactJsonProperties $artifact @('name', 'sizeBytes', 'sha256', 'parts') 'Release artifact descriptor'
  $rootDigest = [string]$artifact.sha256
  if ($rootDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Release artifact descriptor digest is invalid' }
  $rootName = Get-ReleaseArtifactRootName $Kind $rootDigest
  if ([string]$artifact.name -cne $rootName) { throw 'Release artifact descriptor name is invalid' }
  $rootSize = ConvertTo-CanonicalJsonInteger `
    $artifact.sizeBytes 1 ([long]::MaxValue) 'Release artifact descriptor sizeBytes'
  $sourceParts = @($artifact.parts)
  if ($sourceParts.Count -lt 1 -or $sourceParts.Count -gt $OperationalMaxParts) {
    throw 'Release artifact descriptor part count is outside its operational budget'
  }
  $canonicalParts = [Collections.Generic.List[object]]::new()
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $sum = 0L
  for ($position = 0; $position -lt $sourceParts.Count; $position++) {
    $part = $sourceParts[$position]
    Assert-ExactJsonProperties $part @('id', 'name', 'sizeBytes', 'sha256', 'index') `
      "Release artifact descriptor part $position"
    $id = [string]$part.id
    if ($id -cnotmatch '^[1-9][0-9]*$' -or -not $ids.Add($id)) {
      throw 'Release artifact descriptor part ID is invalid or duplicate'
    }
    $index = ConvertTo-CanonicalJsonInteger $part.index 0 999 `
      "Release artifact descriptor part $position index"
    if ($index -ne $position) { throw 'Release artifact descriptor part index is out of order' }
    $digest = [string]$part.sha256
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
      throw 'Release artifact descriptor part digest is invalid'
    }
    $size = ConvertTo-CanonicalJsonInteger `
      $part.sizeBytes 1 2147483647 "Release artifact descriptor part $position sizeBytes"
    $name = "$rootName.part-$position-sha256-$($digest.Substring(7))"
    if ([string]$part.name -cne $name -or -not $names.Add($name)) {
      throw 'Release artifact descriptor part name is invalid or duplicate'
    }
    if ($sum -gt ([long]::MaxValue - $size)) { throw 'Release artifact descriptor size overflows Int64' }
    $sum += $size
    $canonicalParts.Add([ordered]@{
      id = $id
      name = $name
      sizeBytes = [long]$size
      sha256 = $digest
      index = [long]$index
    })
  }
  if ($sum -ne $rootSize) { throw 'Release artifact descriptor parts do not equal root sizeBytes' }
  $canonical = [ordered]@{
    name = $rootName
    sizeBytes = [long]$rootSize
    sha256 = $rootDigest
    parts = $canonicalParts
  }
  $canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    ($canonical | ConvertTo-Json -Depth 8 -Compress)
  )
  if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($canonicalBytes)) {
    throw 'Release artifact descriptor is not canonical JSON'
  }
  return [pscustomobject]@{ DescriptorPath = $item.FullName; Artifact = $canonical }
}
