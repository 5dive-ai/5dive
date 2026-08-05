#!/usr/bin/env bash
# DIVE-2789 — the PRE-MERGE half of the full-sweep gap: full-sweep.yml's
# `on.pull_request.paths` list, and the two things about it that rot silently.
#
# WHY A HARNESS AND NOT JUST A REVIEWED DIFF. A `paths:` filter that matches
# NOTHING still produces a green PR. Every way this trigger can be wrong presents
# as "CI was green": a typo in a glob, a list narrowed in a later cleanup because
# the sweep felt expensive, a job that stops running on the event it was added for.
# None of those produce a red anywhere. So the arms below grade the filter against
# the FILE LISTS OF THE TWO COMMITS THAT MOTIVATED IT, which is the one claim that
# cannot be satisfied by an empty match.
#
#   the filter must FIRE       arms 1-2: every file 2f8dbaa (#486, DIVE-2371) and
#                              4e87712 (#488, DIVE-2603) touched in the source tree
#                              is matched. These are the two measured instances of
#                              a nightly-tier harness broken by a merge whose PR was
#                              green; a list that stops covering either has given up
#                              the only coverage anybody demonstrated it needed.
#   and it must NOT fire       arm 3: paths OUTSIDE the claimed surface do not match.
#                              A list that matched everything would pass arms 1-2 and
#                              mean nothing.
#   the MATCHER can fail       arm 4: the glob translator is re-run against a
#                              deliberately narrow list and must REJECT the instance
#                              file lists. Without this, arms 1-2 are also satisfied
#                              by a matcher that returns True unconditionally.
#   the cost decision holds    arm 5: the four harness-verdict jobs (a SECOND whole
#                              pass over the corpus) stay off the pull_request event.
#                              Dropping that `if:` roughly doubles the trigger's cost
#                              silently — nothing goes red, the queue just gets worse.
#   the caveats survive        arms 6-8: the workflow comment must still say this
#                              sweep is ADVISORY on a PR, and must still name the two
#                              axes it does NOT cover (the release path, and the
#                              selfcheck probe class). Those sentences are the whole
#                              defence against the next author reading "full-sweep
#                              runs on branches" as "a regression outside the core
#                              tier can no longer land" — which is false, and was
#                              false the day this shipped (see DIVE-2798).
#
# NO NETWORK, NO ROOT, NO BUILT BUNDLE. Pure parse of a file in this tree.
#
# Run: bash tests/full_sweep_pr_trigger_unit.sh
set -uo pipefail

# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE the cd
# so ${BASH_SOURCE[0]} still resolves relative to tests/.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
WF="$REPO/.github/workflows/full-sweep.yml"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

[[ -r "$WF" ]] || { no "full-sweep.yml is readable"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# --------------------------------------------------------------------------------
# Arms 1-4: the paths filter, graded against the two instances.
#
# The glob translator implements GitHub's filter-pattern rules, not fnmatch's:
# `**` crosses `/`, a single `*` does not, and a pattern with no wildcard and no
# trailing `/` matches that exact path. Getting this wrong in the LENIENT direction
# is what arm 4 exists to catch.
# --------------------------------------------------------------------------------
python3 - "$WF" <<'PY'
import sys, re, yaml

wf = yaml.safe_load(open(sys.argv[1]))
# `on` is the YAML 1.1 boolean True once safe_load has had it. Accept either.
trig = wf.get('on', wf.get(True))
paths = (trig or {}).get('pull_request', {}).get('paths') or []

def to_re(pat):
    out, i = '', 0
    while i < len(pat):
        c = pat[i]
        if c == '*':
            if pat[i:i+2] == '**':
                out += '.*'; i += 2; continue
            out += '[^/]*'; i += 1; continue
        out += re.escape(c); i += 1
    return re.compile('^' + out + '$')

def matches(pats, path):
    return any(to_re(p).match(path) for p in pats)

# The SOURCE-TREE files of each instance. Workflow and tests/ files are excluded on
# purpose: they are not what this list is claiming to cover, and including them
# would let an unrelated entry satisfy the arm.
INSTANCES = {
    '2f8dbaa #486 DIVE-2371': [
        'src/lib/tasks_db.sh', 'src/cmd_selfcheck.sh', 'src/cmd_task.sh',
    ],
    '4e87712 #488 DIVE-2603': [
        'build.sh', 'install.sh', 'src/header.sh',
    ],
}
OUTSIDE = [
    'README.md',
    'CHANGELOG.md',
    'community/wiki/index.md',
    'docs/anything.md',
    'tests/gate_nonce_unit.sh',          # tests/ is NOT in the surface (only tests/lib/tier.sh)
    'scripts/pii-scan.sh',               # scripts/ is NOT in the surface (only run-harnesses.sh)
]
NARROW = ['src/lib/**']                  # arm 4's deliberately insufficient control

P = F = 0
def ok(m):
    global P; P += 1; print('ok   - ' + m)
def no(m):
    global F; F += 1; print('NOT OK - ' + m)

if not paths:
    no('on.pull_request.paths is a non-empty list (an absent filter is not a broad one)')
else:
    ok('on.pull_request.paths parses to a non-empty list (%d entries)' % len(paths))

for name, files in INSTANCES.items():
    missed = [f for f in files if not matches(paths, f)]
    if missed:
        no('instance %s: paths filter would NOT fire for %s' % (name, ', '.join(missed)))
    else:
        ok('instance %s: every source file it touched is covered (%s)' % (name, ', '.join(files)))

leaks = [p for p in OUTSIDE if matches(paths, p)]
if leaks:
    no('paths filter is over-broad — it matches %s, so arms 1-2 prove nothing' % ', '.join(leaks))
else:
    ok('paths filter does NOT match %d files outside the claimed surface' % len(OUTSIDE))

# Arm 4: the matcher must be able to say no. If a narrow list still "covers" both
# instances, the translator is lenient and every arm above is vacuous.
still = [n for n, fs in INSTANCES.items() if all(matches(NARROW, f) for f in fs)]
if still:
    no('the glob matcher is vacuous — %s reads as covered by %s' % (', '.join(still), NARROW))
else:
    ok('the glob matcher rejects %s for both instances (arms 1-2 are not vacuous)' % NARROW)

# Arm 5: the second whole-corpus pass stays off the PR event.
jobs = wf.get('jobs', {})
for j in ('harness-verdict-pristine', 'harness-verdict-installed',
          'harness-verdict-slow', 'harness-verdict-union'):
    cond = str(jobs.get(j, {}).get('if', ''))
    if 'pull_request' in cond and '!=' in cond:
        ok('%s is excluded from the pull_request event (cost: a second full pass)' % j)
    else:
        no('%s no longer carries `if: github.event_name != \'pull_request\'` (got %r)' % (j, cond))

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
PY
if (( $? == 0 )); then ok "paths filter + verdict-job exclusion (see arms above)"; else no "paths filter + verdict-job exclusion (see arms above)"; fi

# --------------------------------------------------------------------------------
# Arms 6-8: the caveats. These are PROSE, and that is exactly why they need an arm —
# a sentence nothing grades is a sentence the next cleanup deletes.
# --------------------------------------------------------------------------------
if grep -qi 'ADVISORY ON A PR' "$WF"; then
  ok 'the workflow says IN THOSE WORDS that the PR sweep is advisory, not a merge gate'
else
  no 'the workflow no longer states that the PR sweep is ADVISORY — a sweep read as a control is the defect class this row exists to close'
fi

if grep -q 'release-cut.yml' "$WF"; then
  ok 'the workflow names the RELEASE PATH as an axis it does not cover'
else
  no 'the workflow no longer names release-cut.yml as uncovered (DIVE-2798 is the live counterexample)'
fi

if grep -q 'cmd_selfcheck.sh' "$WF"; then
  ok 'the workflow names the SELFCHECK PROBE class as an instrument the corpus never reaches'
else
  no 'the workflow no longer names the selfcheck probe class as uncovered'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
