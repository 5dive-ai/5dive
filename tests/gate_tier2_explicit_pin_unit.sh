#!/usr/bin/env bash
# DIVE-1957 isolated unit harness: an EXPLICIT `--tier=2` (the caller's hard-human
# contract) must survive every KIND-based downgrade/route carve-out.
#
# THE BUG: cmd_task_need resolved the tier correctly (tier_arg remembered the
# explicit pin), then three later carve-outs — eng-ship (DIVE-1359),
# content-curation (DIVE-1381), internal-ops (DIVE-1480) — re-tiered it to 1 and
# lead-routed it WITHOUT ever consulting tier_arg. A brand/money decision filed
# `--type=decision --tier=2` was silently recorded as tier 1 and routed to an
# agent who could clear it. Curation additionally cleared tier_floored, defeating
# the T2 keyword floor as well.
#
# THE SECOND AXIS — why a suite that varies only the ASK falsely passes: the
# classifiers match over the ask AND the TASK TITLE. A gate filed on a normally
# named ENGINEERING task ("LAND the X branch: settle MERGE order") is downgraded
# by construction no matter how the ask is worded, and the filer cannot fix that
# from the ask at all. Every veto case below therefore comes in BOTH forms: the
# keyword in the ask, and the keyword in the TITLE with a neutral ask.
#
# What must NOT change: overriding the TYPE DEFAULT (approval/manual default to
# tier 2) for a builder ship-gate is the whole point of the eng-ship class and is
# re-asserted here, so this suite can't pass by simply disabling the carve-outs.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR — the live tasks.db is never touched.
# Run: bash tests/gate_tier2_explicit_pin_unit.sh (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-t2pin-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
# DIVE-2054: "task.gate-tier2-pin-escalated" is now routed through
# _task_store_audit_log (STORE IDENTITY fence, DIVE-2010) — declare this
# fixture store as prod so the audit-row assertion below keeps exercising the
# real path, mirroring task_merge_gate_multirepo_unit.sh's DIVE-2010 fix.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Never DM the human or shell out to a peer: sentinel + `5dive` shell-function stub
# (shadows the real binary, keeps `command -v 5dive` true, records the send).
HUMAN_PINGED=0
# DIVE-2011: stub the HUMAN deliverer, not the wrapper. task_need_notify is now
# the shared entry point for BOTH rails (it dispatches to the lead-route
# deliverer when TASK_GATE_ROUTE_TO is set), so stubbing the wrapper would make
# this sentinel fire on a ROUTED gate — i.e. report a human ping that never
# happened — and would suppress the route send this harness is asserting on.
# One layer down, HUMAN_PINGED means what its name says: the paired human's
# notify path ran. The routed rail runs for real against the `5dive` stub.
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; HUMAN_PINGED=0; }
route_sent()  { local i; for i in 1 2 3 4 5; do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; grep -c . "$ROUTE_FILE" 2>/dev/null || echo 0; }

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# seed WITH a title — the title is half the classifier input, so it is a first-class
# variable here, not boilerplate.
seed()    { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1',$(sqlq "$2"),'todo','main');"; }
tierof()  { db "SELECT tier FROM tasks WHERE ident='$1';"; }
routedof(){ db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }

# A pinned gate must be: tier 2, NOT routed to a reviewer, human pinged.
assert_pin_held() { # <ident> <label>
  local id="$1" lbl="$2" t r
  t=$(tierof "$id"); r=$(routedof "$id")
  [[ "$t" == "2" && -z "$r" && "$HUMAN_PINGED" == "1" ]] \
    && ok_t "$lbl" || bad_t "$lbl" "tier='$t' routed='$r' human=$HUMAN_PINGED sent=$(route_sent)"
}
# An un-pinned gate of the same kind must still be downgraded + lead-routed.
assert_downgraded() { # <ident> <label>
  local id="$1" lbl="$2" t r
  t=$(tierof "$id"); r=$(routedof "$id")
  [[ "$t" == "1" && "$r" == "main" && "$HUMAN_PINGED" == "0" ]] \
    && ok_t "$lbl" || bad_t "$lbl" "tier='$t' routed='$r' human=$HUMAN_PINGED"
}

# The carve-outs route regardless of the gate_builder_routing pref, so leave the
# pref at its default (off) — that is the live posture the bug was found in.

# =============================================================================
# ENG-SHIP (DIVE-1359) — the pin must survive, in the ASK and in the TITLE
# =============================================================================

# 1: keyword in the ASK — the original repro (`--tier=2` + "Ship it to prod").
route_reset; seed DIVE-901 'DIVE-1690 council page'
cmd_task_need DIVE-901 --type=decision --tier=2 --from=dev \
  --ask="Ship it to prod: which council page copy goes live?" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
assert_pin_held DIVE-901 "eng-ship in ASK: explicit --tier=2 survives (stays hard-human)"

# 2: THE TITLE AXIS — byte-neutral ask, eng-ship keywords ONLY in the task title.
#    This is Marcus's controlled experiment (DIVE-1956 vs DIVE-1672): identical
#    flags + ask, the only variable is the title, and the title alone downgraded
#    the gate. A fix that only reads the ask cannot pass this case.
route_reset; seed DIVE-902 'LAND the DIVE-1672 council-rules branch: rebase package.json + settle MERGE order vs dive-1690'
cmd_task_need DIVE-902 --type=decision --tier=2 --from=dev \
  --ask="Which of these two wordings should the public page use?" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
assert_pin_held DIVE-902 "eng-ship in TITLE: explicit --tier=2 survives (the axis the filer cannot reword)"

# 3: floor term + eng-ship term together (repro 2 — 'BRAND call' + 'ship'). The
#    explicit pin skips the floor evaluation entirely (tier_floored stays 0), so
#    before the fix this was downgraded despite carrying a floor keyword.
route_reset; seed DIVE-903 'Council page polish'
cmd_task_need DIVE-903 --type=decision --tier=2 --from=dev \
  --ask="BRAND call on the public 5dive.ai /council page before we ship it" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
assert_pin_held DIVE-903 "eng-ship + floor term ('brand'+'ship') with --tier=2 stays hard-human"

# 4: approval flavour, keyword in TITLE only.
route_reset; seed DIVE-904 'Merge the pricing-page redesign PR'
cmd_task_need DIVE-904 --type=approval --tier=2 --from=dev \
  --ask="Sign off the final pricing numbers on the public page?" --recommend="yes" >/dev/null 2>&1
assert_pin_held DIVE-904 "eng-ship TITLE + --type=approval --tier=2 survives"

# 5: UNCHANGED — no --tier flag, so the TYPE DEFAULT (approval ⇒ 2) is still
#    overridden and the builder ship-gate is lead-routed. If this ever fails the
#    "fix" is just a disabled carve-out.
route_reset; seed DIVE-905 'LAND the dive-1957 branch: settle MERGE order'
cmd_task_need DIVE-905 --type=approval --from=dev \
  --ask="Approve landing the verified fix and pushing to origin?" --recommend="yes" >/dev/null 2>&1
assert_downgraded DIVE-905 "eng-ship with NO --tier: type default STILL downgraded + lead-routed (DIVE-1359 intact)"

# 6: UNCHANGED — an explicit --tier=1 is not a hard-human pin; nothing to veto.
route_reset; seed DIVE-906 'Ship the dive-1957 fix'
cmd_task_need DIVE-906 --type=decision --tier=1 --from=dev \
  --ask="ship it now or after the release?" --options="now|after" --recommend="now" >/dev/null 2>&1
[[ "$(tierof DIVE-906)" == "1" && "$(routedof DIVE-906)" == "main" ]] \
  && ok_t "explicit --tier=1 eng-ship still lead-routed (only a =2 pin vetoes)" \
  || bad_t "tier=1 eng-ship routed" "tier='$(tierof DIVE-906)' routed='$(routedof DIVE-906)'"

# =============================================================================
# CONTENT-CURATION (DIVE-1381) — same two axes
# =============================================================================

# 7: keyword in the ASK.
route_reset; seed DIVE-910 'Character pack drip'
cmd_task_need DIVE-910 --type=approval --tier=2 --from=dev \
  --ask="approve persona 'doc' as ready to publish to the character-pack drip queue?" --recommend="yes" >/dev/null 2>&1
assert_pin_held DIVE-910 "curation in ASK: explicit --tier=2 survives"

# 8: TITLE AXIS — curation vocabulary only in the title.
route_reset; seed DIVE-911 'Approve the persona pack for the character-packs publish queue'
cmd_task_need DIVE-911 --type=decision --tier=2 --from=dev \
  --ask="Which of the two brand palettes should we commit to?" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
assert_pin_held DIVE-911 "curation in TITLE: explicit --tier=2 survives"

# 9: UNCHANGED — no pin ⇒ the curation carve-out still beats the 'publish' floor.
route_reset; seed DIVE-912 'Character pack drip'
cmd_task_need DIVE-912 --type=approval --from=dev \
  --ask="approve persona 'doc' as ready to publish to the character-pack drip queue?" --recommend="yes" >/dev/null 2>&1
assert_downgraded DIVE-912 "curation with NO --tier: still downgraded + lead-routed (DIVE-1381 intact)"

# =============================================================================
# INTERNAL-OPS (DIVE-1480) — same two axes
# =============================================================================

# 10: keyword in the ASK (the STEER-1 board-wipe repro).
route_reset; seed DIVE-920 'Board recovery'
cmd_task_need DIVE-920 --type=decision --tier=2 --from=dev \
  --ask="The task board was wiped/destroyed at 04:20 — keep or discard my uncommitted work and rebuild the board from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
assert_pin_held DIVE-920 "internal-ops in ASK: explicit --tier=2 survives"

# 11: TITLE AXIS.
route_reset; seed DIVE-921 'Rebuild the wiped task board from the audit log'
cmd_task_need DIVE-921 --type=decision --tier=2 --from=dev \
  --ask="keep or discard the in-flight work?" --options="keep|discard" --recommend="keep" >/dev/null 2>&1
assert_pin_held DIVE-921 "internal-ops in TITLE: explicit --tier=2 survives"

# 12: UNCHANGED — no pin ⇒ the over-fired destructive floor is still carved out.
route_reset; seed DIVE-922 'Board recovery'
cmd_task_need DIVE-922 --type=decision --from=dev \
  --ask="The task board was wiped/destroyed at 04:20 — keep or discard my uncommitted work and rebuild the board from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
assert_downgraded DIVE-922 "internal-ops with NO --tier: still downgraded + lead-routed (DIVE-1480 intact)"

# =============================================================================
# ACCESS (DIVE-1243) — routes by TYPE regardless of tier; the pin backstop
# =============================================================================

# 13: an access gate filed with an explicit --tier=2 is NOT routed to the lead.
route_reset; seed DIVE-930 'Grant prod DB access'
cmd_task_need DIVE-930 --type=access --tier=2 --from=dev \
  --ask="grant me the prod read-replica credentials?" >/dev/null 2>&1
assert_pin_held DIVE-930 "access + explicit --tier=2 is NOT lead-routed (DIVE-1145 invariant backstop)"

# 14: UNCHANGED — an un-pinned access gate still routes to the lead by type.
route_reset; seed DIVE-931 'Grant staging box access'
cmd_task_need DIVE-931 --type=access --from=dev \
  --ask="grant me shell on the staging box?" >/dev/null 2>&1
[[ "$(routedof DIVE-931)" == "main" ]] \
  && ok_t "access with NO --tier: still lead-routed by type (DIVE-1243 intact)" \
  || bad_t "access no-pin routed" "routed='$(routedof DIVE-931)' tier='$(tierof DIVE-931)'"

# =============================================================================
# A LEAD's own pinned gate, and the recorded envelope
# =============================================================================

# 15: the JSON envelope must REPORT tier 2 — the bug was only visible by reading
#     the recorded tier back, so assert the recorded value, not just the routing.
route_reset; seed DIVE-940 'LAND the dive-1957 branch'
OUT=$(cmd_task_need DIVE-940 --type=decision --tier=2 --from=dev \
  --ask="Which wording ships on the public page?" --options="A|B" --recommend="A" 2>/dev/null)
[[ "$(printf '%s' "$OUT" | jq -r '.data.tier')" == "2" ]] \
  && ok_t "recorded JSON envelope reports tier 2 for a pinned eng-ship-TITLE gate" \
  || bad_t "envelope tier 2" "got '$(printf '%s' "$OUT" | jq -r '.data.tier // "?"')'"

# =============================================================================
# AUDIT ROW (Marcus, DIVE-1957 review) — the veto must be MEASURABLE
# =============================================================================
# The warn corrects the next filer; the audit row tells us whether the habit is
# real (the standing remedy for this bug WAS "pin --tier=2", so agents carrying
# that advice may now escalate routine ship gates past their lead). Audit the
# branch that DECLINES to act, not just the one that acts.
AUDIT_FILE="$TMP/audit.log"
audit_log() { printf '%s\n' "$1" >>"$AUDIT_FILE"; }
audit_reset() { : >"$AUDIT_FILE"; }

# 16: a pinned eng-ship gate that escalates past the lead records the row.
route_reset; audit_reset; seed DIVE-950 'LAND the dive-1957 branch: settle MERGE order'
cmd_task_need DIVE-950 --type=decision --tier=2 --from=dev \
  --ask="Which wording ships on the public page?" --options="A|B" --recommend="A" >/dev/null 2>&1
grep -q '^task.gate-tier2-pin-escalated$' "$AUDIT_FILE" \
  && ok_t "pinned eng-ship escalation records an audit row (measurable, not just a warn)" \
  || bad_t "audit row on pinned escalation" "rows='$(tr '\n' ',' <"$AUDIT_FILE")'"

# 17: the un-pinned downgrade does NOT record it — the row means "a pin escalated
#     past a lead", so it must not fire on the normal lead-routed path.
route_reset; audit_reset; seed DIVE-951 'LAND the dive-1957 branch: settle MERGE order'
cmd_task_need DIVE-951 --type=decision --from=dev \
  --ask="Which wording ships on the public page?" --options="A|B" --recommend="A" >/dev/null 2>&1
grep -q '^task.gate-tier2-pin-escalated$' "$AUDIT_FILE" \
  && bad_t "no audit row on the un-pinned downgrade" "rows='$(tr '\n' ',' <"$AUDIT_FILE")'" \
  || ok_t "un-pinned eng-ship downgrade records NO pin-escalation row"

# 18 (DIVE-2062): OFF the prod store, the SAME pinned escalation writes NO row,
# and the withholding is announced. Cases 16/17 above only ever ran ON the prod
# store (FIVEDIVE_PROD_TASKS_DB was declared at the top of this file and never
# unset) — per the DIVE-2054 verifier pass (dev3, 2026-07-26) this suite
# reached the site but only ever on its ALLOWED side. This proves WITHHELD too.
route_reset; audit_reset; unset _TASK_STORE_AUDIT_FENCED
seed DIVE-952 'LAND the dive-1957 branch: settle MERGE order'
FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db" cmd_task_need DIVE-952 \
  --type=decision --tier=2 --from=dev \
  --ask="Which wording ships on the public page?" --options="A|B" --recommend="A" \
  >/dev/null 2>"$TMP/offstore.err"
[[ ! -s "$AUDIT_FILE" ]] \
  && ok_t "off the prod store, the pin-escalation writes NO audit row" \
  || bad_t "off-store must not audit" "rows='$(tr '\n' ',' <"$AUDIT_FILE")'"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t "the withholding is ANNOUNCED, not silent" \
  || bad_t "fence must announce" "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
