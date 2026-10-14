#!/usr/bin/env bash
# DIVE-6206 — a half-extracted npx cache must not fail every skill install forever.
#
# WHY THIS EXISTS. npx reuses ~/.npm/_npx/<hash> whenever that dir exists. A first
# `npx skills add` killed mid-extract (the 180s timeout at seat creation) leaves
# yaml/dist with no index.js, and every later run dies ERR_MODULE_NOT_FOUND. On a
# canary box that kept a codex seat without its default skills through every
# nightly refresh, defeating DIVE-6148's shipped fix. _skills_npx_add now clears
# exactly that one dir and retries ONCE.
#
# SHAPE: the two functions are EXTRACTED VERBATIM from src/lib/agent_setup.sh and
# the SKILL_ADD heredoc verbatim from src/cmd_skill.sh; only `npx` is swapped for a
# stub that models the cache (a dir without index.js fails, a missing dir is
# re-extracted). The delete is the dangerous half, so most arms here are the cases
# that must NOT delete: a bad --skill, a path under another home, a symlink, a
# non-hex name. Pure userland: no root, no network, no npx.
# Run: bash tests/skills_npx_cache_heal_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/src/lib/agent_setup.sh"

TMP="$(mktemp -d /tmp/skills-npx-heal-unit.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap 'rc=$?; cleanup; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq() { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "got '$2' want '$3'"; fi; }

HASH=ac0ed6aa23b37c1e
STUB="$TMP/npx-stub"
cat > "$STUB" <<'STUB_NPX'
#!/usr/bin/env bash
# Models the npx cache: an existing dir is reused as-is; a missing one is extracted.
cat >/dev/null   # the real npx drains an inherited stdin
echo call >> "$HOME/calls"
# A cap, so an unbounded retry fails the arm instead of hanging the harness: past it
# the stub answers with an error the heal does not match, which ends any loop.
[ "$(wc -l < "$HOME/calls")" -gt 5 ] && { echo "npx-stub: call cap hit (retry not bounded)" >&2; exit 1; }
d="$HOME/.npm/_npx/$NPX_HASH"
skill=""; while [ $# -gt 0 ]; do [ "$1" = --skill ] && skill="$2"; shift; done
case "${STUB_MODE:-}" in
  otherhome) echo "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/home/agent-other/.npm/_npx/$NPX_HASH/node_modules/yaml/dist/index.js'" >&2; exit 1 ;;
  dotdot)    echo "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '$HOME/.npm/_npx/../node_modules/yaml/dist/index.js'" >&2; exit 1 ;;
esac
# always: every extract is cut short again, so the rebuilt dir is broken too.
[ "${STUB_MODE:-}" = always ] && mkdir -p "$d/node_modules/yaml/dist"
if [ -d "$d" ] && [ ! -f "$d/node_modules/yaml/dist/index.js" ]; then
  echo "node:internal/modules/esm/resolve:873" >&2
  echo "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '$d/node_modules/yaml/dist/index.js' imported from $d/node_modules/skills/dist/cli.mjs" >&2
  exit 1
fi
mkdir -p "$d/node_modules/yaml/dist"; echo 'export {}' > "$d/node_modules/yaml/dist/index.js"
[ "${STUB_MODE:-}" = badskill ] && { echo "No matching skills found for: $skill" >&2; exit 1; }
mkdir -p "$HOME/$INSTALL_DIR/$skill"
printf -- '---\nname: %s\n---\nbody\n' "$skill" > "$HOME/$INSTALL_DIR/$skill/SKILL.md"
echo "Installed $skill"
STUB_NPX
chmod +x "$STUB"

FN="$(sed -n -e '/^_npx_cache_heal() {$/,/^}$/p' -e '/^_skills_npx_add() {$/,/^}$/p' "$LIB")"
if ! grep -q '^_skills_npx_add() {' <<<"$FN" || ! grep -qF 'timeout 180 npx -y skills add "$@"' <<<"$FN"; then
  bad_t "extract _npx_cache_heal + _skills_npx_add from lib/agent_setup.sh" "not found — this harness graded NOTHING"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
HFN="$(sed "s#timeout 180 npx #timeout 180 $STUB #" <<<"$FN")"
INSTALL_DIR=.agents/skills

# fixture <name>: a seat home whose npx cache dir is half-extracted (no index.js).
fixture() {
  local h="$TMP/$1"; rm -rf "$h"
  mkdir -p "$h/.npm/_npx/$HASH/node_modules/yaml/dist" "$h/.npm/_npx/0123456789abcdef/node_modules"
  : > "$h/.npm/_npx/$HASH/node_modules/yaml/dist/index.d.ts"
  : > "$h/.npm/_npx/0123456789abcdef/node_modules/keep"
  printf '%s' "$h"
}
# add <home> <fn-source> [mode] -> runs `_skills_npx_add` as a heredoc would; rc in $RC, output in <home>/out
add() {
  local h="$1"; RC=0
  ( cd "$h" && env HOME="$h" NPX_HASH="$HASH" STUB_MODE="${3:-}" INSTALL_DIR="$INSTALL_DIR" FN="$2" \
      bash -c 'set -euo pipefail; eval "$FN"; _skills_npx_add "https://github.com/o/skills" --skill 5dive-cli --agent codex --yes' \
  ) >"$h/out" 2>&1 || RC=$?
}
calls() { [[ -f "$1/calls" ]] && wc -l < "$1/calls" | tr -d ' ' || echo 0; }

echo "== ACCEPT: a truncated cache dir is cleared and the add retried once =="
H="$(fixture accept)"
add "$H" "$HFN"
eq "add succeeds after the heal (rc)" "$RC" 0
eq "npx ran exactly twice (one retry)" "$(calls "$H")" 2
grep -q "retrying 'skills add' once" "$H/out" && ok_t "the retry is logged" || bad_t "the retry is logged" "$(cat "$H/out")"
[[ -f "$H/.npm/_npx/$HASH/node_modules/yaml/dist/index.js" ]] && ok_t "the cache dir is rebuilt (index.js present)" \
  || bad_t "the cache dir is rebuilt (index.js present)"
[[ -f "$H/$INSTALL_DIR/5dive-cli/SKILL.md" ]] && ok_t "the skill is installed" || bad_t "the skill is installed"
[[ -f "$H/.npm/_npx/0123456789abcdef/node_modules/keep" ]] && ok_t "a sibling cache dir is untouched" \
  || bad_t "a sibling cache dir is untouched"
add "$H" "$HFN"
eq "a healthy cache: next add is one call, no retry" "$(calls "$H")" 3

echo "== NEGATIVE CONTROL: the pre-fix line fails every time on the same fixture =="
# Verbatim from src/cmd_skill.sh before DIVE-6206 (origin/main b6fd2147, :250/:302).
PRE='timeout 180 npx -y skills add "https://github.com/$SOURCE" --skill "$SKILL" --agent "$AGENT_ID" --yes </dev/null 2>&1 | tail -25'
H="$(fixture prefix)"
for i in 1 2; do
  rc=0
  ( cd "$H" && env HOME="$H" NPX_HASH="$HASH" INSTALL_DIR="$INSTALL_DIR" SOURCE=o/skills SKILL=5dive-cli AGENT_ID=codex \
      bash -c "set -euo pipefail; ${PRE/timeout 180 npx /timeout 180 $STUB }" ) >/dev/null 2>&1 || rc=$?
  eq "pre-fix run $i fails rc 1" "$rc" 1
done
[[ ! -f "$H/.npm/_npx/$HASH/node_modules/yaml/dist/index.js" ]] && ok_t "pre-fix: the cache stays broken" \
  || bad_t "pre-fix: the cache stays broken"
# MUTANT: the shipped function with the heal call removed must fail the same way.
MUT="$(sed 's#_npx_cache_heal "\$log" || break#break#' <<<"$HFN")"
if [[ "$MUT" == "$HFN" ]]; then bad_t "MUTANT: heal call removed" "sed matched nothing — VACUOUS"
else
  H="$(fixture mutant)"; add "$H" "$MUT"
  eq "MUTANT (no heal): add fails rc 1" "$RC" 1
  eq "MUTANT (no heal): no retry" "$(calls "$H")" 1
fi

echo "== no delete when the failure is not a broken cache under this home =="
H="$(fixture badskill)"; rm -rf "$H/.npm/_npx/$HASH"
add "$H" "$HFN" badskill
eq "a bad --skill fails" "$RC" 1
eq "a bad --skill is not retried" "$(calls "$H")" 1
[[ -f "$H/.npm/_npx/$HASH/node_modules/yaml/dist/index.js" && -f "$H/.npm/_npx/0123456789abcdef/node_modules/keep" ]] \
  && ok_t "a bad --skill deletes no cache dir" || bad_t "a bad --skill deletes no cache dir"

H="$(fixture otherhome)"
add "$H" "$HFN" otherhome
eq "a missing module under ANOTHER home: not retried" "$(calls "$H")" 1
[[ -d "$H/.npm/_npx/$HASH" ]] && ok_t "a path under another home deletes nothing here" \
  || bad_t "a path under another home deletes nothing here"

H="$(fixture dotdot)"
add "$H" "$HFN" dotdot
eq "a non-hex _npx path: not retried" "$(calls "$H")" 1
[[ -d "$H/.npm/_npx/$HASH" && -d "$H/.npm/_npx/0123456789abcdef" ]] && ok_t "a non-hex _npx path deletes nothing" \
  || bad_t "a non-hex _npx path deletes nothing"

H="$(fixture symlink)"
mkdir -p "$TMP/elsewhere/node_modules/yaml/dist"
rm -rf "$H/.npm/_npx/$HASH"; ln -s "$TMP/elsewhere" "$H/.npm/_npx/$HASH"
add "$H" "$HFN"
eq "a symlinked cache dir: not retried" "$(calls "$H")" 1
[[ -L "$H/.npm/_npx/$HASH" && -d "$TMP/elsewhere/node_modules/yaml/dist" ]] && ok_t "a symlinked cache dir is not removed" \
  || bad_t "a symlinked cache dir is not removed"

H="$(fixture npxlink)"
mv "$H/.npm" "$TMP/real-npm-$$"; ln -s "$TMP/real-npm-$$" "$H/.npm"
add "$H" "$HFN"
# Count calls, not the dir: a retry through the link re-extracts it and hides the delete.
eq "a symlinked ~/.npm: not retried" "$(calls "$H")" 1
[[ -d "$TMP/real-npm-$$/_npx/$HASH" ]] && ok_t "a symlinked ~/.npm is not followed into a delete" \
  || bad_t "a symlinked ~/.npm is not followed into a delete"

echo "== the retry is bounded at ONE =="
H="$(fixture always)"
add "$H" "$HFN" always
eq "still broken after the heal: fails" "$RC" 1
eq "still broken after the heal: exactly 2 calls" "$(calls "$H")" 2
# MUTANT: the one-retry bound removed. The stub's cap stops it, and the count goes red.
MUT="$(sed 's#\[\[ "\$rc" -eq 0 || "\$tries" -gt 0 \]\] \&\& break#[[ "$rc" -eq 0 ]] \&\& break#' <<<"$HFN")"
if [[ "$MUT" == "$HFN" ]]; then bad_t "MUTANT: retry bound removed" "sed matched nothing — VACUOUS"
else
  H="$(fixture unbounded)"; add "$H" "$MUT" always
  [[ "$(calls "$H")" -gt 2 ]] && ok_t "MUTANT (unbounded retry): red, $(calls "$H") calls, the harness still finishes" \
    || bad_t "MUTANT (unbounded retry) is caught" "calls=$(calls "$H")"
fi

echo "== the shipped SKILL_ADD heredoc, fed on stdin, heals and writes its manifest =="
body="$(sed -n "/<<'SKILL_ADD'/,/^SKILL_ADD\$/p" "$ROOT/src/cmd_skill.sh" | sed '1d;$d' \
  | sed -e 's#^export NVM_DIR=.*#export NVM_DIR=/nonexistent#' -e 's#timeout 20 /usr/bin/git ls-remote#false#')"
if ! grep -qE '^_skills_npx_add ' <<<"$body"; then
  bad_t "SKILL_ADD heredoc calls _skills_npx_add" "not found — this arm graded NOTHING"
else
  H="$(fixture heredoc)"; R="$TMP/heredoc-result.json"
  rc=0
  ( cd "$H" && env -u CLAUDE_CONFIG_DIR HOME="$H" NPX_HASH="$HASH" SOURCE=o/skills SKILL=5dive-cli AGENT_ID=codex \
      INSTALL_DIR="$INSTALL_DIR" FORCE=1 RESULT_FILE="$R" SKILLS_NPX_FN="$HFN" bash -s <<<"$body" ) >"$H/out" 2>&1 || rc=$?
  eq "heredoc: rc 0 on a broken cache" "$rc" 0
  eq "heredoc: one retry" "$(calls "$H")" 2
  [[ -s "$R" && -s "$H/$INSTALL_DIR/.skills-manifest.json" ]] && ok_t "heredoc: result file and manifest written after the retry" \
    || bad_t "heredoc: result file and manifest written after the retry" "$(tail -5 "$H/out")"
  rc=0
  ( cd "$H" && env -u CLAUDE_CONFIG_DIR HOME="$H" SOURCE=o/skills SKILL=5dive-cli AGENT_ID=codex \
      INSTALL_DIR="$INSTALL_DIR" FORCE=1 RESULT_FILE="$R" bash -s <<<"$body" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && ok_t "heredoc: refuses to install with no SKILLS_NPX_FN" || bad_t "heredoc: refuses to install with no SKILLS_NPX_FN"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
