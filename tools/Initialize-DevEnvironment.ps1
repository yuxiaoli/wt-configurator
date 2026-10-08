#requires -Version 7.0
<#
.SYNOPSIS
Downloads exact development module versions into .dev/modules.
.DESCRIPTION
Uses the PowerShell Gallery package endpoint and does not change user-wide module
installations. Existing valid versions are reused. These modules are excluded
from the WTConfigurator package.
#>
[CmdletBinding()]
param(
    [string] $DependencyPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.dev/modules')
)

$ErrorActionPreference = 'Stop'
$dependencyRoot = [System.IO.Path]::GetFullPath($DependencyPath)
[void] [System.IO.Directory]::CreateDirectory($dependencyRoot)
$dependencies = @(
    @{ Name = 'Pester'; Version = '5.9.1' },
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
)

foreach ($dependency in $dependencies) {
    $moduleParent = Join-Path $dependencyRoot $dependency.Name
    $modulePath = Join-Path $moduleParent $dependency.Version
    $manifestPath = Join-Path $modulePath ($dependency.Name + '.psd1')
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
        if ($manifest.Version -ne [version] $dependency.Version) {
            throw "Unexpected installed version at '$manifestPath'."
        }
        Write-Information "Reusing $($dependency.Name) $($dependency.Version)." -InformationAction Continue
        continue
    }
    if (Test-Path -LiteralPath $modulePath) {
        throw "Incomplete dependency directory '$modulePath'. Move it aside and rerun bootstrap."
    }

    $stagingPath = Join-Path $dependencyRoot ('.download-' + [guid]::NewGuid().ToString('N'))
    [void] [System.IO.Directory]::CreateDirectory($stagingPath)
    try {
        $archivePath = Join-Path $stagingPath 'package.zip'
        $unpackPath = Join-Path $stagingPath 'module'
        $packageUrl = 'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f $dependency.Name, $dependency.Version
        Invoke-WebRequest -Uri $packageUrl -OutFile $archivePath -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $unpackPath)
        $downloadedManifest = Join-Path $unpackPath ($dependency.Name + '.psd1')
        $manifest = Test-ModuleManifest -Path $downloadedManifest -ErrorAction Stop
        if ($manifest.Version -ne [version] $dependency.Version) {
            throw "Downloaded $($dependency.Name) package has an unexpected version."
        }
        $resolvedModule = [System.IO.Path]::GetFullPath($modulePath)
        $allowedModulePrefix = $dependencyRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedModule.StartsWith($allowedModulePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to move a dependency outside '$dependencyRoot'."
        }
        [void] [System.IO.Directory]::CreateDirectory($moduleParent)
        Move-Item -LiteralPath $unpackPath -Destination $resolvedModule -ErrorAction Stop
        Write-Information "Installed $($dependency.Name) $($dependency.Version) into '$modulePath'." -InformationAction Continue
    }
    finally {
        $resolvedStaging = [System.IO.Path]::GetFullPath($stagingPath)
        $allowedPrefix = $dependencyRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedStaging.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedStaging) -notlike '.download-*') {
            throw "Refusing to clean unexpected dependency staging path '$resolvedStaging'."
        }
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction Stop
    }
}
