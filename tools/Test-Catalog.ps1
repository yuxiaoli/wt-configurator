#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $SnapshotPath = (Join-Path $PSScriptRoot '../data/terminal-themes.json'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot '../data/terminal-themes.schema.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Catalog.ps1')
$snapshot = Read-WTCatalogSnapshot -Path $SnapshotPath -SchemaPath $SchemaPath
[pscustomobject]@{ Valid = $true; Themes = $snapshot.themes.Count; Documents = $snapshot.documents.Count; SnapshotPath = [IO.Path]::GetFullPath($SnapshotPath) }
