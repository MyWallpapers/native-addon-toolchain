[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'github-api-contract.ps1')

function Invoke-JsonArrayFixture([string]$Json) {
  return $Json | ConvertFrom-Json -NoEnumerate
}

$rawEmpty = Invoke-JsonArrayFixture '[]'
$legacyEmpty = @(Invoke-JsonArrayFixture '[]')
if ($legacyEmpty.Count -ne 1 -or $legacyEmpty[0] -isnot [Array]) {
  throw 'The regression fixture no longer reproduces nested empty JSON-array output'
}
$empty = ConvertTo-GitHubApiItemList -Response $rawEmpty -Label 'Empty fixture'
if ($empty -isnot [Collections.Generic.List[object]] -or $empty.Count -ne 0) {
  throw 'An empty GitHub JSON array was not normalized to an empty item list'
}

$rawMany = Invoke-JsonArrayFixture '[{"id":1,"name":"first"},{"id":2,"name":"second"}]'
$legacyMany = @(Invoke-JsonArrayFixture '[{"id":1},{"id":2}]')
if ($legacyMany.Count -ne 1 -or $legacyMany[0] -isnot [Array] -or $legacyMany[0].Count -ne 2) {
  throw 'The regression fixture no longer reproduces nested non-empty JSON-array output'
}
$many = ConvertTo-GitHubApiItemList -Response $rawMany -Label 'Many fixture'
if ($many -isnot [Collections.Generic.List[object]] -or $many.Count -ne 2 -or
    [string]$many[0].name -cne 'first' -or [string]$many[1].name -cne 'second') {
  throw 'A non-empty GitHub JSON array was not normalized in order'
}

foreach ($invalid in @(
  [pscustomobject]@{ Label = 'object'; Value = [pscustomobject]@{ id = 1 } },
  [pscustomobject]@{ Label = 'scalar item'; Value = [object[]]@(1) },
  [pscustomobject]@{ Label = 'nested array'; Value = [object[]]@(,[object[]]@(1, 2)) }
)) {
  $rejected = $false
  try {
    $null = ConvertTo-GitHubApiItemList -Response $invalid.Value -Label $invalid.Label
  } catch {
    if (-not $_.Exception.Message.Contains('JSON array', [StringComparison]::Ordinal)) { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw "GitHub API normalization accepted an invalid $($invalid.Label) response" }
}
