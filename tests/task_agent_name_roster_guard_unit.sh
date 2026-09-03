#!/usr/bin/env bash
# DIVE-3344 — `assignee` / `created_by` / `verifier` must NAME A REAL AGENT.
#
# The reported symptom is silence: a row assigned to a name that is not a
# registered agent is never dispatched, and nothing anywhere says so. So the
# thing this harness has to prove is not "a valid name is accepted" — today's
# code passes that test, which is why the ticket asks for a NEGATIVE CONTROL
# THAT CAN FAIL. The load-bearing arms are:
#
#   T1  `--assignee=agent-dev` on a board whose real lane is `dev` is REFUSED,
#       and the refusal NAMES `dev`. Prefix drift is the measured common case
#       (9 `agent-main` + 2 `agent-marketing` rows on the reporting board) and a
#       bare "unknown agent" gets worked around by re-typing the same name.
#   T5  `--from=cli` is ACCEPTED. `cli` is lib/actor.sh's documented sentinel for
#       an invocation it could not attribute (root, cron, a build bot); 25 rows
#       carry it by design. The ticket asked for "the same validation on
#       created_by" and the same validation would refuse every root/cron filing.
#   T0  with NO registry the guard REFUSES NOTHING — and this arm runs FIRST, so
#       every refusal below is known to come from the roster rather than from
#       some unrelated validation. An unarmed guard and a passing one print the
#       same thing; this is what separates them.
#   MUT the same tree with the two guard calls stripped ACCEPTS what T1/T7 refuse.
#       Without it a green run cannot distinguish "the guard works" from "the
#       fixture never reached it".
#
# Run: bash tests/task_agent_name_roster_guard_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/task-roster-guard-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
REGISTRY="$STATE_DIR/agents.json"
TASKS_DIR="$STATE_DIR/tasks"
# shellcheck disable=SC2034  # consumed by the sourced DB helpers
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The roster is memoised per process (same shape as actor.sh's registry memo), so
# every arm that changes the fixture has to drop the cache first.
roster_reset() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; _TASK_ROSTER_WARNED=""; }

write_roster() {   # write_roster name...
  local n j='{"agents":{'  first=1
  for n in "$@"; do
    [[ $first == 1 ]] || j+=','
    j+="\"$n\":{\"type\":\"claude\"}"; first=0
  done
  printf '%s}}\n' "$j" > "$REGISTRY"
  roster_reset
}

tasks_db_init

# ---------------------------------------------------------------------------
# T0 — ARMING CONTROL, and it runs first on purpose. No registry file at all:
# registry_read_checked returns 3, the roster is `unestablished:no-registry-file`
# and NOTHING is refused. This is the fresh-install and unit-harness case; a guard
# that treated an unreadable roster as an empty one would refuse every name on the
# board, which is a louder way of being wrong than the bug it replaces.
# ---------------------------------------------------------------------------
rm -f "$REGISTRY"; roster_reset
out=$(cmd_task_add "T0 unarmed" --assignee=definitelynotanagent 2>&1); rc=$?
[[ "$rc" == "0" ]] \
  && ok_t "T0a no registry -> the guard refuses nothing (fail-open, not fail-closed)" \
  || bad_t "T0a unarmed add" "rc=$rc :: $out"
_task_roster
[[ "$_TASK_ROSTER_STATE" == "unestablished:no-registry-file" ]] \
  && ok_t "T0b the state SAYS it could not measure ('$_TASK_ROSTER_STATE'), not 'empty'" \
  || bad_t "T0b roster state" "got '$_TASK_ROSTER_STATE'"

# An UNPARSEABLE registry is a different fact from an absent one, and it is the
# one that warrants a line on stderr: absent is normal, corrupt is a defect.
printf 'not json at all' > "$REGISTRY"; roster_reset
out=$(cmd_task_add "T0 corrupt" --assignee=definitelynotanagent 2>&1); rc=$?
[[ "$rc" == "0" && "$out" == *"validation SKIPPED"* && "$out" == *"unparseable"* ]] \
  && ok_t "T0c a CORRUPT registry accepts the name but SAYS the guard did not run" \
  || bad_t "T0c corrupt registry note" "rc=$rc :: $out"

# ---------------------------------------------------------------------------
# From here the roster is real. `dev`,`dev2`,`dev3` are deliberately present so
# the near-miss suggester has an ambiguous neighbourhood to stay quiet in (T9).
# ---------------------------------------------------------------------------
write_roster dev dev2 dev3 main marketing quinn

# T1 — THE NEGATIVE CONTROL THE TICKET ASKS FOR.
out=$(cmd_task_add "T1 prefix drift" --assignee=agent-dev 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" ]] \
  && ok_t "T1a --assignee=agent-dev is REFUSED, not accepted as a distinct lane" \
  || bad_t "T1a agent-<realname> refusal" "rc=$rc want=$E_VALIDATION :: $out"
[[ "$out" == *"did you mean 'dev'"* ]] \
  && ok_t "T1b the refusal NAMES the near miss (dev)" \
  || bad_t "T1b near-miss named" "$out"
[[ "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='agent-dev';")" == "0" ]] \
  && ok_t "T1c and it wrote NO row — refused before the insert" \
  || bad_t "T1c no-write contract" "a row landed on agent-dev"

# T2 — the real lane still works. (On its own this proves nothing; it is here so a
# regression that refuses EVERYTHING is not mistaken for a passing guard.)
out=$(cmd_task_add "T2 real lane" --assignee=dev 2>&1); rc=$?
[[ "$rc" == "0" ]] \
  && ok_t "T2 a registered agent is accepted" \
  || bad_t "T2 valid assignee" "rc=$rc :: $out"

# T3 — the sentinel as an OWNER. Refused, with its own message: "not a registered
# agent" would read as a contradiction to anyone who has seen `cli` in created_by.
out=$(cmd_task_add "T3 sentinel owner" --assignee=cli 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" && "$out" == *"actor sentinel"* ]] \
  && ok_t "T3 --assignee=cli refused AS A SENTINEL, not as an unknown name" \
  || bad_t "T3 sentinel-as-owner" "rc=$rc :: $out"

# T4 — created_by drift: the class that MISROUTES rather than drops.
out=$(cmd_task_add "T4 creator drift" --from=agent-main 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" && "$out" == *"did you mean 'main'"* ]] \
  && ok_t "T4 --from=agent-main refused and names 'main'" \
  || bad_t "T4 creator prefix drift" "rc=$rc :: $out"

# T5 — THE SPLIT. Same name, other column, opposite verdict.
out=$(cmd_task_add "T5 sentinel creator" --from=cli 2>&1); rc=$?
[[ "$rc" == "0" ]] \
  && ok_t "T5a --from=cli ACCEPTED — the sentinel is legal as a creator (root/cron)" \
  || bad_t "T5a sentinel creator" "rc=$rc :: $out"
out=$(cmd_task_add "T5 council creator" --from=council 2>&1); rc=$?
[[ "$rc" == "0" ]] \
  && ok_t "T5b --from=council accepted (relay principal, no lane)" \
  || bad_t "T5b council creator" "rc=$rc :: $out"
out=$(cmd_task_add "T5 trigger creator" --from=trigger 2>&1); rc=$?
[[ "$rc" == "0" ]] \
  && ok_t "T5c --from=trigger accepted (signed event ingress principal, no lane)" \
  || bad_t "T5c trigger creator" "rc=$rc :: $out"
out=$(cmd_task_add "T5 junk creator" --from=notdevx 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" ]] \
  && ok_t "T5d a creator that is neither lane nor sentinel is still refused" \
  || bad_t "T5d junk creator" "rc=$rc :: $out"

# T6 — --verifier is a dispatch target too (delivering writes assignee=verifier).
out=$(cmd_task_add "T6 verifier drift" --assignee=dev --verifier=agent-quinn 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" && "$out" == *"did you mean 'quinn'"* ]] \
  && ok_t "T6 --verifier=agent-quinn refused at add time" \
  || bad_t "T6 verifier at add" "rc=$rc :: $out"

# T7 — `task assign`, the raw reassignment verb: it can move a LIVE row onto a
# dead lane, which is the shape that cannot be recovered by the machine.
db "INSERT INTO tasks (ident,title,status,assignee,created_by,kind)
    VALUES ('DIVE-7001','T7 row','todo','dev','dev','standard');"
out=$(cmd_task_assign DIVE-7001 agent-dev 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" ]] \
  && ok_t "T7a task assign DIVE-7001 agent-dev is refused" \
  || bad_t "T7a assign refusal" "rc=$rc :: $out"
[[ "$(db "SELECT assignee FROM tasks WHERE ident='DIVE-7001';")" == "dev" ]] \
  && ok_t "T7b the live row kept its owner (no partial write)" \
  || bad_t "T7b assign no-write" "assignee moved"
out=$(cmd_task_assign DIVE-7001 quinn 2>&1); rc=$?
[[ "$rc" == "0" && "$(db "SELECT assignee FROM tasks WHERE ident='DIVE-7001';")" == "quinn" ]] \
  && ok_t "T7c a real reassignment still lands" \
  || bad_t "T7c assign valid" "rc=$rc :: $out"

# T8 — `task verifier` on an already-filed row.
out=$(cmd_task_verifier DIVE-7001 agent-main 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" && "$out" == *"did you mean 'main'"* ]] \
  && ok_t "T8 task verifier refuses agent-main and names main" \
  || bad_t "T8 verifier verb" "rc=$rc :: $out"

# T9 — the suggester STAYS QUIET when it would be guessing. `de` is contained in
# dev, dev2 and dev3; naming one of three is a guess dressed as help.
out=$(cmd_task_add "T9 ambiguous" --assignee=de 2>&1); rc=$?
[[ "$rc" == "$E_VALIDATION" ]] \
  && ok_t "T9a an ambiguous name is still refused" \
  || bad_t "T9a ambiguous refused" "rc=$rc :: $out"
[[ "$out" != *"did you mean"* ]] \
  && ok_t "T9b …with NO suggestion — three candidates is not a near miss" \
  || bad_t "T9b suggester guessed" "$out"

# ---------------------------------------------------------------------------
# T10 — THE SURFACER. Prevention does nothing for the rows already there, and
# those are the reported symptom. Seeded by raw SQL, which is how they arrive in
# real life too (a write path that predates the guard).
# ---------------------------------------------------------------------------
db "INSERT INTO tasks (ident,title,status,assignee,created_by,kind)
    VALUES ('DIVE-7002','T10 orphan owner','todo','cli','dev','standard'),
           ('DIVE-7003','T10 sentinel creator','todo','dev','cli','standard'),
           ('DIVE-7004','T10 drifted creator','todo','dev','agent-marketing','standard'),
           ('DIVE-7005','T10 clean row','todo','dev','dev','standard');"
roster_reset
out=$(JSON_MODE=0 cmd_task_orphans 2>&1); rc=$?
[[ "$out" == *"DIVE-7002"* ]] \
  && ok_t "T10a orphans lists the row whose ASSIGNEE is not a lane" \
  || bad_t "T10a assignee orphan listed" "$out"
[[ "$out" == *"DIVE-7004"* ]] \
  && ok_t "T10b …and the row whose CREATOR drifted (the gate-misrouting class)" \
  || bad_t "T10b creator orphan listed" "$out"
[[ "$out" != *"DIVE-7003"* ]] \
  && ok_t "T10c …and NOT created_by='cli' — the sentinel is not an orphan" \
  || bad_t "T10c sentinel creator flagged as orphan" "$out"
[[ "$out" != *"DIVE-7005"* ]] \
  && ok_t "T10d …and not the clean row" \
  || bad_t "T10d clean row flagged" "$out"
[[ "$out" == *"did you mean 'marketing'"* ]] \
  && ok_t "T10e the listing carries the same near-miss the refusal does" \
  || bad_t "T10e surfacer near-miss" "$out"

# T11 — and it REFUSES TO ANSWER rather than print the whole board as broken.
rm -f "$REGISTRY"; roster_reset
out=$(cmd_task_orphans 2>&1); rc=$?
[[ "$rc" != "0" && "$out" != *"DIVE-7005"* ]] \
  && ok_t "T11 with no roster, orphans refuses instead of calling every row an orphan" \
  || bad_t "T11 orphans without a roster" "rc=$rc :: $out"

# T12 — the WIP-cap installer reads the same column, and it minted `wip_cap:cli`.
write_roster dev dev2 dev3 main marketing quinn
out=$(JSON_MODE=0 cmd_task_wip_cap_install 2>&1); rc=$?
[[ "$(db "SELECT COUNT(*) FROM task_prefs WHERE key='wip_cap:cli';")" == "0" ]] \
  && ok_t "T12a no cap installed for the fake lane 'cli'" \
  || bad_t "T12a wip_cap:cli minted" "$out"
[[ "$out" == *"skipped"* && "$out" == *"cli"* ]] \
  && ok_t "T12b …and the skip is NAMED, not silent" \
  || bad_t "T12b skip named" "$out"
[[ "$(db "SELECT COUNT(*) FROM task_prefs WHERE key='wip_cap:dev';")" == "1" ]] \
  && ok_t "T12c the real lane still got its cap" \
  || bad_t "T12c real lane capped" "$out"

# ---------------------------------------------------------------------------
# T13 — THE ROSTER IS READ FROM STATE_DIR, NOT FROM THE SOURCE-TIME $REGISTRY.
# header.sh binds REGISTRY once when it is sourced, and ~60 harnesses repoint
# STATE_DIR afterwards; a guard that kept the stale global graded a scratch board
# against the HOST's live fleet and turned 16 unrelated harnesses red. This arm
# pins the coupling so a refactor back to the global is a RED here and not a
# surprise on someone else's harness.
# ---------------------------------------------------------------------------
REGISTRY="$TMP/decoy-not-this-file.json"
printf '%s\n' '{"agents":{"decoylane":{}}}' > "$REGISTRY"
roster_reset
_task_roster
[[ "$_TASK_ROSTER" != *"decoylane"* ]] \
  && ok_t "T13a the stale global \$REGISTRY is NOT what the guard reads" \
  || bad_t "T13a roster read from the global REGISTRY" "$_TASK_ROSTER"
[[ "$_TASK_ROSTER" == *"quinn"* && "$_TASK_ROSTER_STATE" == "ok" ]] \
  && ok_t "T13b …it reads \$STATE_DIR/agents.json, the board's own state dir" \
  || bad_t "T13b roster not from STATE_DIR" "state=$_TASK_ROSTER_STATE roster=$_TASK_ROSTER"
REGISTRY="$STATE_DIR/agents.json"; roster_reset

# ---------------------------------------------------------------------------
# T14 — UNDER `set -euo pipefail`, which is how the BUNDLE runs. This harness runs
# `set +e`, so every arm above is blind to a statement that merely exits non-zero
# — and the first cut of `task orphans` did exactly that (`marks+="$([[ -n "$hint" ]]
# && printf …)"`, an assignment inheriting the substitution's status). It passed
# every arm here and died in the bundle with "exited 1 without reporting a
# reason". Both paths are graded: with hints (orphans present) and without.
# ---------------------------------------------------------------------------
write_roster dev dev2 dev3 main marketing quinn
strict_out=$( set -euo pipefail; roster_reset; cmd_task_orphans 2>&1 ); strict_rc=$?
[[ "$strict_rc" == "0" && "$strict_out" == *"DIVE-7002"* ]] \
  && ok_t "T14a orphans survives set -euo pipefail on the WITH-orphans path" \
  || bad_t "T14a strict-mode orphans" "rc=$strict_rc :: $strict_out"
# Note which rows have to be cleaned here: DIVE-1 and DIVE-2 are T0's, accepted
# while the guard was UNARMED. That is the real-world case in miniature — the rows
# already on a dead lane are the ones filed before the guard existed, and the
# surfacer is the only thing that ever mentions them again.
strict_out=$( set -euo pipefail; roster_reset
              db "UPDATE tasks SET assignee='dev' WHERE assignee NOT IN ('dev','dev2','dev3','main','marketing','quinn');
                  UPDATE tasks SET created_by='dev' WHERE created_by NOT IN ('dev','dev2','dev3','main','marketing','quinn','cli','council');"
              roster_reset; cmd_task_orphans 2>&1 ); strict_rc=$?
[[ "$strict_rc" == "0" && "$strict_out" == *"no orphaned rows"* ]] \
  && ok_t "T14b …and on the CLEAN path (no hints to interpolate)" \
  || bad_t "T14b strict-mode clean board" "rc=$strict_rc :: $strict_out"
strict_out=$( set -euo pipefail; roster_reset
              cmd_task_add "T14 strict accept" --assignee=dev 2>&1 ); strict_rc=$?
[[ "$strict_rc" == "0" ]] \
  && ok_t "T14c …and an ACCEPTED add does not trip strict mode either" \
  || bad_t "T14c strict-mode accept" "rc=$strict_rc :: $strict_out"
# T14d — THE NOT-MEASURED PATH UNDER STRICT MODE, which is the one that actually
# shipped broken. registry_read_checked returns 3 when there is no registry file;
# `body=$(…); rc=$?` made that 3 fatal, so on every fresh store — the common case
# for a new host — `task add` died with "exited 3 without reporting a reason".
# A guard's own could-not-measure branch must not be able to take the board down.
rm -f "$STATE_DIR/agents.json"
strict_out=$( set -euo pipefail; roster_reset
              cmd_task_add "T14 no-registry strict" --assignee=whoeverthisis --from=council 2>&1 ); strict_rc=$?
[[ "$strict_rc" == "0" ]] \
  && ok_t "T14d strict mode + NO registry: the add lands, it does not die on rc=3" \
  || bad_t "T14d strict-mode no-registry add" "rc=$strict_rc :: $strict_out"
write_roster dev dev2 dev3 main marketing quinn

# ---------------------------------------------------------------------------
# MUT — the harness's own positive control. Strip the two guard calls from a COPY
# of the tree and re-run T1 and T7a against it: both must now be ACCEPTED. If
# they are not, this file is grading something other than the guard and every ok
# above is worthless.
# ---------------------------------------------------------------------------
MUTSRC="$TMP/mut"
cp -r "$SRC" "$MUTSRC"
sed -i 's|^  _task_require_lane "$assignee" "--assignee"$|  :|' "$MUTSRC/task/crud.sh"
sed -i 's|^  _task_require_lane "$who" "<agent>"$|  :|'         "$MUTSRC/task/crud.sh"
mut_out=$(
  cd "$TMP" && MUT="$MUTSRC" TMP2="$TMP/mut-state" bash -c '
    set -uo pipefail
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
             lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
             lib/tasks_db.sh lib/actor.sh cmd_task.sh; do source "$MUT/$f"; done
    STATE_DIR="$TMP2"; REGISTRY="$STATE_DIR/agents.json"
    TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; mkdir -p "$TASKS_DIR"
    printf "%s\n" "{\"agents\":{\"dev\":{},\"main\":{}}}" > "$REGISTRY"
    tasks_db_init >/dev/null 2>&1
    cmd_task_add "MUT drift" --assignee=agent-dev >/dev/null 2>&1; echo "add=$?"
    db "INSERT INTO tasks (ident,title,status,assignee,created_by,kind)
        VALUES (\"DIVE-7900\",\"mut\",\"todo\",\"dev\",\"dev\",\"standard\");" >/dev/null 2>&1
    cmd_task_assign DIVE-7900 agent-dev >/dev/null 2>&1; echo "assign=$?"
  ' 2>&1
)
[[ "$mut_out" == *"add=0"* ]] \
  && ok_t "MUTa with the add guard stripped, agent-dev is ACCEPTED (T1 can fail)" \
  || bad_t "MUTa mutation not detected by T1" "$mut_out"
[[ "$mut_out" == *"assign=0"* ]] \
  && ok_t "MUTb with the assign guard stripped, the reassignment lands (T7a can fail)" \
  || bad_t "MUTb mutation not detected by T7a" "$mut_out"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
