$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "mywallpaper-web-component-$([Guid]::NewGuid().ToString('N'))"
$global:mywallpaperWebTestCommands = [Collections.Generic.List[string]]::new()
function corepack { $global:mywallpaperWebTestCommands.Add("corepack $args"); $global:LASTEXITCODE = 0 }
function pnpm { $global:mywallpaperWebTestCommands.Add("pnpm $args"); $global:LASTEXITCODE = 0 }
try {
  $repo = Join-Path $temporary 'source'
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  '{"runtime":"native-v1"}' | Set-Content "$repo/manifest.json"
  & "$PSScriptRoot/build-web-component.ps1" -RepositoryRoot $repo -OutputRoot "$temporary/native"
  if ($global:mywallpaperWebTestCommands.Count -ne 0 -or -not (Test-Path "$temporary/native/web/.empty")) { throw 'Native-only build executed Web tooling' }
  New-Item -ItemType Directory -Path "$temporary/native/hooks", "$temporary/native/companion" | Out-Null
  New-Item -ItemType File -Path "$temporary/native/hooks/.empty", "$temporary/native/companion/.empty" | Out-Null
  & "$PSScriptRoot/materialize-addon-build.ps1" -BuildRoot "$temporary/native" -RepositoryRoot $repo -OperationalMaxFiles 20 -OperationalMaxBytes 1000
  if (Test-Path "$repo/dist") { throw 'Native-only materialization created a Web build' }
  '{"runtime":"service-v1","services":{"entry":"dist/service.js"}}' | Set-Content "$repo/manifest.json"
  New-Item -ItemType Directory -Path "$repo/dist" | Out-Null
  'export function start() {}' | Set-Content "$repo/dist/service.js"
  & "$PSScriptRoot/build-web-component.ps1" -RepositoryRoot $repo -OutputRoot "$temporary/service"
  if (@($global:mywallpaperWebTestCommands | Where-Object { $_ -ceq 'pnpm build' }).Count -ne 1 -or -not (Test-Path "$temporary/service/web/dist/service.js")) { throw 'Service-only Web entry did not build once' }
  $rejected = $false
  try { & "$PSScriptRoot/materialize-addon-build.ps1" -BuildRoot "$temporary/native" -RepositoryRoot $repo -OperationalMaxFiles 20 -OperationalMaxBytes 1000 }
  catch { if ($_.Exception.Message -notlike '*require a Web build*') { throw }; $rejected = $true }
  if (-not $rejected) { throw 'Missing required service Web build was accepted' }
} finally {
  $resolved = [IO.Path]::GetFullPath($temporary)
  $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary test path escapes its parent' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
  Remove-Variable -Name mywallpaperWebTestCommands -Scope Global
}
