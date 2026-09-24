#!/usr/bin/env bash
# DIVE-4936 — the Claude Code mod is seated on new Claude seats on OUR box only,
# behind a box switch (`5dive config mod-seat=on`) that defaults OFF, and
# `doctor --category=mod` reads a real per-seat load without touching the seat's
# channels.
#
# WHAT IS STUBBED AND WHAT IS NOT. Two privilege drops: `plugin_seat_run_as` (the
# per-seat `claude plugin install`, simulated by writing the seat's
# installed_plugins.json as plugin_seat_registration_unit.sh does) and
# `mod_seat_probe_run` (the `claude -p /cost --debug-file` load probe, simulated
# by writing the engine's debug line — AND the needs-auth cache the first version
# of the real probe wrote, so the restore is graded on every call). The switch,
# the env writer, the seat enumeration, the doctor lines and the box-config key
# run for real against a temp tree.
#
# THE TWO THINGS GRADED HARDEST: (1) switch OFF means NOTHING happens — no seat is
# probed, nothing is written — because that is the state of every box but ours;
# (2) a probe leaves the seat's needs-auth cache exactly as it found it, because
# the first probe left telegram deaf on two live seats for 15 minutes.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
export GH_ORG=5dive-ai

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/lib/agent_setup.sh
# shellcheck source=/dev/null
source src/lib/plugin_seats.sh
# shellcheck source=/dev/null
source src/lib/mod_seat.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
set +e -o pipefail

require_root() { :; }
# doctor's own writer, extracted by name from the shipping file.
eval "$(sed -n '/^doctor_add() {/,/^}/p' src/cmd_doctor.sh)"
step() { :; }
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
export PERSONA_HOME_ROOT="$TMP/home"
export BOX_CONFIG="$TMP/box.json"
mkdir -p "$PERSONA_HOME_ROOT"
_plugin_ensure_store
jq -n '{"5dive-plugins":{source:"https://github.com/5dive-ai/5dive-plugins.git",kind:"git",ref:"",added_at:"t"}}' > "$(_plugin_mkt_json)"

registry_read() {
  jq -n '{agents:{ceo:{type:"claude"}, devops:{type:"claude"}, researcher:{type:"codex"}, ghost:{type:"claude"}}}'
}
seat_settings() { printf '%s/agent-%s/.claude/settings.json' "$PERSONA_HOME_ROOT" "$1"; }
for s in ceo devops researcher; do mkdir -p "$PERSONA_HOME_ROOT/agent-$s/.claude"; done
for s in ceo devops; do
  jq -n '{model:"claude-opus-5-5", env:{KEEP:"me"}, enabledPlugins:{"telegram@5dive-plugins":true}}' > "$(seat_settings "$s")"
  chmod 600 "$(seat_settings "$s")"
done

REG_CALLS="$TMP/reg-calls"; : > "$REG_CALLS"
plugin_seat_run_as() {
  local user="$1"; shift
  local var plugin="" mkt=""
  for var in "$@"; do
    case "$var" in PLUGIN=*) plugin="${var#PLUGIN=}" ;; MARKETPLACE=*) mkt="${var#MARKETPLACE=}" ;; esac
  done
  cat >/dev/null
  printf '%s %s@%s\n' "$user" "$plugin" "$mkt" >> "$REG_CALLS"
  local f="$PERSONA_HOME_ROOT/${user}/.claude/plugins/installed_plugins.json" tmpf
  mkdir -p "$(dirname "$f")"; [[ -f "$f" ]] || echo '{"plugins":{}}' > "$f"
  tmpf=$(mktemp); jq --arg k "${plugin}@${mkt}" '.plugins[$k] = [{installPath:"x"}]' "$f" > "$tmpf" && mv "$tmpf" "$f"
}
nreg() { grep -c . "$REG_CALLS"; return 0; }

PROBE=loaded; PROBES="$TMP/probes"; : > "$PROBES"
mod_seat_probe_run() {
  echo "$1" >> "$PROBES"
  case "$PROBE" in
    loaded)  echo "2026-09-24T00:00:00Z [DEBUG] hooks module mod@5dive-plugins loaded (worker, environment 2, tier user); events: tool.call" > "$2" ;;
    refused) echo "2026-09-24T00:00:00Z [ERROR] hooks module mod@5dive-plugins failed to load: register.ts does not parse" > "$2" ;;
    silent)  echo "2026-09-24T00:00:00Z [DEBUG] started" > "$2" ;;
    none)    : ;;
  esac
  # What the first real probe did to live seats: a channel server that cannot
  # auth writes the needs-auth cache. Simulated on every call.
  echo '{"plugin:telegram:telegram":{"timestamp":1}}' > "$PERSONA_HOME_ROOT/agent-${1}/.claude/mcp-needs-auth-cache.json"
}
nprobe() { grep -c . "$PROBES"; return 0; }

# ---------------------------------------------------------------------------
echo "== T1 the switch defaults OFF =="
rm -f "$BOX_CONFIG"
t "T1a no box.json: off"            "off" "$(mod_seat_enabled && echo on || echo off)"
echo '{"verify":"never"}' > "$BOX_CONFIG"
t "T1b box.json without the key: off" "off" "$(mod_seat_enabled && echo on || echo off)"
echo '{"mod_seat":"ON"}' > "$BOX_CONFIG"
t "T1c anything but an exact on: off" "off" "$(mod_seat_enabled && echo on || echo off)"
echo '{"mod_seat":"on"}' > "$BOX_CONFIG"
t "T1d on"                           "on"  "$(mod_seat_enabled && echo on || echo off)"

echo "== T2 the env a seated seat gets: the hooks flag, and nothing else =="
t "T2a first write moves the file" "changed" "$(mod_seat_env_apply ceo)"
S=$(cat "$(seat_settings ceo)")
t "T2b the hooks flag is set"         "1"    "$(jq -r '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS' <<<"$S")"
t "T2c no policy pointer: the full guard.json runs" "null" "$(jq -r '.env.FIVEDIVE_MOD_GUARD_POLICY' <<<"$S")"
t "T2d no other mod capability is switched on" "0" "$(jq '[.env | keys[] | select(startswith("FIVEDIVE_MOD_"))] | length' <<<"$S")"
t "T2e the seat's own env survives"   "me"   "$(jq -r '.env.KEEP' <<<"$S")"
t "T2f and so does the rest of the file" "true" "$(jq -r '.enabledPlugins["telegram@5dive-plugins"]' <<<"$S")"
t "T2g mode stays 600"                "600"  "$(stat -c %a "$(seat_settings ceo)")"
b1=$(sha256sum "$(seat_settings ceo)")
t "T2h a second write is a no-op"     "unchanged" "$(mod_seat_env_apply ceo)"
t "T2i and writes no byte"            "$b1" "$(sha256sum "$(seat_settings ceo)")"
jq '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS = "0"' "$(seat_settings devops)" > "$TMP/x" && mv "$TMP/x" "$(seat_settings devops)"
mod_seat_env_apply devops >/dev/null
t "T2j an owner's explicit 0 is kept" "0" "$(jq -r '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS' "$(seat_settings devops)")"
jq 'del(.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS)' "$(seat_settings devops)" > "$TMP/x" && mv "$TMP/x" "$(seat_settings devops)"
t "T2k a seat with no settings.json is a failure, not a silent pass" "fail" \
  "$(mod_seat_env_apply researcher >/dev/null 2>&1 && echo ok || echo fail)"

echo "== T3 seating one seat, and a second pass changes nothing =="
: > "$REG_CALLS"
mod_seat_ensure devops; rc=$?
t  "T3a seated"                  "0" "$rc"
t  "T3b registered once"         "1" "$(nreg)"
tc "T3c through the box's marketplace" "agent-devops mod@5dive-plugins" "$(cat "$REG_CALLS")"
t  "T3d with the hooks flag"     "1" "$(jq -r '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS' "$(seat_settings devops)")"
h1=$(cat "$(seat_settings devops)" "$PERSONA_HOME_ROOT/agent-devops/.claude/plugins/installed_plugins.json" | sha256sum)
mod_seat_ensure devops
t  "T3e a seated seat is not re-registered" "1" "$(nreg)"
t  "T3f and neither fingerprinted file moves" "$h1" \
  "$(cat "$(seat_settings devops)" "$PERSONA_HOME_ROOT/agent-devops/.claude/plugins/installed_plugins.json" | sha256sum)"

echo "== T4 the load check reads a real load and leaves the seat's channels alone =="
mod_seat_ensure ceo >/dev/null
CACHE="$PERSONA_HOME_ROOT/agent-ceo/.claude/mcp-needs-auth-cache.json"; rm -f "$CACHE"
PROBE=loaded
t  "T4a loaded" "loaded" "$(mod_seat_probe ceo)"
t  "T4b a probe never LEAVES a needs-auth cache the seat did not have" "absent" "$([[ -f "$CACHE" ]] && echo present || echo absent)"
echo '{"theirs":1}' > "$CACHE"; mod_seat_probe ceo >/dev/null
t  "T4c a cache the seat already had is restored byte for byte" '{"theirs":1}' "$(cat "$CACHE")"
rm -f "$CACHE"
t  "T4d the probe starts NO MCP server" "yes" \
  "$(grep -q -- '--strict-mcp-config --mcp-config "{\\"mcpServers\\":{}}"' src/lib/mod_seat.sh && echo yes || echo no)"
t  "T4e and never reads the loop's stdin" "yes" \
  "$(sed -n '/^mod_seat_probe_run()/,/^}/p' src/lib/mod_seat.sh | grep -q '</dev/null >/dev/null' && echo yes || echo no)"
PROBE=refused; r=$(mod_seat_probe ceo)
tc "T4f a module the engine refuses is NOT loaded" "not-loaded" "$r"
tc "T4g and carries the engine's own words" "does not parse" "$r"
PROBE=silent; jq '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS = "0"' "$(seat_settings ceo)" > "$TMP/x" && mv "$TMP/x" "$(seat_settings ceo)"
tc "T4h the hooks flag is named when it is the missing gate" "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is not 1" "$(mod_seat_probe ceo)"
jq '.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS = "1"' "$(seat_settings ceo)" > "$TMP/x" && mv "$TMP/x" "$(seat_settings ceo)"
mv "$PERSONA_HOME_ROOT/agent-ceo/.claude/plugins/installed_plugins.json" "$TMP/ip.bak"
tc "T4i an uninstalled plugin is named before anything else" "not installed for this seat" "$(mod_seat_probe ceo)"
mv "$TMP/ip.bak" "$PERSONA_HOME_ROOT/agent-ceo/.claude/plugins/installed_plugins.json"
PROBE=none
tc "T4j a probe that never started claude says so" "no debug log" "$(mod_seat_probe ceo)"
rm -f "$CACHE"

echo "== T5 doctor: switch OFF probes nothing; ON is an error per unloaded seat =="
: > "$PROBES"; DOCTOR_CHECKS='[]'; rm -f "$BOX_CONFIG"; PROBE=refused
doctor_check_mod_seats >/dev/null 2>&1
t  "T5a off: one ok line"           "ok" "$(jq -r '[.[] | .severity] | join(" ")' <<<"$DOCTOR_CHECKS")"
tc "T5b that says how to turn it on" "mod-seat=on" "$(jq -r '.[0].message' <<<"$DOCTOR_CHECKS")"
t  "T5c off: NO seat is probed"      "0" "$(nprobe)"
echo '{"mod_seat":"on"}' > "$BOX_CONFIG"; DOCTOR_CHECKS='[]'
doctor_check_mod_seats >/dev/null 2>&1
t  "T5d on: an unloaded seat is an error, one line per claude seat with a home" "error error" "$(jq -r '[.[] | .severity] | join(" ")' <<<"$DOCTOR_CHECKS")"
t  "T5e codex and homeless rows are never probed" "ceo devops" "$(paste -sd' ' "$PROBES")"
DOCTOR_CHECKS='[]'; PROBE=loaded; doctor_check_mod_seats >/dev/null 2>&1
t  "T5f on: loaded seats read ok" "ok ok" "$(jq -r '[.[] | .severity] | join(" ")' <<<"$DOCTOR_CHECKS")"
t  "T5g and no probe left a cache behind" "0" "$(ls "$PERSONA_HOME_ROOT"/agent-*/.claude/mcp-needs-auth-cache.json 2>/dev/null | grep -c .)"

echo "== T6 the wiring, and what this row must NOT change =="
ci=$(grep -n 'mod_seat_ensure "\$name"' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
si=$(grep -n 'systemctl enable --now "5dive-agent@' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
t  "T6a create seats the mod BEFORE the unit starts" "yes" "$([[ -n "$ci" && -n "$si" && "$ci" -lt "$si" ]] && echo yes || echo no)"
t  "T6b and only behind the switch" "yes" \
  "$(grep -q 'if \[\[ "\$type" == claude \]\] && declare -F mod_seat_enabled >/dev/null 2>&1 && mod_seat_enabled; then' src/cmd_agent_create.sh && echo yes || echo no)"
t  "T6c the walker's capability list is untouched (plugin add on every box)" "yes" \
  "$(grep -q '^PLUGIN_SEAT_CAPS="${PLUGIN_SEAT_CAPS:-skill mcp}"' src/lib/plugin_seats.sh && echo yes || echo no)"
t  "T6d the upgrade backfills no seat" "0" "$(grep -c 'mod_seat\|_seat_mod' install.sh)"
t  "T6e doctor's mod probe is opt-in, never on the dashboard's bare poll" "yes" \
  "$(grep -q '\[\[ "\$filter" == "mod" \]\] && run_mod=1' src/cmd_doctor.sh && echo yes || echo no)"
t  "T6f the lib is in the bundle" "yes" "$(grep -q '^  src/lib/mod_seat.sh$' build.sh && echo yes || echo no)"

echo "== T7 the box setting =="
# shellcheck source=/dev/null
source src/lib/verify_policy.sh 2>/dev/null
# shellcheck source=/dev/null
source src/cmd_box_config.sh
set +e
rm -f "$BOX_CONFIG"
( JSON_MODE=0 cmd_box_config mod-seat=on ) >/dev/null 2>&1
t  "T7a mod-seat=on is stored as .mod_seat" "on" "$(jq -r '.mod_seat' "$BOX_CONFIG" 2>/dev/null)"
t  "T7b and the switch reads it" "on" "$(mod_seat_enabled && echo on || echo off)"
( JSON_MODE=0 cmd_box_config mod-seat=default ) >/dev/null 2>&1
t  "T7c default clears it (= off)" "null off" "$(jq -r '.mod_seat' "$BOX_CONFIG") $(mod_seat_enabled && echo on || echo off)"
( JSON_MODE=0 cmd_box_config mod-seat=yes ) >/dev/null 2>&1; rc=$?
t  "T7d anything else is refused" "refused" "$( (( rc != 0 )) && echo refused || echo accepted)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
