# Primitives

Primitives exports the composable `nixosModules.couchdb` and
`nixosModules.postgresql` public API for the 0.1.0 release line. Import either
module into a NixOS host with Clan and SOPS modules already present. Callers set
typed options under `services.clanwright.primitives`; the installation supplies
encrypted SOPS material and selects the host. These modules do not provision
credentials or network ingress.

`couchdb` composes the native NixOS CouchDB service with a fixed loopback
listener on `127.0.0.1:5984`, CouchDB 3 from this flake's pinned package set,
Clan state at `/var/lib/couchdb`, stable native UID/GID, and SOPS administrator
INI metadata. Set `services.clanwright.primitives.couchdb.enable = true` with
`stateName`, `adminConfigSecretName`, and optional native `extraConfig`. The
default `lifecycle = "enabled"` runs CouchDB; `"disabled-retained"` removes the
runtime while preserving state, identity, and secret metadata. The caller owns
the secret value and any application-specific authentication, CORS, sizing, or
HTTP policy.

`postgresql` takes independent requests under
`services.clanwright.primitives.postgresql.databases.<databaseName>`. Each entry
sets `user`, `stateName`, optional `restoreStopUnits`, and optional `lifecycle`
(default `"enabled"`). Active entries delegate role creation, database
ownership, state, backup, and restore semantics to `clan.core.postgresql` while
selecting PostgreSQL 17 from this flake's pinned package set. A
`"disabled-retained"` entry registers only its existing
`/var/backup/postgres/<databaseName>` path under `stateName`; it does not start
PostgreSQL or recreate the database. An application owns its own data state and
orders its systemd unit after and requires `postgresql.service`.

The 0.1.0 package baseline is CouchDB 3.5.1 and PostgreSQL 17.10 from the
locked nixpkgs input. Changing that pin requires compatibility review. The
modules have no dependency on any application or installation repository.
The project is licensed under the [MIT License](LICENSE).

The standalone `lib.contractCheck` evaluates both modules in a real Clan host
fixture using the exact locked public Clan and nixpkgs inputs. It covers active,
partly retained and wholly retained states, two database requests, restore
mapping, SOPS metadata, no firewall opening, and package identity even with a
different host package overlay. Run `nix eval --json .#lib.contractCheck` from
this directory. This evaluates desired state; it does not test a deployed
service or execute backup/restore.
