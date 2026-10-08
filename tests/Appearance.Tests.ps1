BeforeAll {
    $script:ProjectRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:ProjectRoot 'WTConfigurator/WTConfigurator.psd1') -Force
    function New-AppearanceFixture {
        param([string] $Json = '{}')
        $file = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($file, $Json, (New-Object Text.UTF8Encoding($false)))
        return $file
    }
    function Read-AppearanceFixture { param([string] $Path) [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
}

Describe 'Offline public catalog commands' {
    It 'exports exactly the five intended commands' {
        @(Get-Command -Module WTConfigurator).Count | Should -Be 5
    }
    It 'lists 112 structured themes with 16 colors and source provenance' {
        $themes = @(Get-WindowsTerminalTheme)
        $themes.Count | Should -Be 112
        $themes[0].Palette.Ansi.Count | Should -Be 16
        $themes[0].CapturedAt | Should -Not -BeNullOrEmpty
        $themes[0].CapturedAt | Should -Match '^\d{4}-\d{2}-\d{2}T.*Z$'
        $themes[0].SourceUrl | Should -Match '^https://'
    }
    It 'resolves IDs and combined names case-insensitively' {
        (Get-WindowsTerminalTheme 'AYU/DARK').Id | Should -BeExactly 'ayu/dark'
        (Get-WindowsTerminalTheme 'Ayu Dark').Id | Should -BeExactly 'ayu/dark'
    }
    It 'rejects ambiguous short names with candidate IDs' {
        { Get-WindowsTerminalTheme 'Default' } | Should -Throw '*ambiguous*apprentice/default*'
    }
    It 'rejects an absent former online catalog name' {
        { Get-WindowsTerminalTheme '3024 Night' } | Should -Throw '*absent*'
    }
    It 'uses literal search rather than wildcard interpretation' {
        @(Get-WindowsTerminalTheme -Search '*').Count | Should -Be 0
        @(Get-WindowsTerminalTheme -Search '[').Count | Should -Be 0
        @(Get-WindowsTerminalTheme -Search 'ayu').Count | Should -Be 3
    }
    It 'decodes Unicode and returns independent palette objects' {
        @(Get-WindowsTerminalTheme -Search ('Ros' + [char]0xE9 + ' Pine')).Count | Should -BeGreaterThan 0
        $theme = Get-WindowsTerminalTheme 'ayu/dark'
        $original = $theme.Palette.Ansi[0]
        $theme.Palette.Ansi[0] = '#ABCDEF'
        (Get-WindowsTerminalTheme 'ayu/dark').Palette.Ansi[0] | Should -BeExactly $original
    }
}

Describe 'Transactional appearance updates' {
    It 'requires at least one requested appearance value' {
        { Set-WindowsTerminalAppearance -SettingsPath (New-AppearanceFixture) } | Should -Throw '*at least one*'
    }
    It 'applies theme, opacity and acrylic together with an exact backup' {
        $path = New-AppearanceFixture '// original comment
{"unknown":{"value":"https://example.test/a//b"},"profiles":{"defaults":{},"list":[]},}'
        $original = [IO.File]::ReadAllBytes($path)
        $result = Set-WindowsTerminalAppearance -Theme 'ayu/dark' -Opacity 80 -UseAcrylic $true -SettingsPath $path -PassThru
        $result.Changed | Should -BeTrue
        $result.ChangedProperties | Should -Contain 'schemes'
        $saved = Read-AppearanceFixture $path
        $saved.profiles.defaults.colorScheme | Should -BeExactly 'WTConfigurator/ayu/dark'
        $saved.profiles.defaults.opacity | Should -Be 80
        $saved.profiles.defaults.useAcrylic | Should -BeTrue
        $saved.unknown.value | Should -BeExactly 'https://example.test/a//b'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($result.BackupPath)) | Should -BeExactly ([Convert]::ToBase64String($original))
        [IO.File]::ReadAllText($path) | Should -Not -Match '// original comment'
        $scheme = $saved.schemes[0]
        $theme = Get-WindowsTerminalTheme 'ayu/dark'
        $scheme.cursorColor | Should -BeExactly $theme.Palette.Accent
        $keys = @('black','red','green','yellow','blue','purple','cyan','white','brightBlack','brightRed','brightGreen','brightYellow','brightBlue','brightPurple','brightCyan','brightWhite')
        for ($index = 0; $index -lt 16; $index++) { $scheme.($keys[$index]) | Should -BeExactly $theme.Palette.Ansi[$index] }
    }
    It 'applies opacity alone without adding schemes or reading the catalog' {
        $path = New-AppearanceFixture
        InModuleScope WTConfigurator -Parameters @{ FixturePath = $path } {
            param($FixturePath)
            Mock Get-RuntimeThemeCatalog { throw 'Catalog must not be accessed.' }
            Set-WindowsTerminalAppearance -Opacity 60 -SettingsPath $FixturePath -NoBackup
            Should -Invoke Get-RuntimeThemeCatalog -Times 0
        }
        $saved = Read-AppearanceFixture $path
        $saved.profiles.defaults.opacity | Should -Be 60
        $saved.PSObject.Properties.Name | Should -Not -Contain 'schemes'
    }
    It 'accepts explicit acrylic false without requiring another value' {
        $path = New-AppearanceFixture '{"profiles":{"defaults":{"useAcrylic":true},"list":[]}}'
        Set-WindowsTerminalAppearance -UseAcrylic $false -SettingsPath $path
        (Read-AppearanceFixture $path).profiles.defaults.useAcrylic | Should -BeFalse
    }
    It 'preserves omitted acrylic and unfocused overrides' {
        $path = New-AppearanceFixture '{"profiles":{"defaults":{"useAcrylic":true,"unfocusedAppearance":{"opacity":35,"useAcrylic":false}},"list":[]}}'
        Set-WindowsTerminalAppearance -Opacity 90 -SettingsPath $path
        $target = (Read-AppearanceFixture $path).profiles.defaults
        $target.useAcrylic | Should -BeTrue
        $target.unfocusedAppearance.opacity | Should -Be 35
        $target.unfocusedAppearance.useAcrylic | Should -BeFalse
    }
    It 'accepts opacity boundary <Value>' -TestCases @(@{Value=0},@{Value=100}) {
        param($Value)
        $path = New-AppearanceFixture
        Set-WindowsTerminalAppearance -Opacity $Value -SettingsPath $path
        (Read-AppearanceFixture $path).profiles.defaults.opacity | Should -Be $Value
    }
    It 'rejects invalid opacity <Value> before writing' -TestCases @(@{Value=-1},@{Value=101},@{Value=50.5},@{Value='NaN'},@{Value='Infinity'},@{Value='80.00000000000000000001'},@{Value=$true}) {
        param($Value)
        $path = New-AppearanceFixture
        { Set-WindowsTerminalAppearance -Opacity $Value -SettingsPath $path } | Should -Throw '*Opacity*'
        [IO.File]::ReadAllText($path) | Should -BeExactly '{}'
    }
    It 'rejects collection opacity before settings discovery or catalog lookup' {
        InModuleScope WTConfigurator {
            Mock Resolve-TerminalSettingsPath { throw 'Settings must not be accessed.' }
            Mock Get-WindowsTerminalTheme { throw 'Catalog must not be accessed.' }
            { Set-WindowsTerminalAppearance -Opacity @(80) -Theme 'ayu/dark' } | Should -Throw '*single integer*'
            { Set-WindowsTerminalAppearance -Opacity @(80, 90) } | Should -Throw '*single integer*'
            Should -Invoke Resolve-TerminalSettingsPath -Times 0
            Should -Invoke Get-WindowsTerminalTheme -Times 0
        }
    }
    It 'accepts invariant integer strings and rejects null opacity' {
        $path = New-AppearanceFixture
        Set-WindowsTerminalAppearance -Opacity '80' -SettingsPath $path
        (Read-AppearanceFixture $path).profiles.defaults.opacity | Should -Be 80
        { Set-WindowsTerminalAppearance -Opacity $null -SettingsPath $path } | Should -Throw
    }
    It 'updates a named profile, replaces its light/dark pair and preserves defaults' {
        $path = New-AppearanceFixture '{"profiles":{"defaults":{"opacity":95,"colorScheme":"Old"},"list":[{"guid":"{11111111-1111-1111-1111-111111111111}","name":"PowerShell","colorScheme":{"light":"L","dark":"D"},"opacity":50},{"name":"Other","opacity":60}]}}'
        Set-WindowsTerminalAppearance -Theme 'ayu/light' -Opacity 75 -Profile 'powershell' -SettingsPath $path
        $saved = Read-AppearanceFixture $path
        $saved.profiles.defaults.opacity | Should -Be 95
        $saved.profiles.defaults.colorScheme | Should -BeExactly 'Old'
        $saved.profiles.list[0].opacity | Should -Be 75
        $saved.profiles.list[0].colorScheme | Should -BeExactly 'WTConfigurator/ayu/light'
        $saved.profiles.list[1].opacity | Should -Be 60
        @(Get-WindowsTerminalProfile -SettingsPath $path).Count | Should -Be 2
    }
    It 'selects GUIDs with or without braces' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"guid":"{11111111-1111-1111-1111-111111111111}","name":"PS"}]}}'
        Set-WindowsTerminalAppearance -Opacity 70 -Profile '11111111-1111-1111-1111-111111111111' -SettingsPath $path
        (Read-AppearanceFixture $path).profiles.list[0].opacity | Should -Be 70
    }
    It 'forwards the Profile alias through the theme convenience command' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"name":"PS"}]}}'
        Set-WindowsTerminalTheme 'ayu/dark' -Profile 'PS' -SettingsPath $path
        (Read-AppearanceFixture $path).profiles.list[0].colorScheme | Should -BeExactly 'WTConfigurator/ayu/dark'
    }
    It 'returns an empty list and a GUID-only profile without inventing names' {
        @(Get-WindowsTerminalProfile -SettingsPath (New-AppearanceFixture '{"profiles":{"list":[]}}')).Count | Should -Be 0
        $path = New-AppearanceFixture '{"profiles":{"list":[{"guid":"{11111111-1111-1111-1111-111111111111}"}]}}'
        $record = Get-WindowsTerminalProfile -SettingsPath $path
        $record.guid | Should -BeExactly '{11111111-1111-1111-1111-111111111111}'
        $record.name | Should -BeNullOrEmpty
    }
    It 'rejects duplicate profile names and missing profiles without writing' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"name":"PS"},{"name":"PS"}]}}'
        $before = [IO.File]::ReadAllText($path)
        { Set-WindowsTerminalAppearance -Opacity 80 -Profile 'PS' -SettingsPath $path } | Should -Throw '*ambiguous*'
        { Set-WindowsTerminalAppearance -Opacity 80 -Profile 'Missing' -SettingsPath $path } | Should -Throw '*not found*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
    It 'preserves profile overrides when setting defaults' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"name":"PS","opacity":45,"colorScheme":"Custom"}]}}'
        Set-WindowsTerminalAppearance -Opacity 80 -Theme 'ayu/dark' -SettingsPath $path -WarningAction SilentlyContinue
        (Read-AppearanceFixture $path).profiles.list[0].opacity | Should -Be 45
        (Read-AppearanceFixture $path).profiles.list[0].colorScheme | Should -BeExactly 'Custom'
    }
    It 'preserves additional managed scheme properties and avoids duplicate schemes' {
        $path = New-AppearanceFixture '{"schemes":[{"name":"WTConfigurator/ayu/dark","selectionBackground":"#123456","custom":"keep"}]}'
        Set-WindowsTerminalTheme -Theme 'ayu/dark' -SettingsPath $path
        $saved = Read-AppearanceFixture $path
        @($saved.schemes).Count | Should -Be 1
        $saved.schemes[0].selectionBackground | Should -BeExactly '#123456'
        $saved.schemes[0].custom | Should -BeExactly 'keep'
    }
    It 'rejects duplicate managed names before writing' {
        $path = New-AppearanceFixture '{"schemes":[{"name":"WTConfigurator/ayu/dark"},{"name":"wtconfigurator/ayu/dark"}]}'
        { Set-WindowsTerminalTheme 'ayu/dark' -SettingsPath $path } | Should -Throw '*Duplicate managed*'
    }
    It 'rejects a differently cased managed color key even when its value matches' {
        $color = (Get-WindowsTerminalTheme 'ayu/dark').Palette.Background
        $path = New-AppearanceFixture ('{"schemes":[{"name":"WTConfigurator/ayu/dark","Background":"' + $color + '"}]}')
        $before = [IO.File]::ReadAllText($path)
        { Set-WindowsTerminalTheme 'ayu/dark' -SettingsPath $path } | Should -Throw '*exact casing*background*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
    It 'does not misclassify a single named defaults profile as the defaults target' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"name":"defaults"},{"name":"Other","opacity":40}]}}'
        Set-WindowsTerminalAppearance -Opacity 70 -Profile 'defaults' -SettingsPath $path -WarningAction Stop
        (Read-AppearanceFixture $path).profiles.list[0].opacity | Should -Be 70
        (Read-AppearanceFixture $path).profiles.PSObject.Properties.Name | Should -Not -Contain 'defaults'
    }
    It 'does not write or back up repeat applications' {
        $path = New-AppearanceFixture
        Set-WindowsTerminalAppearance -Theme 'ayu/dark' -Opacity 80 -UseAcrylic $false -SettingsPath $path
        $before = [IO.File]::ReadAllText($path)
        $backupCount = @(Get-ChildItem $TestDrive -Filter '*.bak').Count
        $result = Set-WindowsTerminalAppearance -Theme 'ayu/dark' -Opacity 80 -UseAcrylic $false -SettingsPath $path -PassThru
        $result.Changed | Should -BeFalse
        $result.BackupPath | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
        @(Get-ChildItem $TestDrive -Filter '*.bak').Count | Should -Be $backupCount
    }
    It 'WhatIf produces no success result or filesystem changes' {
        $path = New-AppearanceFixture
        $before = @(Get-ChildItem $TestDrive).Count
        $result = Set-WindowsTerminalAppearance -Theme 'ayu/dark' -Opacity 80 -SettingsPath $path -PassThru -WhatIf
        $result | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($path) | Should -BeExactly '{}'
        @(Get-ChildItem $TestDrive).Count | Should -Be $before
    }
    It 'defaults to no success-stream output' {
        @(Set-WindowsTerminalAppearance -Opacity 80 -SettingsPath (New-AppearanceFixture)).Count | Should -Be 0
    }
    It 'preserves a read-only destination when native replacement is denied' {
        $path = New-AppearanceFixture
        $original = [IO.File]::ReadAllText($path)
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
        try {
            { Set-WindowsTerminalAppearance -Opacity 80 -SettingsPath $path -NoBackup } | Should -Throw '*Recovery files*'
            [IO.File]::ReadAllText($path) | Should -BeExactly $original
        }
        finally { if ([IO.File]::Exists($path)) { [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal) } }
    }
    It 'declining explicit confirmation leaves settings and directory contents unchanged' {
        $path = New-AppearanceFixture
        $before = @(Get-ChildItem $TestDrive -Force).Count
        $manifest = (Join-Path $script:ProjectRoot 'WTConfigurator/WTConfigurator.psd1').Replace("'", "''")
        $literalPath = $path.Replace("'", "''")
        $code = "Write-Output 'BEFORE'; Import-Module '$manifest'; Set-WindowsTerminalAppearance -Opacity 80 -SettingsPath '$literalPath' -Confirm -PassThru; Write-Output 'AFTER'"
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $info.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $output = $process.StandardOutput.ReadToEndAsync()
            $errorOutput = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine('N')
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Confirmation test process did not exit.' }
            $process.ExitCode | Should -Be 0 -Because $errorOutput.Result
            $output.Result | Should -Match 'BEFORE'
            $output.Result | Should -Match 'AFTER'
            [IO.File]::ReadAllText($path) | Should -BeExactly '{}'
            @(Get-ChildItem $TestDrive -Force).Count | Should -Be $before
        }
        finally { $process.Dispose() }
    }
}

Describe 'Exact restoration and script wrapper' {
    It 'restores commented BOM-marked UTF16 bytes and backs up corrupted current settings' {
        $backup = New-AppearanceFixture
        $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
        $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes('// saved original' + "`r`n" + '{"profiles":{"defaults":{},"list":[]},}'))
        [IO.File]::WriteAllBytes($backup, $bytes)
        $path = New-AppearanceFixture 'BROKEN CURRENT FILE'
        $result = Restore-WindowsTerminalSettings -BackupPath $backup -SettingsPath $path -PassThru -Confirm:$false
        $result.Changed | Should -BeTrue
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
        [IO.File]::ReadAllText($result.BackupPath) | Should -BeExactly 'BROKEN CURRENT FILE'
    }
    It 'rejects invalid backups and same-file restoration' {
        $path = New-AppearanceFixture
        { Restore-WindowsTerminalSettings -BackupPath $path -SettingsPath $path -Confirm:$false } | Should -Throw '*different files*'
        $backup = New-AppearanceFixture 'INVALID'
        { Restore-WindowsTerminalSettings -BackupPath $backup -SettingsPath $path -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly '{}'
    }
    It 'restoration supports WhatIf and exact no-ops' {
        $path = New-AppearanceFixture '{"opacity":80}'
        $backup = New-AppearanceFixture '{"opacity":70}'
        $result = Restore-WindowsTerminalSettings -BackupPath $backup -SettingsPath $path -WhatIf -PassThru
        $result | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($path) | Should -BeExactly '{"opacity":80}'
        [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($path))
        (Restore-WindowsTerminalSettings -BackupPath $backup -SettingsPath $path -PassThru).Changed | Should -BeFalse
    }
    It 'wrapper applies only opacity without prompting' {
        $path = New-AppearanceFixture
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $wrapper = Join-Path $script:ProjectRoot 'Set-WindowsTerminalTheme.ps1'
        $output = & $engine -NoProfile -NonInteractive -File $wrapper -Opacity 80 -SettingsPath $path -NoBackup 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        (Read-AppearanceFixture $path).profiles.defaults.opacity | Should -Be 80
    }
    It 'wrapper forwards the Profile alias while changing opacity only' {
        $path = New-AppearanceFixture '{"profiles":{"list":[{"name":"PS"}]}}'
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $wrapper = Join-Path $script:ProjectRoot 'Set-WindowsTerminalTheme.ps1'
        $output = & $engine -NoProfile -NonInteractive -File $wrapper -Opacity 75 -Profile PS -SettingsPath $path -NoBackup 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        (Read-AppearanceFixture $path).profiles.list[0].opacity | Should -Be 75
    }
    It 'interactive cancellation exits successfully without accessing settings' {
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $wrapper = (Join-Path $script:ProjectRoot 'Set-WindowsTerminalTheme.ps1').Replace("'", "''")
        $output = & $engine -NoProfile -NonInteractive -Command "function global:Read-Host { 'q' }; & '$wrapper'" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match 'Cancelled'
    }
    It 'list mode does not access a nonexistent settings file' {
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $wrapper = Join-Path $script:ProjectRoot 'Set-WindowsTerminalTheme.ps1'
        $output = & $engine -NoProfile -NonInteractive -File $wrapper -List -SettingsPath (Join-Path $TestDrive 'missing.json') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match 'ayu/dark'
    }
}
