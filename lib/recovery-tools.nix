{ pkgs }:
let
  inherit (pkgs) lib;
  immutable =
    path:
    builtins.isString path
    && builtins.getContext path != { }
    && builtins.match "/nix/store/[a-z0-9]{32}-[^/]+(/[^/]+)+" path != null
    && !(builtins.any (part: part == "." || part == "..") (lib.splitString "/" path));
  command =
    name: script: dependencies: variables:
    lib.getExe (
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
        ]
        ++ dependencies;
        text = ''
          exec ${pkgs.coreutils}/bin/env -i PATH=${
            lib.escapeShellArg (
              lib.makeBinPath (
                [
                  pkgs.coreutils
                  pkgs.findutils
                ]
                ++ dependencies
              )
            )
          } ${
            lib.concatStringsSep " " (
              lib.mapAttrsToList (key: value: "${key}=${lib.escapeShellArg value}") variables
            )
          } \
            ${pkgs.bash}/bin/bash ${script} "$@"
        '';
      }
    );
  common = {
    RECOVERY_COMMON = "${./recovery/common.sh}";
  };
in
assert lib.versions.major pkgs.postgresql_18.version == "18";
assert pkgs.couchdb3.version == "3.5.2";
{
  # Capture uses the existing Clan native custom-format pg-dump generation.
  mkPostgresqlValidator =
    {
      dumpRelativePath,
      database,
      checkCommand,
    }:
    assert immutable checkCommand;
    assert dumpRelativePath != "" && !(lib.hasPrefix "/" dumpRelativePath);
    assert
      !(builtins.any (part: part == ".." || part == "." || part == "") (
        lib.splitString "/" dumpRelativePath
      ));
    command "validate-postgresql-recovery" ./recovery/postgresql-validate.sh
      [ pkgs.postgresql_18 pkgs.gnugrep ]
      (
        common
        // {
          DUMP_RELATIVE_PATH = dumpRelativePath;
          PGDATABASE = database;
          CHECK_COMMAND = checkCommand;
          NSS_LIBRARY = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
        }
      );
  mkCouchdbRecovery =
    {
      sourceDirectory,
      checkCommand,
      nodeName ? "couchdb@localhost",
    }:
    assert immutable checkCommand;
    assert lib.hasPrefix "/" sourceDirectory;
    assert builtins.match "[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+" nodeName != null;
    {
      captureCommand = command "capture-couchdb-recovery" ./recovery/couchdb-capture.sh [ pkgs.jq ] (
        common
        // {
          SOURCE_DIRECTORY = sourceDirectory;
          NODE_NAME = nodeName;
        }
      );
      validateCommand =
        command "validate-couchdb-recovery" ./recovery/couchdb-validate.sh
          [ pkgs.couchdb3 pkgs.beamPackages.erlang pkgs.curl pkgs.jq pkgs.gnused ]
          (
            common
            // {
              NODE_NAME = nodeName;
              CHECK_COMMAND = checkCommand;
              COUCHDB_DEFAULT_INI = "${pkgs.couchdb3}/etc/default.ini";
              CA_CERTIFICATES = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            }
          );
    };
}
