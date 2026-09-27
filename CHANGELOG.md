# Changelog

## 0.2.0 — 2026-09-27

- Refresh pinned nixpkgs and Clan inputs; select PostgreSQL 18.6 and CouchDB 3.5.2.
  Existing PostgreSQL 17 installations require a separately planned data migration.
- Add the opt-in recovery-unit v1 declaration, immutable owner command paths,
  native state reference validation and compatible shared-group checks.
- Add generic native-tool recovery helpers and disposable database verification;
  application consistency and semantic checks remain with Apps.

## 0.1.0 — 2026-09-26

- Add public composable CouchDB and PostgreSQL NixOS modules with retained-state
  lifecycle behavior and pinned database package closure.
- Add a native Clan contract check for state, secret metadata, restore requests,
  lifecycle and package identity.
