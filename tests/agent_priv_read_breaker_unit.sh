#!/usr/bin/env bash
# DIVE-2791 — a read-only survey column must not ask root by reflex, and must stop
# asking once refused.
#
# THE DEFECT: resolve_agent_model/resolve_agent_effort/resolve_cli_version each reached
# straight for `sudo`, and they run once PER AGENT on every fleet sweep (`agent list`,
# `compose`). On a scoped agent that is one refusal per agent per sweep — measured 29
# syslog lines from a SINGLE `agent list` as agent-dev3, and 224 in 24h across the host.
# A reporter's box ran the same chain for 9 days; each refusal became a mail to a root
# address that resolved off-box, ~39,400 delivery attempts to a nonexistent recipient,
# and the IP landed on Spamhaus CSS + XBL. No compromise — volume to a nonexistent
# recipient is just indistinguishable from abuse at the receiving end.
#
# THE MEASURED MECHANISM, because it is the part that is easy to get wrong: the syslog
# line comes from calling sudo WITHOUT `-n`. Verified as agent-dev3 against a file it
# cannot read:
#     sudo    jq …  -> "a password is required" AND logs `command not allowed`
#     sudo -n jq …  -> "a password is required" and logs NOTHING
# So `-n` is what removes the mail, the breaker is what removes the wasted spawns, and
# readability-first is what makes the value correct for a caller who can just read it.
# All three are load-bearing and they fix different halves.
#
# ARMS T3-T6/T8 EXECUTE the real functions sourced from src/cmd_agent.sh — they are not
# grep assertions about them. They stub `sudo` on PATH, which means they prove the ROUTING
# and the BREAKER and can say nothing whatever about a sudoers decision — see
# community/wiki/a-stubbed-sudo-cannot-see-a-sudoers-argv-denial.md. The end-to-end host
# measurement needs a second, differently-scoped uid and so cannot live in a harness at
# all; it is recorded on the row and here:
#     control (old bundle, agent-dev3, one `agent list`) : 29 sudo lines, 29 denials
#     treatment cold breaker                            : 3 sudo calls, 0 sudo lines, 1 warn
#     treatment warm breaker                            : 0 sudo calls, 0 sudo lines
#     as root, old vs new `agent list --json`           : byte-identical, 18 rows / 13 models
# That is a deliberate coverage limit, not a claim these arms prove the host behaviour.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_agent.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_agent.sh is present — the arms below are not reading an empty file' \
  || { bad_t 'T0 cmd_agent.sh missing — every arm is vacuous' "src=$SRC"; echo "-----"; \
       echo "agent_priv_read_breaker_unit: $pass passed, $fail failed"; exit 1; }

# Source ONLY the helper block. cmd_agent.sh is not sourceable standalone (it expects the
# bundle's globals), so pull the four functions out by name into a subshell-safe file.
# If the extraction stops matching the source, T1 fails loudly rather than silently
# testing nothing — a harness whose subject moved must report a finding, not a pass.
sed -n '/^_priv_state_file()/,/^}/p;/^_priv_denials()/,/^}/p;/^_priv_note()/,/^}/p;/^priv_read()/,/^}/p' \
  "$SRC" > "$TMP/helpers.sh"
helper_count=$(grep -cE '^(_priv_state_file|_priv_denials|_priv_note|priv_read)\(\)' "$TMP/helpers.sh")
if [[ "$helper_count" == 4 ]]; then
  ok_t 'T1 all four helpers extracted (state_file, denials, note, priv_read)'
else
  bad_t 'T1 helper extraction found the wrong number of functions — arms below are not testing the shipped code' \
        "expected 4, got $helper_count"
fi

# shellcheck disable=SC1091
( set -e; . "$TMP/helpers.sh" ) 2>/dev/null \
  && ok_t 'T2 the extracted helper block is syntactically sourceable' \
  || bad_t 'T2 extracted helpers do not source' ''

export XDG_CACHE_HOME="$TMP/cache"

# ---- T3: readable file -> read DIRECTLY, and an empty value stays empty --------------
# The escalation trigger must be READABILITY, not emptiness. A claude agent with no
# `model` key is a legitimate empty; escalating on "" would sudo for every unset agent on
# every sweep forever — the exact shape of the original flood.
run_t3() {
  . "$TMP/helpers.sh"
  local f="$TMP/readable.json"; printf '{"other":1}\n' >"$f"
  # A stub `sudo` on PATH turns any escalation into a hard, visible failure.
  printf '#!/usr/bin/env bash\necho ESCALATED >&2\nexit 99\n' >"$TMP/bin/sudo"
  chmod +x "$TMP/bin/sudo"; PATH="$TMP/bin:$PATH"
  local out; out=$(priv_read "$f" jq -r '.model // empty' "$f" 2>"$TMP/t3.err")
  [[ -z "$out" ]] || { echo "value=[$out]"; return 1; }
  grep -q ESCALATED "$TMP/t3.err" && return 2
  return 0
}
mkdir -p "$TMP/bin"
( run_t3 ) >"$TMP/t3.log" 2>&1; t3=$?
case "$t3" in
  0) ok_t 'T3 a readable file is read directly and an empty value does NOT escalate' ;;
  2) bad_t 'T3 escalated to sudo for a file it could read — the reflex is back' "$(cat "$TMP/t3.log")" ;;
  *) bad_t 'T3 direct read returned the wrong value' "$(cat "$TMP/t3.log")" ;;
esac

# ---- T4: unreadable file -> escalates, and the escalation carries -n ----------------
# `-n` is the difference between a silent refusal and a syslog line, so assert the flag
# is on the actual argv, not merely present somewhere in the file.
run_t4() {
  . "$TMP/helpers.sh"
  mkdir -p "$TMP/bin4"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/argv"\nexit 1\n' "$TMP" >"$TMP/bin4/sudo"
  chmod +x "$TMP/bin4/sudo"; PATH="$TMP/bin4:$PATH"
  priv_read "/nonexistent-unreadable/settings.json" jq -r '.model' /nonexistent-unreadable/settings.json >/dev/null 2>&1
  [[ -s "$TMP/argv" ]] || return 1
  head -1 "$TMP/argv" | grep -q -- '^-n ' || return 2
  return 0
}
( run_t4 ) >"$TMP/t4.log" 2>&1; t4=$?
case "$t4" in
  0) ok_t 'T4 an unreadable file escalates, and the sudo call passes -n (no syslog line, no mail)' ;;
  1) bad_t 'T4 never escalated for an unreadable file — the value would be silently lost' "$(cat "$TMP/t4.log")" ;;
  2) bad_t 'T4 escalated WITHOUT -n — this is the flag that emits the denial line' "$(head -1 "$TMP/argv" 2>/dev/null)" ;;
  *) bad_t 'T4 unexpected failure' "$(cat "$TMP/t4.log")" ;;
esac

# ---- T5: the breaker latches, and it latches ACROSS SUBSHELLS -----------------------
# The regression that makes this whole fix inert: every caller invokes the resolvers as
# `model=$(resolve_agent_model …)`, so a counter held in a shell VARIABLE is written in a
# subshell and discarded. It would read as working in isolation and never latch in
# production. This arm calls priv_read inside `$( )` — the way the real callers do.
run_t5() {
  . "$TMP/helpers.sh"
  mkdir -p "$TMP/bin5"
  printf '#!/usr/bin/env bash\necho CALL >>"%s/calls"\necho "sudo: a password is required" >&2\nexit 1\n' "$TMP" >"$TMP/bin5/sudo"
  chmod +x "$TMP/bin5/sudo"; PATH="$TMP/bin5:$PATH"
  export PRIV_READ_MAX_DENIALS=3
  local i v
  for i in 1 2 3 4 5 6 7 8; do
    v=$(priv_read "/nonexistent-unreadable/a$i.json" jq -r .model "/nonexistent-unreadable/a$i.json" 2>/dev/null)
  done
  local calls; calls=$(grep -c CALL "$TMP/calls" 2>/dev/null || echo 0)
  echo "calls=$calls"
  [[ "$calls" == 3 ]] || return 1
  return 0
}
( run_t5 ) >"$TMP/t5.log" 2>&1; t5=$?
if [[ "$t5" == 0 ]]; then
  ok_t 'T5 the breaker latches at PRIV_READ_MAX_DENIALS across subshell callers (8 agents -> 3 sudo calls)'
else
  bad_t 'T5 breaker did not bound the sudo calls — 8 unreadable agents must cost 3 attempts, not 8' \
        "$(cat "$TMP/t5.log")"
fi

# ---- T6: exactly ONE warn line, however many agents are swept ------------------------
# A silently degraded read is bad; a degraded read that warns once per agent per minute is
# worse than the bug. The operator gets told once.
run_t6() {
  . "$TMP/helpers.sh"
  mkdir -p "$TMP/bin6"
  printf '#!/usr/bin/env bash\necho "sudo: a password is required" >&2\nexit 1\n' >"$TMP/bin6/sudo"
  chmod +x "$TMP/bin6/sudo"; PATH="$TMP/bin6:$PATH"
  export PRIV_READ_MAX_DENIALS=3
  local i
  for i in 1 2 3 4 5 6; do
    priv_read "/nonexistent-unreadable/b$i.json" jq -r .model "/nonexistent-unreadable/b$i.json" >/dev/null
  done
}
export XDG_CACHE_HOME="$TMP/cache6"
( run_t6 ) >/dev/null 2>"$TMP/t6.err"
warns=$(grep -c 'DIVE-2791' "$TMP/t6.err" 2>/dev/null || echo 0)
if [[ "$warns" == 1 ]]; then
  ok_t 'T6 exactly one warn line for a whole sweep (not one per agent)'
else
  bad_t 'T6 wrong number of warn lines — expected exactly 1' "got $warns"
fi

# ---- T7: no unconditional sudo left in the three resolvers --------------------------
# ANCHOR against the reflex returning to these functions specifically. Scoped to the
# resolver bodies, so an unrelated privileged WRITE elsewhere in the file cannot red it.
res_block=$(sed -n '/^resolve_cli_version()/,/^}/p;/^resolve_agent_model()/,/^}/p;/^resolve_agent_effort()/,/^}/p' "$SRC")
if printf '%s\n' "$res_block" | grep -qE '(^|[^-[:alnum:]_])sudo[[:space:]]+(-u[[:space:]]+[[:alnum:]_-]+[[:space:]]+)?(jq|sed|bash|cat)'; then
  bad_t 'T7 a resolver still calls sudo directly on a read — routing bypassed' \
        "$(printf '%s\n' "$res_block" | grep -nE 'sudo[[:space:]]+' | head -3)"
else
  ok_t 'T7 ANCHOR no resolver reaches for sudo directly; reads go through priv_read / the -n guard'
fi

# ---- T8: an UNSET bound must not disable escalation ---------------------------------
# Found by this harness on first run, and it is the reason the bound is resolved inside
# the function rather than read from the global. `(( n >= PRIV_READ_MAX_DENIALS ))` with
# the constant unset is `0 >= 0` — TRUE — so priv_read read as "already latched" and
# returned "" for every agent without ever calling sudo and without a warn line. The
# bundle assigns the constant at top level so it is set in production, but the failure
# depends only on source order and is completely silent, which is exactly the class this
# row exists to remove. This arm sources the FUNCTIONS ONLY, deliberately reproducing
# that context.
run_t8() {
  . "$TMP/helpers.sh"
  unset PRIV_READ_MAX_DENIALS PRIV_READ_TTL
  mkdir -p "$TMP/bin8"
  printf '#!/usr/bin/env bash\necho CALL >>"%s/calls8"\nexit 1\n' "$TMP" >"$TMP/bin8/sudo"
  chmod +x "$TMP/bin8/sudo"; PATH="$TMP/bin8:$PATH"
  priv_read "/nonexistent-unreadable/c.json" jq -r .model "/nonexistent-unreadable/c.json" >/dev/null 2>&1
  [[ -s "$TMP/calls8" ]] || return 1
  return 0
}
export XDG_CACHE_HOME="$TMP/cache8"
( run_t8 ) >"$TMP/t8.log" 2>&1; t8=$?
if [[ "$t8" == 0 ]]; then
  ok_t 'T8 escalation still happens with PRIV_READ_MAX_DENIALS unset (bound defaults inside the function)'
else
  bad_t 'T8 an unset bound silently disabled escalation — 0 >= 0 is true; default the bound locally' \
        "$(cat "$TMP/t8.log")"
fi

echo "-----"
echo "agent_priv_read_breaker_unit: $pass passed, $fail failed"
rc=0; [[ $fail -eq 0 ]] || rc=1
exit "$rc"
