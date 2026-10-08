# Catalog attribution and redistribution status

The theme catalog was obtained from [TerminalColors](https://terminalcolors.com/).
The canonical snapshot is `data/terminal-themes.json`; the installable runtime
catalog is `WTConfigurator/data/themes.json`. The snapshot records each theme's
family, variant, source URL, palette, and original family/SVG document references.
Captured documents include fetch timestamps and SHA-256 hashes. Runtime metadata
retains the source URL and snapshot capture timestamp, with the source documents
omitted from the installed module.

Theme names and underlying palettes belong to their respective creators.
Attribution to TerminalColors identifies the collection source and does not
establish that TerminalColors can authorize redistribution of every theme.
The MIT license in this repository applies to project code and tooling; it does
not relicense catalog data or the source HTML/SVG documents.

**Redistribution rights have not yet been verified.** Public release readiness
requires written evidence covering both the runtime catalog and the archived
HTML/SVG documents in the public source repository. Until that evidence is
reviewed, locally built artifacts are marked `NOT PUBLIC RELEASE READY`.
No permission is inferred from public availability, scraping access, source
URLs, or the absence of an explicit license.

Before public publication, obtain applicable licenses or permission, record
their scope and evidence, retain required creator notices, and complete the
rights checklist in [RELEASE.md](RELEASE.md). If permission does not cover the
existing archives, remove or replace them in a separately reviewed source-data
change before declaring public readiness.
