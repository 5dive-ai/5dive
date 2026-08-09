#!/usr/bin/env bash
# DIVE-2431: the done==merged gate's repo scope.
#
# The defect: _gate_repo_slugs defaulted to exactly three slugs, so a delivery to any
# other repo we ship from was graded by a set that never contained it — false ACCEPT on
# an unrelated repo's commit (measured on DIVE-2303, delivered to character-packs and
# closed on a 5dive-ai/5dive commit), and false REFUSE for genuinely landed work.
#
# Two properties are graded here and they are independent:
#   1. the default set CONTAINS the repos deliveries actually land in;
#   2. every verdict NAMES the set it searched — the refusals always did, the ACCEPT did
#      not, and the accept is the half that fails silently. Property 2 is what pays for
#      the drift in property 1, so a change that widens the list while dropping the
#      disclosure has not kept this file green.
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HERE/../src}"

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2770: the merge gate gained a CREDENTIAL-FREE rail (an unauthenticated read
# of a public repo). Every no-token arm below was written when "no credential"
# meant "no rail", and with the anon rail live they would reach the real network
# and grade a LIVE PR instead of the fixture. Turn it off here: these harnesses
# grade the pre-2770 rails, and tests/task_merge_gate_anon_rail_unit.sh grades the
# new one. This is also what keeps `no root, no network` true of this file.
#
# IT MUST SIT AFTER lib/grading_tree.sh, AND THAT IS NOT A STYLE CHOICE: that file
# sources lib/env_isolation.sh, which CLEARS inherited FIVE_* knobs so a harness
# never grades the caller's environment. Set above it, this export is wiped and the
# harness silently reaches the network instead — measured, and it read as three
# unrelated assertion failures naming a live PR's real state.
export FIVE_GATE_NO_ANON=1

pass=0; fail=0
ok(){ if eval "$2"; then echo "ok   - $1"; pass=$((pass+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

# Source just what we need: _gate_repo_slugs and its one dependency.
_PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"
_push_repo_slug(){ printf '%s' "$1" | sed -E 's#^https://github\.com/##; s#\.git$##'; }
# shellcheck disable=SC1090
eval "$(sed -n '/^_gate_repo_slugs() {/,/^}/p' "$SRC/cmd_task.sh")"

# ---- 1. THE DEFAULT SET ----
slugs="$(FIVE_GATE_REPOS='' _gate_repo_slugs)"
n="$(printf '%s\n' "$slugs" | grep -c .)"

ok "the three original slugs are still in the default set (no coverage lost)" \
  "grep -qx '5dive-ai/5dive' <<<\"\$slugs\" && grep -qx 'lodar/5dive-api' <<<\"\$slugs\" && grep -qx 'lodar/5dive-frontend' <<<\"\$slugs\""
ok "character-packs is in the default set (the repo whose miss produced DIVE-2431)" \
  "grep -qx '5dive-ai/character-packs' <<<\"\$slugs\""
for r in 5dive-ai/skills 5dive-ai/5dive-plugins 5dive-ai/5dive-mcp 5dive-ai/openagent 5dive-ai/ops lodar/5dive-blog lodar/5dive-mobile; do
  ok "shipping repo $r is searched by default" "grep -qx '$r' <<<\"\$slugs\""
done
ok "the set is strictly larger than the original three" "[[ $n -gt 3 ]]"
ok "no duplicate slugs (the awk dedup still holds)" \
  "[[ \$(printf '%s\n' \"\$slugs\" | sort | uniq -d | wc -l) -eq 0 ]]"
ok "the CLI repo is FIRST, so the commonest case costs one lookup" \
  "[[ \$(printf '%s\n' \"\$slugs\" | head -1) == '5dive-ai/5dive' ]]"
ok "every entry is a bare owner/repo, not a URL" \
  "! grep -qE 'https?://|\.git\$' <<<\"\$slugs\""

# ---- 2. FIVE_GATE_REPOS STILL OVERRIDES (the per-ticket escape hatch, DIVE-1955) ----
# shellcheck disable=SC2034  # used inside the eval'd assertion strings below
ov="$(FIVE_GATE_REPOS='acme/one,acme/two' _gate_repo_slugs)"
ok "FIVE_GATE_REPOS replaces the default set entirely" \
  "[[ \$(printf '%s\n' \"\$ov\" | grep -c .) -eq 2 ]] && grep -qx 'acme/one' <<<\"\$ov\""
ok "FIVE_GATE_REPOS override does NOT leak the widened defaults" \
  "! grep -qx '5dive-ai/character-packs' <<<\"\$ov\""
ok "comma AND whitespace separated overrides both parse" \
  "[[ \$(FIVE_GATE_REPOS='a/b c/d,e/f' _gate_repo_slugs | grep -c .) -eq 3 ]]"

# ---- 3. THE ACCEPT DISCLOSES ITS SCOPE (the silent half) ----
# Graded on the source text: this is the one property the widened list depends on, and
# a future edit that widens further while dropping the disclosure must go red here.
ok "the attribution ACCEPT line still exists" \
  "grep -q 'names \$ident in its SUBJECT' \"\$SRC/cmd_task.sh\""
ok "the ACCEPT interpolates a scope clause" \
  "grep -q 'done=merged-to-main satisfied.\$_attr_scope' \"\$SRC/cmd_task.sh\""
ok "the scope clause names the searched set" \
  "grep -q 'the gate searched \$_searched' \"\$SRC/cmd_task.sh\""
ok "the scope clause says repos outside the set were NOT looked at" \
  "grep -q 'repos outside that set were NOT looked at' \"\$SRC/cmd_task.sh\""
ok "the scope clause offers the terminating remedy (Repo: line / delivery_ref)" \
  "grep -q 'line or bind the delivery_ref, and re-check' \"\$SRC/cmd_task.sh\""
ok "the scope clause is CONDITIONAL on the task declaring no repo" \
  "grep -B3 'the gate searched \$_searched' \"\$SRC/cmd_task.sh\" | grep -q 'if \[\[ -z \"\$_task_slug\" \]\]'"
ok "_attr_scope is declared local (no global leak under set -u)" \
  "grep -q 'local _slug _bmerged=.*_attr_scope=' \"\$SRC/cmd_task.sh\""

# ---- 4. THE REFUSALS KEPT THEIR SCOPE DISCLOSURE (no regression) ----
ok "the DIVE-1830 refusal still names \$_searched" \
  "grep -q 'in \$_searched shows branch' \"\$SRC/cmd_task.sh\""
ok "the scan-bound refusal still offers the unsearched-repo explanation" \
  "grep -q 'the branch lives in a repo that was NEVER SCANNED' \"\$SRC/cmd_task.sh\""

echo; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
