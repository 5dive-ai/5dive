#!/usr/bin/env bash
# DIVE-7724 — a Codex agent that shares a ChatGPT sign-in came up broken twice
# over (chill-gorge marcus, 2026-11-04: 14.5 h, no answer).
#
#   arm L (login, any user): N seats on ONE ChatGPT account stay signed in.
#     Refresh tokens are single-use. Seat A refreshed its own copy and spent the
#     token the account still held; nothing wrote A's new one back, so a seat
#     hired after that (C) seeded the spent one. NEGATIVE CONTROL: today's seed
#     hands C the spent token. Then codex_login_sync runs (what the heartbeat
#     tick and every pre-boot normalize now do) and B, C and the account all hold
#     A's live token; a copy of ANOTHER ChatGPT account and an API-key login are
#     never read or written; two seats refreshing at once converge on the newest.
#
#   arm R (root): a Codex seat's ~/.claude ends up the seat's, and the app chat
#     adapter's first mkdir (the one that threw EACCES) works as the seat.
#     NEGATIVE CONTROL: the pre-fix pack-import memory seed leaves ~/.claude
#     root-owned and that same mkdir fails. Also doctor names the seat.
#     Needs root and a user whose group has its name (daemon). Under
#     L7724_REQUIRE_ROOT_ARM=1 a skip is a failure (CI's root-arms job).
#
#   bash tests/dive7724_codex_seat_login_unit.sh
#   sudo -E env L7724_REQUIRE_ROOT_ARM=1 bash tests/dive7724_codex_seat_login_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no()  { printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }
command -v jq >/dev/null 2>&1 || { no "jq missing: arms NOT REACHED"; exit 1; }

TMP=$(mktemp -d); chmod 755 "$TMP"
warn() { echo "warn: $*" >&2; }
step() { :; }

# ---- the real code under test, sourced from the tree -------------------------
# shellcheck source=/dev/null
. src/lib/validation.sh
# shellcheck source=/dev/null
. src/lib/codex_login_sync.sh
fn_from() {   # fn_from <file> <name> — one top-level function, verbatim
  awk -v m="$2() {" 'substr($0,1,length(m))==m { on=1 } on { print } on && $0 == "}" { exit }' "$1"
}
for pair in src/lib/agent_setup.sh:seat_claude_dir_ensure src/cmd_pack.sh:_pack_seat_memdir_make \
            src/cmd_doctor.sh:doctor_check_seat_claude_dir; do
  def=$(fn_from "${pair%%:*}" "${pair#*:}")
  [[ -n "$def" ]] || { no "could not extract ${pair#*:}"; exit 1; }
  eval "$def"
done
declare -F _sp_cred_seats codex_login_sync >/dev/null || { no "sync helpers not defined"; exit 1; }

# The seat-side seed, extracted from the real start script: the codex block up
# to where it stops touching auth.json.
START=bin/5dive-agent-start
SEED=$(awk '$0 == "if [[ \"$TYPE\" == \"codex\" ]]; then" { on=1 } on && /# Set <key> = true under \[features\]/ { exit } on { print }' "$START")
SEED+=$'\nfi'
HELPER=""
for f in cred_seed_breadcrumb_path cred_seed_breadcrumb_write cred_seed_failed cred_seed_ok cred_src_readable cred_seed_why; do
  d=$(fn_from "$START" "$f"); [[ -n "$d" ]] || { no "could not extract $f"; exit 1; }; HELPER+="$d"$'\n'
done
grep -q 'SHARED_AUTH' <<<"$SEED" || { no "codex seed block not found in $START"; exit 1; }
seed_seat() {   # seed_seat <seat> <profile> — boot-time seed, as the seat would
  local home="$AGENT_HOME_ROOT/agent-$1"
  mkdir -p "$home"
  env HOME="$home" TYPE=codex PROFILE_STATE_DIR="$AUTH_PROFILES_DIR/$2/codex" \
    bash -c "set -uo pipefail; sudo() { return 1; }; $HELPER $SEED" >/dev/null 2>&1
}

# ---- arm L: one ChatGPT account, many seats ----------------------------------
export AUTH_PROFILES_DIR="$TMP/profiles" ENV_DIR="$TMP/agents.d" AGENT_HOME_ROOT="$TMP/home"
export FIVEDIVE_DEFAULT_CRED_HOME="$TMP/claude" FIVEDIVE_CLS_ANY_USER=1 FIVEDIVE_CLS_LOCK="$TMP/cls.lock"
mkdir -p "$AUTH_PROFILES_DIR/leo/codex" "$AUTH_PROFILES_DIR/mark/codex" "$ENV_DIR" "$AGENT_HOME_ROOT" "$FIVEDIVE_DEFAULT_CRED_HOME/.codex"
login() {   # login <file> <refresh-token> <last_refresh> [account] [mode]
  mkdir -p "$(dirname "$1")"
  jq -n --arg rt "$2" --arg lr "$3" --arg a "${4:-acct-leo}" --arg m "${5:-chatgpt}" \
    '{auth_mode:$m, OPENAI_API_KEY:null, tokens:{id_token:"x", access_token:("at-"+$rt), refresh_token:$rt, account_id:$a}, last_refresh:$lr}' > "$1"
  chmod 600 "$1"
}
rt()   { jq -r '.tokens.refresh_token' "$1" 2>/dev/null; }
seat() { printf 'AGENT_TYPE=codex\nAGENT_AUTH_PROFILE=%s\n' "$2" > "$ENV_DIR/$1.env"; }
local_auth() { printf '%s/agent-%s/.codex/auth.json' "$AGENT_HOME_ROOT" "$1"; }
PF="$AUTH_PROFILES_DIR/leo/codex/auth.json"

# The chill-gorge state: the account holds the 09-26 token; packager (A)
# refreshed on 10-26 and spent it; marcus (B) still holds the 09-26 copy.
login "$PF" RT0 2026-09-26T03:00:00.123456Z
seat packager leo; seat marcus leo; seat other leo; seat apikey leo; seat elsewhere mark
login "$(local_auth packager)" RT1 2026-10-26T04:05:06.5Z
login "$(local_auth marcus)"   RT0 2026-09-26T03:00:00.123456Z
login "$(local_auth other)"    OTHER 2026-11-03T00:00:00Z acct-someone-else      # another ChatGPT account
login "$(local_auth apikey)"   KEY   2026-11-03T00:00:00Z acct-leo apikey
jq '.tokens.refresh_token=""' "$(local_auth apikey)" > "$TMP/k" && mv "$TMP/k" "$(local_auth apikey)"
login "$AUTH_PROFILES_DIR/mark/codex/auth.json" MARK 2026-10-01T00:00:00Z acct-mark
login "$(local_auth elsewhere)" MARK2 2026-11-02T00:00:00Z acct-mark
cp "$PF" "$FIVEDIVE_DEFAULT_CRED_HOME/.codex/auth.json"   # /home/claude/.codex: the same dead copy

# NEGATIVE CONTROL — today's path: a new seat C on the account seeds the spent token.
seat newhire leo
seed_seat newhire leo
is "L0 negative control: before the sync a new seat seeds the SPENT token" "$(rt "$(local_auth newhire)")" RT0
rm -f "$(local_auth newhire)"

out=$(codex_login_sync leo)
is "L1 the account takes back the newest login (packager's)" "$(rt "$PF")" RT1
is "L2 seat B (marcus) gets the live token on disk" "$(rt "$(local_auth marcus)")" RT1
is "L3 seat A (the refresher) is left as it was" "$(rt "$(local_auth packager)")" RT1
is "L4 a seat signed in to ANOTHER ChatGPT account is never written" "$(rt "$(local_auth other)")" OTHER
is "L5 a newer copy of another account never wins back" "$(jq -r .tokens.account_id "$PF")" acct-leo
is "L6 an API-key login is never read or written" "$(jq -r .tokens.refresh_token "$(local_auth apikey)")" ""
is "L7 another account's seats are not touched" "$(rt "$(local_auth elsewhere)")" MARK2
is "L8 the claude user's same-account copy is healed too" "$(rt "$FIVEDIVE_DEFAULT_CRED_HOME/.codex/auth.json")" RT1
is "L9 a seat copy keeps its mode (0600)" "$(stat -c %a "$(local_auth marcus)")" 600
grep -q 'leo: .*/profiles/leo/codex/auth.json <- .*agent-packager' <<<"$out" \
  && ok "L10 the pass says what it wrote and from where" || no "L10 output: $out"
seed_seat newhire leo
is "L11 a new seat C hired after the sync seeds the LIVE token" "$(rt "$(local_auth newhire)")" RT1
out2=$(codex_login_sync leo)
is "L12 a second pass with nothing newer writes nothing" "$out2" ""

# Two seats refresh at once: both spent RT1; marcus won at OpenAI a little later.
login "$(local_auth packager)" RT2a 2026-11-05T10:00:00Z
login "$(local_auth marcus)"   RT2b 2026-11-05T10:00:01Z
codex_login_sync >/dev/null    # no profile named: every account
is "L13 concurrent refresh: the account takes the newest" "$(rt "$PF")" RT2b
is "L14 concurrent refresh: the loser gets the winner's token" "$(rt "$(local_auth packager)")" RT2b
is "L15 concurrent refresh: seat C follows" "$(rt "$(local_auth newhire)")" RT2b
# The owner signs the account in again: the account's own file is newest.
login "$PF" RT3 2026-11-06T00:00:00Z
codex_login_sync leo >/dev/null
is "L16 a fresh sign-in on the account goes out to every seat" "$(rt "$(local_auth marcus)")/$(rt "$(local_auth packager)")" RT3/RT3
# A half-written seat copy is never taken.
printf '{"tokens":{"refresh' > "$(local_auth marcus)"
codex_login_sync leo >/dev/null
is "L17 an unparsable copy is skipped, the account keeps its login" "$(rt "$PF")" RT3
# Not root: a no-op (a seat cannot write another seat's home).
login "$(local_auth packager)" RT4 2026-11-07T00:00:00Z
if (( EUID != 0 )); then
  ( unset FIVEDIVE_CLS_ANY_USER; codex_login_sync leo )
  is "L18 as a seat (not root) the sync writes nothing" "$(rt "$PF")" RT3
fi

# ---- arm R: the seat's ~/.claude (root) ---------------------------------------
FIX=daemon
if (( EUID != 0 )) || ! command -v setpriv >/dev/null || ! id "$FIX" >/dev/null 2>&1 || ! getent group "$FIX" >/dev/null; then
  echo "skip - R arm (needs root and a '$FIX' user+group)"
  [[ -z "${L7724_REQUIRE_ROOT_ARM:-}" ]] || no "R arm skipped under L7724_REQUIRE_ROOT_ARM"
else
  # As the seat, without sudo (the grading-tree guard wraps sudo on a dev host).
  as_seat() { setpriv --reuid="$FIX" --regid="$FIX" --clear-groups -- "$@"; }
  H="$TMP/rhome"; mkdir -p "$H/agent-old" "$H/agent-new"; chown "$FIX:$FIX" "$H/agent-old" "$H/agent-new"; chmod 755 "$H"
  slug=-home-claude-projects
  # NEGATIVE CONTROL: the pre-fix memory seed of `agent import`, verbatim.
  cdir="$H/agent-old/.claude"; mdir="$cdir/projects/$slug/memory"
  install -d -o "$FIX" -g "$FIX" "$mdir"; chown -R "$FIX:$FIX" "$cdir/projects"
  is "R0 negative control: the old seed leaves ~/.claude root-owned" "$(stat -c %U "$cdir")" root
  err=$(as_seat mkdir -p "$cdir/channels/dashboard/agent-inbox" 2>&1) \
    && no "R1 negative control: the adapter's mkdir should fail on the old tree"
  [[ "$err" == *"Permission denied"* ]] \
    && ok "R1 negative control: the adapter's first mkdir fails (EACCES) on the old tree" \
    || no "R1 negative control failed for the wrong reason: $err"
  # The fix.
  cdir="$H/agent-new/.claude"; mdir="$cdir/projects/$slug/memory"
  _pack_seat_memdir_make "$FIX" "$cdir" "$mdir"
  is "R2 the new seed: every component is the seat's" \
    "$(stat -c %U "$cdir" "$cdir/projects" "$cdir/projects/$slug" "$mdir" | sort -u)" "$FIX"
  is "R3 a new ~/.claude is 0700" "$(stat -c %a "$cdir")" 700
  as_seat mkdir -p "$cdir/channels/dashboard/agent-inbox" \
    && ok "R4 the adapter's first mkdir works as the seat" || no "R4 the adapter's mkdir failed on the new tree"
  # Heal an existing broken seat (what doctor --fix and every dashboard prepare do).
  touch "$H/agent-old/.claude/root-file"
  seat_claude_dir_ensure "$FIX" "$H/agent-old" && ok "R5 a root-owned ~/.claude is handed back" || no "R5 heal failed"
  is "R6 healed dir is the seat's" "$(stat -c %U "$H/agent-old/.claude")" "$FIX"
  is "R7 the heal is not recursive" "$(stat -c %U "$H/agent-old/.claude/root-file")" root
  as_seat mkdir -p "$H/agent-old/.claude/channels/dashboard/agent-inbox" \
    && ok "R8 after the heal the adapter's mkdir works" || no "R8 still EACCES after heal"
  mkdir -p "$H/agent-link" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$H/agent-link/.claude"
  seat_claude_dir_ensure "$FIX" "$H/agent-link" && no "R9 followed a symlinked ~/.claude" \
    || is "R9 a symlinked ~/.claude is refused, its target untouched" "$(stat -c %U "$TMP/elsewhere")" root
  _pack_seat_memdir_make "$FIX" "$H/agent-link/.claude" "$H/agent-link/.claude/projects/x/memory" \
    && no "R10 memdir followed a symlink" || ok "R10 the memory seed refuses a symlinked ~/.claude"
  # doctor names it. agent-<name> is the seat user, so fixture a seat named after a real one.
  DOCTOR_REPAIR=0; DOCTOR_LINES=""
  doctor_add() { DOCTOR_LINES+="$3|$4"$'\n'; }
  mkdir -p "$H/agent-ghost/.claude"   # root-owned, seat user "agent-ghost"
  AGENT_HOME_ROOT="$H" doctor_check_seat_claude_dir '{"agents":{"ghost":{},"new":{}}}'
  grep -q '^error|.*ghost(root).*doctor --fix' <<<"$DOCTOR_LINES" \
    && ok "R11 doctor names a seat whose ~/.claude is not its own" || no "R11 doctor said: $DOCTOR_LINES"
fi

# ---- the wiring the fix rests on ---------------------------------------------
grep -q 'codex_login_sync' src/cmd_heartbeat.sh && ok "W1 the heartbeat tick runs the sync" || no "W1 heartbeat does not call codex_login_sync"
_w2_body=$(awk '/^normalize_profile_seed_perms\(\) \{/,/^}/' src/cmd_auth.sh)
grep -q 'codex_login_sync' <<<"$_w2_body" \
  && ok "W2 the pre-boot normalize runs the sync" || no "W2 normalize_profile_seed_perms does not call codex_login_sync"
grep -q 'src/lib/codex_login_sync.sh' build.sh && ok "W3 the lib is in the bundle" || no "W3 build.sh misses the lib"
grep -q 'seat_claude_dir_ensure' src/cmd_pack.sh && ok "W4 import makes ~/.claude the seat's first" || no "W4"
[[ $(grep -c 'dashboard_inbox_prepare "\$user"' src/lib/agent_setup.sh) -ge 3 ]] \
  && ok "W5 every dashboard inbox prepare heals and checks ~/.claude" || no "W5"
SM=scripts/init-smoke.sh
_wc() { bash -c 'source <(sed -n "/^cell_type()/p;/^cell_has_webchat()/p" "$1"); cell_has_webchat "$2" && echo yes || echo no' _ "$SM" "$1"; }
[[ "$(_wc codex)" == yes ]] \
  && ok "W6 the nightly grades the Codex cell's app chat" || no "W6 init-smoke does not run webchat_arm on codex"
awk '/^webchat_arm\(\) \{/,/^}/' "$SM" | awk '/stat -c %U/{s=NR} /install -d -o/{i=NR} END{exit !(s && i && s<i)}' \
  && ok "W7 the nightly grades ~/.claude's owner before it makes the bridge dirs" || no "W7 webchat_arm repairs ~/.claude before grading it"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
