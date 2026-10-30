# Validation and release checklist

WTConfigurator 1.1.0 targets Windows PowerShell 5.1, PowerShell 7, Windows 10/11,
and Windows Terminal 1.12+ with modern profiles. No package publishing or public
repository upload is performed by the development tools.

## Engineering checks

From PowerShell 7.4.6+ on Windows:

```powershell
.\tools\Initialize-DevEnvironment.ps1
.\tools\Test-Project.ps1
.\tools\Build-Package.ps1
```

`Test-Project.ps1 -Engine Desktop` or `-Engine Core` runs one supported engine;
the default runs both. Core lint requires PowerShell 7.4.6+. `-SkipLint` is for
diagnosis and does not satisfy the release checklist. Pester 5.9.1 and
PSScriptAnalyzer 1.25.0 are loaded from `.dev/modules` by exact version.

The checks cover manifest validity, clean module behavior, temporary settings
transactions, catalog schema/provenance, and byte-identical repeated runtime
catalog generation. `Build-Package.ps1` runs the full checks by default and
creates `dist/WTConfigurator-1.1.0.zip`; `-SkipChecks` is available only after the
same revision passed the full runner, for example in CI. The builder validates
the packaged manifest and imports the extracted package in a clean process.

The ZIP contains `WTConfigurator/`, including the manifest, module/private
helpers, compact catalog, README, changelog, release guide, licenses/notices,
and package metadata. The entry wrapper is beside that directory at ZIP root.
Tests, developer dependencies, refresh tools, and source archives are excluded.
The lean runtime catalog still contains third-party data.

## Manual Terminal appearance checks

Use a disposable copy of settings, or an explicit known settings path, and retain
the returned backup path. Run these checks on Windows 10 and Windows 11:

1. List themes and profiles from both PowerShell engines. Apply a known theme
   such as `catppuccin/mocha` and confirm foreground, background, cursor, and all
   16 ANSI colors in a Terminal tab.
2. Set opacity to 100, then 80 with acrylic enabled; confirm the visible result.
   On Windows 11 set acrylic to false and confirm unblurred transparency.
   Windows 10 does not support the unblurred opacity mode.
3. Change defaults with a profile that has explicit appearance values, then
   target that profile by name and GUID. Confirm unrelated profiles and unfocused
   overrides remain unchanged.
4. Preview with `-WhatIf` and decline `-Confirm`; confirm the settings hash and
   directory contents remain unchanged. Repeat an already satisfied operation;
   confirm it reports `Changed = $false` and creates no backup.
5. Restore a reported backup and verify exact bytes and visible appearance.
   Confirm restoration created a backup of the state it replaced.
6. In Stable/Preview coexistence, confirm active-edition detection or an
   actionable ambiguity error; confirm an explicit `-SettingsPath` resolves it.
7. Extract the ZIP into a temporary module directory, import it in new
   PowerShell 5.1 and 7 sessions, and perform the theme/opacity/restore flow.

Record OS, Terminal version, PowerShell versions, checks, and results before
release. CI fixture success does not substitute for the visual checks.

## Rights gate

The current catalog's redistribution status is unresolved. Both scopes must be
verified before publishing the module or making its archived-source repository
public: (1) runtime catalog data, and (2) archived HTML/SVG source documents.
Check creator-specific attribution or license terms as well as collector terms.

Record reviewed evidence in a JSON file, then supply its path:

```powershell
.\tools\Build-Package.ps1 -ReleaseReady -RightsEvidencePath C:\review\rights.json
```

The required evidence shape is:

```json
{
  "schema_version": "1.0",
  "runtime_catalog": {
    "verified": true,
    "rights_basis": "Applicable license or written permission and its scope",
    "evidence": "Resolvable URL or path to the retained license/permission",
    "reviewed_by": "Human reviewer",
    "reviewed_at": "2026-10-07T00:00:00Z"
  },
  "source_archives": {
    "verified": true,
    "rights_basis": "Permission covering archived HTML and SVG in the public repository",
    "evidence": "Resolvable URL or path to the retained license/permission",
    "reviewed_by": "Human reviewer",
    "reviewed_at": "2026-10-07T00:00:00Z"
  }
}
```

This is a shape example, **not verified evidence**. The builder requires both
affirmative review records and includes the evidence in a release-ready package.
It does not perform a legal assessment or turn an assertion into permission.
The human review must cover the actual bundled data and public source archives,
and required notices must be added to `CATALOG-NOTICES.md` before publication.
Update that notice's unresolved-status text when the review is complete.

Without `-ReleaseReady`, packages are explicitly marked `NOT PUBLIC RELEASE READY`
even if an evidence path is supplied. `-ReleaseReady` also refuses skipped
engineering checks and an unresolved catalog notice. Rights evidence changes
are auditable inputs, never generated assertions.

## Publication preparation

- Confirm engineering checks, both OS visual checks, and both rights scopes.
- Review README, command help, changelog, catalog attribution, and package contents.
- Ensure the public repository home is `yuxiaoli/wt-configurator` and manifest
  version is `1.1.0`; use a `v1.1.0` tag only after review.
- Retain validation and rights evidence with the release record. Publish only
  after the explicit publication instruction; these scripts do not publish.

## Public API acceptance (1.1.0)

After building, extract the ZIP and run `tools/Test-PublicCatalog.ps1` separately
under `powershell.exe` and `pwsh`, supplying `-ManifestPath` for the extracted
manifest and `-OutputDirectory` for disposable fixtures. This explicitly contacts
the approved public API, uses new synthetic settings, checks every palette slot and
all unrelated settings, exercises list/interactive wrapper selection and verifies
exact backup restoration. Receipts report actual engine, OS, source version and
hashes. It does not select a real Terminal installation or claim visual validation.
The offline regression suite uses synthetic data and never requires the public API.

The new consumer does not clear the pre-existing bundled-data rights gate. Local
built 1.1.0 packages remain NOT PUBLIC RELEASE READY until that review and the
manual platform checks above are completed. No release-ready assertion should be
inferred from a passing CI build or a successful public API request.

For a distributable client without the legacy palettes, use
`./tools/Build-Package.ps1 -PublicCatalogOnly` (the CI artifact uses this variant).
It creates `WTConfigurator-1.1.0-public-api.zip`, omits `data/themes.json` and
archived sources, and includes an explicit `data/source.json` configuration making
PublicCatalog the theme default. Import and opacity-only operations stay offline.
Package import, opacity transactions and restoration are checked offline by the
builder. Run the public acceptance script for actual API theme application.
This variant avoids redistributing withheld palettes; it does not override the
existing source-archive rights or manual visual-release requirements.

## Source archive exclusion

`.gitattributes` applies `export-ignore` to exactly
`WTConfigurator/data/themes.json` and `data/terminal-themes.json`. The latter
contains the captured HTML/SVG documents. Git retains both files and their history.
GitHub documents that [source downloads use git archive](https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives);
[Git documents export-ignore](https://git-scm.com/docs/git-archive#ATTRIBUTES).
These archive attributes are separate from `Build-Package -PublicCatalogOnly`.

CI creates a source ZIP from its exact commit and runs `tools/Test-SourceArchive.ps1`.
The check requires every other tracked file, including code, license and notices,
and compares every archived file against its Git blob. Before tagging a release,
also download the actual GitHub ZIP and tarball for the final commit. Check the ZIP
with `tools/Test-SourceArchive.ps1 -Commit <sha> -ArchivePath <downloaded.zip>`
and verify the tarball has the same paths and contents. Retain both inventories
and hashes; local packaging success is not evidence of GitHub's output.

Archive source use requires explicit `-Source PublicCatalog`; installable API-only
packages already select it by default. Exclusion applies to archives of commits
containing these attributes; old commits/tags and Git checkouts are unchanged.
This does not clear legacy rights, authorize publishing, or substitute for the
Windows 10/11 visual checks. A narrower API-only prerelease with outstanding
visual/platform checks requires an explicit owner decision and must state the
limits. Do not use `-ReleaseReady` or assert full release readiness for that build.
