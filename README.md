# WTConfigurator

Choose Windows Terminal color themes and set terminal opacity from PowerShell.
WTConfigurator 1.0.0 uses the bundled 112-theme [TerminalColors](https://terminalcolors.com/)
snapshot offline. Importing the module does not contact a service or change settings.

Supports Windows PowerShell 5.1 and PowerShell 7 on Windows 10/11, with Windows
Terminal 1.12+ and modern `profiles.defaults` / `profiles.list` settings.
Project home: [yuxiaoli/wt-configurator](https://github.com/yuxiaoli/wt-configurator).

## Install and use

From a source checkout:

```powershell
Import-Module .\WTConfigurator\WTConfigurator.psd1

# Inspect the offline catalog; IDs select a theme unambiguously.
Get-WindowsTerminalTheme -Search 'catppuccin'
Get-WindowsTerminalTheme -Theme 'catppuccin/mocha'

# One update applies a theme, 85% opacity, and acrylic blur to defaults.
Set-WindowsTerminalAppearance -Theme 'catppuccin/mocha' `
    -Opacity 85 -UseAcrylic $true -PassThru

# Change opacity alone. Existing acrylic and unfocused settings are preserved.
Set-WindowsTerminalAppearance -Opacity 90

# Select one profile by GUID or unique exact name.
Get-WindowsTerminalProfile
Set-WindowsTerminalAppearance -Profile 'PowerShell' -Opacity 80 -UseAcrylic $false

# Preview without creating a backup or replacing settings.
Set-WindowsTerminalTheme -Theme 'ayu/mirage' -WhatIf
```

For a locally built ZIP, extract it into a directory on `$env:PSModulePath` and
run `Import-Module WTConfigurator -RequiredVersion 1.0.0`. Alternatively, import
the extracted `WTConfigurator\WTConfigurator.psd1` by its full path. The
package has no runtime module dependencies. See [RELEASE.md](RELEASE.md) for build
and rights requirements; a local package is not automatically ready for public release.

The original entry script remains available:

```powershell
.\Set-WindowsTerminalTheme.ps1                 # Interactive theme search/selection
.\Set-WindowsTerminalTheme.ps1 -List
.\Set-WindowsTerminalTheme.ps1 -Theme 'ayu/dark' -Opacity 85 -UseAcrylic $true
.\Set-WindowsTerminalTheme.ps1 -Opacity 85     # No theme prompt
```

If local execution policy blocks a downloaded script, review the file and use
`Unblock-File` or an appropriate process-scoped policy for your environment.

## Commands and selection

| Command | Behavior |
| --- | --- |
| `Get-WindowsTerminalTheme [-Theme <text>] [-Search <text>]` | Returns theme objects; search is a literal, case-insensitive substring match. |
| `Get-WindowsTerminalProfile [-SettingsPath <path>]` | Returns profiles in the selected settings file. |
| `Set-WindowsTerminalAppearance [-Theme <text>] [-Opacity <0-100>] [-UseAcrylic <bool>]` | Applies supplied appearance values together; at least one is required. |
| `Set-WindowsTerminalTheme -Theme <text>` | Convenience command that delegates to the appearance setter. |
| `Restore-WindowsTerminalSettings -BackupPath <path> -SettingsPath <path>` | Restores validated backup bytes exactly and first backs up the current target. |

Both setters accept `-Profile <guid-or-name>`, `-SettingsPath <path>`, `-NoBackup`,
`-PassThru`, `-WhatIf`, and `-Confirm`. Restore accepts `-PassThru`, `-WhatIf`, and
`-Confirm`. Write commands normally return no objects. `-PassThru` reports the
target, changed properties, backup path, and whether anything changed. Module
commands do not open interactive theme selectors. Use `Get-Help <command> -Full`
for parameter help and examples.

Theme selection checks a stable ID first, then the full family/variant display
name returned by the catalog, then a uniquely matching variant name. Ambiguous
names report candidate IDs. Generated scheme names are `WTConfigurator/<theme-id>`.
The 16 ANSI colors retain their source indexes; the accent supplies `cursorColor`.
Source mode metadata is retained, including `unknown`.

Without `-Profile`, setters target `profiles.defaults`. A supplied profile must
match an existing GUID or a unique exact name. Individual profile overrides can
take precedence over defaults; select that profile explicitly to change them.
Applying a theme replaces a target's light/dark `colorScheme` pair with one name.
Additional properties on an existing generated scheme are retained.

`-Opacity` accepts integer percentages from 0 through 100: 100 is fully opaque.
`-UseAcrylic $true` enables background blur; `$false` uses unblurred opacity where
the platform supports it. **Unblurred transparency requires Windows 11.** On
Windows 10 use acrylic for a transparent background. Unfocused appearance overrides
are preserved. See [Microsoft's transparency settings](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-appearance#transparency).

Settings discovery checks standard Stable, Preview, and unpackaged locations and
uses process ancestry to identify the active edition. If selection remains
ambiguous, supply `-SettingsPath`; the module does not guess. Microsoft's
[installation documentation](https://learn.microsoft.com/en-us/windows/terminal/install#settings-json-file)
describes these locations.

## Settings protection and restoration

The module accepts JSONC comments and trailing commas. A successful update writes
formatted UTF-8 JSON, removing original comments and formatting. Its default
backup retains the exact original bytes. Unrelated settings, profile overrides,
and unfocused appearance values are retained. Legacy profile arrays and invalid
consumed containers are rejected.

Before editing, a conservative JSON round-trip check verifies that PowerShell's
built-in parser and serializer preserve token structure, decoded strings, and
exact numeric spellings. Duplicate or case-conflicting keys, date coercion,
numeric spelling changes, depth loss, and serialization warnings can therefore
cause an update to be refused. Fix the reported setting or use Terminal's own
settings editor; a refused operation does not rewrite the file.

Each transaction reads and hashes one byte snapshot, locks cooperating instances
by path, prepares a sibling temporary file, and checks for intervening changes
before atomic replacement. External programs do not share this lock, so detection
of concurrent external writes is best effort. Replacement errors report retained
recovery artifacts. With `-NoBackup`, a temporary recovery backup is removed only
after success. An already satisfied operation changes nothing and creates no backup.

```powershell
$result = Set-WindowsTerminalAppearance -Opacity 85 -PassThru
# Use the returned paths from an operation that changed settings.
Restore-WindowsTerminalSettings -BackupPath $result.BackupPath `
    -SettingsPath $result.SettingsPath -WhatIf
Restore-WindowsTerminalSettings -BackupPath $result.BackupPath `
    -SettingsPath $result.SettingsPath -PassThru
```

Restore validates the backup and restores its exact bytes, including encoding,
comments, and formatting. It always backs up the current settings before an
actual replacement, even if the earlier appearance change used `-NoBackup`.

## Development

Use PowerShell 7.4.6+ for the development runner and lint. Windows PowerShell 5.1
must also be installed to run the complete supported-engine checks.

```powershell
pwsh -NoProfile -File .\tools\Initialize-DevEnvironment.ps1
pwsh -NoProfile -File .\tools\Test-Project.ps1
pwsh -NoProfile -File .\tools\Build-Package.ps1
```

The bootstrap downloads pinned [Pester 5.9.1](https://www.powershellgallery.com/packages/Pester/5.9.1)
and [PSScriptAnalyzer 1.25.0](https://www.powershellgallery.com/packages/PSScriptAnalyzer/1.25.0)
into `.dev/modules`; they are not runtime dependencies. Tests use temporary
settings fixtures. The runner checks the module manifest, tests both engines,
lints on PowerShell Core, and compares deterministic catalog builds with the
checked-in runtime catalog. Windows CI runs the same commands.

Maintainer tools use PowerShell 7 and retain source provenance:

```powershell
.\tools\Test-Catalog.ps1
.\tools\Build-Catalog.ps1
.\tools\Update-Catalog.ps1
```

Refresh discovers public theme families and extracts SVG palettes by semantic
ANSI labels. A fetch, extraction, coverage, hash, or validation failure leaves
the canonical snapshot and runtime catalog intact. Refresh requires a network;
normal module use remains offline. Code is MIT-licensed; catalog data and stored
HTML/SVG documents have separate rights. Read [CATALOG-NOTICES.md](CATALOG-NOTICES.md).
