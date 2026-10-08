#requires -Version 7.0
<#
.SYNOPSIS
Builds and verifies a lean local WTConfigurator ZIP.
.DESCRIPTION
Runs the complete project checks unless -SkipChecks is supplied. Local artifacts
are explicitly not public release ready. -ReleaseReady requires full checks,
reviewed rights evidence covering catalog data and source archives, and updated
catalog notices. No package or repository is published.
.PARAMETER RightsEvidencePath
Path to a reviewed JSON evidence record; see RELEASE.md for its required shape.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),
    [string] $RightsEvidencePath,
    [switch] $ReleaseReady,
    [switch] $SkipChecks
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$moduleRoot = Join-Path $projectRoot 'WTConfigurator'
$manifestPath = Join-Path $moduleRoot 'WTConfigurator.psd1'
$noticePath = Join-Path $projectRoot 'CATALOG-NOTICES.md'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
if ($manifest.Version -ne [version] '1.0.0') { throw 'Expected the WTConfigurator 1.0.0 manifest.' }
$rightsRecord = $null

if ($ReleaseReady) {
    if ($SkipChecks) { throw '-ReleaseReady requires full checks; -SkipChecks is not permitted.' }
    if ([string]::IsNullOrWhiteSpace($RightsEvidencePath) -or -not (Test-Path -LiteralPath $RightsEvidencePath -PathType Leaf)) {
        throw 'Public release readiness requires -RightsEvidencePath covering runtime catalog and archived HTML/SVG redistribution.'
    }
    $jsonArguments = @{
        InputObject = (Get-Content -LiteralPath $RightsEvidencePath -Raw -Encoding utf8)
        ErrorAction = 'Stop'
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArguments.DateKind = 'String' }
    $rightsRecord = ConvertFrom-Json @jsonArguments
    if ($rightsRecord.schema_version -cne '1.0') { throw 'Unsupported rights evidence schema; expected 1.0.' }
    foreach ($scope in @('runtime_catalog', 'source_archives')) {
        $review = $rightsRecord.$scope
        if ($null -eq $review -or $review.verified -isnot [bool] -or -not $review.verified) {
            throw "Rights evidence must affirm verified permission for '$scope'."
        }
        foreach ($field in @('rights_basis', 'evidence', 'reviewed_by')) {
            if ($review.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($review.$field)) {
                throw "Rights evidence for '$scope' must supply '$field'."
            }
        }
        if ($review.reviewed_at -isnot [string] -and $review.reviewed_at -isnot [datetime] -and $review.reviewed_at -isnot [datetimeoffset]) {
            throw "Rights evidence for '$scope' must supply 'reviewed_at'."
        }
        $reviewDate = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($review.reviewed_at, [ref] $reviewDate)) {
            throw "Rights review timestamp for '$scope' is invalid."
        }
    }
    $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding utf8
    if ($noticeText.Contains('Redistribution rights have not yet been verified')) {
        throw 'Catalog notices still declare unresolved redistribution rights. Complete human review and update notices before public readiness.'
    }
}

if (-not $SkipChecks) {
    & (Join-Path $PSScriptRoot 'Test-Project.ps1')
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
[void] [System.IO.Directory]::CreateDirectory($outputRoot)
$stagingRoot = Join-Path $outputRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot 'content'
$packageModule = Join-Path $packageRoot 'WTConfigurator'
$archivePath = Join-Path $stagingRoot 'package.zip'
$finalPath = Join-Path $outputRoot ('WTConfigurator-' + $manifest.Version.ToString() + '.zip')
[void] [System.IO.Directory]::CreateDirectory($packageModule)
try {
    $moduleFiles = @(
        (Join-Path $moduleRoot 'WTConfigurator.psd1'),
        (Join-Path $moduleRoot 'WTConfigurator.psm1'),
        (Join-Path $moduleRoot 'data/themes.json')
    )
    $privateRoot = Join-Path $moduleRoot 'Private'
    if (Test-Path -LiteralPath $privateRoot -PathType Container) {
        $moduleFiles += @(Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' -Recurse -File | Select-Object -ExpandProperty FullName)
    }
    foreach ($moduleFile in $moduleFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($moduleRoot, $moduleFile)
        $destinationPath = Join-Path $packageModule $relativePath
        [void] [System.IO.Directory]::CreateDirectory((Split-Path $destinationPath -Parent))
        Copy-Item -LiteralPath $moduleFile -Destination $destinationPath -ErrorAction Stop
    }
    foreach ($document in @('README.md', 'LICENSE', 'CATALOG-NOTICES.md', 'CHANGELOG.md', 'RELEASE.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $document) -Destination (Join-Path $packageModule $document) -ErrorAction Stop
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Set-WindowsTerminalTheme.ps1') -Destination $packageRoot -ErrorAction Stop
    $readiness = if ($ReleaseReady) { 'PUBLIC RELEASE RIGHTS REVIEW RECORDED' } else { 'NOT PUBLIC RELEASE READY' }
    $metadata = [ordered] @{
        name = 'WTConfigurator'
        version = $manifest.Version.ToString()
        project_uri = 'https://github.com/yuxiaoli/wt-configurator'
        readiness = $readiness
        runtime_catalog_sha256 = (Get-FileHash -LiteralPath (Join-Path $packageModule 'data/themes.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        rights_evidence_included = [bool] $ReleaseReady
    }
    [System.IO.File]::WriteAllText((Join-Path $packageModule 'PACKAGE-METADATA.json'), ($metadata | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
    if ($ReleaseReady) {
        Copy-Item -LiteralPath $RightsEvidencePath -Destination (Join-Path $packageModule 'RIGHTS-EVIDENCE.json') -ErrorAction Stop
    }

    $verifyScriptPath = Join-Path $stagingRoot 'verify.ps1'
    $verifyScript = @'
#requires -Version 5.1
param([string] $ManifestPath, [string] $FixturePath)
$ErrorActionPreference = 'Stop'
$manifest = Test-ModuleManifest -Path $ManifestPath
if ($manifest.Version -ne [version] '1.0.0') { throw 'Packaged manifest version mismatch.' }
Import-Module $ManifestPath -Force
$expected = @('Get-WindowsTerminalTheme', 'Get-WindowsTerminalProfile', 'Set-WindowsTerminalAppearance', 'Set-WindowsTerminalTheme', 'Restore-WindowsTerminalSettings')
$actual = @(Get-Command -Module WTConfigurator | Select-Object -ExpandProperty Name)
if (@(Compare-Object $expected $actual).Count -ne 0) { throw 'Packaged command exports differ from the public contract.' }
if (@(Get-WindowsTerminalTheme).Count -eq 0) { throw 'Packaged catalog is empty.' }
$original = [System.Text.UTF8Encoding]::new($false).GetBytes('{"profiles":{"defaults":{},"list":[]}}')
[System.IO.File]::WriteAllBytes($FixturePath, $original)
$change = Set-WindowsTerminalAppearance -SettingsPath $FixturePath -Theme 'catppuccin/mocha' -Opacity 85 -UseAcrylic $true -PassThru
if (-not $change.Changed) { throw 'Packaged appearance flow did not change the fixture.' }
$restore = Restore-WindowsTerminalSettings -SettingsPath $FixturePath -BackupPath $change.BackupPath -PassThru
if (-not $restore.Changed) { throw 'Packaged restoration flow did not change the fixture.' }
$restored = [System.IO.File]::ReadAllBytes($FixturePath)
if ([Convert]::ToBase64String($original) -cne [Convert]::ToBase64String($restored)) { throw 'Packaged restoration did not preserve exact bytes.' }
'@
    [System.IO.File]::WriteAllText($verifyScriptPath, $verifyScript, [System.Text.UTF8Encoding]::new($false))
    $archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
    $archive = [System.IO.Compression.ZipArchive]::new($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $paths = [string[]] @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Select-Object -ExpandProperty FullName)
        [array]::Sort($paths, [System.StringComparer]::Ordinal)
        foreach ($path in $paths) {
            $entryName = [System.IO.Path]::GetRelativePath($packageRoot, $path).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [datetimeoffset]::new(2000, 1, 1, 0, 0, 0, [timespan]::Zero)
            $inputStream = [System.IO.File]::OpenRead($path)
            $entryStream = $entry.Open()
            try { $inputStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $inputStream.Dispose() }
        }
    }
    finally { $archive.Dispose(); $archiveStream.Dispose() }
    $installationRoot = Join-Path $stagingRoot 'installation'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $installationRoot)
    $installedManifest = Join-Path $installationRoot 'WTConfigurator/WTConfigurator.psd1'
    foreach ($engineName in @('powershell.exe', 'pwsh')) {
        $engineCommand = Get-Command $engineName -CommandType Application -ErrorAction Stop
        $fixturePath = Join-Path $stagingRoot ($engineName + '.settings.json')
        & $engineCommand.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verifyScriptPath -ManifestPath $installedManifest -FixturePath $fixturePath
        if ($LASTEXITCODE -ne 0) { throw "$engineName packaged import/appearance/restore verification failed." }
        & $engineCommand.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $installationRoot 'Set-WindowsTerminalTheme.ps1') -List | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$engineName packaged wrapper verification failed." }
    }
    [System.IO.File]::Move($archivePath, $finalPath, $true)
    if (-not $ReleaseReady) { Write-Warning 'Local package built: NOT PUBLIC RELEASE READY. Catalog and archive redistribution rights remain an external prerequisite.' }
    [pscustomobject] @{
        PackagePath = $finalPath
        Version = $manifest.Version.ToString()
        Readiness = $readiness
        SHA256 = (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash
    }
}
finally {
    $resolvedStaging = [System.IO.Path]::GetFullPath($stagingRoot)
    $allowedPrefix = $outputRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStaging.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolvedStaging) -notlike '.stage-*') {
        throw "Refusing to clean unexpected package staging path '$resolvedStaging'."
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction Stop
}
