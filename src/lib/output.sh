
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

# The top-level verb main() is currently dispatching, set once near the top of
# main() (DIVE-2323). Read by fail()'s E_GENERIC hint so it can point at
# `5dive bug` with the actual failing verb filled in, without fail() itself
# needing to know how it was reached.
CURRENT_VERB=""

# fail <code> <message>
# Always exits. In JSON mode, prints envelope on stdout AND a plain line on
# stderr (for logs). In text mode, prints prose on stderr only. Exit status
# always equals <code> so callers can branch on that alone.
fail() {
  local code="$1"; shift
  local msg="$*"
  # DIVE-2121: an invalid flag is often one shell token containing a pasted
  # paragraph (for example --json="<text>"). Echoing that token verbatim can
  # make the paragraph's closing sentence look like an acknowledgement. Keep
  # enough of the token to identify the typo, but never replay the whole input.
  local unknown_flag_marker='unknown flag: '
  if [[ "$msg" == *"$unknown_flag_marker"* ]]; then
    local unknown_flag_lead="${msg%%"$unknown_flag_marker"*}"
    local unknown_flag_token="${msg#*"$unknown_flag_marker"}"
    if (( ${#unknown_flag_token} > 40 )); then
      msg="${unknown_flag_lead}${unknown_flag_marker}${unknown_flag_token:0:40}..."
    fi
  elif [[ "$msg" == *"unknown flag"* ]]; then
    # A few older parsers say "unknown flag '<token>'" or "unknown flag for
    # <verb>: <token>". They share the same payload risk even though they do
    # not use the prevailing colon form above.
    local unknown_flag_phrase='unknown flag'
    local unknown_flag_lead="${msg%%"$unknown_flag_phrase"*}"
    local unknown_flag_tail="${msg#*"$unknown_flag_phrase"}"
    if (( ${#unknown_flag_tail} > 40 )); then
      msg="${unknown_flag_lead}${unknown_flag_phrase}${unknown_flag_tail:0:40}..."
    fi
  fi
  if (( JSON_MODE )); then
    local class
    class=$(err_class_for "$code")
    jq -cn --argjson c "$code" --arg cl "$class" --arg m "$msg" \
      '{ok:false, error:{code:$c, class:$cl, message:$m}}'
  fi
  echo "error: $msg" >&2
  # DIVE-2323: E_GENERIC is the catch-all/internal bucket (never a usage or
  # validation mistake — see src/lib/error_codes.sh), so this is the one place
  # in the CLI that reliably sees "something we didn't expect broke". Point at
  # the bug-report verb there, with the actual verb/code filled in, rather than
  # leaving discovery to whoever happens to read .github/ISSUE_TEMPLATE.
  if [[ "$code" == "${E_GENERIC:-1}" ]]; then
    echo "hint: run '5dive bug --verb=\"${CURRENT_VERB:-unknown}\" --exit=$code' to preview a diagnostic bug report (allowlisted fields only; nothing is filed until you add --file)" >&2
  fi
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
