#!/usr/bin/env bash
# DIVE-2135 unit harness: the PRIVILEGED sudo-grant fallback.
#
# The defect this pins: DIVE-2079/2088 made `agent info` and `agent list` report
# the MEASURED grant instead of the stored label, but the measurement was
# caller-scoped and /etc/sudoers.d is 0700 root — so every PEER read `unknown`
# for every realistic caller (measured by olivia 2026-07-27 as agent-olivia and
# as `claude`, the dashboard's caller). Honest, but the three-populations-
# render-identically problem was only un-lied-about, not solved.
#
# What must hold, and in BOTH directions:
#   * a granted privileged read turns `unknown` into the real class;
#   * a DENIED, unavailable, or TRUNCATED read stays `unknown` — never the
#     stored label, never a measured `none` (DIVE-2120 absent-vs-forbidden);
#   * `list` pays ONE privileged exec for the whole fleet, `info` pays one per
#     call, and a half-covered batch never lets uncovered rows inherit covered
#     ones.
#
# CALLER-INDEPENDENCE IS THE POINT OF THE FIXTURES. This feature's whole subject
# is that the same command is a different instrument depending on who runs it,
# so a harness that inherits the runner's sudo policy would grade the runner.
# Two devices keep that out: SUDOERS_D points at a directory that does NOT
# exist (so the plain read fails identically for root and for an agent), and
# `sudoers_privileged_dump` — the single seam where a privileged read is
# attempted — is stubbed. Section 5 is the ONE place real sudo is touched, and
# it asserts an invariant that is true for every caller.
#
# Run: bash tests/agent_sudo_fallback_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-sudo-fallback-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

# --- degrade, do not crash ---------------------------------------------------
# Run against a tree WITHOUT the fallback (the control this harness has to be
# able to red against), every name below is undefined and `set -u` would abort
# on the first one — an unbound-variable crash proves nothing about behaviour.
# These shims exist ONLY so the pre-fix tree fails through the ASSERTIONS, as
# `unknown` where a measurement was expected. They never fire on a tree that has
# the feature, so they cannot mask a regression in it.
: "${_SUDOERS_DUMP_OK:====5DIVE-SUDOERS-DUMP-OK}"
: "${_SUDOERS_DUMP_END:====5DIVE-SUDOERS-DUMP-END}"
: "${_SUDOERS_DUMP_FILE:====5DIVE-SUDOERS-FILE:}"
command -v sudo_grant_batch_load  >/dev/null || sudo_grant_batch_load()  { :; }
command -v sudo_grant_batch_reset >/dev/null || sudo_grant_batch_reset() { :; }
command -v _sudoers_dump_valid    >/dev/null || _sudoers_dump_valid()    { return 1; }
batch_state() { printf '%s' "${_SUDOERS_BATCH_STATE:-<absent>}"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
isnt() { [[ "$2" != "$3" ]] && ok "$1" || bad "$1" "anything but '$3'" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }

# A directory that does not exist: the plain, caller-scoped read fails here for
# EVERY caller, which is the state a non-root caller is really in against the
# 0700 /etc/sudoers.d. Nothing in this harness ever creates it.
export SUDOERS_D="$TMP/unreadable.d"

# --- the seam -----------------------------------------------------------------
# Stubs stand in for the one privileged exec. DUMP_MODE selects what the box
# would have answered; DUMP_CALLS counts execs, which is the cost assertion.
# The counter lives in a FILE, not a variable: every lookup under test runs in a
# command-substitution subshell, so an in-memory counter would read 0 forever
# and the cost assertions would pass vacuously against any number of execs.
DUMP_CALLS_FILE="$TMP/dump-calls"; : > "$DUMP_CALLS_FILE"
DUMP_MODE=granted
dump_calls() { wc -l < "$DUMP_CALLS_FILE" | tr -d ' '; }
sudoers_privileged_dump() {
  local dir="$1" one="${2:-}"
  echo x >> "$DUMP_CALLS_FILE"
  case "$DUMP_MODE" in
    denied)    return 1 ;;                       # sudo -n refused / not installed
    granted)   ;;
    truncated) ;;                                # dies mid-dump: no END marker
    *)         return 1 ;;
  esac
  printf '%s\n' "$_SUDOERS_DUMP_OK"
  _emit_one() {
    case "$1" in
      agent-legacyfull) printf '%s%s\n' "$_SUDOERS_DUMP_FILE" "$1"
                        printf 'agent-legacyfull ALL=(ALL) NOPASSWD: ALL\n' ;;
      agent-scoped)     printf '%s%s\n' "$_SUDOERS_DUMP_FILE" "$1"
                        printf 'agent-scoped ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *\n' ;;
      agent-narrow)     printf '%s%s\n' "$_SUDOERS_DUMP_FILE" "$1"
                        printf 'agent-narrow ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _deliver *\n' ;;
      *)                : ;;                     # no drop-in for this user
    esac
  }
  if [[ -n "$one" ]]; then
    _emit_one "$one"
  else
    _emit_one agent-legacyfull
    [[ "$DUMP_MODE" == truncated ]] && return 0   # <- cut off BEFORE the END marker
    _emit_one agent-scoped
    _emit_one agent-narrow
  fi
  [[ "$DUMP_MODE" == truncated ]] && return 0
  printf '%s\n' "$_SUDOERS_DUMP_END"
}
reset_seam() { : > "$DUMP_CALLS_FILE"; sudo_grant_batch_reset; }

# ---------------------------------------------------------------------------
# 1. The per-agent path (`agent info`): a granted read turns unknown into the
#    real class; a denied one stays unknown.
# ---------------------------------------------------------------------------
echo "1. sudo_grant_lines — privileged fallback, granted vs denied"

reset_seam; DUMP_MODE=denied
is "denied read  -> rc=1 (unmeasurable)"        "$(sudo_grant_lines agent-scoped >/dev/null 2>&1; echo $?)" "1"
is "denied read  -> agent_sudo_grant unknown"   "$(agent_sudo_grant agent-scoped)" "unknown|-|0"
is "denied read  -> implied isolation unknown"  "$(isolation_implied_by_grant unknown)" "unknown"
# The rule this feature exists to not break: absence of a measurement must never
# be rendered as the stored label OR as a measured `none`.
isnt "denied read  -> NOT the stored label"     "$(isolation_implied_by_grant "$(agent_sudo_grant agent-scoped | cut -d'|' -f1)")" "admin"
isnt "denied read  -> NOT a measured none"      "$(agent_sudo_grant agent-scoped)" "none|-|0"

reset_seam; DUMP_MODE=granted
is "granted read -> legacy blanket is root-all" "$(agent_sudo_grant agent-legacyfull)" "root-all|any|0"
is "granted read -> CLI grant is cli-root"      "$(agent_sudo_grant agent-scoped)" "cli-root|root|0"
is "granted read -> scoped grant is cli-scoped" "$(agent_sudo_grant agent-narrow)" "cli-scoped|root|0"
# The dump covered the whole directory and holds no file for this user, so
# `none` here is a MEASUREMENT, not a guess.
is "granted read -> no drop-in is a real none"  "$(agent_sudo_grant agent-absent)" "none|-|0"
is "info pays one exec per lookup"              "$(dump_calls)" "4"

# ---------------------------------------------------------------------------
# 2. The batched path (`agent list`): ONE exec for the whole fleet.
# ---------------------------------------------------------------------------
echo "2. sudo_grant_batch_load — one privileged exec for the survey"

reset_seam; DUMP_MODE=granted
sudo_grant_batch_load
is "batch loads"                                "$(batch_state)" "ok"
is "batch: legacy blanket"                      "$(agent_sudo_grant agent-legacyfull)" "root-all|any|0"
is "batch: CLI grant"                           "$(agent_sudo_grant agent-scoped)" "cli-root|root|0"
is "batch: scoped grant"                        "$(agent_sudo_grant agent-narrow)" "cli-scoped|root|0"
is "batch: no drop-in is a real none"           "$(agent_sudo_grant agent-absent)" "none|-|0"
is "FOUR lookups still cost ONE exec"           "$(dump_calls)" "1"
sudo_grant_batch_load
is "re-load is idempotent, no second exec"      "$(dump_calls)" "1"

# ---------------------------------------------------------------------------
# 3. A batch that FAILS or half-succeeds. This is the constraint olivia wrote
#    into the ticket: batching must not weaken absent-vs-forbidden.
# ---------------------------------------------------------------------------
echo "3. failed / truncated batch — every row unknown, never a label, never none"

reset_seam; DUMP_MODE=denied
sudo_grant_batch_load
is "denied batch is remembered as failed"       "$(batch_state)" "failed"
is "denied batch: row 1 unknown"                "$(agent_sudo_grant agent-legacyfull)" "unknown|-|0"
is "denied batch: row 2 unknown"                "$(agent_sudo_grant agent-scoped)" "unknown|-|0"
isnt "denied batch: never a measured none"      "$(agent_sudo_grant agent-absent)" "none|-|0"
is "denied batch: absent row also unknown"      "$(agent_sudo_grant agent-absent)" "unknown|-|0"
is "failure is not re-probed once per row"      "$(dump_calls)" "1"

reset_seam; DUMP_MODE=truncated
sudo_grant_batch_load
is "truncated batch is failed, not partial"     "$(batch_state)" "failed"
# agent-legacyfull WAS in the truncated output. Trusting it would be exactly the
# "rows it could not cover inherit the rows it could" defect: without the END
# marker there is no evidence the dir was fully seen, so nothing is trusted.
is "covered-but-unconfirmed row is unknown"     "$(agent_sudo_grant agent-legacyfull)" "unknown|-|0"
is "uncovered row is unknown"                   "$(agent_sudo_grant agent-narrow)" "unknown|-|0"

# ---------------------------------------------------------------------------
# 4. cmd_list end to end — what the dashboard and the table actually render.
# ---------------------------------------------------------------------------
echo "4. agent list — the survey surface, granted vs denied"

REG=$(jq -nc '{agents: {
  legacyfull: {type:"claude", channels:"none", isolation:"admin", createdAt:"2026-05-15"},
  scoped:     {type:"claude", channels:"none", isolation:"admin", createdAt:"2026-07-22"},
  narrow:     {type:"claude", channels:"none", isolation:"admin", createdAt:"2026-07-22"}
}}')
ensure_state_ro()      { :; }
registry_read()        { printf '%s\n' "$REG"; }
systemctl() {
  local u
  for u in legacyfull scoped narrow; do
    printf 'Id=5dive-agent@%s.service\nActiveState=active\nUnitFileState=enabled\n\n' "$u"
  done
}
resolve_agent_model()  { printf ''; }
resolve_agent_effort() { printf ''; }
DEFAULT_WORKDIR="/home/claude/projects"
JSON_MODE=1
g() { jq -r --arg n "$1" ".data[] | select(.name==\$n) | $2" <<<"$out"; }

reset_seam; DUMP_MODE=granted
out=$(cmd_list 2>/dev/null)
is "list: legacy row is measured"               "$(g legacyfull .sudo.measured)" "true"
is "list: legacy row is root-all"               "$(g legacyfull .sudo.grant)" "root-all"
is "list: legacy row DIVERGES from admin"       "$(g legacyfull .sudo.diverges)" "true"
is "list: scoped row agrees with its label"     "$(g scoped .sudo.diverges)" "false"
is "list: narrow row is cli-scoped"             "$(g narrow .sudo.grant)" "cli-scoped"
# The reason this ticket exists: three identically-labelled agents are now
# distinguishable to a PEER caller, which is what `unknown` could never do.
is "three admin labels, three measurements" \
   "$(g legacyfull .sudo.grant)/$(g scoped .sudo.grant)/$(g narrow .sudo.grant)" \
   "root-all/cli-root/cli-scoped"
is "whole 3-agent survey costs ONE exec"        "$(dump_calls)" "1"

reset_seam; DUMP_MODE=denied
out=$(cmd_list 2>/dev/null)
is "denied list: legacy row unmeasured"         "$(g legacyfull .sudo.measured)" "false"
is "denied list: grant reads unknown"           "$(g legacyfull .sudo.grant)" "unknown"
is "denied list: label still carried separately" "$(g legacyfull .isolation)" "admin"
# `diverges` must stay false: absence of evidence is not evidence of divergence.
is "denied list: never claims divergence"       "$(g legacyfull .sudo.diverges)" "false"
isnt "denied list: implied is NOT the label"    "$(g legacyfull .sudo.impliedIsolation)" "admin"
is "denied list: still ONE attempt, not 3"      "$(dump_calls)" "1"

JSON_MODE=0
reset_seam; DUMP_MODE=denied
out=$(cmd_list 2>/dev/null)
has "denied table: SUDO column reads unknown"   "$out" "unknown"
has "denied table: legend explains unknown"     "$out" "grant not measurable"

# ---------------------------------------------------------------------------
# 5. The ONE real-sudo probe. Its assertion is deliberately an INVARIANT rather
#    than a fixed value, because the honest answer here differs by caller —
#    root and a scoped agent are both refused by design, `claude` is not — and a
#    test that pinned one caller's answer would red on another's box for no
#    defect. What must hold for everyone: a dump either validates or is refused,
#    and refusal never produces a class.
# ---------------------------------------------------------------------------
echo "5. real sudo — the invariant that holds for every caller"

unset -f sudoers_privileged_dump
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"   # restore the real seam
sudo_grant_batch_reset
real_dump=$(sudoers_privileged_dump /etc/sudoers.d 2>/dev/null); real_rc=$?
if (( real_rc == 0 )); then
  is "granted here ($(id -un)): dump is complete" \
     "$(_sudoers_dump_valid "$real_dump" && echo valid || echo invalid)" "valid"
else
  ok "refused here ($(id -un)): rc=$real_rc, as root and scoped agents both are"
fi
SUDOERS_D=/etc/sudoers.d
peer=$(agent_sudo_grant "root" | cut -d'|' -f1)
case "$peer" in
  unknown|root-all|cli-root|cli-scoped|none|custom) ok "peer measurement is a legal value ($peer)" ;;
  *) bad "peer measurement is a legal value" "one of the documented classes" "$peer" ;;
esac
is "unknown never derives a confident label"    "$(isolation_implied_by_grant unknown)" "unknown"

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
