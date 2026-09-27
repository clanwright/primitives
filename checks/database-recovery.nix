{ pkgs }:
let
  tools = import ../lib/recovery-tools.nix { inherit pkgs; };
  sandboxDriver = pkgs.writeShellScript "recovery-sandbox-driver" ''
    set +e
    "$1" /input
    result=$?
    set -e
    scratch=$(find /tmp -mindepth 1 -maxdepth 1 \( -name 'primitives-postgresql.*' -o -name 'primitives-couchdb.*' \) -print -quit)
    if [ -n "$scratch" ]; then
      echo 'FAIL validator left scratch in sandbox' >&2
      exit 1
    fi
    for process in /proc/[0-9]*/comm; do
      case "$(cat "$process" 2>/dev/null || :)" in
        postgres|beam.smp|epmd)
          echo 'FAIL validator left database process in sandbox' >&2
          exit 1
          ;;
      esac
    done
    echo SANDBOX_CLEANUP_OK
    exit "$result"
  '';
  isolated =
    validator:
    pkgs.writeShellScript "isolated-recovery-validator" ''
      exec ${pkgs.bubblewrap}/bin/bwrap --unshare-all --die-with-parent --new-session --clearenv \
        --setenv PATH ${
          pkgs.lib.makeBinPath [
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
          ]
        } \
        --uid 65534 --gid 65534 --ro-bind /nix/store /nix/store \
        --proc /proc --dev /dev --tmpfs /tmp --dir /etc --dir /bin \
        --symlink ${pkgs.bash}/bin/sh /bin/sh \
        --ro-bind "$1" /input ${sandboxDriver} ${validator}
    '';
  sandboxFixture = pkgs.writeShellScript "recovery-sandbox-fixture" ''
    set -eu
    test "$(id -u)" = 65534
    test ! -e /etc/passwd
    test -z "''${PGHOST-}"
    test "$(readlink /proc/self/ns/pid)" != "$(cat /input/host-pid-ns)"
    test "$(readlink /proc/self/ns/net)" != "$(cat /input/host-net-ns)"
    awk 'NR > 2 { name = $1; sub(/:$/, "", name); if (name != "lo") bad = 1; seen = 1 } END { exit (!seen || bad) }' /proc/net/dev
    awk '$5 == "/input" && $6 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' /proc/self/mountinfo
    awk '$5 == "/nix/store" && $6 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' /proc/self/mountinfo
    if touch /input/writable-marker 2>/dev/null; then exit 1; fi
    touch /tmp/writable-marker
    test -e /tmp/writable-marker
  '';
  pgCallback = pkgs.writeShellApplication {
    name = "postgres-owner-invariants";
    runtimeInputs = [ pkgs.postgresql_18 ];
    text = ''
      test "$(psql -X -Atc 'SELECT value FROM meaningful_fixture WHERE id = 1')" = preserved
    '';
  };
  couchCallback = pkgs.writeShellApplication {
    name = "couch-owner-invariants";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      curl --fail --silent --user "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
    '';
  };
  rejectCallback = pkgs.writeShellApplication {
    name = "reject-owner-invariants";
    text = ''
      exit 1
    '';
  };
  waitCallback = pkgs.writeShellApplication {
    name = "wait-owner-invariants";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo VALIDATOR_CALLBACK_READY
      sleep 30
    '';
  };
  pgValidator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    database = "validation";
    checkCommand = pkgs.lib.getExe pgCallback;
  };
  pgRejectValidator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    database = "validation";
    checkCommand = pkgs.lib.getExe rejectCallback;
  };
  pgWaitValidator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    database = "validation";
    checkCommand = pkgs.lib.getExe waitCallback;
  };
  couch = tools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    checkCommand = pkgs.lib.getExe couchCallback;
  };
  couchReject = tools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    checkCommand = pkgs.lib.getExe rejectCallback;
  };
  couchWait = tools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    checkCommand = pkgs.lib.getExe waitCallback;
  };
  copyFailure = pkgs.writeShellScriptBin "cp" ''
    ${pkgs.coreutils}/bin/cp "$@"
    echo CAPTURE_COPY_FAILED
    exit 1
  '';
  copyWait = pkgs.writeShellScriptBin "cp" ''
    echo CAPTURE_COPY_READY
    ${pkgs.coreutils}/bin/sleep 3
  '';
  coreutilsWithCopy =
    copy:
    pkgs.runCommand "recovery-test-coreutils" { } ''
      mkdir -p "$out/bin"
      for tool in ${pkgs.coreutils}/bin/*; do
        if [ "$(basename "$tool")" != cp ]; then ln -s "$tool" "$out/bin/$(basename "$tool")"; fi
      done
      ln -s ${copy}/bin/cp "$out/bin/cp"
    '';
  failureTools = import ../lib/recovery-tools.nix {
    pkgs = pkgs // {
      coreutils = coreutilsWithCopy copyFailure;
    };
  };
  waitTools = import ../lib/recovery-tools.nix {
    pkgs = pkgs // {
      coreutils = coreutilsWithCopy copyWait;
    };
  };
  couchFailureCapture = failureTools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    checkCommand = pkgs.lib.getExe couchCallback;
  };
  couchWaitCapture = waitTools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    checkCommand = pkgs.lib.getExe couchCallback;
  };
in
pkgs.runCommand "database-recovery-roundtrips"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.couchdb3
      pkgs.curl
      pkgs.beamPackages.erlang
      pkgs.jq
      pkgs.nss_wrapper
      pkgs.postgresql_18
    ];
  }
  ''
    mkdir -p "$out"
    export TEST_PG_VALIDATOR=${isolated pgValidator}
    export TEST_PG_REJECT_VALIDATOR=${isolated pgRejectValidator}
    export TEST_PG_WAIT_VALIDATOR=${pgWaitValidator}
    export TEST_COUCH_VALIDATOR=${isolated couch.validateCommand}
    export TEST_COUCH_REJECT_VALIDATOR=${isolated couchReject.validateCommand}
    export TEST_COUCH_WAIT_VALIDATOR=${couchWait.validateCommand}
    export TEST_COUCH_CAPTURE=${couch.captureCommand}
    export TEST_COUCH_FAILURE_CAPTURE=${couchFailureCapture.captureCommand}
    export TEST_COUCH_WAIT_CAPTURE=${couchWaitCapture.captureCommand}
    export TEST_COUCHDB=${pkgs.couchdb3}/bin/couchdb
    export TEST_COUCHDB_DEFAULT_INI=${pkgs.couchdb3}/etc/default.ini
    export TEST_EPMD=${pkgs.beamPackages.erlang}/bin/epmd
    export TEST_CA_CERTIFICATES=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export TEST_NSS_WRAPPER=${pkgs.nss_wrapper}/lib/libnss_wrapper.so
    export TEST_SANDBOX_FIXTURE=${isolated sandboxFixture}
    bash ${./runtime/database-recovery.sh} > "$out/results.log" 2>&1 || { cat "$out/results.log"; exit 1; }
    cat "$out/results.log"
  ''
