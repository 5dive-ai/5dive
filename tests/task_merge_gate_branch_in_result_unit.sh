#!/usr/bin/env bash
# DIVE-2577 isolated unit harness — the auto-detect merge-gate (DIVE-1835) can
# only refuse a close when it finds an OPEN PR or a cited '#N'/pull-URL. DIVE-2556
# closed done with NEITHER a Branch: line nor a delivery_ref, and its own result
# text said "commit dc336f7 on branch dive-2556-maker-credit is UNPUSHED (dev3 has
# no push route)" — real evidence of unlanded work that nothing upstream of
# _gate_branch_refs_from_text could see, because a branch is not a PR. This suite
# pins the new arm: an UNBOUND close whose result/body names "<ident>-<slug>" is
# now run through the same ancestry+attribution+merged-PR scan the DIVE-1830
# declared-Branch: path already runs, and refused if nothing on main shows it
# landed. A close that names no branch at all (the DIVE-2556 population's
# complement — research, decisions, ordinary prose containing the word "branch")
# must stay untouched: this is not a blanket PR-or-branch requirement.
#
# MUTATION GRADE (run by hand against src/cmd_task.sh, both must go red):
#   * neuter the extractor — `_gate_branch_refs_from_text() { :; }` -> case 1 FAILS
#     (closes with the branch never checked at all — reproduces DIVE-2556 exactly).
#   * neuter the refusal — comment out the `policy_refuse ... done-with-unlanded-
#     branch-in-result` call -> case 1 FAILS.
#   * neuter the accept arms — `_gate_branch_ident_on_main() { printf '0'; }` AND
#     stub the merged-PR list empty -> case 2 and case 3 both FAIL (refuse landed
#     work).
#   * loosen the anchor — drop the `${ident}-` prefix requirement from the regex
#     -> case 5 (plain prose containing "branch") FAILS (false-blocks a close that
#     names no branch at all).
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_branch_in_result_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2770: the merge gate gained a CREDENTIAL-FREE rail (an unauthenticated read
# of a public repo). Every no-token arm below was written when "no credential"
# meant "no rail", and with the anon rail live they would reach the real network
# and grade a LIVE PR instead of the fixture. Turn it off here: these harnesses
# grade the pre-2770 rails, and tests/task_merge_gate_anon_rail_unit.sh grades the
# new one. This is also what keeps `no root, no network` true of this file.
#
# IT MUST SIT AFTER lib/grading_tree.sh, AND THAT IS NOT A STYLE CHOICE: that file
# sources lib/env_isolation.sh, which CLEARS inherited FIVE_* knobs so a harness
# never grades the caller's environment. Set above it, this export is wiped and the
# harness silently reaches the network instead — measured, and it read as three
# unrelated assertion failures naming a live PR's real state.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-branch-in-result-unit.XXXXXX)"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; repo=""; i=0; slice='.'
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q|--jq) expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)     expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)  repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
key() { printf '%s' "${1//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # both the open-PR scan (--state open) and the merged-branch-head lookup
  # (--state merged --head <branch>) come through here; key on state+repo.
  st="open"; for x in "${a[@]}"; do [[ "$x" == "merged" ]] && st="merged"; done
  lx="GH_STUB_PRLIST_${st}_$(key "${repo##*/}")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"
  slug=$(printf '%s' "$path" | cut -d/ -f2,3)
  case "$path" in
    */commits\?*)
      br="${path##*sha=}"; br="${br%%&*}"
      fx="GH_STUB_COMMITS_$(key "${slug##*/}")_$(key "$br")"
      pp=30; case "$path" in *per_page=*) pp="${path##*per_page=}"; pp="${pp%%&*}" ;; esac
      [[ "$pp" =~ ^[0-9]+$ ]] || pp=30
      (( pp > 100 )) && pp=100
      pg=1; case "$path" in *"&page="*) pg="${path##*&page=}"; pg="${pg%%&*}" ;; esac
      [[ "$pg" =~ ^[0-9]+$ && "$pg" -gt 0 ]] || pg=1
      slice=".[$(( (pg-1)*pp )):$(( pg*pp ))]" ;;
    *) exit 1 ;;
  esac
  json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -c "$slice" 2>/dev/null | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export FIVE_GATE_REPOS="5dive-ai/5dive"
# DIVE-2054: force-merge-gate's audit write is fenced to the PROD store
# (_task_human_send_allowed) — declare this fixture store as prod so the
# override-is-audited assertion exercises the real path, same as
# task_merge_gate_autodetect_unit.sh.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, status, created_by, assignee)
                   VALUES ('$1','t','in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PRLIST_@}" "${!GH_STUB_COMMITS_@}" 2>/dev/null; }
commits() { printf '[{"commit":{"message":"%s"}},{"commit":{"message":"chore: unrelated"}}]' "$1"; }
NO_MATCH_COMMITS='[{"commit":{"message":"chore(deps): bump something"}}]'
MERGED_PR() { printf '[{"number":%s,"mergedAt":"2026-07-26T09:00:00Z","headRefName":"%s"}]' "$1" "$2"; }

# --- 0. THE PURE EXTRACTOR: anchored to <ident>-, nothing else -----------------
out=$(_gate_branch_refs_from_text 'commit dc336f7 on branch dive-2556-maker-credit is UNPUSHED' 'DIVE-2556')
[[ "$out" == "dive-2556-maker-credit" ]] \
  && ok_t 'extractor finds an ident-prefixed branch slug cited in prose' \
  || bad_t 'extractor should find the DIVE-2556 branch' "out=$out"
out=$(_gate_branch_refs_from_text 'there are three branches of this problem worth exploring' 'DIVE-2556')
[[ -z "$out" ]] \
  && ok_t 'extractor does NOT match plain prose containing the word "branch" with no ident prefix' \
  || bad_t 'extractor over-matched' "out=$out"
out=$(_gate_branch_refs_from_text 'closing DIVE-2556 as verified, no code involved' 'DIVE-2556')
[[ -z "$out" ]] \
  && ok_t 'extractor does NOT match the bare ident with no trailing slug' \
  || bad_t 'extractor over-matched a bare ident' "out=$out"

# --- 0b. DIVE-3265: A FILE IS NOT A BRANCH ------------------------------------
# The measured defect. A non-repo row delivers an ARTIFACT named by the same
# "<ident>-<kebab>" convention as a branch; the extractor could not tell them
# apart, so DIVE-3264's design doc made the gate demand that a branch of that
# name land on main — impossible, the deliverable is a file in a tree that is not
# a git repo — and the row became uncloseable with no escape (results are
# PRESERVED, `set-branch <id> ''` is rejected). Graded as a CLASS, not as the one
# filename: the path form, the bare-basename form, and a non-.md artifact.
#
# THE POSITIVE CONTROLS ARE THE LOAD-BEARING HALF. Every negative below is
# satisfiable by an extractor that returns nothing at all, so each is paired with
# a hit the filter must still let through — the same discipline the DIVE-2603
# rc arms at the bottom of this file use.
#
# MUTATION GRADE: delete the `grep -ivE '\.(md|...)$'` line from the extractor ->
# the three negatives FAIL. Widen it to strip any dotted suffix (`\.[a-z]+$`) ->
# the `v1.2` positive FAILS.
out=$(_gate_branch_refs_from_text 'design doc delivered: community/designs/dive-3264-svc-5dive-api-account-split.md' 'DIVE-3264')
[[ -z "$out" ]] \
  && ok_t 'DIVE-3265: an artifact PATH ending .md is not read as a branch (the measured DIVE-3264 shape)' \
  || bad_t 'DIVE-3265: artifact path must not extract' "out=$out — this is the refusal that bricked DIVE-3264"
out=$(_gate_branch_refs_from_text 'wrote dive-3264-svc-5dive-api-account-split.md and handed it over' 'DIVE-3264')
[[ -z "$out" ]] \
  && ok_t 'DIVE-3265: a bare .md BASENAME (no path) is not read as a branch either' \
  || bad_t 'DIVE-3265: bare basename must not extract' "out=$out"
out=$(_gate_branch_refs_from_text 'applied DIVE-3264-account-split.patch on top' 'DIVE-3264')
[[ -z "$out" ]] \
  && ok_t 'DIVE-3265: the rule is the CLASS of artifact extensions, not just .md' \
  || bad_t 'DIVE-3265: .patch must not extract' "out=$out"
out=$(_gate_branch_refs_from_text 'landed dive-3264-svc-account-split on main' 'DIVE-3264')
[[ "$out" == "dive-3264-svc-account-split" ]] \
  && ok_t 'DIVE-3265 positive control: the SAME slug with no extension is still a branch' \
  || bad_t 'DIVE-3265 positive control: extension-less slug still extracts' "out=$out — the filter is over-broad and DIVE-2577 coverage is gone"
out=$(_gate_branch_refs_from_text 'pushed https://github.com/5dive-ai/5dive/tree/dive-3264-svc-account-split' 'DIVE-3264')
[[ "$out" == "dive-3264-svc-account-split" ]] \
  && ok_t 'DIVE-3265: a branch inside a forge URL still extracts (the rule is a SUFFIX test, not a path test)' \
  || bad_t 'DIVE-3265: forge-URL branch still extracts' "out=$out — a path-shaped rejection would cost this shape for nothing"
out=$(_gate_branch_refs_from_text 'cut branch dive-3264-retry-v1.2 for the second attempt' 'DIVE-3264')
[[ "$out" == "dive-3264-retry-v1.2" ]] \
  && ok_t 'DIVE-3265: a dotted branch name that is not an ARTIFACT extension survives' \
  || bad_t 'DIVE-3265: dotted non-extension branch survives' "out=$out — the filter must be an extension denylist, not 'any dotted suffix'"

# --- 1. THE DIVE-2556 SHAPE: unbound, result names an unlanded branch -> REFUSE
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
seed DIVE-2556
run_done DIVE-2556 --result='VERIFIED PASS. NOT YET IN PROD: commit dc336f7 on branch dive-2556-maker-credit is UNPUSHED (dev3 has no push route); Marcus/main has been sent the push+merge handoff.'
if [[ $RC -ne 0 && "$(statusof DIVE-2556)" == "in_progress" && "$(refusals DIVE-2556)" == "1" ]]; then
  ok_t 'a result naming an unlanded branch, no Branch: line, no delivery_ref — REFUSED (DIVE-2556 reproduction)'
else
  bad_t 'DIVE-2556 shape must refuse' "rc=$RC status=$(statusof DIVE-2556) refusals=$(refusals DIVE-2556) out=$OUT"
fi
[[ "$OUT" == *"dive-2556-maker-credit"* && "$OUT" == *"landed"* ]] \
  && ok_t 'the refusal names the branch and the ticket' \
  || bad_t 'refusal should name branch + DIVE-2577' "out=$OUT"

# Cases 2-4 use their OWN idents (not DIVE-2556 again): policy_refusals is a
# durable log keyed by ident, never cleared between cases, and case 1's refusal
# for DIVE-2556 would otherwise still be counted here even after a later,
# unrelated run of the same ident closes cleanly.

# --- 2. Same shape, but the branch IS on main (attribution) -> CLOSES ----------
clear_fx
export GH_STUB_COMMITS_5dive_main="$(commits 'task: credit maker on close (BR-2)')"
seed BR-2
run_done BR-2 --result='landed via delegated push on branch br-2-maker-credit'
[[ $RC -eq 0 && "$(statusof BR-2)" == "done" && "$(refusals BR-2)" == "0" ]] \
  && ok_t 'a cited branch found on main via attribution closes cleanly' \
  || bad_t 'attributed branch must close' "rc=$RC status=$(statusof BR-2) refusals=$(refusals BR-2) out=$OUT"

# --- 3. Same shape, but the branch is the head of a MERGED PR -> CLOSES --------
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
export GH_STUB_PRLIST_merged_5dive="$(MERGED_PR 41 br-3-maker-credit)"
seed BR-3
run_done BR-3 --result='merged as PR against branch br-3-maker-credit'
[[ $RC -eq 0 && "$(statusof BR-3)" == "done" && "$(refusals BR-3)" == "0" ]] \
  && ok_t 'a cited branch that is head of a MERGED pr closes cleanly' \
  || bad_t 'merged-PR branch must close' "rc=$RC status=$(statusof BR-3) refusals=$(refusals BR-3) out=$OUT"

# --- 4. --force-merge-gate overrides the branch refusal, audited ---------------
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
seed BR-4
run_done BR-4 --result='on branch br-4-maker-credit, unpushed' --force-merge-gate
[[ $RC -eq 0 && "$(statusof BR-4)" == "done" ]] \
  && ok_t '--force-merge-gate overrides the unlanded-branch refusal' \
  || bad_t 'force-merge-gate must still close' "rc=$RC status=$(statusof BR-4) out=$OUT"
grep -q 'task.force-merge-gate' "$AUDIT_CALLS" \
  && ok_t 'the override is audited' \
  || bad_t 'override must be audited' "$(cat "$AUDIT_CALLS")"

# --- 5. Ordinary unbound close naming NO branch at all -> untouched ------------
clear_fx
seed DIVE-9001
run_done DIVE-9001 --result='decision recorded, no code changed — closing per the branch of reasoning discussed with lodar'
[[ $RC -eq 0 && "$(statusof DIVE-9001)" == "done" && "$(refusals DIVE-9001)" == "0" ]] \
  && ok_t 'a close that mentions "branch" in prose but names no ident-prefixed slug is untouched' \
  || bad_t 'plain-prose close must not be blocked' "rc=$RC status=$(statusof DIVE-9001) refusals=$(refusals DIVE-9001) out=$OUT"


# DIVE-2603: the extractor is a PROBE that legitimately finds nothing, and its
# pipeline ends in `grep`, which exits 1 on no-match. Under `set -euo pipefail`
# an UNGUARDED `var=$(...)` around it kills the caller — which is exactly what
# v0.18.3 shipped: `task done` exited 1 with EMPTY stdout AND stderr for every
# caller holding a gh token whose result text named no branch. The die happened
# before anything printed, which is why it presented as a silent failure.
#
# Two arms as a PAIR. The no-match arm alone passes for an extractor that is
# never reached; the match arm proves the probe still works and that the no-match
# arm is not green by vacuity.
_rc_probe() {  # $1 = text ; echoes "rc|output"
  local out rc=0
  out=$(bash -c '
    set -euo pipefail
    '"$(declare -f _gate_branch_refs_from_text 2>/dev/null || true)"'
    _gate_branch_refs_from_text "$1" "$2"
  ' _ "$1" "DIVE-999") || rc=$?
  printf '%s|%s' "$rc" "$out"
}
_r_none="$(_rc_probe 'this result names no branch at all')"
_r_hit="$(_rc_probe 'landed on DIVE-999-some-slug today')"
[[ "${_r_none%%|*}" == "1" ]] \
  && ok_t "DIVE-2603: the extractor itself EXITS 1 on no-match (the hazard is real, not hypothetical)" \
  || bad_t "DIVE-2603: extractor exits 1 on no-match" "expected rc=1, got ${_r_none%%|*} — if this changed, the guard below is grading nothing"
[[ "${_r_hit%%|*}" == "0" && "${_r_hit#*|}" == "dive-999-some-slug" ]] \
  && ok_t "DIVE-2603: positive control — the extractor still finds a real branch (rc=0)" \
  || bad_t "DIVE-2603: positive control" "expected rc=0 and dive-999-some-slug, got ${_r_hit}"
grep -qE '_br_cands=\$\(_gate_branch_refs_from_text [^)]*\) \|\| _br_cands=' "$SRC/cmd_task.sh" \
  && ok_t "DIVE-2603: the call site GUARDS the assignment so a no-match cannot kill the close" \
  || bad_t "DIVE-2603: call site guarded" "the \$( ) assignment is unguarded — under set -e + pipefail a result naming no branch kills 'task done' with empty stdout and stderr"


# --- 6. DIVE-3265 TRUE-POSITIVE ARMS: the control still FIRES ------------------
# Marcus's merge condition, and it is the right one to insist on: this is a change
# to a SAFETY CONTROL, so the arm that matters is not that the false positive
# stopped firing — it is that the TRUE positive still does. "A gate that stops
# crashing by learning to pass everything" is indistinguishable from a fix when you
# only grade the thing that used to be red.
#
# 6a is the sharp one: a close carrying BOTH a real unlanded branch AND an artifact
# filename must still REFUSE. If the extension filter were reachable as a laundering
# route — name your branch, name a .md, watch the gate go quiet — that is a worse
# defect than the one being fixed, and it would look identical from the outside.
clear_fx
export GH_STUB_COMMITS_5dive_main="$NO_MATCH_COMMITS"
seed DIVE-2556
run_done DIVE-2556 --result='delivered the note dive-2556-handoff.md; commit dc336f7 on branch dive-2556-maker-credit is UNPUSHED'
if [[ $RC -ne 0 && "$(statusof DIVE-2556)" == "in_progress" ]]; then
  ok_t 'DIVE-3265 6a TRUE POSITIVE: an .md alongside a REAL unlanded branch does not launder it — still REFUSED'
else
  bad_t 'DIVE-3265 6a TRUE POSITIVE: still refuses' "rc=$RC status=$(statusof DIVE-2556) — the extension filter became a bypass; that is worse than the bug it fixed. out=$OUT"
fi
printf '%s' "$OUT" | grep -q 'dive-2556-maker-credit' \
  && ok_t 'DIVE-3265 6a: the refusal still names the BRANCH (and not the artifact)' \
  || bad_t 'DIVE-3265 6a: refusal names the branch' "out=$OUT"
printf '%s' "$OUT" | grep -q 'dive-2556-handoff.md' \
  && bad_t 'DIVE-3265 6a: the refusal must NOT name the artifact' "the .md is back in the candidate set: $OUT" \
  || ok_t 'DIVE-3265 6a: the artifact is absent from the refusal (it was never a candidate)'

# 6b: the DIVE-1830 DECLARED-`Branch:` path is a DIFFERENT reader and must be
# untouched by this change. Asserted structurally rather than inferred from the
# sibling harness staying green: `_gate_branch_refs_from_text` has exactly TWO
# callers, both on the unbound auto-detect path, so the bound gate cannot have
# been widened. If a third caller ever appears, this arm is the tripwire.
_callers=$(grep -cE '^[^#]*_gate_branch_refs_from_text "' "$SRC/cmd_task.sh")
[[ "$_callers" == "2" ]] \
  && ok_t 'DIVE-3265 6b: the extractor still has exactly 2 call sites — the declared-`Branch:` gate does not read it and was not widened' \
  || bad_t 'DIVE-3265 6b: extractor call-site count' "found $_callers call sites, expected 2 — a new caller inherits this filter; re-argue the bias before shipping it"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
