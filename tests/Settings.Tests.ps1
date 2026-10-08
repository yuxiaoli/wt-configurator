# InModuleScope resolves its module during Pester discovery.
Import-Module (Join-Path $PSScriptRoot '../WTConfigurator/WTConfigurator.psd1') -Force

Describe 'Safe Terminal settings parsing' {
    InModuleScope WTConfigurator {
        It 'accepts JSONC while preserving string escapes, arrays, and unknown settings' {
            $text = @'
{
 // a URL and comment markers remain data inside strings
 "unknown": {"url":"https://example.test/a//b", "text":"quote \" slash \\ unicode \u0041",},
 "profiles":{"defaults":{"colorScheme":{"light":"One"},"opacity":42.5,"useAcrylic":false},"list":[],},
 "schemes":[],
}
'@
            $settings = ConvertFrom-SafeTerminalJson -Text $text
            $settings.unknown.url | Should -BeExactly 'https://example.test/a//b'
            $settings.unknown.text | Should -BeExactly 'quote " slash \ unicode A'
            $settings.profiles.defaults.colorScheme.light | Should -BeExactly 'One'
            $settings.profiles.defaults.opacity | Should -Be 42.5
            $settings.profiles.defaults.useAcrylic | Should -BeFalse
            $settings.profiles.list | Should -HaveCount 0
            { ConvertTo-SafeTerminalJson -Settings $settings } | Should -Not -Throw
        }

        It 'allows a dark-only pair and sparse dynamic profile override' {
            $settings = ConvertFrom-SafeTerminalJson -Text '{"profiles":{"defaults":{"colorScheme":{"dark":"Two"}},"list":[{"guid":"{12345678-1234-1234-1234-123456789012}","hidden":true}]}}'
            $settings.profiles.defaults.colorScheme.dark | Should -BeExactly 'Two'
            $settings.profiles.list[0].hidden | Should -BeTrue
        }

        It 'rejects <Label> before serializing an update' -ForEach @(
            @{ Label = 'a singleton root array'; Json = '[{"profiles":{}}]' }
            @{ Label = 'a scalar root'; Json = '"text"' }
            @{ Label = 'identical duplicate keys'; Json = '{"x":1,"x":2}' }
            @{ Label = 'escaped identical duplicate keys'; Json = '{"x":1,"\u0078":2}' }
            @{ Label = 'case-distinct keys'; Json = '{"Foo":1,"foo":2}' }
            @{ Label = 'number rounding'; Json = '{"x":0.123456789012345678901234567890123456789}' }
            @{ Label = 'negative zero normalization'; Json = '{"x":-0}' }
            @{ Label = 'an unterminated comment'; Json = '{/* missing end' }
            @{ Label = 'a comma without an item'; Json = '{,}' }
            @{ Label = 'a missing value'; Json = '{"x":,}' }
            @{ Label = 'an unsupported escape'; Json = '{"x":"\q"}' }
            @{ Label = 'a non-JSON number'; Json = '{"x":NaN}' }
            @{ Label = 'a null schemes container'; Json = '{"schemes":null}' }
            @{ Label = 'a null scheme entry'; Json = '{"schemes":[null]}' }
            @{ Label = 'an unnamed scheme'; Json = '{"schemes":[{}]}' }
            @{ Label = 'legacy profile arrays'; Json = '{"profiles":[]}' }
            @{ Label = 'scalar defaults'; Json = '{"profiles":{"defaults":"bad"}}' }
            @{ Label = 'a scalar profile list'; Json = '{"profiles":{"list":{}}}' }
            @{ Label = 'a null profile entry'; Json = '{"profiles":{"list":[null]}}' }
            @{ Label = 'a malformed GUID'; Json = '{"profiles":{"list":[{"guid":"bad"}]}}' }
            @{ Label = 'a numeric light scheme'; Json = '{"profiles":{"defaults":{"colorScheme":{"light":1}}}}' }
            @{ Label = 'a null scheme selector'; Json = '{"profiles":{"defaults":{"colorScheme":null}}}' }
            @{ Label = 'root casing'; Json = '{"Profiles":{}}' }
            @{ Label = 'nested casing'; Json = '{"profiles":{"Defaults":{}}}' }
            @{ Label = 'pair casing'; Json = '{"profiles":{"defaults":{"colorScheme":{"Light":"One"}}}}' }
            @{ Label = 'opacity casing'; Json = '{"profiles":{"defaults":{"Opacity":50}}}' }
            @{ Label = 'an out of range opacity'; Json = '{"profiles":{"defaults":{"opacity":101}}}' }
            @{ Label = 'a string opacity'; Json = '{"profiles":{"defaults":{"opacity":"50"}}}' }
            @{ Label = 'a string acrylic flag'; Json = '{"profiles":{"defaults":{"useAcrylic":"false"}}}' }
        ) {
            { ConvertFrom-SafeTerminalJson -Text $Json } | Should -Throw
        }

        It 'compares decoded string tokens with ordinal case sensitivity' {
            $expected = @(Get-JsonTokens -Text '{"value":"One"}')
            $same = @(Get-JsonTokens -Text '{"value":"\u004Fne"}')
            $different = @(Get-JsonTokens -Text '{"value":"one"}')
            { Assert-JsonTokenEquality -Expected $expected -Actual $same } | Should -Not -Throw
            { Assert-JsonTokenEquality -Expected $expected -Actual $different } | Should -Throw
        }

        It 'retains a timestamp string when the engine supports DateKind String' {
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                $settings = ConvertFrom-SafeTerminalJson -Text '{"value":"2020-09-07T09:44:13.769+02:00"}'
                $settings.value | Should -BeOfType [string]
                $settings.value | Should -BeExactly '2020-09-07T09:44:13.769+02:00'
            }
            elseif ($PSVersionTable.PSVersion.Major -ge 6) {
                { ConvertFrom-SafeTerminalJson -Text '{"value":"2020-09-07T09:44:13.769+02:00"}' } | Should -Throw
            }
            else {
                $settings = ConvertFrom-SafeTerminalJson -Text '{"value":"2020-09-07T09:44:13.769+02:00"}'
                $settings.value | Should -BeExactly '2020-09-07T09:44:13.769+02:00'
            }
        }

        It 'rejects depth loss rather than truncating unknown settings' {
            $text = '1'
            foreach ($i in 1..105) { $text = '{"nested":' + $text + '}' }
            { ConvertFrom-SafeTerminalJson -Text $text } | Should -Throw
        }

        It 'rejects case aliasing in setters and preserves a typed empty array' {
            $object = [pscustomobject]@{ Name = 'original' }
            { Set-ObjectProperty -Object $object -Name 'name' -Value 'new' } | Should -Throw
            $object.Name | Should -BeExactly 'original'
            $object = [pscustomobject]@{}
            Set-ObjectProperty -Object $object -Name 'schemes' -Value ([object[]]@())
            ,$object.schemes | Should -BeOfType [object[]]
            $object.schemes | Should -HaveCount 0
        }
    }
}

Describe 'Terminal file snapshots and writes' {
    InModuleScope WTConfigurator {
        BeforeEach {
            $settingsDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void] [IO.Directory]::CreateDirectory($settingsDirectory)
            $settingsPath = Join-Path $settingsDirectory 'settings.json'
            $originalText = "{`r`n // original comment`r`n `"profiles`":{`"defaults`":{},`"list`":[]},`r`n `"schemes`":[],`r`n}`r`n"
            $originalEncoding = New-Object Text.UTF8Encoding($true)
            $originalBytes = [byte[]]@($originalEncoding.GetPreamble() + $originalEncoding.GetBytes($originalText))
            [IO.File]::WriteAllBytes($settingsPath, $originalBytes)
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
        }

        It 'hashes the exact snapshot bytes and reads validated backup bytes without enumeration' {
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            $snapshot.Hash | Should -BeExactly (Get-TerminalByteHash -Bytes $originalBytes)
            $snapshot.Text | Should -BeExactly $originalText
            $bytes = Read-ValidatedTerminalBackup -Path $settingsPath
            ,$bytes | Should -BeOfType [byte[]]
            [Convert]::ToBase64String($bytes) | Should -BeExactly ([Convert]::ToBase64String($originalBytes))
        }

        It 'accepts BOM-marked UTF16 in either byte order with exact snapshot retention' -ForEach @(
            @{ BigEndian = $false }
            @{ BigEndian = $true }
        ) {
            $encoding = New-Object Text.UnicodeEncoding($BigEndian, $true, $true)
            $bytes = [byte[]]@($encoding.GetPreamble() + $encoding.GetBytes('{}'))
            [IO.File]::WriteAllBytes($settingsPath, $bytes)
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            $snapshot.Text | Should -BeExactly '{}'
            [Convert]::ToBase64String($snapshot.Bytes) | Should -BeExactly ([Convert]::ToBase64String($bytes))
        }

        It 'rejects malformed UTF8 and UTF16 rather than inserting replacement characters' {
            { ConvertFrom-TerminalBytes -Bytes ([byte[]]@(123,34,120,34,58,34,192,175,34,125)) } | Should -Throw
            { ConvertFrom-TerminalBytes -Bytes ([byte[]]@(255,254,123)) } | Should -Throw
            { ConvertFrom-TerminalBytes -Bytes ([byte[]]@(255,254,0,0,123,0,0,0)) } | Should -Throw
        }

        It 'replaces settings atomically and keeps an exact byte backup' {
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            Set-ObjectProperty -Object $snapshot.Settings.profiles.defaults -Name 'opacity' -Value 70
            $json = ConvertTo-SafeTerminalJson -Settings $snapshot.Settings
            $backupPath = Invoke-TerminalWrite -Path $settingsPath -OriginalHash $snapshot.Hash -Bytes ($utf8.GetBytes($json))
            $backupPath | Should -Not -BeNullOrEmpty
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath)) | Should -BeExactly ([Convert]::ToBase64String($originalBytes))
            (Read-TerminalSnapshot -Path $settingsPath).Settings.profiles.defaults.opacity | Should -Be 70
            @(Get-ChildItem -LiteralPath $settingsDirectory -Force -Filter '.settings.*') | Should -HaveCount 0
        }

        It 'removes the transient recovery backup only after a successful NoBackup write' {
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            $backupPath = Invoke-TerminalWrite -Path $settingsPath -OriginalHash $snapshot.Hash -Bytes ($utf8.GetBytes('{}')) -NoBackup
            $backupPath | Should -BeNullOrEmpty
            [IO.File]::ReadAllText($settingsPath) | Should -BeExactly '{}'
            @(Get-ChildItem -LiteralPath $settingsDirectory -Force -Filter '.settings.*') | Should -HaveCount 0
        }

        It 'aborts a concurrent change after closing the temp file and retains it' {
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            $changedBytes = $utf8.GetBytes('{"external":true}')
            [IO.File]::WriteAllBytes($settingsPath, $changedBytes)
            Mock Invoke-TerminalReplace { throw 'Replacement must not be reached' }
            { Invoke-TerminalWrite -Path $settingsPath -OriginalHash $snapshot.Hash -Bytes ($utf8.GetBytes('{}')) } | Should -Throw '*changed*'
            Should -Invoke Invoke-TerminalReplace -Times 0 -Exactly
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath)) | Should -BeExactly ([Convert]::ToBase64String($changedBytes))
            $temp = @(Get-ChildItem -LiteralPath $settingsDirectory -Force -Filter '.settings.*.tmp')
            $temp | Should -HaveCount 1
            $stream = [IO.File]::Open($temp[0].FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
        }

        It 'preserves original recovery bytes on a partial native replacement failure under NoBackup' {
            $snapshot = Read-TerminalSnapshot -Path $settingsPath
            Mock Invoke-TerminalReplace {
                [IO.File]::Move($DestinationPath, $BackupPath)
                throw 'simulated failure after moving the original'
            }
            { Invoke-TerminalWrite -Path $settingsPath -OriginalHash $snapshot.Hash -Bytes ($utf8.GetBytes('{}')) -NoBackup } | Should -Throw '*Recovery files*'
            Test-Path -LiteralPath $settingsPath | Should -BeFalse
            $recovery = @(Get-ChildItem -LiteralPath $settingsDirectory -Force -Filter '.settings.*.old')
            $recovery | Should -HaveCount 1
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($recovery[0].FullName)) | Should -BeExactly ([Convert]::ToBase64String($originalBytes))
            @(Get-ChildItem -LiteralPath $settingsDirectory -Force -Filter '.settings.*.tmp') | Should -HaveCount 1
        }

        It 'returns an acquired named mutex that the caller can release' {
            $mutex = Enter-TerminalMutex -Path $settingsPath
            try { $mutex | Should -BeOfType [Threading.Mutex] }
            finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
        }

        It 'creates the mutex in the global namespace for other Windows sessions' {
            $mutex = Enter-TerminalMutex -Path $settingsPath
            $opened = $null
            try {
                $canonicalPath = [IO.Path]::GetFullPath($settingsPath).ToUpperInvariant()
                $name = 'Global\WTConfigurator.' + (Get-TerminalByteHash -Bytes ([Text.Encoding]::UTF8.GetBytes($canonicalPath)))
                $opened = [Threading.Mutex]::OpenExisting($name)
                $opened | Should -BeOfType [Threading.Mutex]
            }
            finally {
                if ($null -ne $opened) { $opened.Dispose() }
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }
        }

        It 'blocks a second process using the same path with different casing' {
            $mutex = Enter-TerminalMutex -Path $settingsPath
            $job = $null
            try {
                $privateScript = Join-Path (Get-Module WTConfigurator).ModuleBase 'Private/Settings.ps1'
                $job = Start-Job -ScriptBlock {
                    param($ScriptPath, $TargetPath)
                    . $ScriptPath
                    $otherMutex = $null
                    try {
                        $otherMutex = Enter-TerminalMutex -Path $TargetPath
                        'Unexpectedly acquired the mutex'
                    }
                    catch { $_.Exception.Message }
                    finally {
                        if ($null -ne $otherMutex) { $otherMutex.ReleaseMutex(); $otherMutex.Dispose() }
                    }
                } -ArgumentList $privateScript, $settingsPath.ToUpperInvariant()
                $message = $job | Receive-Job -Wait -AutoRemoveJob
                $job = $null
                $message | Should -BeLike '*Another WTConfigurator operation*'
            }
            finally {
                if ($null -ne $job) { $job | Stop-Job; $job | Remove-Job -Force }
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }
        }
    }
}

Describe 'Terminal settings discovery' {
    InModuleScope WTConfigurator {
        BeforeEach {
            $previousLocalAppData = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = Join-Path $TestDrive 'localappdata'
            $stable = Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json'
            $preview = Join-Path $env:LOCALAPPDATA 'Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json'
            Mock Get-AncestorExecutablePaths { @() }
        }
        AfterEach { $env:LOCALAPPDATA = $previousLocalAppData }

        It 'honors an explicit path and does not inspect ancestry' {
            $explicit = Join-Path $TestDrive 'explicit.json'
            [IO.File]::WriteAllText($explicit, '{}')
            Resolve-TerminalSettingsPath -ExplicitPath $explicit | Should -BeExactly $explicit
            Should -Invoke Get-AncestorExecutablePaths -Times 0 -Exactly
        }

        It 'selects the only standard installation and rejects ambiguity' {
            [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stable))
            [IO.File]::WriteAllText($stable, '{}')
            Resolve-TerminalSettingsPath | Should -BeExactly $stable
            [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($preview))
            [IO.File]::WriteAllText($preview, '{}')
            { Resolve-TerminalSettingsPath } | Should -Throw '*Multiple*'
        }

        It 'uses the active Preview ancestor when Stable is also installed' {
            foreach ($path in @($stable, $preview)) {
                [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                [IO.File]::WriteAllText($path, '{}')
            }
            Mock Get-AncestorExecutablePaths { @('C:\Program Files\WindowsApps\Microsoft.WindowsTerminalPreview_1.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe') }
            Resolve-TerminalSettingsPath | Should -BeExactly $preview
        }

        It 'discovers portable settings beside the active executable' {
            $portableDirectory = Join-Path $TestDrive 'portable'
            $portable = Join-Path $portableDirectory 'settings/settings.json'
            [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($portable))
            [IO.File]::WriteAllText($portable, '{}')
            Mock Get-AncestorExecutablePaths { @(Join-Path $portableDirectory 'WindowsTerminal.exe') }
            Resolve-TerminalSettingsPath | Should -BeExactly $portable
        }
    }
}
