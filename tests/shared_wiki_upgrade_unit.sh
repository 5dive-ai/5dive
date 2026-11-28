#!/usr/bin/env bash
# DIVE-9481 — the shared team wiki reaches boxes that only ever UPGRADE.
#
# DIVE-4128 created /var/lib/5dive/wiki in install.sh's full-install path only.
# The --upgrade branch (what nightly `self-update` runs) exits before reaching
# it, so a box installed before 2026-09-10 never got a wiki: `memory add
# --store=wiki` refused and the MCP wiki tool answered "This team has no shared
# wiki yet." (13 of 54 prod boxes on 2026-11-28).
#
# The block is extracted VERBATIM from install.sh (its >>> / <<< markers):
#   U1  no wiki dir -> the dir appears, mode 2775, owner root group claude asked for
#   U2  index.md is seeded, mode 664, chowned root:claude, with the publish hint
#   U3  run again over an existing wiki -> idempotent: a page and an edited index survive
#   U4  a fleet box (the product repo's community/wiki exists) -> nothing created
#   U5  install failing (no `claude` group) -> non-zero return, no exit of the caller
#   W1  the --upgrade branch calls it before its `exit 0`, behind a warn-only `||`
#   W2  the full install calls it once, outside the upgrade branch
#   W3  the inline DIVE-4128 block is gone (one copy, in the function)
# [D] = red on the pre-fix tree (no function, no upgrade call). Ownership is
# recorded through stubbed install/chown (no root here); the mode bits are real.
# Run: bash tests/shared_wiki_upgrade_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shared-wiki-upgrade.XXXXXX")"

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BLOCK="$TMP/block.sh"
sed -n '/^# >>> DIVE-4128 shared wiki/,/^# <<< DIVE-4128 shared wiki/p' install.sh >"$BLOCK"
[[ -s "$BLOCK" ]] && grep -q '^_shared_wiki_ensure()' "$BLOCK" \
  && ok_t "[D] the function is in install.sh between its markers" \
  || { bad_t "[D] the function is in install.sh between its markers" "extracted nothing"; echo "TESTS pass=$pass fail=$fail"; exit 1; }

# run_block <state_dir> [fleet_dir] — sources the block in a subshell with
# install/chown stubbed to record the owner/group asked for and drop it (no
# root). Sets RC, OUT, ERR, CALLS.
run_block() {
  : >"$TMP/calls"
  ( STATE_DIR="$1"
    FIVEDIVE_FLEET_WIKI_DIR="${2:-$TMP/no-fleet-checkout}"
    ok() { echo "  ✓ $*"; }
    install() {
      local out=()
      while (( $# )); do
        case "$1" in
          -o|-g) printf 'install %s %s\n' "$1" "$2" >>"$TMP/calls"; shift 2; continue ;;
        esac
        out+=("$1"); shift
      done
      [[ "${STUB_INSTALL_RC:-0}" == 0 ]] || { echo "install: invalid group 'claude'" >&2; return 1; }
      command install "${out[@]}"
    }
    chown() { printf 'chown %s\n' "$*" >>"$TMP/calls"; }
    # shellcheck source=/dev/null
    source "$BLOCK"
    _shared_wiki_ensure
    echo "after-call"   # proves a failure returns instead of exiting the caller
  ) >"$TMP/out" 2>"$TMP/err"; RC=$?
  OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); CALLS=$(cat "$TMP/calls")
}
mode() { stat -c '%a' "$1" 2>/dev/null; }

# --- U1/U2: a pre-09-10 box: state dir, no wiki -----------------------------
S1="$TMP/state1"; mkdir -p "$S1"
run_block "$S1"
if [[ $RC -eq 0 && -d "$S1/wiki" && "$(mode "$S1/wiki")" == 2775 ]] \
   && grep -qx 'install -o root' <<<"$CALLS" && grep -qx 'install -g claude' <<<"$CALLS"; then
  ok_t "[D] U1 no wiki -> STATE_DIR/wiki created 2775, root:claude asked for"
else
  bad_t "[D] U1 no wiki -> wiki created 2775 root:claude" "rc=$RC mode=$(mode "$S1/wiki") calls=$(tr '\n' ' ' <<<"$CALLS") err=$ERR"
fi
if [[ -f "$S1/wiki/index.md" && "$(mode "$S1/wiki/index.md")" == 664 ]] \
   && grep -qx "chown root:claude $S1/wiki/index.md" <<<"$CALLS" \
   && grep -q '^# Team wiki' "$S1/wiki/index.md" \
   && grep -q '5dive memory add --store=wiki' "$S1/wiki/index.md" \
   && [[ "$OUT" == *"shared wiki ready at $S1/wiki"* ]]; then
  ok_t "[D] U2 index.md seeded 664, chowned root:claude, with the publish hint"
else
  bad_t "[D] U2 index.md seeded 664 root:claude" "mode=$(mode "$S1/wiki/index.md") calls=$(tr '\n' ' ' <<<"$CALLS") out=$OUT"
fi

# --- U3: idempotent over a wiki already in use ------------------------------
printf 'page body\n' >"$S1/wiki/some-page.md"
printf '\n- [some page](some-page.md) — edited by a seat\n' >>"$S1/wiki/index.md"
before=$(cat "$S1/wiki/index.md")
run_block "$S1"
if [[ $RC -eq 0 && "$(cat "$S1/wiki/index.md")" == "$before" && "$(cat "$S1/wiki/some-page.md")" == "page body" \
      && "$(mode "$S1/wiki")" == 2775 ]] && ! grep -q '^chown' <<<"$CALLS"; then
  ok_t "U3 a second run keeps the pages and the edited index, re-chowns nothing"
else
  bad_t "U3 a second run is idempotent" "rc=$RC calls=$(tr '\n' ' ' <<<"$CALLS")"
fi

# --- U4: fleet box keeps publishing into git --------------------------------
S2="$TMP/state2"; mkdir -p "$S2" "$TMP/fleet/community/wiki"
run_block "$S2" "$TMP/fleet/community/wiki"
if [[ $RC -eq 0 && ! -e "$S2/wiki" && -z "$CALLS" && "$OUT" == *"fleet box"* ]]; then
  ok_t "U4 a fleet box (community/wiki checked out) gets no second wiki root"
else
  bad_t "U4 a fleet box gets no second wiki root" "rc=$RC exists=$([[ -e $S2/wiki ]] && echo y) calls=$CALLS"
fi

# --- U5: failure returns, does not exit -------------------------------------
S3="$TMP/state3"; mkdir -p "$S3"
STUB_INSTALL_RC=1 run_block "$S3"
if [[ $RC -eq 0 && "$OUT" == *"after-call"* && "$OUT" != *"shared wiki ready"* && ! -e "$S3/wiki/index.md" ]]; then
  # RC is the subshell's (the trailing echo); the function's own return is graded next.
  # shellcheck disable=SC2034,SC1090  # read by the sourced block
  ( STATE_DIR="$S3" FIVEDIVE_FLEET_WIKI_DIR="$TMP/none"; ok() { :; }
    install() { return 1; }; source "$BLOCK"; _shared_wiki_ensure ) 2>/dev/null; frc=$?
  [[ $frc -ne 0 ]] && ok_t "U5 a failed install returns non-zero to the caller and does not exit it" \
    || bad_t "U5 a failed install returns non-zero" "function rc=$frc"
else
  bad_t "U5 a failed install returns non-zero and does not exit" "rc=$RC out=$OUT"
fi

# --- W1-W3: where it is called ----------------------------------------------
UPG=$(awk '/^if \[\[ "\$\{1:-\}" == "--upgrade" \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' install.sh)
call_line=$(grep -n '^  _shared_wiki_ensure' <<<"$UPG" | head -1 | cut -d: -f1)
exit_line=$(grep -n '^  exit 0$' <<<"$UPG" | tail -1 | cut -d: -f1)
call_win=""
[[ -n "$call_line" ]] && call_win=$(sed -n "$((call_line)),$((call_line+1))p" <<<"$UPG")
if [[ -n "$call_line" && -n "$exit_line" && $call_line -lt $exit_line ]] \
   && grep -q '|| echo "warn: shared wiki' <<<"$call_win"; then
  ok_t "[D] W1 the --upgrade branch calls it before exit 0, warn-only on failure"
else
  bad_t "[D] W1 the --upgrade branch calls it before exit 0" "call_line=${call_line:-none} exit_line=${exit_line:-none}"
fi
n_total=$(grep -cE '^ *_shared_wiki_ensure( |$)' install.sh)
n_top=$(grep -c '^_shared_wiki_ensure   # DIVE-4128' install.sh)
if [[ $n_total -eq 2 && $n_top -eq 1 ]]; then
  ok_t "[D] W2 the full install calls it once at top level (2 call sites in all)"
else
  bad_t "[D] W2 the full install calls it once" "total=$n_total top=$n_top"
fi
n_mk=$(grep -c 'install -d -m 2775 -o root -g claude' install.sh)
[[ $n_mk -eq 1 ]] && grep -q 'install -d -m 2775 -o root -g claude' "$BLOCK" \
  && ok_t "W3 one copy of the wiki provisioning, inside the function" \
  || bad_t "W3 one copy of the wiki provisioning" "found $n_mk"

echo "TESTS pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
