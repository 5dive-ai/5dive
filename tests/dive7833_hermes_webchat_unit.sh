#!/bin/bash
# DIVE-7833: the hermes web chat. init-smoke run 42269208312 (hermes x2,
# 24.04) had the plugin linked and FIVEDIVE_* in ~/.hermes/.env, yet the
# gateway said "No messaging platforms enabled": the start script's content
# seed copies the account's config.yaml over the seat's on every boot, which
# dropped `plugins.enabled: [fivedive]`. The seat now re-enables it after the
# seed. Driven with the start script's own function and a fake hermes.
#
# Pure: no root, no systemd, no network. Run: bash tests/dive7833_hermes_webchat_unit.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

START=bin/5dive-agent-start
fn=$(sed -n '/^hermes_fivedive_reenable() {/,/^}/p' "$START")
[[ -n "$fn" ]] && ok_t "the start script has hermes_fivedive_reenable" || bad_t "hermes_fivedive_reenable is missing"

# A fake hermes: `plugins enable fivedive` writes the line the real one writes.
cat > "$TMP/hermes" <<'FAKE'
#!/bin/bash
echo "$*" >> "$REC"
if [[ "$1 $2 $3" == "plugins enable fivedive" ]]; then
  printf 'plugins:\n  enabled:\n    - fivedive\n' >> "$HOME/.hermes/config.yaml"
fi
exit 0
FAKE
chmod +x "$TMP/hermes"

# The seeded config, as the account's copy of cli-config.yaml.example has it:
# a plugins block with no enabled list.
SEEDED=$'model:\n  default: x\nplugins:\n  # Deadline for each Git clone\n  clone_timeout_seconds: 300\n\n# ===\nterminal:\n  backend: local\n'

# run <channels> <linked 0|1> <config text> -> prints the fake's argv log
run() {
  local h="$TMP/h$RANDOM"; mkdir -p "$h/.hermes/plugins"
  (( $2 )) && mkdir "$h/.hermes/plugins/fivedive"
  printf '%s' "$3" > "$h/.hermes/config.yaml"
  : > "$h/rec"
  HOME="$h" REC="$h/rec" CHANNELS="$1" BIN="$TMP/hermes" bash -c "$fn"$'\nhermes_fivedive_reenable' >/dev/null 2>&1
  echo "rc=$? $(tr '\n' ';' < "$h/rec")"
}

out=$(run dashboard 1 "$SEEDED")
[[ "$out" == "rc=0 plugins enable fivedive --no-allow-tool-override;" ]] \
  && ok_t "chat on, seed dropped the line: the seat re-enables fivedive once" || bad_t "chat on, seed dropped the line: got '$out'"
out=$(run telegram,dashboard 1 "$SEEDED")
[[ "$out" == *"plugins enable fivedive"* ]] && ok_t "dashboard among other channels re-enables too" || bad_t "dashboard among channels: got '$out'"
out=$(run dashboard 1 $'plugins:\n  enabled:\n    - fivedive\n  disabled: []\n')
[[ "$out" == "rc=0 " ]] && ok_t "already enabled: hermes is not run (no python start on every boot)" || bad_t "already enabled: got '$out'"
out=$(run telegram 1 "$SEEDED")
[[ "$out" == "rc=0 " ]] && ok_t "chat off: nothing enabled" || bad_t "chat off: got '$out'"
out=$(run dashboard 0 "$SEEDED")
[[ "$out" == "rc=0 " ]] && ok_t "plugin not linked: nothing enabled" || bad_t "not linked: got '$out'"
# A fivedive line somewhere else (a comment, another list) is not plugins.enabled.
out=$(run dashboard 1 $'plugins:\n  clone_timeout_seconds: 300\ntoolsets:\n  - fivedive\n')
[[ "$out" == *"plugins enable fivedive"* ]] && ok_t "a fivedive line outside plugins: does not count" || bad_t "outside plugins: got '$out'"

# Order: after the config.yaml seed, before the gateway is (re)started.
seed=$(grep -n '^  seed_one config.yaml content' "$START" | cut -d: -f1)
call=$(grep -n '^  hermes_fivedive_reenable || true' "$START" | cut -d: -f1)
rest=$(grep -n 'gateway restart >&2 2>&1' "$START" | head -1 | cut -d: -f1)
fallback=$(grep -n '"\$BIN" gateway run </dev/null' "$START" | head -1 | cut -d: -f1)
if [[ -n "$seed" && -n "$call" && -n "$rest" && -n "$fallback" ]] && (( seed < call && call < rest && call < fallback )); then
  ok_t "re-enable runs after the seed ($seed) and before both gateway starts ($rest, $fallback)"
else
  bad_t "order: seed=$seed call=$call restart=$rest fallback=$fallback"
fi

# The nightly init-smoke grades the hermes web chat again.
SM=scripts/init-smoke.sh
wc=$(bash -c "source <(sed -n '/^cell_type()/p;/^cell_has_webchat()/p' $SM); for c in hermes-standard hermes-sandboxed; do cell_has_webchat \$c && echo -n y || echo -n n; done")
[[ "$wc" == yy ]] && ok_t "init-smoke grades the web chat on both hermes cells" || bad_t "init-smoke hermes web chat: $wc"
grep -q 'webchat: not graded on hermes' "$SM" && bad_t "init-smoke still skips the hermes web chat" || ok_t "no 'not graded' skip line left"

# Run 42271431924: all four hermes cells answered the web chat, first with
# Hermes' "needs your OK ... Reply /approve" (the gateway keeps approvals,
# DIVE-7592). The arm answers /approve in the chat, as the owner would.
arm=$(sed -n '/^webchat_arm() {/,/^}/p' "$SM")
[[ "$arm" == *'drop_inbox "$inbox" "/approve"'* && "$arm" == *'approvals < 2'* ]] \
  && ok_t "the web chat arm answers an approval prompt in the chat, at most twice" || bad_t "the web chat arm does not answer /approve"
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
