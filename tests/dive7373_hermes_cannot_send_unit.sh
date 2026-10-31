#!/usr/bin/env bash
# DIVE-7373: a Hermes seat on Anthropic whose shared venv lacks the 'anthropic'
# package drops every message ("Your message was not sent"), while init said
# ready and `agent list` said AUTH ok / ready (QA round 2, 2026-10-31, 0.109.0).
#   1. the reading: hermes_sdk_state / hermes_missing_sdk (venv + seat provider)
#   2. seat_turn_trouble names it `cannot-send`; the operational state is degraded
#   3. agent list (the python snapshot) shows AUTH cannot-send, STATE degraded
#   4. agent ask fails before typing the question; a timed-out ask names it
#   5. the heal: create adds the package on a box that already had Hermes, and
#      the installer adds it on update; the recipe still runs the same step
# Run: bash tests/dive7373_hermes_cannot_send_unit.sh (no root, no network, ~3s)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1${2:+ — $2}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want '$2', got '$3'"; }

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/seat_refusal.sh \
         cmd_auth.sh cmd_agent_create.sh cmd_agent.sh cmd_agent_runtime.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

# Fixture: Hermes's tree, a seat home with the seat's own config.yaml.
H="$TMP/hermes-agent"; mkdir -p "$H/tools" "$H/venv/lib/python3.11/site-packages"
export HERMES_AGENT_DIR="$H" AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$TMP/home/agent-qa7373/.hermes"
seat_cfg() { printf 'model:\n  default: claude-haiku-5-5\n  provider: %s\n  base_url: ""\nterminal:\n  provider: x\n' "$1" > "$TMP/home/agent-qa7373/.hermes/config.yaml"; }
seat_cfg anthropic
TYPE=hermes; agent_type() { echo "$TYPE"; }
seat_started_epoch() { echo 0; }
_seat_recent_records() { return 1; }   # no transcript: only the venv reading speaks
sdk_on()  { mkdir -p "$H/venv/lib/python3.11/site-packages/anthropic"; : > "$H/venv/lib/python3.11/site-packages/anthropic/__init__.py"; }
sdk_off() { rm -rf "$H/venv/lib/python3.11/site-packages/anthropic"; }

# --- 1. the reading -----------------------------------------------------------
eq_t "1a a venv without the package reads missing" missing "$(hermes_sdk_state)"
sdk_on;  eq_t "1b with it, present" present "$(hermes_sdk_state)"; sdk_off
HERMES_AGENT_DIR="$TMP/nope" eq_t "1c no Hermes here is unknown, not missing" unknown "$(HERMES_AGENT_DIR="$TMP/nope" hermes_sdk_state)"
eq_t "1d a Hermes seat on anthropic without it: missing anthropic" anthropic "$(hermes_missing_sdk qa7373)"
seat_cfg openrouter; hermes_missing_sdk qa7373 >/dev/null; eq_t "1e control: a seat on another provider is not flagged" 1 "$?"
seat_cfg anthropic
TYPE=claude; hermes_missing_sdk qa7373 >/dev/null; eq_t "1f control: a non-Hermes seat is not flagged" 1 "$?"; TYPE=hermes
sdk_on; hermes_missing_sdk qa7373 >/dev/null; eq_t "1g control: with the package installed, not flagged" 1 "$?"; sdk_off

# --- 2. seat_turn_trouble + operational state ----------------------------------
t=$(seat_turn_trouble qa7373 0)
eq_t "2a seat_turn_trouble names the kind cannot-send" cannot-send "${t%%$'\t'*}"
[[ "${t#*$'\t'}" == *"'anthropic' package"*"sudo 5dive agent install hermes --upgrade"* ]] \
  && ok_t "2b and says what is missing and the one command that fixes it" || bad_t "2b" "$t"
AH=$(agent_auth_health hermes "" qa7373)
eq_t "2c agent_auth_health (agent info) reads cannot-send, not ok" cannot-send "${AH%%|*}"
eq_t "2d its operational verdict is degraded, not ready" degraded "$(_agent_operational_state active cannot-send clear)"
grep -q 'cannot-send' <(awk '/DIVE-7118 account-refusal hold/,/^    fi$/' src/cmd_heartbeat.sh) \
  && ok_t "2e the heartbeat holds dispatch to a cannot-send seat" || bad_t "2e heartbeat hold does not name cannot-send"

# --- 3. agent list snapshot -----------------------------------------------------
PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/ { emit=1; next } /^# __5DIVE_AGENT_LIST_PY_END__$/ { exit } emit { print }' src/cmd_agent.sh > "$PY"
mkdir -p "$TMP/profiles" "$TMP/sudoers" "$TMP/connectors"
printf '%s\n' '{"agents":{"qa7373":{"type":"hermes","channels":"none","workdir":"/work","isolation":"sandboxed","heartbeat":{"enabled":false},"createdAt":"2026-10-31T05:00:04Z"}}}' > "$TMP/agents.json"
snap() { python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$TMP/home" "$TMP/sudoers" /default 2>/dev/null; }
OUT=$(snap)
eq_t "3a agent list shows AUTH cannot-send" cannot-send "$(jq -r '.[0].health.auth.state' <<<"$OUT")"
[[ "$(jq -r '.[0].health.auth.refusal' <<<"$OUT")" == *"install hermes --upgrade"* ]] \
  && ok_t "3b with the fix in the reason" || bad_t "3b" "$(jq -c '.[0].health.auth' <<<"$OUT")"
sdk_on
eq_t "3c control: with the package installed the seat is not cannot-send" "" "$(snap | jq -r '.[0].health.auth.state | select(. == "cannot-send")')"
sdk_off

# --- 4. agent ask ----------------------------------------------------------------
# The pane main's QA box showed (qainit-hermes2-panes.txt).
P="$TMP/pane"
printf '%s\n' "> [5dive id=abc123] reply with the word ok" "Initializing agent..." \
  "Hermes couldn't start the model connection: The 'anthropic' package is required " \
  "for the Anthropic provider. Install it with: pip install 'anthropic>=0.39.0'. " \
  "Your message was not sent. Run \`hermes doctor\` to check the setup, or /model to " > "$P"
sdk_on   # pane arm alone: the venv reading is quiet
d=$(_ask_timeout_diag abc123 "$P" 1 0)
[[ "$d" == *"NEVER SENT"*"couldn't start the model connection"* ]] \
  && ok_t "4a a timed-out ask names a question the seat never sent" || bad_t "4a" "$d"
[[ "$d" != *"reply-format"* && "$d" != *"REFUSED"* ]] \
  && ok_t "4b and not as a reply-format or credit problem" || bad_t "4b" "$d"
sdk_off
d=$(_ask_timeout_diag abc123 /dev/null 1 0 qa7373)
[[ "$d" == *"NEVER SENT"*"install hermes --upgrade"* ]] \
  && ok_t "4c with the seat named, the venv reading gives the fix" || bad_t "4c" "$d"
printf '> [5dive id=abc123] hi\n' > "$P"
d=$(_ask_timeout_diag abc123 "$P" 0 0)
[[ "$d" != *"NEVER SENT"* ]] && ok_t "4d control: a plain delivered pane keeps the old verdict" || bad_t "4d" "$d"
blk=$(awk '/DIVE-7373: a Hermes seat whose provider package/,/^  fi$/' src/cmd_agent_runtime.sh)
[[ "$blk" == *'hermes_missing_sdk "$name"'*'fail "$E_NOT_INSTALLED"'* ]] \
  && ok_t "4e ask fails before typing the question to a cannot-send seat" || bad_t "4e" "$blk"
n_blk=$(grep -n 'DIVE-7373: a Hermes seat whose provider package' src/cmd_agent_runtime.sh | cut -d: -f1)
n_cap=$(grep -n 'tmux capture-pane -t "agent-${name}" -p 2>/dev/null > "$baseline_file"' src/cmd_agent_runtime.sh | head -1 | cut -d: -f1)
(( n_blk > 0 && n_cap > n_blk )) && ok_t "4f ...and that check sits before the pane is touched" || bad_t "4f" "check@$n_blk capture@$n_cap"

# --- 5. the heal -----------------------------------------------------------------
[[ "${TYPE_INSTALL[hermes]}" == *"$HERMES_SDK_STEP"* && "$HERMES_SDK_STEP" == *'ensure("provider.anthropic", prompt=False)'* ]] \
  && ok_t "5a the recipe runs the shared SDK step" || bad_t "5a" "${TYPE_INSTALL[hermes]}"
bash -n -c "${TYPE_INSTALL[hermes]}" && ok_t "5b the recipe parses" || bad_t "5b recipe does not parse"
cblk=$(awk '/DIVE-7373: Hermes was already here/,/^  fi$/' src/cmd_agent_create.sh)
[[ "$cblk" == *'"$(hermes_sdk_state)" == missing'*'sudo -u claude -i bash -lc "$HERMES_SDK_STEP"'* ]] \
  && ok_t "5c create adds the package when Hermes was already installed without it" || bad_t "5c" "$cblk"
# Run the create block on the stub tree: missing -> the step runs as claude; present -> nothing.
sudo() { printf 'SUDO %s\n' "$*"; }
step() { :; }
code=$(sed -n '/^  if \[\[ "\$type" == hermes && /,/^  fi$/p' src/cmd_agent_create.sh)
out=$(type=hermes; eval "$code" 2>&1)
[[ "$out" == "SUDO -u claude -i bash -lc "*"provider.anthropic"* ]] && ok_t "5d create on a box without it runs the step" || bad_t "5d" "$out"
sdk_on; out=$(type=hermes; eval "$code" 2>&1)
eq_t "5e control: with the package there, create runs nothing" "" "$out"
out=$(type=claude; sdk_off; eval "$code" 2>&1)
eq_t "5f control: another type runs nothing" "" "$out"
unset -f sudo
iblk=$(awk '/DIVE-7373: a box that installed Hermes before/,/^  fi$/' install.sh)
[[ "$iblk" == *'compgen -G "$_hsdk/venv/lib/python3*/site-packages/anthropic/__init__.py"'*'sudo -u claude -H bash -lc'*'provider.anthropic'* ]] \
  && ok_t "5g the installer adds the package on update when it is missing" || bad_t "5g" "$iblk"
bash -n install.sh && ok_t "5h install.sh parses" || bad_t "5h install.sh does not parse"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
