function Get-TerminalByteHash {
    param([byte[]] $Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function ConvertFrom-TerminalBytes {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private decoder accepts a byte array; Bytes describes that input precisely.')]
    [CmdletBinding()]
    param([byte[]] $Bytes)
    $offset = 0
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    if ($Bytes.Length -ge 4 -and
        (($Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) -or
         ($Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255))) {
        throw 'UTF-32 settings are unsupported; save the file as UTF-8 or BOM-marked UTF-16 first.'
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $offset = 3
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $offset = 2
        $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $offset = 2
        $encoding = New-Object Text.UnicodeEncoding($true, $true, $true)
    }
    try { return $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset) }
    catch { throw "The settings file has invalid text encoding: $($_.Exception.Message)" }
}

function Remove-JsonComments {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure text transformation; it does not change files or external state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private text transformation removes all JSON comments.')]
    [CmdletBinding()]
    param([string] $Text)
    $output = New-Object Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char] 0 }
        if ($lineComment) {
            if ($character -eq "`r" -or $character -eq "`n") {
                $lineComment = $false
                [void] $output.Append($character)
            }
            else { [void] $output.Append(' ') }
            continue
        }
        if ($blockComment) {
            if ($character -eq '*' -and $next -eq '/') {
                [void] $output.Append('  ')
                $i++
                $blockComment = $false
            }
            elseif ($character -eq "`r" -or $character -eq "`n") { [void] $output.Append($character) }
            else { [void] $output.Append(' ') }
            continue
        }
        if ($inString) {
            [void] $output.Append($character)
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            [void] $output.Append($character)
        }
        elseif ($character -eq '/' -and $next -eq '/') {
            [void] $output.Append('  ')
            $i++
            $lineComment = $true
        }
        elseif ($character -eq '/' -and $next -eq '*') {
            [void] $output.Append('  ')
            $i++
            $blockComment = $true
        }
        else { [void] $output.Append($character) }
    }
    if ($blockComment) { throw 'settings.json contains an unterminated block comment.' }
    return $output.ToString()
}

function Remove-JsonTrailingCommas {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure text transformation; it does not change files or external state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private text transformation removes all JSON trailing commas.')]
    [CmdletBinding()]
    param([string] $Text)
    $output = New-Object Text.StringBuilder
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($inString) {
            [void] $output.Append($character)
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') {
            $inString = $true
            [void] $output.Append($character)
            continue
        }
        if ($character -eq ',') {
            $after = $i + 1
            while ($after -lt $Text.Length -and [char]::IsWhiteSpace($Text[$after])) { $after++ }
            if ($after -lt $Text.Length -and ($Text[$after] -eq '}' -or $Text[$after] -eq ']')) {
                $before = $i - 1
                while ($before -ge 0 -and [char]::IsWhiteSpace($Text[$before])) { $before-- }
                if ($before -lt 0 -or '{[,:'.IndexOf($Text[$before]) -ge 0) {
                    throw 'settings.json contains a comma without a preceding value.'
                }
                [void] $output.Append(' ')
                continue
            }
        }
        [void] $output.Append($character)
    }
    return $output.ToString()
}

function Get-JsonTokens {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private lexical operation returns an ordered sequence of JSON tokens.')]
    [CmdletBinding()]
    param([string] $Text)
    $tokens = New-Object 'Collections.Generic.List[object]'
    $numberPattern = New-Object Text.RegularExpressions.Regex('\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
    $i = 0
    while ($i -lt $Text.Length) {
        $character = $Text[$i]
        if (' ' -eq $character -or "`t" -eq $character -or "`r" -eq $character -or "`n" -eq $character) {
            $i++
            continue
        }
        $start = $i
        if ('{}[]:,'.IndexOf($character) -ge 0) {
            [void] $tokens.Add([pscustomobject]@{ Kind = 'Punctuation'; Value = [string] $character; Offset = $start })
            $i++
            continue
        }
        if ($character -eq '"') {
            $decoded = New-Object Text.StringBuilder
            $closed = $false
            $i++
            while ($i -lt $Text.Length) {
                $character = $Text[$i]
                if ($character -eq '"') { $closed = $true; $i++; break }
                if ([int] $character -lt 32) { throw "Invalid JSON string control character at offset $i." }
                if ($character -ne '\') { [void] $decoded.Append($character); $i++; continue }
                $i++
                if ($i -ge $Text.Length) { throw "Unterminated JSON escape at offset $i." }
                switch -CaseSensitive ([string] $Text[$i]) {
                    '"' { [void] $decoded.Append('"') }
                    '\' { [void] $decoded.Append('\') }
                    '/' { [void] $decoded.Append('/') }
                    'b' { [void] $decoded.Append([char] 8) }
                    'f' { [void] $decoded.Append([char] 12) }
                    'n' { [void] $decoded.Append([char] 10) }
                    'r' { [void] $decoded.Append([char] 13) }
                    't' { [void] $decoded.Append([char] 9) }
                    'u' {
                        if ($i + 4 -ge $Text.Length) { throw "Incomplete Unicode escape at offset $i." }
                        $hex = $Text.Substring($i + 1, 4)
                        if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw "Invalid Unicode escape at offset $i." }
                        [void] $decoded.Append([char] [Convert]::ToInt32($hex, 16))
                        $i += 4
                    }
                    default { throw "Invalid JSON escape at offset $i." }
                }
                $i++
            }
            if (-not $closed) { throw "Unterminated JSON string at offset $start." }
            [void] $tokens.Add([pscustomobject]@{ Kind = 'String'; Value = $decoded.ToString(); Offset = $start })
            continue
        }
        $match = $numberPattern.Match($Text, $i)
        if ($match.Success -and $match.Index -eq $i) {
            $value = $match.Value
            $kind = 'Number'
        }
        else {
            $value = $null
            foreach ($literal in @('true', 'false', 'null')) {
                if ($i + $literal.Length -le $Text.Length -and
                    [string]::Equals($Text.Substring($i, $literal.Length), $literal, [StringComparison]::Ordinal)) {
                    $value = $literal
                    break
                }
            }
            if ($null -eq $value) { throw "Unsupported JSON token at offset $i." }
            $kind = 'Literal'
        }
        $i += $value.Length
        if ($i -lt $Text.Length -and '{}[]:, '.IndexOf($Text[$i]) -lt 0 -and
            $Text[$i] -ne "`t" -and $Text[$i] -ne "`r" -and $Text[$i] -ne "`n") {
            throw "Invalid JSON token boundary at offset $i."
        }
        [void] $tokens.Add([pscustomobject]@{ Kind = $kind; Value = $value; Offset = $start })
    }
    return $tokens.ToArray()
}

function Assert-JsonTokenEquality {
    param([object[]] $Expected, [object[]] $Actual)
    if ($Expected.Count -ne $Actual.Count) {
        throw 'JSON normalization would change the document structure or drop values; this input is unsupported.'
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Expected[$i].Kind -cne $Actual[$i].Kind -or
            -not [string]::Equals($Expected[$i].Value, $Actual[$i].Value, [StringComparison]::Ordinal)) {
            throw "JSON normalization would change a value or property at offset $($Expected[$i].Offset); this input is unsupported."
        }
    }
}

function ConvertFrom-SafeTerminalJson {
    param([string] $Text)
    $normalized = Remove-JsonTrailingCommas -Text (Remove-JsonComments -Text $Text)
    $tokens = @(Get-JsonTokens -Text $normalized)
    if ($tokens.Count -eq 0 -or $tokens[0].Kind -cne 'Punctuation' -or $tokens[0].Value -cne '{') {
        throw 'The root of settings.json must be a JSON object.'
    }
    $arguments = @{ InputObject = $normalized; ErrorAction = 'Stop'; WarningAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $arguments.DateKind = 'String' }
    try {
        $settings = ConvertFrom-Json @arguments
        $baseline = ConvertTo-Json -InputObject $settings -Depth 100 -ErrorAction Stop -WarningAction Stop
        Assert-JsonTokenEquality -Expected $tokens -Actual @(Get-JsonTokens -Text $baseline)
    }
    catch { throw "Cannot safely normalize settings.json: $($_.Exception.Message)" }
    Assert-TerminalSettings -Settings $settings
    return $settings
}

function Get-OrdinalObjectProperty {
    param([object] $Object, [string] $Name)
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [StringComparison]::Ordinal)) { return $property }
        if ([string]::Equals($property.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsupported settings key '$($property.Name)'; use the exact casing '$Name'."
        }
    }
    return $null
}

function Set-ObjectProperty {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private in-memory helper; the public command owns ShouldProcess before any file write.')]
    [CmdletBinding()]
    param([object] $Object, [string] $Name, [AllowNull()] [object] $Value)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw "The parent of '$Name' must be a JSON object." }
    $property = Get-OrdinalObjectProperty -Object $Object -Name $Name
    if ($null -ne $property) { $property.Value = $Value }
    else { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
}

function Assert-TerminalColorScheme {
    param([object] $Object, [string] $Location)
    $opacity = Get-OrdinalObjectProperty -Object $Object -Name 'opacity'
    if ($null -ne $opacity) {
        $value = $opacity.Value
        $isNumber = $value -is [byte] -or $value -is [sbyte] -or $value -is [int16] -or
            $value -is [uint16] -or $value -is [int] -or $value -is [uint32] -or
            $value -is [long] -or $value -is [uint64] -or $value -is [single] -or
            $value -is [double] -or $value -is [decimal]
        if (-not $isNumber -or [double]::IsNaN([double] $value) -or
            [double]::IsInfinity([double] $value) -or [double] $value -lt 0 -or [double] $value -gt 100) {
            throw "$Location.opacity must be a finite number between 0 and 100."
        }
    }
    $acrylic = Get-OrdinalObjectProperty -Object $Object -Name 'useAcrylic'
    if ($null -ne $acrylic -and $acrylic.Value -isnot [bool]) { throw "$Location.useAcrylic must be a JSON boolean." }
    $property = Get-OrdinalObjectProperty -Object $Object -Name 'colorScheme'
    if ($null -eq $property) { return }
    if ($property.Value -is [string]) { return }
    if ($null -eq $property.Value -or $property.Value -isnot [pscustomobject]) {
        throw "$Location.colorScheme must be a string or a light/dark JSON object."
    }
    foreach ($name in @('light', 'dark')) {
        $entry = Get-OrdinalObjectProperty -Object $property.Value -Name $name
        if ($null -ne $entry -and $entry.Value -isnot [string]) {
            throw "$Location.colorScheme.$name must be a string when present."
        }
    }
}

function Assert-TerminalSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is the Windows Terminal document domain name and the agreed private API.')]
    [CmdletBinding()]
    param([object] $Settings)
    if ($null -eq $Settings -or $Settings -isnot [pscustomobject]) { throw 'The root of settings.json must be a JSON object.' }
    $schemes = Get-OrdinalObjectProperty -Object $Settings -Name 'schemes'
    if ($null -ne $schemes) {
        if ($null -eq $schemes.Value -or $schemes.Value -isnot [array]) { throw 'settings.schemes must be a JSON array.' }
        foreach ($scheme in $schemes.Value) {
            if ($null -eq $scheme -or $scheme -isnot [pscustomobject]) { throw 'Every settings.schemes entry must be a JSON object.' }
            $name = Get-OrdinalObjectProperty -Object $scheme -Name 'name'
            if ($null -eq $name -or $name.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($name.Value)) {
                throw 'Every settings.schemes entry must have a nonempty string name.'
            }
        }
    }
    $profiles = Get-OrdinalObjectProperty -Object $Settings -Name 'profiles'
    if ($null -eq $profiles) { return }
    if ($null -eq $profiles.Value -or $profiles.Value -isnot [pscustomobject]) {
        throw 'settings.profiles must be a JSON object with defaults/list; legacy profile arrays are unsupported by this tool.'
    }
    $defaults = Get-OrdinalObjectProperty -Object $profiles.Value -Name 'defaults'
    if ($null -ne $defaults) {
        if ($null -eq $defaults.Value -or $defaults.Value -isnot [pscustomobject]) { throw 'settings.profiles.defaults must be a JSON object.' }
        Assert-TerminalColorScheme -Object $defaults.Value -Location 'settings.profiles.defaults'
    }
    $list = Get-OrdinalObjectProperty -Object $profiles.Value -Name 'list'
    if ($null -eq $list) { return }
    if ($null -eq $list.Value -or $list.Value -isnot [array]) { throw 'settings.profiles.list must be a JSON array.' }
    for ($i = 0; $i -lt $list.Value.Count; $i++) {
        $profileEntry = $list.Value[$i]
        if ($null -eq $profileEntry -or $profileEntry -isnot [pscustomobject]) { throw "settings.profiles.list[$i] must be a JSON object." }
        $name = Get-OrdinalObjectProperty -Object $profileEntry -Name 'name'
        if ($null -ne $name -and ($name.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($name.Value))) {
            throw "settings.profiles.list[$i].name must be a nonempty string when present."
        }
        $guid = Get-OrdinalObjectProperty -Object $profileEntry -Name 'guid'
        if ($null -ne $guid) {
            $parsedGuid = [guid]::Empty
            if ($guid.Value -isnot [string] -or -not [guid]::TryParse($guid.Value, [ref] $parsedGuid)) {
                throw "settings.profiles.list[$i].guid must be a GUID string when present."
            }
        }
        Assert-TerminalColorScheme -Object $profileEntry -Location "settings.profiles.list[$i]"
    }
}

function Read-TerminalSnapshot {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = ConvertFrom-TerminalBytes -Bytes $bytes
    $settings = ConvertFrom-SafeTerminalJson -Text $text
    return [pscustomobject]@{ Bytes = $bytes; Text = $text; Hash = Get-TerminalByteHash -Bytes $bytes; Settings = $settings }
}

function Read-ValidatedTerminalBackup {
    param([string] $Path)
    $snapshot = Read-TerminalSnapshot -Path $Path
    return ,$snapshot.Bytes
}

function ConvertTo-SafeTerminalJson {
    param([object] $Settings)
    Assert-TerminalSettings -Settings $Settings
    $json = ConvertTo-Json -InputObject $Settings -Depth 100 -ErrorAction Stop -WarningAction Stop
    [void] (ConvertFrom-SafeTerminalJson -Text $json)
    return $json
}

function Enter-TerminalMutex {
    param([string] $Path)
    $canonicalPath = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $pathBytes = [Text.Encoding]::UTF8.GetBytes($canonicalPath)
    $name = 'Global\WTConfigurator.' + (Get-TerminalByteHash -Bytes $pathBytes)
    $mutex = $null
    $acquired = $false
    try {
        $mutex = New-Object Threading.Mutex($false, $name) -ErrorAction Stop
        try { $acquired = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another WTConfigurator operation is using this settings file; try again later.' }
        return $mutex
    }
    catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw "Cannot coordinate access to settings '$Path' using the global mutex: $($_.Exception.Message) Check permissions or wait for the other operation to finish."
    }
}

function Invoke-TerminalReplace {
    param([string] $SourcePath, [string] $DestinationPath, [string] $BackupPath)
    [IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath)
}

function Invoke-TerminalWrite {
    param([string] $Path, [string] $OriginalHash, [byte[]] $Bytes, [switch] $NoBackup)
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $identifier = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ('.settings.{0}.tmp' -f $identifier)
    $backupPath = if ($NoBackup) { $null } else { '{0}.{1}.{2}.bak' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $identifier }
    $replacementBackupPath = if ($NoBackup) { Join-Path $directory ('.settings.{0}.old' -f $identifier) } else { $backupPath }
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        $currentBytes = [IO.File]::ReadAllBytes($Path)
        if (-not [string]::Equals((Get-TerminalByteHash -Bytes $currentBytes), $OriginalHash, [StringComparison]::Ordinal)) {
            throw 'settings.json changed while the update was being prepared; no replacement was attempted.'
        }
        Invoke-TerminalReplace -SourcePath $temporaryPath -DestinationPath $Path -BackupPath $replacementBackupPath
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop }
        if ($NoBackup -and (Test-Path -LiteralPath $replacementBackupPath)) {
            Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction Stop
        }
        return $backupPath
    }
    catch {
        throw "The settings write did not complete cleanly: $($_.Exception.Message) Recovery files, if present, were retained at '$temporaryPath' and '$replacementBackupPath'. No rollback was attempted."
    }
}

function Get-AncestorExecutablePaths {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private discovery helper returns the executable paths in a process ancestry chain.')]
    [CmdletBinding()]
    param()
    $paths = @()
    $processId = $PID
    for ($i = 0; $i -lt 12 -and $processId -gt 0; $i++) {
        try { $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop }
        catch { break }
        if ($null -eq $process) { break }
        if ($process.ExecutablePath) { $paths += [string] $process.ExecutablePath }
        $processId = [int] $process.ParentProcessId
    }
    return $paths
}

function Resolve-TerminalSettingsPath {
    param([string] $ExplicitPath)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "The settings file '$ExplicitPath' does not exist." }
        $resolved = Resolve-Path -LiteralPath $ExplicitPath
        if ($resolved.Provider.Name -ne 'FileSystem') { throw 'SettingsPath must identify a filesystem file.' }
        return $resolved.ProviderPath
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not set; use -SettingsPath explicitly.' }
    $knownPaths = [ordered]@{
        Stable = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        Preview = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
        Unpackaged = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    }
    $ancestorPaths = @(Get-AncestorExecutablePaths)
    $terminalExecutable = $ancestorPaths | Where-Object { [IO.Path]::GetFileName($_) -ieq 'WindowsTerminal.exe' } | Select-Object -First 1
    if ($terminalExecutable) {
        if ($terminalExecutable -match 'Microsoft\.WindowsTerminalPreview_') {
            if (Test-Path -LiteralPath $knownPaths.Preview -PathType Leaf) { return (Resolve-Path -LiteralPath $knownPaths.Preview).ProviderPath }
        }
        elseif ($terminalExecutable -match 'Microsoft\.WindowsTerminal_') {
            if (Test-Path -LiteralPath $knownPaths.Stable -PathType Leaf) { return (Resolve-Path -LiteralPath $knownPaths.Stable).ProviderPath }
        }
        else {
            $executableDirectory = Split-Path -Parent $terminalExecutable
            foreach ($candidate in @((Join-Path $executableDirectory 'settings\settings.json'), (Join-Path $executableDirectory 'settings.json'))) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
            }
            if (Test-Path -LiteralPath $knownPaths.Unpackaged -PathType Leaf) { return (Resolve-Path -LiteralPath $knownPaths.Unpackaged).ProviderPath }
        }
    }
    $existingPaths = @($knownPaths.Values | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    if ($existingPaths.Count -eq 1) { return (Resolve-Path -LiteralPath $existingPaths[0]).ProviderPath }
    if ($existingPaths.Count -eq 0) { throw 'Windows Terminal settings.json was not found. Open Terminal Settings once, or use -SettingsPath.' }
    throw "Multiple Windows Terminal settings files were found; use -SettingsPath explicitly:`n$($existingPaths -join [Environment]::NewLine)"
}
