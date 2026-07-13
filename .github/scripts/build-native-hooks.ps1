[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$OutputRoot,
  [string]$ManifestPath = "manifest.json",
  [string]$CompilerRoot
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$LocalLock = Join-Path $PSScriptRoot "windhawk-v1.lock.json"
$LockPath = if (Test-Path -LiteralPath $LocalLock -PathType Leaf) {
  $LocalLock
} else {
  Join-Path $PSScriptRoot "../../components/windhawk-host/runtime/windhawk-v1.lock.json"
}
$Installer = Join-Path $PSScriptRoot "install-windhawk-toolchain.ps1"
$LocalSdk = Join-Path $PSScriptRoot "mywallpaper_windhawk.hpp"
$SdkHeader = if (Test-Path -LiteralPath $LocalSdk -PathType Leaf) {
  $LocalSdk
} else {
  Join-Path $PSScriptRoot "../../components/windhawk-host/sdk/mywallpaper_windhawk.hpp"
}

if ([string]::IsNullOrWhiteSpace($CompilerRoot)) {
  $FingerprintSource = @($LockPath, $Installer, $SdkHeader) | ForEach-Object {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
  }
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $FingerprintBytes = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($FingerprintSource -join "")))
  } finally {
    $Hasher.Dispose()
  }
  $Fingerprint = (($FingerprintBytes | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 24)
  $CacheRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
  } else {
    Join-Path $env:LOCALAPPDATA "MyWallpaper/native-toolchains"
  }
  $CompilerRoot = Join-Path $CacheRoot "windhawk-v1-$Fingerprint"
}
$CompilerRoot = [IO.Path]::GetFullPath($CompilerRoot)

function Assert-WindowsPathSegment([string]$Segment, [string]$Label) {
  $Reserved = @(
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
  )
  if (
    $Segment.Length -eq 0 -or $Segment.Length -gt 255 -or
    $Segment.EndsWith(".") -or $Segment.EndsWith(" ") -or
    $Segment -notmatch '^[A-Za-z0-9._-]+$' -or
    $Reserved -contains (($Segment -split '\.', 2)[0].ToUpperInvariant())
  ) {
    throw "$Label contains a non-canonical Windows path segment: $Segment"
  }
}

function Resolve-RepositoryFile([string]$RelativePath, [string]$Label) {
  if (
    [string]::IsNullOrWhiteSpace($RelativePath) -or
    [IO.Path]::IsPathRooted($RelativePath) -or
    $RelativePath.Contains(":") -or $RelativePath.Contains("\") -or
    [Text.Encoding]::UTF8.GetByteCount($RelativePath) -gt 900
  ) {
    throw "$Label must be a canonical repository-relative path"
  }
  $Segments = @($RelativePath.Split("/"))
  if (@($Segments | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -ne 0) {
    throw "$Label contains an empty, dot, or traversal segment"
  }
  foreach ($Segment in $Segments) { Assert-WindowsPathSegment $Segment $Label }
  $Candidate = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RelativePath.Replace("/", [IO.Path]::DirectorySeparatorChar)))
  $RootPrefix = $RepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escapes the repository"
  }
  if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "$Label does not exist: $RelativePath"
  }
  $Item = Get-Item -LiteralPath $Candidate -Force
  if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label cannot be a symbolic link or reparse point"
  }
  return $Candidate
}

function Assert-PeMachine([string]$Path, [int]$ExpectedMachine) {
  $Stream = [IO.File]::OpenRead($Path)
  try {
    $Reader = [IO.BinaryReader]::new($Stream)
    if ($Reader.ReadUInt16() -ne 0x5A4D) { throw "Hook output is not a PE file: $Path" }
    $Stream.Position = 0x3C
    $PeOffset = $Reader.ReadUInt32()
    if ($PeOffset -gt ($Stream.Length - 6)) { throw "Hook output has an invalid PE header: $Path" }
    $Stream.Position = $PeOffset
    if ($Reader.ReadUInt32() -ne 0x00004550) { throw "Hook output has an invalid PE signature: $Path" }
    $Machine = $Reader.ReadUInt16()
    if ($Machine -ne $ExpectedMachine) {
      throw "Hook output machine 0x$($Machine.ToString('x4')) does not match expected 0x$($ExpectedMachine.ToString('x4'))"
    }
  } finally {
    $Stream.Dispose()
  }
}

function Get-PeImportedDlls([string]$Path) {
  $Stream = [IO.File]::OpenRead($Path)
  try {
    $Reader = [IO.BinaryReader]::new($Stream)
    if ($Reader.ReadUInt16() -ne 0x5a4d) { throw "Native hook is not a PE image: $Path" }
    $Stream.Position = 0x3c
    $PeOffset = [int64]$Reader.ReadUInt32()
    $Stream.Position = $PeOffset
    if ($Reader.ReadUInt32() -ne 0x00004550) { throw "Native hook has an invalid PE signature: $Path" }
    $Stream.Position = $PeOffset + 6
    $SectionCount = [int]$Reader.ReadUInt16()
    $Stream.Position = $PeOffset + 20
    $OptionalHeaderSize = [int]$Reader.ReadUInt16()
    $OptionalHeaderOffset = $PeOffset + 24
    $Stream.Position = $OptionalHeaderOffset
    $Magic = $Reader.ReadUInt16()
    $DataDirectoryOffset = switch ($Magic) {
      0x010b { $OptionalHeaderOffset + 96; break }
      0x020b { $OptionalHeaderOffset + 112; break }
      default { throw "Native hook has an unsupported PE optional header: $Path" }
    }
    $Stream.Position = $DataDirectoryOffset + 8
    $ImportRva = [uint32]$Reader.ReadUInt32()
    $ImportSize = [uint32]$Reader.ReadUInt32()
    if ($ImportRva -eq 0 -or $ImportSize -eq 0) { return @() }

    $Sections = @()
    $SectionTableOffset = $OptionalHeaderOffset + $OptionalHeaderSize
    for ($Index = 0; $Index -lt $SectionCount; $Index++) {
      $Stream.Position = $SectionTableOffset + ($Index * 40) + 8
      $VirtualSize = [uint32]$Reader.ReadUInt32()
      $VirtualAddress = [uint32]$Reader.ReadUInt32()
      $RawSize = [uint32]$Reader.ReadUInt32()
      $RawOffset = [uint32]$Reader.ReadUInt32()
      $Sections += [pscustomobject]@{
        VirtualAddress = $VirtualAddress
        Span = [uint32][Math]::Max($VirtualSize, $RawSize)
        RawOffset = $RawOffset
      }
    }
    $RvaToOffset = {
      param([uint32]$Rva)
      foreach ($Section in $Sections) {
        if ($Rva -ge $Section.VirtualAddress -and $Rva -lt ($Section.VirtualAddress + $Section.Span)) {
          return [int64]($Section.RawOffset + ($Rva - $Section.VirtualAddress))
        }
      }
      throw "Native hook PE import RVA is outside its sections: $Path"
    }

    $ImportOffset = & $RvaToOffset $ImportRva
    $Imports = [Collections.Generic.List[string]]::new()
    for ($Index = 0; $Index -lt 4096; $Index++) {
      $Stream.Position = $ImportOffset + ($Index * 20)
      $OriginalFirstThunk = $Reader.ReadUInt32()
      $TimeDateStamp = $Reader.ReadUInt32()
      $ForwarderChain = $Reader.ReadUInt32()
      $NameRva = [uint32]$Reader.ReadUInt32()
      $FirstThunk = $Reader.ReadUInt32()
      if (($OriginalFirstThunk -bor $TimeDateStamp -bor $ForwarderChain -bor $NameRva -bor $FirstThunk) -eq 0) {
        return @($Imports)
      }
      if ($NameRva -eq 0) { throw "Native hook PE import has no DLL name: $Path" }
      $Stream.Position = & $RvaToOffset $NameRva
      $NameBytes = [Collections.Generic.List[byte]]::new()
      while ($NameBytes.Count -lt 260) {
        $Byte = $Reader.ReadByte()
        if ($Byte -eq 0) { break }
        $NameBytes.Add($Byte)
      }
      if ($NameBytes.Count -eq 0 -or $NameBytes.Count -eq 260) {
        throw "Native hook PE import has an invalid DLL name: $Path"
      }
      $Imports.Add([Text.Encoding]::ASCII.GetString($NameBytes.ToArray()))
    }
    throw "Native hook PE import table is not terminated: $Path"
  } finally {
    $Stream.Dispose()
  }
}

function Assert-PortableHookImports([string]$Path) {
  $System32 = Join-Path $env:SystemRoot "System32"
  foreach ($ImportedDll in @(Get-PeImportedDlls $Path)) {
    $Name = $ImportedDll.ToLowerInvariant()
    $IsApiSet = $Name.StartsWith("api-ms-win-") -or $Name.StartsWith("ext-ms-win-")
    $IsSystemDll = Test-Path -LiteralPath (Join-Path $System32 $ImportedDll) -PathType Leaf
    if ($Name -ne "windhawk.dll" -and -not $IsApiSet -and -not $IsSystemDll) {
      throw "Native hook imports non-system DLL $ImportedDll; hooks must be self-contained except for windhawk.dll"
    }
  }
}

function Escape-CDefine([string]$Value) {
  return $Value.Replace("\", "\\").Replace('"', '\"')
}

$ManifestFile = Resolve-RepositoryFile $ManifestPath "manifest"
$ManifestBytes = [IO.File]::ReadAllBytes($ManifestFile)
$ManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ManifestFile).Hash
$Manifest = [Text.Encoding]::UTF8.GetString($ManifestBytes) | ConvertFrom-Json
$Hooks = @($Manifest.native.hooks)
Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
if ($Hooks.Count -eq 0) {
  New-Item -ItemType File -Path (Join-Path $OutputRoot ".empty") -Force | Out-Null
  Write-Host "Manifest has no Windhawk hooks"
  exit 0
}

$RequiredToolchainFiles = @(
  "bin/clang++.exe", "bin/ld.lld.exe", "include/windhawk_api.h", "include/mods_api_internal.h",
  "include/mywallpaper_windhawk.hpp", "include/windhawk_utils.h",
  "windhawk_exports.def", "x86_64-w64-mingw32/bin/libc++.dll",
  "x86_64-w64-mingw32/bin/libunwind.dll"
)
if (@($RequiredToolchainFiles | Where-Object {
  -not (Test-Path -LiteralPath (Join-Path $CompilerRoot $_) -PathType Leaf)
}).Count -ne 0) {
  & $Installer -Destination $CompilerRoot -LockPath $LockPath -SdkHeader $SdkHeader
}

$Clang = Join-Path $CompilerRoot "bin/clang++.exe"
$Exports = Join-Path $CompilerRoot "windhawk_exports.def"
$Architectures = [ordered]@{
  "windows-x86" = @{ target = "i686-w64-mingw32"; pe = 0x014c }
  "windows-x86_64" = @{ target = "x86_64-w64-mingw32"; pe = 0x8664 }
  "windows-aarch64" = @{ target = "aarch64-w64-mingw32"; pe = 0xaa64 }
}
$ExportNames = @(Get-Content -LiteralPath $Exports | ForEach-Object {
  $Value = $_.Trim()
  if ($Value -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $Value -notin @("LIBRARY", "EXPORTS")) {
    $Value
  } elseif ($Value -and $Value -notmatch '^LIBRARY\s+"windhawk\.dll"$' -and $Value -ne "EXPORTS") {
    throw "Pinned Windhawk export definition contains an unsupported directive: $Value"
  }
})
if ($ExportNames.Count -eq 0) { throw "Pinned Windhawk export definition is empty" }
$SeenIds = @{}
foreach ($Hook in $Hooks) {
  $AllowedFields = @("id", "runtime", "source", "surface")
  foreach ($Property in $Hook.PSObject.Properties) {
    if ($AllowedFields -notcontains $Property.Name) {
      throw "Hook manifests cannot declare $($Property.Name); targets and binary paths are derived by MyWallpaper"
    }
  }
  $HookId = [string]$Hook.id
  $NormalizedHookId = $HookId.ToLowerInvariant()
  if ($HookId -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $SeenIds.ContainsKey($NormalizedHookId)) {
    throw "Windhawk hook id is invalid or duplicated: $HookId"
  }
  $SeenIds[$NormalizedHookId] = $true
  if ($Hook.runtime -ne "windhawk-v1" -or $Hook.surface -ne "windows-shell-v1") {
    throw "Hook $HookId must use windhawk-v1 on windows-shell-v1"
  }
  $SourceRelative = [string]$Hook.source
  if (
    -not $SourceRelative.StartsWith("native/hooks/", [StringComparison]::Ordinal) -or
    -not $SourceRelative.EndsWith(".wh.cpp", [StringComparison]::Ordinal)
  ) {
    throw "Hook $HookId source must be a .wh.cpp file under native/hooks/"
  }
  $Source = Resolve-RepositoryFile $SourceRelative "hook $HookId source"
  if ((Get-Item -LiteralPath $Source).Length -gt 2MB) { throw "Hook $HookId source exceeds 2 MiB" }
  $SourceText = Get-Content -LiteralPath $Source -Raw
  if ($SourceText -match '(?mi)^\s*//\s*@(include|exclude|architecture|compilerOptions)\b') {
    throw "Hook $HookId contains a targeting or compiler directive; MyWallpaper derives these from its surface"
  }

  $IdentityDirectory = Join-Path $OutputRoot ".generated"
  New-Item -ItemType Directory -Path $IdentityDirectory -Force | Out-Null
  $IdentityHeader = Join-Path $IdentityDirectory "$HookId-identity.hpp"
  @(
    "#define WH_MOD 1",
    "#define WH_MOD_ID L`"$(Escape-CDefine $HookId)`"",
    "#define WH_MOD_VERSION L`"$(Escape-CDefine ([string]$Manifest.version))`"",
    "#define MYWALLPAPER_SURFACE_WINDOWS_SHELL_V1 1"
  ) | Set-Content -LiteralPath $IdentityHeader -Encoding ASCII

  foreach ($TargetName in $Architectures.Keys) {
    $Architecture = $Architectures[$TargetName]
    $TargetOutput = Join-Path $OutputRoot "native/out/hooks/$HookId/$TargetName"
    New-Item -ItemType Directory -Path $TargetOutput -Force | Out-Null
    $ImportLibrary = Join-Path $TargetOutput "libwindhawk.a"
    $ImportStubSource = Join-Path $TargetOutput "windhawk-import-stub.cpp"
    $ImportStubDll = Join-Path $TargetOutput "windhawk-import-stub.dll"
    @($ExportNames | ForEach-Object {
      'extern "C" __declspec(dllexport) void {0}() {{}}' -f $_
    }) | Set-Content -LiteralPath $ImportStubSource -Encoding ASCII
    & $Clang -target $Architecture.target -shared -static-libstdc++ -static-libgcc `
      $ImportStubSource $Exports "-Wl,--out-implib,$ImportLibrary" `
      "-Wl,--no-insert-timestamp" "-Wl,--build-id=none" -o $ImportStubDll
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ImportLibrary -PathType Leaf)) {
      throw "Failed to create the pinned Windhawk ABI library for $TargetName"
    }
    $Dll = Join-Path $TargetOutput "$HookId.dll"
    $Arguments = @(
      "-std=c++23", "-O2", "-shared", "-static-libstdc++", "-static-libgcc",
      "-DUNICODE", "-D_UNICODE", "-DWINVER=0x0A00", "-D_WIN32_WINNT=0x0A00",
      "-D_WIN32_IE=0x0A00", "-DNTDDI_VERSION=0x0A000008", "-D__USE_MINGW_ANSI_STDIO=0",
      "-I", (Join-Path $CompilerRoot "include"),
      "-I", (Join-Path $RepositoryRoot "native/generated"),
      "-I", (Split-Path -Parent $Source),
      $ImportLibrary, $Source,
      "-include", $IdentityHeader, "-include", "windhawk_api.h", "-target", $Architecture.target,
      "-lcomctl32", "-lole32", "-loleaut32", "-lruntimeobject",
      "-Wl,--export-all-symbols", "-Wl,--no-insert-timestamp", "-Wl,--build-id=none",
      "-ffile-prefix-map=$RepositoryRoot=.", "-o", $Dll
    )
    & $Clang @Arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Dll -PathType Leaf)) {
      throw "Pinned Windhawk compilation failed for $HookId/$TargetName"
    }
    Assert-PeMachine $Dll $Architecture.pe
    Assert-PortableHookImports $Dll
    Remove-Item -LiteralPath $ImportLibrary -Force
    Remove-Item -LiteralPath $ImportStubSource, $ImportStubDll -Force -ErrorAction SilentlyContinue
    Write-Host "Built $HookId for product surface windows-shell-v1 ($TargetName)"
  }
}

if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ManifestFile).Hash -ne $ManifestSha256) {
  throw "Native hook build modified manifest.json"
}
