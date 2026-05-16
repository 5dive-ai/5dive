
err_class_for() {
  case "$1" in
    0)  echo ok ;;
    2)  echo usage ;;
    3)  echo validation ;;
    4)  echo not_found ;;
    5)  echo conflict ;;
    6)  echo auth_required ;;
    7)  echo not_installed ;;
    8)  echo not_running ;;
    9)  echo pairing ;;
    10) echo permission ;;
    11) echo timeout ;;
    *)  echo generic ;;
  esac
}

# Set to 1 by the global --json preparse in main(). When 1:
#   - fail() emits {ok:false,error:{...}} on stdout instead of prose on stderr-only
#   - ok()   emits {ok:true,data:{...}} on stdout instead of "OK — ..." prose
#   - step() still emits progress to stderr (stdout stays clean)
JSON_MODE=0

# fail <code> <message>
# Always exits. In JSON mode, prints envelope on stdout AND a plain line on
# stderr (for logs). In text mode, prints prose on stderr only. Exit status
# always equals <code> so callers can branch on that alone.
fail() {
  local code="$1"; shift
  local msg="$*"
  if (( JSON_MODE )); then
    local class
    class=$(err_class_for "$code")
    jq -cn --argjson c "$code" --arg cl "$class" --arg m "$msg" \
      '{ok:false, error:{code:$c, class:$cl, message:$m}}'
  fi
  echo "error: $msg" >&2
  exit "$code"
}

die()  { fail "$E_GENERIC" "$@"; }
warn() { echo "warn: $*" >&2; }

# step <message>
# Progress chatter (what the old script printed as `echo "==> ..."`). Always
# goes to stderr so JSON stdout stays parseable. In text mode the user still
# sees it interleaved at the terminal.
step() { echo "==> $*" >&2; }

# ok <prose-line> [jq-expr] [jq-args...]
# Prose mode: `echo "OK — <prose-line>"` to stdout. Skipped if <prose-line> is
# empty.
# JSON mode:  emits `{ok:true, data: <jq-expr>}` on stdout. If <jq-expr> is
# omitted or empty, data defaults to `{}`. Any trailing args are forwarded to
# jq (typically --arg NAME VALUE) and can be referenced from the expr.
#
# Example:
#   ok "agent '$name' started" '{name:$n, action:"start"}' --arg n "$name"
ok() {
  local prose="${1:-}"; shift || true
  if (( JSON_MODE )); then
    local expr="${1:-}"
    [[ $# -gt 0 ]] && shift
    [[ -z "$expr" ]] && expr='{}'
    jq -cn "$@" "{ok:true, data: ($expr)}"
  else
    [[ -n "$prose" ]] && echo "OK — $prose"
  fi
  return 0
}

