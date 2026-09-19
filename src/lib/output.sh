
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
    # DIVE-3136: the hint PREFILLS --what with the error text this function is
    # already printing one line above. The two empty issues on the public repo
    # (#526, #553) were filed by an agent following this very hint on a path
    # with nobody at a prompt — so the fix is not "remind the caller to
    # describe it", it is to hand them a command that already carries the one
    # fact only this moment knows. #553 would then have read "accepts at most 1
    # arg(s), received 2" instead of an unfilled template comment.
    #
    # THE SHELL-METACHARACTER STRIP, and why it is wider than it first looks.
    # Quotes and newlines are stripped, not escaped: the hint is wrapped in
    # single quotes for copy-paste, so a quote inside it would end the string
    # early and hand the reader a command that runs as something else.
    #
    # $ ` and \ are stripped for a STRONGER reason, and stripping only the
    # quotes (as this line first did — caught by quinn on DIVE-3136 review) was
    # a live command injection, not a cosmetic gap. The --what payload sits
    # inside DOUBLE quotes in the printed command, and double quotes do not
    # suppress substitution: a message carrying $(...) or `...` executes the
    # moment the reader pastes the line. And $msg is caller-influenced —
    # `fail "unknown flag: $1"` puts an attacker-chosen token straight into it,
    # so any verb reaching the E_GENERIC arm was a delivery vector.
    #
    # The whole job of this line is to hand a human a command to run. That is
    # exactly why it must never hand them someone else's: a reader who trusts
    # the tool enough to paste its suggestion is the one person with no defence
    # left. The full error text is already printed verbatim one line above, so
    # nothing is lost by making the COPYABLE copy inert.
    local hint_what="${msg//$'\n'/ }"
    hint_what="${hint_what//\'/}"     # would close the single-quoted wrapper
    hint_what="${hint_what//\"/}"     # would close the --what= double quotes
    hint_what="${hint_what//\$/}"     # $(...) and $VAR expand inside "..."
    hint_what="${hint_what//\`/}"     # `...` expands inside "..." too
    hint_what="${hint_what//\\/}"     # a trailing \ escapes the closing quote
    hint_what="${hint_what:0:160}"
    echo "hint: run '5dive bug --verb=\"${CURRENT_VERB:-unknown}\" --exit=$code --what=\"${hint_what}\"' to preview a diagnostic bug report (allowlisted fields plus the text you pass; nothing is filed until you add --file)" >&2
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

# defer_write_note <message> / _five_flush_write_notes — a warn that is composed at
# the point where its evidence exists and printed at the point where its claim is
# true. Deferred notes that are never flushed are simply never said.
#
# THE DEFECT THIS EXISTS FOR. `_task_guard_result_over_closed` composes the merged
# result and says "this row already carried a result and it was PRESERVED, not
# replaced — N bytes kept above your text" AT THE MOMENT IT COMPOSES IT, which is
# before every close guard that can still refuse: the merge-pending guard
# (DIVE-4520) and the done-before-pr-merged refusal (DIVE-1830) both fire after
# it. So on a refused close the operator read a sentence asserting a write, then a
# refusal, and the row's result was byte-identical to before. Measured twice on
# 2026-09-18 at 7597 and 9237 bytes, both unchanged; two makers believed their
# post-delivery notes were on the row.
#
# WHY DEFER RATHER THAN MOVE THE LINE. The byte count is only in hand where the
# guard composes the text — once any caller has written the row, the previous
# bytes are gone. So the sentence stays where its evidence is and only the CLAIM
# is postponed, to the write sites, which are the callers that know it came true.
#
# WHY NOT FLUSH FROM `ok()`, which was iteration 1 here and reads like the obvious
# single point: `ok` is a two-letter name that the test suite itself redefines as
# a PASS counter — `tests/task_result_loss_open_row_unit.sh` shadows it and then
# calls `cmd_task_done` in-process, so the product's `ok` never runs and the
# announcement vanished from the very harness that exists to pin it. A flush point
# a caller can shadow is not a flush point. The EXIT trap has the same shape of
# problem from the other side: it never fires for an in-process `cmd_*` call at
# all. The write sites fire in both worlds.
_FIVE_WRITE_NOTES=()

defer_write_note() { _FIVE_WRITE_NOTES+=("$1"); }
_five_flush_write_notes() {
  (( ${#_FIVE_WRITE_NOTES[@]} )) || return 0
  local _n
  for _n in "${_FIVE_WRITE_NOTES[@]}"; do warn "$_n"; done
  _FIVE_WRITE_NOTES=()
}

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

# -------- subverb `--help`, shared across surfaces (DIVE-569) --------
#
# `5dive <surface> <verb> --help` must answer with THAT verb's usage. It shipped
# for `task` alone in PR-1000 (src/task/dispatch.sh); `agent` and `account` still
# ran straight into their per-verb flag loops, every one of which ends in
# `-*) fail "$E_USAGE" "unknown flag: $1"`, so the question read as a typo.
#
# The generalisation, rather than a third copy: the intercept is parameterised on
# (a) the function that prints the surface's usage and (b) the dispatch function
# whose `case` labels ENUMERATE the surface's verbs. Both are read back at run
# time, so an alias answers with the usage of the verb it actually runs and a new
# verb costs nothing. The answer text still comes from one of exactly two places
# that already exist:
#
#   1. the surface usage block the verb is documented in, and
#   2. the `usage: 5dive <surface> <verb> …` literal the verb (or its dispatch
#      arm) prints when you get its arguments wrong.
#
# A verb documented in NEITHER is refused BY NAME rather than answered with an
# invented line — the failure mode this whole shape exists to remove.

# _verb_help_wanted <args…> — do these args ASK for help? `--` ends the flags
# (several subverbs honour it), and only the two exact spellings count: the
# `--help` inside `--ask="… --help …"` is a VALUE, not a question.
_verb_help_wanted() {
  local a
  for a in "$@"; do
    case "$a" in
      --)        return 1 ;;
      -h|--help) return 0 ;;
    esac
  done
  return 1
}

# _verb_arm <dispatch_fn> <verb> — "<canonical spelling> <function>", read out of
# <dispatch_fn>'s OWN case statement at run time. Reading it back rather than
# restating it here is what makes an alias (`list`, `view`, `fire`, `rm`) answer
# with the usage of the verb it actually runs, with no second alias list to rot —
# the same reason the pre-push rail extracts the title regex from the workflow
# instead of carrying a copy (DIVE-4208). The second field is empty when the
# arm's first statement is not a plain function call (a nested `case` guard, an
# `AUDIT_CMD=` assignment); callers must treat it as a hint, not a promise.
_verb_arm() {
  declare -f "$1" 2>/dev/null | awk -v v="$2" '
    function tok(line,   f) { split(line, f, "[[:space:]]+"); return (f[1] == "" ? f[2] : f[1]) }
    /^[[:space:]]+[^ (].*\)$/ {
      lab = $0; sub(/\)[[:space:]]*$/, "", lab); gsub(/[[:space:]]/, "", lab)
      n = split(lab, alt, "|")
      for (i = 1; i <= n; i++) if (alt[i] == v) {
        # The handler is the first `cmd_*` token anywhere in the arm, not the
        # first token of its first line: main.sh audits before it dispatches, so
        # half these arms open with `AUDIT_CMD="agent export"` and the one that
        # dispatches is `with_registry_lock cmd_agent_add "$@"` two lines down.
        # Falling back to the first token keeps the surfaces whose arms are
        # one-liners (`task`) resolving exactly as they did.
        first = ""; fn = ""
        while ((getline body) > 0) {
          if (first == "") first = tok(body)
          for (j = 1; j <= NF; j++) {}
          if (match(body, /(^|[[:space:]])cmd_[A-Za-z0-9_]+([[:space:]]|$)/)) {
            fn = substr(body, RSTART, RLENGTH); gsub(/[[:space:]]/, "", fn); break
          }
          if (body ~ /^[[:space:]]*;;[[:space:]]*$/) break
        }
        print alt[1] " " (fn == "" ? first : fn); exit
      }
    }'
}

# _verb_surface_help <usage_fn> <path> <lead> <verb> — the block <usage_fn>
# documents <verb> in, reprinted with a `usage:` header.
#
# <lead> is what sits between the two-space indent and the verb on an entry line,
# because the two surfaces spell their entries differently and neither is going
# to be rewritten for this: `_task_usage` lists bare verbs (`  ls|list …`, so
# lead=""), while the top-level `usage()` lists whole command lines
# (`  5dive agent info <name>`, so lead="5dive agent "). <path> is what the
# header prints — "5dive task", "5dive agent", "5dive account".
_verb_surface_help() {
  local usage_fn="$1" path="$2" lead="$3" verb="$4"
  "$usage_fn" 2>/dev/null | awk -v v="$verb" -v lead="$lead" -v path="$path" '
    BEGIN { n = length(lead) }
    substr($0, 1, 2) == "  " && substr($0, 3, 1) != " " {
      blk = 0
      rest = substr($0, 3)
      if (n == 0 || substr(rest, 1, n) == lead) {
        tok = substr(rest, n + 1); sub(/[[:space:]].*$/, "", tok)
        m = split(tok, alt, "|")
        for (i = 1; i <= m; i++) if (alt[i] == v) blk = 1
      }
      if (!blk) next
      if (seen++) { print; next }
      printf "usage: %s %s\n", path, substr($0, 3 + n)
      next
    }
    /^   / { if (blk) print; next }
    { blk = 0 }'
}

# _verb_own_usage <fn> <path> — the `usage: <path> …` literal <fn> prints itself
# when its arguments are wrong. The token after <path> must be whitespace or the
# end of the literal, so asking about `account list` cannot be answered with the
# surface-wide `usage: 5dive account list|show|usage|add|…` guard.
_verb_own_usage() {
  local fn="$1" path="$2" body line
  body=$(declare -f "$fn" 2>/dev/null) || return 1
  # In the BUILT BUNDLE a lazy module is unparsed text until something calls into
  # it (DIVE-4087), so `declare -f` here yields the one-line autoload STUB, which
  # carries no usage text at all. Load the module the stub names, then read it
  # again. The split tree has no stubs and never takes this branch — which is why
  # the harnesses grade this path through a BUILT BUNDLE and not through src/.
  if [[ "$body" == *_lazy_autoload* ]] && declare -F _load_module >/dev/null 2>&1; then
    local mod="${body#*_lazy_autoload }"; mod="${mod%% *}"
    _load_module "$mod" >/dev/null 2>&1 || return 1
    body=$(declare -f "$fn" 2>/dev/null) || return 1
  fi
  line=$(printf '%s\n' "$body" | awk -v p="usage: $path" '
    {
      s = $0
      while ((i = index(s, p)) > 0) {
        t = substr(s, i + length(p)); c = substr(t, 1, 1)
        if (c == "" || c == " " || c == "\t") { sub(/["\047].*$/, "", t); print p t; exit }
        s = substr(s, i + length(p))
      }
    }') || true
  [[ -n "$line" ]] || return 1
  # A few of these literals are printf formats carrying a `\n` and a paragraph of
  # prose after it; take the usage line and leave the escape unrendered.
  printf '%s\n' "${line%%\\n*}"
}

# _verb_subverb_help <path> <usage_fn> <dispatch_fn> <lead> <verb> — print that
# verb's usage.
#   0  printed it
#   1  not a verb at all (the dispatch case below has better words for that)
#   2  a verb this tree documents NOWHERE — say so rather than invent a line
_verb_subverb_help() {
  local path="$1" usage_fn="$2" dispatch_fn="$3" lead="$4" verb="$5"
  local arm primary fn out=""
  arm=$(_verb_arm "$dispatch_fn" "$verb") || true
  [[ -n "$arm" ]] || return 1
  primary="${arm%% *}"; fn="${arm#* }"
  out=$(_verb_surface_help "$usage_fn" "$path" "$lead" "$primary") || true
  # Then the handler's own literal, then the dispatch arm's — `agent rotation`
  # and friends guard their nested case in main.sh, not in a cmd_ function.
  [[ -n "$out" || -z "$fn" ]] || out=$(_verb_own_usage "$fn" "$path $primary") || true
  [[ -n "$out" ]] || out=$(_verb_own_usage "$dispatch_fn" "$path $primary") || true
  [[ -n "$out" ]] || return 2
  printf '%s\n' "$out"
}

# _verb_help_intercept <path> <usage_fn> <dispatch_fn> <lead> <verb> <args…> — 0
# when the args asked for help and it has been answered. Kept OUT of the
# dispatch function's body on purpose: _verb_arm reads that body back as text,
# and a second `case` inside it would look like arms.
_verb_help_intercept() {
  local path="$1" usage_fn="$2" dispatch_fn="$3" lead="$4" verb="$5"; shift 5
  _verb_help_wanted "$@" || return 1
  # `5dive <surface> --help --help` asks about the SURFACE, and every dispatch
  # case already carries an arm for that. Refusing it here as "a verb documented
  # nowhere" would be the invented answer this whole path exists to avoid.
  _verb_help_wanted "$verb" && return 1
  local rc=0
  _verb_subverb_help "$path" "$usage_fn" "$dispatch_fn" "$lead" "$verb" || rc=$?
  case $rc in
    0) return 0 ;;
    2) fail "$E_USAGE" "$path $verb: no usage text — the verb is documented neither in '$path --help' nor in its own arguments check" ;;
  esac
  return 1
}
