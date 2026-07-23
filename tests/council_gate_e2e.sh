#!/usr/bin/env bash
# CNCL-12 bash e2e — the gate-rot WIRING (not just the pure mapper). Drives the real
# `5dive council {gate-clear,rot-triage}` bundle end-to-end against an isolated STATE_DIR +
# TASKS_DB + a self-provisioned gate-proof key, and asserts the three load-bearing legs the
# acceptance requires:
#   A) a genuine TIER-1 gate is CLEARED with a sealed receipt (task answer written by council),
#   B) a TIER-2 gate routed through gate-clear ESCALATES (guardrail) and is NEVER cleared,
#   C) a synthetic 48h-old TIER-2 gate through rot-triage is re-briefed and NEVER cleared.
# Offline: COUNCIL_MOCK (mock seat votes -> approve), no network, isolated tasks.db.
#
# Needs root (the convene's gate-proof seal runs in-process against the isolated STATE_DIR).
# Re-execs under passwordless sudo when available; SKIPs (green) otherwise — same posture as
# council_veto_e2e.sh, so CI never goes red on a runner that can't seal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum sqlite3; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council gate e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council gate e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP" TASKS_DB="$TMP/tasks.db" COUNCIL_MOCK=1 COUNCIL_5DIVE_BIN="$FIVE"
DB="$TASKS_DB"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
q(){ sqlite3 "$DB" "$1" 2>/dev/null; }

# helper: create a task, file a gate on it, return the ident on stdout.
mkgate() { # <title> <type> <tier> <ask> [recommend] [options]
  local ident
  ident="$("$FIVE" task add "$1" --json 2>/dev/null | jq -r '.data.ident // .data.id // empty')"
  [[ -n "$ident" ]] || ident="$(q "SELECT ident FROM tasks ORDER BY id DESC LIMIT 1;")"
  local -a nargs=(--type="$2" --tier="$3" --ask="$4")
  [[ -n "${5:-}" ]] && nargs+=(--recommend="$5")
  [[ -n "${6:-}" ]] && nargs+=(--options="$6")
  "$FIVE" task need "$ident" "${nargs[@]}" >/dev/null 2>&1 || true
  echo "$ident"
}

# --- genesis so rot-triage's primary-council convene resolves (leg C) ----------------------------
"$FIVE" council init --seats="a:chair,b,c" --threshold="majority" --veto="tg:1234567890" >/dev/null 2>&1 \
  || { echo "FAIL: council init (cannot seal genesis — no gate-proof rail?)"; exit 1; }

# ================= LEG A: a genuine tier-1 gate is CLEARED with a sealed receipt =================
A="$(mkgate "rename internal helper fn" "decision" "1" "Rename the internal helper fn from foo to bar?" "yes" "yes|no")"
atier="$(q "SELECT tier FROM tasks WHERE ident='$A';")"
[[ "$atier" == "1" ]] && ok "leg A gate stays tier-1 (benign, not floored)" || no "leg A gate tier=$atier (want 1 — pick a more benign ask)"
"$FIVE" council gate-clear "$A" --seats="a:chair,b,c" --mode=quick >/dev/null 2>&1 || no "gate-clear returned nonzero"
aans="$(q "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$A';")"
aval="$(q "SELECT COALESCE(need_answer,'') FROM tasks WHERE ident='$A';")"
[[ -n "$aans" ]] && ok "leg A: tier-1 gate CLEARED (need_answered_at set)" || no "leg A: tier-1 gate NOT cleared"
[[ "$aval" == *"[council]"* ]] && ok "leg A: cleared by the council (answer carries [council] provenance)" || no "leg A: answer not council-stamped ($aval)"
# a sealed receipt for the deliberation exists
[[ -n "$(ls -1 "$TMP/council/receipts/"*.json 2>/dev/null | grep -v '/veto-' | head -1)" ]] \
  && ok "leg A: sealed convene receipt written" || no "leg A: no sealed receipt"

# ================= LEG B: a tier-2 gate through gate-clear ESCALATES, never clears ===============
B="$(mkgate "approve a manual step" "approval" "2" "Approve the manual prod step?")"
btier="$(q "SELECT tier FROM tasks WHERE ident='$B';")"
[[ "$btier" == "2" ]] && ok "leg B gate is tier-2 (approval floored)" || no "leg B tier=$btier (want 2)"
bout="$("$FIVE" council gate-clear "$B" --json 2>/dev/null)"
baction="$(printf '%s' "$bout" | jq -r '.data.action // empty' 2>/dev/null)"
[[ "$baction" == "escalate" ]] && ok "leg B: tier-2 gate-clear -> escalate (guardrail, no convene)" || no "leg B: action=$baction (want escalate)"
bans="$(q "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$B';")"
[[ -z "$bans" ]] && ok "leg B: tier-2 gate NEVER cleared (need_answered_at still NULL)" || no "leg B: tier-2 gate was cleared (must not be!)"

# ================= LEG C: a synthetic 48h-old tier-2 gate through rot-triage, never cleared =======
C="$(mkgate "ship the pricing note" "decision" "2" "Ship the pricing footnote change?" "ship" "ship|hold")"
# force tier-2 + backdate the gate-file time past the 48h window.
q "UPDATE tasks SET tier=2, need_asked_at=datetime('now','-3 days') WHERE ident='$C';"
cask_before="$(q "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$C';")"
cout="$("$FIVE" council rot-triage --all --json 2>/dev/null)"
ccount="$(printf '%s' "$cout" | jq -r '.data.count // 0' 2>/dev/null)"
[[ "$ccount" =~ ^[0-9]+$ && "$ccount" -ge 1 ]] && ok "leg C: rot-triage picked up the stale tier-2 gate (count=$ccount)" || no "leg C: rot-triage did not triage the stale gate (count=$ccount)"
cans="$(q "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$C';")"
[[ -z "$cans" ]] && ok "leg C: tier-2 gate NEVER cleared by triage (need_answered_at still NULL)" || no "leg C: triage CLEARED a tier-2 gate (fail-closed violated!)"
cask_after="$(q "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$C';")"
[[ "$cask_after" == *"[council triage]"* ]] && ok "leg C: gate re-briefed (ask carries [council triage])" || no "leg C: ask not re-briefed ($cask_after)"
ctier="$(q "SELECT tier FROM tasks WHERE ident='$C';")"
[[ "$ctier" == "2" ]] && ok "leg C: gate stays tier-2 after triage (human-only preserved)" || no "leg C: tier downgraded to $ctier"

# --- dry-run leaves the gate untouched -----------------------------------------------------------
D="$(mkgate "another stale t2" "decision" "2" "Another stale tier-2 ask?")"
q "UPDATE tasks SET tier=2, need_asked_at=datetime('now','-3 days') WHERE ident='$D';"
dask_before="$(q "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$D';")"
"$FIVE" council rot-triage "$D" --dry-run >/dev/null 2>&1
dask_after="$(q "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$D';")"
[[ "$dask_before" == "$dask_after" ]] && ok "dry-run: gate untouched (no re-brief, no clear)" || no "dry-run mutated the gate"

echo "CNCL-12 gate e2e: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
