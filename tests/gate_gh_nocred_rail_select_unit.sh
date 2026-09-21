#!/usr/bin/env bash
# DIVE-585 — `_gate_gh_nocred` selects its rail on AVAILABILITY, not PERMISSION.
#
# THE DEFECT THIS PINS (measured 2026-09-21, 5dive 0.47.0, upstream a9a7df4f).
# `task merge-landed` refused on a pull request that HAD landed. The box held the
# `_gh_do` sudo grant and no `/etc/5dive/connectors/github-bot.env`. The rail was
# chosen with `_gate_gh_bot_ok` — a PERMISSION question — so the bot rail was
# taken, `_gh_do` died on "machine-account credential missing", and the anonymous
# rail below it was never reached. `_merge_landed_probe` hands `_gate_gh` an EMPTY
# token and its own comment calls that read credential-free by construction; on
# such a box it was not. An unauthenticated GET of the same public repo returned
# `merged_at` the whole time. Three other readers on that seat agreed the PR was
# merged; only this path could not see it.
#
# WHY EVERY ARM HERE IS HOST-INDEPENDENT, which is the point of the file.
# `_gate_gh_bot_ok` short-circuits on `[[ -x /usr/local/bin/5dive ]]` before it
# consults anything a test can stub, so the sibling harnesses SKIP their bot-rail
# arms on a runner — and CI is exactly such a runner. A skipped arm grades
# nothing, and the mutant below would then be red at a desk and green in CI. So
# the two PREDICATES are stubbed directly (they are the inputs to the decision
# under test), the bot rail is observed through a `sudo` stub on PATH that never
# execs the installed CLI, and the anonymous rail through a `_gate_anon_gh` stub.
# Nothing here reads a box path. T4 is the one arm that calls the REAL predicates,
# and it is written to be true and non-vacuous in BOTH environments.
#
# MUTATION GRADE — RUN against this worktree, not predicted (2026-09-21). Three
# mutants, and the first two are the same kill set, which is the point: the
# one-line selection IS the whole behavioural delta of this fix.
#   * `git checkout <base> -- src/task/gate_evidence.sh` (the row's own mutant)
#                                              -> 4/3: T2, T6, T7.
#   * restore `if ! _gate_gh_bot_ok` at the selection, and nothing else
#                                              -> 4/3: T2, T6, T7. Identical, as
#     it must be — everything else in the diff is comment or the reason string.
#   * revert ONLY the reason line to "the gate bot is not usable here"
#                                              -> 6/1: T5 alone. A one-arm kill is
#     what a deliberately narrow regression guard looks like.
# T5 SURVIVES the first two mutants and that is correct rather than a gap: on the
# unfixed tree the bot rail runs and `_gh_do`'s own stderr carries the connector
# path, so the hint reaches the reader by a different road. T5 grades that the fix
# does not COST that hint; T2 and T7 grade the fix itself. An arm that reddens for
# both reasons would tell you less, not more.
# T1, T3 and T4 are controls and survive every mutant above by design — T3 is the
# over-correction guard (a connector-backed box must not be diverted) and would
# red on a mutant that drops the bot rail entirely.
#
# Run: bash tests/gate_gh_nocred_rail_select_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-gh-nocred-rail-select.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub sudo: stands in for the bot rail and dies EXACTLY as `_gh_do` does on a
#     box with the grant and no connector file. It never execs $_GATE_GH_DO, so
#     the arms do not care whether /usr/local/bin/5dive exists here.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'BOT %s\n' "$*" >>"${BOT_LOG:-/dev/null}"
for a in "$@"; do [[ "$a" == "-l" ]] && exit "${SUDO_LIST_RC:-0}"; done
printf 'error: machine-account credential missing (/etc/5dive/connectors/github-bot.env) — 5dive secret write GH_BOT_TOKEN --connector=github-bot\n' >&2
exit 1
STUB
chmod +x "$TMP/bin/sudo"
PATH="$TMP/bin:$PATH"; export PATH

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }
unset GH_TOKEN GITHUB_TOKEN

export BOT_LOG="$TMP/bot.log"
ANON_LOG="$TMP/anon.log"

# The two predicates under crossing, and the anonymous rail, as stubs.
set_rails() {  # <bot_ok_rc> <bot_present_rc> <anon_rc>
  eval "_gate_gh_bot_ok(){ return $1; }"
  eval "_gate_gh_bot_present(){ return $2; }"
  eval "_gate_anon_gh(){ printf 'ANON %s\n' \"\$*\" >>'$ANON_LOG'; [[ $3 -eq 0 ]] || return $3; printf '%s' \"\${ANON_OUT:-ANON-ANSWER}\"; }"
  : >"$BOT_LOG"; : >"$ANON_LOG"
}
took_bot()  { [[ -s "$BOT_LOG"  ]]; }
took_anon() { [[ -s "$ANON_LOG" ]]; }

# --- T1: POSITIVE CONTROL — no grant, no credential => the anonymous rail. -----
# Unchanged by this fix, and asserted rather than assumed: if T1 ever fails the
# crossing below grades nothing, because every other arm is a difference from it.
set_rails 1 1 0
out=$(_gate_gh_nocred 10 pr view https://github.com/o/r/pull/1 --json state); rc=$?
if [[ $rc -eq 0 && "$out" == "ANON-ANSWER" ]] && took_anon && ! took_bot; then
  ok_t "T1 no grant + no credential reaches the anonymous rail (unchanged)"
else
  bad_t "T1 anon rail not reached" "rc=$rc out=$out bot=$(cat "$BOT_LOG")"
fi

# --- T2: THE FIX — grant present, credential ABSENT => anonymous rail. ---------
# This is the box the row was filed from. Under `_gate_gh_bot_ok` the bot rail is
# taken here and dies; the whole defect is that the rail below was never tried.
set_rails 0 1 0
out=$(_gate_gh_nocred 10 pr view https://github.com/o/r/pull/1 --json state); rc=$?
if [[ $rc -eq 0 && "$out" == "ANON-ANSWER" ]] && took_anon && ! took_bot; then
  ok_t "T2 grant present + credential ABSENT falls through to the anonymous rail (the fix)"
else
  bad_t "T2 THE FIX: bot rail taken on a connector-less box" "rc=$rc out=$out bot=$(cat "$BOT_LOG")"
fi

# --- T3: NO OVER-CORRECTION — credential present => the bot rail still wins. ---
# The fix may only ADD a rail to a seat that had none. A connector-backed box must
# still route through `_gh_do`, and its failure must still be ITS failure — not a
# silent anonymous retry, which would read a public answer over a private repo the
# bot could see.
set_rails 0 0 0
out=$(_gate_gh_nocred 10 pr view https://github.com/o/r/pull/1 --json state); rc=$?
if [[ $rc -ne 0 ]] && took_bot && ! took_anon; then
  ok_t "T3 credential PRESENT still takes the bot rail, and its failure is not retried anonymously"
else
  bad_t "T3 bot rail bypassed or anonymously retried" "rc=$rc out=$out anon=$(cat "$ANON_LOG")"
fi

# --- T4: THE INVARIANT, on the REAL predicates. -------------------------------
# `_gate_gh_bot_present` opens with `_gate_gh_bot_ok || return 1`, so (ok=false,
# present=true) is unreachable and the fourth cell of the crossing cannot exist.
# Graded on the real functions with the grant DENIED: true on a runner (no
# installed CLI) and true on a provisioned box (sudo -l refused), so it is
# non-vacuous in both and skips in neither.
unset -f _gate_gh_bot_ok _gate_gh_bot_present
source "$SRC/task/gate_evidence.sh" 2>/dev/null || true
SUDO_LIST_RC=1 _gate_gh_bot_ok
ok_rc=$?
SUDO_LIST_RC=1 _gate_gh_bot_present
pres_rc=$?
if [[ $ok_rc -ne 0 && $pres_rc -ne 0 ]]; then
  ok_t "T4 availability implies permission: present is never true while ok is false"
else
  bad_t "T4 invariant broken" "ok_rc=$ok_rc pres_rc=$pres_rc"
fi

# --- T5: THE PROVISIONING HINT SURVIVES. --------------------------------------
# The old refusal said "the gate bot is not usable here" for BOTH bot states. Only
# one of them has a fix, and it is the one this row's box is in. When the anonymous
# rail also cannot answer, the message must still name the connector and the
# `secret write` that provisions it — otherwise the fix costs a reader the one
# actionable sentence the old text carried.
# Read through the SINK, not `$_GATE_GH_LAST_ERR`: the call below runs in a
# command substitution, and a variable set in that subshell is gone by the time
# the arm reads it — the very reason DIVE-3496 it.2 added the sink. Grading the
# variable here passed vacuously against an empty string.
set_rails 0 1 1
hint="$TMP/hint.err"; : >"$hint"
out=$(_GATE_GH_NOCRED_ERRF="$hint" _gate_gh_nocred 10 pr view https://github.com/o/r/pull/1 --json state); rc=$?
err="$(cat "$hint")"
if [[ $rc -ne 0 && "$err" == *"/etc/5dive/connectors/github-bot.env"* \
      && "$err" == *"secret write"* ]]; then
  ok_t "T5 with both rails dead the reason still names the connector and its secret write"
else
  bad_t "T5 provisioning hint lost" "rc=$rc out=$out err=$err"
fi

# --- T6: the diagnostic still crosses the subshell boundary (DIVE-3496 it.2). --
set_rails 0 1 1
sink="$TMP/sink.err"; : >"$sink"
_GATE_GH_NOCRED_ERRF="$sink" _gate_gh_nocred 10 pr view https://github.com/o/r/pull/1 >/dev/null 2>&1
if [[ -s "$sink" ]] && grep -q 'no gh rail' "$sink"; then
  ok_t "T6 the reason reaches the caller's sink file, not only the dead subshell variable"
else
  bad_t "T6 sink not published" "sink=$(cat "$sink")"
fi

# --- T7: THE SYMPTOM, at the verb's own reader. -------------------------------
# `_merge_landed_probe` is what `task merge-landed` consults, and it hands
# `_gate_gh` an EMPTY token. On the row's box it returned UNKNOWN for a landed PR.
# With the anonymous rail reachable it must read MERGED and carry the sha and the
# timestamp — the two fields the landing is recorded from.
if declare -F _merge_landed_probe >/dev/null 2>&1; then
  set_rails 0 1 0
  ANON_OUT='MERGED|a9a7df4f7be6f6d8b30aedb57506eec2185a4dc0|2026-09-21T10:54:11Z'
  export ANON_OUT
  rec=$(_merge_landed_probe https://github.com/o/r/pull/1062)
  unset ANON_OUT
  verdict="${rec%%$'\x1f'*}"
  if [[ "$verdict" == "MERGED" && "$rec" == *a9a7df4f7be6* && "$rec" == *2026-09-21T10:54:11Z* ]]; then
    ok_t "T7 merge-landed's probe reads MERGED through the anonymous rail on a connector-less box"
  else
    bad_t "T7 probe still cannot see a landed PR" "rec=$(printf '%q' "$rec")"
  fi
else
  bad_t "T7 _merge_landed_probe not loaded" "the symptom arm cannot be graded; check the source list above"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
[[ $PASS -gt 0 ]] || { printf 'FAIL - nothing was graded\n'; exit 1; }
exit 0
