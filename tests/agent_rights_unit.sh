#!/usr/bin/env bash
# DIVE-7143: three narrow root verbs for a STANDARD seat (src/cmd_agent_rights.sh).
#
#   G  the grant: four exact lines in render_standard_sudoers, still cli-scoped
#      (bash and python classifiers), comment block free of backtick and dollar
#   P  agent _peek <name> [--lines=N]       read a TEAMMATE's pane
#   S  agent _skill_give <to> <skill>       copy my skill into a TEAMMATE's dir
#   H  heartbeat _self on|off               my OWN heartbeat, nobody else's
#   N  NEGATIVE CONTROLS: the verb source is copied, its scope check is broken
#      with sed, and the named arm is re-run against the mutant. Each must go red;
#      a control that stays green means the arm proves nothing.
#
# COVERAGE LIMIT: no unix users are made. `_rights_as` (run a fixed command as a
# user) is stubbed to run as the harness user and RECORD the user it was asked
# for, so "packed as the giver, placed as the recipient" is graded by that record,
# not by real file ownership. tmux is a stub that prints numbered lines.
#
# Run: bash tests/agent_rights_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/agent-rights.XXXXXX); TMP=$(readlink -f "$TMP")
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR/tasks" "$STATE_DIR/agents.d" "$STATE_DIR/teams"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/agent_env.sh lib/tasks_db.sh lib/actor.sh \
  cmd_agent_create.sh cmd_agent_runtime.sh cmd_heartbeat.sh cmd_agent_rights.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e +u
REGISTRY="$STATE_DIR/agents.json"; ENV_DIR="$STATE_DIR/agents.d"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
IN_REGISTRY_LOCK=1; JSON_MODE=0
P=0; F=0
pass(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
nope(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }
check(){ local name="$1"; shift; if "$@"; then pass "$name"; else nope "$name"; fi; }

# ── G: the grant ───────────────────────────────────────────────────────────────
LINES_WANT=(
  'agent _peek *'
  'agent _skill_give *'
  'heartbeat _self on'
  'heartbeat _self off'
)
for caps in '0 0' '1 1'; do
  # shellcheck disable=SC2086
  SUD=$(render_standard_sudoers agent-kost $caps)
  for l in "${LINES_WANT[@]}"; do
    [[ $(grep -cxF "agent-kost ALL=(root) NOPASSWD: /usr/local/bin/5dive $l" <<<"$SUD") == 1 ]] \
      && pass "G1 line rendered once, exact: '$l' (caps $caps)" || nope "G1 line rendered once, exact: '$l' (caps $caps)"
  done
  [[ $(grep -c 'heartbeat _self' <<<"$SUD") == 2 ]] && pass "G2 heartbeat _self has exactly its two no-wildcard lines (caps $caps)" \
    || nope "G2 heartbeat _self has exactly two lines (caps $caps)"
  [[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
    && pass "G3 rendered grant classifies cli-scoped, extra=0 (caps $caps)" \
    || nope "G3 rendered grant classifies cli-scoped, extra=0 (caps $caps) (got $(classify_sudo_grant <<<"$SUD"))"
done
[[ "$(printf 'agent-kost ALL=(root) NOPASSWD: /usr/local/bin/5dive heartbeat _self *\n' | classify_sudo_grant)" == 'custom|root|0' ]] \
  && pass 'G4 a wildcarded heartbeat _self line is NOT recognised as scoped' || nope 'G4 a wildcarded heartbeat _self line is not scoped'
[[ "$(printf 'agent-kost ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _peek\n' | classify_sudo_grant)" == 'custom|root|0' ]] \
  && pass 'G4b only the exact _peek spelling is recognised' || nope 'G4b only the exact _peek spelling is recognised'
PYC=$(awk '/^def classify_sudo\(/{p=1} p&&/^sudo_sources = \[\]/{exit} p' "$SRC/cmd_agent.sh")
if [[ -n "$PYC" ]] && command -v python3 >/dev/null; then
  got=$(SUDTXT="$(render_standard_sudoers agent-kost 0 0)" python3 -c "import os, re
$PYC
r = classify_sudo(os.environ['SUDTXT'], True)
print(r['grant'], r['impliedIsolation'], r['extraEntries'])")
  [[ "$got" == 'cli-scoped standard False' ]] && pass 'G5 python classifier: standard, no extra entries' \
    || nope "G5 python classifier: standard, no extra entries (got $got)"
else
  nope 'G5 python classifier extractable'
fi
blk=$(awk '/DIVE-7143: three acts/{p=1} p&&/^[$][{]user[}]/{exit} p{print}' "$SRC/cmd_agent_create.sh")
[[ -n "$blk" && "$blk" != *'`'* && "$blk" != *'$'* ]] \
  && pass 'G6 heredoc comment carries no backtick or dollar' || nope 'G6 heredoc comment carries no backtick or dollar'

# ── the fake box ───────────────────────────────────────────────────────────────
# alice bob sandy: team acme.  dave reports to alice (org edge only).
# lena leads legacy team "old" (manifest, no membership rows); leo reports to lena.
# carol: standard, shares nothing.  ghost: registered, no seat user.
cat >"$REGISTRY" <<'JSON'
{"agents":{
 "alice":{"type":"claude","isolation":"standard"},
 "bob":{"type":"codex","isolation":"standard","heartbeat":{"enabled":false,"everyMin":45,"fresh":true,"lastRunAt":123}},
 "carol":{"type":"claude","isolation":"standard","heartbeat":{"enabled":true,"everyMin":10,"fresh":false,"lastRunAt":7}},
 "sandy":{"type":"claude","isolation":"sandboxed"},
 "dave":{"type":"claude","isolation":"standard"},
 "lena":{"type":"claude","isolation":"standard"},
 "leo":{"type":"claude","isolation":"standard"},
 "ghost":{"type":"claude","isolation":"standard"},
 "nomeas":{"type":"claude"},
 "boss":{"type":"claude","isolation":"admin"}
}}
JSON
for n in alice bob carol dave lena leo ghost; do printf 'AGENT_ISOLATION=standard\n' >"$ENV_DIR/$n.env"; done
printf 'AGENT_ISOLATION=admin\n' >"$ENV_DIR/boss.env"   # boss: an admin seat on team acme
printf 'AGENT_ISOLATION=standard\n' >"$ENV_DIR/sandy.env"   # env says standard, registry says sandboxed
tasks_db_init >/dev/null 2>&1
db "INSERT INTO projects (key, prefix, lead_agent) VALUES ('acme','ACME','alice'), ('old','OLD','lena');
    INSERT INTO team_members (team, agent, reports_to) VALUES ('acme','alice',NULL),('acme','bob','alice'),('acme','sandy','alice'),('acme','boss',NULL);
    INSERT INTO agents_org (name, reports_to) VALUES ('alice',NULL),('lena',NULL);
    INSERT INTO agents_org (name, reports_to) VALUES ('bob','alice'),('dave','alice'),('leo','lena'),('carol',NULL);" \
  || nope 'fixture: tasks db seeded'
: >"$STATE_DIR/teams/old.5dive.yaml"

ROOT=1
_gate_is_root() { (( ROOT )); }
actor_uid_to_name() {
  case "$1" in 1001) echo agent-alice ;; 1002) echo agent-bob ;; 1003) echo agent-carol ;; 1004) echo agent-sandy ;;
    1005) echo agent-dave ;; 1006) echo agent-leo ;; 1007) echo agent-boss ;; 1000) echo claude ;; *) echo "user$1" ;; esac
}
audit_log() { printf '%s\n' "$*" >>"$TMP/audit"; }
registry_write() { cat >"$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"; }
require_root() { (( ROOT )) || fail "$E_PERMISSION" "must run as root"; }
_rights_home() { printf '%s/home/agent-%s' "$TMP" "$1"; }
_rights_seat_user() { [[ "$1" != ghost ]]; }
_rights_as() { printf '%s %s\n' "$1" "$2" >>"$TMP/as"; shift; "$@"; }
TMUX_UP=1
tmux() {
  printf '%s\n' "$*" >>"$TMP/tmux"
  (( TMUX_UP )) || return 1
  local i; for ((i = 1; i <= 600; i++)); do printf 'pane line %d\n' "$i"; done
}
reset() { : >"$TMP/tmux"; : >"$TMP/as"; : >"$TMP/audit"; }
peek() { reset; ( cmd_agent_peek_delegated "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?; }
give() { reset; ( cmd_agent_skill_give_delegated "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?; }
hb()   { reset; ( cmd_heartbeat_self_delegated "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?; }
refused_quiet() { [[ $RC != 0 && ! -s "$TMP/tmux" ]]; }

# ── P: agent _peek ─────────────────────────────────────────────────────────────
arm_P1() { SUDO_UID=1001 peek bob; [[ $RC == 0 && $(grep -c '' "$TMP/out") == 80 && "$(tail -1 "$TMP/out")" == 'pane line 600' ]] \
  && grep -qF 'capture-pane -p -J -t agent-bob -S -80' "$TMP/tmux" && grep -q '^agent-bob tmux$' "$TMP/as" \
  && grep -q 'agent _peek ok 0 -- by=alice target=bob lines=80' "$TMP/audit"; }
check 'P1 alice peeks teammate bob: last 80 lines, fixed capture as agent-bob, audited' arm_P1
arm_P2() { SUDO_UID=1001 peek bob --lines=5; [[ $RC == 0 && $(grep -c '' "$TMP/out") == 5 ]]; }
check 'P2 --lines=5 prints 5 lines' arm_P2
arm_P3() { local l; for l in 0 501 -3 abc 99999; do SUDO_UID=1001 peek bob "--lines=$l"; refused_quiet || return 1; done; }
check 'P3 --lines outside 1..500 (0 501 -3 abc 99999) refused before tmux' arm_P3
arm_P4() { SUDO_UID=1001 peek carol; refused_quiet && [[ $RC == "$E_PERMISSION" ]] && grep -q 'not your teammate' "$TMP/err" \
  && grep -q 'agent _peek refused' "$TMP/audit"; }
check 'P4 alice -> carol (no shared team): refused, not your teammate, audited' arm_P4
arm_P5() { SUDO_UID=1001 peek sandy; refused_quiet && grep -q 'sandboxed' "$TMP/err"; }
check 'P5 sandboxed teammate (registry says so, env does not): refused' arm_P5
arm_P5b() { db "INSERT INTO team_members (team, agent) VALUES ('acme','nomeas');"; SUDO_UID=1001 peek nomeas; local ok=0
  refused_quiet && grep -q 'not measured' "$TMP/err" && ok=1; db "DELETE FROM team_members WHERE agent='nomeas';"; (( ok )); }
check 'P5b teammate whose isolation is unmeasured: refused (fail closed)' arm_P5b
arm_P6() { SUDO_UID=1001 peek alice; refused_quiet && grep -q 'is you' "$TMP/err"; }
check 'P6 self: refused' arm_P6
arm_P7() { SUDO_UID=1001 peek nobody; refused_quiet && [[ $RC == "$E_NOT_FOUND" ]]; }
check 'P7 unknown agent: refused E_NOT_FOUND' arm_P7
arm_P8() { db "INSERT INTO team_members (team, agent) VALUES ('acme','ghost');"; SUDO_UID=1001 peek ghost; local ok=0
  refused_quiet && grep -q 'no agent-ghost seat user' "$TMP/err" && ok=1; db "DELETE FROM team_members WHERE agent='ghost';"; (( ok )); }
check 'P8 registered but no seat user: refused' arm_P8
arm_P9() { local n; for n in ../bob Bob 'bob;id' -bob 'bob x' "$(printf 'a%.0s' {1..40})"; do
  SUDO_UID=1001 peek "$n"; refused_quiet || return 1; done; }
check 'P9 bad names (traversal, case, ;, leading dash, space, 40 chars) refused before tmux' arm_P9
arm_P10() { SUDO_UID=1005 peek alice; [[ $RC == 0 ]]; }
check 'P10 org edge: dave (reports to alice, no team row) peeks alice' arm_P10
arm_P11() { SUDO_UID=1006 peek lena; [[ $RC == 0 ]] || return 1
  mv "$STATE_DIR/teams/old.5dive.yaml" "$TMP/old.bak"; SUDO_UID=1006 peek lena; local rc=$RC; mv "$TMP/old.bak" "$STATE_DIR/teams/old.5dive.yaml"
  [[ $rc == 0 ]]; }
check 'P11 legacy team: leo peeks lead lena via the org subtree (org edge also holds)' arm_P11
arm_P11b() { db "INSERT INTO agents_org (name, reports_to) VALUES ('lou','leo');"
  jq '.agents.lou={"type":"claude","isolation":"standard"}' "$REGISTRY" >"$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
  printf 'AGENT_ISOLATION=standard\n' >"$ENV_DIR/lou.env"
  actor_uid_to_name() { case "$1" in 1007) echo agent-lou ;; 1001) echo agent-alice ;; *) echo "user$1" ;; esac; }
  SUDO_UID=1007 peek lena; local a=$RC
  mv "$STATE_DIR/teams/old.5dive.yaml" "$TMP/old.bak"; SUDO_UID=1007 peek lena; local b=$RC
  mv "$TMP/old.bak" "$STATE_DIR/teams/old.5dive.yaml"
  actor_uid_to_name() {
    case "$1" in 1001) echo agent-alice ;; 1002) echo agent-bob ;; 1003) echo agent-carol ;; 1004) echo agent-sandy ;;
      1005) echo agent-dave ;; 1006) echo agent-leo ;; 1007) echo agent-boss ;; 1000) echo claude ;; *) echo "user$1" ;; esac; }
  [[ $a == 0 && $b != 0 ]]; }
check 'P11b legacy subtree: lou (two levels under lena) peeks her; without the team manifest, refused' arm_P11b
arm_P12() { ROOT=0; SUDO_UID=1001 peek bob; local rc=$RC; ROOT=1; [[ $rc == "$E_PERMISSION" && ! -s "$TMP/tmux" ]]; }
check 'P12 not root: refused' arm_P12
arm_P13() { SUDO_UID="" peek carol; [[ $RC == 0 ]] && grep -q 'by=root target=carol' "$TMP/audit"; }
check 'P13 root itself (no sudo caller) may read any non-sandboxed agent' arm_P13
arm_P14() { SUDO_UID=1000 peek bob; refused_quiet; } ; check 'P14 a sudo caller that is no agent seat (claude): refused' arm_P14
arm_P15() { SUDO_UID=1001 peek bob --tmux; refused_quiet || return 1; SUDO_UID=1001 peek bob carol; refused_quiet; }
check 'P15 unknown flag / second name refused' arm_P15
arm_P16() { TMUX_UP=0; SUDO_UID=1001 peek bob; local rc=$RC; TMUX_UP=1; [[ $rc == "$E_NOT_RUNNING" ]]; }
check 'P16 no tmux session: E_NOT_RUNNING' arm_P16
arm_P17() { JSON_MODE=1; SUDO_UID=1001 peek bob --lines=3; JSON_MODE=0
  [[ $RC == 0 && "$(jq -r '.ok, .data.name, (.data.lines|length)' "$TMP/out" | paste -sd' ')" == 'true bob 3' ]]; }
check 'P17 --json: envelope {name, source, lines}' arm_P17

# ── S: agent _skill_give ───────────────────────────────────────────────────────
AS="$TMP/home/agent-alice/.claude/skills"; BS="$TMP/home/agent-bob/.agents/skills"
mkdir -p "$AS/good/sub" "$AS/linky" "$AS/real" "$AS/big" "$AS/many" "$AS/hard" "$TMP/home/agent-bob"
printf 'name: good\n' >"$AS/good/SKILL.md"; printf 'ref\n' >"$AS/good/sub/ref.md"
printf 'x\n' >"$AS/linky/SKILL.md"; ln -s /etc/passwd "$AS/linky/pw"
printf 'x\n' >"$AS/real/SKILL.md"; ln -s "$AS/real" "$AS/toplink"
head -c $((6 * 1024 * 1024)) /dev/zero >"$AS/big/blob"
for ((i = 0; i < 501; i++)); do : >"$AS/many/f$i"; done
printf 'x\n' >"$AS/hard/a"; ln "$AS/hard/a" "$AS/hard/b"

arm_S1() { SUDO_UID=1001 give bob good; [[ $RC == 0 ]] && cmp -s "$AS/good/SKILL.md" "$BS/good/SKILL.md" \
  && cmp -s "$AS/good/sub/ref.md" "$BS/good/sub/ref.md" && ! compgen -G "$BS/.give-*" >/dev/null \
  && grep -q 'agent _skill_give ok 0 -- by=alice to=bob skill=good files=2' "$TMP/audit"; }
check "S1 alice gives 'good' to bob: lands in bob's codex skills dir, both files, no staging left, audited" arm_S1
arm_S1b() { [[ "$(paste -sd, "$TMP/as")" == 'agent-alice tar,agent-bob bash' ]]; }
check 'S1b packed AS agent-alice, placed AS agent-bob (never as root)' arm_S1b
arm_S2() { printf 'mine\n' >"$BS/good/MARK"; SUDO_UID=1001 give bob good; [[ $RC == "$E_CONFLICT" && -f "$BS/good/MARK" ]] \
  && grep -q -- '--replace' "$TMP/err"; }
check 'S2 existing skill, no --replace: refused E_CONFLICT, recipient copy untouched' arm_S2
arm_S3() { SUDO_UID=1001 give bob good --replace; [[ $RC == 0 && ! -e "$BS/good/MARK" && -f "$BS/good/SKILL.md" ]]; }
check 'S3 --replace overwrites it' arm_S3
nothing_at() { [[ ! -e "$BS/$1" ]]; }
arm_S4() { SUDO_UID=1001 give bob linky; [[ $RC != 0 ]] && grep -q 'symlink' "$TMP/err" && nothing_at linky && ! grep -q 'agent-bob' "$TMP/as"; }
check 'S4 a symlink inside the skill: refused before placement' arm_S4
arm_S5() { SUDO_UID=1001 give bob toplink; [[ $RC != 0 ]] && nothing_at toplink && [[ ! -s "$TMP/as" ]]; }
check 'S5 the skill dir itself is a symlink: refused before packing' arm_S5
arm_S5b() { mv "$AS" "$TMP/realskills"; ln -s "$TMP/realskills" "$AS"; SUDO_UID=1001 give bob good --replace; local rc=$RC
  rm "$AS"; mv "$TMP/realskills" "$AS"; [[ $rc != 0 && ! -s "$TMP/as" ]]; }
check 'S5b a symlinked parent (the skills dir) is refused too' arm_S5b
arm_S6() { SUDO_UID=1001 give bob big; [[ $RC == "$E_VALIDATION" ]] && grep -q 'MB limit' "$TMP/err" && nothing_at big; }
check 'S6 over 5 MB: refused' arm_S6
arm_S7() { SUDO_UID=1001 give bob many; [[ $RC == "$E_VALIDATION" ]] && grep -q '501 files' "$TMP/err" && nothing_at many; }
check 'S7 over 500 files: refused' arm_S7
arm_S8() { SUDO_UID=1001 give bob hard; [[ $RC != 0 ]] && grep -q 'hard link' "$TMP/err" && nothing_at hard; }
check 'S8 a hard link inside the skill: refused' arm_S8
arm_S9() { SUDO_UID=1001 give carol good; [[ $RC == "$E_PERMISSION" ]] && grep -q 'not your teammate' "$TMP/err" \
  && [[ ! -s "$TMP/as" && ! -e "$TMP/home/agent-carol" ]]; }
check 'S9 alice -> carol (not a teammate): refused, nothing packed or written' arm_S9
arm_S10() { SUDO_UID=1001 give sandy good; [[ $RC == "$E_PERMISSION" && ! -s "$TMP/as" ]]; }
check 'S10 sandboxed teammate: refused' arm_S10
arm_S11() { SUDO_UID=1001 give alice good; [[ $RC != 0 && ! -s "$TMP/as" ]]; }
check 'S11 self: refused' arm_S11

# ── U: never up a tier (a standard member and its admin teammate) ──────────────
arm_U1() { SUDO_UID=1001 peek boss; refused_quiet && [[ $RC == "$E_PERMISSION" ]] && grep -q 'wider seat' "$TMP/err" \
  && grep -q 'agent _peek refused' "$TMP/audit"; }
check "U1 standard alice peeks admin teammate boss: refused (a key in the lead's pane would leak), audited" arm_U1
arm_U2() { SUDO_UID=1001 give boss good; [[ $RC == "$E_PERMISSION" ]] && grep -q 'wider seat' "$TMP/err" \
  && [[ ! -s "$TMP/as" && ! -e "$TMP/home/agent-boss" ]]; }
check "U2 standard alice gives admin boss a skill: refused before packing (it would load as boss's own instructions)" arm_U2
arm_U3() { SUDO_UID=1007 peek alice; [[ $RC == 0 && $(grep -c '' "$TMP/out") == 80 ]]; }
check 'U3 admin boss peeks standard teammate alice: allowed (down a tier)' arm_U3
arm_S12() { SUDO_UID=1001 give nobody good; [[ $RC == "$E_NOT_FOUND" && ! -s "$TMP/as" ]]; }
check 'S12 unknown agent: refused' arm_S12
arm_S13() { local k; for k in ../good .hidden -r a/b 'a b' '' good/..; do SUDO_UID=1001 give bob "$k"; [[ $RC != 0 && ! -s "$TMP/as" ]] || return 1; done; }
check "S13 bad skill names (../good .hidden -r a/b 'a b' empty good/..) refused" arm_S13
arm_S14() { SUDO_UID=1001 give bob nosuch; [[ $RC == "$E_NOT_FOUND" && ! -s "$TMP/as" ]]; }
check 'S14 a skill the giver does not have: refused' arm_S14
arm_S15() { SUDO_UID= give bob good --replace; [[ $RC == "$E_AUTH_REQUIRED" && ! -s "$TMP/as" ]]; }
check 'S15 root with no sudo caller: refused (there is no giver)' arm_S15
arm_S16() { ROOT=0; SUDO_UID=1001 give bob good --replace; local rc=$RC; ROOT=1; [[ $rc == "$E_PERMISSION" && ! -s "$TMP/as" ]]; }
check 'S16 not root: refused' arm_S16
arm_S17() { SUDO_UID=1001 give bob good --force; [[ $RC == "$E_USAGE" && ! -s "$TMP/as" ]]; }
check 'S17 unknown flag refused' arm_S17
mkdir -p "$TMP/home/agent-dave/.claude/skills/good"; printf 'dave\n' >"$TMP/home/agent-dave/.claude/skills/good/SKILL.md"
arm_S18() { SUDO_UID=1005 give alice good; [[ $RC == "$E_CONFLICT" ]] || return 1
  mkdir -p "$TMP/home/agent-dave/.claude/skills/dv"; printf 'dave\n' >"$TMP/home/agent-dave/.claude/skills/dv/SKILL.md"
  SUDO_UID=1005 give alice dv; [[ $RC == 0 && "$(cat "$AS/dv/SKILL.md")" == dave ]]; }
check 'S18 org edge: dave gives to his manager alice (and still cannot clobber her skill)' arm_S18

# ── H: heartbeat _self ─────────────────────────────────────────────────────────
hbf() { jq -c --arg n "$1" '.agents[$n].heartbeat' "$REGISTRY"; }
CAROL_BEFORE=$(hbf carol)
arm_H1() { SUDO_UID=1001 hb on; [[ $RC == 0 && "$(hbf alice)" == '{"enabled":true,"everyMin":30,"fresh":false,"lastRunAt":0}' ]] \
  && grep -q 'heartbeat _self on ok 0 -- by=alice' "$TMP/audit"; }
check 'H1 alice: _self on enrols alice (defaults), audited' arm_H1
arm_H2() { SUDO_UID=1002 hb on; [[ $RC == 0 && "$(hbf bob)" == '{"enabled":true,"everyMin":45,"fresh":true,"lastRunAt":123}' ]]; }
check "H2 bob: _self on keeps bob's own cadence, fresh and throttle" arm_H2
arm_H3() { SUDO_UID=1002 hb off; [[ $RC == 0 && "$(hbf bob)" == '{"enabled":false,"everyMin":45,"fresh":true,"lastRunAt":123}' ]]; }
check 'H3 bob: _self off pauses, settings kept' arm_H3
arm_H4() { local before; before=$(cat "$REGISTRY")
  SUDO_UID=1001 hb on carol; [[ $RC == "$E_USAGE" ]] || return 1
  SUDO_UID=1001 hb on --every=5; [[ $RC == "$E_USAGE" ]] || return 1
  SUDO_UID=1001 hb; [[ $RC == "$E_USAGE" ]] || return 1
  SUDO_UID=1001 hb toggle; [[ $RC == "$E_USAGE" ]] || return 1
  [[ "$(cat "$REGISTRY")" == "$before" ]]; }
check 'H4 any argument beyond on|off (a name, a flag, nothing, other op) refused, registry untouched' arm_H4
arm_H5() { SUDO_UID=1000 hb on; [[ $RC == "$E_AUTH_REQUIRED" ]] || return 1; SUDO_UID= hb on; [[ $RC == "$E_AUTH_REQUIRED" ]] || return 1
  ROOT=0; SUDO_UID=1001 hb on; local rc=$RC; ROOT=1; [[ $rc == "$E_PERMISSION" ]]; }
check 'H5 non-agent sudo caller, no sudo caller, not root: all refused' arm_H5
arm_H6() { [[ "$(hbf carol)" == "$CAROL_BEFORE" ]]; }
check "H6 carol's heartbeat never changed by anyone else's _self" arm_H6

# ── dispatch wiring ────────────────────────────────────────────────────────────
grep -q '_peek)       cmd_agent_peek_delegated "\$@"' "$SRC/main.sh" && grep -q '_skill_give) cmd_agent_skill_give_delegated "\$@"' "$SRC/main.sh" \
  && grep -q 'peek)        cmd_agent_peek "\$@"' "$SRC/main.sh" && pass 'W1 main.sh dispatches agent peek/_peek/_skill_give' || nope 'W1 main.sh dispatch'
grep -q '_self)           cmd_heartbeat_self_delegated "\$@"' "$SRC/cmd_heartbeat.sh" && grep -q 'give)      cmd_agent_skill_give "\$name"' "$SRC/cmd_skill.sh" \
  && pass 'W2 heartbeat _self and skill give dispatch' || nope 'W2 heartbeat _self and skill give dispatch'
grep -qx '  src/cmd_agent_rights.sh' build.sh && pass 'W3 build.sh bundles cmd_agent_rights.sh' || nope 'W3 build.sh bundles the module'

# ── N: negative controls, on a mutated COPY of the verb source ─────────────────
mutant() {  # mutant <label> <sed-expr> <arm> — the arm must go RED on the mutant
  local label="$1" expr="$2" arm="$3" m="$TMP/mutant.sh"
  sed "$expr" "$SRC/cmd_agent_rights.sh" >"$m"
  if cmp -s "$m" "$SRC/cmd_agent_rights.sh"; then nope "N $label: the mutation did not apply"; return; fi
  local out
  out=$( ( source "$m"
       _rights_home() { printf '%s/home/agent-%s' "$TMP" "$1"; }
       _rights_seat_user() { [[ "$1" != ghost ]]; }
       _rights_as() { printf '%s %s\n' "$1" "$2" >>"$TMP/as"; shift; "$@"; }
       arm_P2 && echo control-green
       "$arm" && echo arm-green ) 2>/dev/null | grep -E '^(control|arm)-green$' | paste -sd, )
  case "$out" in
    control-green) pass "N $label: $arm goes RED on the mutant (control arm_P2 stays green on it)" ;;
    *arm-green*)   nope "N $label: $arm stayed GREEN on the mutant (it proves nothing)" ;;
    *)             nope "N $label: the mutant is broken (control arm_P2 red), so the red proves nothing" ;;
  esac
}
mutant 'teammate check removed from the shared scope' 's/^  _rights_teammates "\$by" "\$to" \\$/  true \\/' arm_P4
mutant 'teammate check removed (skill give)'          's/^  _rights_teammates "\$by" "\$to" \\$/  true \\/' arm_S9
mutant 'tier check removed from the shared scope'     's/^  (( \$(_rights_tier_rank "\$to" 9) <= \$(_rights_tier_rank "\$by" 0) )) \\$/  true \\/' arm_U1
mutant 'symlink refusal removed from the tar check'   "s/^      l) printf 'it contains a symlink.*/      l) ;;/" arm_S4
mutant 'heartbeat _self arg-count check widened'      's/\[\[ \$# -eq 1 && ( "\$1" == on/[[ $# -ge 1 \&\& ( "$1" == on/' arm_H4

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
