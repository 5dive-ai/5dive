#!/usr/bin/env bash
# DIVE-1342: usage text lives in unquoted heredocs because it expands runtime
# values. Literal backticks inside those heredocs must be escaped, or Bash
# executes the examples as command substitutions while rendering --help.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/help-output-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

check_help() {
  local name="$1"
  shift
  if ! "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    echo "FAIL: $name help exited non-zero" >&2
    sed -n '1,20p' "$TMP/$name.err" >&2
    return 1
  fi
  if [[ -s "$TMP/$name.err" ]]; then
    echo "FAIL: $name help wrote to stderr:" >&2
    sed -n '1,20p' "$TMP/$name.err" >&2
    return 1
  fi
}

check_help root ./5dive --help
check_help task ./5dive task --help

grep -Fq 'see `5dive hire --help`' "$TMP/root.out" \
  || { echo "FAIL: top-level help lost the literal hire example" >&2; exit 1; }
grep -Fq 'A bare `doctor`' "$TMP/root.out" \
  || { echo "FAIL: top-level help lost the literal doctor example" >&2; exit 1; }
grep -Fq 'default cmd for `task verify`' "$TMP/task.out" \
  || { echo "FAIL: task help lost the literal task-verify example" >&2; exit 1; }
grep -Fq 'see `5dive usage`' "$TMP/task.out" \
  || { echo "FAIL: task help lost the literal usage example" >&2; exit 1; }

# Keep the whole usage-heredoc class closed: every raw backtick in an unquoted
# USAGE heredoc is executable shell syntax, even if its command happens to exist.
if ! awk '
  FNR == 1 { in_usage = 0 }
  /cat <<USAGE/ { in_usage = 1; next }
  in_usage && /^USAGE$/ { in_usage = 0; next }
  in_usage && /(^|[^\\])`/ { print FILENAME ":" FNR ":" $0; bad = 1 }
  END { exit bad }
' src/*.sh >"$TMP/heredoc.err"; then
  echo "FAIL: unescaped backtick in an unquoted USAGE heredoc:" >&2
  cat "$TMP/heredoc.err" >&2
  exit 1
fi

echo "help output unit: 2 help paths clean; all usage heredocs inert"
