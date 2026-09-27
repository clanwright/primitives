# Recovery contract v1

Import `primitives.nixosModules.recovery` alongside Clan. It declares
`clanwright.recovery.units` without enabling databases, services, timers or
providers. Existing DB module behavior changes only through explicit options
or the documented PostgreSQL major-version upgrade in this release.

Primitives owns this schema and generic DB mechanics; Apps owns grouping,
application consistency, artifact formats and semantic checks; Reliability owns
isolation, scheduling, Restic destinations, retention and evidence. The consumer
owns selections, deployment, policy and secret bindings.

## Declaration

Unit IDs match `[a-z][a-z0-9-]*`. All fields are required; unknown fields fail.

| Field | Contract |
| --- | --- |
| `contractVersion` | Integer `1`; interface version, not stored format. |
| `formatVersion` | Owner-defined string matching `[A-Za-z0-9_.-]{1,64}`. |
| `stateRefs` | Nonempty, unique list of existing `clan.core.state` names. |
| `captureCommand` | Immutable executable, called with one absolute empty output directory. |
| `validateCommand` | Immutable executable, called with one absolute restored directory. |

Use `${package}/bin/program` to retain Nix dependency context. Evaluation checks
store path shape/context; the executor checks existence and executable mode.
Native Clan is the only folder registry. Referenced folders must be absolute,
without `.` or `..`. Overlapping folders/groups are rejected except identical
stateRef groups sharing the same capture command. Serialize all captures of shared
state. Evaluation cannot detect deployed symlink or bind-mount aliases; owners
must not register those as independent state.

## Capture and validation

Capture receives an existing private empty directory and a minimal environment.
It produces portable regular files/directories, without symlinks or repository
credentials. `reliability-manifest.json` is reserved for Reliability. Capture has
no external networking; consumers grant required production writable paths.
Exit zero means the staged generation is complete and application cleanup and
resumption succeeded. Any failure makes it unpublishable. Owners cover partial
preparation and catchable termination, preserve previously stopped services,
and finish quiescence before returning; remote upload happens afterwards.

Validation runs as a dedicated unprivileged account in a fresh Bubblewrap sandbox:
read-only `/input` and `/nix/store`, writable private `/tmp`, private PID/network
namespaces with loopback, no inherited environment, production paths/credentials,
host services or required `/etc/passwd`. Provide `/bin/sh` as a symlink to a
Nix-store shell for native PostgreSQL initialization; never bind the host `/bin`.
Executable dependencies stay in the store; DB data, sockets, config and logs stay
under `/tmp`. Copy read-only artifacts to scratch if import requires writes.

The owner must reject unsupported formats **before import** and check meaningful
application invariants afterwards. Never run native production restore hooks.
The executor owns final child teardown and scratch lifetime; helpers handle
normal and catchable-failure cleanup. SIGKILL/machine failure cannot be handled
by a shell trap. Consumers must budget termination grace and verify their actual
sandbox before production commissioning.

## Native helpers

`primitives.lib.mkRecoveryTools { system = "aarch64-linux"; }` builds helpers from
this flake's pinned packages (also exposed for `x86_64-linux`). They compose native
commands with shell glue; no project Python runtime or Restic dependency.

- `mkPostgresqlValidator { dumpRelativePath; database; checkCommand; }` returns
  a validator executable. It accepts PostgreSQL 18 custom archives, creates a
  private socket/instance, imports with `pg_restore --no-owner --no-acl`, performs
  structural checks, then calls the immutable owner command without arguments.
  `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` select only the disposable database.
  Source role/permission reconstruction remains production-restore policy.
- `mkCouchdbRecovery { sourceDirectory; checkCommand;
  nodeName ? "couchdb@localhost"; }` returns capture/validate executable paths.
  Capture copies view indexes before `.couch` files, omits config/cookies, and
  never changes source service state. Use the actual database directory and
  source node name. Validation copies to scratch, starts CouchDB with disposable
  authentication, reads database contents, then calls the owner command with
  `COUCHDB_URL`, `COUCHDB_USER`, `COUCHDB_PASSWORD` for that disposable instance.

CouchDB's documented hot copy provides file consistency, not a single atomic
point across multiple databases or application files; Apps coordinates that.
Its helper marker records the expected pinned version, not a queried production
version: pair it with the matching source package. Owner `formatVersion` checks
and semantic callbacks remain mandatory; a placeholder `true` is insufficient.

Reuse Clan's native PostgreSQL preparation: it stages the custom `pg-dump` under
`/var/backup/postgres/<database>`. Copy that completed artifact, never the running
data directory. The [migration example](../examples/postgresql-recovery.nix)
composes native preparation/cleanup for one transaction-consistent database.
Serialize **all** native capture callers sharing its staging directory.

## Historical recovery points

Interface version, stored format and release version are distinct. Unknown data
formats/majors fail closed. Disabling/removing a producer stops new capture but
does not invalidate old archives; retain a separately pinned recovery configuration
and compatible handler closures, DB versions/extensions and app versions. Remove
live unit declarations when their native state registration is removed.
Reliability's manifest records unit ID, format, generation and capture time;
v1 does not automatically record owner-release provenance.

References: [Clan state](https://clan.lol/docs/26.05/reference/clan.core/state),
[PostgreSQL dump](https://www.postgresql.org/docs/18/app-pgdump.html) and
[restore](https://www.postgresql.org/docs/18/app-pgrestore.html),
[CouchDB backup](https://docs.couchdb.org/en/stable/maintenance/backups.html).
