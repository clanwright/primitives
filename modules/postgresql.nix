nixpkgs:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.clanwright.primitives.postgresql;
  active = lib.filterAttrs (_: db: db.lifecycle == "enabled") cfg.databases;
  retained = lib.filterAttrs (_: db: db.lifecycle == "disabled-retained") cfg.databases;
  stateNames = map (db: db.stateName) (lib.attrValues cfg.databases);
  domainPkgs = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.services.clanwright.primitives.postgresql.databases = lib.mkOption {
    default = { };
    description = "Independent PostgreSQL database requests; attribute names are database names.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }: {
          options = {
            user = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = name;
              description = "Database owner and local PostgreSQL role.";
            };
            stateName = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Clan state/service name; retain the existing name across migration.";
            };
            restoreStopUnits = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
              default = [ ];
              description = "Application units Clan stops during restore.";
            };
            lifecycle = lib.mkOption {
              type = lib.types.enum [
                "enabled"
                "disabled-retained"
              ];
              default = "enabled";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg.databases != { }) {
    assertions = [
      {
        assertion = builtins.length stateNames == builtins.length (lib.unique stateNames);
        message = "Primitives PostgreSQL requests must have distinct stateName values.";
      }
    ];

    clan.core.postgresql = lib.mkIf (active != { }) {
      enable = true;
      users = lib.mapAttrs' (_: db: lib.nameValuePair db.user { }) active;
      databases = lib.mapAttrs (_: db: {
        service = db.stateName;
        create.options.OWNER = db.user;
        restore.stopOnRestore = db.restoreStopUnits;
      }) active;
    };

    services.postgresql.package = lib.mkIf (active != { }) domainPkgs.postgresql_18;

    clan.core.state = lib.mapAttrs' (
      name: db:
      lib.nameValuePair db.stateName {
        folders = [ "/var/backup/postgres/${name}" ];
      }
    ) retained;
  };
}
