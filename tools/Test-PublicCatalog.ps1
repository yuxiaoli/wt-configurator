#requires -Version 5.1
<#
.SYNOPSIS
Verifies a built/importable module against the approved public API using new synthetic settings only.
.PARAMETER ManifestPath
Path to the extracted package manifest or source module manifest.
.PARAMETER OutputDirectory
Directory for unique synthetic fixture settings, opt-in cache and a verification receipt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ManifestPath,
    [Parameter(Mandatory = $true)][string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module $ManifestPath -Force
$root = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($root)
$runRoot = Join-Path $root ('public-' + $PSVersionTable.PSEdition + '-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$path = Join-Path $runRoot 'synthetic.settings.json'
$cache = Join-Path $runRoot 'cache'
$utf8 = New-Object Text.UTF8Encoding($true)
$json = '// synthetic fixture; never a discovered Terminal settings path
{"unknown":{"keep":[1,true,"value"]},"actions":[{"command":"paste","keys":"ctrl+v"}],"profiles":{"defaults":{"opacity":91,"font":{"face":"Fixture Font"},"unfocusedAppearance":{"opacity":45}},"list":[{"name":"Fixture","commandline":"pwsh.exe","colorScheme":"Existing"},{"name":"Other","opacity":77}]},"schemes":[{"name":"Existing","background":"#123456"}],}'
$originalBytes = [byte[]]($utf8.GetPreamble() + $utf8.GetBytes($json))
[IO.File]::WriteAllBytes($path,$originalBytes)
$originalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
$themes = @(Get-WindowsTerminalTheme -Source PublicCatalog -CachePath $cache)
if ($themes.Count -eq 0) { throw 'The public catalog is empty.' }
$theme = Get-WindowsTerminalTheme -Source PublicCatalog -Theme 'Spaceduck' -CachePath $cache
$beforeFiles = @(Get-ChildItem -LiteralPath $runRoot -Recurse -File).Count
Set-WindowsTerminalTheme -Theme $theme.Id -Source PublicCatalog -SettingsPath $path -CachePath $cache -WhatIf
if ((Get-FileHash -LiteralPath $path).Hash -ne $originalHash -or @(Get-ChildItem -LiteralPath $runRoot -Recurse -File).Count -ne $beforeFiles) { throw 'WhatIf altered fixture files.' }
$change = Set-WindowsTerminalTheme -Theme $theme.Id -Source PublicCatalog -SettingsPath $path -CachePath $cache -Offline -PassThru
if (-not $change.Changed -or -not $change.BackupPath) { throw 'Theme application did not produce an exact backup.' }
$saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
if ($saved.profiles.defaults.colorScheme -cne ('WTConfigurator/' + $theme.Id)) { throw 'Theme was not selected in defaults.' }
$scheme = $saved.schemes[1]
if ($scheme.background -cne $theme.Palette.Background -or $scheme.foreground -cne $theme.Palette.Foreground -or $scheme.cursorColor -cne $theme.Palette.Cursor) { throw 'Named palette colors differ.' }
$keys = @('black','red','green','yellow','blue','purple','cyan','white','brightBlack','brightRed','brightGreen','brightYellow','brightBlue','brightPurple','brightCyan','brightWhite')
for ($i=0; $i -lt 16; $i++) { if ($scheme.($keys[$i]) -cne $theme.Palette.Ansi[$i]) { throw "ANSI slot $i differs." } }
# Remove only the expected additions, then compare the entire remaining object.
$saved.profiles.defaults.PSObject.Properties.Remove('colorScheme')
$saved.schemes = @($saved.schemes[0])
$expected = $json.Substring($json.IndexOf('{')).Replace('],}',']}') | ConvertFrom-Json
if (($saved | ConvertTo-Json -Depth 30 -Compress) -cne ($expected | ConvertTo-Json -Depth 30 -Compress)) { throw 'Unrelated settings changed.' }
if ((Set-WindowsTerminalTheme -Theme $theme.Id -Source PublicCatalog -SettingsPath $path -CachePath $cache -Offline -PassThru).Changed) { throw 'Repeat application is not idempotent.' }
$restore = Restore-WindowsTerminalSettings -SettingsPath $path -BackupPath $change.BackupPath -PassThru
$restoredHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
if (-not $restore.Changed -or $restoredHash -cne $originalHash -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($originalBytes)) { throw 'Exact backup restoration failed.' }
# Verify the packaged interactive wrapper can search and select from the same cache.
$wrapper = Join-Path (Split-Path (Split-Path ([IO.Path]::GetFullPath($ManifestPath)) -Parent) -Parent) 'Set-WindowsTerminalTheme.ps1'
$engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
& $engine -NoProfile -NonInteractive -File $wrapper -Source PublicCatalog -Offline -CachePath $cache -List | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Packaged public list wrapper failed.' }
$escapedWrapper = $wrapper.Replace("'", "''")
$escapedCache = $cache.Replace("'", "''")
$escapedPath = $path.Replace("'", "''")
& $engine -NoProfile -NonInteractive -Command "function global:Read-Host { 'Spaceduck' }; & '$escapedWrapper' -Source PublicCatalog -Offline -CachePath '$escapedCache' -SettingsPath '$escapedPath'" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Packaged interactive selection failed.' }
$wrapperBackup = @(Get-ChildItem -LiteralPath $runRoot -File | Where-Object { $_.Name -like '*.bak' -and (Get-FileHash -LiteralPath $_.FullName).Hash -ceq $originalHash })[0].FullName
Restore-WindowsTerminalSettings -SettingsPath $path -BackupPath $wrapperBackup
if ((Get-FileHash -LiteralPath $path).Hash -cne $originalHash) { throw 'Wrapper restoration failed.' }
$receipt = [pscustomobject][ordered]@{
    verified_at_utc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    engine = $PSVersionTable.PSEdition; powershell_version = $PSVersionTable.PSVersion.ToString()
    os_version = [Environment]::OSVersion.VersionString
    manifest = [IO.Path]::GetFullPath($ManifestPath); version = (Get-Module WTConfigurator).Version.ToString()
    available_count = $themes.Count; withheld_count = $themes[0].WithheldCount
    theme_id = $theme.Id; source_revision = $theme.SourceRevision; content_sha256 = $theme.ContentSHA256; index_sha256 = $theme.CatalogIndexSHA256
    original_sha256 = $originalHash; restored_sha256 = $restoredHash
    checks = @('live-list','live-exact-selection','whatif','offline-application','all-palette-slots','all-unrelated-settings','idempotency','exact-byte-restoration','packaged-list','interactive-selection','wrapper-restoration')
    limits = @('Synthetic settings only; no live user settings were selected.','Terminal visual rendering on Windows 10/11 was not tested.')
}
$receiptPath = Join-Path $runRoot 'receipt.json'
[IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
$receipt
