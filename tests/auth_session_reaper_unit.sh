#!/usr/bin/env bash
# DIVE-1884 unit harness for auth-session fail-loud + reaping.
#
# Two bugs, both found by main repairing an agent seat on the DIVE-1868 box:
#
#   1. `auth start antigravity` reported state=pending_url INDEFINITELY. The
#      rail wasn't broken the way that reads — agy never GOT to device auth: on
#      a profile with no prior login it opens its first-run onboarding wizard
#      (colour-scheme picker, then a Terms-of-Service + data-use consent screen
#      with [Previous]/[Done]) and waits for keystrokes nobody sends. Because
#      pending_url is also the normal "waiting on the IdP" state, the operator
#      waited forever with no signal. Fix: bound the wait, then FAIL LOUD with
#      the pane tail so the wizard is visible instead of guessed at.
#
#   2. Abandoned sessions were never reaped — a stale login CLI from the
#      previous day was still resident (~11min CPU, ~178MB RSS) and every
#      abandoned attempt left a session dir behind. Fix: `auth reap` (two
#      stages: expire non-terminal past --max-age, remove terminal past --ttl),
#      called from `auth start` so the box self-heals.
#
# Run: bash tests/auth_session_reaper_unit.sh  (no root, no network, no tmux).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enables set -e; the asserts below deliberately probe rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Sandbox the session store so we never touch /var/lib/5dive.
TMP=$(mktemp -d -t auth-reap.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
AUTH_SESSIONS_DIR="$TMP/auth-sessions"
mkdir -p "$AUTH_SESSIONS_DIR"

# Stub the LEAF, not the wrapper: auth_teardown_session's real logic stays under
# test, but its `sudo -u claude tmux …` calls are recorded instead of executed.
# Keeps the harness hermetic on a pristine runner (no claude user, no tmux) AND
# lets us assert the reaper actually tries to kill the process, not just rewrite
# the JSON.
SUDO_CALLS="$TMP/sudo-calls.log"
: > "$SUDO_CALLS"
sudo() { printf '%s\n' "$*" >> "$SUDO_CALLS"; return 0; }

# Build a fake session dir. $1=sid $2=state $3=age-in-seconds
mk_session() {
  local sid="$1" state="$2" age="$3" ts d
  ts=$(date -Iseconds -d "@$(( $(date +%s) - age ))")
  d="${AUTH_SESSIONS_DIR}/${sid}"
  mkdir -p "$d"
  jq -n --arg s "$sid" --arg st "$state" --arg ts "$ts" \
    '{sessionId:$s, type:"antigravity", profile:"qa", state:$st,
      url:null, code:null, error:null, createdAt:$ts, updatedAt:$ts}' \
    > "${d}/meta.json"
}

# --- 1. non-terminal + older than --max-age -> EXPIRED, dir kept ------------
# This is the abandoned-login case: the process is torn down but the dir stays
# so the dashboard can still read WHY it ended.
mk_session aaaaaaaaaaaaaaaa awaiting_code 7200
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 >/dev/null 2>&1
if [[ -d "${AUTH_SESSIONS_DIR}/aaaaaaaaaaaaaaaa" ]] \
   && [[ "$(jq -r .state "${AUTH_SESSIONS_DIR}/aaaaaaaaaaaaaaaa/meta.json")" == "expired" ]] \
   && [[ "$(jq -r .error "${AUTH_SESSIONS_DIR}/aaaaaaaaaaaaaaaa/meta.json")" == *reaped* ]]; then
  ok_t "stale non-terminal session is expired with a reason, dir retained"
else
  bad_t "stale non-terminal session not expired" \
        "expected state=expired + a 'reaped' error, got: $(jq -c . "${AUTH_SESSIONS_DIR}/aaaaaaaaaaaaaaaa/meta.json" 2>&1)"
fi

# ...and the process is actually torn down, not just the JSON rewritten. This is
# the half that matters: the bug was a LIVE login CLI left resident for a day.
if grep -q 'kill-session -t auth-aaaaaaaaaaaaaaaa' "$SUDO_CALLS" \
   && grep -q 'kill-server' "$SUDO_CALLS"; then
  ok_t "reaping a stale session tears the tmux server down too"
else
  bad_t "stale session expired without a teardown" \
        "expected kill-session + kill-server for auth-aaaaaaaaaaaaaaaa, saw: $(cat "$SUDO_CALLS")"
fi

# --- 2. a session still inside --max-age is LEFT ALONE ----------------------
# The reaper must never kill a login a human is mid-way through.
mk_session bbbbbbbbbbbbbbbb awaiting_code 60
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 >/dev/null 2>&1
if [[ "$(jq -r .state "${AUTH_SESSIONS_DIR}/bbbbbbbbbbbbbbbb/meta.json")" == "awaiting_code" ]]; then
  ok_t "in-flight session inside max-age is untouched"
else
  bad_t "in-flight session was reaped" "a 60s-old awaiting_code session must survive --max-age=1800"
fi

# --- 3. terminal + older than --ttl -> dir REMOVED -------------------------
mk_session cccccccccccccccc ok 200000
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 >/dev/null 2>&1
if [[ ! -d "${AUTH_SESSIONS_DIR}/cccccccccccccccc" ]]; then
  ok_t "terminal session past ttl is removed"
else
  bad_t "terminal session past ttl survived" "expected the session dir to be deleted"
fi

# --- 4. terminal but inside --ttl -> dir KEPT ------------------------------
mk_session dddddddddddddddd error 600
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 >/dev/null 2>&1
if [[ -d "${AUTH_SESSIONS_DIR}/dddddddddddddddd" ]]; then
  ok_t "recent terminal session is retained for readback"
else
  bad_t "recent terminal session removed too early" "a 600s-old error session must survive --ttl=86400"
fi

# --- 5. --dry-run mutates nothing -----------------------------------------
mk_session eeeeeeeeeeeeeeee awaiting_code 7200
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 --dry-run >/dev/null 2>&1
if [[ "$(jq -r .state "${AUTH_SESSIONS_DIR}/eeeeeeeeeeeeeeee/meta.json")" == "awaiting_code" ]]; then
  ok_t "--dry-run leaves state untouched"
else
  bad_t "--dry-run mutated a session" "state should still be awaiting_code"
fi

# --- 6. a non-session dir is ignored (sid regex guards the rm) --------------
mkdir -p "${AUTH_SESSIONS_DIR}/not-a-session"
touch -d '2020-01-01' "${AUTH_SESSIONS_DIR}/not-a-session"
JSON_MODE=0 cmd_auth_reap --max-age=1800 --ttl=86400 >/dev/null 2>&1
if [[ -d "${AUTH_SESSIONS_DIR}/not-a-session" ]]; then
  ok_t "non-session dir is skipped by the sid guard"
else
  bad_t "reaper deleted a dir outside the sid namespace" \
        "only 16-hex session dirs may be removed"
fi

# --- 7. structural: teardown never group-kills -----------------------------
# `kill -9 -<pgid>` on this host once took prod down for 19 minutes. The
# teardown walks exact pids instead.
if grep -qE 'kill -(TERM|KILL|9) +-' "$SRC/cmd_auth.sh"; then
  bad_t "auth teardown group-kills" "found a 'kill -SIG -<pgid>' form in cmd_auth.sh — exact pids only"
else
  ok_t "auth teardown uses exact pids, never a process-group kill"
fi

# --- 8. structural: poll fails loud on a wedged pending_url ----------------
# The bug was that pending_url + a live tmux session had NO exit — this asserts
# the deadline branch exists, tears the session down, and records the pane tail.
poll_body=$(awk '/^cmd_auth_poll\(\)/{c=1} c{print} /^cmd_auth_submit\(\)/{if(c) exit}' "$SRC/cmd_auth.sh")
if grep -q 'urlDeadline' <<<"$poll_body" \
   && grep -q 'paneTail' <<<"$poll_body" \
   && grep -q 'auth_teardown_session' <<<"$poll_body"; then
  ok_t "poll bounds pending_url on urlDeadline and surfaces the pane tail"
else
  bad_t "poll can still wedge on pending_url" \
        "expected cmd_auth_poll to check .urlDeadline, capture .paneTail, and tear the session down"
fi

# --- 9. structural: onboarding consent is NEVER auto-accepted --------------
# agy's first-run wizard ends in a legal ToS screen with a PRE-TICKED
# data-collection checkbox. Surfacing it is the fix; clicking it is not ours
# to do. This canary fails if someone later teaches the pending_url path to
# send keystrokes at a terms/consent screen.
pending_block=$(awk '/if \[\[ "\$state" == "pending_url" \]\]; then/{c=1} c{print} /^      if \[\[ "\$state" == "awaiting_code"/{if(c) exit}' "$SRC/cmd_auth.sh")
consent_drive=$(grep -n 'send-keys' <<<"$pending_block" | grep -iE 'terms|consent|done|privacy')
if [[ -z "$consent_drive" ]]; then
  ok_t "pending_url path never sends keys at a terms/consent screen"
else
  bad_t "consent screen is being auto-advanced" \
        "a machine must not accept a ToS + data-use consent on a human's behalf: $consent_drive"
fi

echo
echo "auth-session-reaper: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
