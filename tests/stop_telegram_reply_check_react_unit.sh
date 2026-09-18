#!/usr/bin/env bash
# TIER: nightly — the Stop-hook auto-relay safety net, graded end to end by running the hook against synthetic transcripts with curl stubbed. ~2s. Not on the merge/ship path, and no PR diff outside hooks/ can break it (DIVE-4465).
# A REACTION IS AN ANSWER — the turn that placed one must not have its recap
# auto-relayed to the chat.
#
# Observed 2026-09-18 06:01-06:02Z: three 👍 reactions on "ok"-class messages,
# each followed into the chat by an "(auto-relay) <end-of-turn recap>" message.
#
# Cause: `had_telegram_send` counted only reply/edit_message, so a react-only
# turn fell through to the "transcript text present" branch and relayed the
# whole recap. The react-only branch further down never saw it — that branch is
# reached only when the turn produced NO text, and the harness prompts for a
# recap at the end of every turn.
#
# WHAT THIS GRADES:
#   * react + transcript text  -> SILENT (the fix);
#   * no telegram tool + text  -> RELAYED (the net still works — the whole
#     point is that it must not be weakened into uselessness);
#   * reply/edit_message + text -> SILENT (unchanged);
#   * download_attachment + text -> RELAYED (it reads FROM the channel and
#     says nothing back, so it is still not a send);
#   * no telegram inbound       -> SILENT (the hook is scoped to a channel turn);
#   * MUTANT: strip react back out of the predicate and the first arm goes red,
#     while the other two directions stay green — so the mutant is a WORKING
#     hook that differs in exactly the case this change is about.
#
# Nothing is stubbed but `curl`: jq, the turn-boundary scan, the lock-file
# logic and every branch are the real script, run as the harness runs it.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-stopreact}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}

HOOK="hooks/stop-telegram-reply-check.sh"
[[ -r "$HOOK" ]] || { printf 'FAIL - %s is not readable from the repo root\n' "$HOOK"; exit 1; }

# --- boundary: curl. The only thing stubbed, and it records rather than sends.
STUB="$TMPROOT/bin"; mkdir -p "$STUB"
CURL_LOG="$TMPROOT/curl.log"; : >"$CURL_LOG"
cat >"$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_LOG:?curl stub called with no CURL_LOG}"
exit 0
STUBEOF
chmod +x "$STUB/curl"

# --- transcript fixtures ----------------------------------------------------
INBOUND='{"type":"user","message":{"content":"<channel source=\"plugin:telegram:telegram\" chat_id=\"12345\" message_id=\"678\" user=\"owner\">ok</channel>"}}'
NO_CHANNEL='{"type":"user","message":{"content":"just a local prompt, nothing from telegram"}}'
RECAP='{"type":"assistant","message":{"content":[{"type":"text","text":"Reacted to the ack. Recap: nothing else changed this turn."}]}}'
tool_use() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__plugin_telegram_telegram__%s","input":{}}]}}\n' "$1"; }

# transcript <name> <line...> -> path
transcript() {
  local name="$1"; shift
  local path="$TMPROOT/$name.jsonl"
  : >"$path"
  local line
  for line in "$@"; do printf '%s\n' "$line" >>"$path"; done
  printf '%s\n' "$path"
}

# run_hook <hook> <transcript> -> what curl was asked to send (empty = silent)
run_hook() {
  local hook="$1" transcript="$2"
  : >"$CURL_LOG"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$transcript" \
    | PATH="$STUB:$PATH" CURL_LOG="$CURL_LOG" TELEGRAM_BOT_TOKEN=test-token-abcdef \
      bash "$hook" >/dev/null 2>&1 || true
  cat "$CURL_LOG"
}
relayed() { [[ -n "$1" ]] && printf 'yes\n' || printf 'no\n'; }

T_REACT_TEXT=$(transcript react-text   "$INBOUND" "$(tool_use react)"    "$RECAP")
T_TEXT_ONLY=$(transcript  text-only    "$INBOUND" "$RECAP")
T_REPLY_TEXT=$(transcript reply-text   "$INBOUND" "$(tool_use reply)"    "$RECAP")
T_EDIT_TEXT=$(transcript  edit-text    "$INBOUND" "$(tool_use edit_message)" "$RECAP")
T_DL_TEXT=$(transcript    dl-text      "$INBOUND" "$(tool_use download_attachment)" "$RECAP")
T_REACT_ONLY=$(transcript react-only   "$INBOUND" "$(tool_use react)")
T_NO_INBOUND=$(transcript no-inbound   "$NO_CHANNEL" "$RECAP")

# --- A: the fix -------------------------------------------------------------
out=$(run_hook "$HOOK" "$T_REACT_TEXT")
is "A1: react + an end-of-turn recap is SILENT (the reaction was the answer)" "no" "$(relayed "$out")"
is "A2: ... and the shipped predicate really names react (A1 is not vacuous)" "yes" \
   "$(grep -q 'or (\.name == (\$tg + "react"))' "$HOOK" && echo yes || echo no)"

# --- B: the net still works -------------------------------------------------
out=$(run_hook "$HOOK" "$T_TEXT_ONLY")
is "B1: no telegram tool at all + text is RELAYED (the miss this hook exists for)" "yes" "$(relayed "$out")"
is "B2: ... and what it relays is the auto-relay line" "yes" \
   "$(case "$out" in *'(auto-relay)'*) echo yes;; *) echo no;; esac)"
is "B3: ... addressed to the chat the inbound came from" "yes" \
   "$(case "$out" in *'chat_id=12345'*) echo yes;; *) echo no;; esac)"

# --- C: unchanged behaviour -------------------------------------------------
out=$(run_hook "$HOOK" "$T_REPLY_TEXT")
is "C1: reply + text is SILENT (unchanged)" "no" "$(relayed "$out")"
out=$(run_hook "$HOOK" "$T_EDIT_TEXT")
is "C2: edit_message + text is SILENT (unchanged)" "no" "$(relayed "$out")"
out=$(run_hook "$HOOK" "$T_REACT_ONLY")
is "C3: react with no text at all is SILENT (unchanged)" "no" "$(relayed "$out")"
out=$(run_hook "$HOOK" "$T_NO_INBOUND")
is "C4: no telegram inbound is SILENT (the hook is scoped to a channel turn)" "no" "$(relayed "$out")"

# --- D: the boundary the fix deliberately keeps -----------------------------
out=$(run_hook "$HOOK" "$T_DL_TEXT")
is "D1: download_attachment + text is RELAYED — reading FROM the channel is not a send" "yes" "$(relayed "$out")"

# --- MUTANT: put the defect back --------------------------------------------
# Strip react out of had_telegram_send and restore the paren the fix moved.
MUT="$TMPROOT/hook-mutant.sh"
sed -e 's/or (\.name == (\$tg + "edit_message"))$/or (.name == ($tg + "edit_message"))))/' \
    -e '/or (\.name == (\$tg + "react"))))/d' "$HOOK" >"$MUT"
is "M0a: the mutation changed the script (a no-op sed would grade nothing)" "yes" \
   "$(cmp -s "$HOOK" "$MUT" && echo no || echo yes)"
is "M0b: ... and react is gone from the send predicate" "yes" \
   "$(grep -q 'or (\.name == (\$tg + "react"))' "$MUT" && echo no || echo yes)"
is "M0c: ... and the mutant is still valid bash" "yes" \
   "$(bash -n "$MUT" 2>/dev/null && echo yes || echo no)"

out=$(run_hook "$MUT" "$T_REACT_TEXT")
is "M1: MUTANT — react + recap is RELAYED again (A1 is red on it: the defect)" "yes" "$(relayed "$out")"
is "M2: MUTANT — and what leaks is the recap itself" "yes" \
   "$(case "$out" in *'Recap: nothing else changed this turn.'*) echo yes;; *) echo no;; esac)"
out=$(run_hook "$MUT" "$T_TEXT_ONLY")
is "M3: MUTANT — the net still fires on a real miss (the mutant is a working hook)" "yes" "$(relayed "$out")"
out=$(run_hook "$MUT" "$T_REPLY_TEXT")
is "M4: MUTANT — reply + text still silent (only the react case moved)" "no" "$(relayed "$out")"

# --- RESTORE ----------------------------------------------------------------
out=$(run_hook "$HOOK" "$T_REACT_TEXT")
is "R1: the shipped hook is untouched by the mutant and still silent" "no" "$(relayed "$out")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
