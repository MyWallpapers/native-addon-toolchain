param(
  [Parameter(Mandatory)][string]$SubjectPath,
  [Parameter(Mandatory)][string]$BundleArtifactPath,
  [Parameter(Mandatory)][string]$MaterialsArtifactPath,
  [Parameter(Mandatory)][string]$ExpectedMaterialsDigest,
  [Parameter(Mandatory)][long]$ExpectedMaterialsSize,
  [Parameter(Mandatory)][string]$PublicationRequestId,
  [Parameter(Mandatory)][string]$PublicationAttemptId,
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$RunAttempt,
  [Parameter(Mandatory)][hashtable]$Publisher,
  [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')

foreach ($identity in @($PublicationRequestId, $PublicationAttemptId)) {
  if ($identity -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw 'Publication identity must be a canonical UUID'
  }
}
if ($RunId -cnotmatch '^[1-9][0-9]{0,31}$' -or $RunAttempt -cne '1') {
  throw 'A publication result must belong to the first attempt of an exact GitHub run'
}
if ((($Publisher.Keys | Sort-Object) -join ',') -cne 'imageOs,imageVersion,nodeVersion,pwshVersion') {
  throw 'Publisher observations have fields outside the versioned contract'
}
foreach ($observation in $Publisher.Values) {
  if ($observation -isnot [string] -or [string]::IsNullOrWhiteSpace($observation) -or
      $observation -cne $observation.Trim() -or
      [Text.Encoding]::UTF8.GetByteCount($observation) -gt 256 -or
      $observation -match '[\x00-\x1f\x7f]') {
    throw 'GitHub publisher observation is incomplete or invalid'
  }
}
$subjectFile = Get-Item -LiteralPath $SubjectPath -Force
if (($subjectFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $subjectFile.Length -le 0 -or $subjectFile.Length -gt 2MB) {
  throw 'Admission subject must be a bounded regular file'
}
$subjectText = [Text.UTF8Encoding]::new($false, $true).GetString(
  [IO.File]::ReadAllBytes($subjectFile.FullName)
)
$subject = $subjectText | ConvertFrom-Json -Depth 64
$artifact = (Read-ReleaseArtifactDescriptor $BundleArtifactPath 'bundle').Artifact
$materials = (Read-ReleaseArtifactDescriptor $MaterialsArtifactPath 'materials').Artifact
if ($subject.schemaVersion -ne 1 -or $subject.contract -cne 'central-admission-v1' -or
    $subject.publication.requestId -cne $PublicationRequestId -or
    $subject.publication.attemptId -cne $PublicationAttemptId -or
    $subject.artifact.sha256 -cne $artifact.sha256 -or
    $subject.artifact.sizeBytes -ne $artifact.sizeBytes -or
    $subject.build.reproducible -cne $true) {
  throw 'Publication result differs from the verified admission subject'
}
if ($materials.sha256 -cne $ExpectedMaterialsDigest -or
    $materials.sizeBytes -ne $ExpectedMaterialsSize) {
  throw 'Publication materials differ from the verified logical archive'
}

# This is an input for the broker, never a candidate ID or an admission decision.
# The broker binds the observed run and checks the signed subject and artifacts
# before scheduling the existing ingestion and evidence workers.
$result = [ordered]@{
  schemaVersion = 1
  publicationRequestId = $PublicationRequestId
  publicationAttemptId = $PublicationAttemptId
  artifact = $artifact
  materialsArtifact = $materials
  attempt = [ordered]@{
    schemaVersion = 1
    runId = $RunId
    runAttempt = $RunAttempt
    publisher = $Publisher
  }
}
$envelope = $result | ConvertTo-Json -Depth 64 -Compress
# Preserve signed subject strings exactly: PowerShell may parse ISO timestamps
# as DateTime values and normalize them during JSON reserialization.
$bytes = [Text.UTF8Encoding]::new($false).GetBytes(
  $envelope.Substring(0, $envelope.Length - 1) + ',"subject":' + $subjectText + '}'
)
if ($bytes.Length -gt 2MB) { throw 'Publication result exceeds the broker contract budget' }
$stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try { $stream.Write($bytes) } finally { $stream.Dispose() }
[pscustomobject]@{
  ArtifactName = "mywallpaper-publication-result-$PublicationRequestId-$PublicationAttemptId-$RunId-1"
  Path = $OutputPath
}
