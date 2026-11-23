#!/usr/bin/env bash
# DIVE-9107 — a whole team as ONE .tar.gz: `team export` / `team import <file>`.
#
# WHAT IS PINNED, through the real export, the real unpack, the real parser and
# the real `up` (only the per-agent CLI calls, the agent pack writer and the
# box's registry are replaced):
#   E1  a 3-agent team exports to one file: manifest.json (kind 5dive-team),
#       team.5dive.yaml and one pack per member;
#   E2  the yaml keeps roles, the team-local reporting lines, the role text, the
#       persona slug where there is one, and points each seat at its own pack;
#   E3  memory is off by default; --with-memory seals the distilled set into
#       each member's pack (agent export --approve-memory);
#   E4  a team with no members on the box is refused, naming the team;
#   I1  the file imports on a fresh box: every seat from its OWN pack file inside
#       the unpacked bundle, never by slug, and the org edges are wired;
#   I2  the saved manifest keeps no pack_file (the staged files are gone);
#   N1  a bundle with a `../` member is refused before extraction, nothing made;
#   N2  a bundle with a symlink member is refused the same;
#   N3  a gzip that is not a team file is refused, pointing at agent import;
#   N4  a pack_file that climbs, is absolute, or is not a .tar.gz fails the parser;
#   N5  a seat whose pack file is missing refuses the whole team before any agent.
#
# COVERAGE LIMIT: agents are not provisioned (that needs real unix users) and
# `agent export`/`agent import` themselves are not run: each has its own
# harness. What is graded is the file's shape and which argv the roster is
# brought up with.
#
# Run: bash tests/team_bundle_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_bundle_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh src/cmd_pack.sh src/cmd_team_pack.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-bundle.XXXXXX)"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR" "$TMP/tmpd"
tasks_db_init
export TMPDIR="$TMP/tmpd"
export TEAM_AUTH_PROFILE=fixture

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# ---- the exporting box: three agents, one of them a marketplace persona ------
REG_SRC='{"agents":{"boss":{"type":"claude","pack":{"slug":"olivia"}},"ana":{"type":"claude"},"wri":{"type":"codex"},"outsider":{"type":"claude"},"helper":{"type":"claude","system":"helper"}}}'
REG="$REG_SRC"
registry_read()   { printf '%s' "$REG"; }
require_root()    { :; }
ensure_state()    { :; }
ensure_state_ro() { :; }
resolve_agent_model()  { [[ "$1" == claude ]] && printf 'claude-opus-5-5' || :; }
resolve_agent_effort() { :; }
PERSONA="$TMP/persona"; mkdir -p "$PERSONA"
persona_target() { printf '%s/%s.md' "$PERSONA" "$1"; }
for n in boss ana wri; do
  printf '# %s pack text\n\n# Working comms (chat / Telegram / team)\nseat block\n\n## Role: %s role\n\nDo the %s work well.\nSecond line.\n\n## Reporting\n- You report to **x**.\n' \
    "$n" "$n" "$n" >"$PERSONA/$n.md"
done
db "INSERT INTO team_members (team, agent, reports_to) VALUES
      ('research','boss',NULL),('research','ana','boss'),('research','wri','outsider'),('research','helper','boss');
    INSERT INTO agents_org (name, role, reports_to) VALUES
      ('boss','Head of research',NULL),('outsider',NULL,NULL),('ana','Analyst','boss'),('wri','Writer','outsider');" >/dev/null \
  || { echo "fixture: could not seed the team"; exit 1; }
# agent export: a minimal pack per member, its argv recorded.
export EXPLOG="$TMP/export.log"; : >"$EXPLOG"
cmd_export() {
  local name="" out="" a; local -a all=("$@")
  while (( $# )); do case "$1" in -o) out="$2"; shift ;; -*) ;; *) name="$1" ;; esac; shift; done
  printf '%s\n' "${all[*]}" >>"$EXPLOG"
  local d; d=$(mktemp -d); printf '{"packFormat":1,"name":"%s"}\n' "$name" >"$d/manifest.json"
  tar -czf "$out" -C "$d" manifest.json; rm -rf "$d"
}
_share_memory_distill() { mkdir -p "$2"; printf 'fact\n' >"$2/a.md"; printf '2 1\n'; }

# ============ E1/E2. export a 3-agent team ===================================
( cmd_team export research -o "$TMP/research.team.tar.gz" ) >"$TMP/e1.out" 2>&1; rc=$?
eq_t 'E1 team export succeeds' '0' "$rc"
listing=$(tar -tzf "$TMP/research.team.tar.gz" 2>/dev/null | sort | tr '\n' ' ')
eq_t 'E1b one file: manifest, team yaml, one pack per member (system seat left out)' \
  'manifest.json packs/ packs/ana.tar.gz packs/boss.tar.gz packs/wri.tar.gz team.5dive.yaml ' "$listing"
mkdir -p "$TMP/e1"; tar -xzf "$TMP/research.team.tar.gz" -C "$TMP/e1"
eq_t 'E1c the manifest says what it is' '5dive-team research false boss,ana,wri' \
  "$(jq -r '"\(.kind) \(.team) \(.memory) \(.agents | join(","))"' "$TMP/e1/manifest.json")"
spec=$(_compose_parse "$TMP/e1/team.5dive.yaml" 2>"$TMP/e1.err"); rc=$?
if (( rc == 0 )) && ! grep -q 'unknown key' "$TMP/e1.err"; then ok_t 'E2 the team yaml parses, no unknown key'
else bad_t 'E2 the team yaml does not parse' "rc=$rc $(cat "$TMP/e1.err")"; fi
eq_t 'E2b roles' 'Head of research|Analyst|Writer' "$(jq -r '[.agents.boss.role, .agents.ana.role, .agents.wri.role] | join("|")' <<<"$spec")"
eq_t 'E2c reporting lines: inside the team kept; one whose manager is outside reports to the lead' 'null|boss|boss' \
  "$(jq -r '[.agents.boss.reports_to, .agents.ana.reports_to, .agents.wri.reports_to] | map(tostring) | join("|")' <<<"$spec")"
eq_t 'E2d each seat points at its own pack file' 'packs/boss.tar.gz packs/ana.tar.gz packs/wri.tar.gz' \
  "$(jq -r '[.agents[].pack_file] | join(" ")' <<<"$spec")"
eq_t 'E2e the persona slug rides where there is one, and only there' 'olivia|null' \
  "$(jq -r '[.agents.boss.pack, .agents.ana.pack] | map(tostring) | join("|")' <<<"$spec")"
eq_t 'E2f the role text (not the seat blocks, not the reporting list) rides once' $'Do the ana work well.\nSecond line.' \
  "$(jq -r '.agents.ana.instructions' <<<"$spec")"
eq_t 'E3 memory off by default: no member was packed with memory' '0' "$(grep -c 'approve-memory' "$EXPLOG")"

: >"$EXPLOG"
( cmd_team export research -o "$TMP/mem.tar.gz" --with-memory ) >"$TMP/e3.out" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(grep -c -- '--approve-memory=' "$EXPLOG")" == 3 ]] \
   && [[ "$(tar -xzOf "$TMP/mem.tar.gz" manifest.json | jq -r .memory)" == true ]]; then
  ok_t 'E3b --with-memory seals each member'"'"'s distilled memory into its pack'
else
  bad_t 'E3b --with-memory did not reach the packs' "rc=$rc $(cat "$EXPLOG")"
fi
( cmd_team export nosuch -o "$TMP/x.tar.gz" ) >"$TMP/e4.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q "no team 'nosuch'" "$TMP/e4.out" && [[ ! -e "$TMP/x.tar.gz" ]]; then
  ok_t 'E4 an unknown team is refused, naming it, and writes no file'
else
  bad_t 'E4 an unknown team was not refused' "rc=$rc $(tail -2 "$TMP/e4.out")"
fi

# ============ I1. import it on a fresh box ===================================
REG='{"agents":{}}'
db "DELETE FROM team_members; DELETE FROM agents_org; DELETE FROM projects;" >/dev/null 2>&1
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
export REC="$TMP/rec.log"; : >"$REC"
_compose_self() { printf '%s' "$TMP/fake5dive"; }
persona_append_block() { printf '%s' "$3" >> "$PERSONA/new-$1.md"; }
_teams_get() { printf 'REGISTRY %s\n' "$1" >>"$TMP/registry.log"; return 1; }

( cmd_team import "$TMP/research.team.tar.gz" ) >"$TMP/i1.out" 2>&1; rc=$?
eq_t 'I1 team import <file.tar.gz> succeeds' '0' "$rc"
imports=$(grep '^agent import ' "$REC")
ok_all=1
for n in boss ana wri; do
  grep -qE "^agent import /[^ ]*/packs/${n}\.tar\.gz --as=${n}( |$)" <<<"$imports" || ok_all=0
done
if (( ok_all )); then ok_t 'I1b every seat imports from its own pack file in the bundle'
else bad_t 'I1b the seats did not import from their files' "$imports"; fi
eq_t 'I1c never by slug' '' "$(grep -E '^agent import (olivia|boss|ana|wri)( |$)' "$REC")"
eq_t 'I1d the team registry was never asked' '' "$(cat "$TMP/registry.log" 2>/dev/null)"
if grep -qE 'org.*ana.*boss' "$REC"; then ok_t 'I1e the org edge ana -> boss is wired'
else bad_t 'I1e no org wiring for ana -> boss' "$(grep -i org "$REC" | head -3)"; fi
if grep -q 'Do the ana work well.' "$PERSONA/new-ana.md" 2>/dev/null; then ok_t 'I1f the role text is written to the new seat'
else bad_t 'I1f the role text did not reach the seat' "$(cat "$PERSONA/new-ana.md" 2>&1 | head -3)"; fi
eq_t 'I1g the team is recorded under its name, led by its root' 'boss' \
  "$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key='research';" 2>/dev/null)"
WANT="$STATE_DIR/teams/research.5dive.yaml"
if [[ -f "$WANT" ]] && ! grep -q 'pack_file' "$WANT"; then ok_t 'I2 the saved manifest keeps no pack_file'
else bad_t 'I2 manifest missing or still names the staged packs' "$(grep -n pack_file "$WANT" 2>&1 | head -2)"; fi
eq_t 'I2b no unpacked bundle is left in TMPDIR' '' "$(find "$TMP/tmpd" -name 'team.5dive.yaml' 2>/dev/null)"

# ============ N1/N2. unsafe bundles ==========================================
mkdir -p "$TMP/evil/in" "$TMP/evil/out"
cp "$TMP/e1/manifest.json" "$TMP/e1/team.5dive.yaml" "$TMP/evil/in/"
printf 'x\n' >"$TMP/evil/out/escape.txt"
# GNU tar strips a leading ../ when it CREATES an archive, so the member is written by hand.
python3 -I - "$TMP/evil" <<'PY2'
import sys, tarfile
d = sys.argv[1]
with tarfile.open(d + "/../trav.tar.gz", "w:gz") as t:
    t.add(d + "/in/manifest.json", "manifest.json")
    t.add(d + "/in/team.5dive.yaml", "team.5dive.yaml")
    t.add(d + "/out/escape.txt", "../out/escape.txt")
PY2
ln -s /etc "$TMP/evil/in/link"
tar -czf "$TMP/link.tar.gz" -C "$TMP/evil/in" manifest.json team.5dive.yaml link
for case in trav link; do
  : >"$REC"
  ( cmd_team import "$TMP/$case.tar.gz" ) >"$TMP/$case.out" 2>&1; rc=$?
  label=$([[ $case == trav ]] && echo 'N1 a ../ member' || echo 'N2 a symlink member')
  if (( rc != 0 )) && grep -q 'path outside the file or a link' "$TMP/$case.out" && [[ ! -s "$REC" ]]; then
    ok_t "$label is refused before extraction; nothing is created"
  else
    bad_t "$label was not refused" "rc=$rc rec=$(cat "$REC") $(tail -2 "$TMP/$case.out")"
  fi
done
mkdir -p "$TMP/onepack"; printf '{"packFormat":1}\n' >"$TMP/onepack/manifest.json"
tar -czf "$TMP/onepack.tar.gz" -C "$TMP/onepack" manifest.json
( cmd_team import "$TMP/onepack.tar.gz" ) >"$TMP/n3.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'is not a team file' "$TMP/n3.out" && grep -q 'agent import' "$TMP/n3.out"; then
  ok_t 'N3 one agent'"'"'s pack is not taken for a team, and the message names agent import'
else
  bad_t 'N3 a non-team gzip was not refused' "rc=$rc $(tail -2 "$TMP/n3.out")"
fi

# ============ N4. the key's rules ============================================
bad_spec() {  # <label> <yaml> <expected stderr fragment>
  printf '%s\n' "$2" >"$TMP/n4.yaml"
  if ! _compose_parse "$TMP/n4.yaml" >/dev/null 2>"$TMP/n4.err" && grep -q "$3" "$TMP/n4.err"; then ok_t "$1"
  else bad_t "$1" "$(cat "$TMP/n4.err")"; fi
}
bad_spec 'N4a a climbing pack_file is refused' $'agents:\n  a:\n    pack_file: ../a.tar.gz' 'pack_file must be a relative path'
bad_spec 'N4b an absolute pack_file is refused' $'agents:\n  a:\n    pack_file: /tmp/a.tar.gz' 'pack_file must be a relative path'
bad_spec 'N4c a pack_file that is not a .tar.gz is refused' $'agents:\n  a:\n    pack_file: packs/a.sh' 'pack_file must be a relative path'
bad_spec 'N4d pack_file as a default is refused' $'defaults:\n  pack_file: packs/a.tar.gz\nagents:\n  a:\n    type: claude' 'cannot be a default'

# ============ N5. a missing pack file refuses the whole team =================
mkdir -p "$TMP/n5/packs"; cp "$TMP/e1/manifest.json" "$TMP/e1/team.5dive.yaml" "$TMP/n5/"
cp "$TMP/e1/packs/boss.tar.gz" "$TMP/e1/packs/ana.tar.gz" "$TMP/n5/packs/"
tar -czf "$TMP/n5.tar.gz" -C "$TMP/n5" manifest.json team.5dive.yaml packs
db "DELETE FROM team_members; DELETE FROM projects;" >/dev/null 2>&1; rm -rf "$STATE_DIR/teams"
: >"$REC"
( cmd_team import "$TMP/n5.tar.gz" ) >"$TMP/n5.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q "'wri' seat's pack packs/wri.tar.gz is not in the team's folder" "$TMP/n5.out" \
   && [[ -z "$(grep '^agent ' "$REC")" ]]; then
  ok_t 'N5 a missing member pack refuses the team before the first agent'
else
  bad_t 'N5 a missing pack did not refuse cleanly' "rc=$rc rec=$(cat "$REC") $(tail -2 "$TMP/n5.out")"
fi

# ============ C1. without pack_file, the import argv is unchanged ============
eq_t 'C1 a slug-only seat still imports by its slug' $'olivia\n--as=olivia' \
  "$(_compose_import_args '{"pack":"olivia"}' olivia olivia "$TMP" '')"

SUMMARY_PRINTED=1
printf '\n%s\n' "team_bundle_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
