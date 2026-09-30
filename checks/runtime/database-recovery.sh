#!/usr/bin/env bash
set -euo pipefail

root=$(mktemp -d /tmp/primitives-check.XXXXXX)
source_data=/tmp/primitives-source-couchdb
pg_running=0
couch_pid=
validator_pid=
capture_pid=
cleanup() {
  if [ "$pg_running" = 1 ]; then pg_ctl -D "$root/pg-data" -m immediate -w stop >/dev/null 2>&1 || :; fi
  for pid in "$validator_pid" "$capture_pid"; do
    if [ -n "$pid" ]; then kill -TERM -- "-$pid" 2>/dev/null || :; bounded_wait "$pid" cleanup || :; fi
  done
  if [ -n "$couch_pid" ]; then kill -TERM "$couch_pid" 2>/dev/null || :; bounded_wait "$couch_pid" cleanup || :; fi
  timeout 5s "$TEST_EPMD" -port 14369 -kill >/dev/null 2>&1 || :
  rm -rf "$root" "$source_data"
}
trap cleanup EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@"; then fail "unexpected success: $*"; fi; }
scratch_count() { find /tmp -mindepth 1 -maxdepth 1 \( -name 'primitives-postgresql.*' -o -name 'primitives-couchdb.*' \) | wc -l; }
# The whole fixture has an outer timeout; every readiness and child wait also
# has one shared deadline rather than multiplying per-attempt HTTP budgets.
bounded_wait() {
  local pid=$1 label=$2 log=${3:-/dev/null}
  if ! timeout 10s tail --pid="$pid" --sleep-interval=0.1 -f /dev/null; then
    cat "$log" >&2
    printf 'FAIL %s did not exit within 10 seconds\n' "$label" >&2
    kill -KILL -- "-$pid" 2>/dev/null || :
    kill -KILL "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
    return 124
  fi
  child_status=0
  wait "$pid" || child_status=$?
}
wait_for_log() {
  local pid=$1 marker=$2 log=$3 label=$4 deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if grep -q "$marker" "$log"; then return; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  cat "$log" >&2
  fail "$label readiness timeout or premature exit"
}

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
# Cancellation owns the full native invocation group; this does not model a
# same-host systemd/cgroup runner. Disposable PG is still stopped by pg_ctl.
setsid "$TEST_PG_WAIT_VALIDATOR" "$root/pg-artifact" > "$root/pg-term.log" 2>&1 & validator_pid=$!
wait_for_log "$validator_pid" VALIDATOR_CALLBACK_READY "$root/pg-term.log" 'PostgreSQL termination callback'
kill -TERM -- "-$validator_pid"
bounded_wait "$validator_pid" 'PostgreSQL terminated validator' "$root/pg-term.log" || fail 'PostgreSQL validator termination timed out'
validator_pid=
[ "$child_status" != 0 ] || fail 'terminated PostgreSQL validator returned success'
[ "$(scratch_count)" = "$baseline" ] || fail 'terminated PostgreSQL validator leaked scratch'
printf 'PASS PostgreSQL owned group TERM during owner callback removes scratch and disposable service\n'
# This is a native PostgreSQL 18 archive with synthetic unsupported source
# metadata, not an archive produced by PostgreSQL 17.
mkdir -m 700 "$root/pg-wrong-major"
cp "$root/pg-artifact/pg-dump" "$root/pg-wrong-major/pg-dump"
pg_source_version=$(psql -X -Atc 'SHOW server_version')
version_offset=$(grep -abo -F "$pg_source_version" "$root/pg-wrong-major/pg-dump" | head -n 1 | cut -d: -f1)
[ -n "$version_offset" ] || fail 'native PostgreSQL source version bytes not found'
printf '17' | dd of="$root/pg-wrong-major/pg-dump" bs=1 seek="$version_offset" conv=notrunc status=none
pg_restore --list "$root/pg-wrong-major/pg-dump" > "$root/pg-wrong-major.toc"
grep -Eq '^;[[:space:]]+Format: CUSTOM$' "$root/pg-wrong-major.toc" || fail 'synthetic source-major archive is not custom format'
grep -Eq '^;[[:space:]]+Dumped from database version: 17\.' "$root/pg-wrong-major.toc" || fail 'synthetic source-major metadata not reported by native pg_restore'
wrong_major_before=$(sha256sum "$root/pg-wrong-major/pg-dump")
if "$TEST_PG_VALIDATOR" "$root/pg-wrong-major" > "$root/pg-wrong-major.log" 2>&1; then cat "$root/pg-wrong-major.log"; fail 'unsupported PostgreSQL source major accepted'; fi
cat "$root/pg-wrong-major.toc" "$root/pg-wrong-major.log"
grep -q 'unsupported PostgreSQL source major' "$root/pg-wrong-major.log" || fail 'wrong PostgreSQL source major did not reach version rejection'
if grep -Eq 'Success. You can now start|POSTGRES_OWNER_CALLBACK_REACHED' "$root/pg-wrong-major.log"; then fail 'wrong PostgreSQL source major reached database initialization or owner callback'; fi
grep -q SANDBOX_CLEANUP_OK "$root/pg-wrong-major.log" || fail 'wrong PostgreSQL source major left a disposable process or scratch'
[ "$(sha256sum "$root/pg-wrong-major/pg-dump")" = "$wrong_major_before" ] || fail 'wrong-major PostgreSQL input modified'
[ "$(sha256sum "$root/pg-artifact/pg-dump")" = "$pg_before" ] || fail 'wrong-major case modified original PostgreSQL archive'
[ "$(psql -X -Atc 'SELECT value FROM meaningful_fixture WHERE id=1')" = preserved ] || fail 'wrong-major case changed source PostgreSQL'
[ "$(scratch_count)" = "$baseline" ] || fail 'wrong-major PostgreSQL validation leaked scratch'
printf 'PASS PostgreSQL synthetic source-major 17 metadata rejects before database initialization; input/source unchanged; sandbox clean\n'

# Observe known row bytes in a fresh native uncompressed custom archive, then
# truncate inside that payload. No custom archive offsets/layout are assumed.
mkdir -m 700 "$root/pg-corrupt-payload"
pg_dump --compress=0 --dbname=alpha -Fc -c -f "$root/pg-corrupt-payload/pg-dump"
payload_offsets=$(grep -abo -F preserved "$root/pg-corrupt-payload/pg-dump")
[ "$(printf '%s\n' "$payload_offsets" | wc -l)" = 1 ] || fail 'known PostgreSQL payload does not have exactly one observed byte offset'
payload_offset=${payload_offsets%%:*}
truncate --size="$((payload_offset + 3))" "$root/pg-corrupt-payload/pg-dump"
pg_restore --list "$root/pg-corrupt-payload/pg-dump" > "$root/pg-corrupt-payload.toc"
grep -Eq '^;[[:space:]]+Format: CUSTOM$' "$root/pg-corrupt-payload.toc" || fail 'corrupt PostgreSQL payload damaged custom TOC'
grep -Eq '^;[[:space:]]+Dumped from database version: 18\.' "$root/pg-corrupt-payload.toc" || fail 'corrupt PostgreSQL payload damaged source version'
corrupt_pg_before=$(sha256sum "$root/pg-corrupt-payload/pg-dump")
if "$TEST_PG_VALIDATOR" "$root/pg-corrupt-payload" > "$root/pg-corrupt-payload.log" 2>&1; then cat "$root/pg-corrupt-payload.log"; fail 'corrupt PostgreSQL payload accepted'; fi
cat "$root/pg-corrupt-payload.toc" "$root/pg-corrupt-payload.log"
grep -q 'Success. You can now start' "$root/pg-corrupt-payload.log" || fail 'corrupt PostgreSQL payload did not reach native database initialization'
grep -q '^pg_restore: error:' "$root/pg-corrupt-payload.log" || fail 'corrupt PostgreSQL payload did not fail native import'
if grep -q POSTGRES_OWNER_CALLBACK_REACHED "$root/pg-corrupt-payload.log"; then fail 'corrupt PostgreSQL payload reached owner callback'; fi
grep -q SANDBOX_CLEANUP_OK "$root/pg-corrupt-payload.log" || fail 'corrupt PostgreSQL payload left a disposable process or scratch'
[ "$(sha256sum "$root/pg-corrupt-payload/pg-dump")" = "$corrupt_pg_before" ] || fail 'corrupt PostgreSQL input modified'
[ "$(sha256sum "$root/pg-artifact/pg-dump")" = "$pg_before" ] || fail 'corrupt-payload case modified original PostgreSQL archive'
[ "$(psql -X -Atc 'SELECT value FROM meaningful_fixture WHERE id=1')" = preserved ] || fail 'corrupt-payload case changed source PostgreSQL'
[ "$(scratch_count)" = "$baseline" ] || fail 'corrupt-payload PostgreSQL validation leaked scratch'
printf 'PASS PostgreSQL readable custom TOC with truncated observed row payload fails native import before callback; input/source unchanged; sandbox clean\n'
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
timeout 5s "$TEST_EPMD" -daemon -port 14369 > "$root/epmd.log" 2>&1
timeout --kill-after=5s 10m "$TEST_COUCHDB" > "$root/couch.log" 2>&1 & couch_pid=$!
couch_url=http://127.0.0.1:15984
couch_auth=validator:disposable-validation-only
ready=0
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if ! kill -0 "$couch_pid" 2>/dev/null; then
    wait "$couch_pid" || source_status=$?
    cat "$root/couch.log" "$root/epmd.log"
    fail "source CouchDB exited with status ${source_status:-0}"
  fi
  if curl --fail --silent --max-time 2 --user "$couch_auth" "$couch_url/_up" | jq -e '.status == "ok"' >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { cat "$root/couch.log"; fail 'source CouchDB readiness timeout'; }
curl --fail --silent --max-time 5 --user "$couch_auth" -X PUT "$couch_url/fixture" >/dev/null
curl --fail --silent --max-time 5 --user "$couch_auth" -X PUT -H 'Content-Type: application/json' -d '{"value":"preserved"}' "$couch_url/fixture/meaningful" >/dev/null
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
curl --fail --silent --max-time 5 --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB 3.5.2 live .couch capture and disposable validation; source and input unchanged\n'
# Keep the exact native marker and damage only the captured fixture DB bytes.
mkdir -m 700 "$root/couch-corrupt-payload"
cp -R "$root/couch-artifact/." "$root/couch-corrupt-payload/"
jq -e '. == {format:"primitives-couchdb-files-v1",version:"3.5.2",nodeName:"couchdb@localhost"}' "$root/couch-corrupt-payload/couchdb-recovery.json" >/dev/null
fixture_files=$(find "$root/couch-corrupt-payload/data" -type f -name 'fixture.*.couch')
[ -n "$fixture_files" ] || fail 'native CouchDB capture lacks fixture database files'
while IFS= read -r fixture_file; do
  [ -s "$fixture_file" ] || fail 'native CouchDB fixture file was empty before corruption'
  truncate --size=1 "$fixture_file"
done <<< "$fixture_files"
corrupt_couch_before=$(find "$root/couch-corrupt-payload" -type f -exec sha256sum '{}' + | sort)
if "$TEST_COUCH_VALIDATOR" "$root/couch-corrupt-payload" > "$root/couch-corrupt-payload.log" 2>&1; then cat "$root/couch-corrupt-payload.log"; fail 'corrupt CouchDB payload accepted'; fi
cat "$root/couch-corrupt-payload.log"
grep -q 'curl: (22)' "$root/couch-corrupt-payload.log" || fail 'corrupt CouchDB payload did not fail native HTTP readability'
if grep -q 'unsupported CouchDB artifact' "$root/couch-corrupt-payload.log"; then fail 'corrupt CouchDB payload rejected at marker instead of native readability'; fi
grep -q SANDBOX_CLEANUP_OK "$root/couch-corrupt-payload.log" || fail 'corrupt CouchDB payload left a disposable process or scratch'
[ "$(find "$root/couch-corrupt-payload" -type f -exec sha256sum '{}' + | sort)" = "$corrupt_couch_before" ] || fail 'corrupt CouchDB input modified'
[ "$(find "$root/couch-artifact" -type f -exec sha256sum '{}' + | sort)" = "$artifact_before" ] || fail 'corrupt-payload case modified original CouchDB artifact'
[ "$(find "$source_data" -type f -exec sha256sum '{}' + | sort)" = "$source_before" ] || fail 'corrupt-payload case modified CouchDB source files'
curl --fail --silent --max-time 5 --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
[ "$(scratch_count)" = "$baseline" ] || fail 'corrupt-payload CouchDB validation leaked scratch'
printf 'PASS CouchDB exact valid marker with corrupted native fixture payload rejects on HTTP readability; input/source unchanged; sandbox clean\n'
expect_failure "$TEST_COUCH_REJECT_VALIDATOR" "$root/couch-artifact"
[ "$(find "$root/couch-artifact" -type f -exec sha256sum '{}' + | sort)" = "$artifact_before" ] || fail 'CouchDB input modified on callback failure'
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB callback failure leaked scratch'
printf 'PASS CouchDB owner callback failure rejects and cleans up\n'
mkdir -m 700 "$root/couch-failed-capture"
ln -s "$root/missing" "$source_data/unsupported-link"
expect_failure "$TEST_COUCH_CAPTURE" "$root/couch-failed-capture"
[ -z "$(find "$root/couch-failed-capture" -mindepth 1 -print -quit)" ] || fail 'failed CouchDB capture left partial output'
rm "$source_data/unsupported-link"
curl --fail --silent --max-time 5 --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB capture rejects nonregular source and preserves running service\n'
mkdir -m 700 "$root/couch-copy-failure"
expect_failure "$TEST_COUCH_FAILURE_CAPTURE" "$root/couch-copy-failure"
[ -z "$(find "$root/couch-copy-failure" -mindepth 1 -print -quit)" ] || fail 'copy failure left partial CouchDB output'
printf 'PASS CouchDB partial copy failure clears output\n'
mkdir -m 700 "$root/couch-term-capture"
setsid "$TEST_COUCH_WAIT_CAPTURE" "$root/couch-term-capture" > "$root/capture-term.log" 2>&1 & capture_pid=$!
wait_for_log "$capture_pid" CAPTURE_COPY_READY "$root/capture-term.log" 'CouchDB capture copy'
kill -TERM -- "-$capture_pid"
bounded_wait "$capture_pid" 'CouchDB terminated capture' "$root/capture-term.log" || fail 'CouchDB capture termination timed out'
capture_pid=
[ "$child_status" != 0 ] || fail 'terminated CouchDB capture returned success'
[ -z "$(find "$root/couch-term-capture" -mindepth 1 -print -quit)" ] || fail 'terminated CouchDB capture left partial output'
curl --fail --silent --max-time 5 --user "$couch_auth" "$couch_url/fixture/meaningful" | jq -e '.value == "preserved"' >/dev/null
printf 'PASS CouchDB owned group TERM during copy clears output and preserves running source\n'
kill "$couch_pid"
bounded_wait "$couch_pid" 'source CouchDB' "$root/couch.log" || fail 'source CouchDB shutdown timed out'
couch_pid=
timeout 5s "$TEST_EPMD" -port 14369 -kill >/dev/null
mkdir -m 700 "$root/couch-stopped-capture"
"$TEST_COUCH_CAPTURE" "$root/couch-stopped-capture"
if curl --fail --silent --max-time 2 --user "$couch_auth" "$couch_url/_up" >/dev/null; then fail 'CouchDB capture started stopped source'; fi
printf 'PASS CouchDB capture preserves stopped source state\n'
setsid "$TEST_COUCH_WAIT_VALIDATOR" "$root/couch-artifact" > "$root/couch-term.log" 2>&1 & validator_pid=$!
wait_for_log "$validator_pid" VALIDATOR_CALLBACK_READY "$root/couch-term.log" 'CouchDB termination callback'
kill -TERM -- "-$validator_pid"
bounded_wait "$validator_pid" 'CouchDB terminated validator' "$root/couch-term.log" || fail 'CouchDB validator termination timed out'
validator_pid=
[ "$child_status" != 0 ] || fail 'terminated CouchDB validator returned success'
[ "$(scratch_count)" = "$baseline" ] || fail 'terminated CouchDB validator leaked scratch'
printf 'PASS CouchDB owned group TERM during owner callback removes scratch and disposable service\n'
printf '{"format":"unsupported"}\n' > "$root/couch-artifact/couchdb-recovery.json"
expect_failure "$TEST_COUCH_VALIDATOR" "$root/couch-artifact"
[ "$(scratch_count)" = "$baseline" ] || fail 'CouchDB format failure leaked scratch'
printf 'PASS CouchDB rejects unsupported format\n'
