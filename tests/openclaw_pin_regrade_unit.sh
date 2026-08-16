#!/usr/bin/env bash
# DIVE-3457: `doctor --category=models` re-grades every OPENCLAW_PROVIDER_MODEL
# row AND every already-written seat pin against the INSTALLED openclaw catalog.
#
# WHY THIS HARNESS MUTATES INSTEAD OF LOOKING AT THE LIVE RUN. On the version the
# rows were graded against, every pin resolves, so the live run is all-green and
# proves only that the probe RETURNED (task body, dev2). Every arm below is a
# DEFECT the check must SEE — the green arm is the control, not the evidence.
#
# Offline: openclaw_catalog_ids is stubbed at its ONE seam, so no openclaw
# process, no network, no sudo and no seat config is touched by the run. The
# module under test still calls the real doctor_add/jq (see
# tests/lib/grading_tree.sh and the least-injected-seam rule).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC=src
for f in header.sh lib/error_codes.sh lib/output.sh cmd_doctor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || { echo "source FAIL: $f"; exit 7; }
done

FAILED=0
bad() { echo "FAIL: $1"; echo "      $2"; FAILED=1; }
ok()  { echo "ok: $1"; }

# TYPE_BIN/node gate: the check refuses early when the runtime is absent. Point
# both at things that exist so the arms below reach the graded code, and stub
# the probe itself.
#
# THE NODE PATH IS THE THIRD SEAM, and leaving it live is what failed CI on
# iteration 1. openclaw_catalog_ids and openclaw_written_pins were stubbed; the
# runtime guard inside doctor_check_openclaw_model_pins was not, and it tests a
# path that exists only on a box with openclaw installed. On a clean runner the
# check emitted ONE warn and returned before grading anything, so every arm saw
# an empty tree — and the two arms that assert "no row verdict was emitted"
# stayed GREEN on that emptiness. ARM 0 below is the positive control that makes
# those two arms mean something.
TYPE_BIN[openclaw]="/bin/sh"
OPENCLAW_PIN_NODE_BIN="/bin/sh"
CATALOG=""            # newline-separated ids the stub returns for ANY provider
CATALOG_openai=""     # per-provider override for the control provider
openclaw_catalog_ids() {
  local p="$1"
  # The control provider ALWAYS reads its own fixture — never falling back to
  # $CATALOG. An earlier cut fell back when CATALOG_openai was empty, which is
  # precisely the state ARM 4 sets, so ARM 4 silently graded a NON-vacuous
  # control and passed on the green path. The stub, not the check, was wrong;
  # a fixture that cannot express the defect is not a control arm.
  if [[ "$p" == "$OPENCLAW_PIN_CONTROL_PROVIDER" ]]; then
    printf '%s\n' "$CATALOG_openai" | grep . || true
    return 0
  fi
  printf '%s\n' "$CATALOG" | grep . || true
}
# The written-pin sweep reads real files; stub the enumerator so the harness
# never depends on this box having a seat.
WRITTEN=""
openclaw_written_pins() { [[ -n "$WRITTEN" ]] && printf '%s\n' "$WRITTEN"; return 0; }
# --version is shelled through sudo; neutralise it (the version string is only
# ever interpolated into messages).
sudo() { printf 'OpenClaw test-build\n'; }

run_arm() {
  DOCTOR_CHECKS='[]'
  doctor_check_openclaw_model_pins >/dev/null 2>&1
}
sev_of() { jq -r --arg n "$1" '.[] | select(.name==$n) | .severity' <<<"$DOCTOR_CHECKS"; }
msg_of() { jq -r --arg n "$1" '.[] | select(.name==$n) | .message' <<<"$DOCTOR_CHECKS"; }
count_sev() { jq -r --arg s "$1" '[.[] | select(.severity==$s)] | length' <<<"$DOCTOR_CHECKS"; }

# A single-row table keeps each arm's expectation readable. The real table is
# graded live by `doctor --category=models`, not here.
unset OPENCLAW_PROVIDER_MODEL OPENCLAW_PROVIDER_ID
declare -A OPENCLAW_PROVIDER_MODEL=( [deepseek]="deepseek/deepseek-chat" )
declare -A OPENCLAW_PROVIDER_ID=( [deepseek]="deepseek" )

# ── ARM 0 (POSITIVE CONTROL): the graded path is actually REACHED ───────────
# Load-bearing for arms 4 and 5. Those assert a verdict is ABSENT, and an
# absence assertion passes on empty output — so unless something proves the run
# got PAST the runtime guard, "suppressed by a failing control" and "the check
# returned at line 1 because this box has no openclaw" are the same observation.
# This arm is that proof, and its mutation (ARM 8) shows it can fail.
CATALOG_openai=$'openai/gpt-5.6\nopenai/gpt-5.3'
CATALOG=$'deepseek/deepseek-chat'
WRITTEN=""
run_arm
[[ -z "$(sev_of openclaw-runtime)" ]] \
  && ok "REACH control: the runtime guard did not fire (openclaw seam is stubbed)" \
  || bad "runtime guard fired" "openclaw-runtime='$(sev_of openclaw-runtime)' — every arm below would grade an empty tree"
[[ -n "$(sev_of openclaw-row-deepseek)" ]] \
  && ok "REACH control: a row verdict was emitted, so the sweep ran" \
  || bad "sweep did not run" "no openclaw-row-deepseek verdict; the arms asserting ABSENCE are vacuous"

# ── ARM 1 (control arm): pin present in the catalog → ok, no error ──────────
CATALOG_openai=$'openai/gpt-5.6\nopenai/gpt-5.3'
CATALOG=$'deepseek/deepseek-chat\ndeepseek/deepseek-reasoner'
WRITTEN=""
run_arm
[[ "$(sev_of openclaw-row-deepseek)" == "ok" ]] \
  && ok "green arm: a resolving pin reports ok" \
  || bad "green arm" "got '$(sev_of openclaw-row-deepseek)'"
[[ "$(count_sev error)" == "0" ]] \
  && ok "green arm: no error raised" \
  || bad "green arm errors" "$(count_sev error) error(s)"

# ── ARM 2 (MUTATION): the id disappears from the catalog under the row ──────
# This is the whole ticket: the row is unchanged and byte-identical, the
# INSTALLED catalog moved. Must be error, and must name the re-grade command.
CATALOG=$'deepseek/deepseek-v5-chat\ndeepseek/deepseek-reasoner'
run_arm
[[ "$(sev_of openclaw-row-deepseek)" == "error" ]] \
  && ok "MUTATION stale row: reports error" \
  || bad "MUTATION stale row" "expected error, got '$(sev_of openclaw-row-deepseek)'"
grep -q 'models list --provider deepseek --plain' <<<"$(msg_of openclaw-row-deepseek)" \
  && ok "MUTATION stale row: message names the re-grade command" \
  || bad "stale message" "no re-grade command in: $(msg_of openclaw-row-deepseek)"
[[ "$(sev_of openclaw-pin-summary)" == "error" ]] \
  && ok "MUTATION stale row: summary escalates to error" \
  || bad "summary severity" "got '$(sev_of openclaw-pin-summary)'"

# ── ARM 3 (MUTATION): provider enumerates NOTHING → warn NO-ORACLE, not error ─
# An unenumerated namespace is not a proof of unroutability (DIVE-3130/3184).
# Grading this as `error` would tell an operator to delete a good row.
CATALOG=""
run_arm
[[ "$(sev_of openclaw-row-deepseek)" == "warn" ]] \
  && ok "MUTATION empty catalog: NO-ORACLE is warn, not error" \
  || bad "no-oracle severity" "expected warn, got '$(sev_of openclaw-row-deepseek)'"

# ── ARM 4 (MUTATION): non-vacuity control fails → NO verdict at all ─────────
# openclaw answering nothing for everything would otherwise mark every pin
# stale — the false ALARM. The control must SUPPRESS the sweep, not colour it.
CATALOG_openai=""
CATALOG=$'deepseek/deepseek-chat'
run_arm
[[ "$(sev_of openclaw-pin-control)" == "error" ]] \
  && ok "MUTATION vacuous control: control reports error" \
  || bad "vacuous control" "got '$(sev_of openclaw-pin-control)'"
[[ -z "$(sev_of openclaw-row-deepseek)" && -z "$(sev_of openclaw-runtime)" ]] \
  && ok "MUTATION vacuous control: no row verdict was emitted (and the run REACHED the sweep)" \
  || bad "vacuous control leaked a verdict" "row='$(sev_of openclaw-row-deepseek)' runtime='$(sev_of openclaw-runtime)'"

# ── ARM 5 (MUTATION): discrimination control fails → NO verdict at all ──────
# Sentinel present means the matcher is looser than an exact id compare, so
# every green below it is worthless and must not be printed.
CATALOG_openai=$'openai/gpt-5.6\nopenai/gpt-4o'
run_arm
[[ "$(sev_of openclaw-pin-control)" == "error" ]] \
  && ok "MUTATION loose matcher: control reports error" \
  || bad "loose-matcher control" "got '$(sev_of openclaw-pin-control)'"
[[ -z "$(sev_of openclaw-row-deepseek)" && -z "$(sev_of openclaw-runtime)" ]] \
  && ok "MUTATION loose matcher: no row verdict was emitted (and the run REACHED the sweep)" \
  || bad "loose matcher leaked a verdict" "row='$(sev_of openclaw-row-deepseek)' runtime='$(sev_of openclaw-runtime)'"

# ── ARM 6 (MUTATION): an ALREADY-WRITTEN seat pin has gone stale ────────────
# The row table can be perfect and a seat still dead: _apply_byo_openclaw
# validates at WRITE time and the write already happened.
CATALOG_openai=$'openai/gpt-5.6'
CATALOG=$'deepseek/deepseek-chat'
WRITTEN=$'/home/agent-x/.openclaw/openclaw.json\tdeepseek/deepseek-v4-pro'
run_arm
[[ "$(sev_of openclaw-written-1)" == "error" ]] \
  && ok "MUTATION stale written pin: reports error" \
  || bad "stale written pin" "expected error, got '$(sev_of openclaw-written-1)'"
grep -q '/home/agent-x/.openclaw/openclaw.json' <<<"$(msg_of openclaw-written-1)" \
  && ok "MUTATION stale written pin: message names the file to repair" \
  || bad "written-pin message" "$(msg_of openclaw-written-1)"

# ── ARM 7 (static): `models` must NOT run in the bare-doctor sweep ──────────
# 35.8s of openclaw subprocesses behind a dashboard poll. If someone adds
# `-z "$filter"` to the run_models line, this arm goes red.
if grep -qE '^\s*\[\[ "\$filter" == "models" \]\] && run_models=1' "$SRC/cmd_doctor.sh" \
   && ! grep -qE 'run_models=1' <<<"$(grep -E '\-z "\$filter"' "$SRC/cmd_doctor.sh")"; then
  ok "static: models is opt-in — bare \`doctor\` does not run it"
else
  bad "models is no longer opt-in" "a bare \`doctor --json\` poll now pays ~36s of openclaw subprocesses"
fi
# And it must still be reachable by filter (the DIVE-2327 shape: dispatched but
# rejected by the allow-list is a category nobody can run).
grep -q 'policy|plugins|caps|models) ;;' "$SRC/cmd_doctor.sh" \
  && ok "static: --category=models passes the allow-list" \
  || bad "allow-list" "--category=models is dispatched but not allowed"

# ── ARM 8 (MUTATION of ARM 0): the runtime is absent → NOT-MEASURED, no verdict ─
# Point the node seam at nothing and the check must say so LOUDLY and grade
# nothing. This reproduces iteration 1's CI signature on purpose: it is the only
# arm that can distinguish "the controls suppressed the sweep" from "this box
# never had openclaw", and without it ARM 0 is an unfalsifiable green.
OPENCLAW_PIN_NODE_BIN="/nonexistent/node"
CATALOG_openai=$'openai/gpt-5.6'
CATALOG=$'deepseek/deepseek-chat'
WRITTEN=""
run_arm
[[ "$(sev_of openclaw-runtime)" == "warn" ]] \
  && ok "MUTATION absent runtime: reports NOT-MEASURED as warn" \
  || bad "absent runtime" "expected warn, got '$(sev_of openclaw-runtime)'"
[[ -z "$(sev_of openclaw-row-deepseek)" && -z "$(sev_of openclaw-pin-control)" && -z "$(sev_of openclaw-pin-summary)" ]] \
  && ok "MUTATION absent runtime: nothing was graded (no row, no control, no summary)" \
  || bad "absent runtime graded anyway" "row='$(sev_of openclaw-row-deepseek)' ctl='$(sev_of openclaw-pin-control)' sum='$(sev_of openclaw-pin-summary)'"
grep -q 'NOT-MEASURED' <<<"$(msg_of openclaw-runtime)" \
  && ok "MUTATION absent runtime: message says NOT-MEASURED, not a clean bill of health" \
  || bad "absent-runtime message" "$(msg_of openclaw-runtime)"
OPENCLAW_PIN_NODE_BIN="/bin/sh"

echo
(( FAILED )) && echo "RESULT: FAIL" || echo "RESULT: PASS"
# Verdict LAST, and in a shape tests/meta/harness-verdict-probe.sh can read.
# The earlier `(( FAILED )) && { …; exit 1; }` / `exit 0` pair was correctly
# wired and still UNPROBEABLE — the probe identifies the verdict VARIABLE from
# the last executable line, and `exit 0` names none, so it could not inject its
# mutation and refused to count this harness clean. That refusal is the point of
# DIVE-2013: an unprobeable harness and a harness whose exit status is not wired
# to its assertions are indistinguishable from outside.
exit $(( FAILED > 0 ))
