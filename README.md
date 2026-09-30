# Primitives

Primitives provides generic CouchDB and PostgreSQL NixOS modules with retained
Clan state, plus native database recovery helper packages. Application policy,
ingress, credentials and deployment belong to consumers.

Import `primitives.nixosModules.couchdb` or `primitives.nixosModules.postgresql`
into a NixOS host with Clan and SOPS modules available. Database modules select
CouchDB **3.5.2** and PostgreSQL **18.6** from this flake's locked Nixpkgs input,
independently of host overlays. This explicit authority keeps retained state and
recovery package selection predictable; pin changes require compatibility review.

## Module options

All options are under `services.clanwright.primitives`.

| Module | Options | Behavior |
| --- | --- | --- |
| `couchdb` | `enable` (default false), required `stateName` and `adminConfigSecretName`, optional `extraConfig` (default `{ }`), `lifecycle` | Enabled service binds `127.0.0.1:5984`; registers `/var/lib/couchdb`, native stable UID/GID and mode-0400 SOPS administrator INI metadata. Caller supplies encrypted secret and application configuration. |
| `postgresql.databases.<name>` | Required `stateName`; `user` (default database name), `restoreStopUnits` (default `[ ]`), `lifecycle` | Active requests delegate roles, database ownership, state and restore semantics to `clan.core.postgresql`. Names must be nonempty path components other than `.` or `..`; state names must be distinct. |

Both lifecycles default to `"enabled"`. CouchDB `"disabled-retained"` requires
`enable = true` and preserves state, identity and secret metadata without its
runtime. PostgreSQL `"disabled-retained"` registers the existing
`/var/backup/postgres/<name>` path without requesting its runtime/database.
Applications own their other data state and service ordering.

```nix
{
  imports = [ primitives.nixosModules.postgresql ];
  services.clanwright.primitives.postgresql.databases.app = {
    stateName = "app-db";
    restoreStopUnits = [ "app.service" ];
  };
}
```

## Recovery and verification

[Recovery helpers](docs/recovery.md) owns the package API, component authority,
artifact behavior and resource requirements. [Verification](docs/verification.md)
owns required repository gates, available native checks and the single consumer
PREDEPLOY boundary. Apps owns consistency, publication, readers and semantic
checks. Reliability consumes Apps' public interface separately; it is neither a
Primitives product nor test dependency.

## PostgreSQL major-version migration

Selecting PostgreSQL 18 does not migrate an existing database. Before activating
these modules over an older major, the consumer must plan and test `pg_upgrade`
or logical dump/restore. Never start PostgreSQL 18 on an older-major data directory.
Retain compatible pinned configuration, database/extensions, application versions
and recovery handlers until existing artifacts and the migrated application are
accepted. See [PostgreSQL upgrade guidance](https://www.postgresql.org/docs/18/upgrading.html).

This repository provides configuration and generic tools; production migration
and restore remain consumer operations. Licensed under the [MIT License](LICENSE).
