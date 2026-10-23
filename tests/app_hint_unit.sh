#!/usr/bin/env bash
# DIVE-6781: the open-source install tells its users the phone app exists. One
# block (cmd_app_hint), printed at the end of install.sh and of `5dive init`,
# silent on a 5dive-built box and on a box whose connector is already linked.
# The README carries the same two commands, so the three never drift apart.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

# shellcheck disable=SC1091
source src/cmd_init.sh

install_cmd='curl -4 -sSL https://api.5dive.com/connector/install.sh | sudo bash'
connect_cmd='sudo 5dive-connector connect'

export APP_HINT_PROVISIONING_ENV="$tmp/provisioning.env"
export APP_HINT_CONNECTOR_TOKEN="$tmp/connectord.env"

# 1. A self-hosted, unlinked box gets the block, in the mockup's three steps.
out="$(cmd_app_hint)"
for needle in "Talk to your agents from your phone" "Paste this on your server" \
              "$install_cmd" "$connect_cmd" "Your server shows a code" \
              "Type the code at https://5dive.app"; do
  [[ "$out" == *"$needle"* ]] && ok "block names: $needle" || bad "block is missing: $needle"
done

# 2. A box 5dive built is already linked to its owner's account: no block.
: > "$APP_HINT_PROVISIONING_ENV"
[[ -z "$(cmd_app_hint)" ]] && ok "silent on a 5dive-built box" || bad "printed on a 5dive-built box"
rm -f "$APP_HINT_PROVISIONING_ENV"

# 3. A linked connector: no block. An empty token file is not linked.
: > "$APP_HINT_CONNECTOR_TOKEN"
[[ -n "$(cmd_app_hint)" ]] && ok "an empty token file still prints" || bad "an empty token file hid the block"
printf 'CONNECTORD_TOKEN=abc\n' > "$APP_HINT_CONNECTOR_TOKEN"
[[ -z "$(cmd_app_hint)" ]] && ok "silent once the connector is linked" || bad "printed on a linked box"
rm -f "$APP_HINT_CONNECTOR_TOKEN"

# 4. The off switch.
[[ -z "$(FIVEDIVE_APP_HINT=0 cmd_app_hint)" ]] && ok "FIVEDIVE_APP_HINT=0 turns it off" || bad "FIVEDIVE_APP_HINT=0 ignored"

# 5. Wiring: the installer and the wizard both print it, through the one copy.
grep -q '^5dive _app_hint 2>/dev/null || true$' install.sh && ok "install.sh prints it" || bad "install.sh does not call 5dive _app_hint"
[[ "$(declare -f cmd_init)" == *"cmd_app_hint"* ]] && ok "init prints it" || bad "cmd_init does not call cmd_app_hint"
grep -qE '^\s+_app_hint\)$' src/main.sh && ok "main dispatches _app_hint" || bad "main.sh has no _app_hint verb"

# 6. Both READMEs carry the same commands and the app, above the first section.
for f in README.md README.zh-CN.md; do
  top="$(sed -n '1,/^## /p' "$f")"
  for needle in "$install_cmd" "$connect_cmd" "5dive.app" "docs/readme-app.png"; do
    [[ "$top" == *"$needle"* ]] && ok "$f top has: $needle" || bad "$f top is missing: $needle"
  done
done
[[ -s docs/readme-app.png ]] && ok "docs/readme-app.png exists" || bad "docs/readme-app.png missing"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
