[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$temporary = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-admission-integration-$PID-$([Guid]::NewGuid().ToString('N'))"
$originalGithubOutput = $env:GITHUB_OUTPUT
$originalGitConfigCount = $env:GIT_CONFIG_COUNT
$originalGitConfigKey = $env:GIT_CONFIG_KEY_0
$originalGitConfigValue = $env:GIT_CONFIG_VALUE_0
try {
  New-Item -ItemType Directory -Path $temporary | Out-Null
  $env:GITHUB_OUTPUT = Join-Path $temporary 'github-output.txt'
  $env:GIT_CONFIG_COUNT = '1'
  $env:GIT_CONFIG_KEY_0 = 'safe.directory'
  $env:GIT_CONFIG_VALUE_0 = $toolchainRoot

  $source = Join-Path $temporary 'source'
  New-Item -ItemType Directory -Path "$source/dist", "$source/assets" -Force | Out-Null
  [ordered]@{
    runtime = 'canvas-v1'
    name = 'Admission fixture'
    description = 'Exercises the public admission-v1 evidence boundary.'
    version = '1.2.3'
    entry = 'dist/index.html'
    thumbnail = 'assets/thumbnail.png'
    settings = @()
    ui = [ordered]@{ pointerEvents = 'none' }
  } | ConvertTo-Json -Depth 8 -Compress |
    Set-Content -LiteralPath "$source/manifest.json" -Encoding utf8NoBOM
  'MIT License fixture' | Set-Content -LiteralPath "$source/LICENSE" -Encoding utf8NoBOM
  '<!doctype html><title>admission fixture</title>' |
    Set-Content -LiteralPath "$source/dist/index.html" -Encoding utf8NoBOM
  [IO.File]::WriteAllBytes("$source/assets/thumbnail.png", [byte[]](1, 2, 3, 4))
  [ordered]@{
    name = 'admission-fixture'
    private = $true
    version = '1.2.3'
    packageManager = 'pnpm@11.12.0'
  } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath "$source/package.json" -Encoding utf8NoBOM
  "lockfileVersion: '9.0'" |
    Set-Content -LiteralPath "$source/pnpm-lock.yaml" -Encoding utf8NoBOM
  git -C $source init --initial-branch=admission | Out-Null
  git -C $source config user.email 'admission-fixture@mywallpaper.invalid'
  git -C $source config user.name 'MyWallpaper admission fixture'
  git -C $source add --all
  git -C $source commit -m 'Create admission fixture' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not commit the admission integration fixture' }
  $commit = (git -C $source rev-parse HEAD).Trim().ToLowerInvariant()
  $workflowSha = (git -C $toolchainRoot rev-parse HEAD).Trim().ToLowerInvariant()

  $primary = Join-Path $temporary 'primary'
  New-Item -ItemType Directory -Path "$primary/web/dist", "$primary/companion", "$primary/hooks" -Force | Out-Null
  Copy-Item -LiteralPath "$source/dist/index.html" -Destination "$primary/web/dist/index.html"
  New-Item -ItemType File -Path "$primary/companion/.empty", "$primary/hooks/.empty" | Out-Null
  $reproduction = Join-Path $temporary 'reproduction'
  Copy-Item -LiteralPath $primary -Destination $reproduction -Recurse

  $archive = Join-Path $temporary 'bundle.zip'
  $metadata = Join-Path $temporary 'bundle-metadata'
  & (Join-Path $PSScriptRoot 'package-addon-bundle.ps1') `
    -RepositoryRoot $source `
    -CompanionRoot "$primary/companion" `
    -HooksRoot "$primary/hooks" `
    -RepositoryId 123456 `
    -RepositoryOwner MyWallpapers `
    -RepositoryName admission-fixture `
    -CommitSha $commit `
    -OutputArchive $archive `
    -OperationalMaxFiles 256 `
    -OperationalMaxExpandedBytes 32MB `
    -OperationalMaxArchiveBytes 32MB `
    -AdmissionMetadataRoot $metadata
  if (
    -not (Test-Path -LiteralPath "$metadata/bundle-index.json" -PathType Leaf) -or
    -not (Test-Path -LiteralPath "$metadata/bundle-payload-inventory.json" -PathType Leaf)
  ) { throw 'Bundle packager did not export admission metadata' }

  $observations = Join-Path $temporary 'observations'
  foreach ($replica in @(1, 2)) {
    $directory = Join-Path $observations "replica-$replica"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [ordered]@{
      schemaVersion = 1
      contract = 'github-hosted-windows-build-observation-v1'
      replica = $replica
      run = [ordered]@{ id = '123456'; attempt = '1' }
      workflowSha = $workflowSha
      runner = [ordered]@{
        environment = 'github-hosted'
        label = 'windows-2025'
        operatingSystem = 'Windows'
        architecture = 'X64'
        imageOs = 'win25'
        imageVersion = '20260719.1'
      }
      tools = [ordered]@{
        node = [ordered]@{ version = 'v22.22.3' }
        powershell = [ordered]@{ version = '7.5.2' }
        rust = [ordered]@{
          rustc = [ordered]@{
            sha256 = 'sha256:' + ''.PadLeft(64, '1')
            version = "rustc 1.90.0 (fixture)`nhost: x86_64-pc-windows-msvc`nrelease: 1.90.0"
          }
          cargo = [ordered]@{
            sha256 = 'sha256:' + ''.PadLeft(64, '2')
            version = "cargo 1.90.0 (fixture)`nrelease: 1.90.0"
          }
        }
        msvc = [ordered]@{
          toolsetVersion = '14.44.35207'
          linker = [ordered]@{
            sha256 = 'sha256:' + ''.PadLeft(64, '3')
            version = '14.44.35207'
            fileVersion = '14.44.35207.1'
          }
        }
        windowsSdk = [ordered]@{ availableVersions = @('10.0.26100.0') }
        windhawk = [ordered]@{
          used = $false
          windhawkCommit = ''.PadLeft(40, '4')
          archiveSha256 = 'sha256:' + ''.PadLeft(64, '5')
          clang = $null
          linker = $null
        }
      }
    } | ConvertTo-Json -Depth 16 -Compress |
      Set-Content -LiteralPath "$directory/replica.json" -Encoding utf8NoBOM
  }

  function New-AdmissionEvidence([string]$OutputRoot) {
    $result = node (Join-Path $PSScriptRoot 'create-admission-evidence.mjs') `
      --repository-root $source `
      --primary-root $primary `
      --reproduction-root $reproduction `
      --replica-observations-root $observations `
      --bundle-index "$metadata/bundle-index.json" `
      --payload-inventory "$metadata/bundle-payload-inventory.json" `
      --archive $archive `
      --toolchain-root $toolchainRoot `
      --repository-id 123456 `
      --repository-name MyWallpapers/admission-fixture `
      --commit-sha $commit `
      --release-ref refs/tags/v1.2.3 `
      --workflow-ref "MyWallpapers/native-addon-toolchain/.github/workflows/native-addon-build.yml@$workflowSha" `
      --workflow-sha $workflowSha `
      --run-id 123456 `
      --run-attempt 1 `
      --runner-observation-output "$OutputRoot-runner-observation.json" `
      --operational-max-files 256 `
      --operational-max-expanded-bytes (32MB) `
      --operational-max-metadata-bytes (16MB) `
      --output-root $OutputRoot
    if ($LASTEXITCODE -ne 0) { throw 'Admission integration evidence generation failed' }
    return $result
  }

  $evidenceRoot = Join-Path $temporary 'evidence'
  $rerunEvidenceRoot = Join-Path $temporary 'evidence-rerun'
  $summaryJson = New-AdmissionEvidence $evidenceRoot
  $null = New-AdmissionEvidence $rerunEvidenceRoot
  $summary = $summaryJson | ConvertFrom-Json
  $subjectDigest = 'sha256:' + (Get-FileHash -LiteralPath $summary.subjectPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($subjectDigest -cne $summary.subjectDigest -or $summary.authorInventory.fileCount -ne 4) {
    throw 'Admission integration subject is inconsistent'
  }

  $firstMaterials = Join-Path $temporary 'materials-first.zip'
  $secondMaterials = Join-Path $temporary 'materials-second.zip'
  & (Join-Path $PSScriptRoot 'package-admission-materials.ps1') `
    -EvidenceRoot $rerunEvidenceRoot `
    -OutputArchive $firstMaterials `
    -OperationalMaxFiles 256 `
    -OperationalMaxExpandedBytes 32MB `
    -OperationalMaxArchiveBytes 32MB
  & (Join-Path $PSScriptRoot 'package-admission-materials.ps1') `
    -EvidenceRoot $evidenceRoot `
    -OutputArchive $secondMaterials `
    -OperationalMaxFiles 256 `
    -OperationalMaxExpandedBytes 32MB `
    -OperationalMaxArchiveBytes 32MB
  if (
    (Get-FileHash -LiteralPath $firstMaterials -Algorithm SHA256).Hash -cne
    (Get-FileHash -LiteralPath $secondMaterials -Algorithm SHA256).Hash
  ) { throw 'Admission integration materials are not deterministic' }

  function New-Transport([string]$Source, [string]$Kind, [string]$Output) {
    $item = Get-Item -LiteralPath $Source
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    & (Join-Path $PSScriptRoot 'split-release-artifact.ps1') `
      -SourcePath $Source `
      -Kind $Kind `
      -ExpectedDigest $digest `
      -ExpectedSize $item.Length `
      -OutputRoot $Output `
      -PartSizeBytes 128 `
      -OperationalMaxParts 1000 | Out-Null
    & (Join-Path $PSScriptRoot 'verify-release-artifact-parts.ps1') `
      -TransportRoot $Output `
      -Kind $Kind `
      -ExpectedDigest $digest `
      -ExpectedSize $item.Length `
      -OperationalMaxParts 1000 | Out-Null
  }
  function Assert-TransportIdentical([string]$First, [string]$Second, [string]$Label) {
    $firstManifestBytes = [IO.File]::ReadAllBytes((Join-Path $First 'artifact.json'))
    $secondManifestBytes = [IO.File]::ReadAllBytes((Join-Path $Second 'artifact.json'))
    if ([Convert]::ToBase64String($firstManifestBytes) -cne
        [Convert]::ToBase64String($secondManifestBytes)) {
      throw "$Label transport manifest changed across an exact rerun"
    }
    $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($firstManifestBytes) | ConvertFrom-Json
    if (@($manifest.artifact.parts).Count -lt 2) { throw "$Label fixture did not exercise multipart transport" }
    foreach ($part in @($manifest.artifact.parts)) {
      $firstBytes = [IO.File]::ReadAllBytes((Join-Path "$First/parts" $part.name))
      $secondBytes = [IO.File]::ReadAllBytes((Join-Path "$Second/parts" $part.name))
      if ([Convert]::ToBase64String($firstBytes) -cne [Convert]::ToBase64String($secondBytes)) {
        throw "$Label transport part changed across an exact rerun"
      }
    }
  }

  $bundleTransportFirst = Join-Path $temporary 'bundle-transport-first'
  $bundleTransportSecond = Join-Path $temporary 'bundle-transport-second'
  New-Transport $archive bundle $bundleTransportFirst
  New-Transport $archive bundle $bundleTransportSecond
  Assert-TransportIdentical $bundleTransportFirst $bundleTransportSecond 'Bundle'

  $materialsTransportFirst = Join-Path $temporary 'materials-transport-first'
  $materialsTransportSecond = Join-Path $temporary 'materials-transport-second'
  New-Transport $firstMaterials materials $materialsTransportFirst
  New-Transport $secondMaterials materials $materialsTransportSecond
  Assert-TransportIdentical $materialsTransportFirst $materialsTransportSecond 'Materials'
} finally {
  $env:GITHUB_OUTPUT = $originalGithubOutput
  $env:GIT_CONFIG_COUNT = $originalGitConfigCount
  $env:GIT_CONFIG_KEY_0 = $originalGitConfigKey
  $env:GIT_CONFIG_VALUE_0 = $originalGitConfigValue
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
