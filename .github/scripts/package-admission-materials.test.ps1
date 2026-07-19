[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$packageScript = Join-Path $PSScriptRoot 'package-admission-materials.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-admission-materials-test-$PID-$([Guid]::NewGuid().ToString('N'))"
$evidence = Join-Path $temporary 'evidence'
$originalGithubOutput = $env:GITHUB_OUTPUT
try {
  New-Item -ItemType Directory -Path $evidence | Out-Null
  foreach ($name in @(
    'admission-subject-v1.json',
    'author-inventory.json',
    'bundle-index.json',
    'environment.json',
    'lockfiles.json',
    'payload-inventory.json',
    'provenance.intoto.json',
    'replica-inventories.json',
    'sbom.cdx.json',
    'source-git-tree.txt'
  )) {
    "fixture:$name" | Set-Content -LiteralPath (Join-Path $evidence $name) -Encoding utf8NoBOM
  }
  $env:GITHUB_OUTPUT = Join-Path $temporary 'github-output.txt'
  $first = Join-Path $temporary 'first.zip'
  $second = Join-Path $temporary 'second.zip'
  $budget = @{
    OperationalMaxFiles = 32
    OperationalMaxExpandedBytes = 16MB
    OperationalMaxArchiveBytes = 16MB
  }
  & $packageScript -EvidenceRoot $evidence -OutputArchive $first @budget
  & $packageScript -EvidenceRoot $evidence -OutputArchive $second @budget
  $firstDigest = (Get-FileHash -LiteralPath $first -Algorithm SHA256).Hash
  $secondDigest = (Get-FileHash -LiteralPath $second -Algorithm SHA256).Hash
  if ($firstDigest -cne $secondDigest) {
    throw 'Admission materials packaging is not deterministic'
  }

  Add-Type -AssemblyName System.IO.Compression
  $zip = [IO.Compression.ZipFile]::OpenRead($first)
  try {
    $paths = [string[]]@($zip.Entries.FullName)
    $expected = [string[]]@($paths)
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    if (($paths -join "`n") -cne ($expected -join "`n")) {
      throw 'Admission materials entries are not ordinally sorted'
    }
    if ($zip.Entries.Count -ne 10) { throw 'Admission materials entry count is invalid' }
    if (@($zip.Entries | Where-Object {
      $stamp = $_.LastWriteTime
      $stamp.Year -ne 1980 -or $stamp.Month -ne 1 -or $stamp.Day -ne 1 -or
        $stamp.Hour -ne 0 -or $stamp.Minute -ne 0 -or $stamp.Second -ne 0
    }).Count -ne 0) { throw 'Admission materials timestamps are invalid' }
  } finally { $zip.Dispose() }

  $rejectedInsideRoot = $false
  try {
    & $packageScript -EvidenceRoot $evidence -OutputArchive (Join-Path $evidence 'forbidden.zip') @budget
  } catch {
    if (-not $_.Exception.Message.Contains('outside EvidenceRoot', [StringComparison]::Ordinal)) { throw }
    $rejectedInsideRoot = $true
  }
  if (-not $rejectedInsideRoot) { throw 'Admission materials packager accepted an archive inside its input root' }

  $unexpectedPath = Join-Path $evidence 'unexpected.json'
  '{}' | Set-Content -LiteralPath $unexpectedPath -Encoding utf8NoBOM
  $rejectedUnexpectedFile = $false
  try {
    & $packageScript `
      -EvidenceRoot $evidence `
      -OutputArchive (Join-Path $temporary 'unexpected-forbidden.zip') `
      @budget
  } catch {
    if (-not $_.Exception.Message.Contains('versioned materials contract', [StringComparison]::Ordinal)) { throw }
    $rejectedUnexpectedFile = $true
  } finally {
    Remove-Item -LiteralPath $unexpectedPath -Force
  }
  if (-not $rejectedUnexpectedFile) {
    throw 'Admission materials packager accepted an unexpected evidence file'
  }

  $rejectedOperationalBudget = $false
  try {
    & $packageScript `
      -EvidenceRoot $evidence `
      -OutputArchive (Join-Path $temporary 'budget-forbidden.zip') `
      -OperationalMaxFiles 9 `
      -OperationalMaxExpandedBytes 16MB `
      -OperationalMaxArchiveBytes 16MB
  } catch {
    if (-not $_.Exception.Message.Contains('runner operational file budget', [StringComparison]::Ordinal)) { throw }
    $rejectedOperationalBudget = $true
  }
  if (-not $rejectedOperationalBudget) {
    throw 'Admission materials packager ignored its explicit runner budget'
  }
} finally {
  $env:GITHUB_OUTPUT = $originalGithubOutput
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
