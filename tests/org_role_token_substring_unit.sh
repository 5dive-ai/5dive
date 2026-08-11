#!/usr/bin/env bash
# DIVE-2041 — `agents_org.role` does double duty as human prose AND an exact-match
# machine sentinel, and that collision had TWO live consumers.
#
#   1. `_org_resolve_assignee 'role:<r>'` matched lower(role) = lower(<r>), full-string
#      equality, against a column whose every real value is prose ("QA / testing",
#      "Backend lane — OSS CLI, API, core council/constitution engine"). Measured on the
#      live chart before this change: NO role: token could match ANY agent. It resolved
#      to empty and the task landed unassigned — indistinguishable from ordinary
#      behaviour, which is why it went unreported for as long as the token has existed.
#   2. `_task_resolve_coordinator` matched role='coordinator' EXACTLY, so the only way
#      to tag a coordinator was to DESTROY that agent's rendered role text. DIVE-2031
#      rejected exactly that fix for exactly that reason and re-parented an org root
#      instead — leaving the tag unusable rather than merely unused.
#
# What is pinned here (the arms are the CLAIM, not the implementation):
#   A. role:<r> resolves a PROSE role by space-anchored substring (the reported bug)
#   B. it still matches the whole value when the chart uses terse roles (no regression)
#   C. it matches against title too, mirroring _task_resolve_deputy's predicate
#   D. AMBIGUITY still yields nothing — >1 holder must never be guessed between
#   E. LIKE wildcards in the token are escaped: `role:%` routes to nobody
#   F. the space anchor is real: "uncoordinated" does not satisfy "coordinator"
#   G. the coordinator marker works INSIDE prose and leaves the prose byte-intact
#   H. an exact role='coordinator' tag still wins over a prose marker elsewhere
#   I. two roots and no marker still resolves to NOBODY — this change widens what an
#      operator can EXPRESS; it must not invent a coordinator where none was declared
#      (that state is the DIVE-2031 outage, and the doctor check is what reports it)
# Run: bash tests/org_role_token_substring_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/org-role-token-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init >/dev/null 2>&1 || { echo "SKIP: tasks_db_init failed"; exit 0; }

PASS=0; FAIL=0
# check <label> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected [%s]\n       actual   [%s]\n' "$1" "$2" "$3"; fi
}

# The chart is a faithful copy of the live one's SHAPE: every role is prose, one
# agent has a NULL title, two agents share a keyword. Fake names throughout —
# these are the real fleet's names because the bug is about the real fleet's role
# TEXT, and no name here is a person, box or account (see the fixtures rule).
seed_chart() {
  sqlite3 "$TASKS_DB" "DELETE FROM agents_org;
    INSERT INTO agents_org(name,reports_to,role,title) VALUES
      ('olivia', NULL,     'AI CEO — conducts the fleet (advisory)', 'Olivia · CEO'),
      ('main',   'olivia', 'engineering + infra + the 5dive CLI',    'Marcus · CTO'),
      ('main2',  'main',   'engineering',                            'Marcus-2 · verifier'),
      ('quinn',  'main',   'QA / testing',                           NULL);"
}
seed_chart

# --- A: the reported bug. 'QA' is a fragment of quinn's prose role. -------------
check "A role:QA resolves the prose holder"            "quinn" "$(_org_resolve_assignee 'role:QA')"
# --- B: terse/whole-value roles keep resolving (exact tier, unchanged) ----------
check "B role:<whole value> still resolves"            "quinn" "$(_org_resolve_assignee 'role:QA / testing')"
check "B role:engineering hits the EXACT holder"       "main2" "$(_org_resolve_assignee 'role:engineering')"
# ^ two agents' role text contains "engineering"; main2's is exactly it. The exact
#   tier runs FIRST, so a chart that has a precise answer keeps getting it instead
#   of being told "ambiguous" — this is why exact is tried before substring.
# --- C: the predicate spans role||title, like _task_resolve_deputy --------------
check "C role:CTO matches via TITLE"                   "main"  "$(_org_resolve_assignee 'role:CTO')"
# --- D: ambiguity yields nothing, never a guess ---------------------------------
sqlite3 "$TASKS_DB" "UPDATE agents_org SET role='QA / release testing' WHERE name='main2';"
check "D two prose holders -> EMPTY"                   ""      "$(_org_resolve_assignee 'role:QA')"
seed_chart
# --- E: LIKE wildcards in caller input are escaped ------------------------------
check "E role:% routes to nobody"                      ""      "$(_org_resolve_assignee 'role:%')"
check "E role:_ routes to nobody"                      ""      "$(_org_resolve_assignee 'role:_')"
check "E unknown token still EMPTY"                    ""      "$(_org_resolve_assignee 'role:nosuchrole')"
# --- bare/@ passthrough is untouched -------------------------------------------
check "  @name passthrough unchanged"                  "dev"   "$(_org_resolve_assignee '@dev')"
check "  charter: token unchanged"                     "main"  "$(_org_resolve_assignee 'charter:CTO')"
check "E charter:% routes to nobody"                   ""      "$(_org_resolve_assignee 'charter:%')"

# --- coordinator resolution -----------------------------------------------------
check "  lone root resolves (zero config)"             "olivia" "$(_task_resolve_coordinator)"
sqlite3 "$TASKS_DB" "UPDATE agents_org SET reports_to=NULL WHERE name='quinn';"
check "I two roots, no marker -> NOBODY (DIVE-2031)"   ""       "$(_task_resolve_coordinator)"
sqlite3 "$TASKS_DB" "UPDATE agents_org SET role='AI CEO — conducts the fleet (advisory), fleet coordinator' WHERE name='olivia';"
check "G marker INSIDE prose resolves"                 "olivia" "$(_task_resolve_coordinator)"
check "G ...and the prose is byte-intact" \
  "AI CEO — conducts the fleet (advisory), fleet coordinator" \
  "$(sqlite3 "$TASKS_DB" "SELECT role FROM agents_org WHERE name='olivia';")"
# ^ G is the whole point of tier 2: DIVE-2031 rejected the exact tag because it
#   overwrites the text the org chart and council roster render. Asserting the
#   resolution without asserting the prose survived would pin half the claim.
sqlite3 "$TASKS_DB" "UPDATE agents_org SET role='uncoordinated backend lane' WHERE name='main';"
check "F 'uncoordinated' does NOT count as a marker"   "olivia" "$(_task_resolve_coordinator)"
sqlite3 "$TASKS_DB" "UPDATE agents_org SET role='fleet coordinator' WHERE name='quinn';"
check "D two markers -> EMPTY (ambiguous)"             ""       "$(_task_resolve_coordinator)"
sqlite3 "$TASKS_DB" "UPDATE agents_org SET role='coordinator' WHERE name='quinn';"
check "H exact tag beats a prose marker"               "quinn"  "$(_task_resolve_coordinator)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
