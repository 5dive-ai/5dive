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
trap 'printf "HARNESS-RC=%d\n" "$?"' EXIT
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

printf '\nskills_install_dir_callers_unit: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
