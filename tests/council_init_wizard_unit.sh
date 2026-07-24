#!/usr/bin/env bash
# DIVE-1861 unit — the interactive `council init` wizard builds the correct
# --seats/--threshold/--veto flags from prompted answers, and those flags are the
# SAME contract the non-interactive seal path already consumes. Drives the wizard
# over piped stdin (its dumb-terminal numbered branch), so it gates in CI with no
# TTY, no root, and no gate-proof key. Exit 0 == green.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The wizard + its UI helpers are plain function defs — source them directly.
# Stub the two council seams the wizard leans on so the test needs no live state:
#   · _council_resolve_principal — resolve human:main / tg:<id>, refuse the rest
#   · _council_constitution_path — point at a scratch file we control
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export STATE_DIR="$TMP"          # the template derives COUNCIL_* paths from this at source time
source "$ROOT/src/cmd_init.sh"
# shellcheck disable=SC1090
source "$ROOT/src/council/cmd_council.template.sh"

CPATH="$TMP/constitution.yaml"
_council_constitution_path() { printf '%s' "$CPATH"; }
_council_resolve_principal() {
  case "$1" in
    human:main) printf '%s' '1234567890' ;;
    tg:*) local id="${1#tg:}"; [[ "$id" =~ ^[0-9]+$ ]] && printf '%s' "$id" ;;
    *) : ;;
  esac
}

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1"; echo "  want: [$2]"; echo "  got:  [$3]"; fi; }

# ---- CASE A: bare run, chair + one custom lens, majority, default constitution ----------------
# Prompt order (dumb-terminal numbered picks): seats -> chair# -> olivia lens -> dev lens
#   -> threshold# -> veto -> constitution# -> confirm#
A_ARGS=()
_council_init_wizard "$TMP" A_ARGS "" "" "" 0 <<'ANS' >/dev/null 2>&1
main, olivia, dev
1
the growth lens

1
human:main
1
1
ANS
rc=$?
chk "A wizard exit 0" "0" "$rc"
chk "A seats flag"     "--seats=main:chair,olivia:the growth lens,dev" "${A_ARGS[0]:-}"
chk "A threshold flag" "--threshold=majority" "${A_ARGS[1]:-}"
chk "A veto flag"      "--veto=human:main" "${A_ARGS[2]:-}"
chk "A no stray force" "3" "${#A_ARGS[@]}"

# ---- CASE B: no chair, custom fraction threshold, tg veto, --force carried through -------------
# seats -> chair# (4 = no chair) -> a lens -> b lens -> threshold# (4=custom) -> "3/5"
#   -> veto -> constitution# -> confirm#
B_ARGS=()
_council_init_wizard "$TMP" B_ARGS "" "" "" 1 <<'ANS' >/dev/null 2>&1
a, b
3


4
3/5
tg:987654321
1
1
ANS
chk "B seats flag (no chair)" "--seats=a,b" "${B_ARGS[0]:-}"
chk "B custom threshold"      "--threshold=3/5" "${B_ARGS[1]:-}"
chk "B tg veto"               "--veto=tg:987654321" "${B_ARGS[2]:-}"
chk "B force carried"         "--force" "${B_ARGS[3]:-}"

# ---- CASE C: pre-seeded flags become prompt defaults (Enter accepts) ---------------------------
# Empty seats line -> default "x:chair,y"? No: pre_seats seeds the seats TEXT default only.
# seats(Enter=default) -> chair# -> (y lens) -> threshold(Enter=default idx) -> veto(Enter) -> const# -> confirm#
C_ARGS=()
_council_init_wizard "$TMP" C_ARGS "x, y" "all" "human:main" 0 <<'ANS' >/dev/null 2>&1

1

2
human:main
1
1
ANS
chk "C seats from default"     "--seats=x:chair,y" "${C_ARGS[0]:-}"
chk "C threshold pick=all"     "--threshold=all" "${C_ARGS[1]:-}"

# ---- CASE D: cancel at the confirm step writes nothing (non-zero return) -----------------------
D_ARGS=(SENTINEL)
_council_init_wizard "$TMP" D_ARGS "" "" "" 0 <<'ANS' >/dev/null 2>&1
solo
1
1
human:main
1
2
ANS
chk "D cancel returns non-zero" "yes" "$([ "$?" -ne 0 ] && echo yes || echo no)"

# ---- CASE E: custom constitution with no file on disk aborts (fail-closed) ---------------------
rm -f "$CPATH"
E_ARGS=(SENTINEL)
_council_init_wizard "$TMP" E_ARGS "" "" "" 0 <<'ANS' >/dev/null 2>&1
solo
1
1
human:main
2
ANS
chk "E missing custom const aborts" "yes" "$([ "$?" -ne 0 ] && echo yes || echo no)"

echo
echo "DIVE-1861 council init wizard unit: $P passed, $F failed"
[ "$F" -eq 0 ] || exit 1
