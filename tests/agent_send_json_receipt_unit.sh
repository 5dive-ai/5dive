#!/usr/bin/env bash
# CORE (the default tier): 3.1s measured on this host, 2026-09-22. It grades the
# rc=0 receipt of `agent send` — the one surface every scheduled caller parses —
# and a diff to cmd_send's renderer is exactly what a PR can break silently.
# DIVE-2362 / DIVE-4214 — `agent send --json` must PRINT its rc=0 receipt.
#
# THE DEFECT THIS CLOSES. The ordinary `sent:true` receipt was a single jq object
# literal whose optional values read `($x|select(length>0))`. `select` on an
# empty string yields `empty`, and jq discards the WHOLE object when any
# constructed value is `empty` — so on the common send (no --wake, so
# AGENT_WAKE_READY is unset; no --reply-to-*) `--json` printed NOTHING on stdout
# with rc 0. Measured on 0.48.0: a caller that reads the receipt to confirm
# delivery saw an empty stdout, re-sent, and the target received the message
# twice. Recorded on DIVE-4214's body, named in the comment DIVE-4769 left at
# the receipt, and the reason tests/a2a_busy_queue_unit.sh had to assert its
# success case on the prose line.
#
# WHAT THIS GRADES:
#   * a plain `--json` send to an idle seat prints EXACTLY ONE line, and it is a
#     parseable {ok:true,data:{sent:true,…}} envelope;
#   * the same for the maximally-empty send (`--raw`: no sender, no msg_id, no
#     ready, no reply target), which is the shape furthest from renderable;
#   * an empty optional is OMITTED rather than annihilating the object, and a
#     populated one is PRESENT;
#   * the key ORDER is the order the pre-fix literal published, because a caller
#     that diffs the receipt text is the caller this receipt exists for;
#   * the wake path still reports `ready` — proven and unprovable both;
#   * the prose line is untouched;
#   * the DIVE-4769 urgent receipt is not disturbed (control);
#   * the MUTANT arm: the pre-fix expression, rendered through the same ok() with
#     the same inputs, still prints nothing — so the arms above separate fixed
#     from broken rather than passing against either;
#   * the PRISTINE arm: none of this reads a path this box happens to have.
#
# Boundaries only are stubbed: tmux, `sudo` (reduced to "drop the -u <user>
# prefix and run it here"), the idle predicate, the unit start behind --wake and
# the prompt-detectability probe. cmd_send, agent_wake_gate_ready, ok() and the
# jq expression itself stay REAL — mutating the renderer makes this red.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMPROOT="$(mktemp -d)"
# Exported BEFORE src/header.sh is sourced, because both are resolved once at
# source time. This is the PRISTINE-CI control written as configuration rather
# than as a comment: CI has no /var/lib/5dive and no /etc/5dive, so an arm that
# reached for either would pass here and fail there (DIVE-562). T9 asserts it.
export STATE_DIR="${TMPROOT}/state"
export FIVEDIVE_CONNECTOR_DIR="${TMPROOT}/connectors"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# Point the urgent budget ledger at the throwaway root before the runtime is
# sourced — the path is resolved once, at definition (tests/a2a_urgent_interrupt_unit.sh).
export A2A_URGENT_LEDGER="${TMPROOT}/a2a-urgent.tsv"
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

PASS=0; FAIL=0
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-2362}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}
# Lines in a captured stdout. Command substitution strips the trailing newline,
# so `wc -l` reads 0 for a one-line receipt AND 0 for no receipt at all — the
# two outcomes this whole harness exists to tell apart. Count explicitly.
line_count() { if [[ -z "$1" ]]; then printf '0\n'; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
# Read one data key, distinguishing ABSENT from a falsy value. `// "ABSENT"` is
# the wrong tool here: jq's alternative operator fires on `false` as well as on
# null, so `woken:false` would read as absent — which is the exact confusion
# this receipt is being fixed for.
dget() {
  jq -r --arg k "$1" 'if (.data|has($k)) then (.data[$k]|tostring) else "ABSENT" end' <<<"$2" 2>/dev/null \
    || printf 'UNPARSEABLE\n'
}
keys_of() { jq -r '.data|keys_unsorted|join(",")' <<<"$1" 2>/dev/null || printf 'UNPARSEABLE\n'; }

TYPED="${TMPROOT}/typed.log"; : >"$TYPED"

# --- boundaries -------------------------------------------------------------
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
# NO_SESSION drives cmd_send down the --wake branch: `has-session` is the only
# probe that decides it, so failing just that one subcommand is the whole stub.
tmux() {
  if [[ "${1:-}" == "has-session" && -n "${NO_SESSION:-}" ]]; then return 1; fi
  printf 'TMUX %s\n' "$*" >>"$TYPED"
  return 0
}
# The unit start is a boundary; the READINESS VERDICT is not. agent_wake_gate_ready
# stays real and still owns the `ready` claim, so the two values it can publish are
# driven from the one probe it asks — whether this runtime has a detectable prompt.
agent_wake_for_send()    { return 0; }
agent_prompt_detectable(){ [[ "${PROMPT_DETECTABLE:-1}" == "1" ]]; }
wait_agent_input_ready() { return 0; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '2362\n'; }
_hb_verify_submit()       { return 0; }
_wedge_clear()            { :; }
require_agent()           { :; }
mirror_interagent_outbound() { :; }
_buzz_mirror_outbound()   { :; }
_agent_send_row_hint()    { :; }
_agent_body_shell_hint()  { :; }
a2a_needs_scoped()        { return 1; }
a2a_round_guard()         { return 0; }
envelope_tier()           { printf 'admin\n'; }
envelope_via()            { :; }
envelope_provenance()     { printf 'derived\n'; }
_envelope_caller()        { printf 'ops\n'; }
gen_msg_id()              { printf 'r2362\n'; }
# Same stub as tests/a2a_busy_queue_unit.sh: the peer-forgery guard resolves
# `envelope_peer_forgery` from a lib this harness does not source, and a 127
# inside it aborts the send under errexit — a harness fault that would read as a
# send failure.
_agent_refuse_peer_forgery() { :; }
audit_log()               { :; }
_hb_agent_idle() { return "${IDLE_RC:-0}"; }

reset_arm() { : >"$TYPED"; rm -rf "${TMPROOT}/agent-quinn"; : >"$A2A_URGENT_LEDGER"; }
# The payload the pane was actually told to type, so `bytes` is graded against
# the delivered text rather than against a number copied into this file.
typed_payload() { sed -n 's/^TMUX send-keys -t agent-[^ ]* -l -- //p' "$TYPED" | head -1; }

# --- T1: the receipt EXISTS on the ordinary send -----------------------------
# The regression, stated as the caller's question: "did it go?" `ready` and both
# reply targets are empty here — no --wake, no --reply-to-* — which is the shape
# of nearly every seat-to-seat send, and was exactly the shape that printed
# nothing at all.
reset_arm
out="$(IDLE_RC=0 JSON_MODE=1 cmd_send quinn --message="ping" 2>/dev/null)"
is "T1: exactly one line on stdout" "1"     "$(line_count "$out")"
is "T1: ok:true"                    "true"  "$(jq -r '.ok|tostring' <<<"$out" 2>/dev/null || printf 'UNPARSEABLE\n')"
is "T1: sent:true"                  "true"  "$(dget sent "$out")"
is "T1: name is the target"         "quinn" "$(dget name "$out")"
is "T1: woken:false"                "false" "$(dget woken "$out")"
is "T1: msg_id is carried"          "r2362" "$(dget msg_id "$out")"
is "T1: from is carried"            "ops"   "$(dget from "$out")"
# `bytes` counts the WRAPPED payload — the envelope this send actually typed,
# not the bare --message. Graded against the pane, not against a literal.
is "T1: bytes counts the typed payload" "$(printf '%s' "$(typed_payload)" | wc -c | tr -d ' ')" \
   "$(dget bytes "$out")"

# --- T2: an empty optional is OMITTED, not annihilating ----------------------
# has_key rather than a null read, because "the key is absent" and "the key is
# null" are the same jq answer and only the first one is the contract.
for k in ready reply_to_chat reply_to_msg; do
  is "T2: ${k} is absent when empty" "false" \
     "$(jq -r --arg k "$k" '.data|has($k)|tostring' <<<"$out" 2>/dev/null || printf 'UNPARSEABLE\n')"
done

# --- T3: the key ORDER the pre-fix literal published -------------------------
# DIVE-2362 promised byte compatibility on this receipt. The additive form keeps
# the half of that promise a caller can observe: same keys, same order, minus
# the ones that were never renderable in the first place.
is "T3: key order on the ordinary send" "name,sent,bytes,woken,from,msg_id" "$(keys_of "$out")"

# --- T4: --raw, the maximally-empty receipt ---------------------------------
# No envelope, so no sender and no msg_id either: FOUR of the nine keys are
# empty at once. If any shape still annihilates the object it is this one.
reset_arm
out="$(IDLE_RC=0 JSON_MODE=1 cmd_send quinn --raw --message="ping" 2>/dev/null)"
is "T4: one line"                "1"     "$(line_count "$out")"
is "T4: sent:true"               "true"  "$(dget sent "$out")"
is "T4: bytes is the bare body"  "4"     "$(dget bytes "$out")"
is "T4: from is absent"          "false" "$(jq -r '.data|has("from")|tostring' <<<"$out" 2>/dev/null || printf 'UNPARSEABLE\n')"
is "T4: msg_id is absent"        "false" "$(jq -r '.data|has("msg_id")|tostring' <<<"$out" 2>/dev/null || printf 'UNPARSEABLE\n')"
is "T4: key order"               "name,sent,bytes,woken" "$(keys_of "$out")"

# --- T5: every optional populated -------------------------------------------
reset_arm
out="$(NO_SESSION=1 PROMPT_DETECTABLE=1 IDLE_RC=0 JSON_MODE=1 \
       cmd_send quinn --wake --message="ping" --reply-to-chat=6140 --reply-to-msg=99 2>/dev/null)"
is "T5: one line"          "1"      "$(line_count "$out")"
is "T5: woken:true"        "true"   "$(dget woken "$out")"
is "T5: ready:proven"      "proven" "$(dget ready "$out")"
is "T5: reply_to_chat"     "6140"   "$(dget reply_to_chat "$out")"
is "T5: reply_to_msg"      "99"     "$(dget reply_to_msg "$out")"
is "T5: the full key order" "name,sent,bytes,woken,ready,from,msg_id,reply_to_chat,reply_to_msg" \
   "$(keys_of "$out")"

# --- T6: ready=unprovable is a receipt, not a silence ------------------------
# The whole point of the field (DIVE-2385): a scheduler must be able to tell a
# proven delivery from an assumed one. While the object was being dropped it
# could tell neither, and both read as the same empty stdout.
reset_arm
out="$(NO_SESSION=1 PROMPT_DETECTABLE=0 IDLE_RC=0 JSON_MODE=1 cmd_send quinn --wake --message="ping" 2>/dev/null)"
is "T6: one line"          "1"           "$(line_count "$out")"
is "T6: ready:unprovable"  "unprovable"  "$(dget ready "$out")"

# --- T7: the prose line is untouched ----------------------------------------
reset_arm
prose="$(IDLE_RC=0 cmd_send quinn --message="ping" 2>/dev/null | tail -1)"
is "T7: prose is byte-identical" "OK — sent to agent 'quinn'." "$prose"

# --- T8: control — the DIVE-4769 urgent receipt is not disturbed -------------
reset_arm
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send quinn --urgent --message="ping" 2>/dev/null)"
is "T8: urgent one line"   "1"    "$(line_count "$out")"
is "T8: urgent sent:true"  "true" "$(dget sent "$out")"
is "T8: urgent:true"       "true" "$(dget urgent "$out")"

# --- T9: the MUTANT arm ------------------------------------------------------
# The pre-fix expression, handed to the SAME ok() with the SAME empty optionals.
# If it printed an envelope, every arm above would be vacuous — they would pass
# against the broken renderer too. It must print nothing, rc 0: that is the
# defect in one line, and the reason a caller re-sent.
mutant="$(JSON_MODE=1 ok "sent to agent 'quinn'." \
  '{name:$n, sent:true, bytes:($p|length), woken:($w=="1"), ready:($rd|select(length>0)), from:($s|select(length>0)), msg_id:($i|select(length>0)), reply_to_chat:($rc|select(length>0)), reply_to_msg:($rm|select(length>0))}' \
  --arg n quinn --arg p ping --arg s ops --arg i r2362 --arg rc "" --arg rm "" --arg w 0 --arg rd "" 2>/dev/null)"
is "T9: the pre-fix expression renders NOTHING" "0" "$(line_count "$mutant")"
# And the shipped form renders the envelope from byte-identical inputs.
fixed="$(JSON_MODE=1 ok "sent to agent 'quinn'." \
  '({name:$n, sent:true, bytes:($p|length), woken:($w=="1")}
    + (if ($rd|length) > 0 then {ready:$rd} else {} end)
    + (if ($s|length) > 0 then {from:$s} else {} end)
    + (if ($i|length) > 0 then {msg_id:$i} else {} end)
    + (if ($rc|length) > 0 then {reply_to_chat:$rc} else {} end)
    + (if ($rm|length) > 0 then {reply_to_msg:$rm} else {} end))' \
  --arg n quinn --arg p ping --arg s ops --arg i r2362 --arg rc "" --arg rm "" --arg w 0 --arg rd "" 2>/dev/null)"
is "T9: the shipped form renders one line" "1" "$(line_count "$fixed")"

# --- T10: the PRISTINE arm ---------------------------------------------------
# CI has no /usr/local/bin/5dive, no /etc/5dive and no /var/lib/5dive. Assert it
# rather than trust it: the state roots resolved into the throwaway root and do
# not even exist on disk, /usr/local/{bin,sbin} are off PATH, and T1 still holds.
is "T10: STATE_DIR is the throwaway root" "${TMPROOT}/state"      "$STATE_DIR"
is "T10: CONNECTORS_DIR likewise"         "${TMPROOT}/connectors" "$CONNECTORS_DIR"
is "T10: and neither exists on disk"      "absent" \
   "$( [[ -e "$STATE_DIR" || -e "$CONNECTORS_DIR" ]] && printf 'present\n' || printf 'absent\n' )"
reset_arm
# Built in-shell rather than with a `grep -vx` pipeline in a `$( )`. That pipeline
# is an unguarded probe substitution (DIVE-4811): on the no-match path — a PATH
# made of nothing but those two directories — grep exits 1, `pipefail` carries it
# out of the substitution, and `set -e` kills the harness with nothing printed.
# The loop states the post-condition directly instead: every PATH element except
# the two an install would put a `5dive` in.
_pristine_path=""
IFS=: read -ra _path_parts <<<"$PATH"
for _p in "${_path_parts[@]}"; do
  [[ "$_p" == /usr/local/bin || "$_p" == /usr/local/sbin ]] && continue
  _pristine_path="${_pristine_path:+${_pristine_path}:}${_p}"
done
out="$(PATH="$_pristine_path" IDLE_RC=0 JSON_MODE=1 cmd_send quinn --message="ping" 2>/dev/null)"
is "T10: no 5dive on PATH: still one line" "1"    "$(line_count "$out")"
is "T10: no 5dive on PATH: still sent:true" "true" "$(dget sent "$out")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
