#!/usr/bin/env bash
# DIVE-2848 — THE KEYSTROKE CAP ON RUBBER-STAMP GATES.
#
# lodar, 2026-08-06: "im fighting with unnecessary human gates for the past three
# weeks". The policy that should have stopped it (CLAUDE.md line 61) has existed
# since 2026-06-29. Measured 2026-07-16..08-07 anyway: 96 of 107 human-answered
# judgment gates carrying a --recommend came back as the human tapping that same
# value, and only 7 gates in 346 were keyword-floored — the rest of tier 2 was
# TYPED. A doc is indexed by topic; the act is a keystroke. This grades the cap
# that moved the rule to the keystroke.
#
# EVERY REFUSAL CASE IS PAIRED WITH A CONTROL THAT MUST STILL FILE. The cheap way
# to pass "the rubber-stamp gate was refused" is for cmd_task_need to be broken,
# mis-sourced or refusing everything — and a lone red exit cannot tell that apart
# from the cap working. The three tier-2 shapes that MUST survive (category
# floor, declared --needs, declared --rubber-stamp-ok) are what make the refusals
# mean something.
#
# Assertions read the RECORD (a row's tier / gate_rubber_stamp / existence) as
# well as the exit status, because a refusal that exits non-zero AFTER writing
# the gate would pass an rc-only assertion while leaving the ping it refused.
#
# Run: bash tests/gate_recommend_cap_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-recommend-cap.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
cmd_send()               { return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()              { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()  { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }
# No lead above the filer: keeps eng-ship / curation / --discusses downgrades out
# of these cases, so a tier that survives to the cap survived for the reason the
# case is about. Asserted live below (case C2) rather than assumed.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
rows()  { db "SELECT COUNT(*) FROM tasks WHERE ident='$1';"; }

seed() { # <ident> [title]
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
      VALUES ('$1', '${2:-a plain internal row}', 'medium', 'dev', 'main', 'standard', 'todo');"
}

# file <ident> <args...> -> sets RC and OUT (stdout+stderr together: the refusal
# is a `fail`, which writes to stderr).
RC=0; OUT=""
file_gate() {
  local id="$1"; shift
  OUT=$( (cmd_task_need "$id" --from=dev "$@") 2>&1 ); RC=$?
}

# ============ PRECONDITION: the subject is live ==============================
# Without this every refusal below is indistinguishable from cmd_task_need being
# unreachable in this harness.
seed LIVE-1
file_gate LIVE-1 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=1
eq_t "PRECONDITION: an ordinary tier-1 decision gate files (rc 0)" "$RC" "0"
eq_t "PRECONDITION: ... and the row is a real tier-1 gate" \
     "$(field LIVE-1 need_type)|$(field LIVE-1 tier)" "decision|1"

# ============ A. the cap fires on the shape it was built for =================
seed CAP-1
file_gate CAP-1 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2
[[ "$RC" != "0" ]] && ok_t "A1: --tier=2 decision + --recommend + no capability is REFUSED" \
  || bad_t "A1: --tier=2 decision + --recommend + no capability is REFUSED" "rc=$RC out=$OUT"
has_t "A2: the refusal names --tier=0 as the exit" "$OUT" "--tier=0"
has_t "A3: the refusal names --tier=1 as the exit" "$OUT" "--tier=1"
has_t "A4: the refusal names --needs as the exit" "$OUT" "--needs=human_tap"
has_t "A5: the refusal names the audited escape" "$OUT" "--rubber-stamp-ok"
# The refusal must land BEFORE the write. An rc-only assertion would pass on a
# refusal that had already filed the gate and pinged the human.
eq_t "A6: NO gate was written by the refused filing" "$(field CAP-1 need_type)" "∅"
eq_t "A7: the task was not moved to blocked" "$(field CAP-1 status)" "todo"
has_t "A8: the refusal is audited" "$(cat "$AUDIT_ROWS")" "task need rubber-stamp-cap refused"

# Same gate at tier 0 — the exit the refusal names must actually work, or the cap
# is a dead end rather than a redirect.
seed CAP-11
file_gate CAP-11 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=0
eq_t "A9: the named exit works — the same gate files at --tier=0 (rc 0)" "$RC" "0"
eq_t "A10: ... and tier 0 applied the recommendation with no human" \
     "$(field CAP-11 need_answer)|$(field CAP-11 need_answered_by)" "alpha|auto:t0"

# approval is the other judgment type the cap governs.
seed CAP-2
file_gate CAP-2 --type=approval --ask="approve the internal refactor of the helper" \
          --recommend="approved" --tier=2
[[ "$RC" != "0" ]] && ok_t "A11: --tier=2 approval + --recommend is REFUSED too" \
  || bad_t "A11: --tier=2 approval + --recommend is REFUSED too" "rc=$RC out=$OUT"

# ============ B. the shapes that MUST still reach a person ===================
# B1 — a gate with NO recommendation is not a rubber stamp. Nothing was decided,
# so there is nothing to take back.
seed KEEP-1
file_gate KEEP-1 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --tier=2
eq_t "B1: --tier=2 decision with NO --recommend still files (rc 0)" "$RC" "0"
eq_t "B1b: ... at tier 2" "$(field KEEP-1 tier)" "2"

# B2 — a DECLARED human capability (DIVE-2241) is the honest tier 2.
seed KEEP-2
file_gate KEEP-2 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2 --needs=human_tap
eq_t "B2: a DECLARED --needs=human_tap gate is not capped (rc 0)" "$RC" "0"
eq_t "B2b: ... and stays tier 2" "$(field KEEP-2 tier)" "2"

# B3 — the T2 CATEGORY FLOOR. Money is tier 2 on subject matter; the filer cannot
# lower it and --discusses is its own appeal. If the cap ever swallowed this the
# ticket would have traded rubber stamps for unauthorised spend.
# NON-VACUOUS FIRST: assert the classifier actually fires on this ask, or "the
# money gate was not capped" passes just as well against an ask that was never
# money at all.
if _gate_tier2_floor_hit "approve the monthly spend on the paid Hetzner plan"; then
  ok_t "B3-pre: the control ask really does hit the T2 category floor"
else
  bad_t "B3-pre: the control ask really does hit the T2 category floor" "classifier said no"
fi
seed KEEP-3
file_gate KEEP-3 --type=decision --ask="approve the monthly spend on the paid Hetzner plan" \
          --options="yes|no" --recommend="yes" --tier=2
eq_t "B3: a FLOORED (money) tier-2 decision is not capped (rc 0)" "$RC" "0"
eq_t "B3b: ... stays tier 2 and is marked floored" \
     "$(field KEEP-3 tier)|$(field KEEP-3 need_type)" "2|decision"

# B4 — manual/secret are tier 2 by TYPE and untouched by this ticket.
seed KEEP-4
file_gate KEEP-4 --type=manual --ask="tap the confirm button in the provider console"
eq_t "B4: a manual gate is untouched by the cap (rc 0)" "$RC" "0"
eq_t "B4b: ... and is still tier 2 by type" "$(field KEEP-4 tier)" "2"

# ============ C. the audited escape ==========================================
seed ESC-1
file_gate ESC-1 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2 \
          --rubber-stamp-ok="lodar asked to see this exact wording himself before it lands"
eq_t "C1: --rubber-stamp-ok lets the gate file (rc 0)" "$RC" "0"
eq_t "C1b: ... at tier 2" "$(field ESC-1 tier)" "2"
# The whole value of the escape is that it is COUNTABLE afterwards.
has_t "C2: the declared reason is RECORDED on the gate row" \
      "$(field ESC-1 gate_rubber_stamp)" "lodar asked to see this exact wording"
has_t "C3: ... and readable from task show" \
      "$(JSON_MODE=0 cmd_task_show ESC-1 2>&1)" "rubber-stamp-ok:"

# C4/C5 — the escape is refused where it would be meaningless, never
# accepted-and-ignored (the DIVE-2089 rule: a filer must not believe a
# declaration applied when it did not).
seed ESC-2
file_gate ESC-2 --type=manual --ask="tap the confirm button in the provider console" \
          --rubber-stamp-ok="this is a manual step and needs no escape"
[[ "$RC" != "0" ]] && ok_t "C4: --rubber-stamp-ok on --type=manual is REFUSED" \
  || bad_t "C4: --rubber-stamp-ok on --type=manual is REFUSED" "rc=$RC out=$OUT"
seed ESC-3
file_gate ESC-3 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2 --rubber-stamp-ok="dunno"
[[ "$RC" != "0" ]] && ok_t "C5: a substanceless --rubber-stamp-ok is REFUSED" \
  || bad_t "C5: a substanceless --rubber-stamp-ok is REFUSED" "rc=$RC out=$OUT"

# ============ C6. a PREFILLED recommendation is not the filer's ==============
# The cap's premise is "you wrote a recommendation, so you decided". By the time it
# runs, `recommend` may have been prefilled from a PRECEDENT (OSS-11/OSS-20/OSS-21)
# that the filer never typed — keying on the post-prefill variable inverts the rule
# and refuses a gate for a decision the machine made on the filer's behalf. Found by
# gate_precedent_unit.sh A5, whose fixture passes no --recommend at all and was
# refused anyway; guarded here so the fix has a test that names it.
PREC_ASK="approve the migration runbook"
PREC_SHAPE="$(_gate_ask_shape "$PREC_ASK")"
# Mirrors gate_precedent_unit's seed_prec_by: a precedent carries need_answer +
# ask_shape and NO recommend of its own, and was answered by someone other than the
# filer below — otherwise these two rows would also land in the tap-back window part
# D measures, and D would be grading its own fixtures.
seed_prec() { db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,
                        need_type,tier,ask,ask_shape,need_answer,need_answered_by,
                        need_answered_at,need_asked_at)
                  VALUES ('$1','precedent','medium','dev','main','standard','todo',
                        'approval',2,'$PREC_ASK','$PREC_SHAPE','approved','human:mark',
                        datetime('now'), datetime('now','-2 days'));"; }
seed_prec PREC-1; seed_prec PREC-2
seed PREFILL-1
file_gate PREFILL-1 --type=approval --ask="$PREC_ASK" --tier=2
eq_t "C6: a gate whose recommend was PREFILLED from precedent is not capped (rc 0)" "$RC" "0"
eq_t "C6b: ... and it really did get a prefilled recommendation (the case is live)" \
     "$(field PREFILL-1 recommend)" "approved"

# ============ D. rate-limit the CLASS, not just the instance ==================
# The escape is for an exception. Past the cap it IS the pattern, and the only
# honest exit left is naming a capability.
#
# The tap test is SEMANTIC by design — the first measurement of this ticket read
# 45% because it compared need_answer to recommend with `=`, and an approval tap
# normalises to 'approved' while the recommendation is free text. Both halves are
# seeded here: 11 exact-match decisions and 3 free-text approvals.
seed_answered() { # <ident> <type> <recommend> <answer>
  db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status,
                         need_type, tier, ask, recommend, need_answer, need_answered_by,
                         need_answered_at, need_asked_at, gate_filed_by)
      VALUES ('$1','answered gate','medium','dev','main','standard','todo',
              '$2', 2, 'the ask', '$3', '$4', 'human:lodar',
              datetime('now','-1 day'), datetime('now','-1 day'), 'dev');"
}
for i in $(seq 1 11); do seed_answered "TAP-D$i" decision "alpha" "alpha"; done
for i in $(seq 1 3);  do seed_answered "TAP-A$i" approval "Push it" "approved"; done

read -r _taps _tot <<<"$(_gate_tapback_stats dev)"
eq_t "D1: the semantic tap test counts free-text approvals as taps (14 of 14)" \
     "${_taps}/${_tot}" "14/14"
# The discriminating control: an OVERRIDE must not count. Without it a tap test
# that returns 1 unconditionally passes D1.
seed_answered TAP-OVR decision "alpha" "beta"
read -r _taps2 _tot2 <<<"$(_gate_tapback_stats dev)"
eq_t "D2: an override is NOT counted a tap (14 of 15)" "${_taps2}/${_tot2}" "14/15"

seed RATE-1
file_gate RATE-1 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2 \
          --rubber-stamp-ok="I would like a person to look at this one anyway"
[[ "$RC" != "0" ]] && ok_t "D3: past the cap the ESCAPE itself is refused" \
  || bad_t "D3: past the cap the ESCAPE itself is refused" "rc=$RC out=$OUT"
has_t "D4: the rate refusal names the filer's own number" "$OUT" "of your last"
has_t "D5: ... and leaves --needs as the remaining exit" "$OUT" "--needs=<capability>"
has_t "D6: the rate refusal is audited" "$(cat "$AUDIT_ROWS")" "rubber-stamp-cap refused-rate"

# D7 — a DECLARED capability is never rate-limited. Money and credentials do not
# become unaskable because the filer has a bad recent record.
seed RATE-2
file_gate RATE-2 --type=decision --ask="pick a name for the internal helper" \
          --options="alpha|beta" --recommend="alpha" --tier=2 --needs=spend_authority
eq_t "D7: a declared capability is never rate-limited (rc 0)" "$RC" "0"

# D8 — FAIL-OPEN below the minimum sample: a filer with no history must not
# inherit a refusal. Same shape as D3 from an agent with an empty record.
seed RATE-3
OUT=$( (cmd_task_need RATE-3 --from=newbie --type=decision \
        --ask="pick a name for the internal helper" --options="alpha|beta" \
        --recommend="alpha" --tier=2 \
        --rubber-stamp-ok="first gate I have filed and it wants a person") 2>&1 ); RC=$?
eq_t "D8: a filer with no history is not rate-limited (rc 0)" "$RC" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
