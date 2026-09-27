{
  self,
  nixpkgs,
  clan-core,
  system,
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  source = "/tmp/primitives-example-capture-source";
  clan = clan-core.lib.clan {
    self.inputs.self.clan = clan.config;
    specialArgs.clan-core = clan-core;
    directory = ./.;
    imports = [
      {
        machines.fixture = {
          imports = [ (import ../examples/postgresql-recovery.nix self) ];
          nixpkgs.hostPlatform = system;
          boot.isContainer = true;
          system.stateVersion = "26.11";
          clan.core.state.fixture-app-db = {
            folders = lib.mkForce [ source ];
            preBackupScript = lib.mkForce ''
              mkdir -p ${source}
              if [ "''${TEST_PRE_FAIL:-0}" = 1 ]; then
                printf 'partial\n' > ${source}/pg-dump
                exit 1
              fi
              if [ "''${TEST_TERM:-0}" = 1 ]; then
                kill -TERM "$PPID"
                exit 0
              fi
              if [ "''${TEST_SKIP_DUMP:-0}" != 1 ]; then
                if [ "''${TEST_SYMLINK_DUMP:-0}" = 1 ]; then
                  ln -s /dev/null ${source}/pg-dump
                else
                  printf 'staged-dump\n' > ${source}/pg-dump
                fi
              fi
              if [ "''${TEST_MARKER_FAIL:-0}" = 1 ]; then
                ln -s /dev/full "$TEST_CAPTURE_OUTPUT/format-version"
              fi
            '';
            postBackupScript = lib.mkForce ''
              printf 'post\n' >> "$TEST_POST_LOG"
              if [ "''${TEST_POST_FAIL:-0}" = 1 ]; then
                exit 1
              fi
            '';
          };
        };
        inventory.meta.name = "example-capture-fixture";
        inventory.machines.fixture = { };
      }
    ];
  };
  host = clan.config.nixosConfigurations.fixture.config;
  state = host.clan.core.state.fixture-app-db;
  capture = host.clanwright.recovery.units.fixture-app.captureCommand;
in
assert state.folders == [ source ];
assert lib.hasInfix "TEST_PRE_FAIL" state.preBackupScript;
assert lib.hasInfix "TEST_POST_FAIL" state.postBackupScript;
pkgs.runCommand "postgresql-recovery-example-capture"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
  }
  ''
    set -eu
    mkdir -p "$out" ${source}
    export TEST_POST_LOG="$out/post.log"

    capture_case() {
      case_name=$1
      expected=$2
      output=$(mktemp -d)
      export TEST_CAPTURE_OUTPUT="$output"
      rm -f ${source}/pg-dump
      if ${capture} "$output"; then
        status=success
      else
        status=failure
      fi
      test "$status" = "$expected"
      if [ "$expected" = failure ]; then
        test -z "$(find "$output" -mindepth 1 -print -quit)"
      else
        test "$(cat "$output/pg-dump")" = staged-dump
        test "$(cat "$output/format-version")" = fixture-app-pg18-v1
      fi
      rm -f -- "$output/pg-dump" "$output/format-version"
      rmdir "$output"
      printf '%s: %s\n' "$case_name" "$status" >> "$out/results.log"
    }

    capture_case success success
    export TEST_PRE_FAIL=1
    capture_case partial-pre failure
    unset TEST_PRE_FAIL
    export TEST_SKIP_DUMP=1
    capture_case missing-dump failure
    unset TEST_SKIP_DUMP
    export TEST_SYMLINK_DUMP=1
    capture_case symlink-dump failure
    unset TEST_SYMLINK_DUMP
    export TEST_MARKER_FAIL=1
    capture_case marker-write failure
    unset TEST_MARKER_FAIL
    export TEST_POST_FAIL=1
    capture_case post-hook failure
    unset TEST_POST_FAIL
    export TEST_TERM=1
    capture_case termination failure
    unset TEST_TERM

    test "$(wc -l < "$out/post.log")" -eq 7
    cat "$out/results.log"
  ''
