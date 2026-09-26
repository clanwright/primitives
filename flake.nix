{
  description = "Composable CouchDB and PostgreSQL NixOS modules with retained state";

  inputs.nixpkgs.url = "tarball+https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1044894.59ea0b1c043c/nixexprs.tar.xz";
  inputs.clan-core.url = "github:clan-lol/clan-core/3b5832a13fb0ad1e57c2dafd246ca8ab60ad1b20";

  outputs =
    {
      self,
      nixpkgs,
      clan-core,
    }:
    {
      nixosModules = {
        couchdb = import ./modules/couchdb.nix nixpkgs;
        postgresql = import ./modules/postgresql.nix nixpkgs;
      };
      lib.contractCheck = import ./checks/contract.nix {
        inherit self nixpkgs clan-core;
      };
    };
}
