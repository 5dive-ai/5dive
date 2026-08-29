#!/usr/bin/env bash
# DIVE-3785 (absorbing cancelled OSS-36) — `task inbox` IS the fleet-wide gate
# inbox, and `--fleet` is an accepted no-op.
#
# WHY THIS FILE EXISTS AS ITS OWN HARNESS. `tests/gate_parity_smoke.sh` holds a
# parity matrix: every shipped gate feature owes a covering test that runs with
# Telegram absent, because the gate rail's whole safety property is that a human
# can see and clear a gate from the box with no bot, no token and no network. The
# fleet-inbox row in that matrix sat at PENDING for as long as `inbox --fleet`
# errored. Accepting the flag FLIPPED it to shipped, which is what makes this
# harness owed — the parity smoke tells you so by name.
#
# The claim under test is unusual and needs stating precisely, because "it works"
# and "it is a no-op" are different assertions and only one of them is the risky
# one:
#
#   1. FLEET-WIDE BY DEFAULT (DIVE-3224). `inbox` lists every unanswered human
#      gate in the fleet, not the calling seat's. Nothing in its WHERE clause
#      mentions the caller. The arms below prove that from BOTH ends — a gate
#      owned by a seat that is not the caller is listed and its owner is named
#      (behavioural), and the predicate carries no caller-seat term (static).
#      Behavioural alone is weak here: on a one-seat fixture "the caller's gates"
#      and "the fleet's gates" are the same set, so a seat-scoped implementation
#      would pass it.
#   2. `--fleet` CHANGES NOTHING. Not merely "exits 0" — a flag that silently
#      altered the listing would be worse than the hard error it replaced. So the
#      arm compares full output, byte for byte, in both render modes.
#   3. THE ARG GATE IS STILL CLOSED. Adding one accepted flag must not widen
#      `inbox` to unknown flags or positionals; that gate is the reason a typo
#      ('--fleeet') is a loud error instead of a silently unfiltered fleet view.
#
# Deliberately NOT covered here: `--send`, which DMs the owner over Telegram and
# is therefore the one branch this file's premise excludes. It has its own
# harness (tests/task_inbox_send_unit.sh).
set -euo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${FIVEDIVE_TEST:=1}"; export FIVEDIVE_TEST
CLI="${CLI:-./5dive}"
TMP=$(mktemp -d)
# DIVE-2692 corpus contract (tests/harness_rc_corpus_contract_unit.sh): the
# HARNESS-RC echo and the tempdir cleanup share ONE trap — bash keeps only the
# last registration per signal, and `$?` must be captured BEFORE any cleanup runs.
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
# TASKS_DIR, not just TASKS_DB: `tasks_db_init` guards on the DIRECTORY and a
# non-root caller is REFUSED rather than having it created, so a harness that
# exports only TASKS_DB is green on a 5dive host (where the default dir exists)
# and red on a runner off the identical tree. Measured on this row at a0c0d29.
export STATE_DIR="$TMP"
export TASKS_DIR="$TMP/tasks"
export TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"

# TELEGRAM ABSENT — the property the parity matrix is actually about. Cleared
# rather than assumed unset: a developer's shell exports these, so an inherited
# token would make this file grade a configured host instead of a bare one.
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID FIVEDIVE_TELEGRAM_TOKEN 2>/dev/null || true
export TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""

fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
has()  { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
# One integer, always. `jq -r` on the empty string a refused command produces
# prints nothing, and `$(... || echo 0)` then yields a two-line value that reads
# as a count in a message and is not one — noticed on the negative control.
n_inbox() { local j n; j=$($CLI task inbox --fleet --json 2>/dev/null || true)
            n=$(printf '%s' "$j" | jq -r '.data.inbox|length' 2>/dev/null || true)
            case "$n" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$n";; esac; }

# ── fixture: a human gate on a row owned by a seat that is NOT the caller ────
# Seat names that belong to nobody (fixture rule: never a real identifier); the
# only property that matters is that they differ from whoever runs this harness.
FOREIGN="fleetprobe-owner"
$CLI task add "fleet inbox fixture — manual gate, foreign owner" --assignee="$FOREIGN" >/dev/null
FID=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks WHERE title LIKE 'fleet inbox fixture — manual%';")
[[ -n "$FID" ]] || { bad "fixture: could not add the foreign-owned row"; echo "-----"; exit 1; }
# tier 2 + no routed_reviewer is the "a human owes this" shape the inbox filters
# for, and --type=manual is one only a person can clear.
$CLI task need "$FID" --type=manual --tier=2 \
  --ask="fleet inbox fixture: a person must do this by hand" >/dev/null 2>&1 || true
# THE ASSIGN COMES AFTER THE NEED, AND THAT ORDER IS LOAD-BEARING. Measured:
# `task need` on an UNROUTED tier-2 row REASSIGNS it to the caller — the gate is
# a hard-human contract no routing kind may cross, so it lands on the paired
# human's seat and the `--assignee` passed to `task add` is overwritten. Setting
# the foreign owner first and asserting afterwards therefore produces a fixture
# that silently is not foreign at all, which is exactly the vacuous shape the
# next assertion exists to catch.
$CLI task assign "$FID" "$FOREIGN" >/dev/null 2>&1 || true

# The fixture must ACTUALLY be foreign, or arm 1 is vacuous — a seat-scoped
# implementation would pass it by accident. Assert the mismatch, don't assume it.
OWNER=$(sqlite3 "$TASKS_DB" "SELECT COALESCE(assignee,'') FROM tasks WHERE ident='$FID';")
SELF=$(sqlite3 "$TASKS_DB" "SELECT COALESCE(created_by,'') FROM tasks WHERE ident='$FID';")
[[ "$OWNER" == "$FOREIGN" && "$OWNER" != "$SELF" ]] \
  && ok "fixture is genuinely foreign-owned (owner=$OWNER, caller=$SELF) — arm 1 is not vacuous" \
  || bad "fixture not foreign-owned (owner='$OWNER' caller='$SELF'); the fleet-wide arms below would be vacuous"

# ── arm 1: fleet-wide by DEFAULT — the foreign gate is listed, owner named ───
BOX=$($CLI task inbox 2>/dev/null || true)
has "$FID" "$BOX" \
  && ok "bare 'task inbox' lists a gate on a row owned by another seat (fleet-wide by default)" \
  || bad "bare 'task inbox' did not list the foreign-owned gate: $(printf '%s' "$BOX" | tr '\n' '|')"
has "$FOREIGN" "$BOX" \
  && ok "the listing NAMES the owning seat (the 'owner' column DIVE-3224 added)" \
  || bad "the listing does not name the owning seat"

# ── arm 2: static — the inbox predicate carries no caller-seat scoping ───────
# Behavioural evidence cannot separate "fleet-wide" from "the fixture happens to
# be the caller's" on a small fixture, so read the query itself. `--mine`/`$SELF`
# style scoping in cmd_task_inbox's WHERE is the shape that would make the flag
# OSS-36 asked for meaningful again.
INBOX_FN=$(sed -n '/^cmd_task_inbox()/,/^}/p' src/task/inbox.sh)
[[ -n "$INBOX_FN" ]] || bad "static arm: cmd_task_inbox not found in src/task/inbox.sh (renamed?)"
if printf '%s' "$INBOX_FN" | grep -Eq 'AND[[:space:]]+assignee[[:space:]]*=|--mine'; then
  bad "cmd_task_inbox scopes its listing to a seat — 'fleet-wide by default' is no longer true, and --fleet must stop being a no-op"
else
  ok "cmd_task_inbox's listing predicate has no caller-seat term (fleet-wide by construction)"
fi

# ── arm 3: --fleet is accepted, and is BYTE-IDENTICAL to bare inbox ──────────
if FLEETBOX=$($CLI task inbox --fleet 2>&1); then
  ok "'task inbox --fleet' is accepted (it was 'error: unknown flag: --fleet' before this row)"
else
  bad "'task inbox --fleet' still errors: $(printf '%s' "$FLEETBOX" | head -1)"
fi
[[ "$FLEETBOX" == "$BOX" ]] \
  && ok "--fleet output is byte-identical to bare inbox (a true no-op, not a second filter)" \
  || bad "--fleet changed the human listing — it must be a no-op"
J1=$($CLI task inbox --json 2>/dev/null || true)
J2=$($CLI task inbox --fleet --json 2>/dev/null || true)
[[ -n "$J1" && "$J1" == "$J2" ]] \
  && ok "--fleet --json is byte-identical to --json (no-op in both render modes)" \
  || bad "--fleet --json differs from --json (or both empty)"
# Non-vacuity: the two comparisons above would also pass on two empty strings.
N=$(printf '%s' "$J1" | jq -r '.data.inbox|length' 2>/dev/null || echo 0)
[[ "${N:-0}" -ge 1 ]] \
  && ok "the compared listing is non-empty (n=$N), so the identity arms are not vacuous" \
  || bad "inbox --json listed 0 gates — every identity arm above is vacuous"

# ── arm 4: the arg gate is still closed ─────────────────────────────────────
$CLI task inbox --fleeet >/dev/null 2>&1 \
  && bad "a MISSPELLED flag was accepted — the arg gate widened, so a typo now silently returns an unfiltered view" \
  || ok "an unknown flag is still a hard error (accepting --fleet did not widen the arg gate)"
$CLI task inbox somepositional >/dev/null 2>&1 \
  && bad "a positional arg was accepted" \
  || ok "a positional arg is still a hard error"
$CLI task inbox --channel-proof=1234567890 >/dev/null 2>&1 \
  && bad "--channel-proof was accepted without --send" \
  || ok "--channel-proof still requires --send"

# ── arm 5: an ANSWERED gate LEAVES the fleet inbox ──────────────────────────
# The inverse direction, and the one that makes the listing trustworthy: a view
# that only ever grows is as useless as one that hides pending gates. A second
# fixture, because the tier-2 `manual` gate above is deliberately NOT clearable
# by an agent seat — an unrouted decision gate is the shape a headless test can
# legitimately answer, and answering the other one from here would be forging the
# human tap that tests/gate_nonce_unit.sh exists to protect.
$CLI task add "fleet inbox fixture — decision gate, foreign owner" --assignee="$FOREIGN" >/dev/null
DID=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks WHERE title LIKE 'fleet inbox fixture — decision%';")
$CLI task need "$DID" --type=decision --options="approve|revise" --recommend="approve" \
  --ask="fleet inbox fixture: approve the probe?" >/dev/null 2>&1 || true
$CLI task assign "$DID" "$FOREIGN" >/dev/null 2>&1 || true
BEFORE_N=$(n_inbox)
has "$DID" "$($CLI task inbox --fleet 2>/dev/null || true)" \
  && ok "the second foreign-owned gate is listed while PENDING (n=$BEFORE_N)" \
  || bad "the pending decision gate is missing from the fleet inbox — arm 5 cannot measure a drop"
$CLI task answer "$DID" --value="approve" >/dev/null 2>&1 || true
ANS=$(sqlite3 "$TASKS_DB" "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$DID';")
if [[ -n "$ANS" ]]; then
  ok "the gate was answered through the public CLI with Telegram absent (no token, no network)"
  AFTER=$($CLI task inbox --fleet 2>/dev/null || true)
  AFTER_N=$(n_inbox)
  has "$DID" "$AFTER" \
    && bad "an ANSWERED gate is still listed in the fleet inbox" \
    || ok "an answered gate drops out of the fleet inbox (n $BEFORE_N -> $AFTER_N)"
else
  # NOT a soft NOTE: if the CLI-only answer path stops working, the parity claim
  # this whole file certifies — a human can clear a gate with Telegram absent —
  # is what has broken, and a skipped arm would hide exactly that.
  bad "could not answer the decision gate through the CLI with Telegram absent — the Telegram-free clear path is broken, which is the property this file certifies"
fi

echo "-----"
if (( fails == 0 )); then printf 'fleet_inbox_unit: PASS\n'; else printf 'fleet_inbox_unit: %d FAILED\n' "$fails"; exit 1; fi
