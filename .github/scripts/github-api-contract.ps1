function ConvertTo-GitHubApiItemList {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object]$Response,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Label
  )

  if ($null -eq $Response -or $Response -isnot [Array]) {
    throw "$Label did not return a JSON array"
  }

  $items = [Collections.Generic.List[object]]::new()
  foreach ($item in $Response) {
    if ($item -isnot [pscustomobject]) {
      throw "$Label returned an invalid JSON array item"
    }
    $items.Add($item)
  }
  return ,$items
}
