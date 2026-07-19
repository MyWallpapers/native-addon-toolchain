[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Repository,
  [Parameter(Mandatory = $true)][string]$ReleaseId,
  [Parameter(Mandatory = $true)][string]$BundleTransportRoot,
  [Parameter(Mandatory = $true)][string]$MaterialsTransportRoot,
  [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')
. (Join-Path $PSScriptRoot 'github-api-contract.ps1')
$GitHubAssetExclusiveByteLimit = 2147483648L
$ApiHeaders = @{
  Accept = 'application/vnd.github+json'
  Authorization = "Bearer $env:GITHUB_TOKEN"
  'User-Agent' = 'MyWallpaper-admission-v1'
  'X-GitHub-Api-Version' = '2026-03-10'
}

if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$') {
  throw 'Repository is invalid'
}
if ($ReleaseId -cnotmatch '^[1-9][0-9]*$') { throw 'ReleaseId must be a positive GitHub release ID' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'GITHUB_TOKEN is required' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) { throw 'GITHUB_OUTPUT is required' }

function Get-ErrorDetail([object]$Record) {
  if (-not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.Message)) {
    return [string]$Record.ErrorDetails.Message
  }
  return [string]$Record.Exception.Message
}

function Invoke-GitHubGet([string]$Uri, [string]$Label) {
  try {
    return Invoke-RestMethod -Uri $Uri -Headers $ApiHeaders -MaximumRedirection 0
  } catch {
    throw "$Label failed: $(Get-ErrorDetail $_)"
  }
}

function Get-ReleaseAssets() {
  $assets = [Collections.Generic.List[object]]::new()
  $page = 1
  while ($true) {
    $response = Invoke-GitHubGet `
      "https://api.github.com/repos/$Repository/releases/$ReleaseId/assets?per_page=100&page=$page" `
      'GitHub release asset listing'
    $items = ConvertTo-GitHubApiItemList -Response $response -Label 'GitHub release asset listing'
    foreach ($item in $items) { $assets.Add($item) }
    if ($items.Count -lt 100) { break }
    if ($page -eq [int]::MaxValue) { throw 'GitHub release asset pagination overflowed' }
    $page++
  }
  return $assets
}

function Send-ReleaseAsset([string]$Path, [string]$Name) {
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $client = [Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromMinutes(40)
  $client.DefaultRequestHeaders.Authorization =
    [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:GITHUB_TOKEN)
  $client.DefaultRequestHeaders.Accept.Add(
    [Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/vnd.github+json')
  )
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('MyWallpaper-admission-v1')
  $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2026-03-10')
  $client.DefaultRequestHeaders.ExpectContinue = $true
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $content = [Net.Http.StreamContent]::new($stream)
  $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
  $content.Headers.ContentLength = $stream.Length
  $response = $null
  try {
    $encodedName = [Uri]::EscapeDataString($Name)
    $uri = "https://uploads.github.com/repos/$Repository/releases/$ReleaseId/assets?name=$encodedName"
    $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if ($bytes.Length -gt 1MB) { throw 'GitHub release asset API returned an oversized response' }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw 'GitHub release asset API returned non-UTF-8 response data' }
    if ([int]$response.StatusCode -eq 422) { return $null }
    if ([int]$response.StatusCode -ne 201) {
      throw "GitHub release asset upload failed with HTTP $([int]$response.StatusCode): $text"
    }
    try { return $text | ConvertFrom-Json }
    catch { throw 'GitHub release asset API returned invalid JSON' }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    $content.Dispose()
    $client.Dispose()
  }
}

function Resolve-VerifiedRemoteAsset(
  [object]$Asset,
  [string]$Name,
  [string]$Digest,
  [long]$Size,
  [string]$Label
) {
  if ($null -eq $Asset) { throw "$Label GitHub release asset is missing" }
  $id = [string]$Asset.id
  if ($id -cnotmatch '^[1-9][0-9]*$') { throw "$Label GitHub release asset ID is invalid" }
  for ($attempt = 0; $attempt -lt 6; $attempt++) {
    if ($attempt -gt 0) {
      Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt - 1)))
      $Asset = Invoke-GitHubGet `
        "https://api.github.com/repos/$Repository/releases/assets/$id" `
        "$Label GitHub release asset digest lookup"
    }
    if (
      [string]$Asset.id -cne $id -or
      [string]$Asset.name -cne $Name -or
      [string]$Asset.state -cne 'uploaded' -or
      [string]$Asset.content_type -cne 'application/octet-stream' -or
      [long]$Asset.size -ne $Size
    ) { throw "$Label GitHub release asset differs from the verified local part" }
    $remoteDigest = [string]$Asset.digest
    if ($remoteDigest -ceq $Digest) { return [string]$id }
    if (-not [string]::IsNullOrWhiteSpace($remoteDigest)) {
      throw "$Label GitHub release asset has a different digest"
    }
  }
  throw "$Label GitHub release asset digest was not calculated in time"
}

function Read-LocalArtifact([string]$TransportRoot, [string]$Kind) {
  $TransportRoot = (Resolve-Path -LiteralPath $TransportRoot).ProviderPath
  $rootItem = Get-Item -LiteralPath $TransportRoot -Force
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Kind transport root is invalid"
  }
  $manifestPath = Join-Path $TransportRoot 'artifact.json'
  $partsRoot = Join-Path $TransportRoot 'parts'
  $topLevel = @(Get-ChildItem -LiteralPath $TransportRoot -Force)
  if ($topLevel.Count -ne 2 -or -not (Test-Path -LiteralPath $partsRoot -PathType Container)) {
    throw "$Kind transport root contains unexpected files"
  }
  $artifact = (Read-ReleaseArtifactManifest $manifestPath $Kind 1000).Artifact
  $files = @(Get-ChildItem -LiteralPath $partsRoot -Force)
  if ($files.Count -ne @($artifact.parts).Count -or @($files | Where-Object { $_.PSIsContainer }).Count -ne 0) {
    throw "$Kind transport parts do not match the canonical manifest"
  }
  $paths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
  foreach ($file in $files) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $paths.ContainsKey($file.Name)) {
      throw "$Kind transport contains an invalid or duplicate part"
    }
    $paths.Add($file.Name, $file.FullName)
  }
  foreach ($part in @($artifact.parts)) {
    $name = [string]$part.name
    if (-not $paths.ContainsKey($name)) { throw "$Kind transport part is missing: $name" }
    $path = $paths[$name]
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Length -ne [long]$part.sizeBytes -or $item.Length -le 0 -or
        $item.Length -ge $GitHubAssetExclusiveByteLimit) {
      throw "$Kind transport part size is invalid: $name"
    }
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne [string]$part.sha256) { throw "$Kind transport part digest changed: $name" }
  }
  return [pscustomobject]@{ Artifact = $artifact; Paths = $paths }
}

$bundle = Read-LocalArtifact $BundleTransportRoot 'bundle'
$materials = Read-LocalArtifact $MaterialsTransportRoot 'materials'
$expectedParts = @($bundle.Artifact.parts) + @($materials.Artifact.parts)
if ($expectedParts.Count -lt 2 -or $expectedParts.Count -gt 1000) {
  throw 'Controlled GitHub release exceeds the external 1000-asset limit'
}
$expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($part in $expectedParts) {
  if (-not $expectedNames.Add([string]$part.name)) { throw 'Logical artifacts contain duplicate release part names' }
}

$existingByName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($asset in @(Get-ReleaseAssets)) {
  $name = [string]$asset.name
  if (-not $expectedNames.Contains($name) -or $existingByName.ContainsKey($name)) {
    throw 'Controlled GitHub release contains an unexpected or duplicate asset'
  }
  $existingByName.Add($name, $asset)
}
$publishedByName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($kind in @($bundle, $materials)) {
  foreach ($part in @($kind.Artifact.parts)) {
    $name = [string]$part.name
    $asset = if ($existingByName.ContainsKey($name)) { $existingByName[$name] } else {
      Send-ReleaseAsset $kind.Paths[$name] $name
    }
    if ($null -eq $asset) {
      $matches = @((Get-ReleaseAssets) | Where-Object { [string]$_.name -ceq $name })
      if ($matches.Count -ne 1) { throw 'Could not resolve GitHub release asset after upload race' }
      $asset = $matches[0]
    }
    $id = Resolve-VerifiedRemoteAsset `
      $asset $name ([string]$part.sha256) ([long]$part.sizeBytes) "Part $($part.index)"
    $publishedByName.Add($name, [pscustomobject]@{ Id = $id; Part = $part })
  }
}

$finalAssets = @(Get-ReleaseAssets)
if ($finalAssets.Count -ne $expectedParts.Count) {
  throw 'Controlled GitHub release does not contain the exact logical artifact parts'
}
$seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($asset in $finalAssets) {
  $name = [string]$asset.name
  if (-not $publishedByName.ContainsKey($name)) { throw 'Controlled GitHub release contains an unexpected asset' }
  $published = $publishedByName[$name]
  $verifiedId = Resolve-VerifiedRemoteAsset `
    $asset $name ([string]$published.Part.sha256) ([long]$published.Part.sizeBytes) 'Final part'
  if ($verifiedId -cne [string]$published.Id -or -not $seenIds.Add($verifiedId)) {
    throw 'GitHub release asset identity changed or is duplicated'
  }
}

function New-RootDescriptor([object]$LocalArtifact) {
  $parts = [Collections.Generic.List[object]]::new()
  foreach ($part in @($LocalArtifact.parts)) {
    $published = $publishedByName[[string]$part.name]
    $parts.Add([ordered]@{
      id = [string]$published.Id
      name = [string]$part.name
      sizeBytes = [long]$part.sizeBytes
      sha256 = [string]$part.sha256
      index = [long]$part.index
    })
  }
  return [ordered]@{
    name = [string]$LocalArtifact.name
    sizeBytes = [long]$LocalArtifact.sizeBytes
    sha256 = [string]$LocalArtifact.sha256
    parts = $parts
  }
}

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must not already exist' }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$bundleDescriptorPath = Join-Path $OutputRoot 'bundle-artifact.json'
$materialsDescriptorPath = Join-Path $OutputRoot 'materials-artifact.json'
[IO.File]::WriteAllBytes(
  $bundleDescriptorPath,
  [Text.UTF8Encoding]::new($false).GetBytes(
    ((New-RootDescriptor $bundle.Artifact) | ConvertTo-Json -Depth 8 -Compress)
  )
)
[IO.File]::WriteAllBytes(
  $materialsDescriptorPath,
  [Text.UTF8Encoding]::new($false).GetBytes(
    ((New-RootDescriptor $materials.Artifact) | ConvertTo-Json -Depth 8 -Compress)
  )
)
"bundle-artifact=$bundleDescriptorPath" >> $env:GITHUB_OUTPUT
"materials-artifact=$materialsDescriptorPath" >> $env:GITHUB_OUTPUT
"release-asset-count=$($expectedParts.Count)" >> $env:GITHUB_OUTPUT
