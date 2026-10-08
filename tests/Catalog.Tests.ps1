#requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '../tools/Catalog.ps1')
    $script:snapshotPath = Join-Path $PSScriptRoot '../data/terminal-themes.json'
    $script:originalHash = Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($script:snapshotPath))
    $script:archive = Read-WTCatalogSnapshot -Path $script:snapshotPath
    $script:apprenticeSvg = $script:archive.documents['https://terminalcolors.com/images/colors/apprentice-default.svg'].text
}

Describe 'Catalog provenance and coverage validation' {
    It 'validates all 112 shipped themes and 152 source documents without changing the archive' {
        $result = & (Join-Path $PSScriptRoot '../tools/Test-Catalog.ps1') -SnapshotPath $script:snapshotPath
        $result.Valid | Should -BeTrue
        $result.Themes | Should -Be 112
        $result.Documents | Should -Be 152
        (Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($script:snapshotPath))) | Should -Be $script:originalHash
    }

    It 'rejects a source hash mismatch' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/'].sha256 = '0' * 64
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*hash mismatch*'
    }

    It 'rejects alpha colors even when allowed by the provenance schema' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.themes[0].palette.background = '#26262680'
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*alpha is unsupported*'
    }

    It 'rejects incomplete coverage, duplicate IDs, missing originals, and reversed timestamps' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.discovery.expected_count++
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*Discovery coverage*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.themes += $copy.themes[0]
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*Duplicate theme ID*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents.Remove($copy.themes[0].originals.svg)
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*Missing original document*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.finished_at = '2026-10-06T00:00:00Z'
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*precedes started_at*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/'].fetched_at = '2026-10-08T00:00:00Z'
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*after snapshot finished_at*'
    }

    It 'rejects partial snapshots and ambiguous full names' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.status = 'partial'
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*Only complete snapshots*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.themes[1].family_name = $copy.themes[0].family_name
        $copy.themes[1].name = $copy.themes[0].name
        { Assert-WTCatalogSnapshot -Snapshot $copy } | Should -Throw '*Duplicate full theme name*'
    }
}

Describe 'Offline source replay and palette extraction' {
    It 'rebuilds all family variants and all palette values exactly from archived HTML and SVG' {
        $rebuilt = Get-WTCatalogSnapshot -ReplaySnapshot $script:archive
        Assert-WTCatalogSnapshot -Snapshot $rebuilt
        $rebuilt.themes.Count | Should -Be 112
        $rebuilt.documents.Count | Should -Be 152
        ($rebuilt.themes | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly ($script:archive.themes | ConvertTo-Json -Depth 100 -Compress)
        @($rebuilt.themes | Where-Object { $_.mode -eq 'unknown' }).Count | Should -Be 15
    }

    It 'extracts normal and bright ANSI indices from row labels' {
        $palette = ConvertFrom-WTCatalogSvg -Text $script:apprenticeSvg -ThemeId 'apprentice/default'
        ($palette.ansi -join ',') | Should -BeExactly ($script:archive.themes[0].palette.ansi -join ',')
        $palette.foreground | Should -Be '#BCBCBC'
    }

    It 'rejects malformed XML, DTDs, missing ANSI indices, and duplicate indices' {
        { ConvertFrom-WTCatalogSvg -Text '<svg>' -ThemeId 'test/default' } | Should -Throw '*Invalid SVG*'
        { ConvertFrom-WTCatalogSvg -Text '<!DOCTYPE svg [<!ENTITY value "x">]><svg xmlns="http://www.w3.org/2000/svg" />' -ThemeId 'test/default' } | Should -Throw '*Invalid SVG*'
        $missing = $script:apprenticeSvg.Replace('>1;37m<', '>ignored<')
        { ConvertFrom-WTCatalogSvg -Text $missing -ThemeId 'test/default' } | Should -Throw '*expected all 16*'
        $duplicate = $script:apprenticeSvg.Replace('>1;37m<', '>1;36m<')
        { ConvertFrom-WTCatalogSvg -Text $duplicate -ThemeId 'test/default' } | Should -Throw '*Duplicate ANSI index*'
    }

    It 'detects a family detail page that no longer covers the homepage count' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/'].text = $copy.documents['https://terminalcolors.com/'].text.Replace('&quot;totalVariants&quot;:[0,1]', '&quot;totalVariants&quot;:[0,2]')
        { Get-WTCatalogSnapshot -ReplaySnapshot $copy } | Should -Throw '*Partial variant coverage*'
    }

    It 'rejects source pages that lose classification records or disagree on background' {
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/tags/dark/'].text = '<html>Unsupported page</html>'
        { Get-WTCatalogSnapshot -ReplaySnapshot $copy } | Should -Throw '*no recognizable theme records*'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/images/colors/apprentice-default.svg'].text = $script:apprenticeSvg.Replace('fill="#262626"', 'fill="#000000"')
        { Get-WTCatalogSnapshot -ReplaySnapshot $copy } | Should -Throw '*Background differs*'
    }

    It 'blocks downloads and foreign source hosts before any request' {
        Mock Invoke-WebRequest { throw 'Network must not be used in this test.' }
        { Get-WTCatalogDocument -Url 'https://terminalcolors.com/downloads/anything' } | Should -Throw '*Unsupported catalog source URL*'
        { Get-WTCatalogDocument -Url 'https://example.com/' } | Should -Throw '*Unsupported catalog source URL*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'reports a network failure without changing the canonical archive' {
        Mock Invoke-WebRequest { throw 'Injected network failure.' }
        { Get-WTCatalogSnapshot } | Should -Throw '*Injected network failure*'
        (Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($script:snapshotPath))) | Should -Be $script:originalHash
    }
}

Describe 'Deterministic build and catalog promotion' {
    It 'refuses to replace the source snapshot with the lean build output' {
        { & (Join-Path $PSScriptRoot '../tools/Build-Catalog.ps1') -SnapshotPath $script:snapshotPath -OutputPath $script:snapshotPath } | Should -Throw '*must not overwrite*'
        (Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($script:snapshotPath))) | Should -Be $script:originalHash
    }
    It 'writes a lean identical UTF-8 catalog with LF endings on repeat builds' {
        $output = Join-Path $TestDrive 'runtime/themes.json'
        & (Join-Path $PSScriptRoot '../tools/Build-Catalog.ps1') -SnapshotPath $script:snapshotPath -OutputPath $output | Out-Null
        $bytes = [IO.File]::ReadAllBytes($output)
        $hash = Get-WTCatalogHash -Bytes $bytes
        $bytes[0] | Should -Be 123
        $bytes | Should -Not -Contain 13
        $bytes.Length | Should -BeLessThan 100000
        $runtime = [IO.File]::ReadAllText($output) | ConvertFrom-Json -AsHashtable
        $runtime.themes.Count | Should -Be 112
        $runtime.Contains('documents') | Should -BeFalse
        $runtime.themes[0].Contains('originals') | Should -BeFalse
        & (Join-Path $PSScriptRoot '../tools/Build-Catalog.ps1') -SnapshotPath $script:snapshotPath -OutputPath $output | Out-Null
        (Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($output))) | Should -Be $hash
    }

    It 'promotes a replay into temporary snapshot and runtime artifacts only' {
        $snapshot = Join-Path $TestDrive 'replayed-snapshot.json'
        $runtime = Join-Path $TestDrive 'replayed-runtime.json'
        $result = & (Join-Path $PSScriptRoot '../tools/Update-Catalog.ps1') -SnapshotPath $snapshot -OutputPath $runtime -ReplaySnapshotPath $script:snapshotPath -Confirm:$false
        $result.Replay | Should -BeTrue
        $result.Themes | Should -Be 112
        (Read-WTCatalogSnapshot -Path $snapshot).themes.Count | Should -Be 112
        [IO.File]::Exists($runtime) | Should -BeTrue
        (Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($script:snapshotPath))) | Should -Be $script:originalHash
    }

    It 'leaves both outputs unchanged when replay validation fails' {
        $snapshot = Join-Path $TestDrive 'retained-snapshot.json'
        $runtime = Join-Path $TestDrive 'retained-runtime.json'
        [IO.File]::WriteAllText($snapshot, 'snapshot original')
        [IO.File]::WriteAllText($runtime, 'runtime original')
        $badReplay = Join-Path $TestDrive 'invalid-replay.json'
        $copy = Read-WTCatalogSnapshot -Path $script:snapshotPath
        $copy.documents['https://terminalcolors.com/'].sha256 = '0' * 64
        [IO.File]::WriteAllBytes($badReplay, (ConvertTo-WTCatalogContent -Value $copy))
        { & (Join-Path $PSScriptRoot '../tools/Update-Catalog.ps1') -SnapshotPath $snapshot -OutputPath $runtime -ReplaySnapshotPath $badReplay -Confirm:$false } | Should -Throw '*hash mismatch*'
        [IO.File]::ReadAllText($snapshot) | Should -BeExactly 'snapshot original'
        [IO.File]::ReadAllText($runtime) | Should -BeExactly 'runtime original'
    }

    It 'does not write either output with WhatIf' {
        $snapshot = Join-Path $TestDrive 'whatif-snapshot.json'
        $runtime = Join-Path $TestDrive 'whatif-runtime.json'
        & (Join-Path $PSScriptRoot '../tools/Update-Catalog.ps1') -SnapshotPath $snapshot -OutputPath $runtime -ReplaySnapshotPath $script:snapshotPath -WhatIf | Out-Null
        [IO.File]::Exists($snapshot) | Should -BeFalse
        [IO.File]::Exists($runtime) | Should -BeFalse
    }

    It 'recovers the original first artifact when the second atomic replacement fails' {
        $first = Join-Path $TestDrive 'first.json'
        $second = Join-Path $TestDrive 'second.json'
        [IO.File]::WriteAllText($first, 'first original')
        [IO.File]::WriteAllText($second, 'second original')
        Mock Invoke-WTCatalogFileCommit {
            param($TemporaryPath, $DestinationPath)
            if ($DestinationPath -eq $second) { throw 'Injected second commit failure.' }
            [IO.File]::Replace($TemporaryPath, $DestinationPath, [NullString]::Value)
        }
        $artifacts = @(
            [pscustomobject]@{ Path = $first; Bytes = [Text.Encoding]::UTF8.GetBytes('first replacement') },
            [pscustomobject]@{ Path = $second; Bytes = [Text.Encoding]::UTF8.GetBytes('second replacement') }
        )
        { Write-WTCatalogTransaction -Artifacts $artifacts } | Should -Throw '*Injected second commit failure*'
        [IO.File]::ReadAllText($first) | Should -BeExactly 'first original'
        [IO.File]::ReadAllText($second) | Should -BeExactly 'second original'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.catalog-*').Count | Should -Be 0
    }

    It 'rejects a promotion when an output changed since preparation' {
        $output = Join-Path $TestDrive 'concurrent.json'
        [IO.File]::WriteAllText($output, 'external change')
        $artifact = [pscustomobject]@{ Path = $output; Bytes = [Text.Encoding]::UTF8.GetBytes('candidate'); ExpectedHash = ('0' * 64) }
        { Write-WTCatalogTransaction -Artifacts @($artifact) } | Should -Throw '*changed while refresh was prepared*'
        [IO.File]::ReadAllText($output) | Should -BeExactly 'external change'
    }
}
