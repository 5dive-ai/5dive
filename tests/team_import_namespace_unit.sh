#!/usr/bin/env bash
# DIVE-4822 — a team import makes a TEAM: its own namespace, its own org root,
# and a project row that records it.
#
# THE DEFECT. `compose up` checks the registry per declared agent and, when the
# name already exists, takes the "already exists — ensuring started" branch and
# `continue`s — which skips the whole provisioning block INCLUDING the `org set`
# edge. Two of the three shipped templates root at `ceo`, so `team import
# eng-studio` then `team import startup` produced ONE org tree: the second
# template's root IS the first's, never re-parented, with the second roster
# hanging off it. "Two teams on one box" — the model DIVE-4700 is built on — was
# not reachable, and it failed silently.
#
# WHAT IS PINNED HERE, and why most of it is negative controls: this change
# renames agents, which is the most destructive thing a provisioning path can do
# by accident. The positive arms (a prefix produces a second root) are the cheap
# half. The load-bearing arms are the ones that must NOT fire — a virgin box, a
# re-run of the same roster, an explicit --prefix='' — because a namespace
# applied when it was not asked for provisions a duplicate team.
#
# THE 16-CHARACTER FINDING, pinned in section 3 because it invalidates the
# design the row was filed with. `valid_name` caps an agent at 16 characters, so
# "default the prefix to the template slug" is not implementable:
# `content-studio-editor` is 21 and `up` would warn-and-skip the whole roster.
# The prefix is therefore computed from the roster's own budget, and an explicit
# prefix that does not fit is REFUSED rather than truncated — a truncated name is
# a different agent.
#
# COVERAGE LIMIT, said plainly: these arms drive the spec transforms, the prefix
# ladder and the two team writes against a scratch task store. They do NOT
# provision agents (that needs real unix users), so "the renamed seat boots" is
# not claimed. What is claimed is that the roster handed to `agent create` and
# the org/project rows written afterwards are the right ones.
#
# Run: bash tests/team_import_namespace_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_namespace_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC=src

# shellcheck source=/dev/null
for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/task/routing.sh src/cmd_compose.sh src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
# The sourced CLI turns errexit ON; several helpers here legitimately end on a
# false [[ ]] — same reason the sibling type-override harness does this.
set +e

TMP="$(mktemp -d /tmp/team-import-namespace.XXXXXX)"
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# Reserved fakes only — the templates reference ${VAR}s and _compose_parse hard
# errors on an unset one. Nothing below asserts on their values.
export TEAM_AUTH_PROFILE=fixture
export TEAM_TG_TOKEN='1234567890:AAAAfake-not-a-real-bot-token'
for v in EDITOR WRITER SEO DESIGNER DISTRIBUTOR CEO CMO DEVOPS RESEARCHER CREATIVE; do
  export "${v}_TG_TOKEN=$TEAM_TG_TOKEN"
done

FIX="$ROOT/tests/fixtures/team-templates"

# ============ 0. PRECONDITIONS — the arms below are not vacuous ==============
if [[ -s "$FIX/eng-studio.5dive.yaml" && -s "$FIX/startup.5dive.yaml" ]] \
   && declare -F _compose_apply_name_prefix >/dev/null; then
  ok_t 'T0 both colliding fixture templates and the namespace transform are present'
else
  bad_t 'T0 precondition failed — every arm below is vacuous' "fix=$FIX"
fi

ENG="$(_compose_parse "$FIX/eng-studio.5dive.yaml")"
STA="$(_compose_parse "$FIX/startup.5dive.yaml")"
CON="$(_compose_parse "$FIX/content-studio.5dive.yaml")"

# The row's premise, re-derived rather than assumed: two shipped templates root
# at the same name. If a template is ever renamed this arm says so instead of
# letting the rest of the suite quietly grade a collision that no longer exists.
eq_t 'T0b the row premise holds — eng-studio and startup BOTH root at the same agent' \
     'ceo|ceo' "$(_compose_spec_root "$ENG")|$(_compose_spec_root "$STA")"
eq_t 'T0c a third template roots somewhere else, so the root is derived and not hard-coded' \
     'editor' "$(_compose_spec_root "$CON")"

# ============ 1. THE ROOT IS DERIVED, NEVER DECLARED ========================
# Templates carry per-agent reports_to and nothing names a lead. Guessing which
# of two roots is the lead is the class of confident-wrong-answer this row is
# about, so zero roots and two roots must both decline to answer.
cat > "$TMP/two-roots.yaml" <<'YAML'
version: "2"
agents:
  a: {role: "A"}
  b: {role: "B"}
YAML
cat > "$TMP/cycle.yaml" <<'YAML'
version: "2"
agents:
  a: {role: "A", reports_to: b}
  b: {role: "B", reports_to: a}
YAML
_compose_spec_root "$(_compose_parse "$TMP/two-roots.yaml")" >/dev/null 2>&1 \
  && bad_t 'T1 a two-root spec must NOT name a lead' 'it named one' \
  || ok_t 'T1 a spec with two roots declines to name a lead (no guess)'
# The only way to write a rootless spec is a reporting cycle, and _compose_parse
# already refuses one — so the rootless case never reaches the transform. Pinned
# at the parser, which is where the property actually lives, rather than asserted
# against a fixture the product would never hand us.
_compose_parse "$TMP/cycle.yaml" >/dev/null 2>&1 \
  && bad_t 'T1b a rootless (cyclic) spec must not parse' 'it parsed' \
  || ok_t 'T1b the only rootless shape is a reporting cycle, and the parser refuses it before the transform sees it'

# ============ 2. THE TRANSFORM: names AND the edges between them =============
# Renaming the keys and leaving reports_to alone would split the roster into N
# unrelated roots — the opposite of the bug, and worse.
PFX="$(_compose_apply_name_prefix "$STA" start)"
eq_t 'T2 every declared agent is renamed <prefix>-<name>' \
     'start-ceo,start-cmo,start-creative,start-devops,start-researcher' \
     "$(jq -r '.agents | keys | join(",")' <<<"$PFX")"
eq_t 'T2b the reports_to edges are rewritten with it, so the roster keeps its shape' \
     'start-ceo' \
     "$(jq -r '.agents["start-cmo"].reports_to | if type=="array" then .[0] else . end' <<<"$PFX")"
eq_t 'T2c the renamed roster still has exactly ONE root, and it is the renamed one' \
     'start-ceo' "$(_compose_spec_root "$PFX")"
# The whole point: two imports, two roots.
eq_t 'T2d a second team imported alongside the first has its OWN root, not the first team lead' \
     'start-ceo|ceo' "$(_compose_spec_root "$PFX")|$(_compose_spec_root "$ENG")"

# An edge naming an agent this spec does not declare must be left alone.
cat > "$TMP/outside.yaml" <<'YAML'
version: "2"
agents:
  a: {role: "A"}
  b: {role: "B", reports_to: a}
YAML
OUT="$(_compose_apply_name_prefix "$(_compose_parse "$TMP/outside.yaml")" t)"
eq_t 'T2e an edge INSIDE the roster is rewritten' 't-a' \
     "$(jq -r '.agents["t-b"].reports_to | if type=="array" then .[0] else . end' <<<"$OUT")"

# ============ 3. THE 16-CHARACTER CAP — the finding that reshaped the design ==
eq_t 'T3 valid_name has not moved: 16 chars is still the cap this budget is computed from' \
     'yes|no' \
     "$(valid_name aaaaaaaaaaaaaaaa && echo -n yes || echo -n no)|$(valid_name aaaaaaaaaaaaaaaaa && echo -n yes || echo -n no)"
eq_t 'T3b the FULL SLUG the row asked for does not fit content-studio (21 chars) — this is why it is not the default' \
     'no' "$(valid_name content-studio-editor && echo -n yes || echo -n no)"
eq_t 'T3c the budget is 16 - 1 - the longest LEGAL declared name' \
     '4' "$(_compose_prefix_budget "$CON")"
eq_t 'T3d the default prefix is the slug truncated to that budget, and it fits' \
     'cont|yes' \
     "$(_compose_default_prefix content-studio "$CON")|$(valid_name "$(_compose_default_prefix content-studio "$CON")-distributor" && echo -n yes || echo -n no)"
# Every shipped fixture template must fit, or the feature is unusable on the
# templates we actually ship. This is the arm that reds if a template grows a
# longer role name.
_allfit=1; _worst=""
for t in "$FIX"/*.5dive.yaml; do
  _slug="$(basename "$t")"; _slug="${_slug%.5dive.yaml}"
  _sp="$(_compose_parse "$t" 2>/dev/null)" || continue
  _p="$(_compose_default_prefix "$_slug" "$_sp")"
  [[ -n "$_p" ]] || { _allfit=0; _worst="$_slug (no room at all)"; continue; }
  while IFS= read -r _n; do
    valid_name "$_n" || continue
    valid_name "$_p-$_n" || { _allfit=0; _worst="$_slug: $_p-$_n"; }
  done < <(jq -r '.agents | keys[]' <<<"$_sp")
done
(( _allfit )) && ok_t 'T3e every shipped template gets a default namespace that fits all of its legal names' \
             || bad_t 'T3e a shipped template cannot be namespaced' "$_worst"
# eng-studio ships three names valid_name has NEVER accepted (underscores). They
# are excluded from the budget on purpose — they are skipped by `up` with or
# without a prefix, and letting them shrink the namespace would punish every
# other agent for a defect in one template.
eq_t 'T3f already-illegal declared names do not shrink the budget (eng-studio ships three underscored names)' \
     '7' "$(_compose_prefix_budget "$ENG")"

# ============ 4. COLLISION DETECTION ========================================
REG_EMPTY='{"agents":{}}'
REG_ENG='{"agents":{"ceo":{},"designer":{},"qa":{}}}'
eq_t 'T4 a virgin box reports no collisions' '' \
     "$(_compose_name_collisions "$STA" "$REG_EMPTY" | paste -sd, -)"
eq_t 'T4b a box carrying the other team reports exactly the shared name' 'ceo' \
     "$(_compose_name_collisions "$STA" "$REG_ENG" | paste -sd, -)"
eq_t 'T4c the collision set is computed per declared name, not per template' 'ceo,designer,qa' \
     "$(_compose_name_collisions "$ENG" "$REG_ENG" | paste -sd, -)"

# ============ 4b. THE LADDER — the decision, graded on its own =============
# This is the risky logic: it decides whether to RENAME a roster. Each rung is
# asserted for its decision, not its prose.
REG_STA='{"agents":{"ceo":{},"cmo":{},"devops":{},"researcher":{},"creative":{}}}'
eq_t 'L1 a virgin box: nothing is renamed (the control the whole row rests on)' \
     'free|' "$(_team_choose_prefix startup "$STA" "$REG_EMPTY" "" ceo)"
eq_t 'L2 a box carrying ANOTHER team that shares one name: this roster gets its own namespace' \
     'namespaced|start' "$(_team_choose_prefix startup "$STA" "$REG_ENG" "" ceo)"
eq_t 'L3 every declared name already present: adopt, do NOT provision a second copy' \
     'adopt-all|' "$(_team_choose_prefix startup "$STA" "$REG_STA" "" ceo)"
eq_t 'L4 this template already installed UNPREFIXED: re-import into the same (empty) namespace' \
     'installed|' "$(_team_choose_prefix startup "$STA" "$REG_STA" ceo ceo)"
# The ordering claim, and the reason `installed` is tested ahead of `adopt-all`:
# a prefixed team re-imported would otherwise read as "all names free", come up
# unprefixed, and land a SECOND copy under the bare names.
eq_t 'L5 this template already installed PREFIXED: the prefix is recovered from the project lead' \
     'installed|start' "$(_team_choose_prefix startup "$STA" '{"agents":{"start-ceo":{}}}' start-ceo ceo)"
eq_t 'L5b …and that rung BEATS adopt-all, so a prefixed team is never re-imported under the bare names' \
     'installed|start' "$(_team_choose_prefix startup "$STA" "$REG_STA" start-ceo ceo)"
# A roster with no room for any namespace must REFUSE, never truncate — a
# truncated name is a different agent, and provisioning one silently is the same
# class of defect as the silent adoption being fixed.
cat > "$TMP/longnames.yaml" <<'YAML'
version: "2"
agents:
  aaaaaaaaaaaaaaaa: {role: "A"}
  bbbbbbbbbbbbbbbb: {role: "B", reports_to: aaaaaaaaaaaaaaaa}
YAML
LONG="$(_compose_parse "$TMP/longnames.yaml")"
_lmsg=$(_team_choose_prefix longteam "$LONG" '{"agents":{"aaaaaaaaaaaaaaaa":{}}}' "" aaaaaaaaaaaaaaaa); _lrc=$?
if (( _lrc != 0 )) && [[ "$_lmsg" == *"cannot be imported"* && "$_lmsg" == *"aaaaaaaaaaaaaaaa"* ]]; then
  ok_t 'L6 a clash with no room for a namespace REFUSES, and the refusal names the clashing agent'
else
  bad_t 'L6 a clash with no room for a namespace refuses' "rc=$_lrc msg=$_lmsg"
fi
eq_t 'L6b CONTROL: that same roster on a virgin box still imports untouched' \
     'free|' "$(_team_choose_prefix longteam "$LONG" "$REG_EMPTY" "" aaaaaaaaaaaaaaaa)"

# ============ 5. NEGATIVE CONTROLS — when the namespace must NOT be applied ==
# A prefix applied when it was not asked for provisions a DUPLICATE team, which
# is worse than the merge being fixed. These are the load-bearing arms.
eq_t 'T5 CONTROL: no prefix leaves the parsed spec byte-identical' \
     "$(jq -cS . <<<"$STA")" "$(jq -cS . <<<"$(_compose_apply_name_prefix "$STA" "")")"
eq_t 'T5b CONTROL: the transform touches nothing but agent names and their edges' \
     "$(jq -cS 'del(.agents)' <<<"$STA")" "$(jq -cS 'del(.agents)' <<<"$PFX")"
eq_t 'T5c CONTROL: every non-name field of every agent survives the rename' \
     "$(jq -cS '[.agents[] | del(.reports_to)]' <<<"$STA")" \
     "$(jq -cS '[.agents[] | del(.reports_to)]' <<<"$PFX")"

# ============ 6. THE PROJECT ROW — a team is recorded, once =================
eq_t 'T6 a slug is already a project key' 'eng-studio' "$(_team_slug_key eng-studio)"
eq_t 'T6b a PATH import contributes its file stem, not its directory' 'my-team' \
     "$(_team_slug_key ./some/dir/my-team.5dive.yaml)"
eq_t 'T6c the ident prefix is letters-only — an upper-cased slug with a dash would be refused by project add' \
     'ENGSTUDI' "$(_team_project_prefix eng-studio)"
valid_project_prefix "$(_team_project_prefix eng-studio)" \
  && ok_t 'T6d …and it passes the real valid_project_prefix, so project add accepts it' \
  || bad_t 'T6d the derived ident prefix is accepted by project add' "got=$(_team_project_prefix eng-studio)"

_team_record_team eng-studio engstud-ceo eng-studio
eq_t 'T6e the import writes the project keyed by the slug, led by the team root' \
     'engstud-ceo' "$(db "SELECT lead_agent FROM projects WHERE key='eng-studio';")"
eq_t 'T6f …and the installed lead is readable back, which is how a re-import finds its namespace' \
     'engstud-ceo' "$(_team_installed_lead eng-studio)"
# Re-pointing a project's lead silently MOVES the project between teams, because
# a project's team is derived from root_of(lead_agent). So a second import must
# not do it behind the user's back.
_team_record_team eng-studio somebody-else eng-studio >/dev/null 2>&1
eq_t 'T6g CONTROL: re-importing does NOT re-point an existing project lead (that would move the project between teams)' \
     'engstud-ceo' "$(db "SELECT lead_agent FROM projects WHERE key='eng-studio';")"
# The upgrade path: a project that predates this change has no lead at all.
db "INSERT INTO projects (key, prefix, name) VALUES ('legacy','LEG','legacy');"
_team_record_team legacy leg-boss legacy >/dev/null 2>&1
eq_t 'T6h a project row that predates this change gets its lead filled in, not skipped' \
     'leg-boss' "$(db "SELECT lead_agent FROM projects WHERE key='legacy';")"
# The ident prefix is UNIQUE, so a second team whose key shares a stem must not
# collide — and must never fail the import.
eq_t 'T6i a taken ident prefix shortens rather than failing the import' \
     'ENGSTUD' "$(_team_project_prefix engstudio)"

# ============ 7. THE COORDINATOR TAG ========================================
db "INSERT INTO agents_org(name,reports_to,role) VALUES('engstud-ceo',NULL,'Chief Executive');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('engstud-qa','engstud-ceo','QA');"
_team_tag_root_coordinator engstud-ceo >/dev/null 2>&1
eq_t 'T7 the team root is tagged with the DIVE-2041 PROSE marker, appended to its title' \
     'Chief Executive coordinator' "$(db "SELECT role FROM agents_org WHERE name='engstud-ceo';")"
_team_tag_root_coordinator engstud-ceo >/dev/null 2>&1
eq_t 'T7b CONTROL: tagging is idempotent — a re-import does not append it twice' \
     'Chief Executive coordinator' "$(db "SELECT role FROM agents_org WHERE name='engstud-ceo';")"
eq_t 'T7c CONTROL: the marker is appended, never written over role= (that column is the displayed job title)' \
     'yes' "$(db "SELECT role FROM agents_org WHERE name='engstud-ceo';" | grep -q '^Chief Executive' && echo -n yes || echo -n no)"
_team_tag_root_coordinator ghost-agent >/dev/null 2>&1
eq_t 'T7d CONTROL: tagging an agent that is not on the chart writes nothing' '0' \
     "$(db "SELECT COUNT(*) FROM agents_org WHERE name='ghost-agent';")"
# The real resolver must actually find it — asserting the column shape alone
# would grade the UPDATE, not the routing fact it exists for.
# A SECOND root is added first, on purpose. With one root the resolver's
# lone-root tier answers `engstud-ceo` whether or not anything was tagged — the
# arm would pass on the pre-fix tree for a reason that has nothing to do with
# the tag. Two roots disarms that tier, so only the marker can produce the
# answer, which is the property this write exists for.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('other-lead',NULL,'Other Lead');"
if declare -F _task_resolve_coordinator >/dev/null 2>&1; then
  eq_t 'T7e the REAL resolver finds the tagged root on a TWO-root board, where the lone-root tier cannot answer' \
       'engstud-ceo' "$(_task_resolve_coordinator)"
  eq_t 'T7f CONTROL: the untagged second root is NOT what the resolver returns (the marker is doing the work)' \
       'yes' "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to='';" | grep -q '^2$' && echo -n yes || echo -n no)"
else
  bad_t 'T7e VACUOUS: _task_resolve_coordinator is not in scope' 'the routing claim is ungraded'
fi

# ============ 8. THE REAL BINARY — the flag exists and its refusals fire ====
# Everything above grades sourced functions. These two arms drive the built CLI,
# because a transform nothing can reach is not a feature. SKIPPED-AS-FAIL when
# the tree is not built: an unbuilt tree silently skipping an e2e block and
# printing a green tail is the vacuity this repo's other harnesses already name.
if [[ -x "$ROOT/5dive" ]]; then
  BIN_STATE="$TMP/binstate"; mkdir -p "$BIN_STATE"
  _bin() { STATE_DIR="$BIN_STATE" FIVEDIVE_STATE_DIR="$BIN_STATE" bash "$ROOT/5dive" "$@" 2>&1; }
  _out=$(_bin up --prefix=Bad-Prefix -f "$FIX/startup.5dive.yaml")
  [[ "$_out" == *"bad --prefix"* ]] \
    && ok_t 'T8 the built CLI refuses a prefix that is not a legal name fragment' \
    || bad_t 'T8 a malformed --prefix is refused' "got=${_out:0:160}"
  # NOT graded here: the overflow refusal. `up` gates on root before it reaches
  # the parsed spec, so driving it through the binary would need this harness to
  # run as root. It is graded on its own predicate instead (T8d/T8e below), which
  # is the same function the refusal calls — not a re-typed copy of it.
  _out=$(_bin team import --help)
  [[ "$_out" == *"--prefix=<p>"* ]] \
    && ok_t 'T8c `team import --help` documents the flag, so it is discoverable without reading the source' \
    || bad_t 'T8c team import --help documents --prefix' "got=${_out:0:160}"
else
  bad_t 'T8 SKIPPED-AS-FAIL: ./5dive is not built, so the binary-level arms proved nothing' \
        'run ./build.sh first — an unbuilt tree silently skips e2e blocks and fakes a green'
fi

# The overflow predicate the refusal is built on. A truncated name is a DIFFERENT
# agent, so this is what stands between an over-long prefix and a silently
# provisioned duplicate.
eq_t 'T8d the overflow predicate names every agent an over-long prefix would break' \
     'designer, distributor, editor, seo, writer' \
     "$(_compose_prefix_overflow "$CON" contentstudio)"
eq_t 'T8e CONTROL: the prefix this code would actually CHOOSE overflows nothing' \
     '' "$(_compose_prefix_overflow "$CON" "$(_compose_default_prefix content-studio "$CON")")"
eq_t 'T8f CONTROL: an already-illegal declared name is not reported as an overflow (a prefix did not break it)' \
     '' "$(_compose_prefix_overflow "$ENG" engstud)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
