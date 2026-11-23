#!/usr/bin/env bash
# DIVE-9116 — a premium team bought from 5dive UPDATES IN PLACE from a newer
# signed file: `team import <newer file>` over the installed team, and
# `team update <team>` (asks 5dive for the newest, then the same import).
#
# ROUND TRIP, through the real producer (packaging/premium-team/build.sh), the
# real verify + `team import` → `up` path, and the REAL `agent update
# --from-pack=<file>` (src/cmd_pack.sh) on a fixture home. `agent import` is
# emulated (it needs unix users): it lays the pack down the way import does —
# the pack's section, then the CLI's own block — and records the agent.
#   U1  1.0.0 imports; then 1.1.0 imports over it as an UPDATE (said so);
#   U2  no second copy: no agent is imported again;
#   U3  every seat is moved by `agent update --from-pack=<its pack in the file>`;
#   U4  the changed role text replaces the old one (one role block, not two);
#   U5  a pack skill moves to the new body; the pack's own section moves;
#   U6  memory, the bot's channel file and the CLI's block are byte-identical;
#   U7  the box's label says 1.1.0;
#   U8  a declared loop takes the new schedule and prompt (same row, no second);
#   D1  the same version again is refused, nothing changed;
#   D2  an older version is refused (names --allow-downgrade) ...
#   D3  ... and goes back with --allow-downgrade (role text back to 1.0.0's);
#   B1  a newer file for ANOTHER buyer is refused, label unchanged;
#   O1  `team update`: 204 says up to date; 403 says the subscription ended;
#       200 applies the file it got; a team that is not premium is refused;
#       the bearer never reaches curl's argv.
#
# COVERAGE LIMIT: unix users are not created (emulated import); the API route
# that serves the newest file is DIVE-9114's and is stubbed here.
#
# Run: bash tests/premium_team_update_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - premium_team_update_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
for t in openssl jq sha256sum python3 sqlite3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; SUMMARY_PRINTED=1; exit 0; }; done

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh src/cmd_pack.sh src/cmd_team_pack.sh src/lib/offline_update.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/premium-team-update.XXXXXX)"
export STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR" "$TMP/tmpd" "$TMP/k" "$TMP/ostate"
tasks_db_init
export TMPDIR="$TMP/tmpd" TEAM_AUTH_PROFILE=fixture
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json" PENDING_RESTART_DIR="$TMP/pending"
printf '{"agents":{}}\n' >"$REGISTRY"
BUILD=packaging/premium-team/build.sh

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }
sha()   { sha256sum <"$1" | cut -d' ' -f1; }

# ---- keys: a throwaway root and a team key it certifies ---------------------
K="$TMP/k"
key(){ openssl genpkey -algorithm ed25519 -out "$K/$1.pem" 2>/dev/null; openssl pkey -in "$K/$1.pem" -pubout -out "$K/$1.pub" 2>/dev/null; }
kid(){ openssl pkey -pubin -in "$K/$1.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
sign(){ openssl pkeyutl -sign -inkey "$K/$1.pem" -rawin -in "$2" -out "$3"; }
key root; key team
T="$TMP/trust"; mkdir -p "$T"
jq -cjn --arg id "$(kid team)" --rawfile p "$K/team.pub" --argjson n $(( $(date +%s) + 86400 * 30 )) \
  '{format:1, kind:"5dive-team-key", key_id:$id, pubkey:$p, not_after:$n}' >"$T/team-key.json"; sign root "$T/team-key.json" "$T/team-key.sig"
jq -cjn '{format:1, kind:"5dive-revocations", serial:1, revoked:[]}' >"$T/revoked.json"; sign root "$T/revoked.json" "$T/revoked.sig"
export OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$K/root.pub" OFFLINE_UPDATE_ROOT_PUBKEY_PEM="" OFFLINE_UPDATE_STATE_DIR="$TMP/ostate"
chmod 644 "$K/root.pub"

# ---- two versions of the same team (boss leads, ana reports) ----------------
# mk_bundle <ver> <ana-role-text> <boss-skill-body> <boss-pack-line> <loop-cron> <loop-prompt>
mk_bundle() {
  local v="$1" B="$TMP/bundle-$1" n d
  mkdir -p "$B/packs"
  printf '{"kind":"5dive-team","format":1,"team":"research","memory":false,"agents":["boss","ana"]}\n' >"$B/manifest.json"
  cat >"$B/team.5dive.yaml" <<YAML
version: 2
name: research
agents:
  boss:
    type: claude
    role: Head of research
    pack_file: packs/boss.tar.gz
    loops:
      - id: digest
        title: Weekly digest
        cron: "$5"
        prompt: "$6"
  ana:
    type: claude
    role: Analyst
    reports_to: boss
    instructions: "$2"
    pack_file: packs/ana.tar.gz
YAML
  for n in boss ana; do
    d=$(mktemp -d); mkdir -p "$d/skills/sources"
    jq -n --arg n "$n" '{packFormat:1, agentName:$n, skills:["sources"]}' >"$d/manifest.json"
    printf '# %s\nYou are %s.\n%s\n' "$n" "$n" "$4" >"$d/CLAUDE.md"
    printf '%s\n' "$3" >"$d/skills/sources/SKILL.md"
    tar -czf "$B/packs/$n.tar.gz" -C "$d" manifest.json CLAUDE.md skills; rm -rf "$d"
  done
  tar -czf "$TMP/research-$v.team.tar.gz" -C "$B" manifest.json team.5dive.yaml packs
}
mk_bundle 1.0.0 "Check every number twice." "sources v1" "Pack line of 1.0.0." "0 9 * * 1" "Send the weekly digest."
mk_bundle 1.1.0 "Check every number against two sources." "sources v2" "Pack line of 1.1.0." "0 8 * * 1" "Send the weekly digest with links."
mk() { # <ver> <out> [buyer-account]
  bash "$BUILD" --bundle="$TMP/research-$1.team.tar.gz" --key="$K/team.pem" --trust="$T" \
    --buyer-account="${3:-acct-42}" --buyer-name="Acme Research" --version="$1" -o "$2" >/dev/null 2>"$2.err"
}
mk 1.0.0 "$TMP/v1.gz"; mk 1.1.0 "$TMP/v2.gz"; mk 1.1.0 "$TMP/v2-other.gz" acct-7
[[ -s "$TMP/v1.gz" && -s "$TMP/v2.gz" && -s "$TMP/v2-other.gz" ]] || { bad_t 'fixture files built' "$(cat "$TMP"/*.err)"; }

# ---- the agent CLI: import emulated, update REAL ----------------------------
cat >"$TMP/helper.sh" <<'SH'
#!/usr/bin/env bash
# Runs as a separate process, like the real CLI the compose path shells out to.
set -uo pipefail
cd "$ROOT" || exit 1
verb="$1"; shift
case "$verb" in
  import)
    pack="" as=""
    for a in "$@"; do case "$a" in --as=*) as="${a#--as=}" ;; -*) ;; *) [[ -z "$pack" ]] && pack="$a" ;; esac; done
    d=$(mktemp -d); tar -xzf "$pack" -C "$d" || exit 1
    H="$AGENT_HOME_ROOT/agent-$as"
    mkdir -p "$H/.claude/skills" "$H/.claude/projects/x/memory" "$H/.claude/channels/telegram"
    { cat "$d/CLAUDE.md"; printf '\n# Telegram-paired agent\n\nReply every turn.\n'; } >"$H/.claude/CLAUDE.md"
    cp -r "$d/skills/." "$H/.claude/skills/"
    jq --arg n "$as" '.agents[$n] = {type:"claude", pack:{source:"file", slug:"", skills:{}}}' "$REGISTRY" >"$REGISTRY.t" && mv "$REGISTRY.t" "$REGISTRY"
    rm -rf "$d" ;;
  update)
    reg_keep="$REGISTRY"   # header.sh names the box's own registry; the fixture's wins
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh cmd_skill.sh cmd_pack.sh; do
      # shellcheck source=/dev/null
      source "src/$f"
    done
    set +e
    REGISTRY="$reg_keep"; JSON_MODE=1
    _pending_restart_mark() { mkdir -p "$PENDING_RESTART_DIR"; printf 'reason=%s\n' "$2" >"$PENDING_RESTART_DIR/$1"; }
    agent_type() { jq -r --arg n "$1" '.agents[$n].type // empty' "$REGISTRY"; }
    require_root() { :; }
    chown() { :; }
    _pack_as_agent() { shift; "$@"; }
    cmd_agent_update "$@" ;;
esac
SH
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
case "$1 ${2:-}" in
  "agent import") shift 2; exec bash "$HELPER" import "$@" ;;
  "agent update") shift 2; exec bash "$HELPER" update "$@" ;;
esac
exit 0
SH
chmod +x "$TMP/fake5dive" "$TMP/helper.sh"
export REC="$TMP/rec.log" HELPER="$TMP/helper.sh" ROOT; : >"$REC"
_compose_self() { printf '%s' "$TMP/fake5dive"; }
registry_read()   { cat "$REGISTRY"; }
require_root()    { :; }
ensure_state()    { :; }
ensure_state_ro() { :; }
resolve_agent_model()  { :; }
resolve_agent_effort() { :; }
_pending_restart_mark() { mkdir -p "$PENDING_RESTART_DIR"; printf 'reason=%s\n' "$2" >"$PENDING_RESTART_DIR/$1"; }
persona_target() { printf '%s/agent-%s/.claude/CLAUDE.md' "$AGENT_HOME_ROOT" "$1"; }
persona_append_block() { printf '%s' "$3" >>"$(persona_target "$1")"; }
_teams_get() { return 1; }

MD_ANA="$AGENT_HOME_ROOT/agent-ana/.claude/CLAUDE.md"; MD_BOSS="$AGENT_HOME_ROOT/agent-boss/.claude/CLAUDE.md"
LABEL="$STATE_DIR/premium-teams/research.json"
label_ver() { jq -r '.version // empty' "$LABEL" 2>/dev/null; }

# ============ U. 1.0.0, then 1.1.0 over it ===================================
( cmd_team import "$TMP/v1.gz" --start-now ) >"$TMP/u0.out" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(label_ver)" == 1.0.0 && -f "$MD_ANA" ]] && grep -q 'Check every number twice.' "$MD_ANA"; then
  ok_t 'U0 1.0.0 imports: label 1.0.0, ana carries its role text'
else bad_t 'U0 1.0.0 did not import' "rc=$rc label=$(label_ver) $(tail -5 "$TMP/u0.out")"; fi
# The declared loop's row, as `task add` writes it (the CLI call is stubbed).
grep -q -- "--recurring=0 9 \* \* 1 --assignee=boss" "$REC" || bad_t 'U0b the 1.0.0 loop was declared' "$(grep 'task add' "$REC")"
db "INSERT INTO tasks (ident, title, body, status, priority, assignee, kind, schedule)
    VALUES ('DIVE-1', 'Weekly digest', $(sqlq "Send the weekly digest.

— $(_compose_loop_marker digest) runs on '0 9 * * 1'."), 'todo', 'medium', 'boss', 'recurring', '0 9 * * 1');" >/dev/null
# What the agents hold before the update: memory, a bot channel file, an owner note.
for n in boss ana; do
  printf 'remember: owner is Galina (%s)\n' "$n" >"$AGENT_HOME_ROOT/agent-$n/.claude/projects/x/memory/user.md"
  printf 'TOKEN=123:abc\n' >"$AGENT_HOME_ROOT/agent-$n/.claude/channels/telegram/.env"
done
keep() { local n; for n in boss ana; do
  for f in .claude/projects/x/memory/user.md .claude/channels/telegram/.env; do printf '%s %s\n' "$(sha "$AGENT_HOME_ROOT/agent-$n/$f")" "$n/$f"; done; done; }
KEEP=$(keep)

: >"$REC"
( cmd_team import "$TMP/v2.gz" ) >"$TMP/u1.out" 2>&1; rc=$?
if (( rc == 0 )) && grep -q 'installed at 1.0.0 — updating it in place to 1.1.0' "$TMP/u1.out"; then ok_t 'U1 1.1.0 over 1.0.0 is an update in place, and says so'
else bad_t 'U1 not an in-place update' "rc=$rc $(tail -8 "$TMP/u1.out")"; fi
eq_t 'U2 no second copy: no agent is imported again' '' "$(grep '^agent import' "$REC")"
ok_all=1; for n in boss ana; do grep -qE "^agent update ${n} --from-pack=/[^ ]*/packs/${n}\.tar\.gz$" "$REC" || ok_all=0; done
if (( ok_all )); then ok_t 'U3 every seat is moved by agent update --from-pack=<its pack in the file>'
else bad_t 'U3 seats not updated from the file' "$(cat "$REC")"; fi
if grep -q 'Check every number against two sources.' "$MD_ANA" && ! grep -q 'Check every number twice.' "$MD_ANA" \
   && [[ "$(grep -c '^## Role' "$MD_ANA") $(grep -c '^## Reporting$' "$MD_ANA")" == "1 1" ]]; then
  ok_t 'U4 the role text moves to 1.1.0, in place (one role block)'
else bad_t 'U4 role text not swapped' "$(cat "$MD_ANA")"; fi
if [[ "$(cat "$AGENT_HOME_ROOT/agent-boss/.claude/skills/sources/SKILL.md")" == "sources v2" ]] \
   && grep -q 'Pack line of 1.1.0.' "$MD_BOSS" && ! grep -q 'Pack line of 1.0.0.' "$MD_BOSS"; then
  ok_t 'U5 the pack skill and the pack section move to 1.1.0'
else bad_t 'U5 pack not moved' "skill=$(cat "$AGENT_HOME_ROOT/agent-boss/.claude/skills/sources/SKILL.md") $(head -3 "$MD_BOSS")"; fi
if [[ "$(keep)" == "$KEEP" ]] && grep -q '^# Telegram-paired agent$' "$MD_ANA" && grep -q '^Reply every turn.$' "$MD_ANA"; then
  ok_t 'U6 memory and the bot channel file are byte-identical; the CLI block survives'
else bad_t 'U6 something kept was touched' "$(diff <(echo "$KEEP") <(keep)) $(cat "$MD_ANA")"; fi
eq_t 'U7 the label says 1.1.0' 1.1.0 "$(label_ver)"
eq_t 'U8 the loop takes the new schedule and prompt, on the same row' \
  "1|0 8 * * 1|1" \
  "$(db "SELECT COUNT(*), MAX(schedule), MAX(body LIKE 'Send the weekly digest with links.%') FROM tasks WHERE kind='recurring' AND assignee='boss';")"
[[ -s "$PENDING_RESTART_DIR/ana" ]] && ok_t 'U9 a changed seat is marked to restart at its next quiet moment' || bad_t 'U9 no restart mark for ana' "$(ls "$PENDING_RESTART_DIR" 2>&1)"

# ============ D. same / older versions =======================================
: >"$REC"; MD_BEFORE=$(sha "$MD_ANA")
( cmd_team import "$TMP/v2.gz" ) >"$TMP/d1.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'already at 1.1.0' "$TMP/d1.out" && grep -q 'Nothing was changed' "$TMP/d1.out" \
   && [[ -z "$(grep '^agent ' "$REC")" && "$(sha "$MD_ANA")" == "$MD_BEFORE" ]]; then ok_t 'D1 the same version again is refused, nothing changed'
else bad_t 'D1 same version not refused' "rc=$rc $(tail -3 "$TMP/d1.out")"; fi
( cmd_team import "$TMP/v1.gz" ) >"$TMP/d2.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'older than the 1.1.0' "$TMP/d2.out" && grep -q -- '--allow-downgrade' "$TMP/d2.out" \
   && [[ "$(label_ver)" == 1.1.0 && -z "$(grep '^agent ' "$REC")" ]]; then ok_t 'D2 an older version is refused and names --allow-downgrade'
else bad_t 'D2 older version not refused' "rc=$rc $(tail -3 "$TMP/d2.out")"; fi
( cmd_team import "$TMP/v1.gz" --allow-downgrade ) >"$TMP/d3.out" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(label_ver)" == 1.0.0 ]] && grep -q 'Check every number twice.' "$MD_ANA" \
   && [[ "$(grep -c '^## Role' "$MD_ANA")" == 1 && -z "$(grep '^agent import' "$REC")" ]]; then ok_t 'D3 --allow-downgrade goes back to 1.0.0, in place'
else bad_t 'D3 downgrade failed' "rc=$rc label=$(label_ver) $(tail -3 "$TMP/d3.out")"; fi

# ============ B. another buyer's file ========================================
: >"$REC"
( cmd_team import "$TMP/v2-other.gz" ) >"$TMP/b1.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'same buyer' "$TMP/b1.out" && [[ "$(label_ver)" == 1.0.0 && -z "$(grep '^agent ' "$REC")" ]]; then
  ok_t 'B1 a newer file for another buyer is refused, label unchanged'
else bad_t 'B1 other buyer not refused' "rc=$rc $(tail -3 "$TMP/b1.out")"; fi

# ============ O. team update (online) ========================================
_partner_box_token() { printf 'tok-SECRET'; }
five_api_base() { printf 'https://api.example.test'; }
CURL_CODE=204
curl() { # records argv; serves the 1.1.0 file on 200
  printf '%s\n' "$*" >>"$TMP/curl.argv"; cat >>"$TMP/curl.stdin"
  local o="" prev=""; for a in "$@"; do [[ "$prev" == -o ]] && o="$a"; prev="$a"; done
  [[ "$CURL_CODE" == 200 && -n "$o" ]] && cp "$TMP/v2.gz" "$o"
  printf '%s' "$CURL_CODE"
}
: >"$TMP/curl.argv"; : >"$TMP/curl.stdin"
( _team_premium_update_online research ) >"$TMP/o1.out" 2>&1; rc=$?
if (( rc == 0 )) && grep -q 'up to date (1.0.0)' "$TMP/o1.out" && grep -q 'premium-teams/research/latest?have=1.0.0' "$TMP/curl.argv"; then
  ok_t 'O1a 204: says up to date, and asked with the installed version'
else bad_t 'O1a 204 not handled' "rc=$rc $(cat "$TMP/o1.out") $(cat "$TMP/curl.argv")"; fi
CURL_CODE=403
( _team_premium_update_online research ) >"$TMP/o2.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'subscription to premium team research has ended' "$TMP/o2.out"; then ok_t 'O1b 403: the subscription ended, the team keeps working'
else bad_t 'O1b 403 not handled' "rc=$rc $(cat "$TMP/o2.out")"; fi
CURL_CODE=200; : >"$REC"
( _team_premium_update_online research ) >"$TMP/o3.out" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(label_ver)" == 1.1.0 ]] && grep -q 'Check every number against two sources.' "$MD_ANA" && [[ -z "$(grep '^agent import' "$REC")" ]]; then
  ok_t 'O1c 200: the file it got is checked and applied in place'
else bad_t 'O1c 200 not applied' "rc=$rc label=$(label_ver) $(tail -4 "$TMP/o3.out")"; fi
( _team_premium_update_online nosuch ) >"$TMP/o4.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'not a premium team on this server' "$TMP/o4.out"; then ok_t 'O1d a team that is not premium is refused'
else bad_t 'O1d non-premium not refused' "rc=$rc $(cat "$TMP/o4.out")"; fi
if ! grep -q 'tok-SECRET' "$TMP/curl.argv" && grep -q 'Authorization: Bearer tok-SECRET' "$TMP/curl.stdin"; then ok_t 'O1e the bearer goes on stdin, never argv'
else bad_t 'O1e bearer on argv' "$(cat "$TMP/curl.argv")"; fi
eq_t 'O1f no download is left behind' '' "$(find "$TMP/tmpd" -maxdepth 1 -name '*.gz' 2>/dev/null | head -3)"

SUMMARY_PRINTED=1
printf '\n%s\n' "premium_team_update_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
