#!/usr/bin/env bash
# DIVE-2895 unit harness for the buzz (Nostr) channel CLI wiring.
#
# Adding a channel is not one edit, it is FIVE, spread across three files, and
# four of the five fail SILENTLY when missed — the fifth (5dive-agent-start's
# dispatch) is the only one that says anything, and it says it at boot on a box
# rather than at the keystroke. Measured while wiring the first live buzz agent:
# the plugin was merged to main and installable, and `channels=buzz` was still
# rejected by valid_channel with no hint that four other sites were already
# ready. This harness grades all five together so the next channel cannot ship
# four-fifths wired.
#
#   1. valid_channel()                     accepts it            (validation.sh)
#   2. install_channel_plugin_for_agent()  routes it to the
#                                          5dive-plugins marketplace
#                                          (NOT claude-plugins-official)
#   3. install_channel_for_agent()         refuses non-claude types by name
#   4. cmd_agent_config's staging gate     knows the marketplace, so a
#                                          restart is refused into a deaf
#                                          session rather than allowed
#   5. 5dive-agent-start                   emits --channels plugin:<ch>@<mkt>
#      reconcile_managed_settings()        allowlists it (channelsEnabled)
#
# Run: bash tests/buzz_channel_wiring_unit.sh  (no root, no network, no tmux).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. valid_channel accepts buzz, alone and in a list ---------------------
valid_channel buzz            && ok_t "valid_channel buzz"                  || bad_t "valid_channel buzz"
valid_channel telegram,buzz   && ok_t "valid_channel telegram,buzz"         || bad_t "valid_channel telegram,buzz"
valid_channel buzz,dashboard  && ok_t "valid_channel buzz,dashboard"        || bad_t "valid_channel buzz,dashboard"

# Negative controls: the accept must not have widened to everything. A test that
# only asserts the new value passes just as well against `=~ .*`.
valid_channel buzzz  && bad_t "NEGATIVE: buzzz must be rejected"            || ok_t "NEGATIVE: buzzz rejected"
valid_channel bzz    && bad_t "NEGATIVE: bzz must be rejected"              || ok_t "NEGATIVE: bzz rejected"
valid_channel none,buzz && bad_t "NEGATIVE: none,buzz must be rejected"     || ok_t "NEGATIVE: none,buzz rejected (none is alone-only)"

# --- 2. marketplace routing: buzz is OURS, not upstream ---------------------
# Graded on source text rather than by calling the installer, which needs a real
# agent user, bun, and network. The predicate is one line and this asserts the
# line, plus the negative that the upstream default did not swallow it.
AS=$SRC/lib/agent_setup.sh
if grep -qE '\$plugin" == "telegram" \|\| "\$plugin" == "dashboard" \|\| "\$plugin" == "buzz"' "$AS"; then
  ok_t "install_channel_plugin_for_agent routes buzz to 5dive-plugins"
else
  bad_t "install_channel_plugin_for_agent routes buzz to 5dive-plugins" \
        "buzz missing from the marketplace predicate in $AS — it would install from claude-plugins-official, which has no buzz plugin"
fi

# --- 3. claude-only refusal names the channel -------------------------------
if grep -qE 'plugin" == "buzz" && "\$type" != "claude"' "$AS"; then
  ok_t "install_channel_for_agent refuses buzz on non-claude types"
else
  bad_t "install_channel_for_agent refuses buzz on non-claude types" \
        "no claude-only guard for buzz in $AS"
fi

# --- 4. the config staging gate knows buzz's marketplace --------------------
# Without this, channels_changed_to=buzz hits `*) continue` and the restart
# proceeds into a session whose plugin cache may not be staged — a deaf agent.
if grep -qE 'telegram\|dashboard\|buzz\) gate_marketplace="5dive-plugins"' "$SRC/cmd_agent_config.sh"; then
  ok_t "cmd_agent_config staging gate covers buzz"
else
  bad_t "cmd_agent_config staging gate covers buzz" \
        "buzz falls through to '*) continue' — restart into a possibly-deaf session is not refused"
fi

# --- 5. 5dive-agent-start emits the channel arg, claude-only ----------------
if grep -qE 'ARGS\+=\(--channels "plugin:buzz@5dive-plugins"\)' 5dive-agent-start; then
  ok_t "5dive-agent-start emits --channels plugin:buzz@5dive-plugins"
else
  bad_t "5dive-agent-start emits --channels plugin:buzz@5dive-plugins" \
        "channels=buzz would hit the 'unknown channels' arm and exit 2"
fi
if grep -qE 'channels=buzz is claude-only' 5dive-agent-start; then
  ok_t "5dive-agent-start refuses buzz on non-claude types"
else
  bad_t "5dive-agent-start refuses buzz on non-claude types"
fi

# --- 6. managed-settings reconcile allowlists buzz --------------------------
# channelsEnabled gates inbound channel pings on a personal/self-hosted box; a
# plugin absent from allowedChannelPlugins is installed, running, and ignored.
if grep -qE '\{"plugin":"buzz","marketplace":"5dive-plugins"\}' "$AS"; then
  ok_t "reconcile_managed_settings allowlists buzz@5dive-plugins"
else
  bad_t "reconcile_managed_settings allowlists buzz@5dive-plugins" \
        "existing boxes would never self-heal to allow the buzz channel"
fi

# Positive control on the reconcile jq itself: run it over a fixture that has
# only telegram, and assert buzz is ADDED and the operator's own entry is kept.
# This is the arm that would catch a syntactically-present-but-wrong jq edit —
# grep alone cannot tell a well-formed allowlist from a broken one.
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$AS" 2>/dev/null
  FIX=$(mktemp)
  cat >"$FIX" <<'JSON'
{"allowedChannelPlugins":[{"plugin":"telegram","marketplace":"5dive-plugins"},
                          {"plugin":"custom","marketplace":"operator-own"}]}
JSON
  reconcile_managed_settings "$FIX" >/dev/null 2>&1
  rc=$?
  got_buzz=$(jq -r '[.allowedChannelPlugins[] | select(.plugin=="buzz" and .marketplace=="5dive-plugins")] | length' "$FIX" 2>/dev/null)
  kept_own=$(jq -r '[.allowedChannelPlugins[] | select(.plugin=="custom")] | length' "$FIX" 2>/dev/null)
  enabled=$(jq -r '.channelsEnabled' "$FIX" 2>/dev/null)
  if [[ "$rc" == "0" && "$got_buzz" == "1" ]]; then
    ok_t "reconcile_managed_settings ADDS buzz to an existing file (rc=0)"
  else
    bad_t "reconcile_managed_settings ADDS buzz to an existing file" "rc=$rc buzz_entries=$got_buzz"
  fi
  [[ "$kept_own" == "1" ]] \
    && ok_t "reconcile_managed_settings keeps the operator's own entry" \
    || bad_t "reconcile_managed_settings keeps the operator's own entry" "custom entries=$kept_own"
  [[ "$enabled" == "true" ]] \
    && ok_t "reconcile_managed_settings sets channelsEnabled=true" \
    || bad_t "reconcile_managed_settings sets channelsEnabled=true" "got $enabled"
  # Idempotence: a second run must report already-current (3), not rewrite.
  reconcile_managed_settings "$FIX" >/dev/null 2>&1
  [[ "$?" == "3" ]] \
    && ok_t "reconcile_managed_settings is idempotent (second run = already current)" \
    || bad_t "reconcile_managed_settings is idempotent" "second run rc=$?"
  rm -f "$FIX"
else
  printf 'SKIP - reconcile jq arms (no jq on PATH)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
