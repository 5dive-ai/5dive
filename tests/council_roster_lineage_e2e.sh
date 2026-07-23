#!/usr/bin/env bash
# CNCL-11 bash e2e — the GOVERNANCE SURFACE wiring (roster / log / verify / promote / demote),
# not just the node engine. Drives the real `5dive council {init,roster,promote,demote,log,verify}`
# bundle against an isolated STATE_DIR + a self-provisioned gate-proof key, and asserts the
# acceptance: a promote/demote runs as a convened motion whose receipt + resulting roster join the
# tamper-evident lineage; roster shows the live seats + threshold + veto holder + lineage head;
# recusal drops the subject; `verify` is green while the chain is intact and RED after a tampered,
# dropped, or reordered record. Offline: COUNCIL_MOCK (mock all-approve votes), no network/tasks.db.
#
# Needs root (the gate-proof seal runs in-process against the isolated STATE_DIR). Re-execs under
# passwordless sudo when available; SKIPs (green) otherwise — same posture as council_veto_e2e.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FIVE="$ROOT/5dive"

for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council roster/lineage e2e needs it)"; exit 0; }
done
[[ -x "$FIVE" ]] || { echo "SKIP: built ./5dive not found (run ./build.sh first)"; exit 0; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then exec sudo -n env PATH="$PATH" bash "$0" "$@"; fi
  echo "SKIP: council roster/lineage e2e needs root (in-process gate-proof seal) and passwordless sudo is unavailable"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# COUNCIL_5DIVE_BIN pins the nested convene (a motion shells `council convene`) to the BINARY UNDER
# TEST, not whatever `5dive` is (or isn't) on PATH — CI has no installed 5dive, so a bare `5dive`
# call would fail the motion convene. Same pattern as council_gate_e2e.sh.
export STATE_DIR="$TMP" COUNCIL_MOCK=1 COUNCIL_5DIVE_BIN="$FIVE"
LIN="$TMP/council/lineage.jsonl"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# --- genesis: seed a 3-seat council (main chairs) ------------------------------------------------
"$FIVE" council init --seats="main:chair,theo,olivia" --threshold="majority" --veto="tg:1234567890" >/dev/null 2>&1 \
  || { echo "FAIL: council init (cannot seal genesis — no gate-proof rail?)"; exit 1; }

# --- roster: live seats + threshold + veto holder + lineage head ---------------------------------
R="$("$FIVE" council roster --json 2>/dev/null)"
[[ "$(printf '%s' "$R" | jq -r '.data.seatCount')" == "3" ]] && ok "roster shows 3 seeded seats" || no "roster seatCount != 3 ($R)"
[[ "$(printf '%s' "$R" | jq -r '.data.threshold')" == "2" ]] && ok "roster threshold = majority(3)=2" || no "roster threshold wrong"
[[ "$(printf '%s' "$R" | jq -r '.data.veto.principal')" == "tg:1234567890" ]] && ok "roster shows the founder-veto principal" || no "roster veto principal wrong"
[[ "$(printf '%s' "$R" | jq -r '.data.lineage.records')" == "1" ]] && ok "roster lineage head = 1 record (genesis)" || no "roster lineage records != 1"
# CNCL-27: the chair flag must survive genesis -> persisted bench -> roster (JSON + text badge)
[[ "$(printf '%s' "$R" | jq -r '.data.seats[] | select(.id=="main") | .chair')" == "true" ]] && ok "roster JSON carries the chair flag (main)" || no "roster dropped the chair flag ($R)"
RT="$("$FIVE" council roster 2>/dev/null)"
printf '%s' "$RT" | grep -qE 'seat main \(chair\)' && ok "roster text renders the chair badge" || no "roster text missing (chair) badge ($RT)"

# --- verify: intact single-record chain is GREEN ------------------------------------------------
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN on the seeded genesis" || no "verify RED on a fresh genesis"

# --- PROMOTE: a convened motion that carries and seats a new member ------------------------------
P="$("$FIVE" council promote --subject=codex --lens="codex — engineering rigor." --mode=quick --json 2>/dev/null)"
[[ "$(printf '%s' "$P" | jq -r '.data.carried')" == "true" ]] && ok "promote carried (mock all-approve)" || no "promote did not carry ($P)"
[[ "$(printf '%s' "$P" | jq -r '.data.motion')" == "promote" ]] && ok "motion class auto-classified: promote" || no "promote class wrong"
R2="$("$FIVE" council roster --json 2>/dev/null)"
[[ "$(printf '%s' "$R2" | jq -r '.data.seatCount')" == "4" ]] && ok "roster grew to 4 seats after promote" || no "roster did not grow"
printf '%s' "$R2" | jq -e '.data.seats[] | select(.id=="codex")' >/dev/null 2>&1 && ok "codex now holds a seat" || no "codex not seated"
[[ "$(printf '%s' "$R2" | jq -r '.data.lineage.records')" == "2" ]] && ok "promote record joined the lineage (2 records)" || no "promote not chained into lineage"
# the motion record links back to the convene receipt that decided it
[[ -n "$(tail -n1 "$LIN" | jq -r '.record.receiptDigest // empty')" ]] && ok "motion record carries the convene receiptDigest (receipts join the chain)" || no "motion record has no receiptDigest"
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN after promote (chain intact)" || no "verify RED after a legit promote"

# --- DEMOTE: subject recuses; roster shrinks -----------------------------------------------------
D="$("$FIVE" council demote --subject=theo --mode=quick --json 2>/dev/null)"
[[ "$(printf '%s' "$D" | jq -r '.data.carried')" == "true" ]] && ok "demote carried" || no "demote did not carry ($D)"
[[ "$(tail -n1 "$LIN" | jq -r '.record.recused | join(",")')" == "theo" ]] && ok "recusal recorded: subject 'theo' recused from its own demotion" || no "recusal not recorded"
R3="$("$FIVE" council roster --json 2>/dev/null)"
[[ "$(printf '%s' "$R3" | jq -r '.data.seatCount')" == "3" ]] && ok "roster shrank to 3 after demote" || no "roster did not shrink"
printf '%s' "$R3" | jq -e '.data.seats[] | select(.id=="theo")' >/dev/null 2>&1 && no "theo still seated after demote" || ok "theo no longer holds a seat"

# --- log: past verdicts (genesis + 2 motions) ---------------------------------------------------
L="$("$FIVE" council log --json 2>/dev/null)"
[[ "$(printf '%s' "$L" | jq -r '.data.entries | length')" == "3" ]] && ok "log lists all 3 sealed records" || no "log count wrong"
[[ "$(printf '%s' "$L" | jq -r '[.data.entries[] | select(.kind=="motion")] | length')" == "2" ]] && ok "log shows 2 motion verdicts" || no "log motion count wrong"

# --- verify: still GREEN across the full 3-record chain -----------------------------------------
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN across genesis + promote + demote" || no "verify RED on an intact 3-record chain"

# --- guardrails: bad-subject motions are refused fail-closed ------------------------------------
"$FIVE" council promote --subject=main --mode=quick >/dev/null 2>&1 && no "promote of an already-seated member was NOT refused" || ok "promote of an existing seat refused (fail-closed)"
"$FIVE" council demote --subject=ghost --mode=quick >/dev/null 2>&1 && no "demote of a non-seat was NOT refused" || ok "demote of a non-member refused (fail-closed)"

# ================= DIVE-1667: bench genesis-marker drift resolves from the LINEAGE ================
# Pin the exact DIVE-1664 live failure: `council roster` used to read its seats from the EDITABLE
# registry bench (benches.json .council.{genesis,seats}); once that bench lost its genesis marker it
# died "the Council has no genesis roster — seed it first" EVEN THOUGH the root-sealed lineage was
# intact (roster and log had diverged). The fix derives the roster from the lineage head, with the
# registry bench a fallback ONLY when no lineage record carries seats. Clear the bench genesis marker
# + seats while the intact 3-record chain stays untouched, and assert roster STILL resolves the 3
# lineage-head seats (main/olivia/codex, post-demote) and never emits the seed-it-first death.
REG="$TMP/council/benches.json"
cp "$REG" "$TMP/benches.bak"
jq 'del(.council.genesis) | (.council.seats)=[]' "$REG" > "$TMP/reg.drift" && mv "$TMP/reg.drift" "$REG"
RB="$("$FIVE" council roster --json 2>/dev/null)"
[[ "$(printf '%s' "$RB" | jq -r '.data.seatCount')" == "3" ]] \
  && ok "roster resolves 3 seats from the sealed lineage despite a cleared bench genesis marker (DIVE-1664)" \
  || no "roster failed to resolve from the lineage after bench drift ($RB)"
printf '%s' "$RB" | jq -e '.data.seats[] | select(.id=="main")' >/dev/null 2>&1 \
  && ok "lineage-derived roster still seats main after bench drift" || no "lineage roster lost main after bench drift"
RBT="$("$FIVE" council roster 2>&1)"
printf '%s' "$RBT" | grep -qiE 'no genesis roster|seed it first' \
  && no "roster hit the 'seed it first' death with an intact lineage (DIVE-1664 regression)" \
  || ok "roster renders from the lineage with a drifted bench (no 'seed it first' death)"
"$FIVE" council verify >/dev/null 2>&1 && ok "verify still GREEN — bench drift never touched the sealed chain" || no "verify RED after a bench-only drift"
cp "$TMP/benches.bak" "$REG"

# ================= TAMPER DETECTION — verify must go RED ==========================================
# (a) EDIT a record's canonical: re-seal no longer matches its stored digest.
cp "$LIN" "$TMP/lin.bak"
{ head -n1 "$TMP/lin.bak"
  sed -n '2p' "$TMP/lin.bak" | jq -c '.canonical |= (. + "\ntampered: yes")'
  tail -n1 "$TMP/lin.bak"
} > "$LIN"
"$FIVE" council verify >/dev/null 2>&1 && no "verify GREEN on an EDITED canonical (tamper missed)" || ok "verify RED on an edited record canonical (re-seal mismatch)"
cp "$TMP/lin.bak" "$LIN"

# (b) DROP the middle record: the chain link breaks.
{ head -n1 "$TMP/lin.bak"; tail -n1 "$TMP/lin.bak"; } > "$LIN"
"$FIVE" council verify >/dev/null 2>&1 && no "verify GREEN after a DROPPED record (chain break missed)" || ok "verify RED on a dropped record (chain break)"
cp "$TMP/lin.bak" "$LIN"

# (c) REORDER records: prevDigest link + seq monotonicity break.
{ head -n1 "$TMP/lin.bak"; tail -n1 "$TMP/lin.bak"; sed -n '2p' "$TMP/lin.bak"; } > "$LIN"
"$FIVE" council verify >/dev/null 2>&1 && no "verify GREEN after REORDER (missed)" || ok "verify RED on reordered records"
cp "$TMP/lin.bak" "$LIN"

# --- restored chain verifies again --------------------------------------------------------------
"$FIVE" council verify >/dev/null 2>&1 && ok "verify GREEN again once the lineage is restored" || no "verify RED after restore"

echo
echo "CNCL-11 roster/lineage e2e: $pass passed, $fail failed"
exit $(( fail ? 1 : 0 ))
