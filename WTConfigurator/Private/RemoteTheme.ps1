# Remote discovery and explicit cache synchronization never resolve Terminal settings.
function Assert-PublicPopularity {
    param([object] $Document)
    if (-not $Document.PSObject.Properties['popularity']) { return }
    $metadata = $Document.popularity
    Assert-CatalogObject $metadata @('version','source','catalog_source_revision','flags','order','unmatched','unavailable')
    if ($metadata.version -cne '1' -or $metadata.catalog_source_revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Unsupported popularity metadata version or catalogue revision.' }
    Assert-CatalogObject $metadata.source @('repository','revision','url')
    if ($metadata.source.repository -cne 'Gogh-Co/gogh-website' -or $metadata.source.revision -cnotmatch '^[a-f0-9]{40}$' -or
        $metadata.source.url -cnotmatch '^https://github\.com/Gogh-Co/gogh-website/blob/[a-f0-9]{40}/') { throw 'Invalid Gogh popularity provenance.' }
    if ($metadata.flags -isnot [pscustomobject] -or $metadata.order -isnot [array] -or $metadata.unmatched -isnot [array] -or $metadata.unavailable -isnot [array]) { throw 'Invalid popularity metadata.' }
    $known = @{}
    foreach ($row in (@($Document.entries) + @($Document.excluded))) { $known[$row.id] = $row }
    $positive = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($flag in $metadata.flags.PSObject.Properties) {
        if (-not $known.ContainsKey($flag.Name) -or $known[$flag.Name].source_id -cne 'gogh' -or $flag.Value -isnot [bool]) { throw 'Invalid popularity flag or stable ID.' }
        if ($flag.Value) { [void]$positive.Add($flag.Name) }
    }
    $ordered = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $metadata.order) {
        if ($id -isnot [string] -or -not $positive.Contains($id) -or -not $ordered.Add($id)) { throw 'Invalid popularity declaration order.' }
    }
    if ($positive.Count -ne $ordered.Count) { throw 'Popularity flags and declaration order disagree.' }
}

function Get-PublicPopularityValue {
    param([object] $Index, [string] $Id)
    if ($Index.PSObject.Properties['popularity']) {
        $flag = $Index.popularity.flags.PSObject.Properties[$Id]
        if ($flag) { return $flag.Value }
    }
    return $null
}

function Select-PublicPopularRow {
    param([object] $Index, [object[]] $Rows)
    if (-not $Index.PSObject.Properties['popularity']) {
        throw 'This public catalogue snapshot has no popularity metadata. Refresh the cache after the API update is published; unknown does not mean false.'
    }
    $byId = @{}
    foreach ($row in $Rows) { $byId[$row.id] = $row }
    foreach ($id in $Index.popularity.order) {
        if ($byId.ContainsKey($id)) { $byId[$id] }
    }
}

function Get-WindowsTerminalRemoteTheme {
    <#
    .SYNOPSIS
    Lists all remote terminal themes without changing Windows Terminal settings.
    .DESCRIPTION
    A discoverable PublicCatalog shortcut. Returns summaries, not palette downloads.
    Popular selects only upstream-confirmed Gogh members in declaration order.
    Missing popularity is unknown; an old snapshot cannot satisfy Popular.
    .PARAMETER Popular
    Filter locally by the catalogue's versioned Gogh popularity flags.
    .PARAMETER Search
    Literal substring of the stable ID or display name.
    .PARAMETER CachePath
    Optional validated index cache directory; use Sync-WindowsTerminalTheme for palettes.
    .PARAMETER Offline
    Read only the explicitly chosen cache.
    .PARAMETER IncludeUnavailable
    Include withheld summaries and reasons. No withheld palettes are downloaded.
    .EXAMPLE
    Get-WindowsTerminalRemoteTheme
    .EXAMPLE
    Get-WindowsTerminalRemoteTheme -Popular
    #>
    [CmdletBinding()]
    param([string] $Search, [switch] $Popular, [string] $CachePath, [switch] $Offline, [switch] $IncludeUnavailable)
    Get-PublicTerminalTheme -Search $Search -Popular:$Popular -CachePath $CachePath -Offline:$Offline -IncludeUnavailable:$IncludeUnavailable -NoCacheWrite:$WhatIfPreference
}

function Sync-WindowsTerminalTheme {
    <#
    .SYNOPSIS
    Downloads validated remote terminal palettes into an explicit offline cache.
    .DESCRIPTION
    Fetches the public index once, then each selected compatible palette. It never
    reads or modifies Terminal settings. WhatIf performs no network or cache writes.
    A failure stops the operation and reports progress; completed files remain valid.
    .PARAMETER CachePath
    Required destination for the module's validated response cache.
    .PARAMETER Popular
    Synchronize only confirmed Gogh Popular members.
    .PARAMETER Search
    Literal substring of the stable ID or display name.
    .EXAMPLE
    Sync-WindowsTerminalTheme -CachePath .\theme-cache -Popular
    .EXAMPLE
    Sync-WindowsTerminalTheme -CachePath .\theme-cache -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $CachePath, [switch] $Popular, [string] $Search)
    $destination = [IO.Path]::GetFullPath($CachePath)
    if (-not $PSCmdlet.ShouldProcess($destination, 'Download and validate selected public terminal themes into the cache')) { return }
    $options = @{ CachePath = $destination }
    $root = Read-PublicCatalogDocument -Path 'api/v1/index.json' -Kind Root @options
    $catalog = Read-PublicCatalogDocument -Path $root.Document.categories.terminal.path -Kind Index @options
    $rows = @($catalog.Document.entries)
    if ($Popular) { $rows = @(Select-PublicPopularRow -Index $catalog.Document -Rows $rows) }
    if ($Search) { $rows = @($rows | Where-Object { $_.name.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.id.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    $unsupported = @($rows | Where-Object { $_.source_id -cne 'gogh' -or $_.format -cne 'gogh' })
    if ($unsupported.Count -gt 0) { throw "Cannot sync all selected themes: $($unsupported.Count) available entry/entries have unsupported formats. List Get-WindowsTerminalRemoteTheme to inspect Compatibility. No palettes were downloaded." }
    $completed = 0
    try {
        foreach ($row in $rows) {
            $response = Read-PublicCatalogDocument -Path $row.path -Kind Theme -Entry $row @options
            $saved = Read-PublicCatalogDocument -Path $row.path -Kind Theme -Entry $row -Offline @options
            if ($response.Hash -cne $saved.Hash) { throw 'Cache persistence verification failed.' }
            $completed++
        }
        foreach ($check in @(@{ Path='api/v1/index.json'; Kind='Root'; Hash=$root.Hash }, @{ Path='api/v1/terminal/index.json'; Kind='Index'; Hash=$catalog.Hash })) {
            $saved = Read-PublicCatalogDocument -Path $check.Path -Kind $check.Kind -Offline @options
            if ($saved.Hash -cne $check.Hash) { throw 'Index cache persistence verification failed.' }
        }
    }
    catch { throw "Public theme sync stopped after $completed of $($rows.Count) palettes. Valid completed cache files remain; settings were not changed. $($_.Exception.Message)" }
    [pscustomobject]@{ CachePath=$destination; SyncedCount=$completed; CatalogIndexSHA256=$catalog.Hash; Source='PublicCatalog'; ApiVersion='1' }
}
