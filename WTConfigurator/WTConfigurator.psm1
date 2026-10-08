#requires -Version 5.1
Set-StrictMode -Version 2.0
$script:ThemeCatalog = $null
. (Join-Path $PSScriptRoot 'Private/Settings.ps1')

function Get-RuntimeThemeCatalog {
    if ($null -eq $script:ThemeCatalog) {
        $path = Join-Path $PSScriptRoot 'data/themes.json'
        if (-not [IO.File]::Exists($path)) { throw "Bundled catalog is missing: $path. Run tools/Build-Catalog.ps1 from the source checkout." }
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $text = [IO.File]::ReadAllText($path, $encoding)
        $jsonArguments = @{ InputObject = $text; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArguments.DateKind = 'String' }
        $catalog = ConvertFrom-Json @jsonArguments
        if ($null -eq $catalog -or $catalog -isnot [pscustomobject] -or
            -not $catalog.PSObject.Properties['schema_version'] -or $catalog.schema_version -cne '1.0' -or
            -not $catalog.PSObject.Properties['themes'] -or $catalog.themes -isnot [array] -or $catalog.themes.Count -eq 0) {
            throw 'The bundled theme catalog has an unsupported format.'
        }
        # Older Core engines parse ISO strings as DateTime. Preserve the generated
        # catalog's original UTC capture string rather than exposing a culture-specific date.
        $capture = [regex]::Match($text, '"captured_at"\s*:\s*"(?<utc>[0-9TZ:.+-]+)"')
        $captureDate = [datetimeoffset]::MinValue
        if (-not $capture.Success -or -not $capture.Groups['utc'].Value.EndsWith('Z', [StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse($capture.Groups['utc'].Value, [ref]$captureDate)) { throw 'The catalog is missing a valid UTC capture timestamp.' }
        $catalog.captured_at = $capture.Groups['utc'].Value
        $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $catalog.themes) {
            if ($null -eq $row -or $row -isnot [pscustomobject]) { throw 'The catalog contains a non-object theme.' }
            foreach ($key in @('id', 'family_name', 'name', 'url', 'mode', 'palette')) {
                if (-not $row.PSObject.Properties[$key] -or $null -eq $row.$key) { throw "Catalog theme is missing '$key'." }
            }
            if ([string]$row.id -cnotmatch '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_-]*$' -or -not $ids.Add([string]$row.id)) { throw "Invalid or duplicate catalog ID '$($row.id)'." }
            foreach ($key in @('family_name', 'name', 'url')) {
                if ($row.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($row.$key)) { throw "Theme '$($row.id)' has an invalid '$key'." }
            }
            if ($row.mode -cnotin @('dark', 'light', 'unknown') -or $row.palette -isnot [pscustomobject]) { throw "Theme '$($row.id)' has an invalid mode or palette." }
            foreach ($key in @('background', 'foreground', 'accent', 'ansi')) {
                if (-not $row.palette.PSObject.Properties[$key]) { throw "Theme '$($row.id)' is missing palette '$key'." }
            }
            if ($row.palette.ansi -isnot [array] -or $row.palette.ansi.Count -ne 16) { throw "Theme '$($row.id)' must contain 16 ANSI colors." }
            foreach ($color in (@($row.palette.background, $row.palette.foreground, $row.palette.accent) + @($row.palette.ansi))) {
                if ($color -isnot [string] -or $color -cnotmatch '^#[0-9A-Fa-f]{6}$') { throw "Theme '$($row.id)' contains an invalid or unsupported alpha color '$color'." }
            }
        }
        $script:ThemeCatalog = $catalog
    }
    return $script:ThemeCatalog
}

function Get-WindowsTerminalTheme {
    <#
    .SYNOPSIS
    Lists or selects offline bundled Windows Terminal themes.
    .DESCRIPTION
    Exact selectors resolve an ID, a family/variant display name, then a unique variant name.
    Search is a literal case-insensitive substring. Results are independent objects suitable for pipelines.
    .PARAMETER Theme
    Exact stable ID, family/variant display name, or uniquely matching variant name.
    .PARAMETER Search
    Literal case-insensitive substring of an ID or display name. No wildcard syntax is interpreted.
    .EXAMPLE
    Get-WindowsTerminalTheme -Search 'ayu'
    .EXAMPLE
    Get-WindowsTerminalTheme -Theme 'ayu/dark'
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(ParameterSetName = 'Exact', Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string] $Theme,
        [Parameter(ParameterSetName = 'Search', Mandatory = $true)]
        [AllowEmptyString()][string] $Search
    )
    $rows = @((Get-RuntimeThemeCatalog).themes)
    if ($PSCmdlet.ParameterSetName -eq 'Exact') {
        $selector = $Theme.Trim()
        $selectionMatches = @($rows | Where-Object { [string]::Equals($_.id, $selector, [StringComparison]::OrdinalIgnoreCase) })
        if ($selectionMatches.Count -eq 0) {
            $selectionMatches = @($rows | Where-Object { [string]::Equals(($_.family_name + ' ' + $_.name), $selector, [StringComparison]::OrdinalIgnoreCase) })
        }
        if ($selectionMatches.Count -eq 0) {
            $selectionMatches = @($rows | Where-Object { [string]::Equals($_.name, $selector, [StringComparison]::OrdinalIgnoreCase) })
        }
        if ($selectionMatches.Count -eq 0) { throw "Theme '$Theme' is absent from the bundled catalog. Use Get-WindowsTerminalTheme to list IDs." }
        if ($selectionMatches.Count -gt 1) { throw "Theme '$Theme' is ambiguous. Select an ID: $(($selectionMatches.id | Sort-Object) -join ', ')." }
        $rows = $selectionMatches
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Search') {
        $rows = @($rows | Where-Object {
            $_.id.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ($_.family_name + ' ' + $_.name).IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
    }
    foreach ($row in ($rows | Sort-Object family_name, name, id)) {
        [pscustomobject][ordered]@{
            PSTypeName = 'WTConfigurator.Theme'
            Id = [string]$row.id
            DisplayName = [string]($row.family_name + ' ' + $row.name)
            FamilyName = [string]$row.family_name
            VariantName = [string]$row.name
            Mode = [string]$row.mode
            SourceUrl = [string]$row.url
            CapturedAt = [string](Get-RuntimeThemeCatalog).captured_at
            Palette = [pscustomobject][ordered]@{
                Background = [string]$row.palette.background
                Foreground = [string]$row.palette.foreground
                Accent = [string]$row.palette.accent
                Ansi = [string[]]@($row.palette.ansi)
            }
        }
    }
}

function Get-ProfileRecord {
    param([object] $Settings)
    if ($Settings.PSObject.Properties['profiles'] -and $Settings.profiles.PSObject.Properties['list']) {
        return $Settings.profiles.list
    }
}

function Resolve-ProfileRecord {
    param([object] $Settings, [string] $Selector)
    $records = @(Get-ProfileRecord -Settings $Settings)
    $guid = [guid]::Empty
    if ([guid]::TryParse($Selector, [ref]$guid)) {
        $selectionMatches = @($records | Where-Object {
            $recordGuid = [guid]::Empty
            $_.PSObject.Properties['guid'] -and [guid]::TryParse([string]$_.guid, [ref]$recordGuid) -and $recordGuid -eq $guid
        })
    }
    else {
        $selectionMatches = @($records | Where-Object { $_.PSObject.Properties['name'] -and [string]::Equals([string]$_.name, $Selector, [StringComparison]::OrdinalIgnoreCase) })
    }
    if ($selectionMatches.Count -eq 0) { throw "Profile '$Selector' was not found in profiles.list. Use Get-WindowsTerminalProfile to inspect stored profiles." }
    if ($selectionMatches.Count -gt 1) { throw "Profile '$Selector' is ambiguous. Select a unique GUID from profiles.list." }
    return $selectionMatches[0]
}

function Get-WindowsTerminalProfile {
    <#
    .SYNOPSIS
    Returns profiles explicitly stored in a Windows Terminal settings file.
    .DESCRIPTION
    Returns GUID, name and explicit appearance values. Defaults and external fragment settings are not resolved.
    .PARAMETER SettingsPath
    Explicit settings.json path. Otherwise the active Terminal edition or sole standard installation is selected.
    .EXAMPLE
    Get-WindowsTerminalProfile -SettingsPath .\settings.json
    #>
    [CmdletBinding()]
    param([string] $SettingsPath)
    $path = Resolve-TerminalSettingsPath -ExplicitPath $SettingsPath
    $snapshot = Read-TerminalSnapshot -Path $path
    foreach ($record in @(Get-ProfileRecord -Settings $snapshot.Settings)) {
        $values = [ordered]@{ PSTypeName = 'WTConfigurator.Profile'; SettingsPath = $path }
        foreach ($key in @('guid', 'name', 'colorScheme', 'opacity', 'useAcrylic')) {
            $values[$key] = if ($record.PSObject.Properties[$key]) { $record.$key } else { $null }
        }
        [pscustomobject]$values
    }
}

function ConvertTo-ManagedScheme {
    param([object] $Theme)
    $scheme = [ordered]@{
        name = 'WTConfigurator/' + $Theme.Id
        background = $Theme.Palette.Background
        foreground = $Theme.Palette.Foreground
        cursorColor = $Theme.Palette.Accent
    }
    $keys = @('black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white', 'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite')
    for ($index = 0; $index -lt 16; $index++) { $scheme[$keys[$index]] = $Theme.Palette.Ansi[$index] }
    return [pscustomobject]$scheme
}

function Set-AppearanceValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private in-memory transformation; the public command gates the file write with ShouldProcess.')]
    [CmdletBinding()]
    param([object] $Object, [string] $Name, [object] $Value, [Collections.Generic.List[string]] $Changes)
    $property = Get-OrdinalObjectProperty -Object $Object -Name $Name
    $equal = $false
    if ($property) {
        if ($Value -is [string]) { $equal = $property.Value -is [string] -and [string]::Equals($property.Value, $Value, [StringComparison]::Ordinal) }
        elseif ($Value -is [bool]) { $equal = $property.Value -is [bool] -and $property.Value -eq $Value }
        else { $equal = $null -ne $property.Value -and $property.Value -is [ValueType] -and $property.Value -isnot [bool] -and $property.Value -eq $Value }
    }
    if (-not $equal) {
        Set-ObjectProperty -Object $Object -Name $Name -Value $Value
        if (-not $Changes.Contains($Name)) { $Changes.Add($Name) }
    }
}

function Set-WindowsTerminalAppearance {
    <#
    .SYNOPSIS
    Applies a bundled theme, opacity, or acrylic to defaults or one profile.
    .DESCRIPTION
    Opacity is percent opaque (0-100); acrylic adds blur. Omitted values and unfocused overrides are retained.
    Updates normalize JSONC and back up exact bytes unless NoBackup is explicitly specified.
    .PARAMETER Theme
    Exact bundled theme ID or unambiguous name. Replaces the target's light/dark pair with one scheme.
    .PARAMETER Opacity
    One integral percentage from 0 to 100, representing percent opaque. Fractional percentages are rejected.
    .PARAMETER UseAcrylic
    Explicit true or false to change background blur. Omission preserves the existing value.
    .PARAMETER TargetProfile
    An existing profile GUID or unique exact name. Alias: Profile. Omission targets profile defaults.
    .PARAMETER SettingsPath
    Explicit settings.json path, required when automatic installation discovery is ambiguous.
    .PARAMETER NoBackup
    Opts out of retaining the original file on a successful update. Failed writes retain recovery files.
    .PARAMETER PassThru
    Returns target, changed properties, backup path, and Changed for a completed update or no-op.
    .EXAMPLE
    Set-WindowsTerminalAppearance -Opacity 80 -UseAcrylic $true
    .EXAMPLE
    Set-WindowsTerminalAppearance -Theme 'ayu/dark' -Opacity 85 -Profile 'PowerShell' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateNotNullOrEmpty()][string] $Theme,
        [ValidateScript({
            if ($_ -is [bool] -or $_ -is [array] -or $_ -is [char]) { throw 'Opacity must be an integer percentage from 0 to 100.' }
            $number = 0.0
            if ([string]$_ -cnotmatch '^\+?[0-9]+(?:\.0+)?$' -or -not [double]::TryParse([string]$_, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
                [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 100 -or [math]::Truncate($number) -ne $number) { throw 'Opacity must be an integer percentage from 0 to 100.' }
            $true
        })][object] $Opacity,
        [bool] $UseAcrylic,
        [Alias('Profile')][ValidateNotNullOrEmpty()][string] $TargetProfile,
        [string] $SettingsPath,
        [switch] $NoBackup,
        [switch] $PassThru
    )
    $hasTheme = $PSBoundParameters.ContainsKey('Theme')
    $hasOpacity = $PSBoundParameters.ContainsKey('Opacity')
    $hasAcrylic = $PSBoundParameters.ContainsKey('UseAcrylic')
    if ($hasOpacity -and $Opacity -is [Collections.IEnumerable] -and $Opacity -isnot [string]) { throw 'Opacity must be a single integer percentage from 0 to 100.' }
    if (-not ($hasTheme -or $hasOpacity -or $hasAcrylic)) { throw 'Supply at least one of -Theme, -Opacity, or -UseAcrylic.' }
    $selectedTheme = if ($hasTheme) { Get-WindowsTerminalTheme -Theme $Theme } else { $null }
    $path = Resolve-TerminalSettingsPath -ExplicitPath $SettingsPath
    $mutex = Enter-TerminalMutex -Path $path
    try {
        $snapshot = Read-TerminalSnapshot -Path $path
        $settings = $snapshot.Settings
        $changes = New-Object 'Collections.Generic.List[string]'
        $targetName = 'defaults'
        if ($PSBoundParameters.ContainsKey('TargetProfile')) {
            $target = Resolve-ProfileRecord -Settings $settings -Selector $TargetProfile
            $targetName = if ($target.PSObject.Properties['guid']) { [string]$target.guid } else { [string]$target.name }
        }
        else {
            if (-not $settings.PSObject.Properties['profiles']) { Set-ObjectProperty -Object $settings -Name 'profiles' -Value ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = @() }) }
            if (-not $settings.profiles.PSObject.Properties['defaults']) { Set-ObjectProperty -Object $settings.profiles -Name 'defaults' -Value ([pscustomobject]@{}) }
            $target = $settings.profiles.defaults
        }
        if ($hasTheme) {
            $scheme = ConvertTo-ManagedScheme -Theme $selectedTheme
            $schemes = @()
            if ($settings.PSObject.Properties['schemes']) { $schemes = @($settings.schemes) }
            $matching = @($schemes | Where-Object { $_.PSObject.Properties['name'] -and [string]::Equals([string]$_.name, $scheme.name, [StringComparison]::OrdinalIgnoreCase) })
            if ($matching.Count -gt 1) { throw "Duplicate managed scheme '$($scheme.name)' exists; resolve the duplicates before applying it." }
            if ($matching.Count -eq 0) {
                Set-ObjectProperty -Object $settings -Name 'schemes' -Value ([object[]](@($schemes) + @($scheme)))
                $changes.Add('schemes')
            }
            else {
                $schemeChanges = New-Object 'Collections.Generic.List[string]'
                foreach ($property in $scheme.PSObject.Properties) { Set-AppearanceValue -Object $matching[0] -Name $property.Name -Value $property.Value -Changes $schemeChanges }
                if ($schemeChanges.Count -gt 0) { $changes.Add('schemes') }
            }
            Set-AppearanceValue -Object $target -Name 'colorScheme' -Value $scheme.name -Changes $changes
        }
        if ($hasOpacity) { Set-AppearanceValue -Object $target -Name 'opacity' -Value ([int]::Parse(([double]$Opacity).ToString('0', [Globalization.CultureInfo]::InvariantCulture))) -Changes $changes }
        if ($hasAcrylic) { Set-AppearanceValue -Object $target -Name 'useAcrylic' -Value $UseAcrylic -Changes $changes }
        $result = [pscustomobject][ordered]@{
            PSTypeName = 'WTConfigurator.UpdateResult'
            SettingsPath = $path
            Target = $targetName
            ThemeId = if ($selectedTheme) { $selectedTheme.Id } else { $null }
            ChangedProperties = [string[]]$changes.ToArray()
            BackupPath = $null
            Changed = $false
        }
        if ($changes.Count -eq 0) { if ($PassThru) { $result }; return }
        Assert-TerminalSettings -Settings $settings
        $json = ConvertTo-SafeTerminalJson -Settings $settings
        if ($PSCmdlet.ShouldProcess($path, "Update Windows Terminal appearance for $targetName ($($changes -join ', '))")) {
            $encoding = New-Object Text.UTF8Encoding($false, $true)
            $result.BackupPath = Invoke-TerminalWrite -Path $path -OriginalHash $snapshot.Hash -Bytes ($encoding.GetBytes($json + "`r`n")) -NoBackup:$NoBackup
            $result.Changed = $true
            if (-not $PSBoundParameters.ContainsKey('TargetProfile')) {
                $overrides = @(Get-ProfileRecord -Settings $settings | Where-Object {
                    $record = $_
                    @($changes | Where-Object { $_ -ne 'schemes' -and $record.PSObject.Properties[$_] }).Count -gt 0
                })
                if ($overrides.Count -gt 0) { Write-Warning "$($overrides.Count) stored profile(s) explicitly override the changed defaults; their overrides were preserved." }
            }
            if ($PassThru) { $result }
        }
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Set-WindowsTerminalTheme {
    <#
    .SYNOPSIS
    Applies one bundled theme to Windows Terminal defaults or one stored profile.
    .PARAMETER Theme
    Exact bundled theme ID or unambiguous name.
    .PARAMETER TargetProfile
    An existing profile GUID or unique exact name. Alias: Profile. Omission targets profile defaults.
    .PARAMETER SettingsPath
    Explicit settings.json path; otherwise use automatic installation discovery.
    .PARAMETER NoBackup
    Opts out of retaining the original file after success; normalization removes comments.
    .PARAMETER PassThru
    Returns the appearance update result, including Changed and BackupPath.
    .EXAMPLE
    Set-WindowsTerminalTheme -Theme 'ayu/dark' -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidateNotNullOrEmpty()][string] $Theme,
        [Alias('Profile')][ValidateNotNullOrEmpty()][string] $TargetProfile,
        [string] $SettingsPath,
        [switch] $NoBackup,
        [switch] $PassThru
    )
    Set-WindowsTerminalAppearance @PSBoundParameters
}

function Restore-WindowsTerminalSettings {
    <#
    .SYNOPSIS
    Restores a validated backup exactly and backs up the current target.
    .DESCRIPTION
    Both paths are explicit. Restoration preserves original comments, formatting, BOM and encoding.
    .PARAMETER BackupPath
    Existing valid JSONC settings backup to restore. Must differ from SettingsPath.
    .PARAMETER SettingsPath
    Existing target settings file. Its current bytes are always backed up before replacement.
    .PARAMETER PassThru
    Returns the restoration target, current-file backup path, and Changed.
    .EXAMPLE
    Restore-WindowsTerminalSettings -BackupPath .\settings.json.bak -SettingsPath .\settings.json -WhatIf
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The public API names the Windows Terminal settings document and preserves the approved Restore-WindowsTerminalSettings contract.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $BackupPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $SettingsPath,
        [switch] $PassThru
    )
    $path = Resolve-TerminalSettingsPath -ExplicitPath $SettingsPath
    $backup = Resolve-TerminalSettingsPath -ExplicitPath $BackupPath
    if ([string]::Equals($path, $backup, [StringComparison]::OrdinalIgnoreCase)) { throw 'BackupPath and SettingsPath must be different files.' }
    $bytes = Read-ValidatedTerminalBackup -Path $backup
    $mutex = Enter-TerminalMutex -Path $path
    try {
        # Current settings may be corrupted; always preserve their exact bytes for recovery.
        $current = [IO.File]::ReadAllBytes($path)
        $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($current)).Replace('-', '') }
        finally { $hashAlgorithm.Dispose() }
        $same = $current.Length -eq $bytes.Length
        if ($same) {
            for ($index = 0; $index -lt $current.Length; $index++) { if ($current[$index] -ne $bytes[$index]) { $same = $false; break } }
        }
        $result = [pscustomobject][ordered]@{ PSTypeName = 'WTConfigurator.UpdateResult'; SettingsPath = $path; Target = 'settings'; ChangedProperties = @('settings'); BackupPath = $null; Changed = $false }
        if ($same) { $result.ChangedProperties = @(); if ($PassThru) { $result }; return }
        if ($PSCmdlet.ShouldProcess($path, "Restore exact settings bytes from '$backup'")) {
            $result.BackupPath = Invoke-TerminalWrite -Path $path -OriginalHash $hash -Bytes $bytes
            $result.Changed = $true
            if ($PassThru) { $result }
        }
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

Export-ModuleMember -Function Get-WindowsTerminalTheme, Get-WindowsTerminalProfile, Set-WindowsTerminalAppearance, Set-WindowsTerminalTheme, Restore-WindowsTerminalSettings
