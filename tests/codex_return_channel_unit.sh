#!/usr/bin/env bash
# DIVE-1535: default a2a return-channel convention seeded into a new codex
# agent's standing instructions. Follow-up to DIVE-1528/DIVE-1410: the push-back
# convention was proven end-to-end but only ever hand-written into andy's
# ~/.codex/AGENTS.md, so every other codex worker booted with no return channel.
#
# Pure test — no root, network, users, or runtime state. Exercises the content
# generator (_codex_operating_baseline_doc) plus the non-destructive guard logic of
# preseed_codex_return_channel with the filesystem primitives stubbed to a temp
# HOME. The real ownership/perms plumbing is covered by the create-path smoke test.
set -euo pipefail

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
trap 'rc=$?; rm -rf "${tmp:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/registry.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh

pass=0
check() { if eval "$2"; then pass=$((pass+1)); else echo "FAIL: $1"; exit 1; fi; }

# --- content generator: all managed operating-baseline concerns ---------------
doc=$(_codex_operating_baseline_doc andy)
check "doc has versioned begin marker" 'grep -q "5dive:codex-operating-baseline:begin v1" <<<"$doc"'
check "doc has the push-back verb"     'grep -q "5dive agent send <from>" <<<"$doc"'
check "doc cites DIVE-1410 rationale"  '[[ "$doc" == *"DIVE-1410"* ]]'
check "doc warns no backticks"         '[[ "$doc" == *"NO backticks"* ]]'
check "doc says when-done not mid-job" '[[ "$doc" == *"not mid-render"* ]]'
check "doc names notify-user"          'grep -q "notify-user" <<<"$doc"'
check "doc names 5dive-cli"            'grep -q "5dive-cli" <<<"$doc"'
check "doc names compile-knowledge"    'grep -q "compile-knowledge" <<<"$doc"'
check "doc carries channel etiquette"  'grep -q "Telegram-paired seat" <<<"$doc"'
check "doc carries model tiering"      'grep -q "## Model tiering" <<<"$doc"'
check "doc carries resume guidance"    'grep -q "## Resuming work" <<<"$doc"'
# A different agent name interpolates through, not a hardcoded "andy".
doc2=$(_codex_operating_baseline_doc worker7)
check "doc interpolates any name"      '[[ "$doc2" == *"You (worker7)"* ]]'

# --- non-destructive + fresh-seed behavior, with primitives stubbed ----------
tmp=$(mktemp -d)
HOME_BASE="$tmp/home"
# Stub the plumbing so preseed_codex_return_channel writes into $tmp, not /home.
id() { return 0; }                                   # user "exists"
install() {                                          # honor -d (mkdir) and file-create
  local mkdir=0 dest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) mkdir=1 ;;
      -m|-o|-g) shift ;;                             # skip mode/owner/group values
      /dev/null) : ;;                                # source placeholder
      *) dest="$1" ;;
    esac
    shift
  done
  [[ "$dest" != "$HOME_BASE/agent-broken-codex/.codex" ]] || return 1
  if (( mkdir )); then mkdir -p "$dest"; else : >"$dest"; fi
}
sudo() {                                             # drop `-u <user>`, run the rest here
  printf '%s\n' "$*" >>"$SUDO_LOG"
  shift 2
  "$@"
}
chmod() { :; }
SUDO_LOG="$tmp/sudo.log"

seed_one() {
  mkdir -p "$HOME_BASE/agent-$1"
  CODEX_AGENT_HOME_ROOT="$HOME_BASE" preseed_codex_return_channel "$1"
}

# fresh agent → file is created with the convention
seed_one fresh
f="$HOME_BASE/agent-fresh/.codex/AGENTS.md"
check "fresh seed creates AGENTS.md"   '[[ -f "$f" ]]'
check "fresh seed has convention"      'grep -q "5dive agent send <from>" "$f"'
check "content write runs as seat"      'grep -q "tee .*\.codex/\.AGENTS\.md" "$SUDO_LOG" && grep -q "mv -f .*\.codex/\.AGENTS\.md" "$SUDO_LOG"'

# curated file already present → preserved outside an appended managed block
mkdir -p "$HOME_BASE/agent-curated/.codex"
printf 'CUSTOM CURATED FILE\n' > "$HOME_BASE/agent-curated/.codex/AGENTS.md"
seed_one curated
cf="$HOME_BASE/agent-curated/.codex/AGENTS.md"
check "curated content survives"       'head -1 "$cf" | grep -qx "CUSTOM CURATED FILE"'
check "managed block is appended"      'grep -q "5dive:codex-operating-baseline:begin v1" "$cf"'

# A second provisioning pass is byte-identical.
before=$(sha256sum "$cf" | awk '{print $1}')
seed_one curated
after=$(sha256sum "$cf" | awk '{print $1}')
check "second seed is idempotent"       '[[ "$before" == "$after" ]]'

# An older managed block is replaced in place while both user-owned sides stay.
legacy="$HOME_BASE/agent-legacy/.codex/AGENTS.md"
mkdir -p "$(dirname "$legacy")"
cat >"$legacy" <<'OLD'
USER BEFORE
<!-- 5dive:codex-operating-baseline:begin v0 -->
obsolete managed content
<!-- 5dive:codex-operating-baseline:end -->
USER AFTER
OLD
seed_one legacy
check "old block upgraded"              'grep -q "begin v1" "$legacy" && ! grep -q "obsolete managed content" "$legacy"'
check "prefix preserved"                'head -1 "$legacy" | grep -qx "USER BEFORE"'
check "suffix preserved"                'tail -1 "$legacy" | grep -qx "USER AFTER"'

# A malformed ownership boundary is refused rather than consuming user text.
broken="$HOME_BASE/agent-broken/.codex/AGENTS.md"
mkdir -p "$(dirname "$broken")"
printf 'KEEP ME\n<!-- 5dive:codex-operating-baseline:begin v0 -->\nNO END\n' >"$broken"
broken_before=$(sha256sum "$broken" | awk '{print $1}')
if seed_one broken; then
  echo "FAIL: malformed block must be refused"
  exit 1
fi
broken_after=$(sha256sum "$broken" | awk '{print $1}')
check "malformed block is untouched"    '[[ "$broken_before" == "$broken_after" ]]'

# A failed read in the unmarked append path must fail without replacing the
# original. This is the short-write/no-space shape from the verifier receipt.
append_fail="$HOME_BASE/append-fail.md"
printf 'ORIGINAL USER TEXT\n' >"$append_fail"
cat() {
  if [[ "${1:-}" == "$append_fail" ]]; then printf 'IRR'; return 1; fi
  command cat "$@"
}
if _codex_sync_operating_baseline_file "$append_fail" append-fail; then
  echo "FAIL: failed append read must be refused"
  exit 1
fi
unset -f cat
check "failed append leaves original"   'grep -qx "ORIGINAL USER TEXT" "$append_fail"'

# The upgrade primitive filters the registry to Codex seats only and reports all
# four outcomes. One fixture starts current and one hits a real install failure,
# so the install-error, accounting, non-zero, and warning branches are live.
mkdir -p "$HOME_BASE/agent-fleet-codex" "$HOME_BASE/agent-current-codex/.codex" "$HOME_BASE/agent-broken-codex" "$HOME_BASE/agent-fleet-claude"
_codex_operating_baseline_doc current-codex >"$HOME_BASE/agent-current-codex/.codex/AGENTS.md"
require_root() { :; }
SYNC_SUMMARY=""
ok() { SYNC_SUMMARY="$1"; }
WARN_LOG="$tmp/warn.log"
WARN_SUMMARY=""
warn() { WARN_SUMMARY="$1"; printf '%s\n' "$*" >>"$WARN_LOG"; }
export CODEX_AGENT_HOME_ROOT="$HOME_BASE"
REGISTRY="$tmp/agents.json"
printf '%s\n' '{"agents":{"fleet-codex":{"type":"codex"},"current-codex":{"type":"codex"},"missing-codex":{"type":"codex"},"broken-codex":{"type":"codex"},"fleet-claude":{"type":"claude"}}}' >"$REGISTRY"
fleet_rc=0
cmd_agent_sync_codex_baseline || fleet_rc=$?
check "upgrade syncs existing codex"    '[[ -f "$HOME_BASE/agent-fleet-codex/.codex/AGENTS.md" ]]'
check "upgrade skips non-codex"         '[[ ! -e "$HOME_BASE/agent-fleet-claude/.codex/AGENTS.md" ]]'
check "failure summary counts all arms" '[[ "$WARN_SUMMARY" == *"updated=1, current=1, skipped=1, failed=1"* ]]'
check "fleet failure returns nonzero"   '[[ "$fleet_rc" -ne 0 ]]'
check "fleet failure warns incomplete" 'grep -q "reconcile incomplete" "$WARN_LOG"'

# The wildcard state is also fail-closed. Route exactly one fixture through an
# impossible success token so mutating the *) arm to current is observable.
real_preseed=$(declare -f preseed_codex_return_channel | sed '1s/preseed_codex_return_channel/_real_preseed_codex_return_channel/')
eval "$real_preseed"
preseed_codex_return_channel() {
  [[ "$1" != "unexpected-codex" ]] || { printf 'impossible-state\n'; return 0; }
  _real_preseed_codex_return_channel "$@"
}
printf '%s\n' '{"agents":{"unexpected-codex":{"type":"codex"}}}' >"$REGISTRY"
: >"$WARN_LOG"; WARN_SUMMARY=""; unexpected_rc=0
cmd_agent_sync_codex_baseline || unexpected_rc=$?
check "unknown state returns nonzero"   '[[ "$unexpected_rc" -ne 0 ]]'
check "unknown state counts failure"    '[[ "$WARN_SUMMARY" == *"updated=0, current=0, skipped=0, failed=1"* ]]'
unset -f preseed_codex_return_channel
eval "$(declare -f _real_preseed_codex_return_channel | sed '1s/_real_preseed_codex_return_channel/preseed_codex_return_channel/')"

# Missing, unreadable, and malformed registries fail loud instead of collapsing
# to a vacuous green fleet pass.
assert_bad_registry() {
  local label="$1"
  : >"$WARN_LOG"
  if cmd_agent_sync_codex_baseline >/dev/null; then
    echo "FAIL: $label registry must refuse"
    exit 1
  fi
  grep -q "reconcile refused" "$WARN_LOG" || { echo "FAIL: $label registry did not warn"; exit 1; }
  pass=$((pass+1))
}
rm -f "$REGISTRY"
assert_bad_registry "missing"
printf '%s' '{"agents":{"broken"' >"$REGISTRY"
assert_bad_registry "malformed"
# Exercise registry_read_checked's documented unreadable outcome directly so
# this arm remains live even when the harness itself runs as root.
real_registry_read_checked=$(declare -f registry_read_checked)
registry_read_checked() { return 4; }
assert_bad_registry "unreadable"
eval "$real_registry_read_checked"

# The installed-upgrade path actually invokes the primitive after bundle swap.
check "installer wires upgrade sync"    'grep -q "agent _sync_codex_baseline" install.sh'

echo "codex_return_channel_unit: ${pass}/${pass} checks passed"
