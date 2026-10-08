#requires -Version 7.4

function Get-WTCatalogHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function ConvertTo-WTCatalogContent {
    param([Parameter(Mandatory)] $Value)
    $json = ($Value | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    return ,([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Assert-WTCatalogColor {
    param([Parameter(Mandatory)][string] $Color, [string] $Context = 'palette')
    if ($Color -cnotmatch '^#[0-9A-F]{6}$') {
        throw "Unsupported color '$Color' in $Context. Catalog v1 requires uppercase six-digit RGB colors; alpha is unsupported."
    }
}

function Assert-WTCatalogSnapshot {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Snapshot,
        [string] $SchemaPath = (Join-Path $PSScriptRoot '../data/terminal-themes.schema.json')
    )
    $json = $Snapshot | ConvertTo-Json -Depth 100
    if (-not (Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw 'Catalog snapshot does not satisfy its schema.'
    }
    if ($Snapshot.status -ne 'complete' -or -not $Snapshot.discovery.complete -or $Snapshot.failures.Count -ne 0) {
        throw 'Only complete snapshots with complete discovery and no failures can be promoted.'
    }
    $dates = @{}
    foreach ($field in @('started_at', 'finished_at')) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($Snapshot[$field], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $parsed) -or -not $Snapshot[$field].EndsWith('Z')) {
            throw "Invalid UTC timestamp in '$field'."
        }
        $dates[$field] = $parsed
    }
    if ($dates.finished_at -lt $dates.started_at) { throw 'Snapshot finished_at precedes started_at.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $labels = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($theme in $Snapshot.themes) {
        if (-not $ids.Add($theme.id)) { throw "Duplicate theme ID '$($theme.id)'." }
        if ($theme.id -cne "$($theme.family_id)/$($theme.variant_id)") { throw "Theme ID '$($theme.id)' does not match its family and variant." }
        if (-not $labels.Add("$($theme.family_name) $($theme.name)")) { throw "Duplicate full theme name '$($theme.family_name) $($theme.name)'." }
        foreach ($role in @('background', 'foreground', 'accent')) { Assert-WTCatalogColor -Color $theme.palette[$role] -Context "$($theme.id).$role" }
        foreach ($color in $theme.palette.ansi) { Assert-WTCatalogColor -Color $color -Context "$($theme.id).ansi" }
        foreach ($url in $theme.originals.Values) {
            if (-not $Snapshot.documents.Contains($url)) { throw "Missing original document '$url' for '$($theme.id)'." }
        }
    }
    if ($null -eq $Snapshot.discovery.expected_count -or $Snapshot.discovery.expected_count -ne $ids.Count -or -not $ids.SetEquals([string[]] $Snapshot.discovery.theme_ids)) {
        throw 'Discovery coverage does not match expected_count and exported theme IDs.'
    }
    foreach ($url in $Snapshot.documents.Keys) {
        $document = $Snapshot.documents[$url]
        $fetched = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($document.fetched_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $fetched) -or -not $document.fetched_at.EndsWith('Z')) {
            throw "Invalid fetched_at timestamp in '$url'."
        }
        if ($fetched -gt $dates.finished_at) { throw "Source document '$url' was fetched after snapshot finished_at." }
        $hash = Get-WTCatalogHash -Bytes ([Text.Encoding]::UTF8.GetBytes($document.text))
        if ($hash -cne $document.sha256) { throw "Source document hash mismatch for '$url'." }
    }
}

function Read-WTCatalogSnapshot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $SchemaPath = (Join-Path $PSScriptRoot '../data/terminal-themes.schema.json')
    )
    $json = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path), [Text.Encoding]::UTF8)
    $snapshot = $json | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    # ConvertFrom-Json turns ISO dates into DateTime on older PowerShell 7 hosts.
    # Preserve the original JSON strings without requiring the 7.5 DateKind switch.
    $document = [Text.Json.JsonDocument]::Parse($json)
    try {
        foreach ($field in @('started_at', 'finished_at')) { $snapshot[$field] = $document.RootElement.GetProperty($field).GetString() }
        foreach ($property in $document.RootElement.GetProperty('documents').EnumerateObject()) {
            $snapshot.documents[$property.Name].fetched_at = $property.Value.GetProperty('fetched_at').GetString()
        }
    }
    finally { $document.Dispose() }
    Assert-WTCatalogSnapshot -Snapshot $snapshot -SchemaPath $SchemaPath
    return $snapshot
}

function ConvertTo-WTRuntimeCatalog {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Snapshot)
    $themesById = @{}
    foreach ($theme in $Snapshot.themes) { $themesById[$theme.id] = $theme }
    [string[]] $sortedIds = @($themesById.Keys)
    [Array]::Sort($sortedIds, [StringComparer]::Ordinal)
    $themes = foreach ($id in $sortedIds) {
        $theme = $themesById[$id]
        [ordered]@{
            id = $theme.id; family_id = $theme.family_id; variant_id = $theme.variant_id
            family_name = $theme.family_name; name = $theme.name; url = $theme.url; mode = $theme.mode
            palette = [ordered]@{
                background = $theme.palette.background; foreground = $theme.palette.foreground
                accent = $theme.palette.accent; ansi = @($theme.palette.ansi)
            }
        }
    }
    return [ordered]@{
        schema_version = '1.0'
        source = [ordered]@{ id = $Snapshot.source.id; url = $Snapshot.source.url }
        captured_at = $Snapshot.finished_at
        themes = @($themes)
    }
}

function Invoke-WTCatalogFileCommit {
    param([Parameter(Mandatory)][string] $TemporaryPath, [Parameter(Mandatory)][string] $DestinationPath)
    if ([IO.File]::Exists($DestinationPath)) { [IO.File]::Replace($TemporaryPath, $DestinationPath, [NullString]::Value) }
    else { [IO.File]::Move($TemporaryPath, $DestinationPath) }
}

function Write-WTCatalogTransaction {
    param([Parameter(Mandatory)][object[]] $Artifacts)
    $staged = [Collections.Generic.List[object]]::new()
    $committed = [Collections.Generic.List[object]]::new()
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($artifact in $Artifacts) {
            $path = [IO.Path]::GetFullPath($artifact.Path)
            if (-not $paths.Add($path)) { throw 'Snapshot and runtime output paths must be different.' }
            $oldBytes = if ([IO.File]::Exists($path)) { ,([IO.File]::ReadAllBytes($path)) } else { $null }
            $oldHash = if ($null -ne $oldBytes) { Get-WTCatalogHash -Bytes $oldBytes } else { $null }
            if ($artifact.PSObject.Properties['ExpectedHash'] -and $artifact.ExpectedHash -cne $oldHash) { throw "Catalog '$path' changed while refresh was prepared." }
            $directory = [IO.Path]::GetDirectoryName($path)
            [void] [IO.Directory]::CreateDirectory($directory)
            $temporary = Join-Path $directory ('.catalog-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($temporary, $artifact.Bytes)
            $staged.Add([pscustomobject]@{ Path = $path; Temporary = $temporary; OldBytes = $oldBytes; OldHash = $oldHash; NewHash = (Get-WTCatalogHash -Bytes $artifact.Bytes) })
        }
        foreach ($item in $staged) {
            $currentHash = if ([IO.File]::Exists($item.Path)) { Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($item.Path)) } else { $null }
            if ($currentHash -cne $item.OldHash) { throw "Catalog '$($item.Path)' changed while refresh was prepared." }
            Invoke-WTCatalogFileCommit -TemporaryPath $item.Temporary -DestinationPath $item.Path
            $committed.Add($item)
        }
    }
    catch {
        $failure = $_
        $recoveryErrors = [Collections.Generic.List[string]]::new()
        for ($index = $committed.Count - 1; $index -ge 0; $index--) {
            $item = $committed[$index]
            $recoveryPath = Join-Path ([IO.Path]::GetDirectoryName($item.Path)) ('.catalog-{0}.recovery' -f [guid]::NewGuid().ToString('N'))
            try {
                if ($null -ne $item.OldBytes) { [IO.File]::WriteAllBytes($recoveryPath, $item.OldBytes) }
                $currentHash = if ([IO.File]::Exists($item.Path)) { Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($item.Path)) } else { $null }
                if ($currentHash -cne $item.NewHash) { throw "Concurrent change prevents rollback of '$($item.Path)'; original recovery file: '$recoveryPath'." }
                if ($null -eq $item.OldBytes) { [IO.File]::Delete($item.Path) }
                else { Invoke-WTCatalogFileCommit -TemporaryPath $recoveryPath -DestinationPath $item.Path }
            }
            catch { $recoveryErrors.Add("$($_.Exception.Message) Recovery file: '$recoveryPath'.") }
        }
        if ($recoveryErrors.Count -gt 0) { throw "$($failure.Exception.Message) Rollback needs attention: $($recoveryErrors -join ' ')" }
        throw $failure
    }
    finally {
        foreach ($item in $staged) { if ([IO.File]::Exists($item.Temporary)) { [IO.File]::Delete($item.Temporary) } }
    }
}

function Get-WTAstroThemeProperty {
    param([Parameter(Mandatory)][string] $Html)
    foreach ($tag in [regex]::Matches($Html, '<astro-island\b[^>]*>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $match = [regex]::Match($tag.Value, '\bprops\s*=\s*(["''])(?<value>.*?)\1', [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $match.Success) { continue }
        $props = [Net.WebUtility]::HtmlDecode($match.Groups['value'].Value) | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
        if ($props.Contains('theme')) { $props }
    }
}

function Get-WTCatalogDocument {
    param([Parameter(Mandatory)][string] $Url, [System.Collections.IDictionary] $ReplayDocuments)
    $uri = [uri] $Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'terminalcolors.com' -or $uri.AbsolutePath.StartsWith('/downloads/', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsupported catalog source URL '$Url'."
    }
    if ($null -ne $ReplayDocuments) {
        if (-not $ReplayDocuments.Contains($Url)) { throw "Replay source is missing '$Url'." }
        return $ReplayDocuments[$Url]
    }
    $response = Invoke-WebRequest -Uri $Url -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop
    $text = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string] $response.Content }
    return [ordered]@{
        text = $text; media_type = ([string] $response.Headers['Content-Type']).Split(';')[0]
        encoding = 'utf-8'; fetched_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        sha256 = Get-WTCatalogHash -Bytes ([Text.Encoding]::UTF8.GetBytes($text))
    }
}

function ConvertFrom-WTCatalogSvg {
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][string] $ThemeId)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($Text), $settings)
    try {
        $xml = [Xml.XmlDocument]::new()
        $xml.XmlResolver = $null
        $xml.Load($reader)
    }
    catch { throw "Invalid SVG for '$ThemeId': $($_.Exception.Message)" }
    finally { $reader.Dispose() }
    if ($xml.DocumentElement.LocalName -ne 'svg' -or $xml.DocumentElement.NamespaceURI -ne 'http://www.w3.org/2000/svg') { throw "Invalid SVG root for '$ThemeId'." }
    $backgrounds = @($xml.SelectNodes('//*[local-name()="rect" and @x="0" and @y="0" and @width="500" and @height="300"]'))
    if ($backgrounds.Count -ne 1) { throw "SVG for '$ThemeId' has no unambiguous background sample." }
    $background = $backgrounds[0].GetAttribute('fill').ToUpperInvariant()
    Assert-WTCatalogColor -Color $background -Context "$ThemeId background"
    $colors = @{}
    foreach ($row in $xml.SelectNodes('//*[local-name()="text"]')) {
        $label = $row.SelectSingleNode('./*[local-name()="tspan"][1]')
        if ($null -ne $label -and $label.InnerText -cmatch '^(?<bright>1;)?3(?<index>[0-7])m$') {
            $index = [int] $Matches.index
            if ($Matches.bright) { $index += 8 }
            if ($colors.ContainsKey($index)) { throw "Duplicate ANSI index $index in SVG for '$ThemeId'." }
            $color = $row.GetAttribute('fill').ToUpperInvariant()
            Assert-WTCatalogColor -Color $color -Context "$ThemeId ANSI $index"
            $colors[$index] = $color
        }
    }
    if ($colors.Count -ne 16) { throw "SVG for '$ThemeId' contains $($colors.Count) ANSI indices; expected all 16." }
    $foregrounds = @($xml.SelectNodes('//*[local-name()="text" and @x="90" and @y="15"]'))
    if ($foregrounds.Count -ne 1) { throw "SVG for '$ThemeId' has no unambiguous foreground sample." }
    $foreground = $foregrounds[0].GetAttribute('fill').ToUpperInvariant()
    Assert-WTCatalogColor -Color $foreground -Context "$ThemeId foreground"
    return [ordered]@{ background = $background; foreground = $foreground; ansi = @(0..15 | ForEach-Object { $colors[$_] }) }
}

function Get-WTCatalogSnapshot {
    param([System.Collections.IDictionary] $ReplaySnapshot)
    $started = if ($null -ne $ReplaySnapshot) { $ReplaySnapshot.started_at } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $replayDocuments = if ($null -ne $ReplaySnapshot) { $ReplaySnapshot.documents } else { $null }
    $documents = [ordered]@{}
    $baseUrl = 'https://terminalcolors.com/'
    foreach ($url in @($baseUrl, ($baseUrl + 'robots.txt'), ($baseUrl + 'tags/dark/'), ($baseUrl + 'tags/light/'))) {
        $documents[$url] = Get-WTCatalogDocument -Url $url -ReplayDocuments $replayDocuments
    }
    $families = @{}
    $expected = 0
    foreach ($props in Get-WTAstroThemeProperty -Html $documents[$baseUrl].text) {
        $family = $props.theme[1]
        $id = [string] $family.id[1]
        if ($id -cnotmatch '^[a-z0-9][a-z0-9_-]*$' -or -not $family.Contains('totalVariants') -or [int] $family.totalVariants[1] -lt 1) { throw 'Homepage catalog structure is unsupported.' }
        if ($families.ContainsKey($id)) { throw "Duplicate homepage family '$id'." }
        $families[$id] = $family
        $expected += [int] $family.totalVariants[1]
    }
    if ($families.Count -eq 0) { throw 'Homepage contains no discoverable theme families.' }
    $modes = @{}
    foreach ($mode in @('dark', 'light')) {
        $tagProps = @(Get-WTAstroThemeProperty -Html $documents[($baseUrl + "tags/$mode/")].text)
        if ($tagProps.Count -eq 0) { throw "Mode tag page '$mode' contains no recognizable theme records." }
        foreach ($props in $tagProps) {
            $family = $props.theme[1]
            foreach ($wrapper in $family.variants[1]) {
                $id = "$($family.id[1])/$($wrapper[1].id[1])"
                if ($modes.ContainsKey($id) -and $modes[$id] -ne $mode) { throw "Theme '$id' appears in both mode tags." }
                $modes[$id] = $mode
            }
        }
    }
    [string[]] $familyIds = @($families.Keys)
    [Array]::Sort($familyIds, [StringComparer]::Ordinal)
    $themesById = @{}
    foreach ($familyId in $familyIds) {
        $familyUrl = $baseUrl + "themes/$familyId/"
        $documents[$familyUrl] = Get-WTCatalogDocument -Url $familyUrl -ReplayDocuments $replayDocuments
        $detailProps = @(Get-WTAstroThemeProperty -Html $documents[$familyUrl].text | Where-Object { $_.Contains('currentVariant') -and $_.theme[1].id[1] -ceq $familyId })
        if ($detailProps.Count -ne 1) { throw "Family '$familyId' has no unambiguous detail catalog." }
        $family = $detailProps[0].theme[1]
        if ($family.variants[1].Count -ne [int] $families[$familyId].totalVariants[1]) { throw "Partial variant coverage for family '$familyId'." }
        foreach ($wrapper in $family.variants[1]) {
            $variant = $wrapper[1]
            $variantId = [string] $variant.id[1]
            if ($variantId -cnotmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Unsupported variant ID in '$familyId'." }
            $id = "$familyId/$variantId"
            if ($themesById.ContainsKey($id)) { throw "Duplicate discovered theme '$id'." }
            $svgUrl = $baseUrl + "images/colors/$familyId-$variantId.svg"
            $documents[$svgUrl] = Get-WTCatalogDocument -Url $svgUrl -ReplayDocuments $replayDocuments
            $palette = ConvertFrom-WTCatalogSvg -Text $documents[$svgUrl].text -ThemeId $id
            $background = ([string] $variant.background[1]).ToUpperInvariant()
            $accent = ([string] $variant.accent[1]).ToUpperInvariant()
            Assert-WTCatalogColor -Color $background -Context "$id background"
            Assert-WTCatalogColor -Color $accent -Context "$id accent"
            if ($background -cne $palette.background) { throw "Background differs between family HTML and SVG for '$id'." }
            $themesById[$id] = [ordered]@{
                id = $id; family_id = $familyId; variant_id = $variantId; family_name = $family.name[1]
                name = $variant.name[1]; url = $baseUrl + "themes/$familyId/$variantId/"
                mode = $(if ($modes.ContainsKey($id)) { $modes[$id] } else { 'unknown' })
                palette = [ordered]@{ background = $background; foreground = $palette.foreground; accent = $accent; ansi = $palette.ansi }
                originals = [ordered]@{ family = $familyUrl; svg = $svgUrl }
            }
        }
    }
    if ($themesById.Count -ne $expected) { throw 'Discovered theme count does not match homepage expected count.' }
    foreach ($id in $modes.Keys) { if (-not $themesById.ContainsKey($id)) { throw "Mode tag references undiscovered theme '$id'." } }
    [string[]] $themeIds = @($themesById.Keys)
    [Array]::Sort($themeIds, [StringComparer]::Ordinal)
    [string[]] $documentUrls = @($documents.Keys)
    [Array]::Sort($documentUrls, [StringComparer]::Ordinal)
    $sortedDocuments = [ordered]@{}
    foreach ($url in $documentUrls) { $sortedDocuments[$url] = $documents[$url] }
    return [ordered]@{
        schema_version = '1.0'; source = [ordered]@{ id = 'terminal'; url = $baseUrl }
        started_at = $started
        finished_at = $(if ($null -ne $ReplaySnapshot) { $ReplaySnapshot.finished_at } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') })
        status = 'complete'; discovery = [ordered]@{ complete = $true; expected_count = $expected; theme_ids = @($themeIds) }
        themes = @($themeIds | ForEach-Object { $themesById[$_] }); documents = $sortedDocuments; failures = @()
    }
}
