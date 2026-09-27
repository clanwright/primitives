#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d /tmp/primitives-check.XXXXXX)
source_data=/tmp/primitives-source-couchdb
pg_running=0
couch_pid=
cleanup() {
  if [ "$pg_running" = 1 ]; then pg_ctl -D "$root/pg-data" -m immediate -w stop >/dev/null 2>&1 || :; fi
  if [ -n "$couch_pid" ]; then kill "$couch_pid" 2>/dev/null || :; wait "$couch_pid" 2>/dev/null || :; fi
  "$TEST_EPMD" -port 14369 -kill >/dev/null 2>&1 || :
  rm -rf "$root" "$source_data"
}
trap cleanup EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@"; then fail "unexpected success: $*"; fi; }
scratch_count() { find /tmp -mindepth 1 -maxdepth 1 \( -name 'primitives-postgresql.*' -o -name 'primitives-couchdb.*' \) | wc -l; }

mkdir -m 777 "$root/sandbox-input"
readlink /proc/self/ns/pid > "$root/sandbox-input/host-pid-ns"
readlink /proc/self/ns/net > "$root/sandbox-input/host-net-ns"
"$TEST_SANDBOX_FIXTURE" "$root/sandbox-input"
printf 'PASS executor fixture: unprivileged, separate PID and network namespaces, no passwd, read-only input/store, writable private tmp\n'

export PGHOST="$root" PGPORT=5432 PGUSER=postgres PGDATABASE=alpha
initdb -D "$root/pg-data" --username=postgres --auth=trust --no-locale >/dev/null
pg_ctl -D "$root/pg-data" -l "$root/postgres.log" -w start -o "-k $root -c listen_addresses=''" >/dev/null
pg_running=1
createdb alpha
psql -X -v ON_ERROR_STOP=1 -c "CREATE TABLE meaningful_fixture (id integer PRIMARY KEY, value text); INSERT INTO meaningful_fixture VALUES (1, 'preserved')" >/dev/null
mkdir -m 700 "$root/pg-artifact"
pg_dump --compress=zstd --dbname=alpha -Fc -c -f "$root/pg-artifact/pg-dump.tmp"
mv "$root/pg-artifact/pg-dump.tmp" "$root/pg-artifact/pg-dump"
pg_before=$(sha256sum "$root/pg-artifact/pg-dump")
baseline=$(scratch_count)
"$TEST_PG_VALIDATOR" "$root/pg-artifact"
[ "$(sha256sum "$root/pg-artifact/pg-dump")" = "$pg_before" ] || fail 'PostgreSQL input modified'
[ "$(psql -X -Atc 'SELECT value FROM meaningful_fixture WHERE id=1')" = preserved ] || fail 'source PostgreSQL changed'
[ "$(scratch_count)" = "$baseline" ] || fail 'PostgreSQL scratch leaked'
printf 'PASS PostgreSQL 18 native custom archive roundtrip; input and source unchanged; scratch removed\n'
expect_failure "$TEST_PG_REJECT_VALIDATOR" "$root/pg-artifact"
[ "$(scratch_count)" = "$baseline" ] || fail 'PostgreSQL callback failure leaked scratch'
printf 'PASS PostgreSQL owner callback failure rejects and cleans up\n'
"$TEST_PG_WAIT_VALIDATOR" "$root/pg-artifact" > "$root/pg-term.log" 2>&1 & validator_pid=$!
callback_ready=0
for _ in $(seq 1 200); do
  if grep -q VALIDATOR_CALLBACK_READY "$root/pg-term.log"; then callback_ready=1; break; fi
  if ! kill -0 "$validator_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[ "$callback_ready" = 1 ] || { cat "$root/pg-term.log"; fail 'PostgreSQL termination callback was not reached'; }
kill -TERM "$validator_pid"
if wait "$validator_pid"; then fail 'terminated PostgreSQL validator returned success'; fi
[ "$(scratch_count)" = "$baseline" ] || fail 'terminated PostgreSQL validator leaked scratch'
printf 'PASS PostgreSQL TERM during owner callback removes scratch and disposable service\n'
printf 'not a custom archive\n' > "$root/pg-artifact/pg-dump"
expect_failure "$TEST_PG_VALIDATOR" "$root/pg-artifact"
[ "$(scratch_count)" = "$baseline" ] || fail 'PostgreSQL format failure leaked scratch'
printf 'PASS PostgreSQL rejects invalid archive\n'
pg_ctl -D "$root/pg-data" -m immediate -w stop >/dev/null
pg_running=0

mkdir -m 700 "$source_data"
cat > "$root/source.ini" <<EOF
[couchdb]
database_dir = $source_data
view_index_dir = $root/source-views
single_node = true
uuid = 00000000000000000000000000000001
[chttpd]
bind_address = 127.0.0.1
port = 15984
[httpd]
bind_address = 127.0.0.1
port = 15986
[admins]
validator = disposable-validation-only
[log]
writer = stderr
level = error
EOF
cat > "$root/vm.args" <<EOF
-name couchdb@localhost
-setcookie disposable-validation-only
-start_epmd false
-noinput
+S 2:2
EOF
printf '[{public_key, [{cacerts_path, "%s"}]}].\n' "$TEST_CA_CERTIFICATES" > "$root/sys.config"
export HOME="$root" COUCHDB_ARGS_FILE="$root/vm.args" COUCHDB_SYSCONFIG_FILE="$root/sys.config"
export ERL_FLAGS="-couch_ini $TEST_COUCHDB_DEFAULT_INI $root/source.ini"
export ERL_EPMD_PORT=14369 ERL_EPMD_ADDRESS=127.0.0.1
"$TEST_EPMD" -daemon -port 14369 > "$root/epmd.log" 2>&1
"$TEST_COUCHDB" > "$root/couch.log" 2>&1 & couch_pid=$!
couch_url=http://127.0.0.1:15984
couch_auth=validator:disposable-validation-only
ready=0
for _ in $(seq 1 200); do
  if ! kill -0 "$couch_pid" 2>/dev/null; then
    wait "$couch_pid" || source_status=$?
    cat "$root/couch.log" "$root/epmd.log"
    fail "source CouchDB exited with status ${source_status:-0}"
  fi
  if curl --fail --silent --max-time 2 --user "$couch_auth" "$couch_url/_up" | jq -e '.status == "ok"' >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { cat "$root/couch.log"; fail 'source CouchDB readiness timeout'; }
curl --fail --silent --user "$couch_auth" -X PUT "$couch_url/fixture" >/dev/null
curl --fail --silent --user "$couch_auth" -X PUT -H 'Content-Type: application/json' -d '{"value":"preserved"}' "$couch_url/fixture/meaningful" >/dev/null
[ "$(find "$source_data" -name '*.couch' | wc -l)" -gt 0 ] || fail 'source CouchDB lacks .couch data'
printf 'must-not-enter-artifact\n' > "$source_data/.erlang.cookie"
printf 'must-not-enter-artifact\n' > "$source_data/local.ini"
mkdir -m 700 "$root/couch-artifact"
source_before=$(find "$source_data" -type f -exec sha256sum '{}' + | sort)
"$TEST_COUCH_CAPTURE" "$root/couch-artifact"
artifact_before=$(find "$root/couch-artifact" -type f -exec sha256sum '{}' + | sort)
test ! -e "$root/couch-artifact/data/.erlang.cookie" || fail 'cookie copied into artifact'
test ! -e "$root/couch-artifact/data/local.ini" || fail 'configuration copied into artifact'
[ "$(find "$source_data" -type f -exec sha256sum '{}' + | sort)" = "$source_before" ] || fail 'CouchDB source modified during capture'
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB capture leaked scratch'
"$TEST_COUCH_VALIDATOR" "$root/couch-artifact"
[ "$(find "$root/couch-artifact" -type f -exec sha256sum '{}' + | sort)" = "$artifact_before" ] || fail 'CouchDB input modified during validation'
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB validation leaked scratch'
[ "$(find "$source_data" -type f -exec sha256sum '{}' + | sort)" = "$source_before" ] || fail 'CouchDB source modified during validation'
curl --fail --silent --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB 3.5.2 live .couch capture and disposable validation; source and input unchanged\n'
expect_failure "$TEST_COUCH_REJECT_VALIDATOR" "$root/couch-artifact"
[ "$(find "$root/couch-artifact" -type f -exec sha256sum '{}' + | sort)" = "$artifact_before" ] || fail 'CouchDB input modified on callback failure'
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB callback failure leaked scratch'
printf 'PASS CouchDB owner callback failure rejects and cleans up\n'
mkdir -m 700 "$root/couch-failed-capture"
ln -s "$root/missing" "$source_data/unsupported-link"
expect_failure "$TEST_COUCH_CAPTURE" "$root/couch-failed-capture"
[ -z "$(find "$root/couch-failed-capture" -mindepth 1 -print -quit)" ] || fail 'failed CouchDB capture left partial output'
rm "$source_data/unsupported-link"
curl --fail --silent --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB capture rejects nonregular source and preserves running service\n'
mkdir -m 700 "$root/couch-copy-failure"
expect_failure "$TEST_COUCH_FAILURE_CAPTURE" "$root/couch-copy-failure"
[ -z "$(find "$root/couch-copy-failure" -mindepth 1 -print -quit)" ] || fail 'copy failure left partial CouchDB output'
printf 'PASS CouchDB partial copy failure clears output\n'
mkdir -m 700 "$root/couch-term-capture"
"$TEST_COUCH_WAIT_CAPTURE" "$root/couch-term-capture" > "$root/capture-term.log" 2>&1 & capture_pid=$!
copy_ready=0
for _ in $(seq 1 100); do
  if grep -q CAPTURE_COPY_READY "$root/capture-term.log"; then copy_ready=1; break; fi
  if ! kill -0 "$capture_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[ "$copy_ready" = 1 ] || { cat "$root/capture-term.log"; fail 'CouchDB capture did not reach copy'; }
kill -TERM "$capture_pid"
if wait "$capture_pid"; then fail 'terminated CouchDB capture returned success'; fi
[ -z "$(find "$root/couch-term-capture" -mindepth 1 -print -quit)" ] || fail 'terminated CouchDB capture left partial output'
curl --fail --silent --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB TERM during copy clears output and preserves running source\n'
kill "$couch_pid"
wait "$couch_pid" || :
couch_pid=
"$TEST_EPMD" -port 14369 -kill >/dev/null
mkdir -m 700 "$root/couch-stopped-capture"
"$TEST_COUCH_CAPTURE" "$root/couch-stopped-capture"
if curl --fail --silent --max-time 2 --user "$couch_auth" "$couch_url/_up" >/dev/null; then fail 'CouchDB capture started stopped source'; fi
printf 'PASS CouchDB capture preserves stopped source state\n'
"$TEST_COUCH_WAIT_VALIDATOR" "$root/couch-artifact" > "$root/couch-term.log" 2>&1 & validator_pid=$!
callback_ready=0
for _ in $(seq 1 200); do
  if grep -q VALIDATOR_CALLBACK_READY "$root/couch-term.log"; then callback_ready=1; break; fi
  if ! kill -0 "$validator_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[ "$callback_ready" = 1 ] || { cat "$root/couch-term.log"; fail 'CouchDB termination callback was not reached'; }
kill -TERM "$validator_pid"
if wait "$validator_pid"; then fail 'terminated CouchDB validator returned success'; fi
[ "$(scratch_count)" = "$baseline" ] || fail 'terminated CouchDB validator leaked scratch'
printf 'PASS CouchDB TERM during owner callback removes scratch and disposable service\n'
printf '{"format":"unsupported"}\n' > "$root/couch-artifact/couchdb-recovery.json"
expect_failure "$TEST_COUCH_VALIDATOR" "$root/couch-artifact"
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB format failure leaked scratch'
printf 'PASS CouchDB rejects unsupported format\n'
