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
#   K1-K10 (DIVE-8675) --keep-model: a Hermes/OpenClaw seat on DeepSeek, OpenRouter
#          or Kimi moves on its own key + model (the account names the vendor's
#          Anthropic-format URL and the model); plain OpenAI is refused.
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
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"   # never the host's /etc/5dive/connectors
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
         "$H/.claude/skills/clicker/refs" "$H/.claude/skills/5dive-cli" "$H/.claude/skills/notify-user"
# DIVE-8667: a skill the owner added (clicker, with a nested file and its
# provenance) and two 5dive installs per harness (a default skill, notify-user).
printf -- '---\nname: clicker\ndescription: clicks things\n---\nClick.\n' >"$H/.claude/skills/clicker/SKILL.md"
printf 'ref\n' >"$H/.claude/skills/clicker/refs/one.md"
printf '{"clicker":{"source":"acme/skills","resolved_sha":"","content_sha256":"x","installed_at":"2026-11-01T00:00:00Z"}}\n' \
  >"$H/.claude/skills/.skills-manifest.json"
printf -- '---\nname: 5dive-cli\n---\nclaude-side body\n' >"$H/.claude/skills/5dive-cli/SKILL.md"
printf -- '---\nname: notify-user\n---\nclaude-side body\n' >"$H/.claude/skills/notify-user/SKILL.md"
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
sudo() { local _u="" _h=0
         while [[ "${1:-}" == -* ]]; do case "$1" in -u) _u="$2"; shift 2 ;; -H) _h=1; shift ;; *) shift ;; esac; done
         # -H: the seat's own HOME, as real sudo gives it (the skill manifest writer resolves through it).
         if (( _h )) && [[ -n "$_u" ]]; then ( export HOME="$SWITCH_HOME_ROOT/$_u"; sudo "$@" ); return; fi
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
# DIVE-7747: the move reads the link back before it queues the restart, so the
# shim points it where the real one does (a no-op link is a move that did not land).
link_agent_profile() { printf '%s %s\n' "$1" "${2:-}" >>"$TMP/links"
  rm -f "$ENV_DIR/$1-auth.env"; [[ -z "${2:-}" ]] || ln -s "$AUTH_PROFILES_DIR/$2/combined.env" "$ENV_DIR/$1-auth.env"; }
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
# DIVE-8371: the arms above run as an OUTSIDE caller, wherever the harness runs
# (a seat's own unit, CI): no sudo caller, a cgroup that names no seat.
unset SUDO_USER; export SWITCH_SELF_CGROUP_FILE="$TMP/cg-outside"
printf '0::/system.slice/ci-runner.service\n' >"$SWITCH_SELF_CGROUP_FILE"

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
jq -e '.data.dropped == ["5dive-cli","notify-user","telegram lite profile (Codex'"'"'s bridge has no lite mode)"]' "$TMP/out" >/dev/null 2>&1 \
  && jq -e '.data.telegram.tokenKept == true and .data.from == "claude" and .data.to == "codex"' "$TMP/out" >/dev/null \
  && ok_t "W9 the result lists what did not carry (the per-harness 5dive skills, the lite bot profile) and no longer the owner's skill" \
  || bad_t "W9 dropped list" "$(<"$TMP/out")"
CS="$H/.agents/skills"
[[ -f "$CS/clicker/SKILL.md" && "$(cat "$CS/clicker/refs/one.md" 2>/dev/null)" == ref ]] \
  && cmp -s "$CS/clicker/SKILL.md" "$H/.claude/skills/clicker/SKILL.md" && [[ -f "$H/.claude/skills/clicker/SKILL.md" ]] \
  && jq -e '.data.copied == ["clicker"]' "$TMP/out" >/dev/null 2>&1 \
  && ok_t "W11 a skill the owner added on Claude is copied, whole, into Codex's skills dir and listed as copied; the Claude copy stays (RED on main: only listed)" \
  || bad_t "W11 skill not carried" "$(ls -R "$CS" 2>&1) out=$(<"$TMP/out")"
[[ ! -e "$CS/5dive-cli" && ! -e "$CS/notify-user" ]] \
  && ok_t "W12 a skill 5dive installs per harness (a default skill, notify-user) is NOT copied across" \
  || bad_t "W12 per-harness skill duplicated" "$(ls "$CS")"
jq -e '.clicker.source == "acme/skills"' "$CS/.skills-manifest.json" >/dev/null 2>&1 \
  && ok_t "W13 the copied skill keeps where it came from (its manifest entry is written on the Codex side)" \
  || bad_t "W13 provenance" "$(cat "$CS/.skills-manifest.json" 2>&1)"
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
jq -e '.data.copied == []' "$TMP/out" >/dev/null 2>&1 && [[ "$(ls "$H/.claude/skills" | tr '\n' ' ')" == "5dive-cli clicker notify-user " ]] \
  && ok_t "B7 switching back copies nothing: the skill is already on the Claude side, no duplicate" \
  || bad_t "B7 back copied" "$(ls "$H/.claude/skills") out=$(<"$TMP/out")"

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

# =========================================================== G: Grok (DIVE-7414)
# Dude was hired on a Grok login (a new login is the default for new hires,
# DIVE-7152) and could never move: switch refused every grok seat. Grok reads
# ~/.claude/CLAUDE.md and its memory is the 5dive store, so Claude <-> Grok
# shares both files; Codex <-> Grok converts like Codex <-> Claude.
mkdir -p "$AUTH_PROFILES_DIR/grokacct/grok/.grok"
: >"$AUTH_PROFILES_DIR/grokacct/combined.env"
printf '{"access_token":"x"}\n' >"$AUTH_PROFILES_DIR/grokacct/grok/.grok/auth.json"
export FIVE_GROK_OFF_MARKER="$TMP/grok-off"; : >"$FIVE_GROK_OFF_MARKER"   # owner turned Grok off (DIVE-7802)
grok_plugin_dir() { echo "$TMP/telegram-grok"; }
TYPE_BIN[grok]=/bin/true
DH="$SWITCH_HOME_ROOT/agent-dude"; DMEM="$DH/.claude/projects/-home-claude-projects/memory"
TOKEN_D='7000000002:AAddddddddddddddddddddddddddddddddd'
LD='Dude signs every reply with a dog emoji — owner-written line LD.'
mkdir -p "$DH/.grok/channels/telegram" "$DH/.grok/skills/grok-only" "$DMEM"
printf -- '---\nname: grok-only\n---\nGrok-side skill.\n' >"$DH/.grok/skills/grok-only/SKILL.md"
mkdir -p "$DH/.grok/skills/no-body"   # a folder with no SKILL.md is not a skill: not copied
printf '# Dude\n\n%s\n' "$LD" >"$DH/.claude/CLAUDE.md"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_D" >"$DH/.grok/channels/telegram/.env"
printf '{"dmPolicy":"allowlist","allowFrom":["555"],"groups":{},"pending":{}}\n' >"$DH/.grok/channels/telegram/access.json"
printf -- '---\nname: dude-ships-fridays\ndescription: "releases go out on Fridays"\nmetadata:\n  type: project\n---\n\nFridays.\n' >"$DMEM/project_dude_ships_fridays.md"
printf '# Memory Index\n\n- [dude-ships-fridays](project_dude_ships_fridays.md) — releases go out on Fridays\n' >"$DMEM/MEMORY.md"
REGD=$(jq -c '.agents.dude = {"type":"grok","channels":"telegram","authProfile":"grokacct","isolation":"standard"}' "$TMP/reg")
printf '%s' "$REGD" >"$TMP/reg"
blocks() { grep -c '5dive:carried-instructions:begin' "$1"; }

[[ "$(switch_account_types grokacct)" == grok && "$(switch_target_for_account grok claudeacct)" == claude \
   && "$(switch_target_for_account grok chatgpt)" == codex && "$(switch_target_for_account claude grokacct)" == grok \
   && "$(switch_target_for_account codex grokacct)" == grok && -z "$(switch_target_for_account grok grokacct)" \
   && -z "$(switch_account_harness grokacct)" ]] \
  && ok_t "G0 a Grok account is read as one; a Grok agent on a Claude/ChatGPT account (and back) is a switch; compose's claude/codex answer is unchanged" \
  || bad_t "G0 grok account kinds" "types=$(switch_account_types grokacct) g->c=$(switch_target_for_account grok claudeacct) c->g=$(switch_target_for_account claude grokacct)"
snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_config dude set auth-profile=claudeacct)
[[ "$rc" != 0 ]] && grep -q 'switches it from Grok to Claude Code' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "G1 a plain account move of a Grok agent onto a Claude account is refused with the sentence (RED on main: it binds)" \
  || bad_t "G1 grok rebind not refused" "rc=$rc err=$(<"$TMP/err")"

# grok -> claude
: >"$TMP/active"; : >"$TMP/calls"
rc=$(run agent_account_move_switch config dude set auth-profile=claudeacct --switch-harness)
[[ "$rc" == 0 && "$(jq -r .agents.dude.type "$TMP/reg")" == claude && "$(jq -r .agents.dude.authProfile "$TMP/reg")" == claudeacct ]] \
  && grep -q '^AGENT_TYPE=claude$' "$ENV_DIR/dude.env" && [[ -f "$TMP/active" ]] \
  && ok_t "G2 grok -> claude: the confirmed move (the app's argv) makes Dude a Claude agent on the Claude account and starts it" \
  || bad_t "G2 grok->claude" "rc=$rc err=$(tail -5 "$TMP/err") reg=$(jq -c .agents.dude "$TMP/reg")"
grep -q "^channel claude telegram dude $TOKEN_D  555$" "$TMP/calls" \
  && jq -e '.allowFrom == ["555"]' "$DH/.claude/channels/telegram/access.json" >/dev/null 2>&1 \
  && grep -q '^preseed dude telegram' "$TMP/calls" \
  && ok_t "G3 grok -> claude: Claude is preseeded (first time) and its bridge gets the SAME bot token and allowlist" \
  || bad_t "G3 bridge" "$(cat "$TMP/calls")"
[[ "$(grep -cF "$LD" "$DH/.claude/CLAUDE.md")" == 1 && "$(blocks "$DH/.claude/CLAUDE.md")" == 1 ]] \
  && grep -q 'from=grok' "$DH/.claude/CLAUDE.md" && ! grep -q '^## Memory' "$DH/.claude/CLAUDE.md" \
  && grep -q "$SWITCH_HANDOFF_FILE" "$DH/.claude/CLAUDE.md" \
  && ok_t "G4 grok -> claude: the shared CLAUDE.md keeps LD exactly once, one block pointing at the handoff, no memory copy (Claude loads MEMORY.md)" \
  || bad_t "G4 CLAUDE.md" "$(cat "$DH/.claude/CLAUDE.md")"
[[ -f "$DMEM/project_dude_ships_fridays.md" ]] && jq -e '.data.memory.direction == "grok->claude" and .data.memory.atoms == 1 and .data.from == "grok" and (.data.copied == ["grok-only"]) and (.data.dropped == ["no-body"])' "$TMP/out" >/dev/null \
  && [[ -f "$DH/.claude/skills/grok-only/SKILL.md" && ! -e "$DH/.claude/skills/no-body" ]] \
  && ok_t "G5 grok -> claude: the memory atoms stay where both read them; the Grok-side skill is copied to Claude, a bodiless folder is listed as not carried" \
  || bad_t "G5 memory/result" "$(<"$TMP/out")"

# claude -> grok, owner's switch off, then on
snap_reg=$(sha256sum <"$TMP/reg"); snap_home=$(find "$DH" -type f -exec sha256sum {} + | sort | sha256sum)
rc=$(run cmd_agent_switch dude --to=grok --account=grokacct)
[[ "$rc" != 0 ]] && grep -q 'Grok is turned off on this server' "$TMP/err" && grep -q 'sudo 5dive grok enable' "$TMP/err" \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && "$(find "$DH" -type f -exec sha256sum {} + | sort | sha256sum)" == "$snap_home" ]] \
  && ok_t "G6 claude -> grok with Grok turned off is refused with the reason and how to turn it on; nothing changes" \
  || bad_t "G6 unarmed" "rc=$rc err=$(<"$TMP/err")"
rm -f "$FIVE_GROK_OFF_MARKER"
rc=$(run cmd_agent_switch dude --to=grok --account=claudeacct)
[[ "$rc" != 0 ]] && grep -q 'no Grok sign-in' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "G7 claude -> grok onto an account with no Grok sign-in is refused, nothing changes" \
  || bad_t "G7 no grok login" "rc=$rc err=$(<"$TMP/err")"
: >"$TMP/calls"
rc=$(run cmd_agent_switch dude --to=grok --account=grokacct)
[[ "$rc" == 0 && "$(jq -r .agents.dude.type "$TMP/reg")" == grok && "$(jq -r .agents.dude.authProfile "$TMP/reg")" == grokacct ]] \
  && grep -q "^channel grok telegram dude $TOKEN_D  555$" "$TMP/calls" \
  && ok_t "G8 claude -> grok (Grok on): Grok agent again, same token on the Grok bridge" \
  || bad_t "G8 claude->grok" "rc=$rc err=$(tail -5 "$TMP/err") calls=$(cat "$TMP/calls")"
[[ "$(grep -cF "$LD" "$DH/.claude/CLAUDE.md")" == 1 && "$(blocks "$DH/.claude/CLAUDE.md")" == 1 ]] \
  && grep -q '^## Memory' "$DH/.claude/CLAUDE.md" && grep -q 'dude-ships-fridays' "$DH/.claude/CLAUDE.md" \
  && jq -e '.data.memory.indexCarried == true' "$TMP/out" >/dev/null \
  && ok_t "G9 claude -> grok: LD once, one block, and the memory index is in it (Grok loads no MEMORY.md)" \
  || bad_t "G9 CLAUDE.md to grok" "$(cat "$DH/.claude/CLAUDE.md")"

# grok -> codex, and codex -> grok
rc=$(run cmd_agent_switch dude --to=codex --account=chatgpt)
DAG="$DH/.codex/AGENTS.md"
[[ "$rc" == 0 && "$(jq -r .agents.dude.type "$TMP/reg")" == codex ]] && grep -qF "$LD" "$DAG" \
  && grep -q 'dude-ships-fridays' "$DAG" && [[ "$(blocks "$DAG")" == 1 ]] \
  && [[ "$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$DH/.codex/channels/telegram/.env")" == "$TOKEN_D" ]] \
  && ok_t "G10 grok -> codex: LD and the memory index carried into AGENTS.md, same bot token" \
  || bad_t "G10 grok->codex" "rc=$rc err=$(tail -5 "$TMP/err") $(cat "$DAG" 2>/dev/null)"
printf '\nCodex-era Dude line.\n' >>"$DAG"
mkdir -p "$DH/.codex/memories"
printf '# Task Group: invoices\n\n## Reusable knowledge\n\nInvoices close on the 3rd.\n' >"$DH/.codex/memories/MEMORY.md"
rc=$(run cmd_agent_switch dude --to=grok --account=grokacct)
[[ "$rc" == 0 && "$(jq -r .agents.dude.type "$TMP/reg")" == grok ]] \
  && [[ "$(grep -cF "$LD" "$DH/.claude/CLAUDE.md")" == 1 && "$(blocks "$DH/.claude/CLAUDE.md")" == 1 ]] \
  && grep -q 'Codex-era Dude line' "$DH/.claude/CLAUDE.md" \
  && ok_t "G11 codex -> grok: what the owner added on Codex is carried into CLAUDE.md, LD once, one block" \
  || bad_t "G11 codex->grok" "rc=$rc err=$(tail -5 "$TMP/err") $(cat "$DH/.claude/CLAUDE.md")"
ls "$DMEM"/codex-tg-*invoices*.md >/dev/null 2>&1 && grep -q 'codex-tg-.*invoices' "$DH/.claude/CLAUDE.md" \
  && jq -e '.data.memory.direction == "codex->grok"' "$TMP/out" >/dev/null \
  && ok_t "G12 codex -> grok: the Codex memory is converted into atoms and their index reaches Grok" \
  || bad_t "G12 codex memory to grok" "$(ls "$DMEM") $(<"$TMP/out")"
rc=$(run cmd_agent_switch dude --to=claude --account=claudeacct)
[[ "$rc" == 0 ]] && grep -q 'Codex-era Dude line' "$DH/.claude/CLAUDE.md" \
  && [[ "$(grep -cF "$LD" "$DH/.claude/CLAUDE.md")" == 1 && "$(blocks "$DH/.claude/CLAUDE.md")" == 1 ]] \
  && ! grep -q '^## Memory' "$DH/.claude/CLAUDE.md" \
  && ok_t "G13 grok -> claude after a Codex trip keeps the carried Codex-era line (same-file switch does not drop it)" \
  || bad_t "G13 kept block" "rc=$rc $(cat "$DH/.claude/CLAUDE.md")"
jq '.agents.dude.channels = "telegram,buzz"' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch dude --to=grok --account=grokacct)
[[ "$rc" != 0 ]] && grep -q 'buzz channel, which Grok does not have' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "G14 a channel Grok lacks is refused up front" || bad_t "G14" "rc=$rc err=$(<"$TMP/err")"
w=$(switch_harness_warning Dude grok claude); w2=$(switch_harness_warning Theo claude grok)
[[ "$w" == "Moving Dude to your Claude plan switches it from Grok to Claude Code. Its memory and instructions are converted; this chat's history is not. You can switch back any time." \
   && "$w2" == "Moving Theo to your Grok plan switches it from Claude Code to Grok. Its memory and instructions are converted; this chat's history is not. You can switch back any time." ]] \
  && ok_t "G15 the sentence names Grok both ways" || bad_t "G15 warning" "$w | $w2"
unset FIVE_GROK_OFF_MARKER

# =========================================================== T: token only in the connector copy (DIVE-9216)
# A Claude seat whose bot was attached before DIVE-4609 has no per-seat
# ~/.claude/channels/telegram/.env; its token lives only in the box's
# $CONNECTORS_DIR/telegram-<name>.env (what the unit loads, what telegram-info reads).
# On origin/main the switch refused it: "no bot token on disk".
TH="$SWITCH_HOME_ROOT/agent-tess"; mkdir -p "$TH/.claude"; printf 'Tess line.\n' >"$TH/.claude/CLAUDE.md"
TOKEN_T='7000000003:AAtttttttttttttttttttttttttttttttt'
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_T" >"$CONNECTORS_DIR/telegram-tess.env"
jq '.agents.tess = {"type":"claude","channels":"telegram","authProfile":"claudeacct","isolation":"standard"}' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
rc=$(run cmd_agent_switch tess --to=codex --account=chatgpt)
[[ "$rc" == 0 && "$(jq -r .agents.tess.type "$TMP/reg")" == codex && ! -e "$TH/.claude/channels/telegram/.env" ]] \
  && [[ "$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$TH/.codex/channels/telegram/.env" 2>/dev/null)" == "$TOKEN_T" ]] \
  && ok_t "T1 a Claude seat with its bot token only in the connector copy switches to codex and keeps that bot (RED on main: refused)" \
  || bad_t "T1 connector-only token" "rc=$rc err=$(tail -3 "$TMP/err")"
UH="$SWITCH_HOME_ROOT/agent-una"; mkdir -p "$UH/.claude"; printf 'Una line.\n' >"$UH/.claude/CLAUDE.md"
jq '.agents.una = {"type":"claude","channels":"telegram","authProfile":"claudeacct","isolation":"standard"}' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch una --to=codex --account=chatgpt)
[[ "$rc" != 0 ]] && grep -q "agent 'una' has channels=telegram but no bot token on disk" "$TMP/err" \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && ! -e "$UH/.codex/channels/telegram/.env" ]] \
  && ok_t "T2 a seat with no token anywhere (seat files nor connector copy) is still refused, nothing changed" \
  || bad_t "T2 tokenless refusal" "rc=$rc err=$(tail -3 "$TMP/err")"

# =========================================================== D: a seat switching ITSELF (DIVE-8371)
# kos runs `sudo 5dive agent switch kos` from inside 5dive-agent@kos.service. On
# origin/main step 1 stops that unit and the stop kills the switch with it.
KH="$SWITCH_HOME_ROOT/agent-kos"; mkdir -p "$KH/.claude"; printf 'Kos line.\n' >"$KH/.claude/CLAUDE.md"
jq '.agents.kos = {"type":"claude","channels":"none","authProfile":"claudeacct","isolation":"standard"}' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
systemctl() { printf '%s\n' "$*" >>"$TMP/sysctl"
  case "$1" in is-active) [[ -f "$TMP/active" ]] ;; stop) rm -f "$TMP/active" ;; start) : >"$TMP/active" ;; esac; }
systemd-run() { printf '%s\n' "$*" >>"$TMP/sdrun"; [[ ! -f "$TMP/sdrun-fail" ]]; }
SELFSEND="$TMP/selfsend"; printf '#!/bin/sh\necho "$*" >>%s\nexit 1\n' "$TMP/sends" >"$SELFSEND"; chmod +x "$SELFSEND"
FIVEDIVE_SELF="$SELFSEND"
CG_KOS="$TMP/cg-kos"; printf '0::/system.slice/system-5dive\\x2dagent.slice/5dive-agent@kos.service\n' >"$CG_KOS"
dreset() { : >"$TMP/active"; rm -f "$TMP/sdrun" "$TMP/sysctl" "$TMP/sends" "$TMP/sdrun-fail"; }

dreset; snap_reg=$(sha256sum <"$TMP/reg")
rc=$(SWITCH_SELF_CGROUP_FILE="$CG_KOS" run cmd_agent_switch kos --to=codex --account=chatgpt)
[[ "$rc" == 0 ]] && grep -q -- '--unit=5dive-switch-kos-' "$TMP/sdrun" && grep -q -- '-p KillMode=process' "$TMP/sdrun" \
  && grep -q -- '--setenv=FIVEDIVE_SWITCH_DETACHED=1' "$TMP/sdrun" && grep -q -- '--on-active=20 ' "$TMP/sdrun" \
  && grep -q -- "-- $SELFSEND agent switch kos --to=codex --account=chatgpt\$" "$TMP/sdrun" \
  && ! grep -q '^stop' "$TMP/sysctl" 2>/dev/null && [[ -f "$TMP/active" ]] \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && jq -e '.data.detached == true and .data.to == "codex" and (.data.unit|startswith("5dive-switch-kos-")) and .data.startsInSeconds == 20' "$TMP/out" >/dev/null \
  && ok_t "D1 inside its own unit: the switch relaunches as a detached transient service and returns; no in-line stop, nothing converted yet" \
  || bad_t "D1 self-switch detaches" "rc=$rc sdrun=$(cat "$TMP/sdrun" 2>/dev/null) sysctl=$(cat "$TMP/sysctl" 2>/dev/null) out=$(<"$TMP/out") err=$(tail -3 "$TMP/err")"
[[ ! -s "$TMP/sends" ]] && jq -e '.data.next | contains("~/.5dive-handoff.md") and contains("back on Codex")' "$TMP/out" >/dev/null \
  && ok_t "D2 no handoff ask to a seat that is the caller; it is told to write the note itself" \
  || bad_t "D2 no handoff ask" "sends=$(cat "$TMP/sends" 2>/dev/null) out=$(<"$TMP/out")"

dreset
rc=$(SUDO_USER=agent-kos run cmd_agent_switch kos --to=codex --account=chatgpt)
[[ "$rc" == 0 ]] && grep -q -- '--unit=5dive-switch-kos-' "$TMP/sdrun" && ! grep -q '^stop' "$TMP/sysctl" 2>/dev/null \
  && ok_t "D3 sudo called by the seat's own user detaches too (cgroup unreadable or elsewhere)" \
  || bad_t "D3 SUDO_USER detaches" "rc=$rc sdrun=$(cat "$TMP/sdrun" 2>/dev/null)"

dreset; touch "$TMP/sdrun-fail"; snap_reg=$(sha256sum <"$TMP/reg")
rc=$(SWITCH_SELF_CGROUP_FILE="$CG_KOS" run cmd_agent_switch kos --to=codex --account=chatgpt)
[[ "$rc" != 0 ]] && grep -q 'nothing switched' "$TMP/err" && [[ -f "$TMP/active" ]] && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "D4 a detach that cannot start fails loudly and leaves the seat running and unchanged" \
  || bad_t "D4 detach failure" "rc=$rc err=$(<"$TMP/err")"

dreset; snap_reg=$(sha256sum <"$TMP/reg")
rc=$(SWITCH_SELF_CGROUP_FILE="$CG_KOS" run cmd_agent_switch kos --to=codex --account=empty)
[[ "$rc" != 0 ]] && grep -q 'no Codex sign-in' "$TMP/err" && [[ ! -s "$TMP/sdrun" ]] && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "D5 a pre-flight refusal still reaches the self-caller in line (nothing is detached)" \
  || bad_t "D5 refusal inline" "rc=$rc err=$(<"$TMP/err") sdrun=$(cat "$TMP/sdrun" 2>/dev/null)"

dreset; printf '0::/system.slice/system-5dive\\x2dagent.slice/5dive-agent@kosmo.service\n' >"$TMP/cg-other"
rc=$(SWITCH_SELF_CGROUP_FILE="$TMP/cg-other" SUDO_USER=agent-kosmo run cmd_agent_switch kos --to=codex --account=chatgpt)
[[ "$rc" == 0 ]] && [[ ! -s "$TMP/sdrun" ]] && grep -q '^stop 5dive-agent@kos.service' "$TMP/sysctl" \
  && [[ "$(jq -r '.agents.kos.type' "$TMP/reg")" == codex ]] && grep -q '^start 5dive-agent@kos.service' "$TMP/sysctl" \
  && ok_t "D6 another seat (kosmo) switching kos runs in line as before, and a name prefix is not a match" \
  || bad_t "D6 other caller inline" "rc=$rc sdrun=$(cat "$TMP/sdrun" 2>/dev/null) sysctl=$(cat "$TMP/sysctl" 2>/dev/null) err=$(tail -3 "$TMP/err")"

# The detached half: same cgroup marker would still match, the env says it is the child.
dreset; t0=$(( $(date +%s) - 5 )); printf 'what I was doing\n' >"$KH/.5dive-handoff.md"
rc=$(SWITCH_SELF_CGROUP_FILE="$CG_KOS" FIVEDIVE_SWITCH_DETACHED=1 FIVEDIVE_SWITCH_T0="$t0" run cmd_agent_switch kos --to=claude --account=claudeacct)
[[ "$rc" == 0 ]] && [[ ! -s "$TMP/sdrun" ]] && [[ ! -s "$TMP/sends" ]] && grep -q '^stop 5dive-agent@kos.service' "$TMP/sysctl" \
  && [[ "$(jq -r '.agents.kos.type' "$TMP/reg")" == claude ]] && jq -e '.data.handoff == "written" and .data.running == true' "$TMP/out" >/dev/null \
  && ok_t "D7 the detached child does the real switch (stop, convert, start), never re-detaches or asks, and reads the self-written note" \
  || bad_t "D7 detached child" "rc=$rc sdrun=$(cat "$TMP/sdrun" 2>/dev/null) sends=$(cat "$TMP/sends" 2>/dev/null) out=$(<"$TMP/out") err=$(tail -3 "$TMP/err")"

# =========================================================== H/O: Hermes and OpenClaw -> Claude Code (DIVE-8672)
# X is a hermes seat (or an openclaw seat) with a Telegram bot B2, an owner line
# in its instructions, a memory entry, an owner skill and a scheduled job. After
# `agent switch X --to=claude`: the SAME bot token is on the claude bridge, the
# harness's own poller was stopped first, the memory is atoms `5dive memory
# search` finds, and the result says the scheduled jobs did not move.
TOKEN_H='7000000002:AAhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh'
TOKEN_O='7000000003:AAoooooooooooooooooooooooooooooooooo'
HH="$SWITCH_HOME_ROOT/agent-herm"; OH="$SWITCH_HOME_ROOT/agent-ocl"
mkdir -p "$HH/.hermes/memories" "$HH/.hermes/skills/research/arxiv" "$HH/.hermes/skills/my-notes" "$HH/.hermes/cron"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=1234567890,555\nDEEPSEEK_API_KEY=sk-ds\n' "$TOKEN_H" >"$HH/.hermes/.env"
HSOUL_DEFAULT="$TMP/hermes-agent/hermes_cli/default_soul.py"; mkdir -p "$(dirname "$HSOUL_DEFAULT")"
printf 'DEFAULT_SOUL_MD = (\n    "You are Hermes Agent, a helpful assistant.\\n"\n    "Be concise.\\n"\n)\n' >"$HSOUL_DEFAULT"
export HERMES_AGENT_DIR="$TMP/hermes-agent"
printf 'You are Hermes Agent, a helpful assistant.\nBe concise.\n\nHermes owner line: always cite the source.\n' >"$HH/.hermes/SOUL.md"
printf 'The staging DB is on port 5544.\n§\nDeploys happen on Fridays only.\n' >"$HH/.hermes/memories/MEMORY.md"
printf 'Owner prefers short answers.\n' >"$HH/.hermes/memories/USER.md"
printf -- '---\nname: arxiv\n---\nbundled\n' >"$HH/.hermes/skills/research/arxiv/SKILL.md"
printf -- '---\nname: my-notes\ndescription: owner skill\n---\nNotes.\n' >"$HH/.hermes/skills/my-notes/SKILL.md"
printf 'arxiv:abc123\n' >"$HH/.hermes/skills/.bundled_manifest"
printf '{"jobs":[{"id":"daily"},{"id":"weekly"}]}\n' >"$HH/.hermes/cron/jobs.json"

mkdir -p "$OH/.openclaw/workspace/memory" "$OH/.openclaw/workspace/skills/ocskill" "$OH/.openclaw/secrets"
printf '%s' "$TOKEN_O" >"$OH/.openclaw/secrets/telegram-bot-token"
cat >"$OH/.openclaw/openclaw.json" <<JSON
{"gateway":{"mode":"local"},"channels":{"telegram":{"tokenFile":"$OH/.openclaw/secrets/telegram-bot-token","allowFrom":["telegram:1234567890","*"]}}}
JSON
printf '# AGENTS\n\nOpenClaw owner line: never touch prod.\n' >"$OH/.openclaw/workspace/AGENTS.md"
printf 'Soul: dry humour.\n' >"$OH/.openclaw/workspace/SOUL.md"
printf '# Memory\n\n## Billing\n\nInvoices go out on the 1st.\n\n## Infra\n\nThe VPN is wg0.\n' >"$OH/.openclaw/workspace/MEMORY.md"
printf '# 2026-11-17\n\nShipped the landing page.\n' >"$OH/.openclaw/workspace/memory/2026-11-17.md"
printf -- '---\nname: ocskill\n---\nOC.\n' >"$OH/.openclaw/workspace/skills/ocskill/SKILL.md"

jq '.agents.herm = {"type":"hermes","channels":"telegram","authProfile":"byods","isolation":"standard"}
  | .agents.ocl = {"type":"openclaw","channels":"telegram","isolation":"standard"}
  | .agents.oclx = {"type":"openclaw","channels":"telegram,discord","isolation":"standard"}' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
mkdir -p "$AUTH_PROFILES_DIR/byods"; printf 'DEEPSEEK_API_KEY=sk-ds\n' >"$AUTH_PROFILES_DIR/byods/combined.env"
# The box default holds a Claude plan sign-in (the profile layer's default path).
DEFAULT_CLAUDE_CRED="$TMP/default-claude-cred.json"; printf '{"claudeAiOauth":{"accessToken":"x"}}\n' >"$DEFAULT_CLAUDE_CRED"
TYPE_AUTH[claude]="$DEFAULT_CLAUDE_CRED"
# The source pollers: a recorded uninstall and a process table the stop must empty.
TYPE_BIN[hermes]="$TMP/hermes-bin"; printf '#!/bin/sh\necho "hermes $*" >>%s\n' "$TMP/gw" >"$TMP/hermes-bin"; chmod +x "$TMP/hermes-bin"
pkill() { printf 'pkill %s\n' "$*" >>"$TMP/gw"; [[ -f "$TMP/gw-stuck" ]] || rm -f "$TMP/gw-alive"; return 0; }
pgrep() { [[ -f "$TMP/gw-alive" ]]; }
sleep() { :; }
systemctl() { printf '%s\n' "$*" >>"$TMP/sysctl"
  case "$1" in is-active) [[ -f "$TMP/active" ]] ;; stop) rm -f "$TMP/active" ;; start) : >"$TMP/active"; [[ ! -f "$TMP/gw-alive" ]] || printf 'START-WHILE-POLLING\n' >>"$TMP/gw" ;; esac; return 0; }
FIVEDIVE_SELF=/bin/false
unset SUDO_USER; export SWITCH_SELF_CGROUP_FILE="$TMP/cg-outside"
hreset() { : >"$TMP/active"; : >"$TMP/gw-alive"; rm -f "$TMP/gw" "$TMP/sysctl" "$TMP/gw-stuck"; : >"$TMP/calls"; }

# ---- refusals first: each changes nothing
hreset; snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch herm --to=codex)
[[ "$rc" != 0 ]] && grep -q 'Claude Code only' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] && [[ -f "$TMP/active" ]] \
  && ok_t "H1 a Hermes agent moves to Claude Code only (codex is a later row): refused, nothing changed" \
  || bad_t "H1 hermes -> codex refused" "rc=$rc err=$(<"$TMP/err")"
TYPE_AUTH[claude]="$TMP/no-such-cred"
rc=$(run cmd_agent_switch herm --to=claude)
[[ "$rc" != 0 ]] && grep -q 'needs a Claude plan sign-in' "$TMP/err" && grep -q '5dive agent auth' "$TMP/err" \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && -f "$TMP/active" && ! -s "$TMP/gw" ]] \
  && ok_t "H2 no Claude plan sign-in on the box: refused, naming '5dive agent auth', before anything stops" \
  || bad_t "H2 no-claude pre-flight" "rc=$rc err=$(<"$TMP/err") gw=$(cat "$TMP/gw" 2>/dev/null)"
TYPE_AUTH[claude]="$DEFAULT_CLAUDE_CRED"
rc=$(run cmd_agent_switch oclx --to=claude)
[[ "$rc" != 0 ]] && grep -q 'discord channel' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "H3 a channel the move does not carry (discord) is refused up front" \
  || bad_t "H3 discord refused" "rc=$rc err=$(<"$TMP/err")"
hreset; touch "$TMP/gw-stuck"
rc=$(run cmd_agent_switch herm --to=claude)
[[ "$rc" != 0 ]] && grep -q 'would not stop' "$TMP/err" && grep -q '409' "$TMP/err" \
  && [[ "$(jq -r .agents.herm.type "$TMP/reg")" == hermes && ! -e "$HH/.claude/channels/telegram/.env" ]] \
  && ok_t "H4 a Hermes poller that will not die fails the switch before anything is converted (no double poll)" \
  || bad_t "H4 stuck gateway" "rc=$rc err=$(tail -3 "$TMP/err") type=$(jq -r .agents.herm.type "$TMP/reg")"

# ---- hermes -> claude
hreset
rc=$(run cmd_agent_switch herm --to=claude)
[[ "$rc" == 0 ]] || bad_t "H0 hermes -> claude must succeed" "rc=$rc err=$(tail -5 "$TMP/err") out=$(<"$TMP/out")"
[[ "$(jq -r .agents.herm.type "$TMP/reg")" == claude && "$(jq -r '.agents.herm.authProfile // "default"' "$TMP/reg")" == default ]] \
  && grep -q '^AGENT_TYPE=claude$' "$ENV_DIR/herm.env" \
  && ok_t "H5 the SAME agent is now Claude Code on the box's Claude plan (its DeepSeek key account is not kept)" \
  || bad_t "H5 registry/env" "$(jq -c .agents.herm "$TMP/reg") env=$(cat "$ENV_DIR/herm.env" 2>/dev/null)"
grep -q "^channel claude telegram herm $TOKEN_H  1234567890,555$" "$TMP/calls" \
  && [[ "$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$HH/.claude/channels/telegram/.env")" == "$TOKEN_H" ]] \
  && ok_t "H6 the claude bridge gets Hermes's OWN bot token and its allowlist (same bot answers)" \
  || bad_t "H6 token" "$(cat "$TMP/calls")"
grep -q '^hermes gateway uninstall$' "$TMP/gw" && ! grep -q 'START-WHILE-POLLING' "$TMP/gw" \
  && ok_t "H7 Hermes's own gateway is uninstalled and gone BEFORE the Claude unit starts (no Telegram 409)" \
  || bad_t "H7 gateway order" "$(cat "$TMP/gw" 2>/dev/null)"
HMEM="$HH/.claude/projects/-home-claude-projects/memory"
grep -lq 'staging DB is on port 5544' "$HMEM"/hermes-mem-*.md 2>/dev/null \
  && grep -lq 'Fridays only' "$HMEM"/hermes-mem-*.md && grep -lq 'type: user' "$HMEM"/hermes-user-*.md \
  && [[ $(ls "$HMEM"/hermes-mem-*.md | wc -l) == 2 ]] \
  && grep -q '5dive:hermes-memory:begin' "$HMEM/MEMORY.md" && grep -q 'hermes-mem-the-staging-db' "$HMEM/MEMORY.md" \
  && jq -e '.data.memory.added == 3 and .data.memory.direction == "hermes->claude"' "$TMP/out" >/dev/null \
  && ok_t "H8 each Hermes memory entry is a 5dive atom (USER.md typed user), indexed in MEMORY.md for memory search" \
  || bad_t "H8 memory" "$(ls "$HMEM" 2>&1) $(cat "$HMEM/MEMORY.md" 2>/dev/null) out=$(<"$TMP/out")"
grep -q 'Hermes owner line: always cite the source.' "$HH/.claude/CLAUDE.md" \
  && grep -q '5dive:carried-instructions:begin from=hermes' "$HH/.claude/CLAUDE.md" \
  && ! grep -q 'You are Hermes Agent' "$HH/.claude/CLAUDE.md" \
  && ok_t "H9 SOUL.md's owner text is in CLAUDE.md's carried block; Hermes's default SOUL text is not" \
  || bad_t "H9 instructions" "$(cat "$HH/.claude/CLAUDE.md" 2>/dev/null)"
[[ -f "$HH/.claude/skills/my-notes/SKILL.md" && ! -e "$HH/.claude/skills/arxiv" ]] \
  && jq -e '.data.copied == ["my-notes"] and (.data.dropped | index("1 built-in Hermes skills (Claude Code has its own)"))' "$TMP/out" >/dev/null \
  && ok_t "H10 the owner's Hermes skill is copied to ~/.claude/skills; Hermes's bundled ones are counted, not copied" \
  || bad_t "H10 skills" "$(ls "$HH/.claude/skills" 2>&1) out=$(<"$TMP/out")"
jq -e '.data.scheduledJobs == {carried:false, count:2} and .data.running == true' "$TMP/out" >/dev/null \
  && jq -e '.data.dropped | index("Hermes'"'"'s own scheduled jobs (2)")' "$TMP/out" >/dev/null \
  && ok_t "H11 the result lists Hermes's own scheduled jobs (2) as not carried (scheduledJobs.carried=false), and the seat is running" \
  || bad_t "H11 jobs note" "$(<"$TMP/out")"
[[ -f "$HH/.hermes/SOUL.md" && -f "$HH/.hermes/memories/MEMORY.md" && -f "$HH/.hermes/.env" ]] \
  && ok_t "H12 the Hermes side's files are kept as they were" || bad_t "H12 hermes side touched" ""

# Re-running the conversion is idempotent, and an edited entry replaces its atom.
printf 'The staging DB is on port 6000.\n§\nDeploys happen on Fridays only.\n' >"$HH/.hermes/memories/MEMORY.md"
printf -- '---\nname: owner-own\ndescription: "mine"\nmetadata:\n  type: user\n---\n\nmine\n' >"$HMEM/hermes-mem-owner-own.md"
counts=$(switch_harness_memory_to_atoms hermes "$HH" "$HMEM" "" 2>/dev/null)
[[ "$counts" == "1 0 1 2" ]] && ! grep -lq 'port 5544' "$HMEM"/hermes-mem-*.md && [[ -f "$HMEM/hermes-mem-owner-own.md" ]] \
  && [[ $(grep -c '5dive:hermes-memory:begin' "$HMEM/MEMORY.md") == 1 ]] \
  && ok_t "H13 a re-run rewrites only what changed, removes the stale atom, keeps an atom it did not write, one index block" \
  || bad_t "H13 idempotence" "counts=$counts $(ls "$HMEM")"

# ---- openclaw -> claude
hreset
rc=$(run cmd_agent_switch ocl --to=claude)
[[ "$rc" == 0 ]] || bad_t "O0 openclaw -> claude must succeed" "rc=$rc err=$(tail -5 "$TMP/err") out=$(<"$TMP/out")"
[[ "$(jq -r .agents.ocl.type "$TMP/reg")" == claude ]] \
  && grep -q "^channel claude telegram ocl $TOKEN_O  1234567890$" "$TMP/calls" \
  && [[ "$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$OH/.claude/channels/telegram/.env")" == "$TOKEN_O" ]] \
  && ok_t "O1 an OpenClaw seat is Claude Code with the SAME bot (token read through openclaw.json's tokenFile; 'telegram:' ids kept, '*' not)" \
  || bad_t "O1 openclaw token" "type=$(jq -r .agents.ocl.type "$TMP/reg") calls=$(cat "$TMP/calls")"
grep -q 'openclaw-gateway.service' "$TMP/sysctl" && grep -q 'pkill -u agent-ocl -f openclaw.*gateway' "$TMP/gw" \
  && ! grep -q 'START-WHILE-POLLING' "$TMP/gw" \
  && ok_t "O2 OpenClaw's own gateway (user unit and stray process) is down before Claude starts" \
  || bad_t "O2 openclaw gateway" "sysctl=$(cat "$TMP/sysctl") gw=$(cat "$TMP/gw" 2>/dev/null)"
OMEM="$OH/.claude/projects/-home-claude-projects/memory"
grep -lq 'Invoices go out on the 1st' "$OMEM"/openclaw-mem-billing-*.md 2>/dev/null \
  && grep -lq 'wg0' "$OMEM"/openclaw-mem-infra-*.md && grep -lq 'Shipped the landing page' "$OMEM"/openclaw-note-2026-11-17-*.md \
  && grep -q '5dive:openclaw-memory:begin' "$OMEM/MEMORY.md" \
  && ok_t "O3 OpenClaw's MEMORY.md sections and daily notes are atoms, indexed for memory search" \
  || bad_t "O3 openclaw memory" "$(ls "$OMEM" 2>&1)"
grep -q 'OpenClaw owner line: never touch prod.' "$OH/.claude/CLAUDE.md" && grep -q 'Soul: dry humour.' "$OH/.claude/CLAUDE.md" \
  && [[ -f "$OH/.claude/skills/ocskill/SKILL.md" ]] \
  && jq -e '(.data.dropped | index("OpenClaw'"'"'s own scheduled jobs")) and .data.scheduledJobs.carried == false' "$TMP/out" >/dev/null \
  && ok_t "O4 workspace AGENTS.md + SOUL.md are carried into CLAUDE.md, its skill is copied, and the jobs note is there" \
  || bad_t "O4 openclaw instructions/skills" "$(cat "$OH/.claude/CLAUDE.md" 2>/dev/null) out=$(<"$TMP/out")"

# Pure readers: the token ladder and a planted symlink.
P="$TMP/ocpure"; mkdir -p "$P/.openclaw"
printf '{\n  // edited by hand\n  "channels": {"telegram": {"botToken": "111:inline",}},\n}\n' >"$P/.openclaw/openclaw.json"
[[ "$(_switch_source_tg_token "$P" openclaw)" == "111:inline" ]] \
  && ok_t "O5 an inline botToken in a hand-edited (JSON5) openclaw.json is read" \
  || bad_t "O5 json5 token" "$(_switch_source_tg_token "$P" openclaw)"
printf '{}' >"$P/.openclaw/openclaw.json"; printf 'TELEGRAM_BOT_TOKEN="222:env"\n' >"$P/.openclaw/.env"
[[ "$(_switch_source_tg_token "$P" openclaw)" == "222:env" ]] \
  && ok_t "O6 OpenClaw's env fallback (~/.openclaw/.env TELEGRAM_BOT_TOKEN) is read" \
  || bad_t "O6 env token" "$(_switch_source_tg_token "$P" openclaw)"
printf 'TELEGRAM_BOT_TOKEN=333:root\n' >"$TMP/rootfile"; rm -f "$P/.openclaw/.env"; ln -s "$TMP/rootfile" "$P/.openclaw/.env"
[[ -z "$(_switch_source_tg_token "$P" openclaw)" ]] \
  && ok_t "O7 a symlinked credential file is refused (root never reads a file the seat points it at)" \
  || bad_t "O7 symlink followed" "$(_switch_source_tg_token "$P" openclaw)"

# =========================================================== K: --keep-model (DIVE-8675)
# An OpenClaw seat on DeepSeek (key in its sqlite auth store), one on OpenRouter
# (key in ~/.openclaw/.env, a Claude Code side left from before) and a Hermes
# seat on Kimi move with `--keep-model`: each answers on its OWN provider, key
# and model — the seat's account names the vendor's Anthropic-format base URL
# and the model — and the box needs no Claude plan sign-in for it.
mk_oc_seat() { # <name> <primary> [token]
  local h="$SWITCH_HOME_ROOT/agent-$1"
  mkdir -p "$h/.openclaw/state" "$h/.openclaw/workspace"
  jq -n --arg p "$2" --arg t "${3:-7000000009:AAkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk}" \
    '{gateway:{mode:"local"}, agents:{defaults:{model:{primary:$p}}}, channels:{telegram:{botToken:$t, allowFrom:["1234567890"]}}}' \
    >"$h/.openclaw/openclaw.json"
}
oc_db_key() { # <name> <provider> <key>
  python3 -I -c 'import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, value_json TEXT, updated_at_ms INTEGER)")
c.execute("INSERT INTO config_machine_state VALUES (?,?,3)", ("authProfiles.store", json.dumps({"version":1,"profiles":{"anthropic:x":{"type":"token","provider":"anthropic","token":"nope"}, sys.argv[2]+":manual":{"type":"api_key","provider":sys.argv[2],"key":sys.argv[3]}}})))
c.commit()' "$SWITCH_HOME_ROOT/agent-$1/.openclaw/state/openclaw.sqlite" "$2" "$3"
}
mk_oc_seat ocds deepseek/deepseek-v4-pro; oc_db_key ocds deepseek sk-ds-oc-keep-1234
mk_oc_seat ocor openrouter/deepseek/deepseek-v4.1-flash
printf 'OPENROUTER_API_KEY=sk-or-v1-keep-5678\n' >"$SWITCH_HOME_ROOT/agent-ocor/.openclaw/.env"
mkdir -p "$SWITCH_HOME_ROOT/agent-ocor/.claude"
printf '{"model":"claude-opus-5-5","theme":"dark"}\n' >"$SWITCH_HOME_ROOT/agent-ocor/.claude/settings.json"
mk_oc_seat ocoai openai/gpt-5.5; oc_db_key ocoai openai sk-openai-keep-9999
mk_oc_seat ocnokey deepseek/deepseek-v4-pro
KH="$SWITCH_HOME_ROOT/agent-hkimi"; mkdir -p "$KH/.hermes"
printf 'TELEGRAM_BOT_TOKEN=7000000010:AAkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk\nKIMI_API_KEY=sk-kimi-keep-4321\n' >"$KH/.hermes/.env"
printf 'model:\n  provider: kimi-coding   # set by 5dive\n  default: "kimi-k2.5"\nterminal:\n  default: bash\n' >"$KH/.hermes/config.yaml"
jq '.agents.ocds = {"type":"openclaw","channels":"telegram","isolation":"standard"}
  | .agents.ocor = {"type":"openclaw","channels":"telegram","isolation":"standard"}
  | .agents.ocoai = {"type":"openclaw","channels":"telegram","isolation":"standard"}
  | .agents.ocnokey = {"type":"openclaw","channels":"telegram","isolation":"standard"}
  | .agents.hkimi = {"type":"hermes","channels":"telegram","isolation":"standard"}' "$TMP/reg" >"$TMP/reg.t" && mv "$TMP/reg.t" "$TMP/reg"
penv() { sed -n "s/^$2=//p" "$AUTH_PROFILES_DIR/$1/combined.env" 2>/dev/null | tail -1; }
# No Claude plan on the box: --keep-model must not need one.
TYPE_AUTH[claude]="$TMP/no-such-cred"

# ---- refusals: each changes nothing
hreset; snap_reg=$(sha256sum <"$TMP/reg")
rc=$(run cmd_agent_switch ocoai --to=claude --keep-model)
[[ "$rc" != 0 ]] && grep -q 'OpenAI, which Claude Code cannot talk to' "$TMP/err" && grep -q 'without --keep-model' "$TMP/err" \
  && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && -f "$TMP/active" && ! -s "$TMP/gw" && ! -e "$AUTH_PROFILES_DIR/ocoai-openai" ]] \
  && ok_t "K1 an OpenClaw seat on plain OpenAI (no Anthropic-format endpoint) is refused with the way out, nothing changed" \
  || bad_t "K1 openai refused" "rc=$rc err=$(<"$TMP/err")"
rc=$(run cmd_agent_switch ocnokey --to=claude --keep-model)
[[ "$rc" != 0 ]] && grep -q 'found no DeepSeek key' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" && -f "$TMP/active" ]] \
  && ok_t "K2 a seat whose key cannot be found is refused before anything stops" \
  || bad_t "K2 no key" "rc=$rc err=$(<"$TMP/err")"
rc=$(run cmd_agent_switch ocds --to=claude --keep-model --account=claudeacct)
rc2=$(run cmd_agent_switch theo --to=codex --keep-model)
[[ "$rc" != 0 && "$rc2" != 0 ]] && grep -q 'Hermes or OpenClaw agent' "$TMP/err" && [[ "$(sha256sum <"$TMP/reg")" == "$snap_reg" ]] \
  && ok_t "K3 --keep-model with --account=, or on a Claude/Codex seat, is refused" \
  || bad_t "K3 flag misuse" "rc=$rc rc2=$rc2 err=$(<"$TMP/err")"

# ---- openclaw on DeepSeek, key in the sqlite store, first time on Claude Code
hreset
rc=$(run cmd_agent_switch ocds --to=claude --keep-model)
[[ "$rc" == 0 ]] || bad_t "K0 ocds keep-model must succeed" "rc=$rc err=$(tail -5 "$TMP/err") out=$(<"$TMP/out")"
[[ "$(jq -r .agents.ocds.type "$TMP/reg")" == claude && "$(jq -r .agents.ocds.authProfile "$TMP/reg")" == ocds-deepseek ]] \
  && grep -q '^AGENT_AUTH_PROFILE=ocds-deepseek$' "$ENV_DIR/ocds.env" \
  && [[ "$(readlink "$ENV_DIR/ocds-auth.env")" == "$AUTH_PROFILES_DIR/ocds-deepseek/combined.env" ]] \
  && ok_t "K4 the OpenClaw seat is Claude Code on its own account (ocds-deepseek), bound in the registry, env and unit link" \
  || bad_t "K4 registry/env" "$(jq -c .agents.ocds "$TMP/reg") env=$(cat "$ENV_DIR/ocds.env" 2>/dev/null)"
[[ "$(penv ocds-deepseek ANTHROPIC_BASE_URL)" == https://api.deepseek.com/anthropic \
   && "$(penv ocds-deepseek ANTHROPIC_AUTH_TOKEN)" == sk-ds-oc-keep-1234 \
   && "$(penv ocds-deepseek ANTHROPIC_DEFAULT_OPUS_MODEL)" == deepseek-v4-pro \
   && "$(penv ocds-deepseek ANTHROPIC_DEFAULT_SONNET_MODEL)" == deepseek-v4-pro \
   && -n "$(penv ocds-deepseek ANTHROPIC_DEFAULT_HAIKU_MODEL)" ]] \
  && grep -q '^CLAUDE_CODE_OAUTH_TOKEN=$' "$AUTH_PROFILES_DIR/ocds-deepseek/combined.env" \
  && grep -q '^preseed ocds telegram deepseek-v4-pro high$' "$TMP/calls" \
  && ok_t "K5 its env names DeepSeek's Anthropic-format URL, its own key and model deepseek-v4-pro; Claude Code starts on that model, not Opus" \
  || bad_t "K5 deepseek env" "$(cat "$AUTH_PROFILES_DIR/ocds-deepseek/combined.env" 2>&1) calls=$(cat "$TMP/calls")"
jq -e '.data.keptModel == {provider:"deepseek", model:"deepseek-v4-pro", baseUrl:"https://api.deepseek.com/anthropic"} and (.data.warning | test("own DeepSeek model")) and .data.running == true' "$TMP/out" >/dev/null \
  && ok_t "K6 the result names the kept provider, model and base URL, and the warning says 'own DeepSeek model', not 'your Claude plan'" \
  || bad_t "K6 result" "$(<"$TMP/out")"

# ---- openclaw on OpenRouter, key in ~/.openclaw/.env, seat ran Claude Code before
hreset
rc=$(run cmd_agent_switch ocor --to=claude --keep-model)
[[ "$rc" == 0 ]] \
  && [[ "$(penv ocor-openrouter ANTHROPIC_BASE_URL)" == https://openrouter.ai/api \
     && "$(penv ocor-openrouter ANTHROPIC_AUTH_TOKEN)" == sk-or-v1-keep-5678 \
     && "$(penv ocor-openrouter ANTHROPIC_DEFAULT_OPUS_MODEL)" == deepseek/deepseek-v4.1-flash \
     && "$(penv ocor-openrouter CLAUDE_CODE_MAX_OUTPUT_TOKENS)" == 16000 ]] \
  && jq -e '.model == "deepseek/deepseek-v4.1-flash" and .theme == "dark"' "$SWITCH_HOME_ROOT/agent-ocor/.claude/settings.json" >/dev/null \
  && ok_t "K7 OpenRouter: openclaw's 'openrouter/<slug>' becomes the slug; a settings.json left at claude-opus-5-5 is re-pinned (OpenRouter would serve real Opus), the rest kept" \
  || bad_t "K7 openrouter" "rc=$rc err=$(tail -3 "$TMP/err") env=$(cat "$AUTH_PROFILES_DIR/ocor-openrouter/combined.env" 2>&1) set=$(cat "$SWITCH_HOME_ROOT/agent-ocor/.claude/settings.json")"

# ---- hermes on Kimi (hermes renames kimi to kimi-coding; key in ~/.hermes/.env).
# It has NO Telegram allowlist: on the DIVE-8672 tree that alone ended the
# switch silently under pipefail, after its gateway was already stopped.
hreset
rc=$(run cmd_agent_switch hkimi --to=claude --keep-model)
[[ "$rc" == 0 && "$(jq -r .agents.hkimi.authProfile "$TMP/reg")" == hkimi-moonshot ]] \
  && [[ "$(penv hkimi-moonshot ANTHROPIC_BASE_URL)" == https://api.moonshot.ai/anthropic \
     && "$(penv hkimi-moonshot ANTHROPIC_AUTH_TOKEN)" == sk-kimi-keep-4321 \
     && "$(penv hkimi-moonshot ANTHROPIC_DEFAULT_OPUS_MODEL)" == kimi-k2.5 ]] \
  && grep -q '^hermes gateway uninstall$' "$TMP/gw" \
  && ok_t "K8 a Hermes seat on Kimi with no allowlist keeps Kimi: model.provider kimi-coding + KIMI_API_KEY -> Moonshot's Anthropic URL, model kimi-k2.5" \
  || bad_t "K8 hermes kimi" "rc=$rc out=$(<"$TMP/out") gw=$(cat "$TMP/gw" 2>&1) err=$(tail -3 "$TMP/err") env=$(cat "$AUTH_PROFILES_DIR/hkimi-moonshot/combined.env" 2>&1)"

# ---- the reader on its own: hermes credential pool, lowest priority wins, oauth skipped
P="$TMP/hpool"; mkdir -p "$P/.hermes"
printf 'model:\n  provider: deepseek\n  default: deepseek-v4-pro\n' >"$P/.hermes/config.yaml"
printf '{"credential_pool":{"deepseek":[{"access_token":"sk-second-xxxxxx","priority":1},{"access_token":"tok-oauth-xxxxxx","auth_type":"oauth","priority":0},{"access_token":"sk-first-xxxxxxx","priority":0}]}}\n' >"$P/.hermes/auth.json"
printf 'DEEPSEEK_API_KEY=sk-env-xxxxxxxx\n' >"$P/.hermes/.env"
switch_source_ai "$P" hermes
[[ "$SWITCH_SRC_PROVIDER/$SWITCH_SRC_MODEL/$SWITCH_SRC_KEY" == deepseek/deepseek-v4-pro/sk-first-xxxxxxx ]] \
  && ok_t "K9 Hermes's auth.json credential pool is read first (lowest priority, api-key entries only), before ~/.hermes/.env" \
  || bad_t "K9 hermes pool" "$SWITCH_SRC_PROVIDER/$SWITCH_SRC_MODEL/$SWITCH_SRC_KEY"
rm -f "$P/.hermes/auth.json"; ln -s "$TMP/hpool-root.json" "$P/.hermes/auth.json"
printf '{"credential_pool":{"deepseek":[{"access_token":"sk-ROOT-xxxxxxx"}]}}\n' >"$TMP/hpool-root.json"
switch_source_ai "$P" hermes
[[ "$SWITCH_SRC_KEY" == sk-env-xxxxxxxx ]] \
  && ok_t "K10 a symlinked auth.json is not followed (root reads only the seat's own files)" \
  || bad_t "K10 symlink" "$SWITCH_SRC_KEY"
TYPE_AUTH[claude]="$DEFAULT_CLAUDE_CRED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
