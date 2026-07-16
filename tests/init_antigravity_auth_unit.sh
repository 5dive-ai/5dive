#!/usr/bin/env bash
# DIVE-1339: the init wizard must regain control after Antigravity OAuth rather
# than dropping the user into an agy TUI that only exits via an undisclosed
# `/exit`. This test drives the detached auth-session lifecycle with CLI stubs;
# it touches no credentials, network, tmux, or host auth state.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/cmd_init.sh

state_dir=$(mktemp -d)
trap 'rm -rf "$state_dir"' EXIT
printf '0\n' >"$state_dir/polls"

5dive() {
  case "$*" in
    "agent auth start antigravity --json")
      printf '%s\n' '{"ok":true,"data":{"sessionId":"agy-test"}}'
      ;;
    "agent auth poll agy-test --json")
      poll_count=$(<"$state_dir/polls")
      poll_count=$((poll_count + 1))
      printf '%s\n' "$poll_count" >"$state_dir/polls"
      case "$poll_count" in
        1) printf '%s\n' '{"ok":true,"data":{"state":"pending_url"}}' ;;
        2) printf '%s\n' '{"ok":true,"data":{"state":"awaiting_code","url":"https://accounts.example/agy"}}' ;;
        3) printf '%s\n' '{"ok":true,"data":{"state":"submitted"}}' ;;
        *) printf '%s\n' '{"ok":true,"data":{"state":"ok"}}' ;;
      esac
      ;;
    "agent auth submit agy-test --code=callback-code --json")
      printf '%s\n' 'callback-code' >"$state_dir/submitted"
      printf '%s\n' '{"ok":true,"data":{"state":"submitted"}}'
      ;;
    "agent auth cancel agy-test --json")
      : >"$state_dir/cancelled"
      printf '%s\n' '{"ok":true}'
      ;;
    *)
      printf 'unexpected 5dive call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

sleep() { :; }
_init_secret() { printf -v "$1" '%s' 'callback-code'; }

output=$(_init_antigravity_login 2>&1)
[[ "$output" == *"https://accounts.example/agy"* ]]
[[ "$output" == *"Antigravity sign-in complete"* ]]
[[ "$(<"$state_dir/submitted")" == callback-code ]]
[[ ! -e "$state_dir/cancelled" ]]

body=$(declare -f cmd_init)
[[ "$body" == *'_init_antigravity_login'* ]]
[[ "$body" != *'openclaw|antigravity|grok)'* ]]

auth_src=$(<src/cmd_auth.sh)
[[ "$auth_src" == *'type /exit to return to your shell'* ]]

echo "PASS: init completes Antigravity auth through the detached session and resumes"
