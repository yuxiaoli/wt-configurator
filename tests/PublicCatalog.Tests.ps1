Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WTConfigurator/WTConfigurator.psd1') -Force
Describe 'Public terminal catalog contract and transactions' {
    InModuleScope WTConfigurator {
        BeforeAll {
            function New-PublicFixtureData {
                $script:fixtureId = 'gogh/' + ('a' * 64)
                $script:fixturePath = Get-PublicThemePath $script:fixtureId
                $script:rootJson = '{"api_version":"1","categories":{"terminal":{"path":"api/v1/terminal/index.json"}}}'
                $script:indexData = [pscustomobject]@{
                    api_version = '1'; category = 'terminal'; available_count = 1; excluded_count = 1; source_count = 2
                    entries = @([pscustomobject]@{ id = $script:fixtureId; name = 'Fixture'; source_id = 'gogh'; format = 'gogh'; path = $script:fixturePath })
                    excluded = @([pscustomobject]@{ id = 'terminal/held/default'; name = 'Held'; source_id = 'terminal'; reason = 'distribution-license-unverified' })
                }
                $script:themeData = [pscustomobject]@{
                    api_version = '1'; category = 'terminal'; theme = [pscustomobject]@{
                        id = $script:fixtureId; name = 'Fixture'; source_id = 'gogh'; source_theme_id = ('a' * 64); format = 'gogh'
                        palette = [pscustomobject]@{ background = '#010203'; foreground = '#AABBCC'; cursor = '#123456'; accent = '#654321'; ansi = @(0..15 | ForEach-Object { '#{0:X6}' -f ($_ + 100) }) }
                        publication = [pscustomobject]@{ source_url = 'https://example.test/themes.json'; source_revision = ('b' * 40); license_documents = @('licenses/MIT.txt') }
                        provenance = [pscustomobject]@{ revision = ('b' * 40); repository = 'Example/Fixture'; record_sha256 = ('a' * 64) }
                        license = [pscustomobject]@{ expression = 'MIT'; documents = @('https://example.test/LICENSE') }
                    }
                }
            }
            function New-PublicSettingsFixture {
                $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
                $json = '// exact restore including comment and trailing comma
{"unknown":{"values":[1,true,"kept"]},"profiles":{"defaults":{"font":{"face":"Kept"},"opacity":93,"unfocusedAppearance":{"opacity":42}},"list":[{"name":"PS","colorScheme":"MyScheme","commandline":"pwsh.exe"},{"name":"Other","hidden":false}]},"schemes":[{"name":"MyScheme","background":"#010101"}],"actions":[{"command":"paste","keys":"ctrl+v"}],}'
                [IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($true)))
                return $path
            }
        }
        BeforeEach {
            New-PublicFixtureData
            Mock Get-PublicCatalogText {
                param($Path)
                switch ($Path) {
                    'api/v1/index.json' { return $script:rootJson }
                    'api/v1/terminal/index.json' { return ($script:indexData | ConvertTo-Json -Depth 30 -Compress) }
                    $script:fixturePath { return ($script:themeData | ConvertTo-Json -Depth 30 -Compress) }
                    default { throw "Unexpected network path $Path" }
                }
            }
        }
        It 'lists stable identities without fetching palettes or implying they have been validated' {
            $rows = @(Get-WindowsTerminalTheme -Source PublicCatalog)
            $rows.Count | Should -Be 1
            $rows[0].Id | Should -BeExactly $script:fixtureId
            $rows[0].Compatibility | Should -BeExactly 'RequiresPaletteValidation'
            $rows[0].WithheldCount | Should -Be 1
            Should -Invoke Get-PublicCatalogText -Times 2 -Exactly
        }
        It 'exposes withheld reasons and refuses their selection without a theme request' {
            $rows = @(Get-WindowsTerminalTheme -Source PublicCatalog -IncludeUnavailable -Search held)
            $rows.Count | Should -Be 1
            $rows[0].Available | Should -BeFalse
            $rows[0].Compatibility | Should -Match 'distribution-license-unverified'
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme 'Held' } | Should -Throw '*withheld*'
            Should -Invoke Get-PublicCatalogText -Times 0 -ParameterFilter { $Path -like '*/themes/*' }
        }
        It 'does not fall back to a bundled theme with the same selector' {
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme 'ayu/dark' } | Should -Throw '*absent*'
        }
        It 'uses literal search and exact case-insensitive ID selection' {
            @(Get-WindowsTerminalTheme -Source PublicCatalog -Search '*').Count | Should -Be 0
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme $script:fixtureId.ToUpperInvariant()).Id | Should -BeExactly $script:fixtureId
        }
        It 'rejects ambiguous names with candidate stable IDs' {
            $other = $script:indexData.entries[0] | ConvertTo-Json | ConvertFrom-Json
            $other.id = 'gogh/' + ('c' * 64); $other.path = Get-PublicThemePath $other.id
            $script:indexData.entries += $other
            $script:indexData.available_count++; $script:indexData.source_count++
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture } | Should -Throw '*ambiguous*'
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme $script:fixtureId).Id | Should -BeExactly $script:fixtureId
        }
        It 'lists an unsupported format honestly and refuses application' {
            $script:indexData.entries[0].format = 'editor'
            (Get-WindowsTerminalTheme -Source PublicCatalog).Compatibility | Should -BeExactly 'UnsupportedFormat: editor'
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture } | Should -Throw '*Incompatible*'
        }
        It 'rejects an incorrect index path before fetching it' {
            $script:rootJson = '{"api_version":"1","categories":{"terminal":{"path":"https://private.test/secret"}}}'
            { Get-WindowsTerminalTheme -Source PublicCatalog } | Should -Throw '*index path*'
            Should -Invoke Get-PublicCatalogText -Times 1 -Exactly
        }
        It 'rejects malformed index case <Case>' -TestCases @(
            @{Case='version'},@{Case='category'},@{Case='count'},@{Case='duplicate'},@{Case='escape'},@{Case='wrongHash'},@{Case='missing'}
        ) {
            param($Case)
            switch ($Case) {
                version { $script:indexData.api_version = '2' }
                category { $script:indexData.category = 'editor' }
                count { $script:indexData.available_count = 9 }
                duplicate { $script:indexData.excluded[0].id = $script:fixtureId }
                escape { $script:indexData.entries[0].path = '../private.json' }
                wrongHash { $script:indexData.entries[0].path = 'api/v1/terminal/themes/' + ('f' * 64) + '.json' }
                missing { $script:indexData.PSObject.Properties.Remove('excluded') }
            }
            { Get-WindowsTerminalTheme -Source PublicCatalog } | Should -Throw
        }
        It 'rejects incompatible payload case <Case> before touching settings' -TestCases @(
            @{Case='version'},@{Case='category'},@{Case='id'},@{Case='name'},@{Case='source'},@{Case='format'},@{Case='ansi'},@{Case='alpha'},@{Case='indexed'},@{Case='cursor'},@{Case='revision'},@{Case='record'},@{Case='license'},@{Case='licensePath'}
        ) {
            param($Case)
            $path = New-PublicSettingsFixture
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
            switch ($Case) {
                version { $script:themeData.api_version = '2' }
                category { $script:themeData.category = 'editor' }
                id { $script:themeData.theme.id = 'gogh/wrong' }
                name { $script:themeData.theme.name = 'Wrong' }
                source { $script:themeData.theme.source_id = 'private' }
                format { $script:themeData.theme.format = 'unknown' }
                ansi { $script:themeData.theme.palette.ansi = @('#000000') }
                alpha { $script:themeData.theme.palette.background = '#FFFFFFFF' }
                indexed { $script:themeData.theme.palette.foreground = 'indexed:7' }
                cursor { $script:themeData.theme.palette.PSObject.Properties.Remove('cursor') }
                revision { $script:themeData.theme.publication.source_revision = ('c' * 40) }
                record { $script:themeData.theme.provenance.record_sha256 = ('d' * 64) }
                license { $script:themeData.theme.publication.license_documents = @() }
                licensePath { $script:themeData.theme.publication.license_documents = @('../private.txt') }
            }
            { Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -SettingsPath $path } | Should -Throw
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly $before
            @(Get-ChildItem ($path + '*')).Count | Should -Be 1
        }
        It 'maps cursor and every ANSI slot while preserving unrelated settings and exact restoration' {
            $path = New-PublicSettingsFixture
            $before = [IO.File]::ReadAllBytes($path)
            $original = (Read-TerminalSnapshot $path).Settings
            $result = Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -SettingsPath $path -PassThru
            $saved = (Read-TerminalSnapshot $path).Settings
            $saved.profiles.defaults.colorScheme | Should -BeExactly ('WTConfigurator/' + $script:fixtureId)
            $saved.schemes[1].cursorColor | Should -BeExactly '#123456'
            $keys = @('black','red','green','yellow','blue','purple','cyan','white','brightBlack','brightRed','brightGreen','brightYellow','brightBlue','brightPurple','brightCyan','brightWhite')
            for ($i=0; $i -lt 16; $i++) { $saved.schemes[1].($keys[$i]) | Should -BeExactly $script:themeData.theme.palette.ansi[$i] }
            foreach ($key in @('unknown','actions')) { ($saved.$key | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($original.$key | ConvertTo-Json -Depth 30 -Compress) }
            ($saved.profiles.list | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($original.profiles.list | ConvertTo-Json -Depth 30 -Compress)
            ($saved.schemes[0] | ConvertTo-Json -Compress) | Should -BeExactly ($original.schemes[0] | ConvertTo-Json -Compress)
            $saved.profiles.defaults.PSObject.Properties.Remove('colorScheme')
            ($saved.profiles.defaults | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($original.profiles.defaults | ConvertTo-Json -Depth 30 -Compress)
            $result.ThemeProvenance.SourceRevision | Should -BeExactly ('b' * 40)
            $result.ThemeProvenance.ContentSHA256 | Should -Match '^[a-f0-9]{64}$'
            (Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -SettingsPath $path -PassThru).Changed | Should -BeFalse
            $restore = Restore-WindowsTerminalSettings -BackupPath $result.BackupPath -SettingsPath $path -PassThru
            $restore.Changed | Should -BeTrue
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly ([Convert]::ToBase64String($before))
        }
        It 'targets one profile with the public source while retaining defaults' {
            $path = New-PublicSettingsFixture
            Set-WindowsTerminalAppearance -Source PublicCatalog -Theme Fixture -Profile PS -SettingsPath $path -Opacity 80
            $saved = (Read-TerminalSnapshot $path).Settings
            $saved.profiles.defaults.opacity | Should -Be 93
            $saved.profiles.list[0].colorScheme | Should -BeExactly ('WTConfigurator/' + $script:fixtureId)
            $saved.profiles.list[0].commandline | Should -BeExactly 'pwsh.exe'
        }
        It 'supports explicit offline cached selection with no network' {
            $cache = Join-Path $TestDrive 'cache'
            $online = Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache
            Mock Get-PublicCatalogText { throw 'Network is unavailable' }
            $offline = Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -Offline
            $offline.ContentSHA256 | Should -BeExactly $online.ContentSHA256
            $offline.CacheStatus | Should -BeExactly 'Offline'
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache } | Should -Throw '*request failed*'
            $path = New-PublicSettingsFixture
            (Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -Offline -SettingsPath $path -PassThru).Changed | Should -BeTrue
        }
        It 'preserves valid cached payload after invalid online response' {
            $cache = Join-Path $TestDrive 'cache-retain'
            $online = Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache
            $script:themeData.theme.palette.ansi = @()
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache } | Should -Throw
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -Offline).ContentSHA256 | Should -BeExactly $online.ContentSHA256
        }
        It 'fails closed with a missing or corrupt cache' {
            { Get-WindowsTerminalTheme -Source PublicCatalog -Offline } | Should -Throw '*missing*'
            $cache = Join-Path $TestDrive 'cache-corrupt'
            Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache | Out-Null
            Get-ChildItem $cache -Filter '*.json' | ForEach-Object { [IO.File]::WriteAllText($_.FullName, '{}') }
            { Get-WindowsTerminalTheme -Source PublicCatalog -Offline -CachePath $cache } | Should -Throw
        }
        It 'allows validated online use when cache writes fail' {
            $cache = Join-Path $TestDrive 'not-a-directory'
            [IO.File]::WriteAllText($cache,'kept')
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -WarningAction SilentlyContinue).Compatibility | Should -BeExactly 'Validated'
            [IO.File]::ReadAllText($cache) | Should -BeExactly 'kept'
        }
        It 'WhatIf writes neither settings nor cache' {
            $path = New-PublicSettingsFixture
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
            $cache = Join-Path $TestDrive 'whatif-cache'
            Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -SettingsPath $path -CachePath $cache -WhatIf
            Test-Path $cache | Should -BeFalse
            @(Get-ChildItem ($path + '*')).Count | Should -Be 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly $before
        }
        It 'network failure leaves settings and backups untouched' {
            $path = New-PublicSettingsFixture
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
            Mock Get-PublicCatalogText { throw 'Timeout' }
            { Set-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -SettingsPath $path } | Should -Throw '*request failed*'
            @(Get-ChildItem ($path + '*')).Count | Should -Be 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly $before
        }
    }
}
