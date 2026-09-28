# shellcheck source=lib/recovery/common.sh
source "$RECOVERY_COMMON"
validator_input "$@"
input=$1
jq -e --arg node "$NODE_NAME" '. == {format:"primitives-couchdb-files-v1",version:"3.5.2",nodeName:$node}' "$input/couchdb-recovery.json" >/dev/null || fail 'unsupported CouchDB artifact format/version/node identity'
[[ -d $input/data ]] || fail 'CouchDB data missing'
# Source files are never executed or treated as server configuration.
[[ -z $(find "$input/data" -type f ! -name '*.couch' ! -name '*.view' -print -quit) ]] || fail 'unexpected CouchDB artifact file'
work=$(mktemp -d /tmp/primitives-couchdb.XXXXXXXX)
server_pid=
epmd_started=false
cleanup() {
  local status=$?
  trap '' HUP INT TERM
  if [[ -n $server_pid ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ $epmd_started == true ]]; then
    timeout 5s epmd -port 14369 -kill || status=1
  fi
  if [[ $status != 0 && -f $work/couchdb.log ]]; then cat "$work/couchdb.log" >&2; fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
export HOME=$work TMPDIR=$work
cp -R --no-preserve=mode,ownership -- "$input/data" "$work/data"
chmod -R u+rwX -- "$work/data"
cat > "$work/vm.args" <<ARGS
-name $NODE_NAME
-setcookie disposable-validation-only
-start_epmd false
-noinput
+S 2:2
ARGS
printf '[{public_key, [{cacerts_path, "%s"}]}].\n' "$CA_CERTIFICATES" > "$work/sys.config"
cat > "$work/local.ini" <<INI
[couchdb]
database_dir = $work/data
view_index_dir = $work/data
single_node = true
uuid = 00000000000000000000000000000001
[chttpd]
bind_address = 127.0.0.1
port = 15984
[httpd]
bind_address = 127.0.0.1
port = 15986
[replicator]
ssl_trusted_certificates_file = $CA_CERTIFICATES
[admins]
validator = disposable-validation-only
[log]
writer = stderr
level = error
INI
export COUCHDB_ARGS_FILE=$work/vm.args COUCHDB_SYSCONFIG_FILE=$work/sys.config
export ERL_FLAGS="-couch_ini $COUCHDB_DEFAULT_INI $work/local.ini"
export ERL_EPMD_PORT=14369 ERL_EPMD_ADDRESS=127.0.0.1
export COUCHDB_URL=http://127.0.0.1:15984 COUCHDB_USER=validator COUCHDB_PASSWORD=disposable-validation-only
epmd -daemon -port 14369
epmd_started=true
# GNU timeout forwards termination and bounds a failed native shutdown. Outer
# PID/network containment and its overall budget remain the runner's job.
timeout --kill-after=5s 30m couchdb > "$work/couchdb.log" 2>&1 &
server_pid=$!
http() { curl --fail --silent --show-error --max-time "${2:-5}" --user "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL$1"; }
ready=false
for _ in $(seq 1 100); do
  kill -0 "$server_pid" 2>/dev/null || fail 'disposable CouchDB exited before readiness'
  if http /_up 2>/dev/null | jq -e '.status == "ok"' >/dev/null; then ready=true; break; fi
  sleep .1
done
[[ $ready == true ]] || fail 'disposable CouchDB readiness timed out'
http /_all_dbs > "$work/databases.json"
jq -e 'type == "array" and all(.[]; type == "string")' "$work/databases.json" >/dev/null
while IFS= read -r database; do
  # Parse bounded pages only after curl has finished, so jq cannot backpressure
  # a large response into the HTTP timeout. Readiness retains its 5s budget.
  cursor=null
  total=null
  seen=0
  query="/$database/_all_docs?include_docs=true&limit=32"
  while true; do
    http "$query" 30 > "$work/documents.json"
    jq -e --argjson cursor "$cursor" --argjson total "$total" --argjson seen "$seen" '
      type == "object" and (has("error") | not) and
      (.total_rows | type == "number" and . >= 0 and . == floor) and
      ($total == null or .total_rows == $total) and .offset == $seen and
      (.rows | type == "array" and length <= 32 and
        all(.[];
          type == "object" and (has("error") | not) and
          (.id | type == "string") and .key == .id and
          (.doc | type == "object") and .doc._id == .id and
          .id != $cursor) and
        ([.[].id] | length == (unique | length)))
    ' "$work/documents.json" >/dev/null || fail 'invalid CouchDB document page or pagination progress'
    total=$(jq -r '.total_rows' "$work/documents.json")
    count=$(jq -r '.rows | length' "$work/documents.json")
    seen=$((seen + count))
    (( seen <= total )) || fail 'CouchDB document count exceeded total'
    if (( count < 32 )); then
      (( seen == total )) || fail 'incomplete CouchDB document scan'
      break
    fi
    cursor=$(jq -c '.rows[-1].id' "$work/documents.json")
    startkey=$(jq -r '.rows[-1].id | tojson | @uri' "$work/documents.json")
    query="/$database/_all_docs?include_docs=true&limit=32&startkey=$startkey&skip=1"
  done
done < <(jq -r '.[] | @uri' "$work/databases.json")
"$CHECK_COMMAND"
