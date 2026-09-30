{ pkgs }:
let
  postgresql = pkgs.postgresql_18;
  couchdb = pkgs.couchdb3;
  erlang = pkgs.beamMinimalPackages.erlang;
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
    runtimeInputs = [ postgresql ];
    text = ''
      echo POSTGRES_OWNER_CALLBACK_REACHED
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
      curl --fail --silent --show-error --max-time 10 --user "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
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
      fifo=$(mktemp -u "$TMPDIR/callback-wait.XXXXXXXX")
      mkfifo "$fifo"
      exec 3<>"$fifo"
      rm "$fifo"
      echo VALIDATOR_CALLBACK_READY
      read -r -t 60 -u 3 || exit 1
    '';
  };
  pgValidator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    database = "validation";
    inherit postgresql;
    check = pgCallback;
  };
  pgRejectValidator = tools.mkPostgresqlValidator {
    inherit postgresql;
    dumpRelativePath = "pg-dump";
    database = "validation";
    check = rejectCallback;
  };
  pgWaitValidator = tools.mkPostgresqlValidator {
    inherit postgresql;
    dumpRelativePath = "pg-dump";
    database = "validation";
    check = waitCallback;
  };
  couch = tools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    inherit couchdb erlang;
    check = couchCallback;
  };
  couchReject = tools.mkCouchdbRecovery {
    inherit couchdb erlang;
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    check = rejectCallback;
  };
  couchWait = tools.mkCouchdbRecovery {
    inherit couchdb erlang;
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    check = waitCallback;
  };
  copyFailure = pkgs.writeShellScriptBin "cp" ''
    ${pkgs.coreutils}/bin/cp "$@"
    echo CAPTURE_COPY_FAILED
    exit 1
  '';
  copyWait = pkgs.writeShellScriptBin "cp" ''
    fifo=$(${pkgs.coreutils}/bin/mktemp -u /tmp/capture-wait.XXXXXXXX)
    ${pkgs.coreutils}/bin/mkfifo "$fifo"
    exec 3<>"$fifo"
    ${pkgs.coreutils}/bin/rm "$fifo"
    echo CAPTURE_COPY_READY
    read -r -t 60 -u 3 || exit 1
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
    inherit couchdb erlang;
    check = couchCallback;
  };
  couchWaitCapture = waitTools.mkCouchdbRecovery {
    sourceDirectory = "/tmp/primitives-source-couchdb";
    nodeName = "couchdb@localhost";
    inherit couchdb erlang;
    check = couchCallback;
  };
in
pkgs.runCommand "database-recovery-roundtrips"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      couchdb
      pkgs.curl
      erlang
      pkgs.jq
      pkgs.nss_wrapper
      pkgs.util-linux
      postgresql
    ];
  }
  ''
    mkdir -p "$out"
    export TEST_PG_VALIDATOR=${isolated (pkgs.lib.getExe pgValidator)}
    export TEST_PG_REJECT_VALIDATOR=${isolated (pkgs.lib.getExe pgRejectValidator)}
    export TEST_PG_WAIT_VALIDATOR=${pkgs.lib.getExe pgWaitValidator}
    export TEST_COUCH_VALIDATOR=${isolated (pkgs.lib.getExe couch.validate)}
    export TEST_COUCH_REJECT_VALIDATOR=${isolated (pkgs.lib.getExe couchReject.validate)}
    export TEST_COUCH_WAIT_VALIDATOR=${pkgs.lib.getExe couchWait.validate}
    export TEST_COUCH_CAPTURE=${pkgs.lib.getExe couch.capture}
    export TEST_COUCH_FAILURE_CAPTURE=${pkgs.lib.getExe couchFailureCapture.capture}
    export TEST_COUCH_WAIT_CAPTURE=${pkgs.lib.getExe couchWaitCapture.capture}
    export TEST_COUCHDB=${couchdb}/bin/couchdb
    export TEST_COUCHDB_DEFAULT_INI=${couchdb}/etc/default.ini
    export TEST_EPMD=${erlang}/bin/epmd
    export TEST_CA_CERTIFICATES=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export TEST_SANDBOX_FIXTURE=${isolated sandboxFixture}
    export PATH=${
      pkgs.lib.makeBinPath [
        postgresql
        couchdb
      ]
    }:"$PATH"
    timeout --kill-after=10s 10m bash ${./runtime/database-recovery.sh} > "$out/results.log" 2>&1 || { cat "$out/results.log"; exit 1; }
    cat "$out/results.log"
  ''
