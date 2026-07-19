[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$splitter = Join-Path $PSScriptRoot 'split-release-artifact.ps1'
$verifier = Join-Path $PSScriptRoot 'verify-release-artifact-parts.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-release-parts-test-$PID-$([Guid]::NewGuid().ToString('N'))"
$originalGithubOutput = $env:GITHUB_OUTPUT
$originalLastExitCode = $global:LASTEXITCODE
try {
  New-Item -ItemType Directory -Path $temporary | Out-Null
  $env:GITHUB_OUTPUT = Join-Path $temporary 'github-output.txt'
  $source = Join-Path $temporary 'logical.zip'
  $bytes = [byte[]]::new(37)
  for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = [byte](($index * 17) % 251) }
  [IO.File]::WriteAllBytes($source, $bytes)
  $digest = 'sha256:' + (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()

  $first = Join-Path $temporary 'first'
  $second = Join-Path $temporary 'second'
  $global:LASTEXITCODE = 23
  $firstJson = & $splitter -SourcePath $source -Kind bundle -ExpectedDigest $digest `
    -ExpectedSize $bytes.Length -OutputRoot $first -PartSizeBytes 10 -OperationalMaxParts 10
  $firstResult = $firstJson | ConvertFrom-Json
  if ($firstResult.rootDigest -cne $digest -or $firstResult.partCount -ne 4) {
    throw 'Release artifact splitter did not return its successful structured result'
  }
  & $splitter -SourcePath $source -Kind bundle -ExpectedDigest $digest -ExpectedSize $bytes.Length `
    -OutputRoot $second -PartSizeBytes 10 -OperationalMaxParts 10 | Out-Null
  $global:LASTEXITCODE = 29
  $verificationJson = & $verifier -TransportRoot $first -Kind bundle -ExpectedDigest $digest `
    -ExpectedSize $bytes.Length -OperationalMaxParts 10
  $verification = $verificationJson | ConvertFrom-Json
  if ($verification.rootDigest -cne $digest -or $verification.partCount -ne 4) {
    throw 'Release artifact verifier did not return its successful structured result'
  }
  & $verifier -TransportRoot $second -Kind bundle -ExpectedDigest $digest -ExpectedSize $bytes.Length `
    -OperationalMaxParts 10 | Out-Null

  $firstManifest = [IO.File]::ReadAllBytes((Join-Path $first 'artifact.json'))
  $secondManifest = [IO.File]::ReadAllBytes((Join-Path $second 'artifact.json'))
  if ([Convert]::ToBase64String($firstManifest) -cne [Convert]::ToBase64String($secondManifest)) {
    throw 'Release artifact manifest changed across an exact rerun'
  }
  $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($firstManifest) | ConvertFrom-Json
  if (@($manifest.artifact.parts).Count -ne 4) { throw 'Release artifact was not split at the requested boundary' }
  for ($index = 0; $index -lt 4; $index++) {
    $left = Join-Path "$first/parts" $manifest.artifact.parts[$index].name
    $right = Join-Path "$second/parts" $manifest.artifact.parts[$index].name
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($left)) -cne
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($right))) {
      throw 'Release artifact part changed across an exact rerun'
    }
  }

  . (Join-Path $PSScriptRoot 'release-artifact-contract.ps1')
  $descriptorParts = [Collections.Generic.List[object]]::new()
  foreach ($part in @($manifest.artifact.parts)) {
    $descriptorParts.Add([ordered]@{
      id = [string](1000 + [long]$part.index)
      name = [string]$part.name
      sizeBytes = [long]$part.sizeBytes
      sha256 = [string]$part.sha256
      index = [long]$part.index
    })
  }
  $descriptor = [ordered]@{
    name = [string]$manifest.artifact.name
    sizeBytes = [long]$manifest.artifact.sizeBytes
    sha256 = [string]$manifest.artifact.sha256
    parts = $descriptorParts
  }
  $descriptorPath = Join-Path $temporary 'bundle-artifact.json'
  [IO.File]::WriteAllBytes(
    $descriptorPath,
    [Text.UTF8Encoding]::new($false).GetBytes(($descriptor | ConvertTo-Json -Depth 8 -Compress))
  )
  $validatedDescriptor = Read-ReleaseArtifactDescriptor $descriptorPath bundle 10
  if ([string]$validatedDescriptor.Artifact.sha256 -cne $digest -or
      @($validatedDescriptor.Artifact.parts).Count -ne 4) {
    throw 'Release artifact descriptor did not preserve the logical root'
  }

  $corruptPart = Join-Path "$first/parts" $manifest.artifact.parts[2].name
  $corruptBytes = [IO.File]::ReadAllBytes($corruptPart)
  $corruptBytes[0] = $corruptBytes[0] -bxor 0xff
  [IO.File]::WriteAllBytes($corruptPart, $corruptBytes)
  $rejectedCorruption = $false
  try {
    & $verifier -TransportRoot $first -Kind bundle -ExpectedDigest $digest -ExpectedSize $bytes.Length `
      -OperationalMaxParts 10 | Out-Null
  } catch {
    if (-not $_.Exception.Message.Contains('part digest changed', [StringComparison]::Ordinal)) { throw }
    $rejectedCorruption = $true
  }
  if (-not $rejectedCorruption) { throw 'Release artifact verifier accepted a corrupted part' }

  $rejectedPartBudget = $false
  try {
    & $splitter -SourcePath $source -Kind materials -ExpectedDigest $digest -ExpectedSize $bytes.Length `
      -OutputRoot (Join-Path $temporary 'too-many') -PartSizeBytes 10 -OperationalMaxParts 3 | Out-Null
  } catch {
    if (-not $_.Exception.Message.Contains('operational part budget', [StringComparison]::Ordinal)) { throw }
    $rejectedPartBudget = $true
  }
  if (-not $rejectedPartBudget) { throw 'Release artifact splitter ignored the part-count budget' }
} finally {
  $env:GITHUB_OUTPUT = $originalGithubOutput
  $global:LASTEXITCODE = $originalLastExitCode
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
