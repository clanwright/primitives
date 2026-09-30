# Common helper functions are prepended by the native application writer.
validator_input "$@"
input=$1
dump=$input/$DUMP_RELATIVE_PATH
[[ -f $dump ]] || fail 'native PostgreSQL archive missing'
# Parse and reject unsupported source format/version before starting a database.
listing=$(pg_restore --list "$dump")
grep -Eq '^;[[:space:]]+Format: CUSTOM$' <<< "$listing" || fail 'unsupported PostgreSQL artifact format'
grep -Eq '^;[[:space:]]+Dumped from database version: 18\.' <<< "$listing" || fail 'unsupported PostgreSQL source major'
work=$(mktemp -d /tmp/primitives-postgresql.XXXXXXXX)
cleanup() {
  local status=$?
  trap '' HUP INT TERM
  if [[ -f $work/data/postmaster.pid ]]; then
    pg_ctl -D "$work/data" -m immediate -t 10 -w stop || status=1
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
export HOME=$work TMPDIR=$work PGHOST=$work PGPORT=5432 PGUSER=postgres
# initdb requires an OS identity even when /etc/passwd is intentionally absent.
printf 'validator:x:%s:%s::%s:/bin/false\n' "$(id -u)" "$(id -g)" "$work" > "$work/passwd"
printf 'validator:x:%s:\n' "$(id -g)" > "$work/group"
export LD_PRELOAD=$NSS_LIBRARY NSS_WRAPPER_PASSWD=$work/passwd NSS_WRAPPER_GROUP=$work/group
initdb -D "$work/data" --username=postgres --auth=trust --no-locale
pg_ctl -D "$work/data" -l "$work/postgres.log" -t 30 -w start -o "-F -k $work -c listen_addresses=''"
createdb -- "$PGDATABASE"
pg_restore --exit-on-error --single-transaction --no-owner --no-acl --dbname="$PGDATABASE" "$dump"
pg_amcheck --database="$PGDATABASE" --install-missing
"$CHECK_COMMAND"
