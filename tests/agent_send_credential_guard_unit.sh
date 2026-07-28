#!/usr/bin/env bash
# DIVE-2137 (gh#214, A-MO7SEN) unit: `agent send`/`ask`/`_deliver` must REFUSE to
# type into a pane that is sitting on a credential/login prompt.
#
# THE DEFECT: the send path checked that the pane was ready to receive keystrokes
# (_agent_pane_input_ready) but never what the pane WAS. An agent that booted
# unauthenticated parks on its login menu, where codex still draws the same "›"
# composer glyph it draws in chat — so every readiness marker matched, the
# message was typed into the API-key field and submitted, and the body became the
# agent's stored credential. The caller saw `delivered`.
#
# ---------------------------------------------------------------------------
# PROVENANCE OF EVERY PANE SAMPLE BELOW — read this before adding one.
#
# A fingerprint test is worthless if the fixture was reverse-engineered from the
# matcher: the matcher and the fixture then agree inside a universe neither
# shares with the real TUI, and no amount of mutation grading can see it, because
# every mutant inherits the same wrong fixture. So none of these strings were
# invented here. Each is tagged with where it was actually read from:
#
#   [BIN-codex]  strings(1) over the shipped binary
#                @openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex
#   [BIN-claude] strings(1) over ~/.local/share/claude/versions/2.1.220
#   [FIELD]      quoted from a real pane by the reporter in gh#214
#
# The codex [BIN] rows and the [FIELD] rows agree verbatim, independently — that
# agreement is the reason this fingerprint set is trustworthy at all.
#
# NOT MEASURED (declared, not hidden): "Select login method", "Enter your API
# key" and "Paste your API key" do NOT appear in the shipped claude binary that
# was checked, so the guard does not match them and this file does not pretend
# to cover them. grok and opencode login screens were NOT captured — no sample,
# no fingerprint, no claim. If one of those TUIs is the next report, the missing
# sample is the work, not a regex tweak.
# ---------------------------------------------------------------------------
#
# Pure: sources only the predicate, no tmux, no root, no network.
#   bash tests/agent_send_credential_guard_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."

# Counter shape matches the rest of tests/ on purpose: tests/meta/harness-verdict-probe.sh
# must be able to identify this harness's verdict variable and prove the exit
# status is actually wired to it. A harness it cannot probe is "NOT counted
# clean" — which is the same failure mode this whole ticket is about, one level
# up: a green result that was never measured.
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# Source the SHIPPED predicate out of the real source file so this test cannot
# drift from the code that runs. Same technique as heartbeat_idle_marker_unit.sh.
SRC=src/cmd_agent_runtime.sh
eval "$(awk '/^_agent_pane_credential_prompt\(\) \{$/ { on=1 } on { print } on && $0 == "}" { exit }' "$SRC")"
declare -F _agent_pane_credential_prompt >/dev/null \
  || { echo "FAIL: could not extract _agent_pane_credential_prompt from $SRC"; exit 1; }

refuses() { if _agent_pane_credential_prompt "$2"; then ok_t "$1"; else bad_t "$1 (would have typed a secret into it)"; fi; }
allows()  { if _agent_pane_credential_prompt "$2"; then bad_t "$1 (legitimate send refused)"; else ok_t "$1"; fi; }

# ---------------------------------------------------------------------------
# MUST REFUSE — real login surfaces.
# ---------------------------------------------------------------------------

# [BIN-codex] + [FIELD] — the exact screen from gh#214.
CODEX_LOGIN=$'\n  Sign in with ChatGPT to use Codex as part of your paid plan\n  or connect an API key for usage-based billing\n\n> 1. Sign in with ChatGPT\n    Usage included with Plus, Pro, Business, and Enterprise plans\n  2. Provide your own API key\n    Pay for what you use\n\n  Press Enter to continue.\n'
refuses "codex login menu (ChatGPT / own API key) is refused" "$CODEX_LOGIN"

# [BIN-codex] — device-code variant of the same menu.
CODEX_DEVICE=$'\n> 1. Sign in with ChatGPT\n  2. Sign in with Device Code\n     Sign in from another device with a one-time code\n'
refuses "codex device-code login menu is refused" "$CODEX_DEVICE"

# [BIN-codex] — the API-key ENTRY field. This is the screen that actually stores
# the payload: codex writes what is typed here straight into auth.json.
CODEX_KEY_ENTRY=$'  Use your own OpenAI API key for usage-based billing\n\n  Paste or type your API key below. It will be stored locally in auth.json.\n\n  › \n'
refuses "codex API-key entry field is refused" "$CODEX_KEY_ENTRY"

# [BIN-codex] — the env-var variant of the entry screen.
CODEX_ENV_KEY=$'  Detected OPENAI_API_KEY environment variable.\n  Paste a different key if you prefer to use another account.\n\n  › \n'
refuses "codex detected-env-key entry screen is refused" "$CODEX_ENV_KEY"

# [BIN-claude] — claude's login method chooser.
CLAUDE_LOGIN=$'  Claude account with subscription \n  Starting at $20/mo\n\n  Anthropic Console account \n  API usage billing\n\n❯ \n'
refuses "claude login chooser is refused" "$CLAUDE_LOGIN"

# Generic secret field, for a TUI we have no sample of: a bare label awaiting
# input. Narrow on purpose — nothing after the colon.
refuses "bare 'API key:' field is refused"  $'some output\n\nAPI key: \n'
refuses "bare 'Password:' field is refused" $'connecting...\n\n  Password:\n'
refuses "bare 'Token:' field is refused"    $'setup\n\n> Token:   \n'

# ---------------------------------------------------------------------------
# MUST ALLOW — the false-positive half. This is not decoration: while building
# the guard, a scan of live agent panes on this box matched the substrings
# "api key" and "sign in" inside an ordinary WORKING chat pane (mine, discussing
# this very ticket). A single-substring whole-pane matcher would have refused
# real inter-agent traffic fleet-wide.
# ---------------------------------------------------------------------------

allows "ordinary claude chat pane is allowed" \
  $'● Done — pushed the branch.\n\n❯ \n'
allows "ordinary codex chat pane is allowed" \
  $'• Ran tests, all green.\n\n›  \n  gpt-5.5 medium · ~/projects/5dive\n'

# The real observed near-miss: an agent DISCUSSING credentials.
allows "chat pane discussing an API key is allowed" \
  $'I checked whether the api key was seeded and it was not.\nWe should sign in again before retrying.\n\n❯ \n'
allows "chat pane quoting ONE menu row is allowed" \
  $'The reporter says the pane showed "Provide your own API key".\n\n❯ \n'
allows "chat pane quoting the other menu row is allowed" \
  $'gh#214 mentions Sign in with ChatGPT as the first option.\n\n❯ \n'

# A secret-field label in SCROLLBACK (not the live prompt) must not latch: the
# agent has moved on and is back at a chat input.
SCROLLED_PAST=$'Paste or type your API key below. It will be stored locally in auth.json.\n'
SCROLLED_PAST+=$'ok, authenticated.\n'
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do SCROLLED_PAST+=$'working on DIVE-2137...\n'; done
SCROLLED_PAST+=$'❯ \n'
allows "an API-key prompt scrolled out of the live region is allowed" "$SCROLLED_PAST"

# A label with a VALUE after it is prose/output, not a field awaiting input.
allows "'API key: sk-… (redacted)' output line is allowed" \
  $'config dump\nAPI key: <redacted>\n\n❯ \n'

allows "empty pane is allowed (readiness, not credential, decides)" ""

# ---------------------------------------------------------------------------
# LOCKSTEP: the credential guard must sit on the ONE choke point every typed
# send funnels through. If a future change adds a fourth inject site that calls
# tmux send-keys directly, this fails rather than shipping a hole.
# ---------------------------------------------------------------------------
guard_line=$(grep -n '_agent_pane_safe_to_type "\$name" || return 3' "$SRC" | wc -l)
if (( guard_line == 1 )); then
  ok_t "inject_and_submit carries the credential guard"
else
  bad_t "inject_and_submit no longer carries the credential guard (found $guard_line)"
fi

# Every send-keys -l (the literal payload inject) must live inside
# inject_and_submit, i.e. behind the guard.
literal_injects=$(grep -c 'tmux send-keys -t "agent-\${name}" -l --' "$SRC")
if (( literal_injects == 1 )); then
  ok_t "exactly one literal payload inject exists, and it is behind the guard"
else
  bad_t "found $literal_injects literal payload injects — a new one may bypass the credential guard"
fi

# All three callers must treat rc 3 as a hard failure, never as a warning.
rc3_sites=$(grep -c '_rc == 3' "$SRC")
if (( rc3_sites == 3 )); then
  ok_t "all three inject callers fail hard on the refusal (rc 3)"
else
  bad_t "expected 3 callers handling rc 3, found $rc3_sites"
fi

# The scoped ask path must pass the refusal through instead of relabelling it as
# a missing sudoers grant.
if grep -q '_drc == E_AUTH_REQUIRED' "$SRC"; then
  ok_t "scoped ask path passes the credential refusal through"
else
  bad_t "scoped ask path swallows the credential refusal as a grant error"
fi

# The heartbeat is a FOURTH typed-send site, in a different file, reached with no
# human watching. It must go through the same predicate. Asserted here (not just
# in cmd_agent_runtime.sh) because that is exactly the drift DIVE-1528 was about.
HB=src/cmd_heartbeat.sh
if grep -q '_agent_pane_safe_to_type "\$name" ||' "$HB"; then
  ok_t "heartbeat _hb_send_line is behind the credential guard"
else
  bad_t "heartbeat _hb_send_line types into an unchecked pane"
fi

# Deliberate credential typing must NOT be guarded: `agent auth` exists to put a
# code into a login prompt. Recorded so a future sweep doesn't "fix" it.
if grep -q 'send-keys -t "\$session" -l -- "\$code"' src/cmd_auth.sh; then
  ok_t "cmd_auth's intentional login-code inject is left unguarded (by design)"
else
  bad_t "cmd_auth login-code inject changed shape — re-check the guard boundary"
fi

echo
printf 'credential-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
