{
  self,
  nixpkgs,
  clan-core,
}:
let
  modules = self.nixosModules;
  inherit (nixpkgs) lib;
  evaluate =
    couchLifecycle: alphaLifecycle: pgLifecycle: foreignPackages: duplicateStateName:
    let
      clan = clan-core.lib.clan {
        self.inputs.self.clan = clan.config;
        specialArgs.clan-core = clan-core;
        directory = ./.;
        imports = [
          {
            machines.fixture = {
              imports = [
                modules.couchdb
                modules.postgresql
              ];
              nixpkgs.overlays = lib.optional foreignPackages (
                _: previous: {
                  couchdb3 = previous.couchdb3.overrideAttrs (_: {
                    pname = "foreign-couchdb";
                  });
                  postgresql_18 = previous.postgresql_18.overrideAttrs (_: {
                    pname = "foreign-postgresql";
                  });
                }
              );
              nixpkgs.hostPlatform = "x86_64-linux";
              boot.isContainer = true;
              system.stateVersion = "26.11";
              sops.defaultSopsFile = builtins.toFile "primitives-empty-sops.yaml" "sops:\n  age: []\n";
              sops.age.keyFile = "/run/fixture/age-key";
              services.clanwright.primitives = {
                couchdb = {
                  enable = true;
                  lifecycle = couchLifecycle;
                  stateName = "fixture-couch";
                  adminConfigSecretName = "fixture-admin-ini";
                  extraConfig.log.level = "warning";
                };
                postgresql.databases = {
                  alpha = {
                    user = "alpha-user";
                    stateName = "alpha-db";
                    lifecycle = alphaLifecycle;
                    restoreStopUnits = [ "alpha-app.service" ];
                  };
                  beta = {
                    user = "beta-user";
                    stateName = if duplicateStateName then "alpha-db" else "beta-db";
                    lifecycle = pgLifecycle;
                    restoreStopUnits = [ "beta-app.service" ];
                  };
                };
              };
            };
            inventory.meta.name = "primitives-fixture";
            inventory.machines.fixture = { };
          }
        ];
      };
      c = clan.config.nixosConfigurations.fixture.config;
    in
    {
      couchEnabled = c.services.couchdb.enable;
      couchBind = c.services.couchdb.bindAddress;
      couchPort = c.services.couchdb.port;
      couchVersion = c.services.couchdb.package.version;
      couchPackage = c.services.couchdb.package.outPath;
      couchAdminPass = c.services.couchdb.adminPass;
      couchSecretFiles = c.services.couchdb.extraConfigFiles;
      couchState = c.clan.core.state.fixture-couch.folders;
      couchUid = c.users.users.couchdb.uid;
      couchGid = c.users.groups.couchdb.gid;
      expectedCouchUid = c.ids.uids.couchdb;
      expectedCouchGid = c.ids.gids.couchdb;
      couchSecretPath = c.sops.secrets.fixture-admin-ini.path;
      couchOwner = c.sops.secrets.fixture-admin-ini.owner;
      couchGroup = c.sops.secrets.fixture-admin-ini.group;
      couchMode = c.sops.secrets.fixture-admin-ini.mode;
      couchRestart = c.sops.secrets.fixture-admin-ini.restartUnits;
      postgresEnabled = c.clan.core.postgresql.enable;
      postgresVersion =
        if alphaLifecycle == "enabled" || pgLifecycle == "enabled" then
          c.services.postgresql.package.version
        else
          null;
      postgresPackage =
        if alphaLifecycle == "enabled" || pgLifecycle == "enabled" then
          c.services.postgresql.package.outPath
        else
          null;
      postgresDatabases = builtins.attrNames c.clan.core.postgresql.databases;
      alphaOwner =
        if alphaLifecycle == "enabled" then
          c.clan.core.postgresql.databases.alpha.create.options.OWNER
        else
          null;
      alphaStateName =
        if alphaLifecycle == "enabled" then c.clan.core.postgresql.databases.alpha.service else null;
      alphaRestoreUnits =
        if alphaLifecycle == "enabled" then
          c.clan.core.postgresql.databases.alpha.restore.stopOnRestore
        else
          [ ];
      alphaState = c.clan.core.state.alpha-db.folders or [ ];
      betaState = c.clan.core.state.beta-db.folders or [ ];
      firewall = c.networking.firewall.allowedTCPPorts;
      failedAssertions = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
    };
  active = evaluate "enabled" "enabled" "enabled" false false;
  retained = evaluate "disabled-retained" "enabled" "disabled-retained" false false;
  allRetained = evaluate "disabled-retained" "disabled-retained" "disabled-retained" false false;
  foreignHostPackages = evaluate "enabled" "enabled" "enabled" true false;
  duplicateStateName =
    evaluate "disabled-retained" "disabled-retained" "disabled-retained" false
      true;
  expectedCouch = nixpkgs.legacyPackages.x86_64-linux.couchdb3.outPath;
  expectedPostgres = nixpkgs.legacyPackages.x86_64-linux.postgresql_18.outPath;
in
assert
  active.failedAssertions == [ ]
  && retained.failedAssertions == [ ]
  && allRetained.failedAssertions == [ ]
  && foreignHostPackages.failedAssertions == [ ];
assert active.couchEnabled && active.couchBind == "127.0.0.1" && active.couchPort == 5984;
assert
  active.couchAdminPass == null && active.couchSecretFiles == [ "/run/secrets/fixture-admin-ini" ];
assert
  active.couchState == [ "/var/lib/couchdb" ]
  && active.couchOwner == "couchdb"
  && active.couchGroup == "couchdb"
  && active.couchMode == "0400";
assert
  active.couchRestart == [ "couchdb.service" ]
  && active.couchPackage == expectedCouch
  && active.couchVersion == "3.5.2";
assert
  active.postgresEnabled
  &&
    active.postgresDatabases == [
      "alpha"
      "beta"
    ];
assert
  active.alphaOwner == "alpha-user"
  && active.alphaStateName == "alpha-db"
  && active.alphaRestoreUnits == [ "alpha-app.service" ];
assert active.postgresPackage == expectedPostgres && active.postgresVersion == "18.6";
assert
  retained.couchEnabled == false
  && retained.couchRestart == [ ]
  && retained.couchState == [ "/var/lib/couchdb" ]
  && retained.couchUid == retained.expectedCouchUid
  && retained.couchGid == retained.expectedCouchGid
  && retained.couchOwner == "couchdb"
  && retained.couchGroup == "couchdb"
  && retained.couchMode == "0400"
  && retained.couchSecretPath == "/run/secrets/fixture-admin-ini";
assert
  retained.postgresDatabases == [ "alpha" ] && retained.betaState == [ "/var/backup/postgres/beta" ];
assert
  allRetained.couchEnabled == false
  && allRetained.postgresEnabled == false
  && allRetained.postgresDatabases == [ ]
  && allRetained.couchUid == allRetained.expectedCouchUid
  && allRetained.couchGid == allRetained.expectedCouchGid
  && allRetained.couchOwner == "couchdb"
  && allRetained.couchGroup == "couchdb"
  && allRetained.couchMode == "0400"
  && allRetained.couchSecretPath == "/run/secrets/fixture-admin-ini";
assert
  allRetained.alphaState == [ "/var/backup/postgres/alpha" ]
  && allRetained.betaState == [ "/var/backup/postgres/beta" ];
assert
  foreignHostPackages.couchPackage == expectedCouch
  && foreignHostPackages.postgresPackage == expectedPostgres;
assert
  active.firewall == [ ]
  && retained.firewall == [ ]
  && allRetained.firewall == [ ]
  && foreignHostPackages.firewall == [ ];
assert builtins.elem "Primitives PostgreSQL requests must have distinct stateName values."
  duplicateStateName.failedAssertions;
true
