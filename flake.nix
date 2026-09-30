{
  description = "Composable CouchDB and PostgreSQL NixOS modules with retained state";

  inputs.nixpkgs.url = "tarball+https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1080142.f9bce96a417a/nixexprs.tar.xz";
  inputs.clan-core.url = "github:clan-lol/clan-core/c612dac4b2bfb5278b7c366f250044ddb5401bcb";

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
      lib.mkRecoveryTools = import ./lib/recovery-tools.nix;
      checks = nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (system: {
        database-recovery = import ./checks/database-recovery.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });
      lib.recoveryToolsCheck = import ./checks/recovery-tools.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      };
      lib.contractCheck =
        assert self.lib.recoveryToolsCheck;
        import ./checks/contract.nix {
          inherit self nixpkgs clan-core;
        };
    };
}
