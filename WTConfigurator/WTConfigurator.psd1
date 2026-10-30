@{
    RootModule = 'WTConfigurator.psm1'
    ModuleVersion = '1.1.0'
    GUID = 'f320f18f-d489-4c95-8778-e7f3b589662e'
    Author = 'Sean'
    Copyright = '(c) 2026 Sean. Code licensed under MIT; catalog rights are separate.'
    Description = 'Windows Terminal bundled/public theme, opacity, acrylic, and backup configuration.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @('Get-WindowsTerminalTheme', 'Get-WindowsTerminalProfile', 'Set-WindowsTerminalAppearance', 'Set-WindowsTerminalTheme', 'Restore-WindowsTerminalSettings')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('WindowsTerminal', 'Windows', 'Themes', 'Opacity', 'Desktop', 'Core')
            ProjectUri = 'https://github.com/yuxiaoli/wt-configurator'
            LicenseUri = 'https://github.com/yuxiaoli/wt-configurator/blob/main/LICENSE'
            ReleaseNotes = 'Opt-in public API terminal catalogue with validated palettes, explicit offline cache, provenance and safe settings transactions.'
        }
    }
}
