# Public terminal catalogue integration

Scope: extend the existing PowerShell module, preserving bundled compatibility,
settings transactions and all unrelated settings. Consume only the approved public
API v1; no private source, withheld palettes, live settings or Boot Loader changes.

1. Inspect current repository/protocol, ownership, API contract and release gates.
2. Implement explicit source selection, index/palette/provenance checks, safe
   network/cache behavior and wrapper selection.
3. Test both PowerShell engines with synthetic fixtures, then test actual public
   API application/restoration using the extracted built package.
4. Build the existing installable module ZIP; review and submit a feature PR to
   develop. Preserve main. Follow existing release rights and visual-check gates.

Design: bundled remains the offline default. Public summaries resolve names to
stable IDs, then fetch only the selected payload. Formats are deliberately limited
to validated Gogh RGB palettes. Explicit offline cache avoids unnoticed staleness;
network failure cannot reach settings writes. Source/version evidence is returned
to callers without adding foreign metadata to Terminal settings.

The repository initially had only main and no AGENTS/.agents skills. Develop was
created from 37cd163508ef60215cf5fa9ad43a3f4e3fb03ec4. Default-branch setting needs an
available authenticated administration interface; the connected tools do not expose
that mutation and the in-app GitHub browser is signed out. No protection is bypassed.
