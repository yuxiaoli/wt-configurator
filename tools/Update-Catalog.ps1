#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SnapshotPath = (Join-Path $PSScriptRoot '../data/terminal-themes.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../WTConfigurator/data/themes.json'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot '../data/terminal-themes.schema.json'),
    [string] $ReplaySnapshotPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Catalog.ps1')
$expectedHashes = @{}
foreach ($path in @($SnapshotPath, $OutputPath)) {
    $fullPath = [IO.Path]::GetFullPath($path)
    $expectedHashes[$fullPath] = if ([IO.File]::Exists($fullPath)) { Get-WTCatalogHash -Bytes ([IO.File]::ReadAllBytes($fullPath)) } else { $null }
}
$replay = if ($ReplaySnapshotPath) { Read-WTCatalogSnapshot -Path $ReplaySnapshotPath -SchemaPath $SchemaPath } else { $null }
$snapshot = Get-WTCatalogSnapshot -ReplaySnapshot $replay
Assert-WTCatalogSnapshot -Snapshot $snapshot -SchemaPath $SchemaPath
$runtime = ConvertTo-WTRuntimeCatalog -Snapshot $snapshot
if ($PSCmdlet.ShouldProcess("$SnapshotPath and $OutputPath", 'Promote validated catalog snapshot and runtime catalog')) {
    Write-WTCatalogTransaction -Artifacts @(
        [pscustomobject]@{ Path = $SnapshotPath; Bytes = (ConvertTo-WTCatalogContent -Value $snapshot); ExpectedHash = $expectedHashes[[IO.Path]::GetFullPath($SnapshotPath)] },
        [pscustomobject]@{ Path = $OutputPath; Bytes = (ConvertTo-WTCatalogContent -Value $runtime); ExpectedHash = $expectedHashes[[IO.Path]::GetFullPath($OutputPath)] }
    )
}
[pscustomobject]@{ Themes = $snapshot.themes.Count; Documents = $snapshot.documents.Count; Replay = [bool] $ReplaySnapshotPath; SnapshotPath = [IO.Path]::GetFullPath($SnapshotPath); OutputPath = [IO.Path]::GetFullPath($OutputPath) }
