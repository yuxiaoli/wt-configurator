#requires -Version 5.1
<#
.SYNOPSIS
Validates WTConfigurator on its supported PowerShell engines.
.DESCRIPTION
Uses pinned project-local development modules, checks deterministic runtime
catalog generation, runs Pester under Windows PowerShell 5.1 and/or PowerShell
Core, and lints on Core 7.4.6 or later. No real Terminal settings are selected.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Desktop', 'Core')]
    [string] $Engine = 'All',
    [switch] $SkipLint,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$dependencyRoot = Join-Path $projectRoot '.dev/modules'
$moduleManifest = Join-Path $projectRoot 'WTConfigurator/WTConfigurator.psd1'
$testRoot = Join-Path $projectRoot 'tests'

if ($Worker) {
    if ($Engine -eq 'All') { throw 'A worker requires -Engine Desktop or Core.' }
    if ($Engine -eq 'Desktop' -and $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Desktop validation must run under Windows PowerShell.'
    }
    if ($Engine -eq 'Core' -and $PSVersionTable.PSEdition -ne 'Core') {
        throw 'Core validation must run under PowerShell Core.'
    }
    if ($Engine -eq 'Core' -and -not $SkipLint -and $PSVersionTable.PSVersion -lt [version] '7.4.6') {
        throw 'Core lint requires PowerShell 7.4.6 or later.'
    }
    $pesterManifest = Join-Path $dependencyRoot 'Pester/5.9.1/Pester.psd1'
    if (-not (Test-Path -LiteralPath $pesterManifest -PathType Leaf)) {
        throw 'Run tools/Initialize-DevEnvironment.ps1 before project validation.'
    }
    $env:PSModulePath = $dependencyRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module $pesterManifest -RequiredVersion 5.9.1 -Force -ErrorAction Stop
    $manifest = Test-ModuleManifest -Path $moduleManifest -ErrorAction Stop
    if ($manifest.Version -ne [version] '1.0.0' -or $manifest.Author -ne 'Sean') {
        throw 'WTConfigurator manifest version/author differs from the v1 release contract.'
    }
    if (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File).Count -eq 0) {
        throw "No Pester tests exist at '$testRoot'."
    }
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @(
        Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File -Recurse |
            Where-Object { $Engine -ne 'Desktop' -or $_.Name -ne 'Catalog.Tests.ps1' } |
            Select-Object -ExpandProperty FullName
    )
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Output.Verbosity = 'Detailed'
    $results = Invoke-Pester -Configuration $configuration
    if ($results.FailedCount -gt 0 -or $results.TotalCount -eq 0) {
        throw "$Engine Pester validation failed: $($results.FailedCount) failed of $($results.TotalCount)."
    }

    if ($Engine -eq 'Core' -and -not $SkipLint) {
        $analyzerManifest = Join-Path $dependencyRoot 'PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1'
        Import-Module $analyzerManifest -RequiredVersion 1.25.0 -Force -ErrorAction Stop
        $analysisPaths = @(
            (Join-Path $projectRoot 'WTConfigurator'),
            (Join-Path $projectRoot 'Set-WindowsTerminalTheme.ps1'),
            $PSScriptRoot
        )
        $diagnostics = @(
            foreach ($analysisPath in $analysisPaths) {
                Invoke-ScriptAnalyzer -Path $analysisPath -Recurse -Severity Warning, Error -ErrorAction Stop
            }
        )
        if ($diagnostics.Count -gt 0) {
            $diagnostics | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String | Write-Output
            throw "PSScriptAnalyzer reported $($diagnostics.Count) warning/error findings."
        }
    }
    Write-Information "$Engine checks passed on PowerShell $($PSVersionTable.PSVersion)." -InformationAction Continue
    exit 0
}

$coreCommand = Get-Command pwsh -CommandType Application -ErrorAction Stop
$catalogCheck = Join-Path $PSScriptRoot 'Test-Catalog.ps1'
$catalogBuild = Join-Path $PSScriptRoot 'Build-Catalog.ps1'
$runtimeCatalog = Join-Path $projectRoot 'WTConfigurator/data/themes.json'
$temporaryCatalog = Join-Path ([System.IO.Path]::GetTempPath()) ('wtcatalog-' + [guid]::NewGuid().ToString('N') + '.json')
$secondCatalog = $temporaryCatalog + '.second'
try {
    & $coreCommand.Source -NoProfile -NonInteractive -File $catalogCheck
    if ($LASTEXITCODE -ne 0) { throw 'Catalog validation failed.' }
    & $coreCommand.Source -NoProfile -NonInteractive -File $catalogBuild -OutputPath $temporaryCatalog
    if ($LASTEXITCODE -ne 0) { throw 'Runtime catalog build failed.' }
    & $coreCommand.Source -NoProfile -NonInteractive -File $catalogBuild -OutputPath $secondCatalog
    if ($LASTEXITCODE -ne 0) { throw 'Repeated runtime catalog build failed.' }
    $generatedHash = (Get-FileHash -LiteralPath $temporaryCatalog -Algorithm SHA256).Hash
    if ($generatedHash -ne (Get-FileHash -LiteralPath $secondCatalog -Algorithm SHA256).Hash -or
        $generatedHash -ne (Get-FileHash -LiteralPath $runtimeCatalog -Algorithm SHA256).Hash) {
        throw 'Runtime catalog is stale or generation is nondeterministic. Run tools/Build-Catalog.ps1 and review its result.'
    }
}
finally {
    foreach ($temporaryPath in @($temporaryCatalog, $secondCatalog)) {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

$engines = if ($Engine -eq 'All') { @('Desktop', 'Core') } else { @($Engine) }
foreach ($selectedEngine in $engines) {
    $engineCommand = if ($selectedEngine -eq 'Desktop') {
        Get-Command powershell.exe -CommandType Application -ErrorAction Stop
    }
    else { $coreCommand }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Worker', '-Engine', $selectedEngine)
    if ($SkipLint) { $arguments += '-SkipLint' }
    & $engineCommand.Source @arguments
    if ($LASTEXITCODE -ne 0) { throw "$selectedEngine project validation failed (exit $LASTEXITCODE)." }
}
