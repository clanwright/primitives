# Common helper functions are prepended by the native application writer.
absolute_directory "$@"
output=$1
[[ $(stat -c %a "$output") == 700 && $(stat -c %u "$output") == "$(id -u)" ]] || fail 'output must be private and owned by the capture account'
[[ -z $(find "$output" -mindepth 1 -print -quit) ]] || fail 'output must already be empty'
absolute_directory "$SOURCE_DIRECTORY"
regular_tree "$SOURCE_DIRECTORY"
[[ $output != "$SOURCE_DIRECTORY" && $output != "$SOURCE_DIRECTORY/"* ]] || fail 'output must be outside the source tree'
complete=false
cleanup() {
  local status=$?
  trap '' HUP INT TERM
  if [[ $complete != true ]]; then
    find "$output" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
mkdir "$output/data"
# Apache's hot-copy order: derived view indexes first, append-only DB files last.
# Copy only database artifacts; never include cookies, INI configuration or logs.
cd "$SOURCE_DIRECTORY" || exit 1
for pattern in '*.view' '*.couch'; do
  find . -type f -name "$pattern" -print0 > "$output/.capture-files"
  while IFS= read -r -d '' file; do
    [[ -f $file && ! -L $file ]] || fail 'source changed type during capture'
    mkdir -p -- "$output/data/$(dirname "$file")"
    cp --no-dereference --reflink=auto -- "$file" "$output/data/$file"
  done < "$output/.capture-files"
done
rm -- "$output/.capture-files"
regular_tree "$output"
jq -n --arg node "$NODE_NAME" '{format:"primitives-couchdb-files-v1",version:"3.5.2",nodeName:$node}' > "$output/couchdb-recovery.json"
complete=true
