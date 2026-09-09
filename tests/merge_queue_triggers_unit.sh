#!/usr/bin/env bash
# DIVE-4139 — the wiring a merge queue needs, graded as text, before the queue exists.
#
# TIER: core — 0.4s measured (pure grep/awk over .github/workflows, no network, no
# build). It grades the ONE property whose failure mode is invisible: with a merge
# queue enabled, GitHub evaluates required status checks on the temporary
# `gh-readonly-queue/main/...` merge group, NOT on the pull request. A required
# context whose workflow does not fire on `merge_group` therefore never reports
# there; the entry sits until the check-response timeout and is EVICTED. Nothing is
# red — the PR simply never merges, and the reason is a trigger list nobody reads.
# That is the same shape as DIVE-2141 (a required context that does not RUN blocks
# forever), which is why the invariant is pinned in the corpus and not in a comment.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

WF=.github/workflows

# The ten REQUIRED status checks on main, read from the API 2026-09-09 (classic
# protection and ruleset 22522554 agree), mapped to the workflow that DECLARES the
# job of that name. Pinned, not derived: a harness must not need a credential.
declare -A OWNER=(
  [test]=unit-tests [test-installed-host]=unit-tests [test-confirm]=unit-tests
  [test-installed-host-confirm]=unit-tests [changed-harnesses]=unit-tests
  [shellcheck]=install-smoke [docker-install]=install-smoke
  [scan]=pii-guard [check]=bundle-drift [supply-chain-guard]=supply-chain-guard
)

# The `on:` block only — a `merge_group` word inside a job or a comment is not a
# trigger. awk from `on:` to the first column-0 line that is not part of it.
on_block(){ awk '/^on:/{i=1;next} i&&/^[a-zA-Z]/{exit} i' "$1"; }

# --- arm 1: every required context's workflow fires on merge_group -------------
for ctx in "${!OWNER[@]}"; do
  f="$WF/${OWNER[$ctx]}.yml"
  if ! grep -qE '^  *[a-z0-9_-]*:?$' <<<"" ; then :; fi
  if [[ ! -f $f ]]; then no "arm1 $ctx: $f missing"; continue; fi
  grep -qE "^  ${OWNER[$ctx]}:" /dev/null 2>/dev/null || true
  if ! grep -qE "^  ${ctx}:\$" "$f"; then no "arm1 $ctx: job not declared in $f"; continue; fi
  if on_block "$f" | grep -qE '^  merge_group:'; then ok "arm1 $ctx -> ${OWNER[$ctx]}.yml fires on merge_group"
  else no "arm1 $ctx: ${OWNER[$ctx]}.yml has NO merge_group trigger — the queue would evict every entry waiting on '$ctx'"; fi
done

# --- arm 2: no merge_group workflow ALSO catches the queue branch via push ------
# `branches: ['**']` matches gh-readonly-queue/..., so the same context would be
# reported by two racing runs on one merge group.
for f in "$WF"/*.yml; do
  on_block "$f" | grep -qE '^  merge_group:' || continue
  pat=$(on_block "$f" | awk '/^  push:/{i=1;next} i&&/^  [a-z]/{exit} i' | grep -E "^ +branches:" || true)
  if grep -q "'\*\*'" <<<"$pat" && ! grep -q "gh-readonly-queue" <<<"$pat"; then
    no "arm2 $(basename "$f"): push branches '**' matches gh-readonly-queue/** and merge_group also fires — one context, two runs"
  else ok "arm2 $(basename "$f"): no double-fire on the queue branch"; fi
done

# --- arm 3: a merge_group workflow must not read a PR sha unconditionally ------
# github.event.pull_request.* is EMPTY on merge_group. Empty shas do not skip a
# scan, they make it exit "could not scan" — which is wired to red.
for f in "$WF"/*.yml; do
  on_block "$f" | grep -qE '^  merge_group:' || continue
  bad=$(grep -nE '\$\{\{ *github\.event\.pull_request\.(base|head)\.sha *\}\}' "$f" || true)
  if [[ -n $bad ]]; then no "arm3 $(basename "$f"): unguarded PR sha on a merge_group workflow: ${bad%%$'\n'*}"
  else ok "arm3 $(basename "$f"): every base/head sha branches on the event"; fi
done

# --- arm 4: the known job-name collision set is CLOSED -------------------------
# Two workflows may declare a job with the same id; the status context is that id,
# so both report the same name. `check` (bundle-drift + template-skills) is the one
# that exists today and it is SAFE only because template-skills does not fire on
# merge_group. A NEW collision on a required context must red here.
known_set="badge-staleness:check template-skills:check"
found=""
for ctx in "${!OWNER[@]}"; do
  for f in "$WF"/*.yml; do
    b=$(basename "$f" .yml); [[ $b == "${OWNER[$ctx]}" ]] && continue
    grep -qE "^  ${ctx}:\$" "$f" && found+="$b:$ctx "
  done
done
if [[ "$(tr ' ' '\n' <<<"${found% }" | sort | tr '\n' ' ')" == "$(tr ' ' '\n' <<<"$known_set" | sort | tr '\n' ' ')" ]]; then
  ok "arm4 collision set is exactly the known one ($known_set)"
else
  no "arm4 collision set changed: [${found% }] — a second workflow now reports a required context"
fi

printf '\nmerge_queue_triggers_unit: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
