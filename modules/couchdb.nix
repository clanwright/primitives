nixpkgs:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.clanwright.primitives.couchdb;
  active = cfg.enable && cfg.lifecycle == "enabled";
  domainPkgs = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.services.clanwright.primitives.couchdb = {
    enable = lib.mkEnableOption "retained or active loopback CouchDB with Clan state and SOPS administrator configuration";
    lifecycle = lib.mkOption {
      type = lib.types.enum [
        "enabled"
        "disabled-retained"
      ];
      default = "enabled";
      description = "Retained keeps state, identity and secret metadata without starting CouchDB.";
    };
    stateName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Clan state registration name for /var/lib/couchdb.";
    };
    adminConfigSecretName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "SOPS secret containing a CouchDB administrator INI fragment; the caller supplies the encrypted value.";
    };
    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Native services.couchdb.extraConfig supplied by the application.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        clan.core.state."${cfg.stateName}".folders = [ "/var/lib/couchdb" ];
        sops.secrets."${cfg.adminConfigSecretName}" = {
          path = "/run/secrets/${cfg.adminConfigSecretName}";
          owner = "couchdb";
          group = "couchdb";
          mode = "0400";
          restartUnits = lib.optional active "couchdb.service";
        };
      }
      (lib.mkIf (!active) {
        users.users.couchdb = {
          description = "CouchDB Server user";
          group = "couchdb";
          uid = config.ids.uids.couchdb;
          isSystemUser = true;
          isNormalUser = false;
          home = "/var/empty";
          createHome = false;
          useDefaultShell = false;
          shell = "${pkgs.shadow}/bin/nologin";
        };
        users.groups.couchdb = {
          gid = config.ids.gids.couchdb;
          name = "couchdb";
        };
      })
      (lib.mkIf active {
        users.users.couchdb = {
          isSystemUser = true;
          shell = "${pkgs.shadow}/bin/nologin";
        };
        services.couchdb = {
          enable = true;
          package = domainPkgs.couchdb3;
          bindAddress = "127.0.0.1";
          port = 5984;
          adminPass = null;
          extraConfigFiles = [ config.sops.secrets."${cfg.adminConfigSecretName}".path ];
          inherit (cfg) extraConfig;
        };
      })
    ]
  );
}
