#!/usr/bin/env bash
# DIVE-6935/6938 — the devteam plugin's code is read into 5dive itself
# (src/lib/devteam.sh), and since DIVE-6938 the core keeps no copy of it.
#
# Part D runs the real bundle on a box WITHOUT the plugin: every dev-team verb
# answers with one line, a row with no bound PR closes on `done`, a row with one
# refuses and stays open. Part B gives the same bundle a fixture plugin and checks
# who may supply the code: the key, review, capability, enabled flag, ownership
# and write bits, an older plugin missing a module, a plugin that redefines a
# core function, FIVEDIVE_DEVTEAM=0, and that a community plugin claiming `push`
# never runs (four of these verbs are root sudo grants). Part C runs mutants of
# the built bundle and requires each to turn an arm red. Part A grades the
# install gate: `core` installs only as devteam@5dive-plugins from 5dive's own
# source, and no plugin may declare a dev-team verb. The D9/B8 arms grade the
# heartbeat's forge-merge sweep, whose helpers moved into the plugin (DIVE-7244).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
umask 022

TMP="$(mktemp -d)"
chmod 755 "$TMP"

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

BUNDLE="$TMP/5dive"
BUILD_OUT="$BUNDLE" ./build.sh >/dev/null 2>"$TMP/build.err" \
  || { echo "FAIL: build: $(cat "$TMP/build.err")"; exit 1; }

MOVED_FILES="cmd_deploy.sh cmd_gh.sh cmd_proof.sh cmd_push.sh lib/gh_config.sh task/delivery.sh task/gate_evidence.sh task/grader_pool.sh task/grader_process.sh"
n=0; for f in $MOVED_FILES; do [[ -e "src/$f" ]] && n=$((n+1)); done
t "D0 none of the moved files is left in src/" 0 "$n"
t "D0b nor named in build.sh" 0 "$(grep -cE 'src/(cmd_(deploy|gh|proof|push)|lib/gh_config|task/(delivery|gate_evidence|grader_pool|grader_process))\.sh' build.sh)"
t "D0c the pace stayed in the core" 1 "$(grep -c '^_pace_band() {' src/lib/pace.sh)"

export STATE_DIR="$TMP/state" TASKS_DB="$TMP/state/tasks/tasks.db" REGISTRY="$TMP/state/agents.json"
export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0
mkdir -p "$STATE_DIR/tasks"; printf '{"schemaVersion":2,"agents":{}}\n' > "$REGISTRY"
OUT=""; ERR=""; RC=0
dv() {  # run the bundle under test (BIN, default BUNDLE): OUT, ERR, RC
  local b="${BIN:-$BUNDLE}"
  OUT=$(cd "$TMP" && FIVE_LAZY_TRACE=1 bash "$b" "$@" 2>"$TMP/.e"); RC=$?; ERR=$(cat "$TMP/.e")
}
LINE="is in the devteam plugin: 5dive plugin install devteam"
NOTRUN="sweep did NOT run"
fm() {  # one forge-merge pass, sourced as a tick runs it: prints what it logged
  ( set +u; source src/header.sh 2>/dev/null; set +e
    source src/lib/devteam.sh; source src/cmd_heartbeat.sh
    _hb_log() { printf '%s\n' "$1"; }; db() { :; }   # an empty board
    _tasks_merge_owner_sql() { printf "''"; }; _TASKS_TFV_SQL=0
    _devteam_init   # before main, as src/main.sh runs it
    _hb_forge_merge_sweep ) 2>&1
}

# =============================================================================
# Part D — no plugin: the one line, and `done` with and without a bound PR
# =============================================================================
for v in proof gh push deploy _gh_do _push_do _deploy_do _merge_do; do
  dv "$v" x
  t  "D1 '5dive $v' without the plugin exits E_USAGE" 2 "$RC"
  tc "D1b and says where it went" "$v $LINE" "$ERR"
done
for v in deliver merge merge-landed merge-declined unbind-pr merge-audit merge-unverified merge-gate-selftest grade-context grader-tick grader-replay; do
  dv task "$v" DIVE-1
  t  "D2 'task $v' without the plugin exits E_USAGE" 2 "$RC"
  tc "D2b and says where it went" "task $v $LINE" "$ERR"
  dv task "$v" --help
  tc "D2c and so does its --help" "task $v $LINE" "$ERR"
done
dv task add "plain row" --assignee=dev
dv task add "bound row" --assignee=dev --verifier=quinn
sqlite3 "$TASKS_DB" "UPDATE tasks SET delivery_ref='https://github.com/example/repo/pull/1' WHERE id=2;"
dv task start DIVE-1; dv task done DIVE-1 --result="closed with no PR"
t  "D3 a row with no bound PR closes on done" 0 "$RC"
t  "D3b and is done" done "$(sqlite3 "$TASKS_DB" "SELECT status FROM tasks WHERE id=1;")"
tn "D3c and no dev-team code was asked for" "devteam" "$ERR"
dv task start DIVE-2; dv task done DIVE-2 --result="tries to close a bound PR"
t  "D4 a row with a bound PR refuses on done" 2 "$RC"
tc "D4b with the one line, naming the PR" "pull/1), $LINE" "$ERR"
t  "D4c and stays open" in_progress "$(sqlite3 "$TASKS_DB" "SELECT status FROM tasks WHERE id=2;")"
t  "D4d with its result unwritten" "" "$(sqlite3 "$TASKS_DB" "SELECT COALESCE(result,'') FROM tasks WHERE id=2;")"
# The maker->verifier loop is the core's, not the plugin's: a verifier row with no
# bound PR is handed to its verifier on done, and `task reject` is there to bounce it.
dv task add "verifier row" --assignee=dev --verifier=quinn --verify
dv task start DIVE-3; dv task done DIVE-3 --result="ready for review"
t  "D8 a verifier row with no bound PR is handed over on done" 0 "$RC"
t  "D8b to its verifier, as a delivery and not a close" "todo|quinn" "$(sqlite3 "$TASKS_DB" "SELECT status||'|'||assignee FROM tasks WHERE id=3;")"
dv task reject --help
t  "D8c task reject answers --help without the plugin" 0 "$RC"
tn "D8d and is not sent to the plugin" "$LINE" "$ERR"
dv heartbeat --help
t  "D5 heartbeat --help runs (nothing in it sources a moved file)" 0 "$RC"
dv loop --help
t  "D5b loop --help runs" 0 "$RC"
tn "D5c no 'command not found' anywhere above" "command not found" "$ERR"
( set +u; source src/header.sh 2>/dev/null; source src/lib/devteam.sh; devteam_status_line ) > "$TMP/.s" 2>&1
tc "D6 doctor's line on a box without it" "not installed — this box has no dev-team tools" "$(cat "$TMP/.s")"
dv selfcheck --only=scorecard-honesty
tc "D7 selfcheck's scorecard probe is not-reached without it, never a red or a fake pass" "no-devteam" "$OUT$ERR"
# DIVE-7244: the sweep's helpers are the plugin's, so their absence here is the
# answer and a tick says nothing (it said "did NOT run" 288 times a day).
t  "D9 without the plugin a forge-merge pass logs nothing" "" "$(fm)"
dfm() {  # doctor's forge-merge-poll line: <status> <message>
  ( set +u; source src/header.sh 2>/dev/null; set +e; source src/lib/devteam.sh; source src/cmd_doctor.sh
    doctor_add() { printf '%s %s\n' "$3" "$4"; }; doctor_check_forge_merge_poll ) 2>&1
}
tc "D9c and doctor says the poll is off, not unmeasured" "ok the forge merge poll is off on this box" "$(dfm)"
tc "D9d a tree that carries the helpers runs the poll, so doctor does not call it off" "has taken no reading" \
   "$( ( set +u; source src/header.sh 2>/dev/null; set +e; source src/lib/devteam.sh; source src/cmd_doctor.sh
        _merge_landed_probe() { :; }; _task_merge_landed_record() { :; }; _gate_slug_from_url() { :; }
        doctor_add() { printf '%s %s\n' "$3" "$4"; }; doctor_check_forge_merge_poll ) 2>&1 )"
tc "D9e a partial tree (one helper, no plugin) still logs the loud line" "$NOTRUN (devteam: not installed)" \
   "$( ( set +u; source src/header.sh 2>/dev/null; set +e; source src/lib/devteam.sh; source src/cmd_heartbeat.sh
        _gate_slug_from_url() { :; }; _hb_log() { printf '%s\n' "$1"; }; _hb_forge_merge_sweep ) 2>&1 )"
tc "D9b a harness with no plugin loader still gets the loud line" "$NOTRUN —" \
   "$( ( set +u; source src/header.sh 2>/dev/null; set +e; source src/cmd_heartbeat.sh
        _hb_log() { printf '%s\n' "$1"; }; _hb_forge_merge_sweep ) 2>&1 )"

# =============================================================================
# Part B — a fixture plugin, and who may supply it
# =============================================================================
PL="$STATE_DIR/plugins"
VDIR="$PL/cache/5dive-plugins/devteam/0.2.0"
mkdir -p "$VDIR/core/task" "$VDIR/core/lib" "$PL/enabled"
# One function per verb the core hands over; cmd_proof.sh also declares a
# top-level readonly, which dies if the file is ever read twice in one run.
fx() { printf '%s\n' "$2" > "$VDIR/core/$1"; chmod 644 "$VDIR/core/$1"; }
fx cmd_proof.sh  'readonly _DEVTEAM_FIXTURE_RO=1
cmd_proof() { echo "DEVTEAM-PROOF $* ro=$_DEVTEAM_FIXTURE_RO pace=$(declare -F _pace_band >/dev/null && echo core)"; }'
fx cmd_gh.sh     'cmd_gh() { echo "DEVTEAM-GH $*"; }
cmd_gh_do() { echo "DEVTEAM-GH-DO"; }'
fx cmd_push.sh   'cmd_push() { echo "DEVTEAM-PUSH $*"; }
cmd_push_setup() { echo "DEVTEAM-PUSH-SETUP"; }
cmd_push_do() { echo "DEVTEAM-PUSH-DO"; }'
fx cmd_deploy.sh 'cmd_deploy() { echo "DEVTEAM-DEPLOY"; }
cmd_deploy_do() { echo "DEVTEAM-DEPLOY-DO"; }'
fx lib/gh_config.sh 'gh_config_dir() { echo /nonexistent; }'
fx task/delivery.sh 'cmd_task_deliver() { echo "DEVTEAM-DELIVER $*"; }
cmd_task_merge_do() { echo "DEVTEAM-MERGE-DO"; }
_merge_landed_probe() { :; }
_task_merge_landed_record() { :; }
_gate_slug_from_url() { :; }'
fx task/gate_evidence.sh '_devteam_fixture_gate() { :; }'
fx task/grader_pool.sh '_devteam_fixture_pool() { :; }'
fx task/grader_process.sh '_devteam_fixture_process() { :; }'
ln -s "$VDIR" "$PL/enabled/devteam@5dive-plugins"
record() {  # record <review> <capabilities-json> <enabled>
  jq -n --arg r "$1" --argjson c "$2" --argjson e "$3" \
    '{"devteam@5dive-plugins": {plugin:"devteam", marketplace:"5dive-plugins", version:"0.2.0",
       enabled:$e, review:$r, publisher:"5dive", capabilities:$c, grants:[], verbs:[]}}' \
    > "$PL/installed.json"
  chmod 644 "$PL/installed.json"
}
LOADED="DEVTEAM-PROOF x ro=1 pace=core"

record official '["core"]' true
dv proof x
t  "B1 official, enabled, core capability, safe files: the plugin's verb runs" "$LOADED" "$OUT"
tc "B1b read on first use, from the plugin" "devteam load cmd_proof" "$ERR"
tn "B1c once (a top-level readonly survives)" "readonly variable" "$ERR"
dv version
tn "B1d a run that never touches it never reads it" "devteam load" "$ERR"
for p in "gh x:DEVTEAM-GH x" "push x:DEVTEAM-PUSH x" "push setup:DEVTEAM-PUSH-SETUP" "deploy:DEVTEAM-DEPLOY" \
         "_gh_do:DEVTEAM-GH-DO" "_push_do:DEVTEAM-PUSH-DO" "_deploy_do:DEVTEAM-DEPLOY-DO" "_merge_do:DEVTEAM-MERGE-DO" \
         "task deliver DIVE-9:DEVTEAM-DELIVER DIVE-9"; do
  # shellcheck disable=SC2086
  dv ${p%%:*}
  t "B1e '5dive ${p%%:*}' runs the plugin's function" "${p#*:}" "$OUT"
done
( set +u; source src/header.sh 2>/dev/null; source src/lib/devteam.sh; devteam_status_line ) > "$TMP/.s" 2>&1
tc "B1f doctor's line names where they come from" "loaded from $VDIR (9 modules)" "$(cat "$TMP/.s")"
rm -f "$STATE_DIR/forge-merge-poll.reading"
t  "B1g with the plugin loaded a forge-merge pass logs nothing on an empty board" "" "$(fm)"
tc "B1h because it ran: it recorded its reading" "class=ok" "$(cat "$STATE_DIR/forge-merge-poll.reading" 2>&1)"

FIVEDIVE_DEVTEAM=0 dv proof x
tc "B2 FIVEDIVE_DEVTEAM=0 skips the plugin" "$LINE" "$ERR"
record community '["core"]' true; dv proof x
tc "B3 a record whose review is community is not loaded" "$LINE" "$ERR"
record official '["verb"]' true; dv proof x
tc "B4 a record without the core capability is not loaded" "$LINE" "$ERR"
record official '["core"]' false; dv proof x
tc "B5 a disabled record is not loaded" "$LINE" "$ERR"
record official '["core"]' true
chmod 664 "$VDIR/core/task/delivery.sh"; dv proof x
tc "B6 a group-writable module is not loaded" "$LINE" "$ERR"
( set +u; source src/header.sh 2>/dev/null; source src/lib/devteam.sh; devteam_status_line ) > "$TMP/.s" 2>&1
tc "B6b and doctor says which file, with the way out" "core/task/delivery.sh is writable by someone other than root. Reinstall" "$(cat "$TMP/.s")"
tc "B8 a plugin refused at load still logs the forge-merge line, with the reason" \
   "$NOTRUN (devteam: core/task/delivery.sh is writable by someone other than root" "$(fm)"
tc "B8b and doctor does not call the poll off" "has taken no reading" "$(rm -f "$STATE_DIR/forge-merge-poll.reading"; dfm)"
chmod 644 "$VDIR/core/task/delivery.sh"
chmod 777 "$VDIR/core/task"; dv proof x
tc "B7 a world-writable module directory is not loaded" "$LINE" "$ERR"
chmod 755 "$VDIR/core/task"
chmod 666 "$PL/installed.json"; dv proof x
tc "B8 a writable install record is not trusted" "$LINE" "$ERR"
chmod 644 "$PL/installed.json"
mv "$PL/enabled/devteam@5dive-plugins" "$PL/enabled/devteam@lookalike"
jq '{"devteam@lookalike": (.["devteam@5dive-plugins"] | .marketplace = "lookalike")}' "$PL/installed.json" > "$TMP/x" && mv "$TMP/x" "$PL/installed.json"
chmod 644 "$PL/installed.json"; dv proof x
tc "B9 the same plugin under any other key is not loaded" "$LINE" "$ERR"
mv "$PL/enabled/devteam@lookalike" "$PL/enabled/devteam@5dive-plugins"
record official '["core"]' true
mv "$VDIR/core/lib/gh_config.sh" "$TMP/gh_config.sh"; dv proof x
tc "B10 a phase-1 copy (no lib/gh_config.sh) is refused whole" "$LINE" "$ERR"
( set +u; source src/header.sh 2>/dev/null; source src/lib/devteam.sh; devteam_status_line ) > "$TMP/.s" 2>&1
tc "B10b and doctor says to upgrade it" "it is older than this 5dive (no core/lib/gh_config.sh)" "$(cat "$TMP/.s")"
mv "$TMP/gh_config.sh" "$VDIR/core/lib/gh_config.sh"
printf '_pace_band() { echo HIJACKED-PACE; }\n' >> "$VDIR/core/task/grader_pool.sh"; dv proof x
tc "B11 a plugin that redefines a core function is refused whole" "$LINE" "$ERR"
fx task/grader_pool.sh '_devteam_fixture_pool() { :; }'
dv proof x
t  "B12 positive control after every negative above: it runs again" "$LOADED" "$OUT"

# A community plugin that claims `push`, with a real bin/push. It must never run:
# not without devteam (the line), and not instead of devteam.
CVD="$PL/cache/someone/pusher/0.1.0"
mkdir -p "$CVD/bin"; printf '#!/bin/sh\necho HIJACKED-PUSH\n' > "$CVD/bin/push"; chmod 755 "$CVD/bin/push"
printf '#!/bin/sh\necho COMMUNITY-HELLO\n' > "$CVD/bin/hello"; chmod 755 "$CVD/bin/hello"
ln -s "$CVD" "$PL/enabled/pusher@someone"
jq '. + {"pusher@someone": {plugin:"pusher", marketplace:"someone", version:"0.1.0", enabled:true,
        review:"community", publisher:"x", capabilities:["verb"], grants:[], verbs:[{name:"push"},{name:"hello"}]}}' \
  "$PL/installed.json" > "$TMP/x" && mv "$TMP/x" "$PL/installed.json"; chmod 644 "$PL/installed.json"
dv hello
t  "B13-pre positive control: the community plugin's own verb does run" "COMMUNITY-HELLO" "$OUT"
dv push x
t  "B13 with devteam: '5dive push' is devteam's, never the claimant's" "DEVTEAM-PUSH x" "$OUT"
FIVEDIVE_DEVTEAM=0 dv push x
tn "B13b without devteam: the claimant still does not run" "HIJACKED-PUSH" "$OUT"
tc "B13c it gets the line instead" "push $LINE" "$ERR"

# =============================================================================
# Part C — mutants. Each removes one pin; the arm it guards must go red.
# =============================================================================
mutant() {  # mutant <name> <sed-expr>  -> path of a mutated bundle
  local m="$TMP/5dive.$1"
  sed -e "$2" "$BUNDLE" > "$m"
  printf '%s' "$m"
}
BIN=$(mutant perms 's/^_devteam_path_safe() {$/_devteam_path_safe() { return 0;/')
chmod 664 "$VDIR/core/task/delivery.sh"; dv proof x; chmod 644 "$VDIR/core/task/delivery.sh"
t  "C1 mutant: no ownership/write check -> B6 would load the group-writable file" "$LOADED" "$OUT"
BIN=$(mutant review 's/(\.review == "official")/true/')
jq '.["devteam@5dive-plugins"].review = "community"' "$PL/installed.json" > "$TMP/x" && mv "$TMP/x" "$PL/installed.json"; chmod 644 "$PL/installed.json"
dv proof x
jq '.["devteam@5dive-plugins"].review = "official"' "$PL/installed.json" > "$TMP/x" && mv "$TMP/x" "$PL/installed.json"; chmod 644 "$PL/installed.json"
t  "C2 mutant: no review pin -> B3 would load a community record" "$LOADED" "$OUT"
BIN=$(mutant clash '/^_devteam_init() {$/,/^}$/ s/^    if declare -F "\$fn" >\/dev\/null 2>&1; then$/    if false; then/')
printf '_pace_band() { echo HIJACKED-PACE; }\n' >> "$VDIR/core/task/grader_pool.sh"; dv proof x
fx task/grader_pool.sh '_devteam_fixture_pool() { :; }'
tc "C3 mutant: no core-function check -> B11 would load the plugin that redefines one" "DEVTEAM-PROOF" "$OUT"
BIN=$(mutant both 's/^      if _devteam_is_verb "\$top"; then$/      if false; then/; s/^  \[\[ " \${DEVTEAM_VERBS:-.*$/  false/')
FIVEDIVE_DEVTEAM=0 dv push x
t  "C4 mutant: no reservation and no pinned fallthrough -> B13b's claimant would run as 'push'" "HIJACKED-PUSH" "$OUT"
BIN=$(mutant taskline 's/^  devteam_loaded || devteam_refuse "task \$1"$/  :/')
FIVEDIVE_DEVTEAM=0 dv task deliver DIVE-9
tn "C5 mutant: no task-verb guard -> D2 would print 'command not found' instead of the line" "task deliver $LINE" "$ERR"
BIN=$(mutant boundpr 's/^  if \[\[ "\$verb" == "done" \]\] \&\& ! devteam_loaded; then$/  if false; then/')
sqlite3 "$TASKS_DB" "UPDATE tasks SET status='in_progress', result=NULL WHERE id=2;"
FIVEDIVE_DEVTEAM=0 dv task done DIVE-2 --result="tries to close a bound PR"
t  "C6 mutant: no bound-PR refusal -> D4 would hand on a row whose PR nobody checked" "todo|quinn" "$(sqlite3 "$TASKS_DB" "SELECT status||'|'||assignee FROM tasks WHERE id=2;")"
BIN="$BUNDLE"
for _m in perms review clash both taskline boundpr; do
  cmp -s "$BUNDLE" "$TMP/5dive.$_m"
  t "C0-$_m the mutant really changed the bundle" "1" "$?"
done

# =============================================================================
# Part A — the install gate, sourced like tests/plugin_contract_unit.sh
# =============================================================================
export STATE_DIR="$TMP/state-a"
# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/lib/devteam.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
set +e -o pipefail
require_root() { :; }
JSON_MODE=0
RC=0
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}
# shellcheck source=/dev/null
. "$ROOT/tests/lib/github_fixture.sh"
gh_fixture_seam "$TMP/github"
unset FIVEDIVE_PLUGIN_REGISTRY
mkmkt() {  # mkmkt <owner> -> a fixture marketplace with devteam, corecomm and pusher
  local m="$TMP/github/$1/fixture-mkt.git" n review f
  mkdir -p "$m/.claude-plugin"
  for n in devteam corecomm; do
    review=official; [[ "$n" == corecomm ]] && review=community
    mkdir -p "$m/$n/.claude-plugin" "$m/$n/core/task" "$m/$n/core/lib"
    for f in $MOVED_FILES; do echo ': # fixture' > "$m/$n/core/$f"; done
    jq -cn --arg n "$n" --arg r "$review" \
      '{name:$n, version:"0.2.0", description:"fixture", author:{name:"t"},
        fivedive:{contract:"1", capabilities:["core"], grants:[],
                  trust:{publisher:"t", did:"did:key:t", review:$r}}}' > "$m/$n/.claude-plugin/plugin.json"
  done
  mkdir -p "$m/pusher/.claude-plugin" "$m/pusher/bin"
  printf '#!/bin/sh\necho x\n' > "$m/pusher/bin/push"; chmod 755 "$m/pusher/bin/push"
  jq -cn '{name:"pusher", version:"0.1.0", description:"fixture", author:{name:"t"},
           fivedive:{contract:"1", capabilities:["verb"], grants:[], verbs:[{name:"push"}],
                     trust:{publisher:"t", did:"did:key:t", review:"community"}}}' > "$m/pusher/.claude-plugin/plugin.json"
  jq -n '{name:"fixture", description:"t", owner:{name:"t"},
          plugins:[{name:"devteam",description:"d",category:"test",source:"./devteam"},
                   {name:"corecomm",description:"c",category:"test",source:"./corecomm"},
                   {name:"pusher",description:"p",category:"test",source:"./pusher"}]}' \
    > "$m/.claude-plugin/marketplace.json"
  gh_fixture_publish "$m"
}
mkmkt 5dive-ai
mkmkt someone

t "A0 the gate function exists (an empty source would pass every refusal vacuously)" "function" "$(type -t _plugin_core_cap_gate)"
run _plugin_mkt_add 5dive-ai/fixture-mkt --as=fixture
t "A0b fixture marketplace registers" "0" "$RC"
run cmd_plugin_add devteam@fixture --yes
t  "A1 the core capability under any key but devteam@5dive-plugins is refused" "$E_VALIDATION" "$RC"
tc "A1b and the refusal names the one key that may use it" "only 5dive's own devteam@5dive-plugins" "$ERR"
run cmd_plugin_add pusher@fixture --yes
t  "A1c a plugin declaring a dev-team verb ('push') is refused at install" "$E_VALIDATION" "$RC"
tc "A1d as a 5dive command" "declares the verb 'push', which is already a 5dive command" "$ERR"

run _plugin_mkt_add 5dive-ai/fixture-mkt --as=5dive-plugins
t "A2-pre the same source registers as 5dive-plugins" "0" "$RC"
run cmd_plugin_add corecomm@5dive-plugins --yes
tc "A2b and it is the core gate that refused it" "only 5dive's own" "$ERR"
t  "A2 a community plugin declaring core is refused, even from 5dive's marketplace" "$E_VALIDATION" "$RC"
run cmd_plugin_add devteam@5dive-plugins --yes
t  "A3 positive control: devteam@5dive-plugins from a 5dive-owned source installs" "0" "$RC"
t  "A3b and its record carries the core capability the loader looks for" "true" \
   "$(jq -r '.["devteam@5dive-plugins"] | (.capabilities | index("core") != null) and .review == "official"' "$STATE_DIR/plugins/installed.json")"
( _devteam_resolve; echo "dir=$_DEVTEAM_DIR why=$_DEVTEAM_WHY" ) > "$TMP/.r" 2>&1
tc "A3c and the loader accepts what install wrote" "dir=$STATE_DIR/plugins/cache/5dive-plugins/devteam/0.2.0" "$(cat "$TMP/.r")"

# The same plugin from somebody else's GitHub, registered under 5dive's name.
export STATE_DIR="$TMP/state-a2"
run _plugin_mkt_add someone/fixture-mkt --as=5dive-plugins
run cmd_plugin_add devteam@5dive-plugins --yes
tc "A4b and it is the core gate that refused it" "only 5dive's own" "$ERR"
t  "A4 devteam@5dive-plugins from a source 5dive does not own is refused" "$E_VALIDATION" "$RC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
