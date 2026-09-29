[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ValidatorRoot)

$ErrorActionPreference = 'Stop'
$validator = Join-Path (Resolve-Path -LiteralPath $ValidatorRoot).ProviderPath 'cli/dist/bin.js'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) { throw 'Expanded canonical validator is missing' }
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporary = Join-Path $temporaryParent ('mywallpaper-canonical-surfaces-' + [Guid]::NewGuid().ToString('N'))
$previousRefType = $env:GITHUB_REF_TYPE
$previousRefName = $env:GITHUB_REF_NAME
try {
  $env:GITHUB_REF_TYPE = 'tag'
  $env:GITHUB_REF_NAME = 'v1.0.0'
  New-Item -ItemType Directory -Path $temporary | Out-Null
  foreach ($runtime in @('canvas-v1', 'canvas-native-v1', 'service-v1', 'native-v1', 'service-native-v1')) {
    $source = Join-Path $temporary $runtime
    New-Item -ItemType Directory -Path $source | Out-Null
    $manifest = [ordered]@{
      runtime = $runtime
      name = "Canonical $runtime fixture"
      description = 'Static validation of the isolated canonical archive; no author code is executed.'
      version = '1.0.0'
      deviceSettingsVersion = '1'
      settings = @()
    }
    'MIT License fixture' | Set-Content -LiteralPath "$source/LICENSE" -Encoding utf8NoBOM
    if ($runtime.StartsWith('canvas-')) {
      $manifest.entry = 'dist/addon.js'
      $manifest.thumbnail = 'assets/thumbnail.png'
      New-Item -ItemType Directory -Path "$source/dist", "$source/assets" | Out-Null
      'export function mount() {}' | Set-Content -LiteralPath "$source/dist/addon.js" -Encoding utf8NoBOM
      Add-Type -AssemblyName System.Drawing
      $bitmap = [Drawing.Bitmap]::new(640, 360)
      try { $bitmap.Save("$source/assets/thumbnail.png", [Drawing.Imaging.ImageFormat]::Png) }
      finally { $bitmap.Dispose() }
    }
    if ($runtime.StartsWith('service-')) {
      $manifest.services = @{ entry = 'dist/service.js'; provides = @{ clock = @{ contract = 'community/clock'; version = 1 } } }
      New-Item -ItemType Directory -Path "$source/dist" | Out-Null
      'export function start() {}' | Set-Content -LiteralPath "$source/dist/service.js" -Encoding utf8NoBOM
    }
    if ($runtime -in @('native-v1', 'service-native-v1', 'canvas-native-v1')) {
      $manifest.native = @{ companion = @{ runtime = 'process-v2'; entries = @{ 'windows-x86_64' = 'native/out/windows-x86_64/companion.exe' } } }
      New-Item -ItemType Directory -Path "$source/native/out/windows-x86_64" -Force | Out-Null
      # PE architecture fixture only, never a runnable companion or release proof.
      $pe = [byte[]]::new(128)
      $pe[0] = 77; $pe[1] = 90; $pe[60] = 64
      $pe[64] = 80; $pe[65] = 69; $pe[68] = 100; $pe[69] = 134
      [IO.File]::WriteAllBytes("$source/native/out/windows-x86_64/companion.exe", $pe)
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$source/manifest.json" -Encoding utf8NoBOM
    node $validator generate --directory $source
    if ($LASTEXITCODE -ne 0) { throw "Canonical generate failed for $runtime" }
    git -C $source init --initial-branch=fixture | Out-Null
    git -C $source config user.name 'Canonical validator fixture'
    git -C $source config user.email 'fixture@mywallpaper.invalid'
    git -C $source config commit.gpgsign false
    git -C $source remote add origin 'https://github.com/MyWallpapers/canonical-fixture.git'
    git -C $source add --all
    git -C $source commit -m 'Canonical surface fixture' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not commit $runtime fixture" }
    $report = (node $validator check --json --directory $source) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $report.ok) {
      throw "Canonical check failed for ${runtime}: $($report | ConvertTo-Json -Depth 10 -Compress)"
    }
    # Prove headless admission does not implicitly require JavaScript tooling,
    # an image or a visual entry. The signed workflow still checks native bytes.
    if (-not $runtime.StartsWith('canvas-') -and (Test-Path -LiteralPath "$source/assets")) { throw 'Unexpected headless thumbnail' }
    if (Test-Path -LiteralPath "$source/package.json") { throw 'Fixture acquired a JavaScript package requirement' }
    Write-Host "Canonical generate/check passed: $runtime"
  }
} finally {
  $env:GITHUB_REF_TYPE = $previousRefType
  $env:GITHUB_REF_NAME = $previousRefName
  $resolved = [IO.Path]::GetFullPath($temporary)
  $prefix = $temporaryParent.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped the temporary directory' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
