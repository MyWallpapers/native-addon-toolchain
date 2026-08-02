[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Repository,
  [Parameter(Mandatory = $true)][string]$TagName,
  [Parameter(Mandatory = $true)][string]$CommitSha,
  [Parameter(Mandatory = $true)][string]$SourceRepository,
  [Parameter(Mandatory = $true)][string]$SourceTagName,
  [Parameter(Mandatory = $true)][string]$SourceCommitSha,
  [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PublicationRequestId = '',
  [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PublicationAttemptId = '',
  [Parameter(Mandatory = $true)][string]$BundleManifest,
  [Parameter(Mandatory = $true)][string]$MaterialsManifest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')
. (Join-Path $PSScriptRoot 'github-api-contract.ps1')
$ApiVersion = '2026-03-10'
$SemVerTagPattern = '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
$PublicationRequestPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
$Headers = @{
  Accept = 'application/vnd.github+json'
  Authorization = "Bearer $env:GITHUB_TOKEN"
  'User-Agent' = 'MyWallpaper-admission-v1'
  'X-GitHub-Api-Version' = $ApiVersion
}

if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$') {
  throw 'Repository is invalid'
}
if ($CommitSha -cnotmatch '^[0-9a-f]{40}$') { throw 'CommitSha must be a lowercase full Git commit SHA' }
if ($SourceRepository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$' -or
    $SourceTagName -cnotmatch $SemVerTagPattern -or
    $SourceCommitSha -cnotmatch '^[0-9a-f]{40}$') {
  throw 'Immutable source identity is invalid'
}
$CentralPublication = -not [string]::IsNullOrEmpty($PublicationRequestId) -or
  -not [string]::IsNullOrEmpty($PublicationAttemptId)
if ($CentralPublication) {
  if ($PublicationRequestId -cnotmatch $PublicationRequestPattern -or
      $PublicationAttemptId -cnotmatch $PublicationRequestPattern -or
      $Repository -cne 'MyWallpapers/native-addon-toolchain' -or
      $TagName -cne "publication-$PublicationAttemptId") {
    throw 'Central transport identity is invalid'
  }
} elseif ($TagName -cnotmatch $SemVerTagPattern -or
          $Repository -cne $SourceRepository -or
          $TagName -cne $SourceTagName -or
          $CommitSha -cne $SourceCommitSha) {
  throw 'Legacy transport must remain identical to its source release'
}
if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'GITHUB_TOKEN is required' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) { throw 'GITHUB_OUTPUT is required' }

$BundleArtifact = (Read-ReleaseArtifactManifest $BundleManifest 'bundle' 1000).Artifact
$MaterialsArtifact = (Read-ReleaseArtifactManifest $MaterialsManifest 'materials' 1000).Artifact
$ExpectedAssetCount = @($BundleArtifact.parts).Count + @($MaterialsArtifact.parts).Count
if ($ExpectedAssetCount -lt 2 -or $ExpectedAssetCount -gt 1000) {
  throw 'Controlled GitHub release exceeds the external 1000-asset limit'
}

$ExpectedReleaseName = if ($CentralPublication) { "$SourceRepository@$SourceTagName" } else { $TagName }
$ExpectedReleaseBody = if ($CentralPublication) {
  [string]::Join("`n", @(
    '<!-- mywallpaper-central-admission-v1 -->',
    "Publication request: $PublicationRequestId",
    "Publication attempt: $PublicationAttemptId",
    "Source repository: $SourceRepository",
    "Source tag: $SourceTagName",
    "Source commit: $SourceCommitSha",
    "Toolchain commit: $CommitSha",
    "Bundle: $($BundleArtifact.sha256)",
    "Materials: $($MaterialsArtifact.sha256)"
  ))
} else {
  [string]::Join("`n", @(
    '<!-- mywallpaper-admission-v1 -->',
    "Source commit: $CommitSha",
    "Bundle: $($BundleArtifact.sha256)",
    "Materials: $($MaterialsArtifact.sha256)"
  ))
}
$ExpectedAssets = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($part in @($BundleArtifact.parts) + @($MaterialsArtifact.parts)) {
  $ExpectedAssets.Add([string]$part.name, [pscustomobject]@{
    Digest = [string]$part.sha256
    Size = [long]$part.sizeBytes
  })
}

function Get-ErrorDetail([object]$Record) {
  if (-not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.Message)) {
    return [string]$Record.ErrorDetails.Message
  }
  return [string]$Record.Exception.Message
}

function Invoke-GitHubGet([string]$Uri, [string]$Label) {
  try {
    return Invoke-RestMethod -Uri $Uri -Headers $Headers -MaximumRedirection 0
  } catch {
    throw "$Label failed: $(Get-ErrorDetail $_)"
  }
}

function Get-TagCommit([string]$TagRepository, [string]$ExpectedTagName) {
  $encodedTag = [Uri]::EscapeDataString($ExpectedTagName)
  $reference = Invoke-GitHubGet `
    "https://api.github.com/repos/$TagRepository/git/ref/tags/$encodedTag" `
    'GitHub tag lookup'
  if ([string]$reference.ref -cne "refs/tags/$ExpectedTagName") { throw 'GitHub returned a different tag ref' }
  $objectSha = [string]$reference.object.sha
  $objectType = [string]$reference.object.type
  if ($objectSha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub tag target SHA is invalid' }
  if ($objectType -ceq 'commit') { return $objectSha }
  if ($objectType -cne 'tag') { throw "GitHub tag has unsupported target type: $objectType" }

  $tagObject = Invoke-GitHubGet `
    "https://api.github.com/repos/$TagRepository/git/tags/$objectSha" `
    'GitHub annotated-tag lookup'
  if ([string]$tagObject.tag -cne $ExpectedTagName) { throw 'GitHub returned a different annotated tag' }
  if ([string]$tagObject.object.type -cne 'commit') {
    throw 'Nested or non-commit annotated tags are not admissible'
  }
  $peeledSha = [string]$tagObject.object.sha
  if ($peeledSha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub annotated-tag commit SHA is invalid' }
  return $peeledSha
}

function Ensure-CentralTransportTag() {
  if (-not $CentralPublication) { return }
  $body = [ordered]@{
    ref = "refs/tags/$TagName"
    sha = $CommitSha
  } | ConvertTo-Json -Depth 3 -Compress
  try {
    $null = Invoke-RestMethod `
      -Method Post `
      -Uri "https://api.github.com/repos/$Repository/git/refs" `
      -Headers $Headers `
      -MaximumRedirection 0 `
      -ContentType 'application/json' `
      -Body ([Text.UTF8Encoding]::new($false).GetBytes($body))
  } catch {
    # A retry or concurrent attempt can win creation. Only an exact subsequent
    # read is trusted; every other 422/permission/network failure still fails.
    if ([int]$_.Exception.Response.StatusCode -ne 422) {
      throw "GitHub central transport tag creation failed: $(Get-ErrorDetail $_)"
    }
  }
  if ((Get-TagCommit $Repository $TagName) -cne $CommitSha) {
    throw 'GitHub central transport tag differs from the frozen toolchain commit'
  }
}

function Get-ReleasesForTag() {
  $matches = [Collections.Generic.List[object]]::new()
  $page = 1
  while ($true) {
    $response = Invoke-GitHubGet `
      "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page" `
      'GitHub release listing'
    $items = ConvertTo-GitHubApiItemList -Response $response -Label 'GitHub release listing'
    foreach ($item in $items) {
      if ([string]$item.tag_name -ceq $TagName) { $matches.Add($item) }
    }
    if ($items.Count -lt 100) { break }
    if ($page -eq [int]::MaxValue) { throw 'GitHub release pagination overflowed' }
    $page++
  }
  return $matches
}

function Get-ReleaseAssets([string]$ReleaseId) {
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

function Resolve-VerifiedAsset([object]$Asset, [string]$Name, [object]$Expected) {
  $id = [string]$Asset.id
  if ($id -cnotmatch '^[1-9][0-9]*$') { throw 'Controlled GitHub release asset ID is invalid' }
  for ($attempt = 0; $attempt -lt 6; $attempt++) {
    if ($attempt -gt 0) {
      Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt - 1)))
      $Asset = Invoke-GitHubGet `
        "https://api.github.com/repos/$Repository/releases/assets/$id" `
        'GitHub release asset digest lookup'
    }
    if (
      [string]$Asset.id -cne $id -or
      [string]$Asset.name -cne $Name -or
      [string]$Asset.state -cne 'uploaded' -or
      [string]$Asset.content_type -cne 'application/octet-stream' -or
      [long]$Asset.size -ne [long]$Expected.Size
    ) { throw 'Controlled GitHub release asset differs from the verified part' }
    $digest = [string]$Asset.digest
    if ($digest -ceq [string]$Expected.Digest) { return }
    if (-not [string]::IsNullOrWhiteSpace($digest)) {
      throw 'Controlled GitHub release asset has a different digest'
    }
  }
  throw 'GitHub did not finish calculating the release asset digest in time'
}

function Assert-AssetSubset([object[]]$Assets, [bool]$RequireComplete) {
  if ($Assets.Count -gt $ExpectedAssets.Count) {
    throw 'Controlled GitHub release contains unexpected assets'
  }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($asset in $Assets) {
    $name = [string]$asset.name
    if (-not $ExpectedAssets.ContainsKey($name) -or -not $seen.Add($name)) {
      throw 'Controlled GitHub release contains an unexpected or duplicate asset'
    }
    $expected = $ExpectedAssets[$name]
    Resolve-VerifiedAsset $asset $name $expected
  }
  if ($RequireComplete -and $seen.Count -ne $ExpectedAssets.Count) {
    throw 'Immutable GitHub release is missing a verified asset'
  }
}

function Assert-ControlledRelease([object]$Release) {
  if ($null -eq $Release) { throw 'Controlled GitHub release is missing' }
  $id = [string]$Release.id
  if (
    $id -cnotmatch '^[1-9][0-9]*$' -or
    [string]$Release.tag_name -cne $TagName -or
    [string]$Release.name -cne $ExpectedReleaseName -or
    [string]$Release.body -cne $ExpectedReleaseBody -or
    [bool]$Release.prerelease
  ) { throw 'GitHub release is not the exact admission-v1 controlled release' }

  if ([bool]$Release.draft) {
    if ([bool]$Release.immutable -or -not [string]::IsNullOrWhiteSpace([string]$Release.published_at)) {
      throw 'GitHub draft release state is inconsistent'
    }
    Assert-AssetSubset @(Get-ReleaseAssets $id) $false
    return [pscustomobject]@{ Id = $id; State = 'draft' }
  }
  if (-not [bool]$Release.immutable) {
    throw 'An already-published mutable GitHub release is never reusable'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Release.published_at)) {
    throw 'Immutable GitHub release has no publication timestamp'
  }
  Assert-AssetSubset @(Get-ReleaseAssets $id) $true
  return [pscustomobject]@{ Id = $id; State = 'immutable' }
}

function New-ControlledRelease() {
  $body = [ordered]@{
    tag_name = $TagName
    target_commitish = $CommitSha
    name = $ExpectedReleaseName
    body = $ExpectedReleaseBody
    draft = $true
    prerelease = $false
    generate_release_notes = $false
  } | ConvertTo-Json -Depth 4 -Compress
  try {
    return Invoke-RestMethod `
      -Method Post `
      -Uri "https://api.github.com/repos/$Repository/releases" `
      -Headers $Headers `
      -MaximumRedirection 0 `
      -ContentType 'application/json' `
      -Body ([Text.UTF8Encoding]::new($false).GetBytes($body))
  } catch {
    $status = [int]$_.Exception.Response.StatusCode
    if ($status -eq 422) { return $null }
    throw "GitHub draft release creation failed: $(Get-ErrorDetail $_)"
  }
}

if ((Get-TagCommit $SourceRepository $SourceTagName) -cne $SourceCommitSha) {
  throw 'GitHub source tag no longer resolves to the frozen source commit'
}
Ensure-CentralTransportTag
$matches = @(Get-ReleasesForTag)
if ($matches.Count -gt 1) { throw 'GitHub returned multiple releases for the same tag' }
$release = if ($matches.Count -eq 1) { $matches[0] } else { New-ControlledRelease }
if ($null -eq $release) {
  # A concurrent rerun can win the create race. Reuse only the exact controlled release.
  $matches = @(Get-ReleasesForTag)
  if ($matches.Count -ne 1) { throw 'Could not resolve the controlled GitHub release after create race' }
  $release = $matches[0]
}
$validated = Assert-ControlledRelease $release
if ((Get-TagCommit $Repository $TagName) -cne $CommitSha) {
  throw 'GitHub transport tag does not resolve to the frozen transport commit'
}
if ((Get-TagCommit $SourceRepository $SourceTagName) -cne $SourceCommitSha) {
  throw 'GitHub source tag changed while preparing the controlled release'
}
"release-id=$($validated.Id)" >> $env:GITHUB_OUTPUT
"release-state=$($validated.State)" >> $env:GITHUB_OUTPUT
