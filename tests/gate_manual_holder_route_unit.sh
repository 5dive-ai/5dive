#!/usr/bin/env bash
# TIER: core
# DIVE-4329 — A TIER-2 MANUAL GATE IS DELIVERED TO ITS NAMED HOLDER AND IS NEVER
# RE-ROUTED TO A LEAD SEAT.
#
# Invariant 6 of DIVE-4327's BLOCKED side-state: a human is asked for a
# CAPABILITY, and the ask goes to the HOLDER of that capability, directly.
#
# MEASURED 2026-09-11 14:24Z. DIVE-4239's login-test gate is a tier-2 `manual`
# gate whose holder is lodar — a person at a browser, the only party who can do
# the thing. It queued on a lead seat for review and was never pinged, by two
# independent mechanisms that this harness grades separately:
#
#   1. ROUTING. `_row_ship` (DIVE-3266/3528) routes any of decision/approval/
#      manual on a branch- or delivery-bound row to the filer's lead, and it
#      deliberately does not lower the tier. A tier-2 manual gate on a row that
#      carries a PR was therefore handed to a seat that, by the gate's own type,
#      cannot perform the step.
#   2. THE PLAIN-ENGLISH LINT. DIVE-4176 refuses an unreadable human-facing ask
#      and offered `--tier=1` as one of its exits — a ROUTING verb as the remedy
#      for a VOCABULARY complaint. A preview URL matches the `path` and `branch`
#      arms of the jargon classifier, so "try logging in at <preview link>" was
#      refused, and the exit that makes the command exit 0 moves the gate off the
#      only desk that could answer it.
#
# EVERY ARM IS PAIRED WITH A CONTROL THAT MUST STILL DO THE OLD THING. A fix that
# makes `manual` unroutable everywhere, or makes the lint stop refusing, passes an
# rc-only reading of arms 1-3 while deleting two shipped rules. So:
#   * a DOWNGRADED manual gate (eng-ship kind, tier 1) must still route to the
#     lead — that is DIVE-1182's population and it is not what broke;
#   * an approval gate on the same bound row must still route to the lead;
#   * a URL does NOT buy an exemption for the rest of the ask: a link plus an
#     ident is still refused, and a URL in a non-human_tap gate is still jargon.
#
# Run: bash tests/gate_manual_holder_route_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-manual-holder.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         lib/broker.sh cmd_push.sh; do
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
cmd_send()                  { return 0; }
_task_agent_channel()       { return 0; }
_task_send_owner()          { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()                 { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()     { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }

# THE HOLDER IS REAL AND THE LEAD IS REAL. Both halves matter: with no lead above
# the filer every routing arm would pass by accident (_gate_route_reviewer empty
# is already the fall-through to the human), so the lead is seeded and asserted
# live in arm P2 before any arm reads a route.
_gate_route_reviewer()      { printf 'olivia'; }

# task_need_notify is the human ping. Record WHO it was asked to reach rather
# than stubbing it to a bare 0: "never re-routed to a lead" and "delivered to the
# holder" are two different claims and a silent stub can only ever grade the first.
NOTIFIED="$TMP/notified"; : >"$NOTIFIED"
task_need_notify() {
  local ident="$1"
  # Call the REAL stamper (src/task/notify.sh) rather than re-deriving the owner
  # here: "delivered to the named holder" is a claim about the shipped resolution
  # order, and a harness that reimplements it grades its own copy.
  _task_stamp_human_owner "$ident" || true
  local numid; numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");")
  local owner; owner=$(db "SELECT COALESCE(human_owner,'') FROM tasks WHERE id=${numid};")
  [[ -n "$owner" ]] || owner=$(_human_gate_recipient "$numid")
  printf '%s\t%s\t%s\n' "$numid" "${owner:-<none>}" "${TASK_GATE_ROUTE_TO:-}" >>"$NOTIFIED"
  return 0
}

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
no_t()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] unexpectedly contains [$3]"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
notified_for()  { awk -v i="$(db "SELECT id FROM tasks WHERE ident='$1';")" -F'\t' '$1==i{print $2}' "$NOTIFIED" | tail -1; }
# What the notifier was told to ROUTE to. Empty is the human path; a seat name
# here is the re-route this row exists to abolish, and it is a different fact
# from routed_reviewer (which a later writer could set).
routed_send() { awk -v i="$(db "SELECT id FROM tasks WHERE ident='$1';")" -F'\t' '$1==i{print $3}' "$NOTIFIED" | tail -1; }

# A row bound to a branch: this is what makes `_row_ship` fire, and it is the
# shape DIVE-4239 was in (a PR was already open on it).
N=0
seed() { N=$((N+1)); db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status, body)
      VALUES ('$1', '${2:-a plain internal row}', 'medium', 'dev', 'main', 'standard', 'todo',
              'Branch: dive-4239-login-check
Repo: 5dive-ai/app');"; }

RC=0; OUT=""
file_gate() { local id="$1"; shift; OUT=$( (cmd_task_need "$id" --from=dev "$@") 2>&1 ); RC=$?; }

# The holder: a real person on the registry, linked to the filing seat's chain.
db "INSERT OR IGNORE INTO humans (id) VALUES ('lodar');"
db "UPDATE humans SET telegram_id='1234567890' WHERE id='lodar';"
db "INSERT OR IGNORE INTO human_agents (human_id, agent) VALUES ('lodar','dev');"

READABLE="Please try signing in on the preview site and tell me if it works?"
LINKED="Please try signing in at https://app-git-login.vercel.app/login and say if it works?"

# ============ P. preconditions: the subject and the counterfactual are live ===
seed PRE-1
file_gate PRE-1 --type=approval --ask="Should we turn the new sign-in on for everyone?"
eq_t "P1: PRECONDITION — an approval gate on this bound row files (rc 0)" "$RC" "0"
eq_t "P2: PRECONDITION — ... and IS routed to the lead, so a route is reachable here" \
     "$(field PRE-1 routed_reviewer)" "olivia"
eq_t "P3: PRECONDITION — the holder resolves for this filer" \
     "$(_human_gate_recipient "$(db "SELECT id FROM tasks WHERE ident='PRE-1';")")" "lodar"

# ============ A. the headline: a tier-2 manual gate is the holder's ==========
seed MAN-1
file_gate MAN-1 --type=manual --ask="$READABLE"
eq_t "A1: a tier-2 manual gate FILES (rc 0)" "$RC" "0"
eq_t "A2: ... at tier 2, as the type defaults" "$(field MAN-1 tier)" "2"
eq_t "A3: ... and is NEVER handed to a lead seat" "$(field MAN-1 routed_reviewer)" "∅"
eq_t "A4: ... it is delivered to the NAMED HOLDER" "$(notified_for MAN-1)" "lodar"
eq_t "A5: ... and the holder is stamped on the row" "$(field MAN-1 human_owner)" "lodar"
eq_t "A5b: ... and the SEND itself was told no seat, i.e. the human rail" "$(routed_send MAN-1)" ""

# A6 — the same gate with the holder named explicitly. `--owner=` must win, and
# must not be undone by the routing change.
seed MAN-2
file_gate MAN-2 --type=manual --ask="$READABLE" --owner=lodar
eq_t "A6: --owner= names the holder and the gate still bypasses the lead" \
     "$(field MAN-2 routed_reviewer)|$(field MAN-2 human_owner)" "∅|lodar"

# ============ B. CONTROL: the lead route that was NOT the defect =============
# B1 — an approval gate on the identical row keeps its lead route (P2 again, as a
# control alongside the manual arm rather than only as a precondition).
seed APP-1
file_gate APP-1 --type=approval --ask="Should we turn the new sign-in on for everyone?"
eq_t "B1 CONTROL: approval on a bound row still routes to the lead" \
     "$(field APP-1 routed_reviewer)" "olivia"

# B2 — a manual gate at tier 1 still routes to the lead. THE PREDICATE IS THE
# EFFECTIVE TIER, and this arm is what proves the fix did not simply delete
# `manual` from the router.
#
# It is filed with an explicit --tier=1 rather than through a downgrade kind, and
# that is a finding rather than a shortcut: NO downgrade reaches this type.
# eng-ship is scoped to decision/approval (DIVE-1359 — "manual is never
# downgraded, the nudge is its only treatment"), and curation and internal-ops
# are each "guarded to decision/approval with a reviewer". So after this row
# every tier-2 `manual` gate is the holder's, by every kind-route there is —
# the deliberate widening the ticket asked for, and this is the arm that says so.
# A builder who wants a lead to clear a ship handoff has two exits, both already
# shipped and both preserved here: --type=decision (the DIVE-1738 nudge prints it
# on exactly this filing) or --tier=1.
seed SHIP-1
file_gate SHIP-1 --type=manual --tier=1 --ask="Should I rebuild the task board from the backlog, or leave it?"
eq_t "B2 CONTROL: a manual gate downgraded off tier 2 still routes to the lead" \
     "$(field SHIP-1 tier)|$(field SHIP-1 routed_reviewer)" "1|olivia"

# B3 — secret stays exactly as it was: never routed, never reached by this change.
seed SEC-1
file_gate SEC-1 --type=secret --ask="Please paste the new sign-in key when you get a moment?"
eq_t "B3 CONTROL: a secret gate is still unrouted" "$(field SEC-1 routed_reviewer)" "∅"

# ============ C. the lint is a lint, not a router ============================
# C1 — a link in a human_tap ask is no longer a refusal by itself.
seed URL-1
file_gate URL-1 --type=manual --ask="$LINKED"
eq_t "C1: a preview LINK in a manual ask files (rc 0)" "$RC" "0"
eq_t "C2: ... reaching the holder, not a lead" \
     "$(field URL-1 routed_reviewer)|$(notified_for URL-1)" "∅|lodar"
eq_t "C3: ... and the ask keeps the link the person needs" \
     "$(db "SELECT CASE WHEN ask LIKE '%https://app-git-login.vercel.app/login%' THEN 'kept' ELSE 'stripped' END FROM tasks WHERE ident='URL-1';")" "kept"

# C4 — declared rather than typed: --needs=human_tap buys the same exemption.
seed URL-2
file_gate URL-2 --type=approval --tier=2 --needs=human_tap --ask="$LINKED"
eq_t "C4: --needs=human_tap earns the same link exemption" "$RC" "0"

# C5 — NOT A BLANKET EXEMPTION. A link plus a real internal name is still refused:
# the URL leaves the SCAN, the scan does not leave the gate.
seed URL-3
file_gate URL-3 --type=manual --ask="Try https://app-git-login.vercel.app/login and confirm DIVE-4239?"
[[ "$RC" != "0" ]] && ok_t "C5: a link does NOT excuse the rest of the ask" \
  || bad_t "C5: a link does NOT excuse the rest of the ask" "rc=$RC out=$OUT"
has_t "C5b: ... and the refusal still names the offending token" "$OUT" "DIVE-4239"
eq_t  "C5c: ... and no gate was written" "$(field URL-3 need_type)" "∅"

# C6 — CONTROL: the same URL on a gate that does NOT consume human_tap is still
# jargon. The exemption is keyed to the capability, not to the character '/'.
seed URL-4
file_gate URL-4 --type=approval --tier=2 --ask="Should we ship https://app-git-login.vercel.app/login to everyone?"
[[ "$RC" != "0" ]] && ok_t "C6 CONTROL: a URL in a non-human_tap ask is still refused" \
  || bad_t "C6 CONTROL: a URL in a non-human_tap ask is still refused" "rc=$RC out=$OUT"

# C7/C8 — WHEN IT DOES REFUSE, IT DOES NOT OFFER A DIFFERENT DESK. The exits are
# rewrite-it and declare-the-exception; `--tier=1` is gone, and this is the line
# DIVE-4239's filer actually followed.
seed LINT-1
file_gate LINT-1 --type=manual --ask="Approve merging DIVE-3164 at head e39ad3a?"
[[ "$RC" != "0" ]] && ok_t "C7: an unreadable holder-facing ask is still REFUSED" \
  || bad_t "C7: an unreadable holder-facing ask is still REFUSED" "rc=$RC out=$OUT"
no_t  "C8: the refusal no longer offers --tier=1 as an exit" "$OUT" "  --tier=1 "
has_t "C8b: ... it offers the audited exception inline instead" "$OUT" "--ask-ok="
has_t "C8c: ... and says why a wording note may not move the desk" "$OUT" "DOES NOT OFFER IS A DIFFERENT DESTINATION"

# C9 — the escape still files, and still lands on the holder. A gate must never
# become unfileable (DIVE-2216), and the escape must not quietly re-route either.
seed LINT-2
file_gate LINT-2 --type=manual --ask="Approve merging DIVE-3164 at head e39ad3a?" \
  --ask-ok="the sha is the thing he has to paste into the box"
eq_t "C9: --ask-ok files the refused ask (rc 0)" "$RC" "0"
eq_t "C9b: ... still to the holder, never to a lead" \
     "$(field LINT-2 routed_reviewer)|$(notified_for LINT-2)" "∅|lodar"
has_t "C9c: ... and the exception is audited" "$(cat "$AUDIT_ROWS")" "task need ask-readability escaped"

# ============ D. the unit-level predicate ====================================
_gate_is_human_tap manual 2 ""        && ok_t "D1: manual@2 is human_tap by type" \
  || bad_t "D1: manual@2 is human_tap by type" "predicate said no"
_gate_is_human_tap manual 1 ""        && bad_t "D2: manual@1 is NOT human_tap" "predicate said yes" \
  || ok_t "D2: manual@1 is NOT human_tap (it was downgraded to a lead)"
_gate_is_human_tap approval 2 human_tap && ok_t "D3: a declared human_tap is human_tap" \
  || bad_t "D3: a declared human_tap is human_tap" "predicate said no"
_gate_is_human_tap approval 2 spend_authority && bad_t "D4: spend_authority is NOT human_tap" "predicate said yes" \
  || ok_t "D4: spend_authority is NOT human_tap (money is not a browser)"
_gate_is_human_tap approval 2 human_tap_delegate && bad_t "D5: no prefix match" "predicate said yes" \
  || ok_t "D5: 'human_tap_delegate' does not match by prefix"
eq_t "D6: the URL stripper removes the link and nothing else" \
     "$(_gate_ask_url_strip "try https://a.b/c now")" "try link now"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
