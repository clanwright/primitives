# Sourced only by the immutable helper scripts.
set -euo pipefail
umask 077
export LANG=C LC_ALL=C
fail() { printf '%s\n' "$*" >&2; exit 1; }
absolute_directory() {
  [[ $# == 1 && $1 == /* && -d $1 && ! -L $1 ]] || fail 'expected an absolute real directory'
  [[ $(realpath -- "$1") == "${1%/}" ]] || fail 'directory path must be canonical'
}
regular_tree() {
  local unsupported
  unsupported=$(find "$1" ! -type d ! -type f -print -quit) || fail 'cannot traverse input'
  [[ -z $unsupported ]] || fail 'symlinks and special files are unsupported'
}
validator_input() {
  absolute_directory "$@"
  regular_tree "$1"
  [[ $(id -u) != 0 ]] || fail 'validation requires a dedicated unprivileged uid'
}
