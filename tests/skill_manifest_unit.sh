#!/usr/bin/env bash
# DIVE-2282 — grade the per-agent skill manifest's changed-detection.
#
# WHY THIS EXISTS. DIVE-2282 is the defect "skills refresh done: 12 re-pulled"
# could not distinguish 12 UNCHANGED from 12 SILENTLY REWRITTEN. The fix records
# a content hash per installed skill and reports changed / content_sha256 /
# previous_content_sha256 back to the caller. Shipping that with no arm
# reproduces the same defect one level up: if the comparison is inverted, or
# previous_ is never populated, or `changed` is hardwired false, every refresh
# prints a confident "unchanged" and nothing downstream can tell a WORKING
# report from a BROKEN one. This is a root-executed fleet path.
#
# SHAPE, and it is deliberate (same as tests/release_cut_guards_unit.sh and
# tests/install_pin_sha_unit.sh): the manifest block is EXTRACTED VERBATIM from
# src/cmd_skill.sh by fence marker and those bytes are what run here. It is not
# re-implemented. A harness that re-implements the logic it grades is internally
# consistent and externally silent — it agrees with itself while the shipped
# file does something else.
#
# The fenced copy is the ADMIN install heredoc (SKILL_ADD), the most common
# install path. The drift guard at the bottom asserts the other two heredocs
# (SKILL_ADD_MANUAL, SKILL_ADD_SANDBOXED) still carry byte-identical logic, so
# an edit to one copy that is not mirrored to the other two is caught here
# rather than in production on a fleet of agents.
#
# Isolation: pure userland. No root, no network, no sudo, no real agent user —
# the fenced block runs strictly AFTER the install step and only hashes a
# directory that is already on disk, so a couple of fixture files under a
# throwaway $HOME stand in for "the skill dir the install produced".
# Run: bash tests/skill_manifest_unit.sh
set -uo pipefail

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
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/cmd_skill.sh"

TMP="$(mktemp -d /tmp/skill-manifest-unit.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

eq() {  # eq "$name" "$actual" "$expected"
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "got '$2' want '$3'"; fi
}

# --- extract the shipped bytes ----------------------------------------------
# A check that cannot run is its own outcome and must say so, never report a
# false green (see the "three outcomes, not two" note in lib/grading_tree.sh).
[[ -f "$SRC" ]] || { echo "FAIL - could not read $SRC"; exit 1; }
BLOCK="$(sed -n '/# >>> DIVE-2282 skill manifest block/,/# <<< DIVE-2282 skill manifest block/p' "$SRC" | sed '1d;$d')"
if [[ -z "$BLOCK" ]]; then
  echo "FAIL - could not extract the DIVE-2282 fenced manifest block from $SRC"
  echo "       (fence markers missing or renamed; this harness graded NOTHING)"
  exit 1
fi
# Sanity on the extraction itself: if the fence ever slides over the wrong
# lines, every arm below would still "pass" against whatever it caught.
for needle in 'MANIFEST="$HOME/$INSTALL_DIR/.skills-manifest.json"' 'CONTENT_SHA=' 'PREV_SHA=' 'RESULT_FILE'; do
  grep -qF -- "$needle" <<<"$BLOCK" \
    || { echo "FAIL - extracted block is missing '$needle'; the fence does not cover the logic under test"; exit 1; }
done

INSTALL_DIR=".claude/skills"
SKILL="demo-skill"
SOURCE="5dive-ai/skills"
RESOLVED_SHA="0000000000000000000000000000000000000000"

# write_block <text> <path> — materialise extracted bytes as a runnable script.
write_block() {
  { printf '#!/usr/bin/env bash\nset -euo pipefail\n'; printf '%s\n' "$1"; } > "$2"
}

# run_block <script> <home> <body-content> <result-file>
# Seeds $HOME/$INSTALL_DIR/$SKILL with fixture files, then runs the extracted
# block against it exactly as the install heredoc would, with RESOLVED_SHA
# supplied as a plain env var (the real line above the fence needs the network
# and is not what is under test).
run_block() {
  local script="$1" home="$2" body="$3" rf="$4"
  mkdir -p "$home/$INSTALL_DIR/$SKILL"
  printf -- '---\nname: %s\n---\n' "$SKILL" > "$home/$INSTALL_DIR/$SKILL/SKILL.md"
  printf '%s\n' "$body" > "$home/$INSTALL_DIR/$SKILL/reference.md"
  rm -f "$rf"
  env -u CLAUDE_CONFIG_DIR HOME="$home" INSTALL_DIR="$INSTALL_DIR" SKILL="$SKILL" \
    SOURCE="$SOURCE" RESOLVED_SHA="$RESOLVED_SHA" RESULT_FILE="$rf" \
    bash "$script" >/dev/null 2>&1
}

res()      { jq -r "$2 // empty" "$1" 2>/dev/null || true; }   # res <file> <filter>
manifest() { jq -r --arg k "$SKILL" '.[$k].content_sha256 // empty' "$1" 2>/dev/null || true; }
# `.changed` needs its own reader: `false // empty` is EMPTY in jq, so the
# obvious `res "$f" .changed` reads a correctly-reported false as "missing" —
# the same alternative-operator trap _skill_read_result documents in the source.
# MISSING is a distinct third value so "no result file" can never read as false.
changed() { jq -r 'if has("changed") then (.changed|tostring) else "MISSING" end' "$1" 2>/dev/null || echo MISSING; }

REAL="$TMP/block-real.sh"
write_block "$BLOCK" "$REAL"

# --- ARM C + ARM A: first install, then a REWRITTEN reinstall ---------------
echo "== ARM C: a first install is 'first install', not 'changed' =="
HA="$TMP/homeA"; RA1="$TMP/resA1.json"; RA2="$TMP/resA2.json"
run_block "$REAL" "$HA" "content X" "$RA1"
MAN_A="$HA/$INSTALL_DIR/.skills-manifest.json"

if [[ -s "$MAN_A" ]]; then ok_t "first install writes .skills-manifest.json"
else bad_t "first install writes .skills-manifest.json" "missing or empty: $MAN_A"; fi
eq "manifest records source"      "$(jq -r --arg k "$SKILL" '.[$k].source // empty' "$MAN_A" 2>/dev/null)" "$SOURCE"
eq "manifest records resolved_sha" "$(jq -r --arg k "$SKILL" '.[$k].resolved_sha // empty' "$MAN_A" 2>/dev/null)" "$RESOLVED_SHA"
if [[ -n "$(jq -r --arg k "$SKILL" '.[$k].installed_at // empty' "$MAN_A" 2>/dev/null)" ]]; then
  ok_t "manifest records installed_at"
else bad_t "manifest records installed_at" "empty"; fi

SHA1="$(manifest "$MAN_A")"
if [[ -n "$SHA1" ]]; then ok_t "first install records a content_sha256"
else bad_t "first install records a content_sha256" "empty"; fi
eq "first install: changed=false"                  "$(changed "$RA1")" "false"
eq "first install: previous_content_sha256 empty"  "$(res "$RA1" .previous_content_sha256)" ""
eq "first install: result content_sha256 == manifest" "$(res "$RA1" .content_sha256)" "$SHA1"

echo "== ARM A: reinstall with DIFFERENT content must report changed =="
run_block "$REAL" "$HA" "content Y — a silently rewritten skill body" "$RA2"
A_CHANGED="$(changed "$RA2")"
eq "rewritten reinstall: changed=true"                    "$A_CHANGED" "true"
eq "rewritten reinstall: previous_ == first install's sha" "$(res "$RA2" .previous_content_sha256)" "$SHA1"
SHA2="$(res "$RA2" .content_sha256)"
if [[ -n "$SHA2" && "$SHA2" != "$SHA1" ]]; then ok_t "rewritten reinstall: content_sha256 actually moved"
else bad_t "rewritten reinstall: content_sha256 actually moved" "sha1='$SHA1' sha2='$SHA2'"; fi
eq "rewritten reinstall: manifest advanced to the new sha" "$(manifest "$MAN_A")" "$SHA2"

# --- ARM B: byte-identical reinstall ---------------------------------------
echo "== ARM B: reinstall with IDENTICAL content must report unchanged =="
HB="$TMP/homeB"; RB1="$TMP/resB1.json"; RB2="$TMP/resB2.json"
run_block "$REAL" "$HB" "content X" "$RB1"
MAN_B="$HB/$INSTALL_DIR/.skills-manifest.json"
SHA_B1="$(manifest "$MAN_B")"
run_block "$REAL" "$HB" "content X" "$RB2"
B_CHANGED="$(changed "$RB2")"
eq "identical reinstall: changed=false"                     "$B_CHANGED" "false"
eq "identical reinstall: content_sha256 is stable"          "$(res "$RB2" .content_sha256)" "$SHA_B1"
eq "identical reinstall: previous_ == the same sha"         "$(res "$RB2" .previous_content_sha256)" "$SHA_B1"

# --- MUTATION: prove these arms are sensitive to the logic under test -------
# Neuter ONLY the change comparison (second condition can never hold). A
# plausible near-miss: it must break change DETECTION specifically. If it also
# flipped ARM B it would be a global break and would prove nothing about which
# property the suite is actually watching.
echo "== MUTATION: neuter the hash comparison; ARM A must go RED, ARM B stay GREEN =="
MUT_EXPR='s/\[ "\$PREV_SHA" != "\$CONTENT_SHA" \]/false/'
MUT_BLOCK="$(sed "$MUT_EXPR" <<<"$BLOCK")"
if [[ "$MUT_BLOCK" == "$BLOCK" ]]; then
  bad_t "mutation applies to the extracted block" \
        "sed expr matched nothing — this arm graded NOTHING (VACUOUS): $MUT_EXPR"
else
  ok_t "mutation applies to the extracted block"
  MUT="$TMP/block-mutant.sh"
  write_block "$MUT_BLOCK" "$MUT"

  # ARM A replayed against the mutant: the rewritten body must now go unreported.
  HAM="$TMP/homeA-mut"; RAM1="$TMP/resAm1.json"; RAM2="$TMP/resAm2.json"
  run_block "$MUT" "$HAM" "content X" "$RAM1"
  run_block "$MUT" "$HAM" "content Y — a silently rewritten skill body" "$RAM2"
  MA_CHANGED="$(changed "$RAM2")"

  # ARM B replayed against the SAME mutant: must be unaffected.
  HBM="$TMP/homeB-mut"; RBM1="$TMP/resBm1.json"; RBM2="$TMP/resBm2.json"
  run_block "$MUT" "$HBM" "content X" "$RBM1"
  run_block "$MUT" "$HBM" "content X" "$RBM2"
  MB_CHANGED="$(changed "$RBM2")"

  printf '     ARM A (rewritten body):  real changed=%s  -> mutant changed=%s\n' "$A_CHANGED" "$MA_CHANGED"
  printf '     ARM B (identical body):  real changed=%s  -> mutant changed=%s\n' "$B_CHANGED" "$MB_CHANGED"

  eq "MUTANT: ARM A goes RED (rewrite no longer detected)" "$MA_CHANGED" "false"
  eq "MUTANT: ARM B stays GREEN (unchanged still unchanged)" "$MB_CHANGED" "false"
  if [[ "$A_CHANGED" == "true" && "$MA_CHANGED" == "false" && "$B_CHANGED" == "false" && "$MB_CHANGED" == "false" ]]; then
    ok_t "MUTANT: the split is change-detection-specific, not a global break"
  else
    bad_t "MUTANT: the split is change-detection-specific, not a global break" \
          "A real=$A_CHANGED mutant=$MA_CHANGED | B real=$B_CHANGED mutant=$MB_CHANGED"
  fi
  # Non-vacuity of the mutant itself: it must still RUN and still write a
  # result file, otherwise "changed=false" would just be an empty read.
  if [[ -s "$RAM2" ]]; then ok_t "MUTANT: still produces a result file (false is a read, not a miss)"
  else bad_t "MUTANT: still produces a result file (false is a read, not a miss)" "$RAM2 missing/empty"; fi
fi

# --- drift guard: the other two install paths must carry the same logic -----
# The manifest write is copied into three heredocs. Only one is fenced and
# graded; if a future edit lands in that one and not the others, the agents
# installed through the manual/sandboxed paths silently keep the old behaviour.
echo "== drift guard: all three install heredocs carry identical manifest logic =="
heredoc_manifest() {  # $1 = heredoc terminator name
  sed -n "/<<'$1'/,/^$1\$/p" "$SRC" \
    | sed -n '/^MANIFEST="\$HOME\/\$INSTALL_DIR\/\.skills-manifest\.json"$/,/^  > "\$RESULT_FILE" 2>\/dev\/null || true$/p'
}
for term in SKILL_ADD_MANUAL SKILL_ADD_SANDBOXED; do
  other="$(heredoc_manifest "$term")"
  if [[ -z "$other" ]]; then
    bad_t "drift guard: $term manifest block located" "extraction returned nothing — this arm graded NOTHING"
  elif [[ "$other" == "$BLOCK" ]]; then
    ok_t "drift guard: $term manifest logic is byte-identical to the fenced copy"
  else
    bad_t "drift guard: $term manifest logic is byte-identical to the fenced copy" \
          "$(diff <(printf '%s\n' "$BLOCK") <(printf '%s\n' "$other") | head -20)"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
