#!/usr/bin/env bash
# DIVE-7860 — the nightly skill refresh emptied a grok seat's skills for 7 nights.
# A root (sandboxed) run left ~/.grok/skills root-owned. Once isolation resolved to
# standard, the install ran as the seat: its `rm -rf` deleted the skill's files but
# could not unlink the dir from the root-owned parent, `set -e` exited 1, and the
# seat kept an EMPTY skill dir (chill-gorge, 2026-11-01..07, audit said only `code 1`).
# And `agent skill <seat> list` said "no skills installed" / ok:true when the caller's
# sudo was simply refused.
#   A. root-owned skills dir, standard isolation: the dir goes back to the seat and the
#      skill ends populated, rc 0 (pre-fix: EMPTY, rc 1).
#   B. a skills dir the seat cannot write and that is NOT root-owned (so nothing heals
#      it): the install fails, the old copy is still whole, no staging dir is left.
#   C. the clone fails: rc 1, the old copy is still there, and the error line reaches
#      the caller's JSON and the audit row.
#   D. a plain re-install: populated, no dot-dirs left behind.
#   E. a root (sandboxed) run hands the skills dir itself back to the seat.
#   F. list with a refused sudo: rc 10 and ok:false (pre-fix: ok:true, skills:[]).
#   G. list on a readable seat with no skills: rc 0, "no skills installed".
#   H. list by the seat itself, with no sudo at all: its real skills.
# "root-owned" is modelled with a 555 dir plus the owner-read seam; the chown stub
# hands it back by making it writable. sudo, git and npx are stubs; nothing leaves $TMP.
# TIER: core
# Run: timeout 120 bash tests/skill_add_root_owned_dir_unit.sh
# Negative control: SRC_REV=origin/main timeout 120 bash tests/skill_add_root_owned_dir_unit.sh
#   (sources src/ at that rev; only the agent-home test seam is patched in)
set -uo pipefail
# shellcheck disable=SC2034  # JSON_MODE/AUDIT_* are read by the sourced CLI inside the subshells
export GH_ORG=5dive-ai
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; chmod -R u+w "${TMP:-/nonexistent-dive-7860}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/skill-root-owned.XXXXXX)"
SRC="src"
if [[ -n "${SRC_REV:-}" ]]; then
  mkdir -p "$TMP/src-rev"
  git archive "$SRC_REV" src | tar -x -C "$TMP/src-rev" || { echo "cannot read src at $SRC_REV"; exit 2; }
  SRC="$TMP/src-rev/src"
  # The one seam this harness needs: the agent home root. Without it the pre-fix
  # tree would aim at the real /home/agent-grok.
  sed -i 's|home="/home/agent-\${name}"|home="${AGENT_HOME_ROOT:-/home}/agent-${name}"|g' "$SRC/cmd_skill.sh"
  echo "sourcing src at $SRC_REV ($(git rev-parse --short "$SRC_REV"))"
fi
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_env.sh lib/agent_setup.sh lib/audit.sh cmd_skill.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json"
H="$AGENT_HOME_ROOT/agent-grok"; SK="$H/.grok/skills"
grep -q 'AGENT_HOME_ROOT:-/home}/agent-' "$SRC/cmd_skill.sh" || { echo "home seam missing — refusing to run"; exit 2; }

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }

# ---- stubs -----------------------------------------------------------------
CALLER="root"; SUDO_REFUSE=0; ISO="standard"
id() {
  case "$1" in
    -u)  [[ "${2:-}" == agent-* ]] && echo 1000 || command id -u ;;
    -un) echo "$CALLER" ;;
    *)   command id "$@" ;;
  esac
}
agent_type() { echo grok; }
agent_isolation_2src() { printf '%s\tenv\n' "$ISO"; }
# sudo [-n] -u <user> [-H] <cmd...>: refuse, or run the command as "the seat" with its HOME.
sudo() {
  local u=""
  while [[ $# -gt 0 ]]; do
    case "$1" in -n|-H) shift ;; -u) u="$2"; shift 2 ;; *) break ;; esac
  done
  (( SUDO_REFUSE )) && { echo "sudo: a password is required" >&2; return 1; }
  # The list's npx read: the seat's npx is unavailable here, so the dir scan answers.
  [[ "$1" == bash && "${2:-}" == -s ]] && { cat >/dev/null; return 1; }
  HOME="$AGENT_HOME_ROOT/$u" "$@"
}
CHOWNS="$TMP/chowns"
ROOT_OWNED=""
_agent_dir_uid() {
  [[ " $ROOT_OWNED " == *" $1 "* ]] && { echo 0; return; }
  # E: the dir turns root-owned only once the (root) install has run, i.e. after the clone.
  [[ "$1" == "$SK" && -e "$TMP/root-ran" ]] && { echo 0; return; }
  echo 1000
}
# A chown hands the dir to the seat: model that as making it writable again.
chown() {
  printf '%s\n' "$*" >>"$CHOWNS"
  local last="${!#}"
  [[ -d "$last" ]] && chmod u+w "$last" 2>/dev/null
  return 0
}
chowned() { grep -qE -- " $1\$" "$CHOWNS" 2>/dev/null; }

mkdir -p "$TMP/bin" "$TMP/fixture/skills/5dive-cli"
printf 'new skill\n' >"$TMP/fixture/skills/5dive-cli/SKILL.md"
printf 'ref\n' >"$TMP/fixture/skills/5dive-cli/ref.md"
cat >"$TMP/bin/git" <<EOF
#!/usr/bin/env bash
[ "\$1" = clone ] || exit 1
[ "\${FAKE_CLONE_FAIL:-0}" = 1 ] && { echo "fatal: repository not found" >&2; exit 128; }
[ "\${ROOT_RUN_MARK:-0}" = 1 ] && touch "$TMP/root-ran"
cp -r "$TMP/fixture" "\${!#}"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/npx"
chmod +x "$TMP/bin/git" "$TMP/bin/npx"
export PATH="$TMP/bin:$PATH"

AUDIT_FILE="$TMP/audit.ndjson"
_emit_audit_line() { printf '%s\n' "$1" >>"$AUDIT_FILE"; }

seed_old() {  # a working old copy under a seat-owned, writable skills dir
  chmod -R u+w "$TMP/home" 2>/dev/null; rm -rf "$TMP/home" "$CHOWNS" "$AUDIT_FILE"
  mkdir -p "$SK/5dive-cli"; printf 'old skill\n' >"$SK/5dive-cli/SKILL.md"
  printf '{}' >"$SK/.skills-manifest.json"
  ROOT_OWNED=""; ISO="standard"; CALLER="root"; SUDO_REFUSE=0; export FAKE_CLONE_FAIL=0
}
run_add() {  # -> RC, OUT; the EXIT trap writes the audit row as main() would
  OUT=$( (
    JSON_MODE=1; AUDIT_CMD="agent skill"; AUDIT_ARGS=(grok add --source=5dive-ai/skills --skill=5dive-cli --force)
    AUDIT_LOG="$TMP/audit.log"; trap on_exit_audit EXIT
    cmd_skill_add grok --source=5dive-ai/skills --skill=5dive-cli --force
  ) 2>"$TMP/stderr" ); RC=$?
}
dotdirs() { find "$SK" -mindepth 1 -maxdepth 1 -name '.*' -type d | wc -l; }

echo "A. root-owned skills dir, standard isolation"
seed_old; chmod 555 "$SK"; ROOT_OWNED="$SK"
run_add
is "A1 rc 0" "$RC" 0
is "A2 the skill is populated with the new copy" "$(cat "$SK/5dive-cli/SKILL.md" 2>/dev/null)" "new skill"
chowned "$SK" && ok_ "A3 the skills dir was handed to the seat" || bad_ "A3 the skills dir was never handed to the seat"
is "A4 no staging dir left" "$(dotdirs)" 0

echo "B. a skills dir the seat cannot write, not root-owned (nothing heals it)"
seed_old; chmod 555 "$SK"
run_add
is "B1 rc 1" "$RC" 1
is "B2 the old copy is whole" "$(cat "$SK/5dive-cli/SKILL.md" 2>/dev/null)" "old skill"
is "B3 no staging dir left" "$(dotdirs)" 0
jq -e '.ok == false and (.error.message | test("cannot write"))' <<<"$OUT" >/dev/null \
  && ok_ "B4 the caller is told why" || bad_ "B4 no reason in the error (got: $OUT)"

echo "C. the clone fails"
seed_old; export FAKE_CLONE_FAIL=1
run_add
is "C1 rc 1" "$RC" 1
is "C2 the old copy is still there" "$(cat "$SK/5dive-cli/SKILL.md" 2>/dev/null)" "old skill"
jq -e '.ok == false and (.error.message | test("could not clone"))' <<<"$OUT" >/dev/null \
  && ok_ "C3 the error line reaches the caller" || bad_ "C3 the caller got no error line (got: $OUT)"
jq -se 'last | .result == "error" and (.error // "" | test("^ERROR: could not clone"))' "$AUDIT_FILE" >/dev/null 2>&1 \
  && ok_ "C4 the error line reaches the audit row" || bad_ "C4 the audit row has no error line (got: $(tail -1 "$AUDIT_FILE" 2>/dev/null))"

echo "D. a plain re-install"
seed_old
run_add
is "D1 rc 0" "$RC" 0
is "D2 populated with the new copy" "$(cat "$SK/5dive-cli/SKILL.md" 2>/dev/null)" "new skill"
is "D3 every file landed" "$(LC_ALL=C ls "$SK/5dive-cli" 2>/dev/null | tr '\n' ' ')" "SKILL.md ref.md "
is "D4 no staging or old dir left" "$(dotdirs)" 0
jq -e '."5dive-cli".content_sha256 | length == 64' "$SK/.skills-manifest.json" >/dev/null \
  && ok_ "D5 manifest stamped" || bad_ "D5 manifest not stamped"
jq -se 'last | .result == "ok" and (has("error") | not)' "$AUDIT_FILE" >/dev/null 2>&1 \
  && ok_ "D6 an ok audit row carries no error field" || bad_ "D6 ok audit row wrong (got: $(tail -1 "$AUDIT_FILE" 2>/dev/null))"

echo "E. a root (sandboxed) run"
seed_old; ISO="sandboxed"; rm -f "$TMP/root-ran"
# The skills dir is the seat's before the run and root's after it (the fake clone marks
# that), so only a hand-back AFTER the root run can catch it.
export ROOT_RUN_MARK=1
run_add
export ROOT_RUN_MARK=0
is "E1 rc 0" "$RC" 0
chowned "$SK" && ok_ "E2 the skills dir itself goes back to the seat after a root run" \
  || bad_ "E2 a root run leaves the skills dir root-owned (chowns: $(tr '\n' ';' <"$CHOWNS"))"
rm -f "$TMP/root-ran"

run_list() { OUT=$( ( JSON_MODE="$1"; cmd_skill_list grok ) 2>"$TMP/stderr" ); RC=$?; }

echo "F. list with a refused sudo"
seed_old; CALLER="agent-vesper"; SUDO_REFUSE=1
run_list 1
is "F1 rc 10 (permission)" "$RC" 10
jq -e '.ok == false and (.error.message | test("needs root"))' <<<"$OUT" >/dev/null \
  && ok_ "F2 --json says ok:false, needs root" || bad_ "F2 --json still answers (got: $OUT)"
run_list 0
[[ "$OUT" != *"no skills installed"* ]] && ok_ "F3 text mode never says 'no skills installed'" \
  || bad_ "F3 text mode says 'no skills installed' on a refused read"

echo "G. list on a readable seat with no skills"
seed_old; rm -rf "${SK:?}/5dive-cli"
run_list 0
is "G1 rc 0" "$RC" 0
is "G2 says no skills installed" "$OUT" "no skills installed for 'grok'"

echo "H. the seat lists itself with no sudo grant"
seed_old; CALLER="agent-grok"; SUDO_REFUSE=1
OUT=$( ( JSON_MODE=1; HOME="$H"; cmd_skill_list grok ) 2>"$TMP/stderr" ); RC=$?
is "H1 rc 0" "$RC" 0
is "H2 lists its own skill" "$(jq -r '.data.skills | map(.name) | join(",")' <<<"$OUT" 2>/dev/null)" "5dive-cli"

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
