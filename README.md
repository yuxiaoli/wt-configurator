# WTConfigurator

Choose Windows Terminal color themes and set terminal opacity from PowerShell.
A source checkout of WTConfigurator 1.1.0 defaults to the bundled 112-theme [TerminalColors](https://terminalcolors.com/)
snapshot offline. Importing the module does not contact a service or change settings.

Supports Windows PowerShell 5.1 and PowerShell 7 on Windows 10/11, with Windows
Terminal 1.12+ and modern `profiles.defaults` / `profiles.list` settings.
Project home: [yuxiaoli/wt-configurator](https://github.com/yuxiaoli/wt-configurator).

## Install and use

The `WTConfigurator-1.1.0-public-api.zip` package contains the API client and no
bundled third-party palettes. Extract and import `WTConfigurator/WTConfigurator.psd1`.
In this package, theme listing/selection defaults to `PublicCatalog` and requires
network access unless an explicit cache is used with `-Offline`. Import itself
and opacity-only changes remain offline. `-Source Bundled` is unavailable in this
package. The existing source checkout and legacy local package retain their bundled
default; the command examples below identify bundled source use.

From a source checkout (legacy bundled catalogue):

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
run `Import-Module WTConfigurator -RequiredVersion 1.1.0`. Alternatively, import
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

## Public terminal catalogue

Use `-Source PublicCatalog` explicitly on the same commands or interactive wrapper.
The only network source is the approved [public API v1 export](https://yuxiaoli.github.io/themes-catalog-api/api/v1/index.json).
Importing the module and using the default `Bundled` source remain offline.

```powershell
Get-WindowsTerminalTheme -Source PublicCatalog -Search 'Spaceduck'
$theme = Get-WindowsTerminalTheme -Source PublicCatalog -Theme 'Spaceduck'
$theme | Format-List Id, SourceRevision, ContentSHA256, License, LicenseDocuments

# Preview and apply to an explicit disposable settings file.
Set-WindowsTerminalTheme -Source PublicCatalog -Theme $theme.Id `
    -SettingsPath .\fixture\settings.json -WhatIf
$result = Set-WindowsTerminalTheme -Source PublicCatalog -Theme $theme.Id `
    -SettingsPath .\fixture\settings.json -PassThru
Restore-WindowsTerminalSettings -SettingsPath $result.SettingsPath -BackupPath $result.BackupPath

# Opt-in cache; an exact selection caches the index and that theme's full response.
Get-WindowsTerminalTheme -Source PublicCatalog -Theme $theme.Id -CachePath .\theme-cache
Set-WindowsTerminalTheme -Source PublicCatalog -Theme $theme.Id `
    -Offline -CachePath .\theme-cache -SettingsPath .\fixture\settings.json

# Inspect withheld names/reasons without fetching or applying them.
Get-WindowsTerminalTheme -Source PublicCatalog -IncludeUnavailable
.\Set-WindowsTerminalTheme.ps1 -Source PublicCatalog -SettingsPath .\fixture\settings.json
```

Public lists return summaries with `Available`, `Compatibility`, `WithheldCount`
and stable namespaced IDs. `RequiresPaletteValidation` means the format is supported
but its full palette has not yet been fetched. Exact selection fetches and validates
it, returning `Compatibility = Validated`, palette, license links, API version,
index/content SHA-256 and source revision. Names may be ambiguous; choose an ID.
The update's `ThemeProvenance` carries these identifiers without adding metadata to
Terminal settings. Hashes identify received content; they are not digital signatures.

API v1 paths resolve relative to the Pages root. The consumer accepts only the
terminal category and Gogh format, validates the index identity against its payload,
and requires background, foreground, cursor, accent and exactly 16 opaque RGB colors.
ANSI indexes map directly to Terminal's normal/bright slots; `cursor` maps to
`cursorColor`. No indexed/alpha/editor palette conversion or guessed colors occur.
Other formats and withheld entries are reported explicitly and cannot be applied.
The initial export has 1,251 available and 112 withheld terminal entries; live
counts are read from the index. Withheld entries never fall back to bundled data.
The legacy bundled catalogue has its own unresolved rights status (see notices).

No cache is created by default. With `-CachePath`, only validated raw JSON responses
are stored, using atomic replacement. Online calls always request the current API;
network failure fails before settings discovery or writing, with no silent stale
fallback. `-Offline` is an explicit choice to use a possibly old snapshot; every
cached document is revalidated and a missing/corrupt entry fails closed. Cache write
failure warns but leaves the validated online result usable. `-WhatIf` also prevents
cache writes. The client rejects redirects/non-JSON responses, limits each response
to 4 MiB, and uses 20-second connect/read timeouts with normal system TLS validation.
No credentials are sent and upstream/private source URLs are never fetched.
Cache snapshots can become stale or withdrawn; refresh online before relying on
current availability. No automatic schedule or background update is installed.

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
bundled theme use remains offline; the public source is opt-in. Code is MIT-licensed; catalog data and stored
HTML/SVG documents have separate rights. Read [CATALOG-NOTICES.md](CATALOG-NOTICES.md).
