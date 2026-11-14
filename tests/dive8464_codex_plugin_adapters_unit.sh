#!/usr/bin/env bash
# DIVE-8464 — Teams and a plugin's own channel (email) on a Codex seat.
#
# The Codex dispatcher runs each as a channel adapter: 5dive-agent-start hands it
# CODEX_DISPATCHER_PLUGIN_ADAPTERS (channel -> absolute entry path, read from the
# plugin's manifest) and wires the plugin's own guard as a Codex PreToolUse hook.
#
#   P1-P3  the boot predicate (and its byte-identical delivery copy) selects the
#          dispatcher for teams and a plugin channel; never for none/discord/buzz
#   D1-D2  plugin_store_dir_for finds an ENABLED plugin's dir, nothing else
#   C1-C5  codex_adapter_add: the adapter path, the hook, a path that climbs out
#          is refused, a missing adapter is refused, a missing GUARD drops the channel
#   R1-R2  plugin_channel_runs_on codex needs harnesses:codex AND a codex_adapter
#   K1-K3  the hook stanza: added once, a restart adds nothing, a moved dir is
#          re-pointed in place
#   V1-V2  agent config / install refuse teams only off claude and codex
#
# Run: bash tests/dive8464_codex_plugin_adapters_unit.sh   (no root, no network)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP="$(mktemp -d /tmp/d8464.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
START=bin/5dive-agent-start
RT=src/cmd_agent_runtime.sh
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

fn_of() { sed -n "/^$1() {/,/^}/p" "$2"; }

# --- P ------------------------------------------------------------------------
eval "$(fn_of codex_dispatcher_enabled "$START")"
for ch in teams email telegram dashboard telegram,teams dashboard,email; do
  codex_dispatcher_enabled "$ch" && ok_t "P1 channels='$ch' selects the dispatcher" || bad_t "P1 channels='$ch'"
done
for ch in "" none discord buzz discord,buzz; do
  codex_dispatcher_enabled "$ch" && bad_t "P2 channels='$ch' must stay on the pane" || ok_t "P2 channels='$ch' stays on the pane"
done
b1=$(fn_of codex_dispatcher_enabled "$START" | sed 1d); b2=$(fn_of _codex_dispatcher_enabled "$RT" | sed 1d)
[[ -n "$b1" && "$b1" == "$b2" ]] && ok_t "P3 the delivery copy is byte-identical" || bad_t "P3 parity" "$b1 // $b2"

# --- fixtures -----------------------------------------------------------------
P="$TMP/plugins"; mkdir -p "$P/enabled"
fixture() { # fixture <key> <plugin> <enabled> <fivedive json>
  mkdir -p "$P/enabled/$1/.claude-plugin"
  jq -n --arg p "$2" --argjson f "$4" '{name:$p, version:"0.0.1", fivedive:$f}' >"$P/enabled/$1/.claude-plugin/plugin.json"
  local cur='{}'; [[ -s "$P/installed.json" ]] && cur=$(cat "$P/installed.json")
  jq --arg k "$1" --arg p "$2" --argjson e "$3" '.[$k] = {plugin:$p, marketplace:"m", enabled:$e, capabilities:["channel"]}' <<<"$cur" >"$P/installed.json"
}
fixture teams@m teams true '{"codex_adapter":"start.ts","codex_hook":"hooks/codex-role-guard.ts"}'
mkdir -p "$P/enabled/teams@m/hooks"; touch "$P/enabled/teams@m/start.ts" "$P/enabled/teams@m/hooks/codex-role-guard.ts"
fixture mail@m mail true '{"channel":{"name":"email","harnesses":["claude","codex"],"codex_adapter":"start.ts","codex_hook":"hooks/codex-mail-guard.ts"}}'
touch "$P/enabled/mail@m/start.ts"   # its guard is MISSING on purpose (C5)
fixture climb@m climb true '{"codex_adapter":"../teams@m/start.ts"}'
fixture noad@m noad true '{}'
fixture off@m off false '{"codex_adapter":"start.ts"}'; touch "$P/enabled/off@m/start.ts"

eval "$(fn_of plugin_store_dir_for "$START")"
eval "$(fn_of codex_adapter_add "$START")"
NAME=fixture
export FIVEDIVE_PLUGIN_STORE="$P"
REAL_HOME="$HOME"; export HOME="$TMP/home"; mkdir -p "$HOME"

# --- D ------------------------------------------------------------------------
[[ "$(plugin_store_dir_for teams)" == "$P/enabled/teams@m" ]] && ok_t "D1 the enabled teams plugin's dir" || bad_t "D1" "$(plugin_store_dir_for teams)"
plugin_store_dir_for off >/dev/null && bad_t "D2 a disabled plugin must not resolve" || ok_t "D2 a disabled plugin does not resolve"

# --- C ------------------------------------------------------------------------
CODEX_ADAPTERS_JSON='{}'; CODEX_ADAPTER_HOOKS=()
codex_adapter_add teams "$P/enabled/teams@m"; rc=$?
[[ $rc == 0 && "$(jq -r .teams <<<"$CODEX_ADAPTERS_JSON")" == "$HOME/.5dive/codex-adapters/teams/start.ts" \
   && -f "$HOME/.5dive/codex-adapters/teams/start.ts" ]] \
  && ok_t "C1 teams -> its adapter entry, in a copy the seat owns" || bad_t "C1" "rc=$rc $CODEX_ADAPTERS_JSON"
mkdir -p "$HOME/.5dive/codex-adapters/teams/node_modules/x"; touch "$P/enabled/teams@m/new.ts"
CODEX_ADAPTERS_JSON='{}'; CODEX_ADAPTER_HOOKS=()
codex_adapter_add teams "$P/enabled/teams@m"
[[ -d "$HOME/.5dive/codex-adapters/teams/node_modules/x" && -f "$HOME/.5dive/codex-adapters/teams/new.ts" ]] \
  && ok_t "C1b a restart refreshes the copy and keeps its node_modules" || bad_t "C1b refresh"
[[ "${CODEX_ADAPTER_HOOKS[*]}" == "teams=$P/enabled/teams@m/hooks/codex-role-guard.ts" ]] \
  && ok_t "C2 and its guard hook" || bad_t "C2" "${CODEX_ADAPTER_HOOKS[*]}"
codex_adapter_add climb "$P/enabled/climb@m" && bad_t "C3 a path out of the plugin must be refused" || ok_t "C3 a path out of the plugin is refused"
codex_adapter_add noad "$P/enabled/noad@m" && bad_t "C4 no adapter must be refused" || ok_t "C4 a plugin with no codex_adapter is refused"
codex_adapter_add email "$P/enabled/mail@m" 2>"$TMP/c5"; rc=$?
[[ $rc != 0 && "$(jq -r '.email // "absent"' <<<"$CODEX_ADAPTERS_JSON")" == absent && "$(cat "$TMP/c5")" == *"NOT started without it"* ]] \
  && ok_t "C5 a missing guard drops the channel and says so" || bad_t "C5" "rc=$rc $CODEX_ADAPTERS_JSON $(cat "$TMP/c5")"

# --- R ------------------------------------------------------------------------
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/plugin_channels.sh; do source "src/$f" 2>/dev/null; done
set +e
STATE_DIR="$TMP"
plugin_channel_runs_on email codex && plugin_channel_runs_on email claude \
  && ok_t "R1 email (harnesses claude+codex, codex_adapter) runs on both" || bad_t "R1"
fixture chatx@m chatx true '{"channel":{"name":"chatx","harnesses":["claude","codex"]}}'
plugin_channel_runs_on chatx codex && bad_t "R2 codex without a codex_adapter must be refused" || ok_t "R2 harnesses:codex alone is not enough"

# --- K: the hook stanza, run from agent-start's own block -----------------------
blk=$(awk '/# DIVE-8464: each adapter plugin.s own guard/{on=1} on{print} on&&/^  done$/{exit}' "$START")
if [[ -z "$blk" ]]; then bad_t "K1 hook block not found in $START"; else
  AGENT_CODEX_HOME="$TMP/codex"; mkdir -p "$AGENT_CODEX_HOME"; printf 'model = "x"\n' >"$AGENT_CODEX_HOME/config.toml"
  codex_ensure_feature() { :; }
  CODEX_ADAPTER_HOOKS=("email=/p/a/hooks/g.ts")
  eval "$blk"
  c=$(grep -c '^command = "bun /p/a/hooks/g.ts"$' "$AGENT_CODEX_HOME/config.toml")
  [[ $c == 1 ]] && grep -q '^\[\[hooks.PreToolUse.hooks\]\]$' "$AGENT_CODEX_HOME/config.toml" \
    && ok_t "K1 the guard is added as a PreToolUse hook" || bad_t "K1" "$(cat "$AGENT_CODEX_HOME/config.toml")"
  eval "$blk"
  [[ $(grep -c '5dive-codex-adapter-hook: email' "$AGENT_CODEX_HOME/config.toml") == 1 ]] \
    && ok_t "K2 a restart adds nothing" || bad_t "K2" "$(cat "$AGENT_CODEX_HOME/config.toml")"
  CODEX_ADAPTER_HOOKS=("email=/p/b/hooks/g.ts")
  eval "$blk"
  grep -q '^command = "bun /p/b/hooks/g.ts"$' "$AGENT_CODEX_HOME/config.toml" \
    && ! grep -q '/p/a/' "$AGENT_CODEX_HOME/config.toml" \
    && [[ $(grep -c '5dive-codex-adapter-hook: email' "$AGENT_CODEX_HOME/config.toml") == 1 ]] \
    && ok_t "K3 a moved plugin dir is re-pointed in place" || bad_t "K3" "$(cat "$AGENT_CODEX_HOME/config.toml")"
fi

# --- V ------------------------------------------------------------------------
grep -q '"$type" != "claude" && "$type" != "codex" ]] && channel_in_list teams' src/cmd_agent_config.sh \
  && ok_t "V1 agent config allows teams on codex" || bad_t "V1"
grep -q '"$plugin" == "teams" && "$type" != "claude" && "$type" != "codex"' src/lib/agent_setup.sh \
  && ok_t "V2 the channel installer allows teams on codex" || bad_t "V2"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
