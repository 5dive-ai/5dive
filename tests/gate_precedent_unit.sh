#!/usr/bin/env bash
# OSS-11 (DIVE-976) isolated unit harness for decision-memory precedent prefill.
# Two halves:
#   * _gate_ask_shape() normalizer — idents/dates/amounts/hosts/nums/quoted-names
#     collapse to typed placeholders; different targets => same shape; the shape
#     key is what precedent matching keys on.
#   * cmd_task_need precedent prefill + the DIVE-916 SAFETY INVARIANT: prefill
#     fills a BLANK recommend only (never overrides a filer rec), from an equal-
#     or-higher tier precedent, of the SAME need_type — and it NEVER mutates tier
#     nor auto-answers the gate (the clear path is untouched).
# Isolation matches the sibling harnesses: source src/ libs against a throwaway
# STATE_DIR; the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_precedent_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-precedent-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }

tasks_db_init

# Capture the citation task need hands the notifier (arg 9) instead of DMing.
NOTIFY_CITE=""
task_need_notify() { NOTIFY_CITE="${9:-}"; }
audit_log() { :; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
# Seed an ALREADY-ANSWERED precedent gate directly (bypasses the human-only clear
# path — we only need the row a lookup would find).
seed_precedent() { # <ident> <type> <tier> <shape> <answer>
  seed_task "$1"
  db "UPDATE tasks SET need_type='$2', tier=$3, ask_shape=$(sqlq "$4"),
        need_answer=$(sqlq "$5"), need_answered_at=datetime('now'),
        need_answered_by='human:mark', status='todo' WHERE ident='$1';"
}
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# ============================ shape normalizer ============================
eq_t "shape: idents collapse"            "$(_gate_ask_shape 'Deploy DIVE-100 and OSS-3 now')" \
                                         "deploy <ident> and <ident> now"
eq_t "shape: different targets => same"  "$(_gate_ask_shape 'teardown box alpha-7')" \
                                         "$(_gate_ask_shape 'teardown box beta-9')"
eq_t "shape: bare integers => <num>"     "$(_gate_ask_shape 'scale to 12 workers')" \
                                         "scale to <num> workers"
eq_t "shape: dollar amount => <amount>"  "$(_gate_ask_shape 'approve spend of $2,500 now')" \
                                         "approve spend of <amount> now"
eq_t "shape: ISO date => <date>"         "$(_gate_ask_shape 'ship on 2026-07-04')" \
                                         "ship on <date>"
eq_t "shape: host => <host>"             "$(_gate_ask_shape 'point dns at api.5dive.com')" \
                                         "point dns at <host>"
eq_t "shape: quoted name => <name>"      "$(_gate_ask_shape 'rename to "Prod East" cluster')" \
                                         "rename to <name> cluster"
# decimal must NOT be swallowed by the host rule (final label is numeric)
eq_t "shape: decimal => <num>"           "$(_gate_ask_shape 'bump to 3.5x budget')" \
                                         "bump to <num>x budget"

# ==================== precedent prefill + invariants =====================
# P0: matching precedent prefills a BLANK recommend + sets precedent_ref + cites.
SHAPE_PROD="$(_gate_ask_shape 'deploy DIVE-100 to prod')"
seed_precedent DIVE-1000 decision 1 "$SHAPE_PROD" yes
PREC_ID="$(db "SELECT id FROM tasks WHERE ident='DIVE-1000';")"
seed_task DIVE-1001
NOTIFY_CITE=""
cmd_task_need DIVE-1001 --type=decision --ask="deploy DIVE-100 to prod" --options="yes|no" >/dev/null 2>&1
eq_t "prefill: blank recommend filled from precedent" "$(field DIVE-1001 recommend)" "yes"
eq_t "prefill: precedent_ref recorded"                "$(field DIVE-1001 precedent_ref)" "$PREC_ID"
if [[ -n "$NOTIFY_CITE" ]]; then ok_t "prefill: citation handed to notifier"; else bad_t "prefill: citation handed to notifier" "empty"; fi

# INV1: prefill NEVER mutates tier (decision defaults to tier 1, unchanged).
eq_t "invariant: tier not mutated by prefill" "$(field DIVE-1001 tier)" "1"

# INV2: fill-blank-ONLY — an explicit filer recommend is never overridden.
seed_task DIVE-1002
cmd_task_need DIVE-1002 --type=decision --ask="deploy DIVE-200 to prod" --options="yes|no" --recommend="no" >/dev/null 2>&1
eq_t "invariant: filer recommend not overridden" "$(field DIVE-1002 recommend)" "no"

# INV3: different need_type NEVER matches (approval gate, same shape, no prefill).
seed_task DIVE-1003
cmd_task_need DIVE-1003 --type=approval --ask="deploy DIVE-300 to prod" >/dev/null 2>&1
eq_t "invariant: cross-type never matches (recommend blank)" "$(field DIVE-1003 recommend)" "∅"
eq_t "invariant: cross-type never matches (precedent_ref null)" "$(field DIVE-1003 precedent_ref)" "∅"

# INV4: tier(P) >= tier(G) — a lower-tier precedent can't prefill a higher gate.
SHAPE_LOW="$(_gate_ask_shape 'rotate the DIVE-1 worker pool')"
seed_precedent DIVE-1010 decision 0 "$SHAPE_LOW" yes
seed_task DIVE-1011
cmd_task_need DIVE-1011 --type=decision --ask="rotate the DIVE-2 worker pool" --options="yes|no" >/dev/null 2>&1
eq_t "invariant: lower-tier precedent rejected (blank)" "$(field DIVE-1011 recommend)" "∅"

# INV5: precedent NEVER auto-answers — an approval gate stays blocked/unanswered
# even when a matching precedent prefills its recommend (the clear path is untouched).
SHAPE_APP="$(_gate_ask_shape 'grant DIVE-50 admin access')"
seed_precedent DIVE-1020 approval 2 "$SHAPE_APP" approved
seed_task DIVE-1021
cmd_task_need DIVE-1021 --type=approval --ask="grant DIVE-60 admin access" >/dev/null 2>&1
eq_t "invariant: precedent prefills approval rec"      "$(field DIVE-1021 recommend)" "approved"
eq_t "invariant: precedent does NOT auto-answer"       "$(field DIVE-1021 need_answered_at)" "∅"
eq_t "invariant: gate still blocked (needs human)"     "$(field DIVE-1021 status)" "blocked"

# INV6: decision option-mismatch — precedent cites but does NOT prefill a rec that
# isn't one of THIS gate's options (a shown rec must map to a real option).
SHAPE_PICK="$(_gate_ask_shape 'pick a region for DIVE-70')"
seed_precedent DIVE-1030 decision 1 "$SHAPE_PICK" yes
seed_task DIVE-1031
cmd_task_need DIVE-1031 --type=decision --ask="pick a region for DIVE-80" --options="approve|reject" >/dev/null 2>&1
eq_t "invariant: option-mismatch skips prefill" "$(field DIVE-1031 recommend)" "∅"
eq_t "invariant: option-mismatch still cites"   "$(field DIVE-1031 precedent_ref)" "$(db "SELECT id FROM tasks WHERE ident='DIVE-1030';")"

# EXACT match kind is recorded on the exact path (P0 gate DIVE-1001 above).
eq_t "kind: exact match recorded"               "$(field DIVE-1001 precedent_kind)" "exact"

# ======================= OSS-20 fuzzy shape fallback =====================
# _gate_shape_jaccard(): token-set Jaccard as an integer percent.
eq_t "jaccard: identical => 100"  "$(_gate_shape_jaccard 'a b c' 'a b c')"     "100"
eq_t "jaccard: disjoint => 0"     "$(_gate_shape_jaccard 'a b c' 'x y z')"     "0"
eq_t "jaccard: empty side => 0"   "$(_gate_shape_jaccard '' 'a b c')"          "0"
eq_t "jaccard: 4/5 => 80 (thresh)" "$(_gate_shape_jaccard 'a b c d' 'a b c d e')" "80"
eq_t "jaccard: dup-insensitive"   "$(_gate_shape_jaccard 'a a b c' 'a b c')"   "100"

# F1: exact MISS but a paraphrase at Jaccard>=0.8 fuzzy-prefills + tags kind=fuzzy.
# Precedent shape has 5 tokens; the gate adds one word (6 tokens) => 5/6 = 0.83.
SHAPE_ARCH="$(_gate_ask_shape 'archive the stale sandbox namespaces')"
seed_precedent DIVE-1040 decision 1 "$SHAPE_ARCH" yes
FZ_ID="$(db "SELECT id FROM tasks WHERE ident='DIVE-1040';")"
seed_task DIVE-1041
NOTIFY_CITE=""
cmd_task_need DIVE-1041 --type=decision --ask="archive the stale sandbox namespaces please" --options="yes|no" >/dev/null 2>&1
# Guard: the paraphrase really is an EXACT miss (shapes differ) so this exercises fuzzy.
if [[ "$(field DIVE-1041 ask_shape)" != "$SHAPE_ARCH" ]]; then ok_t "fuzzy: paraphrase is an exact-shape miss"; else bad_t "fuzzy: paraphrase is an exact-shape miss" "shapes collided"; fi
eq_t "fuzzy: blank recommend filled from paraphrase" "$(field DIVE-1041 recommend)" "yes"
eq_t "fuzzy: precedent_ref recorded"                 "$(field DIVE-1041 precedent_ref)" "$FZ_ID"
eq_t "fuzzy: precedent_kind=fuzzy"                    "$(field DIVE-1041 precedent_kind)" "fuzzy"
if [[ -n "$NOTIFY_CITE" ]]; then ok_t "fuzzy: citation handed to notifier"; else bad_t "fuzzy: citation handed to notifier" "empty"; fi

# F2: fuzzy NEVER auto-answers — the clear path stays exact-only (OSS-21). A
# tier-1 decision fuzzy hit prefills a rec but the gate stays blocked/unanswered.
eq_t "fuzzy: does NOT auto-answer"  "$(field DIVE-1041 need_answered_at)" "∅"
eq_t "fuzzy: gate still blocked"    "$(field DIVE-1041 status)"           "blocked"
eq_t "fuzzy: tier not mutated"      "$(field DIVE-1041 tier)"             "1"

# F3: below-threshold paraphrase (Jaccard<0.8) does NOT match — no prefill/ref/kind.
seed_task DIVE-1042
cmd_task_need DIVE-1042 --type=decision --ask="archive the stale sandbox namespaces now please immediately today" --options="yes|no" >/dev/null 2>&1
eq_t "fuzzy: sub-threshold no prefill"       "$(field DIVE-1042 recommend)"      "∅"
eq_t "fuzzy: sub-threshold no precedent_ref" "$(field DIVE-1042 precedent_ref)" "∅"
eq_t "fuzzy: sub-threshold no kind"          "$(field DIVE-1042 precedent_kind)" "∅"

# F4: fuzzy respects tier gating — a lower-tier precedent can't fuzzy-prefill up.
SHAPE_PURGE="$(_gate_ask_shape 'purge the orphaned build artifacts')"
seed_precedent DIVE-1050 decision 0 "$SHAPE_PURGE" yes
seed_task DIVE-1051
cmd_task_need DIVE-1051 --type=decision --ask="purge the orphaned build artifacts please" --options="yes|no" >/dev/null 2>&1
eq_t "fuzzy: lower-tier precedent rejected" "$(field DIVE-1051 recommend)"      "∅"
eq_t "fuzzy: lower-tier no kind"            "$(field DIVE-1051 precedent_kind)" "∅"

# F5: fuzzy honours the decision option-check — cites but does NOT prefill a rec
# that isn't one of THIS gate's options.
seed_task DIVE-1052
cmd_task_need DIVE-1052 --type=decision --ask="archive the stale sandbox namespaces asap" --options="approve|reject" >/dev/null 2>&1
eq_t "fuzzy: option-mismatch skips prefill" "$(field DIVE-1052 recommend)"      "∅"
eq_t "fuzzy: option-mismatch still cites"   "$(field DIVE-1052 precedent_ref)" "$FZ_ID"
eq_t "fuzzy: option-mismatch kind=fuzzy"    "$(field DIVE-1052 precedent_kind)" "fuzzy"

# ============================ OSS-21 auto-clear ============================
# Auto-clear is behind the precedent_autoclear pref (default OFF) and keys on
# EXACT human precedent only. Seed a human precedent at a chosen age (minutes ago)
# so "most recent qualifying gate" is deterministic; seed_prec_by sets an
# arbitrary provenance to prove the human-only / no-compounding seed rules.
seed_human_prec_age() { # <ident> <type> <tier> <shape> <answer> <min-ago>
  seed_task "$1"
  db "UPDATE tasks SET need_type='$2', tier=$3, ask_shape=$(sqlq "$4"),
        need_answer=$(sqlq "$5"), need_answered_at=datetime('now','-$6 minute'),
        need_answered_by='human:mark', status='todo' WHERE ident='$1';"
}
seed_prec_by() { # <ident> <type> <tier> <shape> <answer> <answered_by>
  seed_task "$1"
  db "UPDATE tasks SET need_type='$2', tier=$3, ask_shape=$(sqlq "$4"),
        need_answer=$(sqlq "$5"), need_answered_at=datetime('now'),
        need_answered_by=$(sqlq "$6"), status='todo' WHERE ident='$1';"
}

ASK_AC="restart the worker pool on box gamma"
SHAPE_AC="$(_gate_ask_shape "$ASK_AC")"

# A0: pref OFF (default) — 2 human precedents but the gate still surfaces (v1).
seed_human_prec_age DIVE-1200 decision 1 "$SHAPE_AC" yes 10
seed_human_prec_age DIVE-1201 decision 1 "$SHAPE_AC" yes 5
seed_task DIVE-1202
cmd_task_need DIVE-1202 --type=decision --ask="$ASK_AC" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear OFF: gate stays blocked"  "$(field DIVE-1202 status)"           "blocked"
eq_t "autoclear OFF: not auto-answered"   "$(field DIVE-1202 need_answered_at)" "∅"

# Flip the pref ON for the qualifying cases.
cmd_task_precedent on >/dev/null 2>&1
eq_t "pref: precedent on persists" "$(_task_pref_get precedent_autoclear)" "on"

# A1: qualifying — 2 distinct human gates, identical answer => clears at file-time
# via auto:precedent, precedent_ref = most-recent (DIVE-1201).
ID_1201="$(db "SELECT id FROM tasks WHERE ident='DIVE-1201';")"
seed_task DIVE-1203
cmd_task_need DIVE-1203 --type=decision --ask="$ASK_AC" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A1: status flipped to todo"   "$(field DIVE-1203 status)"          "todo"
eq_t "autoclear A1: answer applied"           "$(field DIVE-1203 need_answer)"     "yes"
eq_t "autoclear A1: provenance auto:precedent" "$(field DIVE-1203 need_answered_by)" "auto:precedent"
eq_t "autoclear A1: precedent_ref = newest"   "$(field DIVE-1203 precedent_ref)"   "$ID_1201"
eq_t "autoclear A1: precedent_kind exact"     "$(field DIVE-1203 precedent_kind)"  "exact"

# A2: contradiction — two human gates with DIFFERENT answers => never auto-clears.
ASK_CON="compact the analytics table nightly"; SHAPE_CON="$(_gate_ask_shape "$ASK_CON")"
seed_human_prec_age DIVE-1210 decision 1 "$SHAPE_CON" yes 10
seed_human_prec_age DIVE-1211 decision 1 "$SHAPE_CON" no  5
seed_task DIVE-1212
cmd_task_need DIVE-1212 --type=decision --ask="$ASK_CON" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A2: contradiction blocks"     "$(field DIVE-1212 status)"           "blocked"
eq_t "autoclear A2: contradiction unanswered" "$(field DIVE-1212 need_answered_at)" "∅"

# A3: agent-answered seeds never qualify (human-only), even if unanimous.
ASK_AG="rebuild the search index"; SHAPE_AG="$(_gate_ask_shape "$ASK_AG")"
seed_prec_by DIVE-1220 decision 1 "$SHAPE_AG" yes "agent:dev"
seed_prec_by DIVE-1221 decision 1 "$SHAPE_AG" yes "agent:dev"
seed_task DIVE-1222
cmd_task_need DIVE-1222 --type=decision --ask="$ASK_AG" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A3: agent seed blocks"        "$(field DIVE-1222 status)"           "blocked"
eq_t "autoclear A3: agent seed unanswered"    "$(field DIVE-1222 need_answered_at)" "∅"

# A4: auto-answered seeds never qualify (no compounding).
ASK_AU="prune expired cache entries"; SHAPE_AU="$(_gate_ask_shape "$ASK_AU")"
seed_prec_by DIVE-1230 decision 1 "$SHAPE_AU" yes "auto:ttl"
seed_prec_by DIVE-1231 decision 1 "$SHAPE_AU" yes "auto:precedent"
seed_task DIVE-1232
cmd_task_need DIVE-1232 --type=decision --ask="$ASK_AU" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A4: auto seed blocks"         "$(field DIVE-1232 status)"           "blocked"
eq_t "autoclear A4: auto seed unanswered"     "$(field DIVE-1232 need_answered_at)" "∅"

# A5: T2 never auto-clears — an approval gate defaults tier 2, ineligible.
ASK_T2="approve the migration runbook"; SHAPE_T2="$(_gate_ask_shape "$ASK_T2")"
seed_prec_by DIVE-1240 approval 2 "$SHAPE_T2" approved "human:mark"
seed_prec_by DIVE-1241 approval 2 "$SHAPE_T2" approved "human:mark"
seed_task DIVE-1242
cmd_task_need DIVE-1242 --type=approval --ask="$ASK_T2" >/dev/null 2>&1
eq_t "autoclear A5: T2 tier unchanged"        "$(field DIVE-1242 tier)"             "2"
eq_t "autoclear A5: T2 stays blocked"         "$(field DIVE-1242 status)"           "blocked"
eq_t "autoclear A5: T2 unanswered"            "$(field DIVE-1242 need_answered_at)" "∅"

# A6: secret never auto-clears (excluded by guard AND floored to T2).
ASK_SEC="load the staging deploy key"; SHAPE_SEC="$(_gate_ask_shape "$ASK_SEC")"
seed_prec_by DIVE-1250 secret 1 "$SHAPE_SEC" done "human:mark"
seed_prec_by DIVE-1251 secret 1 "$SHAPE_SEC" done "human:mark"
seed_task DIVE-1252
cmd_task_need DIVE-1252 --type=secret --ask="$ASK_SEC" >/dev/null 2>&1
eq_t "autoclear A6: secret stays blocked"     "$(field DIVE-1252 status)"           "blocked"
eq_t "autoclear A6: secret unanswered"        "$(field DIVE-1252 need_answered_at)" "∅"

# A7: decision consensus that isn't a current option => falls through to human.
ASK_OPT="cordon the flaky node"; SHAPE_OPT="$(_gate_ask_shape "$ASK_OPT")"
seed_human_prec_age DIVE-1260 decision 1 "$SHAPE_OPT" yes 10
seed_human_prec_age DIVE-1261 decision 1 "$SHAPE_OPT" yes 5
seed_task DIVE-1262
cmd_task_need DIVE-1262 --type=decision --ask="$ASK_OPT" --options="approve|reject" >/dev/null 2>&1
eq_t "autoclear A7: off-menu answer blocks"   "$(field DIVE-1262 status)"           "blocked"
eq_t "autoclear A7: off-menu unanswered"      "$(field DIVE-1262 need_answered_at)" "∅"

# A9: fuzzy-prefilled human answers never seed auto-clear (OSS-21: main's exact-only
# rule). Two human-answered gates on the exact shape, but each was itself prefilled
# via the OSS-20 fuzzy fallback (precedent_kind='fuzzy'). They'd otherwise qualify —
# the fuzzy filter must keep the new gate blocked so fuzzy can't leak into auto-clear.
seed_fuzzy_human() { # <ident> <type> <tier> <shape> <answer> <min-ago>
  seed_task "$1"
  db "UPDATE tasks SET need_type='$2', tier=$3, ask_shape=$(sqlq "$4"),
        need_answer=$(sqlq "$5"), need_answered_at=datetime('now','-$6 minute'),
        need_answered_by='human:mark', precedent_kind='fuzzy', status='todo' WHERE ident='$1';"
}
ASK_FZ="drain the standby replica"; SHAPE_FZ="$(_gate_ask_shape "$ASK_FZ")"
seed_fuzzy_human DIVE-1270 decision 1 "$SHAPE_FZ" yes 10
seed_fuzzy_human DIVE-1271 decision 1 "$SHAPE_FZ" yes 5
seed_task DIVE-1272
cmd_task_need DIVE-1272 --type=decision --ask="$ASK_FZ" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A9: fuzzy seed blocks"       "$(field DIVE-1272 status)"           "blocked"
eq_t "autoclear A9: fuzzy seed unanswered"   "$(field DIVE-1272 need_answered_at)" "∅"

# A8: pref OFF again restores exact v1 behaviour on a would-qualify gate.
cmd_task_precedent off >/dev/null 2>&1
eq_t "pref: precedent off persists" "$(_task_pref_get precedent_autoclear)" "off"
seed_task DIVE-1263
cmd_task_need DIVE-1263 --type=decision --ask="$ASK_AC" --options="yes|no" >/dev/null 2>&1
eq_t "autoclear A8: OFF re-blocks qualifier"  "$(field DIVE-1263 status)"           "blocked"
eq_t "autoclear A8: OFF unanswered"           "$(field DIVE-1263 need_answered_at)" "∅"

echo "-------------------------------------"
echo "gate_precedent_unit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
