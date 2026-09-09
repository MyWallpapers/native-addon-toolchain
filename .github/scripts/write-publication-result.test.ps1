param([string]$ResultFixturePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('publication-result-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Root | Out-Null
try {
  $Digest = 'sha256:' + ('b' * 64)
  $Sha = 'a' * 40
  $RequestId = '90000000-0000-7000-8000-000000000001'
  $AttemptId = '90000000-0000-7000-8000-000000000002'
  $Subject = [ordered]@{
    schemaVersion = 1
    contract = 'central-admission-v1'
    publication = @{requestId = $RequestId; attemptId = $AttemptId}
    source = @{repositoryId = '123456789'; repository = 'creator/addon'; commitSha = $Sha; ref = 'refs/tags/v1.0.0'}
    release = @{version = '1.0.0'; distributionDigest = $Digest}
    workflow = @{
      repository = 'MyWallpapers/native-addon-toolchain'
      path = '.github/workflows/native-addon-build.yml'
      workflowSha = $Sha
      requestedRef = "MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@$Sha"
    }
    build = @{environmentDigest = $Digest; reproducible = $true}
    artifact = @{sha256 = $Digest; sizeBytes = 100}
    generatedAt = '2026-09-09T16:05:06+02:00'
  }
  $SubjectText = $Subject | ConvertTo-Json -Depth 16 -Compress
  $SubjectPath = Join-Path $Root 'subject.json'
  [IO.File]::WriteAllText($SubjectPath, $SubjectText)
  foreach ($Kind in @('bundle', 'materials')) {
    $Prefix = if ($Kind -eq 'bundle') { 'mywallpaper-addon-bundle' } else { 'mywallpaper-admission-materials' }
    $Name = "$Prefix-sha256-$($Digest.Substring(7)).zip"
    $Descriptor = [ordered]@{
      name = $Name
      sizeBytes = 100L
      sha256 = $Digest
      parts = @([ordered]@{
        id = '77'
        name = "$Name.part-0-sha256-$($Digest.Substring(7))"
        sizeBytes = 100L
        sha256 = $Digest
        index = 0L
      })
    }
    [IO.File]::WriteAllText((Join-Path $Root "$Kind.json"), ($Descriptor | ConvertTo-Json -Depth 8 -Compress))
  }
  $Arguments = @{
    SubjectPath = $SubjectPath
    BundleArtifactPath = Join-Path $Root 'bundle.json'
    MaterialsArtifactPath = Join-Path $Root 'materials.json'
    ExpectedMaterialsDigest = $Digest
    ExpectedMaterialsSize = 100L
    PublicationRequestId = $RequestId
    PublicationAttemptId = $AttemptId
    RunId = '9001'
    RunAttempt = '1'
    Publisher = @{imageOs = 'ubuntu24'; imageVersion = '20260909.1'; nodeVersion = 'v24.14.0'; pwshVersion = '7.5.2'}
    OutputPath = Join-Path $Root 'publication-result-v1.json'
  }
  $Writer = Join-Path $PSScriptRoot 'write-publication-result.ps1'
  $Summary = & $Writer @Arguments
  $Text = [IO.File]::ReadAllText($Arguments.OutputPath)
  $Result = $Text | ConvertFrom-Json
  $ExpectedFields = 'artifact,attempt,materialsArtifact,publicationAttemptId,publicationRequestId,schemaVersion,subject'
  if ((($Result.PSObject.Properties.Name | Sort-Object) -join ',') -cne $ExpectedFields -or
      $Summary.ArtifactName -cne "mywallpaper-publication-result-$RequestId-$AttemptId-9001-1" -or
      $Result.attempt.runId -cne '9001' -or $Result.attempt.runAttempt -cne '1' -or
      $Result.artifact.parts[0].id -cne '77' -or
      -not $Text.Contains('"subject":' + $SubjectText)) {
    throw 'Producer does not satisfy the broker envelope or preserve the signed subject'
  }
  if ($ResultFixturePath) { [IO.File]::WriteAllText($ResultFixturePath, $Text) }

  foreach ($Case in @(
    @{PublicationRequestId = '90000000-0000-7000-8000-000000000003'},
    @{PublicationAttemptId = '90000000-0000-7000-8000-000000000003'},
    @{RunAttempt = '2'},
    @{RunId = '9001/other'},
    @{ExpectedMaterialsDigest = ('sha256:' + ('c' * 64))},
    @{ExpectedMaterialsSize = 101L},
    @{Publisher = @{imageOs = ''; imageVersion = 'v'; nodeVersion = 'v24'; pwshVersion = '7.5'}}
  )) {
    $Invalid = $Arguments.Clone()
    $Invalid.OutputPath = Join-Path $Root ([guid]::NewGuid().ToString() + '.json')
    foreach ($Key in $Case.Keys) { $Invalid[$Key] = $Case[$Key] }
    $Rejected = $false
    try { $null = & $Writer @Invalid } catch { $Rejected = $true }
    if (-not $Rejected -or (Test-Path -LiteralPath $Invalid.OutputPath)) {
      throw "Accepted a substituted publication binding: $($Case.Keys -join ',')"
    }
  }
  $Subject.artifact.sha256 = 'sha256:' + ('c' * 64)
  [IO.File]::WriteAllText($SubjectPath, ($Subject | ConvertTo-Json -Depth 16 -Compress))
  $Arguments.OutputPath = Join-Path $Root 'substituted-bundle.json'
  $Rejected = $false
  try { $null = & $Writer @Arguments } catch { $Rejected = $true }
  if (-not $Rejected) { throw 'Accepted a bundle different from the signed subject' }
  Write-Host 'PASS: broker envelope, exact signed subject, artifact name and eight substituted bindings.'
} finally {
  $ResolvedRoot = [IO.Path]::GetFullPath($Root)
  if (-not $ResolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test cleanup escaped the temporary directory'
  }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}
