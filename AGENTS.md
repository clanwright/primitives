# Primitives contributor notes

- Own only the generic CouchDB and PostgreSQL NixOS module contracts here. Keep
  application routes, ingress, installation policy and credentials with their
  respective owners.
- Preserve state names, runtime identity, secret metadata, restore ownership and
  database major versions when changing lifecycle behavior.
- Run `nixfmt --check` on changed Nix files and
  `nix eval --json .#lib.contractCheck` before proposing a release. The contract
  check must pass against the locked public Clan input. Record readable check
  results before proposing a release.
- Reviews inspect this repository and its check results. Treat upstream NixOS
  and Clan modules as external projects: use their public options and evaluated
  behavior, without inspecting implementations through other checkouts, the Nix
  store, fetched sources, or GitHub.
- Do not deploy, change providers or DNS, restore or prune backups, or create or
  alter credentials and secrets from this repository. Publication and release
  require separate owner authorization.
