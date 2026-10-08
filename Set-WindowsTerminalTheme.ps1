#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This interactive CLI presentation wrapper writes human-readable prompts; module commands return pipeline objects.')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)][string] $Theme,
    [object] $Opacity,
    [bool] $UseAcrylic,
    [Alias('Profile')][string] $TargetProfile,
    [string] $SettingsPath,
    [switch] $List,
    [switch] $NoBackup
)

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'WTConfigurator/WTConfigurator.psd1') -ErrorAction Stop
    $hasAppearance = $PSBoundParameters.ContainsKey('Theme') -or $PSBoundParameters.ContainsKey('Opacity') -or $PSBoundParameters.ContainsKey('UseAcrylic')
    if ($List) {
        if ($hasAppearance) { throw '-List cannot be combined with theme, opacity, or acrylic changes.' }
        Get-WindowsTerminalTheme | Format-Table Id, DisplayName, Mode -AutoSize
        exit 0
    }
    $arguments = @{}
    foreach ($key in @('Theme', 'Opacity', 'UseAcrylic', 'TargetProfile', 'SettingsPath', 'NoBackup', 'WhatIf', 'Confirm', 'Verbose', 'Debug')) {
        if ($PSBoundParameters.ContainsKey($key)) { $arguments[$key] = $PSBoundParameters[$key] }
    }
    if (-not $hasAppearance) {
        Write-Host "Type part of a theme name or ID to search; '?' lists all themes."
        while ($true) {
            $query = Read-Host 'Theme search (q to cancel)'
            if ($query -ieq 'q') { Write-Host 'Cancelled; no settings changed.'; exit 0 }
            if ($query -eq '?') { Get-WindowsTerminalTheme | Format-Table Id, DisplayName, Mode -AutoSize; continue }
            if ([string]::IsNullOrWhiteSpace($query)) { continue }
            $themeMatches = @(Get-WindowsTerminalTheme -Search $query)
            if ($themeMatches.Count -eq 0) { Write-Warning "No themes contain '$query'."; continue }
            if ($themeMatches.Count -eq 1) { $arguments.Theme = $themeMatches[0].Id; break }
            if ($themeMatches.Count -gt 30) { Write-Warning "$($themeMatches.Count) themes matched; refine the search."; continue }
            for ($index = 0; $index -lt $themeMatches.Count; $index++) { Write-Host ('{0,2}. {1} [{2}]' -f ($index + 1), $themeMatches[$index].DisplayName, $themeMatches[$index].Id) }
            $choice = Read-Host "Choose 1-$($themeMatches.Count), q to cancel, or Enter to search again"
            if ($choice -ieq 'q') { Write-Host 'Cancelled; no settings changed.'; exit 0 }
            $number = 0
            if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $themeMatches.Count) { $arguments.Theme = $themeMatches[$number - 1].Id; break }
        }
    }
    $result = Set-WindowsTerminalAppearance @arguments -PassThru
    if ($null -ne $result) {
        if ($result.Changed) {
            Write-Host "Updated $($result.Target) in $($result.SettingsPath)." -ForegroundColor Green
            if ($result.BackupPath) { Write-Host "Exact backup: $($result.BackupPath)" }
        }
        else { Write-Host 'The selected appearance is already set; no file was written.' }
    }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
