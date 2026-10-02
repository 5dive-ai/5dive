#!/usr/bin/env bash
# DIVE-5367: a standard seat's own /account switch and /usage board cross ONE
# exact-path, self-scoped primitive (_self_account). The seat is derived from
# SUDO_UID root-side, so no argument can name another seat.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/self-account.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_account.sh cmd_agent_create.sh; do
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }

# ── the grant ────────────────────────────────────────────────────────────────
SUD=$(render_standard_sudoers agent-tap 0 0)
[[ $(grep -cE '^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _self_account$' <<<"$SUD") == 1 ]] \
  && ok 'exact-path self-account grant is rendered once' || bad 'exact-path self-account grant is rendered once'
[[ $(grep -v '^#' <<<"$SUD" | grep '_self_account') != *'*'* ]] \
  && ok 'self-account grant has no wildcard' || bad 'self-account grant has no wildcard'
# No line names set-account / account usage directly: the only reach is the rail.
grep -v '^#' <<<"$SUD" | grep -qE 'set-account|account usage|account list' \
  && bad 'no direct set-account/account grant' || ok 'no direct set-account/account grant'
# The classifier must still read a freshly rendered file as standard with NO
# unrecognised entry, or every reconciled seat reports a drifted grant (DIVE-3160)
# and `agent _reconcile_sudoers` skips the very seats that need the new line.
[[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
  && ok 'rendered standard grant classifies cli-scoped, extra=0' \
  || bad "rendered standard grant classifies cli-scoped, extra=0 (got $(classify_sudo_grant <<<"$SUD"))"
grep -qF 'command.startswith("/usr/local/bin/5dive _self_account")' "$SRC/cmd_agent.sh" \
  && ok 'python agent-list classifier knows the verb' || bad 'python agent-list classifier knows the verb'

# ── the root half ────────────────────────────────────────────────────────────
CALLS="$TMP/calls"
cmd_account_usage(){ printf 'usage json=%s\n' "$JSON_MODE" >>"$CALLS"; }
cmd_agent_set_account(){ printf 'set %s\n' "$*" >>"$CALLS"; }
with_registry_lock(){ local fn="$1"; shift; "$fn" "$@"; }
_gate_uid_to_agent(){ [[ "$1" == 1042 ]] && printf 'tap' || printf ''; }
_gate_is_root(){ return 0; }
# run_root <sudo_uid> <wire...> — the executor in a subshell (fail exits), wire on stdin
run_root(){
  local uid="$1"; shift
  : >"$CALLS"
  ( export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_self_account_delegated ) >"$TMP/out" 2>&1
}
run_root 1042 json usage;       rc=$?
[[ $rc == 0 && "$(cat "$CALLS")" == 'usage json=1' ]] && ok 'usage reads the board in json' || bad "usage reads the board in json (rc=$rc, $(cat "$CALLS"))"
run_root 1042 text usage;       [[ "$(cat "$CALLS")" == 'usage json=0' ]] && ok 'text mode is honoured' || bad 'text mode is honoured'
run_root 1042 json set mark;    rc=$?
[[ $rc == 0 && "$(cat "$CALLS")" == 'set tap mark' ]] && ok 'set binds the CALLER seat, derived from SUDO_UID' || bad "set binds the caller seat (rc=$rc, $(cat "$CALLS"))"
run_root 1042 json set default; [[ "$(cat "$CALLS")" == 'set tap default' ]] && ok 'set default clears to the box default' || bad 'set default'
# negative controls: nothing reaches the setter
neg(){ local label="$1"; shift; run_root "$@"; local r=$?
  [[ $r != 0 && ! -s "$CALLS" ]] && ok "refused: $label" || bad "refused: $label (rc=$r, $(cat "$CALLS"))"; }
neg 'a second positional cannot smuggle a seat'   1042 json set mark quinn
neg 'an operation outside usage/set'              1042 json add evil
neg 'set-model is not an operation'               1042 json set-model mark opus
neg 'an account name that is not a profile name'  1042 json set '../../etc'
neg 'usage with an argument'                      1042 json usage --history
neg 'a mode other than json/text'                 1042 yaml usage
neg 'an empty wire'                               1042
neg 'SUDO_UID 0 (root itself, not a seat)'        0    json set mark
neg 'a uid that is not an agent seat'             1000 json set mark
neg 'no SUDO_UID'                                 ''   json set mark
: >"$CALLS"; ( export SUDO_UID=1042; printf '%s\0' json usage | cmd_self_account_delegated quinn ) >/dev/null 2>&1; rc=$?
[[ $rc != 0 && ! -s "$CALLS" ]] && ok 'refused: argv (the grant is exact-path, args are never read)' || bad 'refused: argv'
_gate_is_root(){ return 1; }
run_root 1042 json set mark; rc=$?
[[ $rc != 0 && ! -s "$CALLS" ]] && ok 'refused: a non-root caller of the executor' || bad 'refused: a non-root caller of the executor'

# ── the caller half ──────────────────────────────────────────────────────────
WIRE="$TMP/wire"; SUDOS="$TMP/sudos"
GRANTED=1
sudo(){
  printf '%s\n' "$*" >>"$SUDOS"
  if [[ "$2" == "-l" ]]; then [[ "$GRANTED" == 1 && "$3" == /usr/local/bin/5dive && "$4" == _self_account && $# == 4 ]]; return; fi
  python3 -c 'import sys; print(sys.stdin.buffer.read().decode().replace("\0","|"))' >"$WIRE"
  printf '{"ok":true}\n'; return "${CROSS_RC:-0}"
}
_gate_is_root(){ return 1; }
_gate_caller_uid(){ printf 1042; }
cmd_agent_set_account(){ printf 'rootpath %s\n' "$*" >>"$CALLS"; }
: >"$SUDOS"
_self_account_eligible && ok 'granted non-root seat is eligible' || bad 'granted non-root seat is eligible'
GRANTED=0; _self_account_eligible && bad 'ungranted seat is NOT eligible' || ok 'ungranted seat is NOT eligible'
GRANTED=1; _gate_is_root(){ return 0; }
_self_account_eligible && bad 'root never crosses the rail' || ok 'root never crosses the rail'
_gate_is_root(){ return 1; }
SELF_ACCOUNT_DELEGATED=1 _self_account_eligible && bad 'no recursion from the executor' || ok 'no recursion from the executor'

# set-account naming ITSELF crosses; the wire carries mode + op + account only
: >"$CALLS"; : >"$SUDOS"
( JSON_MODE=1; agent_set_account_dispatch tap mark ) >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$WIRE")" == 'json|set|mark|' ]] && ok 'self set-account crosses with json|set|mark' || bad "self set-account crosses (rc=$rc, wire=$(cat "$WIRE"))"
grep -qx -- '-n /usr/local/bin/5dive _self_account' "$SUDOS" && ok 'the crossing is the exact granted argv' || bad "the crossing is the exact granted argv ($(cat "$SUDOS"))"
[[ ! -s "$CALLS" ]] && ok 'self set-account does not also run the root path' || bad 'self set-account does not also run the root path'
# ...and naming ANOTHER seat never touches the rail: it goes to the root path,
# which a standard seat's sudo refuses (the grader's live negative control).
: >"$CALLS"; : >"$SUDOS"; : >"$WIRE"
( agent_set_account_dispatch quinn mark ) >/dev/null 2>&1
[[ "$(cat "$CALLS")" == 'rootpath quinn mark' && ! -s "$WIRE" ]] && ok 'another seat stays on the root path' || bad "another seat stays on the root path ($(cat "$CALLS"))"
grep -q '_self_account$' "$SUDOS" && bad 'another seat never probes or crosses the rail' || ok 'another seat never probes or crosses the rail'
# ungranted seat naming itself: today's path, byte for byte
GRANTED=0; : >"$CALLS"; : >"$WIRE"
( agent_set_account_dispatch tap mark ) >/dev/null 2>&1
[[ "$(cat "$CALLS")" == 'rootpath tap mark' && ! -s "$WIRE" ]] && ok 'ungranted seat keeps today'"'"'s path' || bad 'ungranted seat keeps today'"'"'s path'
GRANTED=1
# a refusal on the root side is the caller's exit status, not a fall-through
: >"$CALLS"; ( CROSS_RC=7; agent_set_account_dispatch tap mark ) >/dev/null 2>&1; rc=$?
[[ $rc == 7 && ! -s "$CALLS" ]] && ok 'a root-side refusal is returned, never retried on the root path' || bad "root-side refusal (rc=$rc, $(cat "$CALLS"))"

# account usage on a granted seat crosses before require_root
require_root(){ printf 'require_root\n' >>"$CALLS"; return 1; }
ensure_state(){ :; }
unset -f cmd_account_usage; source <(sed -n '/^cmd_account_usage()/,/^}/p' "$SRC/cmd_account.sh")
: >"$CALLS"; : >"$WIRE"
( JSON_MODE=1; cmd_account_usage ) >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$WIRE")" == 'json|usage|' && ! -s "$CALLS" ]] && ok 'account usage crosses on a granted seat' || bad "account usage crosses (rc=$rc, wire=$(cat "$WIRE"), $(cat "$CALLS"))"
GRANTED=0; : >"$CALLS"; : >"$WIRE"
( cmd_account_usage ) >/dev/null 2>&1
[[ "$(cat "$CALLS")" == 'require_root' && ! -s "$WIRE" ]] && ok 'account usage on an ungranted seat still requires root' || bad 'account usage on an ungranted seat still requires root'

# the dispatcher reaches the executor, with argv, so it can refuse argv
grep -A8 '^    _self_account)' "$SRC/main.sh" | grep -q 'cmd_self_account_delegated "\$@"' \
  && ok 'main.sh dispatches _self_account with argv' || bad 'main.sh dispatches _self_account with argv'
grep -A3 '^        set-account)' "$SRC/main.sh" | grep -q 'agent_set_account_dispatch "\$@"' \
  && ok 'main.sh routes set-account through the dispatch' || bad 'main.sh routes set-account through the dispatch'

echo "$P passed, $F failed"
(( F == 0 ))
