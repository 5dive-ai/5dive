#!/usr/bin/env bash
# DIVE-4022 — `team import` must carry LOOPS, and carrying them must be idempotent.
#
# THE DEFECT: `team import` provisioned a roster, not a working company. Agents,
# roles and reporting lines came up with nothing recurring on the board, so an
# imported team sat idle until someone hand-created the work.
#
# THE TRAP, and what most of this file grades: `up` is declarative and re-runnable,
# so loops created by import must RECONCILE, not accumulate. A second `team import`
# that doubles every recurring job is worse than no loops at all — it is a company
# that does everything twice, and nothing in the summary would say so.
#
# These arms are FUNCTIONAL where they can be. _compose_apply_loops is exercised
# against a real sqlite task store with a stub `self` standing in for the CLI, so
# the reconcile key is graded by running it, not by grepping for it. The parser
# arms run the real `_compose_parse` over real YAML. Only the wiring arms (which
# live inside cmd_compose_up and would need to provision users on the host) are
# source-level, and they are labelled as such.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"
TMP="$(mktemp -d)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_compose.sh is present — the arms below are not reading an empty file' \
  || { bad_t 'T0 cmd_compose.sh missing — every arm is vacuous' "src=$SRC"; echo "-----"; exit 1; }

command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || {
  printf 'SKIP - python3 + PyYAML unavailable; the parser arms cannot run\n'; echo "-----"; exit 0
}
command -v sqlite3 >/dev/null || {
  printf 'SKIP - sqlite3 unavailable; the reconcile arms cannot run\n'; echo "-----"; exit 0
}

# ---- load the two units under test, without the rest of the CLI -------------
# _compose_parse ends at the `}` after its embedded python heredoc, so the extract
# is anchored on `^PY$` — a bare /^}/ stops inside the heredoc and yields a file
# that will not even parse.
awk '/^_compose_parse\(\)/{f=1} f{print} f&&/^PY$/{p=1} p&&/^}$/{exit}' "$SRC" > "$TMP/parse.sh"
sed -n '/^_compose_loop_marker()/,/^}/p'  "$SRC" >  "$TMP/loops.sh"
sed -n '/^_compose_loop_present()/,/^}/p' "$SRC" >> "$TMP/loops.sh"
sed -n '/^_compose_apply_loops()/,/^}/p'  "$SRC" >> "$TMP/loops.sh"
sed -n '/^_compose_export_loops()/,/^}/p' "$SRC" >> "$TMP/loops.sh"
bash -n "$TMP/parse.sh" && bash -n "$TMP/loops.sh" \
  && ok_t 'T0b both extracted units parse — the extraction anchors still hold' \
  || bad_t 'T0b extraction produced unparseable bash — the anchors moved; every arm below is vacuous' ''

parse() { ( set -uo pipefail; . "$TMP/parse.sh"; _compose_parse "$1" ); }

# ---------------------------------------------------------------------------
# PARSER ARMS — a bad cadence must be refused at PARSE, before anything is
# provisioned. Discovered at provision time it leaves a half-built company, which
# is the same reason --type is validated before ensure_state.
# ---------------------------------------------------------------------------
spec() { printf 'version: "2"\nagents:\n  a:\n    type: claude\n    loops:\n%s' "$1" > "$TMP/s.yaml"; }

spec '      - id: weekly-brief
        title: "Weekly brief"
        cron: "0 9 * * 1"
        prompt: "do it"
        ceiling: 200000
      - pack: ci-analyst
'
got=$(parse "$TMP/s.yaml" 2>/dev/null | jq -c '.agents.a.loops')
[[ "$got" == '[{"id":"weekly-brief","title":"Weekly brief","cron":"0 9 * * 1","prompt":"do it","ceiling":200000},{"pack":"ci-analyst"}]' ]] \
  && ok_t 'T1 a valid loops: block survives the parser intact, both forms' \
  || bad_t 'T1 loops: did not round-trip through the parser' "got=$got"

# Each of these is a real way a hand-written spec goes wrong. A parser that
# accepts them stores a template that never fires, and nothing downstream looks.
declare -a bad_cases=(
  'not-a-list|      foo: bar\n'
  'entry-not-a-map|      - just-a-string\n'
  'neither-pack-nor-id|      - title: x\n        cron: "0 9 * * 1"\n'
  'inline-without-title|      - id: x\n        cron: "0 9 * * 1"\n'
  'inline-without-cron|      - id: x\n        title: t\n'
  'unparseable-cadence|      - id: x\n        title: t\n        cron: "every monday"\n'
  'id-outside-the-charset|      - id: "Weekly Brief!"\n        title: t\n        cron: "0 9 * * 1"\n'
  'duplicate-key-on-one-agent|      - id: x\n        title: t\n        cron: "0 9 * * 1"\n      - id: x\n        title: t2\n        cron: "0 9 * * 2"\n'
  'pack-with-its-own-title|      - pack: ci-analyst\n        title: nope\n'
  'negative-ceiling|      - id: x\n        title: t\n        cron: "0 9 * * 1"\n        ceiling: -5\n'
)
for c in "${bad_cases[@]}"; do
  label="${c%%|*}"; yaml="${c#*|}"
  spec "$(printf '%b' "$yaml")"
  parse "$TMP/s.yaml" >/dev/null 2>&1
  (( $? != 0 )) \
    && ok_t "T2 refused at parse: $label" \
    || bad_t "T2 the parser ACCEPTED $label — a loop that cannot fire would be stored silently" ''
done

# Forward-compat: an unknown loop key WARNS and continues, matching the v2 rule
# for unknown agent keys. A hard fail here would make an older CLI reject a newer
# template outright, which is the whole reason the additive route was chosen.
spec '      - id: x
        title: t
        cron: "0 9 * * 1"
        cadence: nope
'
werr=$(parse "$TMP/s.yaml" 2>&1 >/dev/null); wrc=$?
if (( wrc == 0 )) && grep -q "unknown loop key 'cadence'" <<<"$werr"; then
  ok_t 'T3 an unknown loop key warns and continues (forward-compat, per schema v2)'
else
  bad_t 'T3 an unknown loop key is not forward-compatible' "rc=$wrc err=$werr"
fi

# ---------------------------------------------------------------------------
# RECONCILE ARMS — the trap. Run for real against a sqlite store.
# ---------------------------------------------------------------------------
DB="$TMP/tasks.db"
sqlite3 "$DB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, kind TEXT, assignee TEXT, title TEXT, body TEXT, schedule TEXT);"

# A stub standing in for the CLI binary _compose_apply_loops shells out to. It
# writes the row the real `task add --recurring` writes, so the reconcile is
# graded against a real store rather than against a mock of itself.
cat > "$TMP/self.sh" <<'STUB'
#!/usr/bin/env bash
DB="${STUB_DB:?}"
printf '%s\n' "$*" >> "${STUB_LOG:?}"
[[ "${STUB_FAIL:-0}" == 1 ]] && exit 1
verb="$1"
if [[ "$verb" == task ]]; then
  body=""; cron=""; assignee=""; title=""
  shift 2   # task add
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      body="${1#--body=}" ;;
      --recurring=*) cron="${1#--recurring=}" ;;
      --assignee=*)  assignee="${1#--assignee=}" ;;
      --) shift; title="$1" ;;
      *) : ;;
    esac
    shift
  done
  # The real body carries a cron in single quotes; escape or the INSERT dies and
  # the harness reads as a product failure.
  q() { printf '%s' "${1//\'/\'\'}"; }
  sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES ('recurring','$(q "$assignee")','$(q "$title")','$(q "$body")','$(q "$cron")');"
elif [[ "$verb" == loop ]]; then
  # `loop install <slug> --onto=<agent>` — the marker is cmd_loop_pack's own.
  slug="$3"; onto=""
  for a in "$@"; do [[ "$a" == --onto=* ]] && onto="${a#--onto=}"; done
  sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES ('recurring','$onto','$slug job','— installed loop: $slug (5dive marketplace).','0 */4 * * *');"
fi
exit 0
STUB
chmod +x "$TMP/self.sh"

# Harness-side stand-ins for the CLI's shared helpers.
apply() {
  ( set -uo pipefail
    db()   { sqlite3 "$DB" "$1"; }
    sqlq() { printf "'%s'" "${1//\'/\'\'}"; }
    step() { :; }
    warn() { :; }
    . "$TMP/loops.sh"
    STUB_DB="$DB" STUB_LOG="$TMP/stub.log" STUB_FAIL="${2:-0}" \
      _compose_apply_loops "$1" a "$TMP/self.sh" )
}
rowcount() { sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE kind='recurring' AND assignee='a';"; }

SPEC=$(jq -nc '{agents:{a:{loops:[
  {id:"weekly-brief", title:"Weekly brief", cron:"0 9 * * 1", prompt:"do it"},
  {pack:"ci-analyst"}
]}}}')

out1=$(apply "$SPEC"); c1=$(rowcount)
[[ "$out1" == *"COUNTS 2 0 0"* && "$c1" == 2 ]] \
  && ok_t 'T4 first up: both declared loops are created (inline + pack), 2 recurring rows' \
  || bad_t 'T4 first up did not create the declared loops' "out=$out1 rows=$c1"

# THE ARM THIS FILE EXISTS FOR.
out2=$(apply "$SPEC"); c2=$(rowcount)
[[ "$out2" == *"COUNTS 0 2 0"* && "$c2" == 2 ]] \
  && ok_t 'T5 second up: both loops are found, NOTHING is duplicated (still 2 rows)' \
  || bad_t 'T5 RE-IMPORT DUPLICATED THE LOOPS — the company would do everything twice' "out=$out2 rows=$c2"

# A third pass, because an accumulate bug can be off by one rather than doubling.
apply "$SPEC" >/dev/null; c3=$(rowcount)
[[ "$c3" == 2 ]] \
  && ok_t 'T5b third up: still 2 rows — the reconcile is stable, not merely first-run-safe' \
  || bad_t 'T5b rows grew on the third up' "rows=$c3"

# Adding a loop to a company already imported must create ONLY the new one. This
# is why the reconcile runs over the whole roster instead of the create branch.
SPEC2=$(jq -nc '{agents:{a:{loops:[
  {id:"weekly-brief", title:"Weekly brief", cron:"0 9 * * 1", prompt:"do it"},
  {pack:"ci-analyst"},
  {id:"daily-sweep", title:"Daily sweep", cron:"0 8 * * 1-5"}
]}}}')
out4=$(apply "$SPEC2"); c4=$(rowcount)
[[ "$out4" == *"COUNTS 1 2 0"* && "$c4" == 3 ]] \
  && ok_t 'T6 a loop added to an already-imported company is created, the existing two are not' \
  || bad_t 'T6 adding a loop to a live roster did not reconcile' "out=$out4 rows=$c4"

# A recurring row created by HAND (no marker) must not be re-created from a spec
# that names the same title — that is the accumulation arriving via `export`.
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES ('recurring','a','Hand made row','no marker here','0 2 * * *');"
SPEC3=$(jq -nc '{agents:{a:{loops:[{id:"hand-made-row", title:"Hand made row", cron:"0 2 * * *"}]}}}')
out5=$(apply "$SPEC3")
[[ "$out5" == *"COUNTS 0 1 0"* ]] \
  && ok_t 'T7 a marker-less recurring row is matched on TITLE — an exported fleet re-imports without doubling' \
  || bad_t 'T7 a hand-created recurring row was duplicated by a re-import' "out=$out5"

# A failed install must be COUNTED and must hand back a runnable retry, not vanish.
sqlite3 "$DB" "DELETE FROM tasks;"
out6=$(apply "$SPEC" 1)
if [[ "$out6" == *"COUNTS 0 0 2"* ]] && grep -q '^RETRY ' <<<"$out6"; then
  ok_t 'T8 a loop that will not install is counted as an error AND emits a runnable retry line'
else
  bad_t 'T8 a failed loop install is silent — the user would never learn the company came up short' "out=$out6"
fi

# A child that reads stdin would eat the rest of the here-string the loop list is
# fed on, and the remaining loops would vanish with no error at all. Graded with a
# stub that drains stdin: without the </dev/null redirects, the second loop is
# never seen.
sqlite3 "$DB" "DELETE FROM tasks;"
cat > "$TMP/greedy.sh" <<'GREEDY'
#!/usr/bin/env bash
cat >/dev/null            # drain whatever stdin we were handed
exec "${STUB_REAL:?}" "$@"
GREEDY
chmod +x "$TMP/greedy.sh"
out7=$( set -uo pipefail
        db() { sqlite3 "$DB" "$1"; }
        sqlq() { printf "'%s'" "${1//\'/\'\'}"; }
        step() { :; }; warn() { :; }
        . "$TMP/loops.sh"
        STUB_DB="$DB" STUB_LOG="$TMP/stub.log" STUB_REAL="$TMP/self.sh" \
          _compose_apply_loops "$SPEC" a "$TMP/greedy.sh" )
[[ "$out7" == *"COUNTS 2 0 0"* ]] \
  && ok_t 'T8b a child that drains stdin cannot swallow the remaining loops' \
  || bad_t 'T8b a stdin-reading child ate the loop list — loops vanish with no error' "out=$out7"

# ---------------------------------------------------------------------------
# EXPORT ARM — export must not claim a company with recurring work has none.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM tasks;"
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','a','CI triage','x — installed loop: ci-analyst (5dive marketplace).','0 */4 * * *'),
  ('recurring','a','Weekly brief','b — declared loop: weekly-brief (5dive.yaml) runs on 0 9 * * 1.','0 9 * * 1'),
  ('recurring','a','Hand Made: Row!','nothing','0 2 * * *'),
  ('standard','a','not a loop','','');"
exp=$( set -uo pipefail
       db() { sqlite3 "$DB" "$1"; }
       sqlq() { printf "'%s'" "${1//\'/\'\'}"; }
       . "$TMP/loops.sh"; _compose_export_loops a )
want='[{"pack":"ci-analyst","cron":"0 */4 * * *"},{"id":"weekly-brief","title":"Weekly brief","cron":"0 9 * * 1"},{"id":"hand-made-row","title":"Hand Made: Row!","cron":"0 2 * * *"}]'
[[ "$exp" == "$want" ]] \
  && ok_t 'T9 export dumps a pack loop as pack:, a declared loop by its id, and a hand-made one by a derived id' \
  || bad_t 'T9 export does not round-trip loops — a saved fleet would claim it has no recurring work' "got=$exp"

# A title long enough to hit the 64-char cap must not export an id ending in a
# hyphen — measured on the live fleet, where several recurring titles do.
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','b','Recurring: smart GitHub discovery of new OSS integration targets everywhere','','0 9 * * 1');"
lid=$( set -uo pipefail
       db() { sqlite3 "$DB" "$1"; }
       sqlq() { printf "'%s'" "${1//\'/\'\'}"; }
       . "$TMP/loops.sh"; _compose_export_loops b | jq -r '.[0].id' )
[[ ${#lid} -le 64 && "$lid" != *- ]] \
  && ok_t "T9d a long title exports a capped id with no trailing hyphen (got '$lid')" \
  || bad_t 'T9d the derived id is malformed at the length cap' "id=$lid len=${#lid}"

# The derived id must be the one the reconcile then matches on, or the round-trip
# is a doubling machine: export -> re-import -> two of everything.
[[ "$(jq -r '.[2].title' <<<"$exp")" == "$(sqlite3 "$DB" "SELECT title FROM tasks WHERE title LIKE 'Hand Made%';")" ]] \
  && ok_t 'T9b the exported loop carries the EXACT title, which is the reconcile key on re-import' \
  || bad_t 'T9b the exported title does not match the row — a re-import would create a second copy' ''

# ---------------------------------------------------------------------------
# ROUND-TRIP ARMS (DIVE-4022 iteration 2) — export | THE REAL PARSER.
#
# WHY THESE EXIST. Iteration 1 had five export arms and all five read the
# export's OUTPUT. None fed it back in. Fed to the real `_compose_parse`, the
# live board refused the WHOLE document three ways — and because the parse is
# whole-document, one bad row makes the entire company unimportable, at the
# user's `up`, not at the `export` that wrote it. An artefact whose only job is
# to be re-imported is not graded until the importer has eaten it.
#
# The fixture below is seeded from the shapes the LIVE board actually holds, not
# from the fields the author was thinking about: a cadence-less recurring row
# (main's objective-replan driver), a title with no Latin characters at all, and
# a pair of titles that agree on their first 64 slug characters (the live fleet
# already has many ids sitting exactly at that cap). The iteration-1 fixture
# carried schedules and Latin titles only, which is why it stayed green.
#
# The assembly step here mirrors cmd_compose_export's; T9c is the arm that grades
# the real wiring calls it.
# ---------------------------------------------------------------------------
_shape() { ( set -uo pipefail
             db() { sqlite3 "$DB" "$1"; }
             sqlq() { printf "'%s'" "${1//\'/\'\'}"; }
             warn() { printf 'warn: %s\n' "$*" >&2; }
             . "$TMP/loops.sh"; _compose_export_loops "$1" ) }

# Assemble a v2 doc the way export does, then run the REAL parser over it.
_roundtrip() {  # $1 = agent name whose loops to wrap
  local loops; loops=$(_shape "$1")   # stderr is the report channel; do NOT swallow it
  jq -n --arg n "$1" --argjson l "${loops:-[]}" \
     '{version:"2", agents:{($n): ({type:"claude"} + (if ($l|length)>0 then {loops:$l} else {} end))}}' \
  | python3 -c 'import sys,yaml,json; print(yaml.safe_dump(json.load(sys.stdin), sort_keys=False, allow_unicode=True))' \
  > "$TMP/rt.yaml" || return 9
  TEAM_AUTH_PROFILE=x parse "$TMP/rt.yaml"
}

sqlite3 "$DB" "DELETE FROM tasks;"
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','rt','Daily objective replan driver — funnel-channel-acquisition','nothing',''),
  ('recurring','rt','Weekly brief','b — declared loop: weekly-brief (5dive.yaml).','0 9 * * 1');"
rt_out=$(_roundtrip rt 2>"$TMP/rt.err"); rt_rc=$?
if (( rt_rc == 0 )) && jq -e '[.agents.rt.loops[]] | length == 1 and (.[0].id == "weekly-brief")' <<<"$rt_out" >/dev/null 2>&1; then
  ok_t 'T17 a cadence-less recurring row is dropped from the export instead of refusing the whole document at re-import'
else
  bad_t 'T17 export emitted a loop the real parser rejects — one dead board row makes the entire company unimportable' \
        "rc=$rt_rc err=$(tr '\n' ' ' < "$TMP/rt.err" | head -c 200)"
fi
grep -q 'has no cadence' "$TMP/rt.err" \
  && ok_t 'T17b the dropped row is REPORTED, not silently swallowed — export does not lie about what it left out' \
  || bad_t 'T17b a row was dropped from the export with no warning — the dump silently under-reports the fleet' \
           "err=$(tr '\n' ' ' < "$TMP/rt.err" | head -c 200)"

# A title with no [a-z0-9] at all slugifies to "", and `id: ""` fails the
# parser's "needs either pack: or id:". Any non-Latin script reaches this.
sqlite3 "$DB" "DELETE FROM tasks;"
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','rt','每日简报','nothing','0 9 * * *');"
rt_out=$(_roundtrip rt 2>"$TMP/rt.err"); rt_rc=$?
if (( rt_rc == 0 )) && jq -e '.agents.rt.loops | length == 1 and (.[0].id | test("^[a-z0-9][a-z0-9-]{0,63}$"))' <<<"$rt_out" >/dev/null 2>&1; then
  ok_t "T18 a title that slugifies to nothing still exports a parseable id (got '$(jq -r '.agents.rt.loops[0].id' <<<"$rt_out" 2>/dev/null)')"
else
  bad_t 'T18 a non-Latin title exported id:"" — the parser refuses the whole company' \
        "rc=$rt_rc err=$(tr '\n' ' ' < "$TMP/rt.err" | head -c 200)"
fi

# Two titles agreeing on their first 64 slug characters derive the SAME id, and
# the parser answers "duplicate loop key" for the whole document.
sqlite3 "$DB" "DELETE FROM tasks;"
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','rt','Recurring smart GitHub discovery of new OSS integration targets alpha','','0 9 * * 1'),
  ('recurring','rt','Recurring smart GitHub discovery of new OSS integration targets beta','','0 9 * * 2');"
rt_out=$(_roundtrip rt 2>"$TMP/rt.err"); rt_rc=$?
if (( rt_rc == 0 )) && jq -e '.agents.rt.loops | length == 2 and ((map(.id) | unique | length) == 2)' <<<"$rt_out" >/dev/null 2>&1; then
  ok_t 'T19 two titles colliding at the 64-char id cap export as two DISTINCT ids, and both survive the parser'
else
  bad_t 'T19 a title collision at the id cap exported a duplicate key — the parser refuses the whole company' \
        "rc=$rt_rc err=$(tr '\n' ' ' < "$TMP/rt.err" | head -c 200)"
fi
# ...and both rows must still be there. Deduping by DROPPING one would pass a
# uniqueness check while silently losing a loop.
if jq -e '[.agents.rt.loops[].title] | (index("Recurring smart GitHub discovery of new OSS integration targets alpha") != null) and (index("Recurring smart GitHub discovery of new OSS integration targets beta") != null)' <<<"$rt_out" >/dev/null 2>&1; then
  ok_t 'T19b the collision is resolved by suffixing, not by dropping a loop'
else
  bad_t 'T19b a colliding loop was silently dropped instead of renamed — the export loses recurring work' "out=$rt_out"
fi
# The suffix must be stable: exporting an unchanged board twice must not churn ids.
rt2=$(_roundtrip rt 2>/dev/null)
[[ "$(jq -cS '.agents.rt.loops' <<<"$rt_out")" == "$(jq -cS '.agents.rt.loops' <<<"$rt2")" ]] \
  && ok_t 'T19c the derived ids are stable across exports of an unchanged board' \
  || bad_t 'T19c the derived id churns between runs — every re-export would look like a change' ''

# A pack row keeps cron OPTIONAL (the pack carries its own cadence), so the
# cadence-less DROP above must not have been implemented as "drop every row with
# no schedule" — that would silently delete installed marketplace loops.
sqlite3 "$DB" "DELETE FROM tasks;"
sqlite3 "$DB" "INSERT INTO tasks (kind,assignee,title,body,schedule) VALUES
  ('recurring','rt','CI triage','x — installed loop: ci-analyst (5dive marketplace).','');"
rt_out=$(_roundtrip rt 2>/dev/null); rt_rc=$?
if (( rt_rc == 0 )) && jq -e '.agents.rt.loops | length == 1 and (.[0].pack == "ci-analyst")' <<<"$rt_out" >/dev/null 2>&1; then
  ok_t 'T20 a cadence-less PACK row still exports (the pack owns its cadence) and still parses'
else
  bad_t 'T20 the cadence-less drop also ate an installed marketplace loop' "rc=$rt_rc out=$rt_out"
fi

# ---- the same round-trip against the LIVE task store, when it is readable ----
# The fixture above is chosen from live shapes, but a fixture only ever contains
# what its author thought of — which is exactly how iteration 1 stayed green. This
# arm re-runs the shaper over the REAL board and feeds the result to the REAL
# parser. It SKIPS rather than fails where the store is unreadable (CI), so it is
# a bonus signal, never the harness's load-bearing evidence.
_live_db=""
# NOTE: /var/lib/5dive/tasks.db EXISTS on this host and holds no `tasks` table —
# a decoy that would make this probe fail open (readable, zero rows, SKIP that
# reads as "no live board"). The candidate must be confirmed by the TABLE, not
# by the filename.
for _c in "${TASKS_DB:-}" /var/lib/5dive/tasks/tasks.db /var/lib/5dive/state/tasks.db "$HOME/.5dive/tasks.db"; do
  [[ -n "$_c" && -r "$_c" ]] || continue
  sqlite3 "$_c" "SELECT 1 FROM tasks LIMIT 1;" >/dev/null 2>&1 && { _live_db="$_c"; break; }
done
if [[ -z "$_live_db" ]]; then
  printf 'SKIP - T21 live task store not readable from this seat; round-trip graded on the fixture only\n'
else
  _live_bad=0; _live_agents=0; _live_loops=0
  _fixture_db="$DB"; DB="$_live_db"
  while IFS= read -r _a; do
    [[ -n "$_a" ]] || continue
    _live_agents=$((_live_agents+1))
    rt_out=$(_roundtrip "$_a" 2>/dev/null) || { _live_bad=$((_live_bad+1)); echo "   live parse failed for agent: $_a"; continue; }
    _live_loops=$((_live_loops + $(jq -r '(.agents[].loops // []) | length' <<<"$rt_out" 2>/dev/null || echo 0)))
  done < <(sqlite3 "$_live_db" "SELECT DISTINCT assignee FROM tasks WHERE kind='recurring' AND assignee IS NOT NULL AND assignee<>'';" 2>/dev/null)
  DB="$_fixture_db"
  if (( _live_agents == 0 )); then
    printf 'SKIP - T21 the live store holds no recurring rows; nothing to round-trip\n'
  elif (( _live_bad == 0 )); then
    ok_t "T21 every loop the LIVE board exports is accepted by the real parser ($_live_loops loop(s) across $_live_agents agent(s))"
  else
    bad_t "T21 the LIVE board exports $_live_bad agent(s) whose loops the real parser refuses" ''
  fi
fi

# ---------------------------------------------------------------------------
# WIRING ARMS — source-level, and labelled. These live inside cmd_compose_up,
# which creates agents; a harness cannot run it without provisioning host users.
# ---------------------------------------------------------------------------
_wire_ln=$(grep -n '_compose_apply_loops "\$spec" "\$name" "\$self"' "$SRC" | head -1 | cut -d: -f1)
_create_ln=$(grep -n 'bash "\$self" agent create "\${args\[@\]}"' "$SRC" | head -1 | cut -d: -f1)
_sum_ln=$(grep -n 'OK — applied \$file' "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$_wire_ln" && -n "$_create_ln" && -n "$_sum_ln" ]] && (( _wire_ln > _create_ln && _wire_ln < _sum_ln )); then
  ok_t "T10 loops are applied AFTER the roster is created and BEFORE the summary (create $_create_ln, loops $_wire_ln, summary $_sum_ln)"
else
  bad_t 'T10 the loop pass is misplaced — a loop needs its owner to exist, and its counts belong on the summary' \
        "create=$_create_ln loops=$_wire_ln summary=$_sum_ln"
fi

# T9c: exporting a loops[] is worthless if cmd_compose_export never asks for it.
# The functional T9 above grades the SHAPER in isolation; this grades the WIRING,
# which is the half a refactor actually drops.
_exp_fn=$(sed -n '/^cmd_compose_export()/,/^}/p' "$SRC")
if grep -q '_compose_export_loops "\$name"' <<<"$_exp_fn" \
   && grep -q 'if (\$loops | length) > 0 then .loops = \$loops' <<<"$_exp_fn"; then
  ok_t 'T9c cmd_compose_export actually calls the shaper and puts loops on the agent object'
else
  bad_t 'T9c export never wires the loops in — a saved fleet still claims it has no recurring work' ''
fi

# The pass must iterate the DECLARED roster, not only what this run created.
# Folded into the create branch, adding loops: to an existing company is a no-op.
if sed -n "$((_wire_ln-25)),${_wire_ln}p" "$SRC" | grep -q 'for name in "\${names\[@\]}"'; then
  ok_t 'T11 the loop pass iterates the whole DECLARED roster, so loops can be added to a live company'
else
  bad_t 'T11 the loop pass does not iterate the declared roster — new loops on an existing company would be dropped' ''
fi

# A loop failure must NOT fail the import: the roster is up, and a marketplace
# fetch needs the network the one-tap dashboard import cannot assume. Same rule
# as DIVE-2347's failed skill and DIVE-3994's unset bot token.
if grep -q 'errors=\$((errors + loops_errors))' "$SRC"; then
  bad_t 'T12 ANCHOR a failed loop is folded into errors — a network hiccup would fail a company that came up fine' ''
else
  ok_t 'T12 ANCHOR a failed loop does not fail the import (reported last instead, with the retry)'
fi

grep -q 'declared loop(s) did NOT install' "$SRC" \
  && ok_t 'T13 a failed loop is restated AFTER the summary, where it is actually read' \
  || bad_t 'T13 a failed loop is only a mid-scroll warn — the last thing read would say nothing is wrong' ''

# The retry list travels on stdout, not a shared array: the caller consumes the
# function through a process substitution, so an array appended in there is lost.
if grep -q "printf 'RETRY " "$SRC" && grep -q '_COMPOSE_LOOP_RETRY+=("${_line#RETRY }")' "$SRC"; then
  ok_t 'T14 retries travel on stdout — a subshell cannot swallow them on the way back'
else
  bad_t 'T14 retries are collected in a way a process substitution discards' ''
fi

# ---------------------------------------------------------------------------
# TEMPLATE ARM — scope item 4: the path must be exercised by a bundled template,
# not only by a future one.
# ---------------------------------------------------------------------------
_tpl_with_loops=0
for f in "$ROOT"/team-templates/*.5dive.yaml; do
  [[ -f "$f" ]] || continue
  TEAM_AUTH_PROFILE=x parse "$f" 2>/dev/null | jq -e '[.agents[] | (.loops // []) | length] | add > 0' >/dev/null 2>&1 \
    && _tpl_with_loops=$((_tpl_with_loops+1))
done
(( _tpl_with_loops > 0 )) \
  && ok_t "T15 $_tpl_with_loops bundled template(s) declare real loops — the path ships exercised, not theoretical" \
  || bad_t 'T15 no bundled template declares a loop — every import still lands an idle roster' ''

# And every bundled template must still parse: `loops:` is additive, so a template
# that never gained one must be byte-for-byte unaffected.
_tpl_bad=0
for f in "$ROOT"/team-templates/*.5dive.yaml; do
  [[ -f "$f" ]] || continue
  TEAM_AUTH_PROFILE=x parse "$f" >/dev/null 2>&1 || { _tpl_bad=$((_tpl_bad+1)); echo "   parse failed: $f"; }
done
(( _tpl_bad == 0 )) \
  && ok_t 'T16 every bundled template still parses — the addition is purely additive' \
  || bad_t "T16 $_tpl_bad bundled template(s) no longer parse" ''

echo "-----"
echo "compose_loops_unit: $pass passed, $fail failed"
rc=0; [[ $fail -eq 0 ]] || rc=1
exit "$rc"
