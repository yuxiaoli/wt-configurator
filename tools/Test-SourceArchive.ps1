#requires -Version 7.0
<#
.SYNOPSIS
Verifies a source ZIP against a Git commit, excluding only the legacy theme data.
.PARAMETER ArchivePath
An existing GitHub source ZIP. When omitted, generates a local git archive.
.PARAMETER Commit
Exact source commit to verify. Defaults to HEAD; no branch or tag is changed.
#>
[CmdletBinding()]
param(
    [string] $ArchivePath,
    [string] $Commit = 'HEAD',
    [string] $OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.dev/archive-check')
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$commitSha = & git -C $projectRoot rev-parse --verify ($Commit + '^{commit}')
if ($LASTEXITCODE -ne 0 -or $commitSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve source commit.' }
$treeLines = @(& git -C $projectRoot ls-tree -r $commitSha)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read source commit tree.' }
$expected = @{}
foreach ($line in $treeLines) {
    if ($line -cnotmatch '^100[67]44 blob ([0-9a-f]{40})\t(.+)$' -and
        $line -cnotmatch '^100755 blob ([0-9a-f]{40})\t(.+)$') {
        throw "Unsupported source tree entry: $line"
    }
    $expected[$Matches[2]] = $Matches[1]
}
$excluded = @('WTConfigurator/data/themes.json', 'data/terminal-themes.json')
foreach ($path in $excluded) {
    if (-not $expected.ContainsKey($path)) { throw "Legacy file unexpectedly missing from Git: $path" }
    $expected.Remove($path)
}
foreach ($path in @('LICENSE','README.md','RELEASE.md','CATALOG-NOTICES.md','WTConfigurator/WTConfigurator.psd1',
        'WTConfigurator/WTConfigurator.psm1','WTConfigurator/Private/PublicCatalog.ps1','WTConfigurator/Private/Settings.ps1',
        'Set-WindowsTerminalTheme.ps1')) {
    if (-not $expected.ContainsKey($path)) { throw "Required source file missing: $path" }
}
$runRoot = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $runRoot 'source.zip'
    & git -C $projectRoot archive --format=zip --prefix=WTConfigurator-source/ --output=$ArchivePath $commitSha
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
$actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$inventory = [Collections.Generic.List[object]]::new()
$prefix = $null
try {
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        if ($entry.FullName -cnotmatch '^([^/]+/)(.+)$') { throw "Invalid archive entry: $($entry.FullName)" }
        if ($null -eq $prefix) { $prefix = $Matches[1] }
        if ($prefix -cne $Matches[1]) { throw 'Source archive has multiple roots.' }
        $path = $Matches[2]
        if ($path.Contains('\') -or $path.Split('/') -contains '..' -or
            -not $actual.Add($path) -or -not $expected.ContainsKey($path)) {
            throw "Unexpected, duplicate or excluded archive file: $path"
        }
        $stream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
        finally { $stream.Dispose(); $memory.Dispose() }
        $header = [Text.Encoding]::UTF8.GetBytes('blob ' + $bytes.Length + [char]0)
        $blobBytes = [byte[]]($header + $bytes)
        $sha1 = [Security.Cryptography.SHA1]::Create()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $blob = [Convert]::ToHexString($sha1.ComputeHash($blobBytes)).ToLowerInvariant()
            $contentHash = [Convert]::ToHexString($sha256.ComputeHash($bytes)).ToLowerInvariant()
        }
        finally { $sha1.Dispose(); $sha256.Dispose() }
        if ($blob -cne $expected[$path]) { throw "Archive content differs from Git commit: $path" }
        $inventory.Add([pscustomobject]@{ path = $path; bytes = $bytes.Length; git_blob = $blob; sha256 = $contentHash })
    }
}
finally { $archive.Dispose() }
if ($actual.Count -ne $expected.Count) {
    $missing = @($expected.Keys | Where-Object { -not $actual.Contains($_) })
    throw "Source archive omitted required files: $($missing -join ', ')"
}
$receipt = [ordered]@{
    verified_at_utc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    commit = $commitSha
    archive = $ArchivePath
    archive_sha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    file_count = $actual.Count
    excluded_paths = $excluded
    files = @($inventory | Sort-Object path)
    limits = @('Archive packaging check only; no rights clearance or Terminal visual validation is asserted.')
}
$receiptPath = Join-Path $runRoot 'receipt.json'
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Commit = $commitSha; Files = $actual.Count; ArchiveSHA256 = $receipt.archive_sha256; Receipt = $receiptPath }
