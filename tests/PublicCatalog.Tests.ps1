Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WTConfigurator/WTConfigurator.psd1') -Force
Describe 'Public terminal catalog contract and transactions' {
    InModuleScope WTConfigurator {
        BeforeAll {
            function Add-PopularFixture {
                $flags = [pscustomobject]@{}
                $flags | Add-Member -NotePropertyName $script:fixtureId -NotePropertyValue $true
                $script:indexData | Add-Member -NotePropertyName popularity -NotePropertyValue ([pscustomobject]@{
                    version='1'; catalog_source_revision=('b' * 40)
                    source=[pscustomobject]@{ repository='Gogh-Co/gogh-website'; revision=('c' * 40); url=('https://github.com/Gogh-Co/gogh-website/blob/' + ('c' * 40) + '/app/pages/index.vue') }
                    flags=$flags; order=@($script:fixtureId); unmatched=@(); unavailable=@()
                })
            }

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

        It 'offers a remote shortcut independent of the bundled default and never resolves settings' {
            Mock Resolve-TerminalSettingsPath { throw 'Must not inspect settings' }
            $rows = @(Get-WindowsTerminalRemoteTheme -IncludeUnavailable)
            $rows.Count | Should -Be 2
            $rows[0].Source | Should -BeExactly 'PublicCatalog'
            Should -Invoke Resolve-TerminalSettingsPath -Times 0
            Should -Invoke Get-PublicCatalogText -Times 2 -Exactly
        }
        It 'keeps missing popularity unknown and fails an explicit popular request clearly' {
            $row = Get-WindowsTerminalRemoteTheme
            ($null -eq $row.Popular) | Should -BeTrue
            { Get-WindowsTerminalRemoteTheme -Popular } | Should -Throw '*no popularity metadata*'
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -Popular } | Should -Throw '*no popularity metadata*'
        }
        It 'filters true membership and preserves explicit false versus unknown' {
            Add-PopularFixture
            $rows = @(Get-WindowsTerminalRemoteTheme -Popular -IncludeUnavailable)
            $rows.Count | Should -Be 1
            $rows[0].Popular | Should -BeTrue
            $rows[0].PopularitySourceRevision | Should -BeExactly ('c' * 40)
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -Popular).Popular | Should -BeTrue
            $script:indexData.popularity.flags.($script:fixtureId) = $false
            $script:indexData.popularity.order = @()
            @(Get-WindowsTerminalRemoteTheme -Popular).Count | Should -Be 0
            (Get-WindowsTerminalRemoteTheme).Popular | Should -BeFalse
            { Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -Popular } | Should -Throw '*not a confirmed popular member*'
            @(Get-WindowsTerminalRemoteTheme -IncludeUnavailable | Where-Object { $null -eq $_.Popular }).Count | Should -Be 1
        }
        It 'rejects malformed popularity case <Case>' -TestCases @(
            @{Case='string'},@{Case='unknown'},@{Case='order'},@{Case='revision'},@{Case='version'}
        ) {
            param($Case)
            Add-PopularFixture
            switch ($Case) {
                string { $script:indexData.popularity.flags.($script:fixtureId) = 'true' }
                unknown { $script:indexData.popularity.flags | Add-Member -NotePropertyName 'gogh/unknown' -NotePropertyValue $false }
                order { $script:indexData.popularity.order += $script:fixtureId }
                revision { $script:indexData.popularity.source.revision = 'latest' }
                version { $script:indexData.popularity.version = '2' }
            }
            { Get-WindowsTerminalRemoteTheme } | Should -Throw '*popularity*'
        }
        It 'syncs compatible palettes once and enables exact offline selection without settings access' {
            Add-PopularFixture
            Mock Resolve-TerminalSettingsPath { throw 'Must not inspect settings' }
            $cache = Join-Path $TestDrive 'synced'
            $result = Sync-WindowsTerminalTheme -CachePath $cache -Popular
            $result.SyncedCount | Should -Be 1
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -Offline).Palette.Cursor | Should -BeExactly '#123456'
            @(Get-WindowsTerminalRemoteTheme -CachePath $cache -Offline -Popular).Count | Should -Be 1
            Should -Invoke Get-PublicCatalogText -Times 3 -Exactly
            Should -Invoke Resolve-TerminalSettingsPath -Times 0
        }
        It 'sync WhatIf creates no cache and makes no network request' {
            $cache = Join-Path $TestDrive 'sync-whatif'
            Sync-WindowsTerminalTheme -CachePath $cache -WhatIf
            Test-Path -LiteralPath $cache | Should -BeFalse
            Should -Invoke Get-PublicCatalogText -Times 0 -Exactly
        }
        It 'sync rejects invalid palettes without poisoning an existing validated cache' {
            $cache = Join-Path $TestDrive 'sync-failure'
            Sync-WindowsTerminalTheme -CachePath $cache | Out-Null
            $script:themeData.theme.palette.cursor = 'invalid'
            { Sync-WindowsTerminalTheme -CachePath $cache } | Should -Throw '*stopped after 0 of 1*'
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Fixture -CachePath $cache -Offline).Palette.Cursor | Should -BeExactly '#123456'
        }
        It 'sync reports cache-write failures instead of claiming success' {
            $cache = Join-Path $TestDrive 'not-a-directory'
            [IO.File]::WriteAllText($cache, 'occupied')
            { Sync-WindowsTerminalTheme -CachePath $cache -WarningAction SilentlyContinue } | Should -Throw '*stopped after 0 of 1*'
        }
        It 'sync search does not download unrelated or withheld palettes' {
            $cache = Join-Path $TestDrive 'sync-search'
            (Sync-WindowsTerminalTheme -CachePath $cache -Search '*').SyncedCount | Should -Be 0
            Should -Invoke Get-PublicCatalogText -Times 0 -ParameterFilter { $Path -like '*/themes/*' }
        }


        It 'syncs every matching palette and preserves upstream order across multiple entries' {
            Add-PopularFixture
            $other = $script:indexData.entries[0] | ConvertTo-Json | ConvertFrom-Json
            $other.id = 'gogh/' + ('d' * 64); $other.name = 'Second'; $other.path = Get-PublicThemePath $other.id
            $script:indexData.entries += $other
            $script:indexData.available_count++; $script:indexData.source_count++
            $script:indexData.popularity.flags | Add-Member -NotePropertyName $other.id -NotePropertyValue $true
            $script:indexData.popularity.order = @($other.id, $script:fixtureId)
            $script:secondTheme = $script:themeData | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $script:secondTheme.theme.id = $other.id
            $script:secondTheme.theme.name = 'Second'
            $script:secondTheme.theme.source_theme_id = 'd' * 64
            $script:secondTheme.theme.provenance.record_sha256 = 'd' * 64
            Mock Get-PublicCatalogText {
                param($Path)
                switch ($Path) {
                    'api/v1/index.json' { return $script:rootJson }
                    'api/v1/terminal/index.json' { return ($script:indexData | ConvertTo-Json -Depth 30 -Compress) }
                    $script:fixturePath { return ($script:themeData | ConvertTo-Json -Depth 30 -Compress) }
                    default { return ($script:secondTheme | ConvertTo-Json -Depth 30 -Compress) }
                }
            }
            @(Get-WindowsTerminalRemoteTheme -Popular)[0].DisplayName | Should -BeExactly 'Second'
            $cache = Join-Path $TestDrive 'multi-sync'
            (Sync-WindowsTerminalTheme -CachePath $cache).SyncedCount | Should -Be 2
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Second -CachePath $cache -Offline).Id | Should -BeExactly $other.id
            $script:secondTheme.theme.palette.cursor = 'invalid'
            { Sync-WindowsTerminalTheme -CachePath $cache } | Should -Throw '*stopped after 1 of 2*'
            (Get-WindowsTerminalTheme -Source PublicCatalog -Theme Second -CachePath $cache -Offline).Palette.Cursor | Should -BeExactly '#123456'
        }

        It 'does not silently skip available unsupported formats during an all-theme sync' {
            $script:indexData.entries[0].format = 'unsupported'
            { Sync-WindowsTerminalTheme -CachePath (Join-Path $TestDrive 'unsupported-sync') } | Should -Throw '*unsupported formats*'
            Should -Invoke Get-PublicCatalogText -Times 0 -ParameterFilter { $Path -like '*/themes/*' }
        }
    }
}
