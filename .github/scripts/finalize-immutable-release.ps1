[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Repository,
  [Parameter(Mandatory = $true)][string]$ReleaseId,
  [Parameter(Mandatory = $true)][string]$TagName,
  [Parameter(Mandatory = $true)][string]$CommitSha,
  [Parameter(Mandatory = $true)][string]$BundleArtifact,
  [Parameter(Mandatory = $true)][string]$MaterialsArtifact
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')
. (Join-Path $PSScriptRoot 'github-api-contract.ps1')
$ApiVersion = '2026-03-10'
$SemVerTagPattern = '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
$Headers = @{
  Accept = 'application/vnd.github+json'
  Authorization = "Bearer $env:GITHUB_TOKEN"
  'User-Agent' = 'MyWallpaper-admission-v1'
  'X-GitHub-Api-Version' = $ApiVersion
}

if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$') {
  throw 'Repository is invalid'
}
if ($ReleaseId -cnotmatch '^[1-9][0-9]*$') { throw 'ReleaseId must be a positive decimal string' }
if ($TagName -cnotmatch $SemVerTagPattern) { throw 'TagName must be a v-prefixed canonical SemVer tag' }
if ($CommitSha -cnotmatch '^[0-9a-f]{40}$') { throw 'CommitSha must be a lowercase full Git commit SHA' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'GITHUB_TOKEN is required' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) { throw 'GITHUB_OUTPUT is required' }

$BundleDescriptor = (Read-ReleaseArtifactDescriptor $BundleArtifact 'bundle' 1000).Artifact
$MaterialsDescriptor = (Read-ReleaseArtifactDescriptor $MaterialsArtifact 'materials' 1000).Artifact
$AllParts = @($BundleDescriptor.parts) + @($MaterialsDescriptor.parts)
if ($AllParts.Count -lt 2 -or $AllParts.Count -gt 1000) {
  throw 'Controlled GitHub release exceeds the external 1000-asset limit'
}
$ExpectedAssets = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$ExpectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($part in $AllParts) {
  $id = [string]$part.id
  if (-not $ExpectedIds.Add($id)) { throw 'GitHub asset ID is duplicated across logical artifacts' }
  $ExpectedAssets.Add([string]$part.name, [pscustomobject]@{
    Id = $id
    Digest = [string]$part.sha256
    Size = [long]$part.sizeBytes
  })
}
$ExpectedReleaseName = $TagName
$ExpectedReleaseBody = [string]::Join("`n", @(
  '<!-- mywallpaper-admission-v1 -->',
  "Source commit: $CommitSha",
  "Bundle: $($BundleDescriptor.sha256)",
  "Materials: $($MaterialsDescriptor.sha256)"
))

function Get-ErrorDetail([object]$Record) {
  if (-not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.Message)) {
    return [string]$Record.ErrorDetails.Message
  }
  return [string]$Record.Exception.Message
}

function Invoke-GitHubGet([string]$Uri, [string]$Label) {
  try { return Invoke-RestMethod -Uri $Uri -Headers $Headers -MaximumRedirection 0 }
  catch { throw "$Label failed: $(Get-ErrorDetail $_)" }
}

function Get-TagCommit() {
  $encodedTag = [Uri]::EscapeDataString($TagName)
  $reference = Invoke-GitHubGet `
    "https://api.github.com/repos/$Repository/git/ref/tags/$encodedTag" `
    'GitHub tag lookup'
  if ([string]$reference.ref -cne "refs/tags/$TagName") { throw 'GitHub returned a different tag ref' }
  $objectSha = [string]$reference.object.sha
  $objectType = [string]$reference.object.type
  if ($objectSha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub tag target SHA is invalid' }
  if ($objectType -ceq 'commit') { return $objectSha }
  if ($objectType -cne 'tag') { throw "GitHub tag has unsupported target type: $objectType" }
  $tagObject = Invoke-GitHubGet `
    "https://api.github.com/repos/$Repository/git/tags/$objectSha" `
    'GitHub annotated-tag lookup'
  if ([string]$tagObject.tag -cne $TagName -or [string]$tagObject.object.type -cne 'commit') {
    throw 'Nested, non-commit or different annotated tag is not admissible'
  }
  $peeledSha = [string]$tagObject.object.sha
  if ($peeledSha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub annotated-tag commit SHA is invalid' }
  return $peeledSha
}

function Get-Release() {
  return Invoke-GitHubGet `
    "https://api.github.com/repos/$Repository/releases/$ReleaseId" `
    'GitHub release lookup'
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

function Assert-ControlledRelease([object]$Release) {
  if ($null -eq $Release -or
      [string]$Release.id -cne $ReleaseId -or
      [string]$Release.tag_name -cne $TagName -or
      [string]$Release.name -cne $ExpectedReleaseName -or
      [string]$Release.body -cne $ExpectedReleaseBody -or
      [bool]$Release.prerelease) {
    throw 'GitHub release is not the exact admission-v1 controlled release'
  }
  if ([bool]$Release.draft) {
    if ([bool]$Release.immutable -or -not [string]::IsNullOrWhiteSpace([string]$Release.published_at)) {
      throw 'GitHub draft release state is inconsistent'
    }
    return 'draft'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Release.published_at)) {
    throw 'Published GitHub release has no publication timestamp'
  }
  if ([bool]$Release.immutable) { return 'immutable' }
  return 'pending-immutable'
}

function Assert-ExactAssets() {
  $assets = @(Get-ReleaseAssets)
  if ($assets.Count -ne $ExpectedAssets.Count) {
    throw 'GitHub release does not contain exactly the verified logical artifact parts'
  }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($asset in $assets) {
    $name = [string]$asset.name
    if (-not $ExpectedAssets.ContainsKey($name) -or -not $seen.Add($name)) {
      throw 'GitHub release contains an unexpected or duplicate asset'
    }
    $expected = $ExpectedAssets[$name]
    if ([string]$asset.id -cne [string]$expected.Id -or
        [string]$asset.state -cne 'uploaded' -or
        [string]$asset.content_type -cne 'application/octet-stream' -or
        [long]$asset.size -ne [long]$expected.Size -or
        [string]$asset.digest -cne [string]$expected.Digest) {
      throw 'GitHub release asset differs from the verified logical artifact part'
    }
  }
}

function Wait-ImmutableRelease() {
  for ($attempt = 0; $attempt -lt 6; $attempt++) {
    if ($attempt -gt 0) {
      Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt - 1)))
    }
    $candidate = Get-Release
    $state = Assert-ControlledRelease $candidate
    if ($state -ceq 'immutable') { return $candidate }
    if ($state -ceq 'draft') { throw 'GitHub release returned to draft during immutable publication' }
  }
  throw 'GitHub published the release but did not confirm its immutable lock in time'
}

if ((Get-TagCommit) -cne $CommitSha) { throw 'GitHub tag no longer resolves to the triggering commit' }
$release = Get-Release
$state = Assert-ControlledRelease $release
Assert-ExactAssets
if ($state -ceq 'draft') {
  $body = [ordered]@{
    tag_name = $TagName
    target_commitish = $CommitSha
    name = $ExpectedReleaseName
    body = $ExpectedReleaseBody
    draft = $false
    prerelease = $false
    make_latest = 'legacy'
  } | ConvertTo-Json -Depth 4 -Compress
  try {
    $release = Invoke-RestMethod `
      -Method Patch `
      -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId" `
      -Headers $Headers `
      -MaximumRedirection 0 `
      -ContentType 'application/json' `
      -Body ([Text.UTF8Encoding]::new($false).GetBytes($body))
  } catch {
    throw "GitHub immutable release publication failed: $(Get-ErrorDetail $_)"
  }
  $patchedState = Assert-ControlledRelease $release
  if ($patchedState -ceq 'draft') { throw 'GitHub did not publish the controlled draft release' }
}
$release = Wait-ImmutableRelease
Assert-ExactAssets
if ((Get-TagCommit) -cne $CommitSha) {
  throw 'Immutable GitHub release tag differs from the triggering commit'
}
"release-id=$ReleaseId" >> $env:GITHUB_OUTPUT
'release-immutable=true' >> $env:GITHUB_OUTPUT
