#!/usr/bin/env bash
# DIVE-4127 unit: the "no memory stores found" error must name --agent=.
#
# WHY THIS EXISTS. The dashboard Memory panel shells out through shelld, which
# execs `sudo -n /usr/local/bin/5dive …` with NO `-u <user>`. sudo's env_reset
# then sets HOME=/root, so `memory search` resolved its stores from
# /root/.claude/projects/*/memory — a path that exists on no box — and every
# search on a box full of memory answered "no memory stores found … pass
# --roots=". The flag that actually fixes it is --agent=<agent> (the documented
# root-only path to a per-user 0600 store); the message never mentioned it, so
# the fix was invisible to the reader of the error.
#
# TWO call sites raise it — `_memory_resolve_roots` (search/get/router) and
# `_memory_doctor` — so this pins BOTH: a message fix that touches one is half a
# fix. Runs against an EMPTY synthetic HOME in a tempdir; no root, no network,
# no real store touched.
#
# Run: bash tests/memory_no_stores_message_unit.sh
#
# TIER: core — pure string + control-flow assertions on a sourced function,
# ~0.1s, no node, no fixtures beyond two empty dirs.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-nostores-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "$SRC/$f"; done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# An empty HOME with no .claude tree at all — exactly what root sees on a box.
export HOME="$TMP/root"
mkdir -p "$HOME"

# _memory_wiki_root() also probes /home/claude/projects/5dive/community/wiki,
# which EXISTS on internal fleet boxes and would hand the resolver a root. Point
# the wiki probe's $HOME-side path at nothing and neutralise the hardcoded one by
# overriding the resolver for this harness: the property under test is the
# message raised when NO root resolves, not where the wiki lives.
_memory_wiki_root() { echo ""; }

# --- site 1: _memory_resolve_roots (search / get / router) ------------------
out="$( _memory_resolve_roots "all" "" "" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok_t "resolve_roots fails when no store resolves (rc=$rc)"
else bad_t "resolve_roots fails when no store resolves" "rc=0, out=$out"; fi

case "$out" in
  *"--agent="*) ok_t "resolve_roots message names --agent=" ;;
  *)            bad_t "resolve_roots message names --agent=" "got: $out" ;;
esac
case "$out" in
  *"--roots="*) ok_t "resolve_roots message still offers --roots=" ;;
  *)            bad_t "resolve_roots message still offers --roots=" "got: $out" ;;
esac
# The old text read as if --roots were the ONLY way out. --agent must come first.
a_at=${out%%--agent=*}; r_at=${out%%--roots=*}
if [ ${#a_at} -lt ${#r_at} ]; then ok_t "--agent= is offered BEFORE --roots="
else bad_t "--agent= is offered BEFORE --roots=" "got: $out"; fi

# --- site 2: _memory_doctor -------------------------------------------------
out2="$( _memory_doctor 2>&1 )"; rc2=$?
if [ "$rc2" -ne 0 ]; then ok_t "memory doctor fails when no store resolves (rc=$rc2)"
else bad_t "memory doctor fails when no store resolves" "rc=0, out=$out2"; fi
case "$out2" in
  *"--agent="*) ok_t "memory doctor message names --agent= too (both call sites)" ;;
  *)            bad_t "memory doctor message names --agent= too (both call sites)" "got: $out2" ;;
esac

# --- control: a store that DOES resolve must not raise the error ------------
mkdir -p "$HOME/.claude/projects/-home-demo/memory"
out3="$( _memory_resolve_roots "mine" "" "" 2>&1 )"; rc3=$?
if [ "$rc3" -eq 0 ] && [ "$out3" = "$HOME/.claude/projects/-home-demo/memory" ]; then
  ok_t "control: a real store resolves and raises nothing"
else
  bad_t "control: a real store resolves and raises nothing" "rc=$rc3 out=$out3"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
