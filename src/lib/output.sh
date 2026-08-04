
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

# ---------------------------------------------------------------------------
# DIVE-2598 — THE SILENT NON-ZERO, AND WHY IT NEEDS A BACKSTOP AND NOT A FIX.
#
# `set -euo pipefail` (src/header.sh) is the right default for this script and it
# is not going away. Its cost is that ANY unguarded command failure terminates the
# process AT THAT LINE — before the handler reaches its own error path, so nothing
# is printed on stdout OR stderr and the caller gets a bare exit code with no
# reason attached to it. Twice in one release that was a `var=$(<probe>)` around a
# pipeline ending in `grep`, which exits 1 on no-match: DIVE-2566 killed `5dive
# push`, DIVE-2603 killed `5dive task done` for every caller whose result text
# named no branch. Both were found by `bash -x` on the installed binary, because
# the product itself said nothing at all.
#
# Each of those got its own `|| var=""`. That is the correct fix for the line, and
# it is not a fix for the CLASS: the next unguarded substitution is a normal thing
# to write and will present identically. What is missing is not another guard, it
# is a REPORTER — the property that this CLI never exits non-zero silently,
# whatever killed it.
#
# WHY A FILE AND NOT A VARIABLE. `fail()` runs inside command substitutions and
# `flock` subshells, whose variable writes are invisible to the parent that will
# actually exit and fire the EXIT trap. A marker file is written by the subshell
# and read by the trap. `$$` (deliberately, not `$BASHPID`) is the same value in
# every subshell of one invocation and different in a nested `5dive` child, so the
# path is exactly per-invocation. Cleared at load, so a stale file from a
# same-pid predecessor can only make us MISS a report — never invent one.
FIVE_REPORTED_FLAG="${TMPDIR:-/tmp}/.5dive-reported.$(id -u 2>/dev/null || echo x).$$"
rm -f "$FIVE_REPORTED_FLAG" 2>/dev/null || true

# mark_reported — "this exit already told the caller why". Called by fail(), which
# every reported error in this CLI funnels through (including policy_refuse). Any
# other deliberate non-zero exit that prints its own reason first — the
# `<verb>_usage; exit "$E_USAGE"` sites — calls it too.
mark_reported() { : > "$FIVE_REPORTED_FLAG" 2>/dev/null || true; }

# push_exit_handler <function-or-snippet> — register verb-local cleanup on the
# process EXIT chain.
#
# DIVE-2598 iteration 2. The backstop below is hung off the process EXIT trap,
# and bash traps REPLACE rather than stack: a verb that wrote the obvious thing —
# `trap '_watch_teardown' EXIT`, as `watch` and `supervisor --watch` both did —
# silently discarded `trap on_exit_audit EXIT` for the rest of the process,
# taking the never-exit-silently report AND the audit record with it. Measured on
# a built bundle: an induced death before that line printed a 461-byte diagnostic,
# the same death after it printed nothing.
#
# No census of exit SITES can catch this, because the line that disables the
# backstop contains no `exit`. So the fix is not another audit — it is removing
# the ability to write it: cmd_* register here, `on_exit_audit` stays the one and
# only EXIT trap in the bundle, and tests/silent_nonzero_exit_backstop_unit.sh
# pins that population.
#
# Handlers run LIFO and BEFORE the report, so an alt-screen teardown restores the
# terminal first and the diagnostic lands somewhere the caller can actually read.
# A handler that fails cannot change the exit code — it is already captured — and
# cannot stop the ones behind it.
declare -a _FIVE_EXIT_STACK=()
push_exit_handler() { _FIVE_EXIT_STACK+=("$1"); }

# Drained into a local copy and cleared BEFORE anything runs, so a handler that
# exits (or a second trip through the trap) cannot re-run the chain. The local
# declaration is also what keeps `${#…[@]}` resolvable inside this function —
# tests/local_array_unbound_default_unit.sh arm G resolves a read only against
# what its own function creates, and the array above is file-scope.
_five_run_exit_handlers() {
  local -a stack=("${_FIVE_EXIT_STACK[@]+"${_FIVE_EXIT_STACK[@]}"}")
  _FIVE_EXIT_STACK=()
  local i
  for (( i=${#stack[@]} - 1; i >= 0; i-- )); do
    eval "${stack[$i]}" || true
  done
}

# _report_silent_exit <code> — the backstop itself, fired from the EXIT trap.
_report_silent_exit() {
  local code="${1:-0}"
  if (( code == 0 )) || [[ -e "$FIVE_REPORTED_FLAG" ]]; then
    rm -f "$FIVE_REPORTED_FLAG" 2>/dev/null || true
    return 0
  fi
  # 130/143 are Ctrl-C and SIGTERM. A signal is not an unreported failure — the
  # person who sent it knows why it died, and `watch`/`supervisor` exit this way
  # by design.
  (( code == 130 || code == 143 )) && return 0
  local verb="${CURRENT_VERB:-}"
  local msg="5dive${verb:+ $verb} exited $code without reporting a reason. This is a bug in the CLI, not a refusal: a command failed under \`set -euo pipefail\` and ended the run before any error path could print. The command did NOT run to completion and its effect is UNKNOWN — re-read the object (\`5dive task show\`, \`5dive agent list\`) before retrying. To locate it: \`bash -x \$(command -v 5dive) ${verb:-<verb>} ...\` and read the last line before the exit. Please file it: \`5dive bug\`."
  if (( JSON_MODE )); then
    jq -cn --argjson c "$code" --arg m "$msg" \
      '{ok:false, error:{code:$c, class:"generic", message:$m}}' 2>/dev/null || true
  fi
  echo "error: $msg" >&2
}

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
  # DIVE-2598: this exit carries a reason, so the EXIT-trap backstop stays quiet
  # for it. Set AFTER the message is emitted, never before — the flag asserts "the
  # caller WAS told", and claiming it earlier would silence the backstop for a
  # death between the claim and the print.
  mark_reported
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
