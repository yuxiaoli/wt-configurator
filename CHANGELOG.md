# Changelog

## 1.1.0

- Add explicit `PublicCatalog` source to theme commands and interactive selection.
- Validate public API v1 identities, Gogh palettes and source/license provenance;
  expose withheld entries and reject unsupported formats without fallback.
- Add opt-in atomic JSON caching and explicit offline mode; failures preserve settings.
- Reuse transactional writes, exact backups/restoration, profile targeting and WhatIf.
- Make the test runner fail on Pester discovery/container errors as well as test failures.
- Preserve the bundled catalogue's existing rights gate; this is not a rights clearance.

## 1.0.0 - 2026-10-07

- Added an offline PowerShell module with theme lookup, profile inspection,
  combined appearance updates, and exact-byte settings restoration.
- Added opacity and acrylic controls for defaults or one selected profile.
- Added conservative JSON round-trip validation, exact backups, cooperating
  process locking, atomic replacement, no-op detection, and recovery reporting.
- Retained the script entry point for listing and interactive selection.
- Added catalog validation, deterministic runtime generation, source-preserving
  refresh tooling, two-engine tests, Windows CI, and local package builds.
- Separated project MIT licensing from catalog and archive rights. Public
  release readiness remains conditional on verified redistribution evidence.
