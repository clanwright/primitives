{
  self,
  nixpkgs,
  clan-core,
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  tools = self.lib.mkRecoveryTools { system = "x86_64-linux"; };
  couchOwnerCheck = lib.getExe (
    pkgs.writeShellApplication {
      name = "second-couch-recovery-invariants";
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
      ];
      text = ''
        curl --fail --silent --user "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL/fixture/installation" | jq -e '.value == "fixture-preserved"'
      '';
    }
  );
  couchRecovery = tools.mkCouchdbRecovery {
    sourceDirectory = "/var/lib/couchdb";
    checkCommand = couchOwnerCheck;
  };
  clan = clan-core.lib.clan {
    self.inputs.self.clan = clan.config;
    specialArgs.clan-core = clan-core;
    directory = ./.;
    imports = [
      {
        machines.fixture = {
          imports = [
            (import ../examples/postgresql-recovery.nix self)
            self.nixosModules.couchdb
          ];
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.isContainer = true;
          system.stateVersion = "26.11";
          sops.defaultSopsFile = builtins.toFile "producer-example-empty-sops.yaml" "sops:\n  age: []\n";
          sops.age.keyFile = "/run/fixture/age-key";
          services.clanwright.primitives.couchdb = {
            enable = true;
            stateName = "second-couch";
            adminConfigSecretName = "second-couch-admin";
          };
          clanwright.recovery.units.second-couch = {
            contractVersion = 1;
            formatVersion = "second-couch-v1";
            stateRefs = [ "second-couch" ];
            inherit (couchRecovery) captureCommand validateCommand;
          };
        };
        inventory.meta.name = "producer-examples-fixture";
        inventory.machines.fixture = { };
      }
    ];
  };
  host = clan.config.nixosConfigurations.fixture.config;
  units = host.clanwright.recovery.units;
  state = host.clan.core.state.fixture-app-db;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) host.assertions);
  dispatch = lib.mapAttrs (_: unit: {
    inherit (unit)
      contractVersion
      formatVersion
      stateRefs
      captureCommand
      validateCommand
      ;
  }) units;
in
assert failures == [ ];
assert
  builtins.attrNames dispatch == [
    "fixture-app"
    "second-couch"
  ];
assert builtins.all (unit: unit.contractVersion == 1) (builtins.attrValues dispatch);
assert units.fixture-app.stateRefs == [ "fixture-app-db" ];
assert units.fixture-app.formatVersion == "fixture-app-pg18-v1";
assert units.fixture-app.captureCommand != units.second-couch.captureCommand;
assert units.fixture-app.validateCommand != units.second-couch.validateCommand;
assert host.clan.core.postgresql.databases.fixture_app.service == "fixture-app-db";
assert host.clan.core.state.second-couch.folders == [ "/var/lib/couchdb" ];
assert state.folders == [ "/var/backup/postgres/fixture_app" ];
assert builtins.isString state.preBackupScript;
assert lib.hasInfix "pg_dump" state.preBackupScript;
assert lib.hasInfix "pg-dump" state.preBackupScript;
assert state.postBackupScript == null;
true
