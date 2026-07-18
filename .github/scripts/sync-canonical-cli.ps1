[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$MyWallpaperRoot,
  [Parameter(Mandatory = $true)][string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$MyWallpaperRoot = (Resolve-Path -LiteralPath $MyWallpaperRoot).ProviderPath
$SourceCommit = $SourceCommit.ToLowerInvariant()
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'SourceCommit must be a full lowercase Git SHA' }
$ActualCommit = (& git -C $MyWallpaperRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $ActualCommit -cne $SourceCommit) {
  throw 'MyWallpaper checkout does not match SourceCommit'
}
$Remote = (& git -C $MyWallpaperRoot remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '^(?:git@github\.com:|https://github\.com/)MyWallpapers/MyWallpaper(?:\.git)?$') {
  throw 'Canonical release validator must be exported from MyWallpapers/MyWallpaper'
}
$Status = (& git -C $MyWallpaperRoot status --porcelain=v1 --untracked-files=all) -join "`n"
if ($LASTEXITCODE -ne 0 -or -not [string]::IsNullOrWhiteSpace($Status)) {
  throw 'MyWallpaper checkout must be clean before exporting the canonical release validator'
}

Push-Location $MyWallpaperRoot
try {
  corepack pnpm --filter '@mywallpaper/cli' run build:release-validator
  if ($LASTEXITCODE -ne 0) { throw 'Canonical release validator build failed' }
} finally { Pop-Location }

$ArtifactRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../canonical-cli'))
$Staging = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-canonical-cli-$([guid]::NewGuid().ToString('N'))"
$ArchiveTemporary = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-canonical-cli-$([guid]::NewGuid().ToString('N')).zip"
New-Item -ItemType Directory -Path $Staging | Out-Null

function Copy-RegularTree([string]$Source, [string]$Destination, [string]$Filter = '*') {
  $Source = (Resolve-Path -LiteralPath $Source).ProviderPath
  foreach ($Item in Get-ChildItem -LiteralPath $Source -File -Recurse -Filter $Filter | Sort-Object FullName) {
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Canonical release validator source contains a reparse point: $($Item.FullName)"
    }
    $Relative = $Item.FullName.Substring($Source.Length).TrimStart([char[]]@('\', '/'))
    $Output = Join-Path $Destination $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
    Copy-Item -LiteralPath $Item.FullName -Destination $Output
  }
}

function Resolve-NodePackageRoot([string]$FromDirectory, [string]$PackageName) {
  $ResolveScript = @'
const { realpathSync, readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const { dirname, join, resolve } = require('node:path');
const fromDirectory = process.argv[1];
const packageName = process.argv[2];
const request = createRequire(resolve(fromDirectory, 'package.json'));
let current = realpathSync(dirname(request.resolve(packageName)));
while (true) {
  const packageJson = join(current, 'package.json');
  try {
    const parsed = JSON.parse(readFileSync(packageJson, 'utf8'));
    if (parsed.name === packageName) {
      process.stdout.write(current);
      break;
    }
  } catch {}
  const parent = dirname(current);
  if (parent === current) throw new Error(`Could not resolve package root for ${packageName}`);
  current = parent;
}
'@
  $Resolved = (& node -e $ResolveScript $FromDirectory $PackageName).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Resolved)) {
    throw "Could not resolve canonical release validator runtime package: $PackageName"
  }
  return (Resolve-Path -LiteralPath $Resolved).ProviderPath
}

function Assert-PackageIdentity([string]$Root, [string]$ExpectedName, [string]$ExpectedVersion) {
  $Package = Get-Content -LiteralPath (Join-Path $Root 'package.json') -Raw | ConvertFrom-Json
  if ($Package.name -cne $ExpectedName -or $Package.version -cne $ExpectedVersion) {
    throw "Canonical release validator dependency must be $ExpectedName@$ExpectedVersion"
  }
}

try {
  $CliRoot = Join-Path $MyWallpaperRoot 'packages/cli'
  $SdkRoot = Join-Path $MyWallpaperRoot 'packages/sdk-public'
  Copy-RegularTree (Join-Path $CliRoot 'release-dist') (Join-Path $Staging 'cli/dist')
  New-Item -ItemType Directory -Path (Join-Path $Staging 'cli') -Force | Out-Null
  [ordered]@{
    name = '@mywallpaper/release-validator'
    private = $true
    type = 'module'
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Staging 'cli/package.json') -Encoding utf8NoBOM
  Copy-Item -LiteralPath (Join-Path $CliRoot 'LICENSE') -Destination (Join-Path $Staging 'cli/LICENSE')

  $SdkDestination = Join-Path $Staging 'cli/node_modules/@mywallpaper/sdk'
  New-Item -ItemType Directory -Path $SdkDestination -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $SdkRoot 'package.json') -Destination (Join-Path $SdkDestination 'package.json')
  Copy-Item -LiteralPath (Join-Path $SdkRoot 'LICENSE') -Destination (Join-Path $SdkDestination 'LICENSE')
  Copy-RegularTree (Join-Path $SdkRoot 'dist/addon-schema') (Join-Path $SdkDestination 'dist/addon-schema') '*.js'
  Copy-RegularTree (Join-Path $SdkRoot 'dist/protocol') (Join-Path $SdkDestination 'dist/protocol') '*.js'
  Copy-RegularTree (Join-Path $SdkRoot 'dist/generated') (Join-Path $SdkDestination 'dist/generated') '*.js'

  $SharpRoot = Resolve-NodePackageRoot $CliRoot 'sharp'
  $SharpNodeModules = Split-Path -Parent $SharpRoot
  $RuntimePackages = [ordered]@{
    'sharp' = @{ Root = $SharpRoot; Version = '0.35.3' }
    '@img/sharp-win32-x64' = @{ Root = Join-Path $SharpNodeModules '@img/sharp-win32-x64'; Version = '0.35.3' }
    '@img/colour' = @{ Root = Join-Path $SharpNodeModules '@img/colour'; Version = '1.1.0' }
    'detect-libc' = @{ Root = Join-Path $SharpNodeModules 'detect-libc'; Version = '2.1.2' }
    'semver' = @{ Root = Join-Path $SharpNodeModules 'semver'; Version = '7.8.5' }
  }
  foreach ($PackageName in $RuntimePackages.Keys) {
    $PackageRoot = (Resolve-Path -LiteralPath $RuntimePackages[$PackageName].Root).ProviderPath
    Assert-PackageIdentity $PackageRoot $PackageName $RuntimePackages[$PackageName].Version
    Copy-RegularTree $PackageRoot (Join-Path $Staging "cli/node_modules/$PackageName")
  }

  [ordered]@{
    sourceRepository = 'MyWallpapers/MyWallpaper'
    sourceCommit = $SourceCommit
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $Staging 'provenance.json') -Encoding utf8NoBOM

  Add-Type -AssemblyName System.IO.Compression
  $Files = @(Get-ChildItem -LiteralPath $Staging -File -Recurse | Sort-Object FullName)
  $Stream = [IO.File]::Open($ArchiveTemporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $Archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
      foreach ($File in $Files) {
        $Relative = $File.FullName.Substring($Staging.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $Entry = $Archive.CreateEntry($Relative, [IO.Compression.CompressionLevel]::NoCompression)
        $Entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $Input = [IO.File]::OpenRead($File.FullName)
        $Output = $Entry.Open()
        try { $Input.CopyTo($Output) }
        finally { $Output.Dispose(); $Input.Dispose() }
      }
    } finally { $Archive.Dispose() }
  } finally { $Stream.Dispose() }

  New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null
  $ArchivePath = Join-Path $ArtifactRoot 'mywallpaper-cli.zip'
  Move-Item -LiteralPath $ArchiveTemporary -Destination $ArchivePath -Force
  $ArchiveItem = Get-Item -LiteralPath $ArchivePath
  [ordered]@{
    schemaVersion = 1
    sourceRepository = 'MyWallpapers/MyWallpaper'
    sourceCommit = $SourceCommit
    archive = 'mywallpaper-cli.zip'
    size = $ArchiveItem.Length
    sha256 = 'sha256:' + (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ArtifactRoot 'canonical-cli.lock.json') -Encoding utf8NoBOM
} finally {
  Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ArchiveTemporary -Force -ErrorAction SilentlyContinue
}

Write-Host "Exported canonical release validator from MyWallpapers/MyWallpaper@$SourceCommit"
