#!/usr/bin/env bash
# DIVE-5501 — move an agent between Claude Code and Codex IN PLACE, and refuse an
# unconfirmed account move that would do it silently.
#
# The row's grader purpose, run against a temp home tree:
#   X is a claude seat with memory atom M, a CLAUDE.md line L and bot token B.
#   S1-S3  `agent config X set auth-profile=<chatgpt>` WITHOUT --switch-harness is
#          REFUSED with the plain sentence, and nothing changes (negative control;
#          on origin/main the same call succeeds and binds a Claude seat to a
#          ChatGPT login — DIVE-5432's dead seat).
#   S4     a same-harness move still binds (the refusal is not a blanket one).
#   W1-W9  `agent switch X --to=codex`: same unix user + bot token, type/env/account
#          flipped, L carried into AGENTS.md, M's index carried, 5dive's claude-only
#          fragments not carried, allowFrom kept, CLAUDE.md left as it was.
#   B1-B6  and back: type claude, L unchanged in CLAUDE.md, M still there plus the
#          codex memory converted to atoms, no stacked carried blocks.
#   C*/M*  the pure pieces (carry, memory conversion, access merge) on their own.
#
# `sudo`, `install -o`, `chown` and `id` are runas-stripping shims; systemd and the
# channel installers are recorded, not run. The writers under test are the real ones.
#
# Run: bash tests/agent_switch_harness_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/agent-switch.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         cmd_auth.sh cmd_account.sh cmd_agent_runtime.sh cmd_agent_create.sh cmd_agent_config.sh \
         cmd_pack.sh cmd_agent_switch.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ------------------------------------------------------------------ fixtures
export SWITCH_HOME_ROOT="$TMP/home"
AUTH_PROFILES_DIR="$TMP/profiles"; ENV_DIR="$TMP/agents.d"; STATE_DIR="$TMP/state"
mkdir -p "$AUTH_PROFILES_DIR/claudeacct" "$AUTH_PROFILES_DIR/chatgpt/codex" "$AUTH_PROFILES_DIR/empty" "$ENV_DIR" "$STATE_DIR"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-test\n' >"$AUTH_PROFILES_DIR/claudeacct/combined.env"
: >"$AUTH_PROFILES_DIR/chatgpt/combined.env"
printf '{"tokens":{"id_token":"x"}}\n' >"$AUTH_PROFILES_DIR/chatgpt/codex/auth.json"
: >"$AUTH_PROFILES_DIR/empty/combined.env"

# The shipped claude fragments, as 5dive installs them (stand-ins with the same role).
TELEGRAM_AGENT_CLAUDE_MD="$TMP/frag-telegram.md"; MODEL_TIERING_CLAUDE_MD="$TMP/frag-tier.md"
OPERATIONAL_COMMS_CLAUDE_MD="$TMP/frag-ops.md"
printf '# Telegram-paired agent\n\nReply through mcp reply every turn.\n' >"$TELEGRAM_AGENT_CLAUDE_MD"
printf '## Model tiering\n\nUse haiku for Explore.\n' >"$MODEL_TIERING_CLAUDE_MD"
printf '## Operational comms\n\nBe terse.\n' >"$OPERATIONAL_COMMS_CLAUDE_MD"

H="$SWITCH_HOME_ROOT/agent-theo"
TOKEN_B='7000000001:AAbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
L='Always answer in Portuguese — owner-written line L.'
mkdir -p "$H/.claude/channels/telegram" "$H/.claude/projects/-home-claude-projects/memory" \
         "$H/.claude/skills/clicker" "$H/.claude/skills/5dive-cli"
{ cat "$TELEGRAM_AGENT_CLAUDE_MD"; printf '\n'; cat "$MODEL_TIERING_CLAUDE_MD"; printf '\n'; cat "$OPERATIONAL_COMMS_CLAUDE_MD"
  printf '\n%s\n' "$L"; } >"$H/.claude/CLAUDE.md"
printf '{}\n' >"$H/.claude/settings.json"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_PROFILE=lite\n' "$TOKEN_B" >"$H/.claude/channels/telegram/.env"
printf '{"dmPolicy":"allowlist","allowFrom":["1234567890"],"groups":{"-1001":{"requireMention":true}},"pending":{}}\n' \
  >"$H/.claude/channels/telegram/access.json"
MEM="$H/.claude/projects/-home-claude-projects/memory"
printf -- '---\nname: owner-likes-mornings\ndescription: "the owner reads messages before 9am"\nmetadata:\n  type: user\n---\n\nM: mornings.\n' \
  >"$MEM/user_owner_likes_mornings.md"
printf '# Memory Index\n\n- [owner-likes-mornings](user_owner_likes_mornings.md) — the owner reads messages before 9am\n' >"$MEM/MEMORY.md"
mkdir -p "$H/.claude/plugins/cache/5dive-plugins/telegram"

REG0='{"agents":{"theo":{"type":"claude","channels":"telegram","authProfile":"claudeacct","isolation":"standard"},"cdx":{"type":"codex","channels":"telegram","authProfile":"chatgpt"}}}'
printf '%s' "$REG0" >"$TMP/reg"

# ------------------------------------------------------------------ shims
sudo() { while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
         while [[ "${1:-}" == *=* ]]; do export "$1"; shift; done; [[ "${1:-}" == env ]] && shift
         while [[ "${1:-}" == *=* ]]; do export "$1"; shift; done; "$@"; }
install() { local -a a=(); while [[ $# -gt 0 ]]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; command install "${a[@]}"; }
chown() { :; }
id() { [[ "${1:-}" == -u ]] && { echo 1000; return 0; }; command id "$@"; }
require_root() { :; }
step() { :; }
warn() { :; }
ensure_state() { :; }
audit_log() { :; }
registry_read() { cat "$TMP/reg"; }
registry_write() { cat >"$TMP/reg"; }
with_registry_lock() { "$@"; }
link_agent_profile() { printf '%s %s\n' "$1" "${2:-}" >>"$TMP/links"; }
account_binding_record() { :; }
plugin_seat_backfill() { :; }
mod_seat_enabled() { return 1; }
preseed_codex_return_channel() { :; }
preseed_claude_agent() { printf 'preseed %s\n' "$*" >>"$TMP/calls"; }
codex_plugin_dir() { echo "$TMP/telegram-codex"; }
cmd_install() { :; }
systemctl() { case "$1" in is-active) [[ -f "$TMP/active" ]] ;; stop) rm -f "$TMP/active" ;; start) : >"$TMP/active" ;; esac; }
systemd-run() { printf 'restart\n' >>"$TMP/restarts"; }
# The channel installer is recorded, and writes the token where the real one does.
install_channel_for_agent() {
  printf 'channel %s\n' "$*" >>"$TMP/calls"
  local d="$SWITCH_HOME_ROOT/agent-$3/.$1/channels/telegram"
  [[ "$2" == telegram ]] && { mkdir -p "$d"; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$4" >"$d/.env"; }
  return 0
}
set_claude_telegram_env_key() {
  local f="$SWITCH_HOME_ROOT/agent-$1/.claude/channels/telegram/.env"
  grep -v "^$2=" "$f" >"$f.t" 2>/dev/null; printf '%s=%s\n' "$2" "$3" >>"$f.t"; mv "$f.t" "$f"
}
TYPE_BIN[claude]=/bin/true; TYPE_BIN[codex]=/bin/true
FIVEDIVE_SELF=/bin/false   # handoff "send" fails -> state unreachable, no wait

run() { ( set -e; JSON_MODE=1; "$@" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }

# =========================================================== A: account kinds
[[ "$(switch_account_harness claudeacct)" == claude && "$(switch_account_harness chatgpt)" == codex \
   && -z "$(switch_account_harness empty)" ]] \
  && ok_t "A1 an account is a Claude sign-in or a ChatGPT one, read off its credentials" \
  || bad_t "A1 account kinds" "claudeacct=$(switch_account_harness claudeacct) chatgpt=$(switch_account_harness chatgpt) empty=$(switch_account_harness empty)"
[[ "$(switch_target_for_account claude chatgpt)" == codex && "$(switch_target_for_account codex claudeacct)" == claude \
   && -z "$(switch_target_for_account claude claudeacct)" && -z "$(switch_target_for_account claude empty)" ]] \
  && ok_t "A2 only a move onto the OTHER harness's account is a switch (same harness / no sign-in: plain bind)" \
  || bad_t "A2 switch_target_for_account" ""

# =========================================================== S: the refusal
snap_reg=$(sha256sum <"$TMP/reg"); snap_home=$(find "$H" -type f -exec sha256sum {} + | sort | sha256sum)
: >"$TMP/restarts"
rc=$(run cmd_config theo set auth-profile=chatgpt)
[[ "$rc" != 0 ]] && grep -q 'switches it from Claude Code to Codex' "$TMP/err" \
  && grep -q -- '--switch-harness' "$TMP/err" \
  && ok_t "S1 moving a Claude agent to a ChatGPT account without --switch-harness is refused with the plain sentence (RED on main: it binds)" \
  || bad_t "S1 not refused" "rc=$rc err=$(<"$TMP/err")"
[[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && ! -s "$TMP/restarts" \
   && "$(find "$H" -type f -exec sha256sum {} + | sort | sha256sum)" == "$snap_home" ]] \
  && ok_t "S2 the refusal changes nothing: registry, seat files and no restart" \
  || bad_t "S2 something changed" "$(cat "$TMP/reg")"
rc=$(run cmd_config cdx set auth-profile=claudeacct)
[[ "$rc" != 0 ]] && grep -q 'switches it from Codex to Claude Code' "$TMP/err" \
  && ok_t "S3 the reverse direction (Codex agent onto a Claude account) is refused the same way" \
  || bad_t "S3 reverse not refused" "rc=$rc err=$(<"$TMP/err")"
printf '%s' "$REG0" | jq '.agents.theo.authProfile = "empty"' >"$TMP/reg"
rc=$(run cmd_config theo set auth-profile=claudeacct)
[[ "$rc" == 0 && "$(jq -r .agents.theo.authProfile "$TMP/reg")" == claudeacct ]] \
  && ok_t "S4 a same-harness account move still binds as before" \
  || bad_t "S4 same-harness bind broken" "rc=$rc err=$(<"$TMP/err")"
printf '%s' "$REG0" >"$TMP/reg"

# =========================================================== W: switch to codex
: >"$TMP/active"; : >"$TMP/calls"
rc=$(run agent_account_move_switch set-account theo chatgpt --switch-harness)
if [[ "$rc" != 0 ]]; then
  bad_t "W0 set-account --switch-harness must succeed" "rc=$rc err=$(tail -5 "$TMP/err") out=$(<"$TMP/out")"
fi
[[ "$(jq -r .agents.theo.type "$TMP/reg")" == codex && "$(jq -r .agents.theo.authProfile "$TMP/reg")" == chatgpt ]] \
  && ok_t "W1 the confirmed move flips the SAME agent to codex on the ChatGPT account" \
  || bad_t "W1 registry" "$(jq -c .agents.theo "$TMP/reg")"
grep -q '^AGENT_TYPE=codex$' "$ENV_DIR/theo.env" && grep -q '^AGENT_AUTH_PROFILE=chatgpt$' "$ENV_DIR/theo.env" \
  && ok_t "W2 the unit's env names codex and the account (what 5dive-agent-start launches from)" \
  || bad_t "W2 env" "$(cat "$ENV_DIR/theo.env" 2>/dev/null)"
grep -q "^channel codex telegram theo $TOKEN_B  1234567890$" "$TMP/calls" \
  && [[ "$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$H/.codex/channels/telegram/.env")" == "$TOKEN_B" ]] \
  && ok_t "W3 the codex bridge is installed with the SAME bot token B and the allowlist" \
  || bad_t "W3 token/bridge" "$(cat "$TMP/calls")"
jq -e '.allowFrom == ["1234567890"] and .groups["-1001"].requireMention == true and .dmPolicy == "allowlist"' \
   "$H/.codex/channels/telegram/access.json" >/dev/null 2>&1 \
  && ok_t "W4 allowFrom, groups and dmPolicy carry to the codex bridge" \
  || bad_t "W4 access" "$(cat "$H/.codex/channels/telegram/access.json" 2>/dev/null)"
AG="$H/.codex/AGENTS.md"
grep -qF "$L" "$AG" && ok_t "W5 CLAUDE.md line L is in AGENTS.md" || bad_t "W5 L not carried" "$(cat "$AG" 2>/dev/null)"
! grep -q 'mcp reply\|haiku for Explore\|Be terse' "$AG" \
  && ok_t "W6 5dive's claude-only fragments are NOT carried (codex has its own baseline)" \
  || bad_t "W6 fragments leaked" "$(cat "$AG")"
grep -q 'owner-likes-mornings' "$AG" && grep -q '5dive memory search' "$AG" \
  && [[ -f "$MEM/user_owner_likes_mornings.md" ]] \
  && ok_t "W7 memory atom M stays in the 5dive store and its index is in AGENTS.md (codex loads it every turn)" \
  || bad_t "W7 memory" "$(cat "$AG")"
grep -qF "$L" "$H/.claude/CLAUDE.md" && [[ -f "$H/.claude/settings.json" ]] \
  && ok_t "W8 the Claude side's files are kept (switching back is instant)" \
  || bad_t "W8 claude side changed" ""
jq -e '.data.dropped | index("clicker") and index("telegram lite profile (Codex'"'"'s bridge has no lite mode)")' "$TMP/out" >/dev/null 2>&1 \
  && jq -e '.data.telegram.tokenKept == true and .data.from == "claude" and .data.to == "codex"' "$TMP/out" >/dev/null \
  && ok_t "W9 the result lists what did not carry (a claude-only skill, the lite bot profile)" \
  || bad_t "W9 dropped list" "$(<"$TMP/out")"
[[ -f "$TMP/active" ]] && jq -e '.data.running == true' "$TMP/out" >/dev/null \
  && ok_t "W10 the unit is started again and reported running" || bad_t "W10 not restarted" "$(<"$TMP/out")"

# While on codex: the user adds a line to AGENTS.md and codex writes memory.
printf '\nCodex-era owner line.\n' >>"$AG"
mkdir -p "$H/.codex/memories"
printf '# Task Group: billing export\n\n## Reusable knowledge\n\nThe export runs at 02:00 UTC.\n' >"$H/.codex/memories/MEMORY.md"

# =========================================================== B: and back
rc=$(run cmd_agent_switch theo --to=claude --account=claudeacct)
[[ "$rc" == 0 && "$(jq -r .agents.theo.type "$TMP/reg")" == claude && "$(jq -r .agents.theo.authProfile "$TMP/reg")" == claudeacct ]] \
  && ok_t "B1 switching back makes it claude on the Claude account" \
  || bad_t "B1 back" "rc=$rc err=$(tail -5 "$TMP/err")"
CM="$H/.claude/CLAUDE.md"
[[ "$(grep -cF "$L" "$CM")" == 1 ]] \
  && ok_t "B2 L is in CLAUDE.md exactly once (unchanged, not stacked by the round trip)" \
  || bad_t "B2 L count" "$(grep -cF "$L" "$CM")"
grep -q 'Codex-era owner line' "$CM" && [[ "$(grep -c '5dive:carried-instructions:begin' "$CM")" == 1 ]] \
  && ok_t "B3 what the owner added on codex is carried back, in one block" \
  || bad_t "B3 codex-era line" "$(cat "$CM")"
[[ -f "$MEM/user_owner_likes_mornings.md" ]] && ls "$MEM"/codex-tg-*billing-export*.md >/dev/null 2>&1 \
  && grep -q '5dive:codex-memory:begin' "$MEM/MEMORY.md" && grep -q 'owner-likes-mornings' "$MEM/MEMORY.md" \
  && ok_t "B4 M is still there and the codex memory is converted into atoms + indexed (own index kept)" \
  || bad_t "B4 memory back" "$(ls "$MEM"; cat "$MEM/MEMORY.md")"
! grep -q 'channel claude telegram' "$TMP/calls" && grep -q "^TELEGRAM_BOT_TOKEN=$TOKEN_B$" "$H/.claude/channels/telegram/.env" \
  && grep -q '^TELEGRAM_PROFILE=lite$' "$H/.claude/channels/telegram/.env" \
  && ok_t "B5 the kept claude bridge is reused (token refreshed, lite profile intact, no reinstall)" \
  || bad_t "B5 claude bridge" "$(cat "$TMP/calls")"
! grep -q '^preseed' "$TMP/calls" \
  && ok_t "B6 the kept Claude settings (model) are not re-preseeded" || bad_t "B6 preseed ran" "$(cat "$TMP/calls")"

# =========================================================== R: more refusals
snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch theo --to=codex --account=claudeacct)
[[ "$rc" != 0 ]] && grep -q 'no Codex sign-in' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "R1 switching onto an account with no sign-in for the target is refused, nothing changes" \
  || bad_t "R1" "rc=$rc err=$(<"$TMP/err")"
jq '.agents.theo.channels = "telegram,buzz"' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch theo --to=codex --account=chatgpt)
[[ "$rc" != 0 ]] && grep -q 'buzz channel, which Codex does not have' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "R2 a channel Codex lacks is refused up front rather than silently dropped" \
  || bad_t "R2" "rc=$rc err=$(<"$TMP/err")"
rc=$(run agent_account_move_switch config theo set auth-profile=chatgpt model=x --switch-harness)
[[ "$rc" != 0 ]] && grep -q 'exactly one key' "$TMP/err" \
  && ok_t "R3 --switch-harness refuses to ride along with other keys" || bad_t "R3" "rc=$rc err=$(<"$TMP/err")"

# The UI sends `agent config <n> set auth-profile=<p> --switch-harness`. A box
# whose CLI predates this change has no main.sh route for the flag, so the flag
# reaches cmd_config's key loop: it must be refused there BEFORE any write — else
# the UI would bind a Claude agent to a ChatGPT account on an old box.
printf '%s' "$REG0" >"$TMP/reg"; snap_reg=$(sha256sum <"$TMP/reg"); : >"$TMP/restarts"
rc=$(run cmd_config theo set auth-profile=claudeacct --switch-harness)
[[ "$rc" != 0 ]] && grep -q 'unknown config key: --switch-harness' "$TMP/err" \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && ! -s "$TMP/restarts" ]] \
  && ok_t "R4 the flag reaching cmd_config unrouted (an old CLI) is refused before any write" \
  || bad_t "R4" "rc=$rc err=$(<"$TMP/err")"

# =========================================================== C/M: pure pieces
printf 'own text\n' >"$TMP/dst.md"
switch_carry_doc "$CM" "$TMP/dst.md" claude codex "" >"$TMP/c1"
cp "$TMP/c1" "$TMP/dst.md"
switch_carry_doc "$CM" "$TMP/dst.md" claude codex "" >"$TMP/c2"
cmp -s "$TMP/c1" "$TMP/c2" && [[ "$(head -1 "$TMP/c1")" == "own text" ]] \
  && ok_t "C1 carrying twice is idempotent and the target's own text stays first, untouched" \
  || bad_t "C1 carry not idempotent" "$(diff "$TMP/c1" "$TMP/c2")"
out=$(switch_codex_memory_to_atoms "$H/.codex/memories" "$MEM")
[[ "$out" == "0 0 0 1" ]] \
  && ok_t "M1 re-converting unchanged codex memory rewrites nothing (only what changed since)" \
  || bad_t "M1 counts" "$out"
: >"$H/.codex/memories/MEMORY.md"
out=$(switch_codex_memory_to_atoms "$H/.codex/memories" "$MEM")
[[ "$out" == "0 0 1 0" ]] && ! grep -q 'codex-memory:begin' "$MEM/MEMORY.md" && [[ -f "$MEM/user_owner_likes_mornings.md" ]] \
  && ok_t "M2 a codex fact that is gone is removed with its index block; claude atoms untouched" \
  || bad_t "M2" "$out $(cat "$MEM/MEMORY.md")"
{ printf 'line\n%.0s' $(seq 1 6000); } >"$TMP/big.md"
switch_carry_doc "$TMP/big.md" "$TMP/none.md" claude codex "" >"$TMP/c3"
[[ $(wc -c <"$TMP/c3") -lt 17000 ]] && grep -q "cut at 15000 bytes for Codex's 32 KiB limit" "$TMP/c3" \
  && grep -q '5dive:carried-instructions:end' "$TMP/c3" \
  && ok_t "C3 carried instructions are cut for codex's 32 KiB AGENTS.md limit, and the block still closes" \
  || bad_t "C3 budget" "$(wc -c <"$TMP/c3")"
# C5: the budget is BYTES. Cyrillic is two bytes a character, so a character
# count let a 49 KB CLAUDE.md + an 8 KB index carry ~37 KB and push '## Memory'
# past codex's 32 KiB read (quinn's repro, iteration 1).
LANG=en_US.UTF-8 python3 -c "print(('Всегда отвечай владельцу по-русски, коротко и по делу.\n')*900)" >"$TMP/cyr.md"
python3 -c "print(('- [some-atom](some-atom.md) — a one-line hook about a fact\n')*200)" >"$TMP/idx8k.md"
( export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null
  switch_carry_doc "$TMP/cyr.md" "$TMP/none.md" claude codex "$TMP/idx8k.md" ) >"$TMP/c5"
c5b=$(sed -n '/5dive:carried-instructions:begin/,/5dive:carried-instructions:end/p' "$TMP/c5" | LC_ALL=C wc -c)
c5m=$(grep -bo '^## Memory' "$TMP/c5" | cut -d: -f1)
[[ "$c5b" -lt 24576 && -n "$c5m" ]] && python3 -c 'import sys; open(sys.argv[1], encoding="utf-8").read()' "$TMP/c5" \
  && grep -q '5dive:carried-instructions:end' "$TMP/c5" \
  && ok_t "C5 multibyte instructions are cut by BYTES: block ${c5b} B < 24 KiB, '## Memory' at byte ${c5m}, valid UTF-8" \
  || bad_t "C5 byte budget" "block=${c5b} memory-at=${c5m:-absent}"
switch_carry_doc "$TMP/big.md" "$TMP/none.md" codex claude "" >"$TMP/c4"
[[ $(wc -c <"$TMP/c4") -gt 30000 ]] && ok_t "C4 nothing is cut going to Claude (no such limit)" || bad_t "C4" "$(wc -c <"$TMP/c4")"
# L1-L3: the conversion runs as root in a dir the seat owns. A link the agent
# plants there must not carry root's write (quinn's repro, iteration 1).
LH="$TMP/lh"; LM="$LH/.claude/projects/p/memory"; LC="$LH/.codex/memories"
mkdir -p "$LM" "$LC" "$TMP/rootdir"
printf -- '- [codex-tg-owner](x) — owner\n' >"$LC/MEMORY.md"
echo "ROOT-OWNED ORIGINAL" >"$TMP/victim"; echo "ROOT-OWNED IDX" >"$TMP/victim2"
v1=$(sha256sum <"$TMP/victim"); v2=$(sha256sum <"$TMP/victim2")
ln -sf "$TMP/victim" "$LM/codex-tg-owner.md"; ln -sf "$TMP/victim2" "$LM/MEMORY.md"
_pack_codex_to_atoms_real=$(declare -f _pack_codex_to_atoms)
_pack_codex_to_atoms() { printf -- '---\nname: codex-tg-owner\ndescription: "x"\n---\nssh-ed25519 AAAAC3Nza-agent-controlled-line\n' >"$2/codex-tg-owner.md"; }
switch_codex_memory_to_atoms "$LC" "$LM" agent-lh "$LH" >/dev/null
[[ "$(sha256sum <"$TMP/victim")" == "$v1" && -L "$LM/codex-tg-owner.md" ]] \
  && ok_t "L1 a codex atom planted as a symlink is refused: its target is unchanged" \
  || bad_t "L1 wrote through the atom symlink" "$(cat "$TMP/victim")"
[[ "$(sha256sum <"$TMP/victim2")" == "$v2" && -L "$LM/MEMORY.md" ]] \
  && ok_t "L2 a MEMORY.md planted as a symlink is refused: its target is unchanged" \
  || bad_t "L2 wrote through the MEMORY.md symlink" "$(cat "$TMP/victim2")"
rm -rf "$LH/.claude/projects/p"; ln -s "$TMP/rootdir" "$LH/.claude/projects/p"
switch_codex_memory_to_atoms "$LC" "$LH/.claude/projects/p/memory" agent-lh "$LH" >/dev/null; rc=$?
[[ "$rc" != 0 && -z "$(ls -A "$TMP/rootdir")" ]] \
  && ok_t "L3 a memory dir reached through a symlinked parent is refused: nothing created there" \
  || bad_t "L3 symlinked parent" "rc=$rc $(ls -AR "$TMP/rootdir")"
eval "$_pack_codex_to_atoms_real"

# =========================================================== P: a parked agent
# `5dive agent stop` records desiredState=stopped; the switch converts the seat
# and must NOT start it (the GUARDED verdict in refresh_plugins_parked_agent_unit).
jq '.agents.theo = {"type":"claude","channels":"telegram","authProfile":"claudeacct","isolation":"standard","desiredState":"stopped"}' \
  "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
rm -f "$TMP/active"
rc=$(run cmd_agent_switch theo --to=codex --account=chatgpt)
[[ "$rc" == 0 && "$(jq -r .agents.theo.type "$TMP/reg")" == codex && ! -f "$TMP/active" ]] \
  && [[ "$(jq -r .agents.theo.desiredState "$TMP/reg")" == stopped ]] \
  && jq -e '.data.running == false and .data.parked == true' "$TMP/out" >/dev/null \
  && ok_t "P1 a parked agent is switched but left stopped (its park survives the switch)" \
  || bad_t "P1 parked agent was started" "rc=$rc active=$([[ -f "$TMP/active" ]] && echo yes || echo no) err=$(tail -3 "$TMP/err") out=$(<"$TMP/out")"
(JSON_MODE=0; cmd_agent_switch theo --to=claude --account=claudeacct) >"$TMP/out" 2>"$TMP/err"; rc=$?
[[ "$rc" == 0 && ! -f "$TMP/active" ]] && grep -qF "switched; left stopped, start it with 5dive agent start theo" "$TMP/out" \
  && ok_t "P2 the result tells the owner it was left stopped and how to start it" \
  || bad_t "P2 parked wording" "rc=$rc out=$(<"$TMP/out") err=$(tail -3 "$TMP/err")"

# An instructions file the type map does not know fails loudly before any write
# (the optional-map contract), rather than dying on set -u or carrying to $home/.
snap_reg=$(sha256sum <"$TMP/reg"); _pf_saved="${TYPE_PERSONA_FILE[codex]}"; unset 'TYPE_PERSONA_FILE[codex]'
rc=$(run cmd_agent_switch theo --to=codex --account=chatgpt)
TYPE_PERSONA_FILE[codex]="$_pf_saved"
[[ "$rc" != 0 ]] && grep -q 'no instructions file is known' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "P3 a type with no instructions file in the map is refused with a message, registry unchanged" \
  || bad_t "P3 empty persona map" "rc=$rc err=$(tail -3 "$TMP/err")"

w=$(switch_harness_warning Theo claude codex)
[[ "$w" == "Moving Theo to your ChatGPT plan switches it from Claude Code to Codex. Its memory and instructions are converted; this chat's history is not. You can switch back any time." ]] \
  && ok_t "C2 the warning sentence is the one every surface shows" || bad_t "C2 warning" "$w"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
