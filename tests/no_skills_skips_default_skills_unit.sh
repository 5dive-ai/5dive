#!/usr/bin/env bash
# DIVE-6751 unit harness: `agent create --no-skills` installs no skills at all.
#
# The defect this pins: --no-skills only cleared the --with-skills extras. Every
# preseed branch (claude, codex, grok, opencode, pi, antigravity) then called
# preseed_default_skills_for_type, which seeded DEFAULT_AGENT_SKILLS (5dive-cli,
# compile-knowledge) unconditionally, and the nightly 5dive-refresh-skills.sh
# re-pulled them on every registered seat. Found by main's live connector arm on
# CLI 0.97.0.
#
# Grades:
#   1. NO_DEFAULT_SKILLS=1 (cmd_create's --no-skills): nothing seeded, every type;
#      control: unset, the whole list is seeded
#   2. a registry seat with noSkills: true (a later channel attach): nothing seeded
#   3. cmd_create's wiring: the flag is set before the first preseed call, and the
#      registry write records noSkills
#   4. the nightly refresh skips a noSkills seat and still refreshes the others
#   5. pack import keeps the defaults: it opts out with --with-skills=, not --no-skills
#   6. MUTATION: origin/main's agent_setup.sh seeds under the flag (arm 1 is not vacuous)
#
# No root, no adduser, no network, no npx: install_default_skill_for_agent is
# stubbed to record its arguments, getent and the bundle are faked.
#
# Run: bash tests/no_skills_skips_default_skills_unit.sh
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2229: pinned-commit baseline for the mutation arm, fail-closed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/pinned_baseline.sh" \
  || printf 'pinned baseline helper: UNRESOLVED (tests/lib/pinned_baseline.sh not reachable)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/no-skills-defaults.XXXXXX)"
export GH_ORG=5dive-ai

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
REGISTRY="$TMP/agents.json"
echo '{"agents":{"plain":{"type":"claude"},"bare":{"type":"claude","noSkills":true}}}' >"$REGISTRY"

# Not named ok/fail: src/lib/output.sh and error_codes.sh own those.
t_pass=0; t_fail=0
t_ok()  { echo "  ok: $1"; t_pass=$((t_pass+1)); }
t_bad() { echo "  FAIL: $1" >&2; t_fail=$((t_fail+1)); }
t_eq()  { [[ "$2" == "$3" ]] && t_ok "$1" || { t_bad "$1"; printf '    want: %s\n    got : %s\n' "$3" "$2" >&2; }; }

install_default_skill_for_agent() { printf '%s:%s\n' "$3" "$4" >>"$TMP/seeded"; }
seeded() { : >"$TMP/seeded"; preseed_default_skills_for_type "$1" "$2"; cat "$TMP/seeded"; }
list_now=$(default_agent_skill_specs)

echo "== 1. --no-skills seeds none of the defaults, on every type =="
for type in claude codex grok opencode pi antigravity; do
  NO_DEFAULT_SKILLS=1
  t_eq "--no-skills ($type)" "$(seeded fresh "$type")" ""
  NO_DEFAULT_SKILLS=0
  t_eq "control, no flag ($type)" "$(seeded fresh "$type")" "$list_now"
done

echo "== 2. a seat recorded noSkills stays bare on a later preseed =="
t_eq "registry noSkills: true" "$(seeded bare claude)" ""
t_eq "control, a seat without it" "$(seeded plain claude)" "$list_now"

echo "== 3. cmd_create sets the flag before the preseed and records it =="
flag_at=$(grep -n 'NO_DEFAULT_SKILLS=\$no_skills' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
preseed_at=$(grep -nE '^\s+preseed_[a-z_]+_agent "\$name"' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
if [[ -n "$flag_at" && -n "$preseed_at" ]] && (( flag_at < preseed_at )); then
  t_ok "NO_DEFAULT_SKILLS=\$no_skills (line $flag_at) precedes the first preseed (line $preseed_at)"
else
  t_bad "flag line '${flag_at:-none}' does not precede the first preseed '${preseed_at:-none}'"
fi
reg_jq=$(sed -n '/step "Registering in \$REGISTRY"/,/registry_write/p' "$SRC/cmd_agent_create.sh")
grep -q 'noSkills: true' <<<"$reg_jq" && t_ok "the registry write carries noSkills" \
  || t_bad "the registry write does not record noSkills"
# The jq fragment itself: 1 -> {noSkills:true}, 0 -> nothing.
for ns in 1 0; do
  got=$(jq -nc --argjson ns "$ns" '{type: "claude"} + (if $ns == 1 then {noSkills: true} else {} end)')
  want='{"type":"claude"}'; [[ $ns == 1 ]] && want='{"type":"claude","noSkills":true}'
  t_eq "registry entry, no_skills=$ns" "$got" "$want"
done

echo "== 4. the nightly refresh leaves a noSkills seat alone =="
mkdir -p "$TMP/bin" "$TMP/home/agent-plain/.claude" "$TMP/home/agent-bare/.claude"
cat >"$TMP/bin/getent" <<SH
#!/usr/bin/env bash
printf '%s:x:1000:1000::%s:/bin/bash\n' "\$2" "$TMP/home/\$2"
SH
cat >"$TMP/fake-5dive" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent _default_skills") echo "5dive-ai/skills:5dive-cli" ;;
  "agent _skills_install_dir") echo ".claude/skills" ;;
  "agent skill") echo "\$3" >>"$TMP/attempted"; echo '{"data":{"previous_content_sha256":"","changed":true}}' ;;
  "agent pack-sync") exit 0 ;;
  *) exit 64 ;;
esac
SH
chmod +x "$TMP/bin/getent" "$TMP/fake-5dive"
: >"$TMP/attempted"
PATH="$TMP/bin:$PATH" FIVE_BIN="$TMP/fake-5dive" FIVE_AGENTS_JSON="$REGISTRY" bash ./bin/5dive-refresh-skills.sh >"$TMP/refresh.out" 2>&1
t_eq "refresh re-pulled only the seat without noSkills" "$(sort -u "$TMP/attempted")" "plain"
grep -q 'bare — created with --no-skills, skipping' "$TMP/refresh.out" && t_ok "and says why it skipped the other" \
  || t_bad "no skip line for the noSkills seat: $(cat "$TMP/refresh.out")"

echo "== 5. pack import keeps the defaults =="
cargs=$(grep -n 'local -a cargs=("\$as" "--type=\$type"' "$SRC/cmd_pack.sh")
grep -q -- '--with-skills=")' <<<"$cargs" && ! grep -q -- '--no-skills' <<<"$cargs" \
  && t_ok "import creates with --with-skills= (extras off, defaults kept)" \
  || t_bad "import's create argv: $cargs"

echo "== 6. MUTATION: the pre-fix provisioner seeds under the flag =="
# PINNED TO A COMMIT, NOT TO origin/main (DIVE-6755). Read from origin/main this
# arm went vacuous the moment DIVE-6751 merged: main carries the fix, so it
# skipped forever. deba606 is main immediately before DIVE-6751.
PRE_FIX_REF="deba60628ea0440756b91ceadfcee484ee7b4f88"   # main immediately before DIVE-6751
if pinned_blob "$PRE_FIX_REF" src/lib/agent_setup.sh "$TMP/agent_setup_prefix.sh"; then
  if grep -q agent_skips_default_skills "$TMP/agent_setup_prefix.sh"; then
    t_bad "the pin $PRE_FIX_REF already carries the fix; the mutation arm would be vacuous"
  else
    got=$(bash -c '
      set -uo pipefail
      for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "src/$f"; done
      source "$1"
      install_default_skill_for_agent() { printf "%s:%s\n" "$3" "$4"; }
      NO_DEFAULT_SKILLS=1 preseed_default_skills_for_type fresh claude' _ "$TMP/agent_setup_prefix.sh")
    [[ -n "$got" ]] && t_ok "pre-fix ${PRE_FIX_REF:0:8} seeds $(wc -l <<<"$got") default skill(s) despite the flag (arm 1 reds on it)" \
      || t_bad "pre-fix ${PRE_FIX_REF:0:8} seeded nothing under the flag; arm 1 would be vacuous"
  fi
else
  t_bad "mutation arm NOT measured: $(pinned_unavailable_msg "$PRE_FIX_REF")"
fi

echo
echo "no_skills_skips_default_skills_unit: $t_pass passed, $t_fail failed"
[[ $t_fail -eq 0 && $t_pass -ge 20 ]]   # count floor: a shadowed/skipped assertion must not read as green
