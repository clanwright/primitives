# v0.2.0 verification — 2026-09-27

- `nix eval --json .#lib.contractCheck`: `true`, with the locked public Clan input.
- `nixfmt --check` on all repository Nix files: passed.
- `bash -n` and `shellcheck -s bash -x` on recovery/check scripts: passed.
- `git diff --cached --check`: passed.
- `nix build --no-link .#checks.aarch64-linux.database-recovery .#checks.aarch64-linux.example-capture`: passed, final invocation 81.26 seconds (example already cached).
- Independent standards and recovery-safety reviews: material findings resolved.

Readable build outputs (`results.log` in each directory):

```text
/nix/store/v40zy412yrclzzdh8ak8j5z5cvnyzhvj-database-recovery-roundtrips
/nix/store/0f13r222z293h90q64ri9f6nv1f18d84-postgresql-recovery-example-capture
```

Runtime coverage includes real PostgreSQL 18.6 and CouchDB 3.5.2 data recovery,
owner callbacks, read-only artifacts, source preservation, isolated validation,
partial failures and catchable termination cleanup. The capture example has
seven success/failure cases using fixture preparation/cleanup hooks; native Clan
hook wiring is evaluated, not executed against a deployed service.

CouchDB emits a nonfatal OS CA lookup diagnostic from its replication component
in the isolated environment. Local recovery passes with an immutable CA bundle;
outbound replication is neither used nor tested. Runtime evidence is aarch64 Linux;
application integration, x86_64 runtime acceptance and production migration remain
separate consumer checks. This release performs no deployment or production restore.
