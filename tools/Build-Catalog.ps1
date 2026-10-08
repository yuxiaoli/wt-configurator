#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $SnapshotPath = (Join-Path $PSScriptRoot '../data/terminal-themes.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../WTConfigurator/data/themes.json'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot '../data/terminal-themes.schema.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Catalog.ps1')
foreach ($inputPath in @($SnapshotPath, $SchemaPath)) {
    if ([IO.Path]::GetFullPath($OutputPath).Equals([IO.Path]::GetFullPath($inputPath), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime output must not overwrite the source snapshot or its schema.'
    }
}
$snapshot = Read-WTCatalogSnapshot -Path $SnapshotPath -SchemaPath $SchemaPath
$catalog = ConvertTo-WTRuntimeCatalog -Snapshot $snapshot
Write-WTCatalogTransaction -Artifacts @([pscustomobject]@{ Path = $OutputPath; Bytes = (ConvertTo-WTCatalogContent -Value $catalog) })
[pscustomobject]@{ Themes = $catalog.themes.Count; OutputPath = [IO.Path]::GetFullPath($OutputPath) }
