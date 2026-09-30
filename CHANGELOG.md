# Changelog

## 0.3.0 — 2026-09-30

- Replace recovery command strings with native executable packages, explicit
  source database packages and package-valued semantic callbacks.
- Require an explicit CouchDB Erlang component package for EPMD and verify its
  native argument replay preserves the effective CouchDB derivation and output.
  Caller Erlang defaults do not select database support.
- Remove the recovery-unit schema, its exports/checks and the shared PostgreSQL
  staging example. Apps owns capture
  orchestration; Reliability needs no direct Primitives API.
- Keep native database roundtrips and failure/cleanup coverage, with bounded
  fixture waits and process-group cancellation instead of fixed sleeps.
- Reject empty PostgreSQL database names, `.`/`..`, and names containing `/`
  before accepting active or retained state configuration.
- Clarify that generic CouchDB validation reads current document bodies and does
  not verify attachment payloads or nonwinning conflict revisions.
- Use native active CouchDB account and group declarations, preserving the
  evaluated identity policy and explicit retained identity.

## 0.2.1 — 2026-09-28

- Paginate CouchDB validation in bounded pages and verify traversal counts.

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
