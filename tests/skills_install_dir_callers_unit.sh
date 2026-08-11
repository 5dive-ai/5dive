#!/usr/bin/env bash
# DIVE-2609 — every skill-dir caller must resolve through skills_install_dir().
#
# Four callers used to repeat the map lookup. The values agreed, but nothing
# coupled those copies to the resolver. This harness grades both halves:
#   1. the resolver owns the only executable SKILLS_INSTALL_DIR read in src/;
#   2. each caller's actual assignment is executed for every mapped type and
#      must equal the resolver. Synthetic unique values make a copied constant
#      agree for at most one type instead of hiding behind today's duplicates.
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit

SRC=src
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# Both files are function definitions only at source time.
# shellcheck source=/dev/null
source "$SRC/cmd_skill.sh"
# shellcheck source=/dev/null
source "$SRC/lib/agent_setup.sh"
set +e

pass=0
fail=0
ok_t()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad_t() { fail=$((fail + 1)); printf '  FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Source enumeration is intentional for this half: the defect is a second
# executable read. Comments that document the map are not reads, so match the
# parameter expansion itself. Exactly one is allowed, in the resolver body.
mapfile -t direct_reads < <(
  grep -RInF -- '${SKILLS_INSTALL_DIR[' "$SRC" \
    | awk -F: '$3 !~ /^[[:space:]]*#/'
)
if [[ ${#direct_reads[@]} -eq 1 && "${direct_reads[0]}" == src/header.sh:* ]]; then
  ok_t 'skills_install_dir owns the only executable SKILLS_INSTALL_DIR read in src/'
else
  bad_t 'direct SKILLS_INSTALL_DIR reads remain outside the resolver' "${direct_reads[*]:-none found}"
fi

# Pull the real assignment out of the sourced function. We execute this text
# below; merely finding a function name or grepping for a call is not a grade.
caller_assignment() {
  local fn="$1"
  declare -f "$fn" | awk '
    /^[[:space:]]*install_dir=/ { sub(/^[[:space:]]*/, ""); print; found++ }
    END { if (found != 1) exit 1 }
  '
}

resolve_at_caller() {
  local fn="$1" type="$2" assignment install_dir=""
  assignment=$(caller_assignment "$fn") || return 2
  eval "$assignment" || return 3
  printf '%s\n' "$install_dir"
}

mapfile -t mapped_types < <(printf '%s\n' "${!SKILLS_INSTALL_DIR[@]}" | sort)
if [[ ${#mapped_types[@]} -ge 8 && ${#mapped_types[@]} -eq ${#SKILLS_INSTALL_DIR[@]} ]]; then
  ok_t 'mapped-type sweep is non-vacuous'
else
  bad_t 'mapped-type sweep is vacuous or incomplete' "visited=${#mapped_types[@]} map=${#SKILLS_INSTALL_DIR[@]}"
fi

# Make every expected value unique. With the production map, several types
# legitimately share .agents/skills; that would let one hardcoded string pass
# multiple iterations and weaken this arm.
for type in "${mapped_types[@]}"; do
  SKILLS_INSTALL_DIR["$type"]="dive-2609-probe/$type"
done

callers=(cmd_skill_add _skill_list_json cmd_skill_rm install_default_skill_for_agent)
for fn in "${callers[@]}"; do
  bad=""; ran=0
  for type in "${mapped_types[@]}"; do
    got=$(resolve_at_caller "$fn" "$type")
    expected=$(skills_install_dir "$type")
    [[ "$got" == "$expected" ]] || bad+=" $type(got:${got:-none},want:$expected)"
    ran=$((ran + 1))
  done
  if [[ -z "$bad" && $ran -eq ${#mapped_types[@]} ]]; then
    ok_t "$fn resolves the helper's value for every mapped type"
  else
    bad_t "$fn diverges from skills_install_dir" "${bad:-ran $ran of ${#mapped_types[@]}}"
  fi
done

# Harness control: under the unique probe map, a copied constant must not pass
# more than one iteration. This proves the loop above distinguishes derivation
# from a value that merely happens to be right for one caller/type today.
constant="${SKILLS_INSTALL_DIR[${mapped_types[0]}]}"; constant_matches=0
for type in "${mapped_types[@]}"; do
  [[ "$constant" == "$(skills_install_dir "$type")" ]] && constant_matches=$((constant_matches + 1))
done
if [[ $constant_matches -eq 1 ]]; then
  ok_t 'control: a hardcoded directory passes at most one mapped type'
else
  bad_t 'control could not distinguish a hardcoded directory' "matches=$constant_matches"
fi

# ---- the enumerating caller is GRADED, not merely counted ------------------
# Arm 1 above is a COUNT: exactly one executable read of the map's values, in
# the resolver. It is satisfied by an enumerator that calls the resolver and
# then throws the answer away. DIVE-3172's `_agent_payload_fingerprint` is the
# first real caller that needs every value at once (DIVE-2609 x DIVE-3172,
# 2026-08-11), and what actually matters about it is not the shape of its read
# but whether the payload set it hashes MOVES WITH THE MAP.
#
# So: put a probe directory into SKILLS_INSTALL_DIR and prove the fingerprint
# changes when that directory changes. THE CONTROL IS THE HALF THAT MATTERS —
# an identical directory that is NOT in the map must leave the fingerprint
# still. Without it, a fingerprint that simply hashed the whole agent home
# would pass the first half while being coupled to nothing.
#
# The subject is extracted from the shipped bytes by its own markers, the way
# its own harness extracts it (tests/self_update_restart_predicate_unit.sh:45),
# because a re-source would grade this file's idea of cmd_selfupdate.sh rather
# than cmd_selfupdate.sh. The resolver pair is lifted the same way, for the
# same reason and for one more: without them in scope the enumeration yields
# NOTHING, the fingerprint quietly falls back to its documented .claude/* set,
# and every arm below would pass while grading the blind spot. That failure is
# silent, so the precondition is loud.
_fp_block="$(sed -n '/^# >>> DIVE-3172 agent payload fingerprint/,/^# <<< DIVE-3172 agent payload fingerprint/p' \
  "$SRC/cmd_selfupdate.sh")"
_fp_maps="$(sed -n '/^declare -A SKILLS_INSTALL_DIR=(/,/^)$/p; /^declare -A TYPE_PERSONA_FILE=(/,/^)$/p' \
  "$SRC/header.sh")"
_fp_resolver="$(sed -n '/^skills_install_dir() {/,/^}$/p; /^skills_install_dirs_all() {/,/^}$/p' \
  "$SRC/header.sh")"
if ! grep -q '_agent_payload_fingerprint()' <<<"$_fp_block"; then
  bad_t 'enumerating caller is UNGRADED' \
        "no _agent_payload_fingerprint between the DIVE-3172 markers in $SRC/cmd_selfupdate.sh"
elif ! grep -q 'skills_install_dir()' <<<"$_fp_resolver" \
     || ! grep -q 'skills_install_dirs_all()' <<<"$_fp_resolver"; then
  bad_t 'resolver pair not extractable from src/header.sh' \
        'skills_install_dir / skills_install_dirs_all missing — the enumeration would yield nothing and the arms below would grade the .claude/* fallback and pass vacuously'
else
  _W="$(mktemp -d)"; mkdir -p "$_W/home/dive2609-probe" "$_W/home/dive2609-unmapped" "$_W/lib"
  printf 'before\n' >"$_W/home/dive2609-probe/body.md"
  printf 'before\n' >"$_W/home/dive2609-unmapped/body.md"
  # The probe type is ADDED to the map rather than replacing an entry: the
  # fingerprint also hashes a fixed .claude/* set, so an arm built on a value
  # that is already in that set could not tell the map from the fallback.
  _fp() {
    bash -c "set -uo pipefail
$_fp_maps
SKILLS_INSTALL_DIR[dive2609probe]=\"dive2609-probe\"
$_fp_resolver
$_fp_block
_agent_payload_fingerprint \"\$1\" \"\$2\"" _ "$_W/home" "$_W/lib"
  }
  _a=$(_fp); _c=$(_fp)
  printf 'after\n' >"$_W/home/dive2609-probe/body.md";     _b=$(_fp)
  printf 'after\n' >"$_W/home/dive2609-unmapped/body.md";  _d=$(_fp)
  # AN EMPTY FINGERPRINT IS THE COUPLING FAILURE, not a broken probe, and the
  # two must not share a label. The probe directory exists and has bytes in it,
  # so the only way the hash comes back empty is that the derived path set never
  # reached it and the fixture home matched none of the four .claude/* literals
  # — i.e. the enumeration yielded nothing. Measured: stubbing
  # skills_install_dirs_all to `return 0` lands here, and the first cut of this
  # arm called that "probe unusable", which sends the next reader to the harness
  # when the defect is in the source.
  if [[ -z "$_a" ]]; then
    bad_t 'the enumerating caller does NOT track the map (nothing enumerated)' \
          'the payload set came back empty with a populated mapped directory on disk — skills_install_dirs_all yielded nothing and the fingerprint fell through to its .claude/* literals'
  elif [[ "$_a" != "$_c" ]]; then
    bad_t 'fingerprint is not usable as a probe' \
          "unstable across two identical runs (a=$_a c=$_c)"
  elif [[ "$_a" == "$_b" ]]; then
    bad_t 'the enumerating caller does NOT track the map' \
          'a directory in SKILLS_INSTALL_DIR changed on disk and the payload fingerprint did not move'
  elif [[ "$_b" != "$_d" ]]; then
    bad_t 'control: the enumerating caller tracks directories OUTSIDE the map' \
          'an unmapped directory moved the fingerprint, so the arm above proves nothing about the map'
  else
    ok_t 'the enumerating caller is coupled to the map (a mapped dir moves the payload fingerprint, an unmapped one does not)'
  fi
  rm -rf "$_W"
fi

printf '\nskills_install_dir_callers_unit: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
