#!/usr/bin/env bash
# DIVE-4203 unit harness: ONE default-skills list, two consumers, no drift.
#
# The defect this pins: the provisioner (src/lib/agent_setup.sh) and the nightly
# backfill (5dive-refresh-skills.sh) each carried their own hand-maintained list,
# and they had drifted — create seeded four skills, DEFAULT_SKILLS held one. So
# DIVE-4130's fleet-wide removal of `openagent` (16 of 16 on-type seats) and its
# fix in PR #837 stopped the nightly cron re-pulling it, and lasted exactly until
# the next `5dive agent create` re-seeded it. Fixing the reconciler does not fix
# the provisioner.
#
# Grades four things:
#   1. the list itself is DIVE-4130's keep-set, and openagent/find-skills are absent
#   2. the PROVISIONER's seed plan == the list, on every harness type
#   3. the REFRESH script's plan == the list (read via its PRINT_PLAN seam)
#   4. the NEGATIVE arm — a skill added to the list appears in BOTH plans with
#      no second edit, which is the property that makes 2 and 3 non-vacuous
#
# No root, no adduser, no network, no npx: install_default_skill_for_agent is
# stubbed to record its arguments, and gh_org() is pinned via GH_ORG.
#
# Run: bash tests/default_skills_single_list_unit.sh
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/default-skills-single-list.XXXXXX)"

# gh_org() otherwise probes the network to pick the mirror. Pin it so the whole
# harness is hermetic and the specs are byte-comparable.
export GH_ORG=5dive-ai

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/lib/agent_setup.sh"

# Defined AFTER the sources on purpose, and NOT named ok/fail/check: src/lib/
# output.sh owns `ok` and error_codes.sh owns `fail`, so helpers named that way
# are silently replaced by the tree under test and every assertion becomes a
# no-op that still exits 0. (That happened on the first draft of this file: 19
# green lines, "0 passed, 0 failed", HARNESS-RC=0.)
t_pass=0; t_fail=0
t_ok()  { echo "  ok: $1"; t_pass=$((t_pass+1)); }
t_bad() { echo "  FAIL: $1" >&2; t_fail=$((t_fail+1)); }
t_eq()  { [[ "$2" == "$3" ]] && t_ok "$1" || { t_bad "$1"; printf '    want: %s\n    got : %s\n' "$3" "$2" >&2; }; }

echo "== 1. the list is DIVE-4130's keep-set =="
list_now=$(default_agent_skill_specs)
t_eq "resolved list" "$list_now" \
  "$(printf '5dive-ai/skills:5dive-cli\n5dive-ai/skills:compile-knowledge')"

# The two skills DIVE-4130 removed fleet-wide. Named individually, because a
# whole-list equality check above would silently start passing again if someone
# rewrote the expectation instead of the list.
for gone in openagent find-skills; do
  if grep -q ":$gone\$" <<<"$list_now"; then
    t_bad "$gone is back in DEFAULT_AGENT_SKILLS (DIVE-4130 removed it fleet-wide)"
  else
    t_ok "$gone absent from the list"
  fi
done

echo "== 2. the provisioner seeds exactly the list, on every type =="
# Stub the installer: record `<source>:<skill>` instead of pulling anything.
install_default_skill_for_agent() { printf '%s:%s\n' "$3" "$4" >>"$TMP/seeded"; }

# Every harness type with a preseed branch. A type missing here is not caught by
# this harness — arm 5 below closes that by grading the call sites themselves.
for type in claude codex grok opencode pi antigravity; do
  : >"$TMP/seeded"
  preseed_default_skills_for_type unit-fixture "$type"
  t_eq "provisioner plan ($type)" "$(cat "$TMP/seeded")" "$list_now"
done

echo "== 3. the refresh script's plan is the same list =="
# Stand in for the installed bundle: answer `agent _default_skills` out of the
# very functions sourced above, so this grades the SEAM, not a copy of it.
cat >"$TMP/fake-5dive" <<SH
#!/usr/bin/env bash
if [[ "\$1" == "agent" && "\$2" == "_default_skills" ]]; then
  GH_ORG=$GH_ORG bash -c '
    set -uo pipefail
    cd "$PWD"
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "src/\$f"; done
    source src/lib/agent_setup.sh
    default_agent_skill_specs'
  exit 0
fi
echo "fake-5dive: unexpected args: \$*" >&2; exit 64
SH
chmod +x "$TMP/fake-5dive"
refresh_plan=$(FIVE_BIN="$TMP/fake-5dive" REFRESH_SKILLS_PRINT_PLAN=1 bash ./5dive-refresh-skills.sh 2>"$TMP/refresh.err")
t_eq "refresh plan" "$refresh_plan" "$list_now"

# ...and it must not have a private list to fall back on.
if grep -qE '^DEFAULT_SKILLS=\(' 5dive-refresh-skills.sh; then
  t_bad "5dive-refresh-skills.sh carries its own DEFAULT_SKILLS array again (that IS the drift)"
else
  t_ok "5dive-refresh-skills.sh holds no second list"
fi

echo "== 4. negative arm: one edit reaches both consumers =="
# Add a skill to the ONE list and re-derive both plans. If either is a copy
# rather than a reader, exactly one of these two checks fails.
DEFAULT_AGENT_SKILLS+=("@org/skills:unit-fixture-skill")
list_plus=$(default_agent_skill_specs)
grep -q '^5dive-ai/skills:unit-fixture-skill$' <<<"$list_plus" \
  && t_ok "list carries the added skill" || t_bad "list did not take the added skill"

: >"$TMP/seeded"
preseed_default_skills_for_type unit-fixture claude
t_eq "provisioner picks up the added skill" "$(cat "$TMP/seeded")" "$list_plus"

# The refresh side reads through the fake bundle, which re-sources a PRISTINE
# copy of the file — so append the same one line to a scratch copy of the tree's
# list and point the fake at that, proving the reader tracks the source.
sed 's#^  "@org/skills:compile-knowledge".*#&\n  "@org/skills:unit-fixture-skill"#' \
  src/lib/agent_setup.sh >"$TMP/agent_setup_plus.sh"
cat >"$TMP/fake-5dive-plus" <<SH
#!/usr/bin/env bash
if [[ "\$1" == "agent" && "\$2" == "_default_skills" ]]; then
  GH_ORG=$GH_ORG bash -c '
    set -uo pipefail
    cd "$PWD"
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source "src/\$f"; done
    source "$TMP/agent_setup_plus.sh"
    default_agent_skill_specs'
  exit 0
fi
exit 64
SH
chmod +x "$TMP/fake-5dive-plus"
refresh_plus=$(FIVE_BIN="$TMP/fake-5dive-plus" REFRESH_SKILLS_PRINT_PLAN=1 bash ./5dive-refresh-skills.sh 2>/dev/null)
t_eq "refresh picks up the added skill" "$refresh_plus" "$list_plus"

echo "== 5. no preseed branch bypasses the helper =="
# Arm 2 can only grade the types it was told about. This grades the TREE: the
# only place allowed to call install_default_skill_for_agent with a default is
# preseed_default_skills_for_type itself. A new harness type that hand-rolls its
# own quartet (which is how the seven sites drifted) fails here.
strays=$(grep -n 'install_default_skill_for_agent "\$name"' src/lib/agent_setup.sh \
         | grep -v 'install_default_skill_for_agent "\$name" "\$type"' || true)
if [[ -n "$strays" ]]; then
  t_bad "hand-rolled default-skill seeding outside preseed_default_skills_for_type:"
  printf '    %s\n' "$strays" >&2
else
  t_ok "every preseed branch routes through the one helper"
fi

echo
echo "default_skills_single_list_unit: $t_pass passed, $t_fail failed"
[[ $t_fail -eq 0 && $t_pass -ge 15 ]]   # count floor: a shadowed/skipped assertion must not read as green
