# Verification

## Required repository gates

Before proposing a release, run the contributor gates from [AGENTS.md](../AGENTS.md):

```sh
nixfmt --check <changed Nix files>
nix eval --json .#lib.contractCheck
```

The contract must pass against the locked public Clan input. Keep readable output
and timings in local evidence. Run `bash -n` and ShellCheck for changed helper or
fixture scripts, and `git diff --check` for whitespace. Obtain independent review
of the coherent change and resolve material findings. Reuse unaffected runtime
evidence only with explicit unchanged inputs/code/derivation/closure identities.

`lib.contractCheck` includes `lib.recoveryToolsCheck` and starts no databases.
It evaluates default-disabled, active, partly retained and wholly retained
modules; stable state/identity/secret/restore mappings; safe database names and
exact duplicate-state rejection; package authority independent of host overlays;
callback/package/path contracts; and required CouchDB component provenance.
Component negatives force capture and validator independently; native replay must
match both derivation and output. Pure success is configuration/package evidence,
not an application recovery or deployed-runtime result.

## Available native fixture

```sh
nix build --no-link .#checks.aarch64-linux.database-recovery
# x86_64-linux exposes the same check
```

The fixture runs native PostgreSQL/CouchDB on a Linux builder, with a ten-minute
failure ceiling and bounded child/readiness waits. It creates no NixOS/QEMU VM
or root/system-manager runner and has no application or Reliability dependency.
The output contains readable `results.log`.

Coverage includes custom PostgreSQL import/structural check and semantic fixture
callback; CouchDB ordered capture/disposable import and callback; input/source
preservation; read-only input/store, private PID/network and writable scratch;
callback failure, partial copy, source running/stopped state, owned group TERM,
process/scratch cleanup and rejected formats. Focused corruption cases cover
synthetic wrong source-major metadata before PostgreSQL initialization, readable
TOC with truncated PostgreSQL payload failing import before callback, and a
corrupt CouchDB fixture file with valid marker failing composed HTTP readability.
Synthetic metadata is not a real older-major dump; selected corrupt fixtures do
not prove general corruption detection. Attachment/conflict coverage remains
limited as specified in [recovery helpers](recovery.md#artifact-behavior).

Use meaningful affected checks without repeating unchanged generic suites.
Package/closure equality can justify reuse; neither a matching DB version nor a
result-log closure alone proves identity of an executed validator. Consumer
qualification must use effective DB, native component, callbacks and support
packages through the public API; no neighbor/upstream implementation inspection
or legacy adapter is needed.

## Consumer PREDEPLOY boundary

Current source acceptance comprises review, locked pure evaluation/composition,
builds and available ordinary native tool/process/DB checks. Actual system-manager
and live consumer behavior below is mandatory **PREDEPLOY / NOT OBSERVED**.
Missing observations do not block source/release acceptance and never count as
PASS. No new VM, root runner or privilege/credential/isolation workaround is
created. Production operations require their separate authorization.

Apps owns consistency, native capture, publication, readers and application
semantics. Reliability consumes Apps' public interface and owns transport; it is
not a Primitives product/test dependency. They own one shared acceptance matrix
and reuse generic DB evidence rather than adding a Primitives lifecycle engine.

| Required runtime observation | Owner |
| --- | --- |
| Actual PostgreSQL root-to-postgres peer connection, selected socket/port/package, private output FD propagation and real application semantic callbacks | Apps |
| Quiescence across activation paths, complete prior-activity record before mutation, failed preparation, initially active/inactive state and verified resumption | Apps |
| Failure/cancellation preserves prior current before commit; completed atomic commit selects complete immutable generation despite later cancellation or unit failure | Apps |
| Full-attempt admission; unknown ownership/activity/teardown fails closed; selected current never reclaimed; failed reclaim prevents a third producer payload | Apps |
| Reader acquisition overlapping publication/prepare; independent disk copy before reclaim; preservation of foreign/uncertain input | Apps / Reliability |
| Same-host confinement, TERM/KILL descendants and unknown outcomes, process stop before reader deletion, cleanup failures and RuntimeDirectory lifetime | Apps / Reliability |
| Host-wide capacity/admission for producer trees, each reader, wrapper input, writable DB scratch, native writes/logs/pages and failed scratch | Apps / Reliability |

Complete capture and semantic recovery acceptance are separate. Producer capture
has no precommit disposable/semantic import; teardown and verified prior-activity
restoration precede marker/metadata and atomic commit. Two full producer trees
(current + pending) exclude independent reader and validator workspaces; they
are not an observed total-host capacity limit. Final consumer source/package
qualification must match that contract before the corresponding deployment.
Open issues with outstanding consumer/runtime criteria remain open.
