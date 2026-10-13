#!/usr/bin/env bash
# DIVE-6148 unit harness: the nightly skill refresh's never-booted guard covers
# ONLY seats whose skills dir is under ~/.claude.
#
# The defect this pins: 5dive-refresh-skills.sh skipped every seat with no
# ~/.claude as "not booted yet". A codex seat installs to ~/.agents/skills and may
# never grow a ~/.claude, so codex-elm ran 22 days with no default skills while
# every nightly summary said "1 awaiting first boot" — a false verdict nobody
# looks at.
#
# Grades:
#   1. the primitive: `agent _skills_install_dir <name>` answers from the registry
#      type through skills_install_dir (codex -> .agents/skills, claude and an
#      unrecorded type -> .claude/skills), and refuses a missing name with usage
#   2. a codex seat with no ~/.claude is ATTEMPTED and counted (first-install),
#      never "awaiting first boot"
#   3. NEGATIVE CONTROL: a claude seat with no ~/.claude is still skipped and
#      counted "awaiting first boot"; a booted claude seat is attempted
#   4. a bundle too old to answer the primitive keeps the old guard (skip)
#   5. MUTATION: the pre-fix guard (~/.claude alone) reds arm 2
#
# No root, no adduser, no network, no npx: getent and the 5dive bundle are
# stubbed; the stub answers `_skills_install_dir` out of the real src/ functions
# against a fixture registry, so arm 2 grades the seam, not a copy of the map.
#
# Run: bash tests/refresh_skills_never_booted_guard_unit.sh
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/refresh-skills-guard.XXXXXX)"

# Not named ok/fail: src/lib/output.sh and error_codes.sh own those.
t_pass=0; t_fail=0
t_ok()  { echo "  ok: $1"; t_pass=$((t_pass+1)); }
t_bad() { echo "  FAIL: $1" >&2; t_fail=$((t_fail+1)); }
t_eq()  { [[ "$2" == "$3" ]] && t_ok "$1" || { t_bad "$1"; printf '    want: %s\n    got : %s\n' "$3" "$2" >&2; }; }

cat >"$TMP/agents.json" <<'JSON'
{"agents":{"cx":{"type":"codex"},"cl":{"type":"claude"},"cb":{"type":"claude"},"nt":{}}}
JSON
mkdir -p "$TMP/home/agent-cx" "$TMP/home/agent-cl" "$TMP/home/agent-cb/.claude"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/getent" <<SH
#!/usr/bin/env bash
[[ "\$1" == passwd ]] || exit 2
printf '%s:x:1000:1000::%s:/bin/bash\n' "\$2" "$TMP/home/\$2"
SH
chmod +x "$TMP/bin/getent"

# The real primitive, sourced from this tree, with registry_read on the fixture.
cat >"$TMP/primitive.sh" <<SH
set -uo pipefail
cd "$PWD"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh cmd_agent_runtime.sh; do
  source "src/\$f"
done
registry_read() { cat "$TMP/agents.json"; }
cmd_agent_skills_install_dir "\$@"
SH

# Fake bundle. OLD=1 plays a bundle that predates the primitive.
cat >"$TMP/fake-5dive" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent _default_skills") echo "5dive-ai/skills:5dive-cli" ;;
  "agent _skills_install_dir")
    [[ -z "\${OLD:-}" ]] || { echo "error: unknown agent subcommand" >&2; exit 2; }
    shift 2; bash "$TMP/primitive.sh" "\$@" ;;
  "agent skill")
    echo "\$3" >>"$TMP/attempted"
    echo '{"data":{"previous_content_sha256":"","changed":true}}' ;;
  *) echo "fake-5dive: unexpected args: \$*" >&2; exit 64 ;;
esac
SH
chmod +x "$TMP/fake-5dive"

# refresh <script> <agent> -> the summary line; attempted agents land in $TMP/attempted.
refresh() {
  : >"$TMP/attempted"
  PATH="$TMP/bin:$PATH" FIVE_BIN="$TMP/fake-5dive" bash "$1" "$2" 2>/dev/null | grep '^skills refresh done:'
}

echo "== 1. the primitive answers from the registry type =="
for pair in "cx .agents/skills" "cl .claude/skills" "nt .claude/skills" "nobody .claude/skills"; do
  read -r ag want <<<"$pair"
  t_eq "_skills_install_dir $ag" "$(bash "$TMP/primitive.sh" "$ag" 2>/dev/null)" "$want"
done
if bash "$TMP/primitive.sh" 2>"$TMP/usage.err"; then
  t_bad "_skills_install_dir with no name exits 0"
else
  grep -q 'usage: 5dive agent _skills_install_dir <name>' "$TMP/usage.err" \
    && t_ok "_skills_install_dir with no name refuses with its usage line (answers --help)" \
    || t_bad "_skills_install_dir usage line missing: $(cat "$TMP/usage.err")"
fi

S=./5dive-refresh-skills.sh
SUM_ATTEMPTED="skills refresh done: 0 changed, 0 unchanged, 1 first-install, 0 failed, 0 awaiting first boot"
SUM_SKIPPED="skills refresh done: 0 changed, 0 unchanged, 0 first-install, 0 failed, 1 awaiting first boot"

echo "== 2. a codex seat with no ~/.claude is attempted =="
t_eq "codex seat, no ~/.claude: summary" "$(refresh "$S" cx)" "$SUM_ATTEMPTED"
t_eq "codex seat, no ~/.claude: add ran" "$(cat "$TMP/attempted")" "cx"
[[ ! -d "$TMP/home/agent-cx/.claude" ]] && t_ok "refresh did not create ~/.claude to get past the guard" \
  || t_bad ".claude appeared in the codex fixture home (the arm would be vacuous)"

echo "== 3. NEGATIVE CONTROL: claude seats keep the guard =="
t_eq "claude seat, no ~/.claude: summary" "$(refresh "$S" cl)" "$SUM_SKIPPED"
t_eq "claude seat, no ~/.claude: add did not run" "$(cat "$TMP/attempted")" ""
t_eq "unrecorded type, no ~/.claude: summary (fallback dir is .claude/skills)" "$(mkdir -p "$TMP/home/agent-nt"; refresh "$S" nt)" "$SUM_SKIPPED"
t_eq "booted claude seat: summary" "$(refresh "$S" cb)" "$SUM_ATTEMPTED"

echo "== 4. a bundle without the primitive keeps the old guard =="
t_eq "old bundle, codex seat, no ~/.claude: skipped" "$(OLD=1 refresh "$S" cx)" "$SUM_SKIPPED"

echo "== 5. MUTATION: the pre-fix guard reds arm 2 =="
perl -0pe 's/  if \[\[ \( -z "\$skills_dir".*?\n.*?\]\]; then/  if [[ ! -d "\$home\/.claude" ]]; then/s' "$S" >"$TMP/prefix.sh"
if cmp -s "$S" "$TMP/prefix.sh"; then
  t_bad "mutation did not apply (guard text moved?) — arm 5 would be vacuous"
else
  got=$(refresh "$TMP/prefix.sh" cx)
  [[ "$got" == "$SUM_SKIPPED" ]] && t_ok "pre-fix guard counts the codex seat 'awaiting first boot' (arm 2 is not vacuous)" \
    || t_bad "pre-fix guard did not reproduce the defect: $got"
fi

echo
echo "$t_pass passed, $t_fail failed"
(( t_fail == 0 ))
