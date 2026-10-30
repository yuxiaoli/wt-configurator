# Archive packaging remediation

Parent explicitly requested packaging-only remediation while PR merge, repository
settings and Release publication remain paused. Preserve legacy files and history.

- Exclude only the runtime palette and captured source snapshot from git archives.
- Keep module code, license, documentation, developer tooling and synthetic tests.
- Add a CI archive check comparing the complete remaining inventory and blob bytes.
- Verify GitHub ZIP and tarball at the resulting exact commit, then verify the
  newly built installable API-only ZIP with isolated settings on both engines.
- Record final remote commit, archive/package hashes and receipts in PR1 and the
  ignored dist handoff after the commit is available.

GitHub archive documentation and Git export-ignore reference are linked in RELEASE.md.
No owner rights assertion is generated. The policy-denied portable Terminal launch
will not be retried through another launcher; visual/platform limits remain.
