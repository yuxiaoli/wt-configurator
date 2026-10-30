# Public API v1 consumer. Only the approved Pages export is a network source.
$script:PublicCatalogRoot = 'https://yuxiaoli.github.io/themes-catalog-api/'

function Assert-CatalogObject {
    param([object] $Value, [string[]] $Fields)
    if ($Value -isnot [pscustomobject]) { throw 'Public catalog contains a non-object value.' }
    foreach ($field in $Fields) {
        if (-not $Value.PSObject.Properties[$field] -or $null -eq $Value.$field) { throw "Public catalog is missing '$field'." }
    }
}

function Assert-CatalogString {
    param([object] $Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1f\x7f]') {
        throw 'Public catalog contains an invalid text field.'
    }
}

function Get-PublicThemePath {
    param([string] $Id)
    $hash = Get-TerminalByteHash -Bytes ([Text.Encoding]::UTF8.GetBytes("terminal`0$Id"))
    return 'api/v1/terminal/themes/' + $hash.ToLowerInvariant() + '.json'
}

function Assert-PublicCatalogDocument {
    param([object] $Document, [ValidateSet('Root','Index','Theme')][string] $Kind, [object] $Entry)
    Assert-CatalogObject $Document @('api_version')
    if ($Document.api_version -isnot [string] -or $Document.api_version -cne '1') { throw 'Unsupported public catalog API version; expected 1.' }
    if ($Kind -eq 'Root') {
        Assert-CatalogObject $Document @('categories')
        Assert-CatalogObject $Document.categories @('terminal')
        Assert-CatalogObject $Document.categories.terminal @('path')
        if ($Document.categories.terminal.path -cne 'api/v1/terminal/index.json') { throw 'Unsupported terminal index path.' }
        return
    }
    Assert-CatalogObject $Document @('category')
    if ($Document.category -cne 'terminal') { throw 'Only the terminal catalog category is supported.' }
    if ($Kind -eq 'Index') {
        Assert-CatalogObject $Document @('entries','excluded','available_count','excluded_count','source_count')
        if ($Document.entries -isnot [array] -or $Document.excluded -isnot [array]) { throw 'Invalid public catalog entry arrays.' }
        foreach ($key in @('available_count','excluded_count','source_count')) {
            if ($Document.$key -isnot [ValueType] -or $Document.$key -is [bool] -or $Document.$key -lt 0 -or [math]::Truncate($Document.$key) -ne $Document.$key) { throw 'Invalid public catalog count.' }
        }
        if ($Document.entries.Count -ne $Document.available_count -or $Document.excluded.Count -ne $Document.excluded_count -or
            $Document.source_count -ne ($Document.available_count + $Document.excluded_count)) { throw 'Public catalog counts do not match its entries.' }
        $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in (@($Document.entries) + @($Document.excluded))) {
            Assert-CatalogObject $row @('id','name','source_id')
            foreach ($key in @('id','name','source_id')) { Assert-CatalogString $row.$key }
            if ($row.id -cnotmatch '^[a-z0-9][a-z0-9_-]*/[a-zA-Z0-9_/-]+$' -or -not $ids.Add($row.id)) { throw 'Invalid or duplicate public catalog ID.' }
        }
        foreach ($row in $Document.entries) {
            Assert-CatalogObject $row @('format','path')
            Assert-CatalogString $row.format
            if ($row.path -cne (Get-PublicThemePath $row.id)) { throw 'Public theme path does not match its stable ID.' }
        }
        foreach ($row in $Document.excluded) { Assert-CatalogObject $row @('reason'); Assert-CatalogString $row.reason }
        return
    }
    Assert-CatalogObject $Document @('theme')
    $theme = $Document.theme
    Assert-CatalogObject $theme @('id','name','source_id','source_theme_id','format','palette','publication','provenance','license')
    foreach ($key in @('id','name','source_id','format')) {
        if ($theme.$key -cne $Entry.$key) { throw "Public theme '$key' differs from the selected index entry." }
    }
    if ($theme.format -cne 'gogh' -or $theme.source_id -cne 'gogh') { throw "Incompatible public theme format '$($theme.format)' from '$($theme.source_id)'." }
    Assert-CatalogObject $theme.palette @('background','foreground','cursor','accent','ansi')
    if ($theme.palette.ansi -isnot [array] -or $theme.palette.ansi.Count -ne 16) { throw 'A compatible terminal palette must contain exactly 16 ANSI colors.' }
    foreach ($color in (@($theme.palette.background,$theme.palette.foreground,$theme.palette.cursor,$theme.palette.accent) + @($theme.palette.ansi))) {
        if ($color -isnot [string] -or $color -cnotmatch '^#[0-9a-fA-F]{6}$') { throw 'Incompatible terminal palette: expected opaque #RRGGBB colors.' }
    }
    Assert-CatalogObject $theme.provenance @('revision','repository','record_sha256')
    Assert-CatalogObject $theme.publication @('source_revision','source_url','license_documents')
    Assert-CatalogObject $theme.license @('expression','documents')
    if ($theme.provenance.revision -cnotmatch '^[a-f0-9]{40}$' -or $theme.publication.source_revision -cne $theme.provenance.revision -or
        $theme.provenance.record_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $theme.source_theme_id -cne $theme.provenance.record_sha256 -or
        $theme.id -cne ('gogh/' + $theme.source_theme_id)) { throw 'Public theme source/version provenance is inconsistent.' }
    foreach ($text in @($theme.provenance.repository,$theme.license.expression)) { Assert-CatalogString $text }
    $sourceUri = $null
    if (-not [uri]::TryCreate($theme.publication.source_url, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -ne 'https') { throw 'Public theme source URL must be HTTPS.' }
    if ($theme.publication.license_documents -isnot [array] -or $theme.publication.license_documents.Count -eq 0) { throw 'Public theme has no retained license notices.' }
    foreach ($path in $theme.publication.license_documents) {
        if ($path -cnotmatch '^licenses/[a-zA-Z0-9.-]+\.txt$') { throw 'Invalid public license document path.' }
    }
}

function Get-PublicCatalogText {
    param([string] $Path)
    # Do not follow redirects, send credentials, disable TLS checks, or fetch upstream/private URLs.
    $request = [Net.HttpWebRequest]::Create($script:PublicCatalogRoot + $Path)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    $request.Accept = 'application/json'
    $request.UserAgent = 'WTConfigurator/1.1'
    $response = $null
    $stream = $null
    $buffer = New-Object byte[] 8192
    $memory = New-Object IO.MemoryStream
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ContentType -notmatch '^application/json(?:;|$)') { throw 'Public catalog response is not HTTP 200 JSON.' }
        $stream = $response.GetResponseStream()
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt 4194304) { throw 'Public catalog response exceeds 4 MiB.' }
            $memory.Write($buffer, 0, $read)
        }
        return (New-Object Text.UTF8Encoding($false,$true)).GetString($memory.ToArray())
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $memory.Dispose()
    }
}

function Read-PublicCatalogDocument {
    param([string] $Path, [string] $Kind, [object] $Entry, [string] $CachePath, [switch] $Offline, [switch] $NoCacheWrite)
    if ($Path -cnotin @('api/v1/index.json','api/v1/terminal/index.json') -and $Path -cnotmatch '^api/v1/terminal/themes/[a-f0-9]{64}\.json$') { throw 'Refusing a path outside the approved public terminal API.' }
    $cacheFile = $null
    if ($CachePath) {
        $key = (Get-TerminalByteHash ([Text.Encoding]::UTF8.GetBytes($script:PublicCatalogRoot + $Path))).ToLowerInvariant()
        $cacheFile = Join-Path ([IO.Path]::GetFullPath($CachePath)) ($key + '.json')
    }
    if ($Offline) {
        if (-not $cacheFile -or -not [IO.File]::Exists($cacheFile)) { throw "Offline public catalog cache is missing '$Path'. Fetch it online with -CachePath first." }
        if ((Get-Item -LiteralPath $cacheFile).Length -gt 4194304) { throw 'Public catalog cache exceeds 4 MiB.' }
        $text = [IO.File]::ReadAllText($cacheFile, (New-Object Text.UTF8Encoding($false,$true)))
    }
    else {
        try { $text = Get-PublicCatalogText $Path }
        catch { throw "Public catalog request failed for '$Path'. Settings were not changed. Use -Offline -CachePath only for an explicitly chosen cached snapshot. $($_.Exception.Message)" }
    }
    $jsonArgs = @{ InputObject = $text; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArgs.DateKind = 'String' }
    $document = ConvertFrom-Json @jsonArgs
    Assert-PublicCatalogDocument -Document $document -Kind $Kind -Entry $Entry
    # An invalid response never replaces a validated cache. A failed cache write is nonfatal.
    if ($cacheFile -and -not $Offline -and -not $NoCacheWrite) {
        $temporary = $cacheFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cacheFile))
            [IO.File]::WriteAllText($temporary, $text, (New-Object Text.UTF8Encoding($false)))
            if ([IO.File]::Exists($cacheFile)) { [IO.File]::Replace($temporary,$cacheFile,$null) }
            else { [IO.File]::Move($temporary,$cacheFile) }
        }
        catch { Write-Warning "Public catalog was validated but its cache could not be saved: $($_.Exception.Message)" }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    return [pscustomobject]@{ Document = $document; Hash = (Get-TerminalByteHash ([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant(); Mode = $(if ($Offline) { 'Offline' } else { 'Online' }) }
}

function Get-PublicTerminalTheme {
    param([string] $Theme, [string] $Search, [string] $CachePath, [switch] $Offline, [switch] $IncludeUnavailable, [switch] $NoCacheWrite)
    $options = @{ CachePath = $CachePath; Offline = $Offline; NoCacheWrite = $NoCacheWrite }
    $root = Read-PublicCatalogDocument -Path 'api/v1/index.json' -Kind Root @options
    $catalog = Read-PublicCatalogDocument -Path $root.Document.categories.terminal.path -Kind Index @options
    $rows = @($catalog.Document.entries)
    if ($Theme) {
        $selector = $Theme.Trim()
        $selected = @($rows | Where-Object { $_.id -ieq $selector })
        if ($selected.Count -eq 0) { $selected = @($rows | Where-Object { $_.name -ieq $selector }) }
        if ($selected.Count -eq 0) {
            $excluded = @($catalog.Document.excluded | Where-Object { $_.id -ieq $selector -or $_.name -ieq $selector })
            if ($excluded.Count -gt 0) { throw "Public theme '$Theme' is withheld: $(($excluded.reason | Select-Object -Unique) -join ', '). It cannot be fetched or applied from this source." }
            throw "Theme '$Theme' is absent from the public terminal catalog. List stable IDs with Get-WindowsTerminalTheme -Source PublicCatalog."
        }
        if ($selected.Count -gt 1) { throw "Theme '$Theme' is ambiguous. Select an ID: $(($selected.id | Sort-Object) -join ', ')." }
        $row = $selected[0]
        if ($row.format -cne 'gogh' -or $row.source_id -cne 'gogh') { throw "Incompatible public theme format '$($row.format)' from '$($row.source_id)'." }
        $response = Read-PublicCatalogDocument -Path $row.path -Kind Theme -Entry $row @options
        $item = $response.Document.theme
        return [pscustomobject][ordered]@{
            PSTypeName = 'WTConfigurator.Theme'; Id = $item.id; DisplayName = $item.name
            FamilyName = $item.source_id; VariantName = $item.name; Mode = 'unknown'
            Source = 'PublicCatalog'; SourceUrl = $item.publication.source_url
            ApiVersion = '1'; CatalogUrl = $script:PublicCatalogRoot + $row.path
            CatalogIndexSHA256 = $catalog.Hash; ContentSHA256 = $response.Hash
            SourceRevision = $item.publication.source_revision; Provenance = $item.provenance
            License = $item.license; LicenseDocuments = @($item.publication.license_documents | ForEach-Object { $script:PublicCatalogRoot + $_ })
            CacheStatus = $response.Mode; Available = $true; Compatibility = 'Validated'
            Palette = [pscustomobject]@{ Background = $item.palette.background; Foreground = $item.palette.foreground; Accent = $item.palette.accent; Cursor = $item.palette.cursor; Ansi = [string[]]@($item.palette.ansi) }
        }
    }
    if ($IncludeUnavailable) { $rows += @($catalog.Document.excluded) }
    foreach ($row in ($rows | Sort-Object name,id)) {
        if ($Search -and $row.name.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and $row.id.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $available = -not [bool]$row.PSObject.Properties['reason']
        $compatibility = if (-not $available) { 'Withheld: ' + $row.reason } elseif ($row.format -ceq 'gogh' -and $row.source_id -ceq 'gogh') { 'RequiresPaletteValidation' } else { 'UnsupportedFormat: ' + $row.format }
        [pscustomobject][ordered]@{
            PSTypeName = 'WTConfigurator.ThemeSummary'; Id = $row.id; DisplayName = $row.name
            Source = 'PublicCatalog'; SourceId = $row.source_id; Available = $available; Compatibility = $compatibility
            ApiVersion = '1'; CatalogIndexSHA256 = $catalog.Hash; CacheStatus = $catalog.Mode
            AvailableCount = $catalog.Document.available_count; WithheldCount = $catalog.Document.excluded_count
        }
    }
}
