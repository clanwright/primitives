# Database recovery helpers

Primitives composes native database tools into executable packages. Apps owns
capture orchestration, application consistency, publication, reader lifetime and
semantic acceptance. There is no PostgreSQL capture factory, shared staging lock,
recovery declaration schema or lifecycle executor here.

## Package API and authority

`primitives.lib.mkRecoveryTools { inherit pkgs; }` uses caller `pkgs` for support
tools. Each constructor requires an explicit effective database package and a
callback derivation with nonempty `meta.mainProgram`; invoke returned packages
with `lib.getExe`. Callbacks must enforce meaningful application invariants and
use the selected database/client packages. Helpers clear inherited environment
while preserving file descriptors; native package writers provide entrypoints,
PATH and runtime variables. No project-owned Python or Restic dependency is used.

| Constructor | Arguments | Result |
| --- | --- | --- |
| `mkPostgresqlValidator` | `postgresql`, `dumpRelativePath`, `database`, `check` | Validator package, `validate-postgresql-recovery` |
| `mkCouchdbRecovery` | `couchdb`, `erlang`, `sourceDirectory`, `check`, `nodeName ? "couchdb@localhost"` | `capture` and `validate` packages |

PostgreSQL must be major 18; CouchDB must be 3.5.2 for its artifact format.
`dumpRelativePath` is nonempty and relative, with no empty, `.` or `..` components.
`sourceDirectory` is absolute. Runtime directories must be canonical real
paths; input trees reject symlinks and special files.

```nix
let
  tools = primitives.lib.mkRecoveryTools { inherit pkgs; };
  databasePkgs =
    primitives.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
  postgresValidator = tools.mkPostgresqlValidator {
    postgresql = config.services.postgresql.package;
    dumpRelativePath = "database/pg-dump";
    database = "validation";
    check = applicationPostgresqlCheck;
  };
  couchRecovery = tools.mkCouchdbRecovery {
    couchdb = config.services.couchdb.package;
    erlang = databasePkgs.beamMinimalPackages.erlang;
    sourceDirectory = "/var/lib/couchdb";
    nodeName = "couchdb@localhost"; # match the source node
    check = applicationCouchdbCheck;
  };
}
```

The application supplies the two executable callback packages. The `erlang`
binding shown is supported for the unmodified Primitives CouchDB module: refer
to the SAME Primitives artifact supplying the module, whose database comes from
that input's `couchdb3`. Caller Clan support packages do not select the component.
A component-changing native override requires its explicitly selected component.

The factory requires derivation-valued `erlang` and supported native override
metadata, then verifies that
`couchdb.override { beamMinimalPackages = { inherit erlang; }; }` reproduces BOTH
the effective CouchDB `drvPath` and `outPath` before returning either package.
The replay is an assertion; original `couchdb` remains the sole executable and
`etc/default.ini` authority. Disposable configuration appends generated
`local.ini` to that default INI, without host discovery or fallback.

This check prevents silently mixing a caller Erlang cohort with the selected DB.
Support covers native CouchDB3.5.2 and specifically tested preserving overrides.
Matching versions or paths do not generally attest arbitrary spoofed,
argument-ignoring, destructive dependency or wrapper constructions; those require
explicit qualification. Record effective DB, component, callback and support
closures together, including PostgreSQL `nss_wrapper` and CouchDB HTTP/JSON tools
and CA bundle. No package scanner or global input rebinding is provided.

## Artifact behavior

PostgreSQL capture belongs to Apps using native `pg_dump` from the effective
source service package and an explicitly supported socket, port and role.
Never copy a live PostgreSQL data directory. Validation receives one absolute
artifact directory, rejects non-CUSTOM/non-18 archives before initialization,
starts a disposable cluster/private socket, imports with
`pg_restore --exit-on-error --single-transaction --no-owner --no-acl`, runs
`pg_amcheck`, then invokes `check` without arguments. `PGHOST`, `PGPORT`, `PGUSER`
and `PGDATABASE` select that disposable database. Production role/ACL
reconstruction belongs to the restore owner.

CouchDB capture receives one existing empty mode-0700 directory owned by the
capture account and outside the source tree. It copies `.view` indexes before
`.couch` files, excludes configuration/cookies/logs, and writes
`couchdb-recovery.json` with format `primitives-couchdb-files-v1`, version 3.5.2
and node name. It never changes source service state; catchable failure clears
partial output. The marker states expected package version, not a queried source
version. Hot-copy file consistency does not establish cross-database/application
atomicity; Apps owns writer coordination.

CouchDB validation checks the exact marker and allowed files, copies data to
writable scratch and starts disposable CouchDB. It traverses current winning
document bodies in pages of 32 rows with 30-second page requests, then invokes
`check` with disposable `COUCHDB_URL`, `COUCHDB_USER` and `COUCHDB_PASSWORD`.
It does not establish attachment-payload or nonwinning-conflict readability.

## Workspace and execution contract

Capture writes one full candidate directly into caller output; temporary
`.capture-files` path metadata stays there and is removed before the marker.
Reserve full-copy capacity even with `reflink=auto`, plus metadata and source
growth. Validation separately requires a complete writable input copy, database
writes, logs and page overhead; row limits are not byte caps. Each independent
reader, retained wrapper copy and retained failed scratch adds to host-wide
accounting. A two-tree producer bound is not a total-host byte cap.

Validators require non-root identity. The execution owner supplies private
PID/network/filesystem isolation, admission, an overall execution budget and
final process-tree/scratch lifetime enforcement; helper-local directories and
fixed disposable ports alone do not provide isolation. Helpers stop native
processes before normal scratch removal and handle catchable signals. SIGKILL
or host failure requires executor cleanup. PostgreSQL import/callback has no
helper-wide timeout; CouchDB server lifetime is locally bounded but the outer
attempt still needs a budget.

Retain compatible handler closures, DB packages/extensions and app versions for
stored artifacts; reject unsupported formats before import. See
[verification and consumer PREDEPLOY acceptance](verification.md#consumer-predeploy-boundary)
for the single owner/acceptance matrix; generic imports alone do not establish
publication, application semantics or same-host runtime guarantees.
