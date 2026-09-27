primitives:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  database = "fixture_app";
  stateName = "fixture-app-db";
  formatVersion = "fixture-app-pg18-v1";
  state = config.clan.core.state.${stateName};
  stateFolder = builtins.head state.folders;
  nativePre = state.preBackupScript;
  nativePost = state.postBackupScript;
  tools = primitives.lib.mkRecoveryTools { system = pkgs.stdenv.hostPlatform.system; };
  ownerSQLCheck = lib.getExe (
    pkgs.writeShellApplication {
      name = "fixture-app-recovery-invariants";
      runtimeInputs = [ pkgs.postgresql_18 ];
      text = ''
        test "$(psql -X -A -t -d ${database} -c "SELECT value FROM fixture_settings WHERE key = 'installation-id'")" = fixture-preserved
      '';
    }
  );
  validator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    inherit database;
    checkCommand = ownerSQLCheck;
  };
  expectedMarker = pkgs.writeText "fixture-app-recovery-format" "${formatVersion}\n";
  capture = lib.getExe (
    pkgs.writeShellApplication {
      name = "capture-fixture-app-postgresql";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.bash
      ];
      text = ''
        test "$#" -eq 1
        output=$1
        case "$output" in /*) ;; *) exit 1 ;; esac
        test -d "$output"
        test ! -L "$output"
        test "$(stat -c %u "$output")" = "$(id -u)"
        test "$(stat -c %a "$output")" = 700
        test -z "$(find "$output" -mindepth 1 -print -quit)"

        cleanup() {
          status=$?
          trap - EXIT
          trap : HUP INT TERM
        ${lib.optionalString (nativePost != null) ''
          if ! ${pkgs.bash}/bin/bash -euo pipefail -c ${lib.escapeShellArg nativePost}; then
            status=1
          fi
        ''}
        if [ "$status" -ne 0 ]; then
          rm -f -- "$output/pg-dump" "$output/format-version"
        fi
        exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        ${pkgs.bash}/bin/bash -euo pipefail -c ${lib.escapeShellArg nativePre}
        test -f ${lib.escapeShellArg "${stateFolder}/pg-dump"}
        test ! -L ${lib.escapeShellArg "${stateFolder}/pg-dump"}
        cp -- ${lib.escapeShellArg "${stateFolder}/pg-dump"} "$output/pg-dump"
        printf '%s\n' ${lib.escapeShellArg formatVersion} > "$output/format-version"
      '';
    }
  );
  validate = lib.getExe (
    pkgs.writeShellApplication {
      name = "validate-fixture-app-postgresql";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        test "$#" -eq 1
        input=$1
        test -f "$input/format-version"
        cmp -s -- "$input/format-version" ${expectedMarker}
        exec ${validator} "$input"
      '';
    }
  );
in
{
  imports = [
    primitives.nixosModules.postgresql
    primitives.nixosModules.recovery
  ];

  services.clanwright.primitives.postgresql.databases.${database} = {
    user = "fixture-app";
    inherit stateName;
  };

  clanwright.recovery.units.fixture-app = {
    contractVersion = 1;
    inherit formatVersion;
    captureCommand = capture;
    validateCommand = validate;
    stateRefs = [ stateName ];
  };
}
