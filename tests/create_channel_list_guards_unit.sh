#!/usr/bin/env bash
# DIVE-2381: the two REACHABLE exact-match `$channels` comparisons on the
# agent-create path must be list-aware (channel_in_list), not `==`.
#
#   site A  hermes messaging gateway   — `--type=hermes --channels=telegram,discord`
#           silently skipped ensure_hermes_gateway: the agent came up with no
#           gateway and NO error.
#   site B  bot_username resolution    — every claude create with an explicit
#           `--channels=telegram` arrives here as "telegram,dashboard" (the
#           DIVE-856 append at cmd_agent_create.sh), so getMe never ran and
#           botUsername was written EMPTY to the registry.
#
# HOW THIS GRADES (and why it is not the idiom swap restated):
# the harness does NOT contain a copy of either predicate. It EXTRACTS each
# guard verbatim from src/cmd_agent_create.sh at run time, by anchor comment,
# and executes THAT text against real inputs. Revert either line in the source
# and this harness goes red, because the reverted line is what runs.
#
# No root, network, credentials, users, or runtime state are touched.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh

SRC=src/cmd_agent_create.sh

# Lift the block starting at <anchor comment> and ending at the first line that
# is exactly "  fi" — the shipped text, indentation and continuations included.
extract_guard() {
  local anchor="$1" start
  start=$(grep -nF -- "$anchor" "$SRC" | head -1 | cut -d: -f1) || start=""
  [[ -n "$start" ]] || {
    echo "FAIL: anchor not found in $SRC: $anchor" >&2
    echo "      (the guard moved or was reworded — re-anchor this test, do not delete it)" >&2
    exit 1
  }
  sed -n "${start},\$p" "$SRC" | sed -n '1,/^  fi$/p'
}

# --- reachability preconditions (the ticket's claims, re-checked live) -------
# A wrong premise here would make every assertion below vacuous.
[[ "${TYPE_CHANNELS[hermes]:-0}" == "1" ]] \
  || { echo 'FAIL: hermes does not accept --channels at all; site A is unreachable' >&2; exit 1; }
valid_channel 'telegram,discord' \
  || { echo 'FAIL: valid_channel rejects telegram,discord; site A is unreachable' >&2; exit 1; }
# hermes must NOT be in the codex/grok/antigravity/opencode no-discord-build refusal.
if grep -q 'hermes' <<<"$(grep -A2 'no discord build yet' "$SRC")"; then
  echo 'FAIL: hermes now refuses discord; site A is unreachable' >&2; exit 1
fi
# The DIVE-856 append is what puts a LIST in front of site B on the ordinary path.
grep -qF 'channels="${channels},dashboard"' "$SRC" \
  || { echo 'FAIL: the DIVE-856 dashboard append is gone; site B repro premise is stale' >&2; exit 1; }

pass=0 fail=0
check() { # check <expected 0|1> <label>
  if [[ "$1" == "$2" ]]; then pass=$((pass + 1)); printf 'ok   %s\n' "$3"
  else fail=$((fail + 1)); printf 'FAIL %s (want %s, got %s)\n' "$3" "$1" "$2" >&2; fi
}

# --- site A: hermes messaging gateway ---------------------------------------
GUARD_A=$(extract_guard '# For hermes telegram/discord channels, install + start the per-user')
grep -q 'ensure_hermes_gateway' <<<"$GUARD_A" \
  || { echo 'FAIL: extracted block A does not call ensure_hermes_gateway — bad anchor' >&2; exit 1; }

gateway_for() { # gateway_for <type> <channels> <defer_auth> -> echoes 1 if called
  # shellcheck disable=SC2034  # type/channels/defer_auth/name are read by the eval'd guard
  local type="$1" channels="$2" defer_auth="$3" name=hermes-qa called=0
  ensure_hermes_gateway() { called=1; }
  eval "$GUARD_A"
  echo "$called"
}

check 1 "$(gateway_for hermes telegram 0)"          'A: hermes + telegram          -> gateway installed'
check 1 "$(gateway_for hermes discord 0)"           'A: hermes + discord           -> gateway installed'
# THE DEFECT. Pre-fix this is 0: the agent boots with no messaging gateway, silently.
check 1 "$(gateway_for hermes telegram,discord 0)"  'A: hermes + telegram,discord  -> gateway installed'
check 1 "$(gateway_for hermes discord,telegram 0)"  'A: hermes + discord,telegram  -> gateway installed'
# Negatives: the fix must not widen the guard.
check 0 "$(gateway_for hermes none 0)"              'A: hermes + none              -> no gateway'
check 0 "$(gateway_for hermes telegram,discord 1)"  'A: --defer-auth               -> no gateway'
check 0 "$(gateway_for claude telegram 0)"          'A: non-hermes type            -> no gateway'
# A substring compare (the other tempting "fix") would match these; channel_in_list must not.
check 0 "$(gateway_for hermes dashboard 0)"         'A: dashboard only             -> no gateway'

# --- site B: bot_username resolution ----------------------------------------
GUARD_B=$(extract_guard '# Resolve bot @username via Telegram getMe so the dashboard')
grep -q 'fetch_bot_username' <<<"$GUARD_B" \
  || { echo 'FAIL: extracted block B does not call fetch_bot_username — bad anchor' >&2; exit 1; }

username_for() { # username_for <channels> <token> -> echoes resolved bot_username
  # shellcheck disable=SC2034  # channels/telegram_token are read by the eval'd guard
  local channels="$1" telegram_token="$2"
  fetch_bot_username() { echo "qa_bot"; }
  eval "$GUARD_B"
  echo "$bot_username"
}

check qa_bot "$(username_for telegram tok-123)"            'B: telegram                   -> botUsername resolved'
# THE DEFECT. Pre-fix this is empty: EVERY claude `--channels=telegram` create
# lands here as "telegram,dashboard", so the registry got botUsername="" and the
# dashboard agent list could not render the t.me/<bot> deep link.
check qa_bot "$(username_for telegram,dashboard tok-123)"  'B: telegram,dashboard         -> botUsername resolved'
check qa_bot "$(username_for dashboard,telegram tok-123)"  'B: dashboard,telegram         -> botUsername resolved'
check '' "$(username_for telegram '')"                     'B: telegram, no token         -> empty'
check '' "$(username_for discord,dashboard tok-123)"       'B: no telegram in list        -> empty'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
