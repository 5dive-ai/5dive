#!/usr/bin/env bash
# DIVE-2124 — `5dive org set` / `org rm` had NO authorization check of any kind, and
# the usage text advertised it: "Any agent (group claude) can run these without sudo."
# Measured live before the fix: `sudo -u agent-dev 5dive org set testprobe-2099
# --manager=dev` returned OK and the row landed in agents_org.
#
# WHY THIS IS NOT BOOKKEEPING. agents_org.reports_to is TRUSTED INPUT to gate routing:
# _gate_route_reviewer(filer) resolves a builder's gate reviewer from it. An agent able
# to set its OWN reports_to picks who reviews the gates it files — a self-grant on the
# authority path. routed_reviewer is stamped at filing time, which bounds the damage to
# gates already filed, but the resolution is live AT filing and any future live
# resolution inherits the hole. The write side is where the class ends.
#
# What is pinned here:
#   1. an unprivileged caller is REFUSED on `org set` and on `org rm`
#   2. the refusal happens BEFORE any write — a refused call leaves no row behind
#   3. `rm` is gated too, or the guard is bypassed by rm-then-set
#   4. READS stay open — agents must still be able to see the chart
#   5. the privileged path still works (require_root satisfied)
# Run: bash tests/org_write_authz_unit.sh  (must be run UNPRIVILEGED)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/org-authz-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
audit_log() { return 0; }
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
placed() { db "SELECT COUNT(*) FROM agents_org WHERE name=$(sqlq "$1");"; }
mgr_of() { db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$1");"; }

# The refusal arms are only meaningful unprivileged. Running as root would make them
# pass for the wrong reason — a vacuous green is worse than a red, so say so instead.
if (( EUID == 0 )); then
  bad_t "this suite must run UNPRIVILEGED — as root the refusal arms cannot be exercised at all"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# --- 1. THE HOLE: an unprivileged caller must be REFUSED on `org set` ----------
out=$( ( cmd_org_set probe-2124 --manager=dev ) 2>&1 ); rc=$?
(( rc != 0 )) \
  && ok_t "an unprivileged caller is REFUSED by 'org set' (was: returned OK and wrote the row)" \
  || bad_t "org set must refuse unprivileged" "rc=$rc out=$out"
grep -qi 'root' <<<"$out" \
  && ok_t "...and the refusal says what is required, so the caller knows the fix" \
  || bad_t "refusal must name the requirement" "$out"

# --- 2. REFUSED MEANS NOTHING WAS WRITTEN -------------------------------------
# A guard that refuses AFTER the UPDATE is not a guard. This is the assertion that
# would catch require_root being placed below the db write.
[[ "$(placed probe-2124)" == "0" ]] \
  && ok_t "a refused 'org set' leaves NO row behind (the guard runs before the write)" \
  || bad_t "refused call still wrote" "rows=$(placed probe-2124)"

# --- 3. `rm` IS GATED TOO, or the guard is bypassed by rm-then-set ------------
# Seed a row through the privileged path so there is something real to try to delete.
require_root() { :; }                       # stand in for root for setup only
( cmd_org_set victim-2124 --manager=dev ) >/dev/null 2>&1
# RE-SOURCE to restore the real guard. `unset -f` does NOT restore a shadowed sourced
# function — it deletes it outright, and a MISSING require_root fails OPEN here
# (command-not-found is non-fatal without set -e, so the write proceeds). That is the
# DIVE-2072 shape, and it cost two false reds in this very harness before it was
# spotted: the arms went red reporting "require_root: command not found", which reads
# like the guard rejecting when it was actually absent.
# shellcheck source=/dev/null
source "$SRC/lib/validation.sh"
[[ "$(placed victim-2124)" == "1" ]] \
  && ok_t "setup: the privileged path still writes (the guard blocks callers, not the feature)" \
  || bad_t "privileged write failed" "rows=$(placed victim-2124)"
out=$( ( cmd_org_rm victim-2124 ) 2>&1 ); rc=$?
(( rc != 0 )) && [[ "$(placed victim-2124)" == "1" ]] \
  && ok_t "an unprivileged 'org rm' is REFUSED and the row survives (no rm-then-set bypass)" \
  || bad_t "org rm must refuse unprivileged" "rc=$rc rows=$(placed victim-2124) out=$out"

# --- 4. an unprivileged caller cannot RE-PARENT ITSELF ------------------------
# The concrete exploit: set my own reports_to, then file a gate that routes to a
# reviewer I chose. Pinned as its own arm because it is the reason this is security
# and not tidiness.
out=$( ( cmd_org_set victim-2124 --manager=attacker-2124 ) 2>&1 ); rc=$?
(( rc != 0 )) && [[ "$(mgr_of victim-2124)" == "dev" ]] \
  && ok_t "an unprivileged caller cannot RETARGET an existing reports_to edge (the gate-routing self-grant)" \
  || bad_t "reports_to must not be rewritable unprivileged" "rc=$rc mgr=$(mgr_of victim-2124)"

# --- 5. READS STAY OPEN -------------------------------------------------------
# Agents need the chart to route work; it is writing it that is privileged. If this
# arm ever goes red the fix over-corrected.
for verb in cmd_org_ls cmd_org_tree; do
  ( "$verb" ) >/dev/null 2>&1
  (( $? == 0 )) && ok_t "read verb '${verb#cmd_org_}' still works unprivileged" \
                || bad_t "read verb ${verb#cmd_org_} must stay open" "rc=$?"
done
( cmd_org_show victim-2124 ) >/dev/null 2>&1
(( $? == 0 )) && ok_t "read verb 'show' still works unprivileged" || bad_t "show must stay open" ""

# --- 6. STRUCTURAL: the guard is present in BOTH write verbs ------------------
# Cheap and it catches the guard being dropped in a refactor even if some future arm
# stops exercising it (same idiom as tests/agent_isolation_unit.sh).
for fn in cmd_org_set cmd_org_rm; do
  if declare -f "$fn" | grep -q 'require_root'; then
    ok_t "$fn carries an explicit require_root"
  else
    bad_t "$fn lost its require_root" "a write verb with no authorization check is the DIVE-2124 defect"
  fi
done
# ...and the usage text must not still advertise the hole.
if _org_usage 2>&1 | grep -qi 'any agent.*without sudo'; then
  bad_t "the usage text still advertises unauthenticated writes" "it read: 'Any agent (group claude) can run these without sudo.'"
else
  ok_t "the usage text no longer advertises unauthenticated writes"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
