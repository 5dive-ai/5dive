#!/usr/bin/env bash
# DIVE-2118 harness for scripts/version-assign.sh — the performer half of the
# "version is assigned at MERGE" rule, whose prohibition half everyone follows and
# whose performance half was owned by nobody (#218/#219/#220/#221 all merged at
# 0.16.19 against a version already published with a different bundle).
#
# Decision arms are hermetic throwaway repos. The --apply arm runs in the REAL repo
# on a throwaway branch, because it must exercise the actual build.sh — a fixture
# build would be a reimplementation, and a reimplementation drifts exactly where the
# thing you are catching drifts.
#
# ARMS G AND H EXIST BECAUSE THIS HARNESS FAILED ITS OWN MUTATION TEST (iteration 1).
# The reviewer replaced two apply-path assertions with `true` and the harness stayed
# 16/16 GREEN: the self-grading added to compensate for the bump commit never seeing
# CI was ITSELF ungraded. G grades those two assertions by mutation; H grades the
# no-tag guarantee behaviourally instead of by its message.
# Run: bash tests/version_assign_unit.sh
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
cd "$(dirname "$0")/.."
REPO="$PWD"; S="$REPO/scripts/version-assign.sh"
TMP="$(mktemp -d /tmp/version-assign-unit.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   $2"; }

# fixture: base commit at $1/$2 (version/sha), then a second commit at $3/$4
mk() { local d="$TMP/$RANDOM$RANDOM"; mkdir -p "$d/src"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'readonly FIVE_VERSION="%s"\n' "$1" > "$d/src/header.sh"; printf '%s  5dive\n' "$2" > "$d/5dive.sha256"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf 'readonly FIVE_VERSION="%s"\n' "$3" > "$d/src/header.sh"; printf '%s  5dive\n' "$4" > "$d/5dive.sha256"
  # ALWAYS make the second commit non-empty: case C deliberately leaves version and
  # bundle identical, and an empty commit fails, which made mk() return git's error
  # text as the fixture path and reported a SCRIPT failure for a HARNESS bug.
  date +%s%N > "$d/unrelated.txt"
  git -C "$d" add -A; git -C "$d" commit -qm new
  printf '%s' "$d"; }
run(){ ( cd "$1" && bash "$S" HEAD HEAD~1 ) 2>&1; }

# A: THE DEFECT — bundle moved, version did not.
d=$(mk 0.16.19 aaa 0.16.19 bbb); out=$(run "$d"); rc=$?
(( rc == 0 )) && ok "A owed-assignment exits 0 (it is a finding, not an error)" || no "A rc" "$rc"
grep -q 'ASSIGNMENT OWED' <<<"$out" && ok "A names it as an owed assignment" || no "A" "$out"
grep -q 'next = 0.16.20' <<<"$out" && ok "A computes the next patch (0.16.19 -> 0.16.20)" || no "A next" "$out"
grep -q 'nothing written' <<<"$out" && ok "A is dry by default — no --apply, no write" || no "A dry" "$out"

# B: version already moved -> nothing owed (the merger did assign it).
# DIVE-2230 collapsed the two not-owed REASONS into one, because they were both
# proxies for the same absolute fact: main's bundle is the bundle its version
# shipped. Here the anchor IS the head commit, so the sha it recorded is the sha at
# HEAD. The old wording ("FIVE_VERSION already moved") is gone deliberately — it
# described the delta, which is the thing that could be laundered.
d=$(mk 0.16.19 aaa 0.16.20 bbb); out=$(run "$d")
grep -q 'no assignment needed' <<<"$out" && grep -q '0.16.20 was assigned at' <<<"$out" \
  && ok "B version already assigned -> nothing owed, measured against that assignment" || no "B" "$out"

# C: bundle unchanged (workflow/doc-only push) -> exempt.
d=$(mk 0.16.19 aaa 0.16.19 aaa); out=$(run "$d")
grep -q 'bundle is unchanged' <<<"$out" && ok "C doc-only push is exempt" || no "C" "$out"

# D: NON-SEMVER must refuse to guess, not invent a successor.
d=$(mk 0.16.19 aaa 0.16.19-rc1 bbb); out=$(run "$d")
grep -q 'no assignment needed' <<<"$out" && ok "D a moved non-semver version is already assigned" || no "D" "$out"
d=$(mk nightly aaa nightly bbb); out=$(run "$d"); rc=$?
(( rc == 2 )) && ok "D unparseable version exits 2, refusing to guess a successor" || no "D semver rc" "$rc: $out"

# E: UNDETERMINED is exit 2, says so, and its causes do not share one message.
d=$(mk 0.16.19 aaa 0.16.19 bbb)
out=$( cd "$d" && bash "$S" nosuchrev HEAD~1 2>&1 ); rc=$?
(( rc == 2 )) && ok "E missing rev exits 2, distinct from pass(0)" || no "E rc" "$rc"
grep -q 'NOT a pass' <<<"$out" && ok "E says explicitly it is not a pass" || no "E" "$out"
E1=$(sed "s/'[^']*'/'REF'/g" <<<"$out")
out2=$( cd "$d" && bash "$S" HEAD nosuchbase 2>&1 )
E2=$(sed "s/'[^']*'/'REF'/g" <<<"$out2")
[[ "$E2" != "$E1" ]] && ok "E the two UNDETERMINED causes emit different TEMPLATES (not folded)" \
  || no "E folded" "bad-new and bad-base read identically once refs are normalised"

# F: --apply in the REAL repo on a throwaway branch — exercises the actual build.sh.
B="va-apply-probe-$$"
# Snapshot the script BEFORE touching git: the first version of this arm ran
# `git stash -u`, which swallowed scripts/version-assign.sh itself (still untracked)
# and every assertion then failed with "No such file or directory" — the harness
# destroyed its own subject. Two assertions ALSO passed vacuously against the
# untouched tree, which is the worse half: a broken arm that still reports green.
SNAP="$TMP/version-assign.snapshot.sh"; cp "$S" "$SNAP"
# ...AND IT DESTROYED ITS SUBJECT A SECOND WAY. `commit -am` swept every OTHER
# modified file in the tree into the probe commit and `reset --hard HEAD~1` then
# deleted them: running the harness mid-edit silently ate the edits (measured during
# iteration 2 of this very ticket — it ate this file). The probe now commits and
# restores ONLY the paths it touches, never -a and never --hard.
#
# DIVE-2322: THAT NARROWING MOVED THE BLAST RADIUS, IT DID NOT REMOVE IT. Scoping the
# commit and the restore to PROBE_FILES protects every path OUTSIDE the list and
# nothing INSIDE it — `restore --source=HEAD --staged --worktree` discards both the
# staged and the worktree copy of an uncommitted edit to src/cmd_task.sh, the
# most-edited file in the CLI and the one anybody working on task-gate behaviour has
# open. It ate a working tree a third time on DIVE-2318. Worse, the SENTINEL that was
# meant to grade this used README.md, picked *because* it is not a probe file: the arm
# printed "an unrelated uncommitted edit survived the probe" on the very run that
# destroyed the operator's work, which turns "stash first" into "the harness says I do
# not need to". So this arm now REFUSES to run when a probe file is dirty, F0 grades
# that refusal, and the README sentinel says out loud what it does and does not cover.
PROBE_FILES=(src/cmd_task.sh src/header.sh 5dive 5dive.sha256)

# One dirty PROBE_FILE per line, staged or worktree. -uno on purpose: an UNTRACKED
# path is not in HEAD and so cannot be destroyed by a restore from HEAD, and refusing
# to run over a file that was never at risk is how a guard gets deleted.
probe_dirty() { local r="$1"; shift; git -C "$r" status --porcelain -uno -- "$@" | cut -c4-; }

# F0 GRADES THE REFUSAL, hermetically — it never touches the real repo. Without it the
# guard is an unexercised branch: on a clean tree (CI, and every honest run) it never
# fires, so a probe_dirty() that always returned empty would look exactly like this one.
gd="$TMP/guard$RANDOM$RANDOM"; mkdir -p "$gd/src"
git -C "$gd" init -q -b main; git -C "$gd" config user.email t@t; git -C "$gd" config user.name t
GP=(src/cmd_task.sh src/header.sh)
printf 'clean\n' > "$gd/src/cmd_task.sh"; printf 'clean\n' > "$gd/src/header.sh"
printf 'outside the probe set\n' > "$gd/README.md"
git -C "$gd" add -A; git -C "$gd" commit -qm base
[[ -z "$(probe_dirty "$gd" "${GP[@]}")" ]] \
  && ok "F0 CONTROL: the guard reports nothing on a clean tree (so a hit below is the edit, not noise)" \
  || no "F0 clean" "guard fired on a clean tree: $(probe_dirty "$gd" "${GP[@]}")"
printf 'wip\n' >> "$gd/README.md"
[[ -z "$(probe_dirty "$gd" "${GP[@]}")" ]] \
  && ok "F0 the guard is SCOPED: an edit OUTSIDE the probe set does not refuse the run" \
  || no "F0 scope" "the guard tripped on a path the probe never restores"
printf 'operator wip\n' >> "$gd/src/cmd_task.sh"
[[ "$(probe_dirty "$gd" "${GP[@]}")" == "src/cmd_task.sh" ]] \
  && ok "F0 a WORKTREE edit to a probe file is detected, and the path is named" \
  || no "F0 worktree" "got: $(probe_dirty "$gd" "${GP[@]}")"
git -C "$gd" add -- src/cmd_task.sh
[[ "$(probe_dirty "$gd" "${GP[@]}")" == "src/cmd_task.sh" ]] \
  && ok "F0 ...and so is a STAGED one — the restore takes --staged too, so both copies are at risk" \
  || no "F0 staged" "got: $(probe_dirty "$gd" "${GP[@]}")"

# F0b LIVENESS FOR THE GUARD, and the assertion the old SENTINEL should always have
# been. A refusal is only worth its cost if the thing it refuses really destroys work,
# so replay the exact sequence — commit -- paths, reset --soft, restore --source=HEAD —
# over a path list holding an uncommitted edit, and demand the edit is gone. Red here
# means the sequence became safe and the refusal can be relaxed; it does not mean
# scripts/version-assign.sh regressed.
git -C "$gd" -c user.email=t@t -c user.name=t commit -q -m probe -- "${GP[@]}"
git -C "$gd" reset -q --soft HEAD~1
git -C "$gd" restore --source=HEAD --staged --worktree -- "${GP[@]}"
grep -q 'operator wip' "$gd/src/cmd_task.sh" \
  && no "F0b the probe sequence no longer destroys an uncommitted edit to a PROBE file — the refusal below is now unnecessary and can be relaxed (DIVE-2322)" \
  || ok "F0b LIVENESS: the probe sequence really does destroy an uncommitted edit INSIDE its path list — the case the README sentinel never graded"
grep -q 'wip' "$gd/README.md" \
  && ok "F0b CONTROL: the same sequence leaves a path OUTSIDE the list untouched — that, and only that, is what the README sentinel proves" \
  || no "F0b outside" "the scoped commit/restore reached beyond its own path list"

# THE REFUSAL. Skip the destructive body entirely and count a FAIL, so the harness
# exits non-zero: an arm that cannot run safely says so rather than running anyway.
DIRTY=$(probe_dirty "$REPO" "${PROBE_FILES[@]}")
if [[ -n "$DIRTY" ]]; then
  no "F REFUSED: arm F did not run — it would have destroyed uncommitted work in the real repo" \
"$(printf '%s\n' "$DIRTY" | sed 's/^/       dirty probe file: /')
       This arm commits those paths, soft-resets, then restores them from HEAD, which
       discards the staged AND the worktree copy. Commit or stash them and re-run;
       a clean probe set makes the restore a no-op. Every other arm still ran.
       (DIVE-2322 — this ate src/cmd_task.sh during DIVE-2318.)"
else
  SENTINEL=$(cd "$REPO" && ls README.md CONTRIBUTING.md 2>/dev/null | head -1)
  trap 'git -C "$REPO" checkout -q -- "$SENTINEL" 2>/dev/null; rm -rf "$TMP"' EXIT
  printf '\n<!-- version-assign harness sentinel -->\n' >> "$REPO/$SENTINEL"

  git -C "$REPO" checkout -q -b "$B" 2>/dev/null
  v0=$(grep -m1 -oE 'FIVE_VERSION="[^"]+"' "$REPO/src/header.sh")
  # Derive the expected successor rather than hardcoding it: this arm asserted a literal
  # 0.16.20 -> 0.16.21, which turns into a false FAIL the moment main moves on, and a
  # harness that fails for calendar reasons teaches people to ignore it.
  cur=$(sed 's/.*"\(.*\)"/\1/' <<<"$v0")
  exp="${cur%.*}.$(( ${cur##*.} + 1 ))"
  printf '\n# version-assign apply probe\n' >> "$REPO/src/cmd_task.sh"
  ( cd "$REPO" && ./build.sh >/dev/null 2>&1 )
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "probe: bundle moves, version does not" -- "${PROBE_FILES[@]}"
  out=$( cd "$REPO" && bash "$SNAP" HEAD HEAD~1 --apply 2>&1 ); rc=$?
  if grep -q "applied $cur -> $exp" <<<"$out"; then ok "F --apply bumps the real repo $cur -> $exp"; else no "F apply" "$out"; fi
  grep -q 'NO TAG' <<<"$out" \
    && ok "F (MESSAGE ONLY) --apply prints NO TAG — grades the sentence, not the behaviour; arm H grades the behaviour" \
    || no "F tag msg" "$out"
  if grep -q "FIVE_VERSION=\"$exp\"" "$REPO/5dive"; then ok "F the new version is EMBEDDED in the rebuilt bundle"; else no "F embed" "bundle not rebuilt with the bump"; fi
  built=$(sha256sum "$REPO/5dive" | cut -d' ' -f1)
  [[ "$built" == "$(cut -d' ' -f1 < "$REPO/5dive.sha256")" ]] && ok "F rebuilt bundle matches 5dive.sha256" || no "F sha" "mismatch"
  git -C "$REPO" reset -q --soft HEAD~1
  git -C "$REPO" restore --source=HEAD --staged --worktree -- "${PROBE_FILES[@]}"
  git -C "$REPO" checkout -q - 2>/dev/null; git -C "$REPO" branch -qD "$B" 2>/dev/null
  [[ "$(grep -m1 -oE 'FIVE_VERSION="[^"]+"' "$REPO/src/header.sh")" == "$v0" ]] \
    && ok "F the probe left the working tree at its original version" || no "F cleanup" "tree not restored"
  # SCOPE, not safety. This grades the probe set's OUTER edge only — that no `commit -a`
  # and no `reset --hard` crept back in. It says NOTHING about edits to PROBE_FILES
  # themselves, which the restore still discards; that is the refusal's job above and
  # F0b's to grade. The old wording ("an unrelated uncommitted edit survived the probe")
  # read as "your tree is safe" and was printed by the runs that ate it.
  tail -1 "$REPO/$SENTINEL" | grep -q 'harness sentinel' \
    && ok "F SCOPE: an edit OUTSIDE the probe set survived (no commit -a, no reset --hard) — edits INSIDE it are NOT protected, hence the refusal above" \
    || no "F sentinel" "the probe ate a working-tree modification outside its path list — it did exactly this during iteration 2"
  git -C "$REPO" checkout -q -- "$SENTINEL"
fi

# ---------------------------------------------------------------------------
# G: MUTATION-GRADED APPLY ASSERTIONS.
# Arm F proves the HAPPY path. It does not prove that the apply path's two safety
# assertions do anything — the reviewer replaced both with `true` and F stayed green,
# because on the happy path neither ever fires. These arms drive the script INTO each
# assertion and demand that assertion's OWN message: delete the assertion and the
# script still fails, but with a DIFFERENT message, so the arm goes red.
#
# These use a fixture build.sh ON PURPOSE, and it is not the reimplementation F
# avoids: F already exercises the real build.sh on the honest path, and what is
# graded here is the ASSERTION, not the build. G0 is the positive control — without
# it a red G1/G2 would prove nothing, since a fixture broken for unrelated reasons is
# also red.
mkapply() { # $1 = honest|badsha
  local d="$TMP/apply$RANDOM$RANDOM"; mkdir -p "$d/src"
  git -C "$d" init -q -b main; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'readonly FIVE_VERSION="0.16.19"\n' > "$d/src/header.sh"
  printf 'aaa  5dive\n' > "$d/5dive.sha256"; printf 'placeholder\n' > "$d/5dive"
  {
    echo '#!/usr/bin/env bash'
    echo 'cat src/header.sh > 5dive'
    if [[ "$1" == badsha ]]; then
      # The build "succeeds" (exit 0) but records a sha that does not match the bundle
      # it just wrote. Exactly the drift the assertion exists to catch, and exactly
      # what a green exit code cannot tell you.
      echo 'printf "deadbeefdeadbeef  5dive\n" > 5dive.sha256'
    else
      echo 'printf "%s  5dive\n" "$(sha256sum 5dive | cut -d" " -f1)" > 5dive.sha256'
    fi
  } > "$d/build.sh"; chmod +x "$d/build.sh"
  git -C "$d" add -A; git -C "$d" commit -qm base
  printf 'bbb  5dive\n' > "$d/5dive.sha256"   # bundle moved, version did not
  git -C "$d" add -A; git -C "$d" commit -qm new
  printf '%s' "$d"; }

# G0 POSITIVE CONTROL: the fixture apply path works end to end.
d=$(mkapply honest); out=$( cd "$d" && bash "$S" HEAD HEAD~1 --apply 2>&1 ); rc=$?
(( rc == 0 )) && grep -q 'applied 0.16.19 -> 0.16.20' <<<"$out" \
  && ok "G0 CONTROL: honest fixture applies cleanly (so a red G1/G2 means the mutation, not a broken fixture)" \
  || no "G0 control" "rc=$rc $out"

# G1 grades the "rebuilt bundle does not match 5dive.sha256" assertion (reviewer's M5).
# With that assertion stubbed to true the script sails on: the bundle DOES contain the
# new version, so the next check passes and it exits 0 "applied" — silently blessing a
# bundle whose recorded sha is wrong. Hence: demand exit 2 AND this exact message.
d=$(mkapply badsha); out=$( cd "$d" && bash "$S" HEAD HEAD~1 --apply 2>&1 ); rc=$?
(( rc == 2 )) && ok "G1 MUTATION: a build that records a mismatched sha exits 2" || no "G1 rc" "$rc: $out"
grep -q 'rebuilt bundle does not match 5dive.sha256' <<<"$out" \
  && ok "G1 MUTATION: and fails with the sha-match assertion's OWN message (stub it to true and this goes red)" \
  || no "G1 msg" "$out"

# G2 grades the "the bump did NOT take in src/header.sh" assertion (reviewer's M3).
# A PATH shim no-ops ONLY in-place sed, which is precisely "the bump did not take";
# the script's other sed use (parsing FIVE_VERSION) still reaches the real sed, so the
# arm isolates the one behaviour. With the assertion stubbed, the script instead
# reaches the embedded-version check and dies with a DIFFERENT message — red.
REALSED="$(command -v sed)"
mkdir -p "$TMP/shim"
{ echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do [[ "$a" == -i* ]] && exit 0; done'
  echo "exec $REALSED \"\$@\""; } > "$TMP/shim/sed"; chmod +x "$TMP/shim/sed"
d=$(mkapply honest); out=$( cd "$d" && PATH="$TMP/shim:$PATH" bash "$S" HEAD HEAD~1 --apply 2>&1 ); rc=$?
(( rc == 2 )) && ok "G2 MUTATION: a no-op in-place sed (the bump silently not landing) exits 2" || no "G2 rc" "$rc: $out"
grep -q 'the bump did NOT take in src/header.sh' <<<"$out" \
  && ok "G2 MUTATION: and fails with the bump-took assertion's OWN message (stub it to true and this goes red)" \
  || no "G2 msg" "$out"

# H: NO TAG, BEHAVIOURALLY. Arm F greps the output for "NO TAG", which grades a
# sentence — a script that printed it and tagged anyway would pass. The real guarantee
# is that no tag verb exists anywhere in the SHIPPED files. (Only the shipped
# files are scanned: this harness does not run in CI, and it necessarily contains the
# very strings being searched for.)
#
# DIVE-2143 moved the push loop OUT of the YAML and into scripts/version-assign-push-loop.sh,
# so the scanned set had to move with it. A guarantee whose scope silently stops
# covering the code it was written for is worse than no guarantee — it still reports.
if grep -nEi 'git[[:space:]]+tag|gh[[:space:]]+release|refs/tags|--tags|create-release|action-gh-release' \
     "$REPO/scripts/version-assign.sh" "$REPO/scripts/version-assign-push-loop.sh" \
     "$REPO/scripts/git-push-reject-class.sh" "$REPO/.github/workflows/version-assign.yml"; then
  no "H a tag verb appears in a shipped file (bump yes, tag no — lodar froze releases)"
else
  ok "H BEHAVIOURAL: no tag verb (git tag / gh release / refs/tags / --tags) appears in either shipped file"
fi

# ---------------------------------------------------------------------------
# I: DIVE-2230 — THE FAILED ASSIGNMENT MUST NOT LAUNDER ITSELF GREEN.
#
# The regression case is NOT "a push fails". Arms A/G already cover that, and the
# BROKEN implementation passes them: at the failing commit itself the bundle did move
# in that push, so a delta check and an absolute check agree. The case is "a push
# fails, THEN an unrelated non-bundle commit lands" — the delta comes back clean, the
# obligation vanishes, and every subsequent run is green with main unassigned.
#
# So this arm is DIFFERENTIAL by construction. It runs the real script AND a mutant
# that restores the one line of old behaviour (anchor -> BASE), and demands they
# DISAGREE on the three-commit fixture while AGREEING on the two-commit one. A test
# that only asserts the real script would pass on an implementation that had merely
# been reworded.
mklaunder() { # v/sha at the assignment, then the failed-assign commit, then N doc commits
  local d="$TMP/launder$RANDOM$RANDOM" i; mkdir -p "$d/src"
  git -C "$d" init -q -b main; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'readonly FIVE_VERSION="0.16.19"\n' > "$d/src/header.sh"; printf 'aaa  5dive\n' > "$d/5dive.sha256"
  git -C "$d" add -A; git -C "$d" commit -qm "release: assign 0.16.19"
  # the merge whose assignment FAILED to push: bundle moved, version did not
  printf 'bbb  5dive\n' > "$d/5dive.sha256"; git -C "$d" add -A; git -C "$d" commit -qm "feat: bundle moves, assignment never landed"
  for (( i=0; i<${1:-0}; i++ )); do   # unrelated non-bundle pushes (workflow/doc-only)
    printf 'doc %s\n' "$i" > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm "docs: unrelated"
  done
  printf '%s' "$d"; }

# The mutant: one line, restoring exactly the semantics this ticket removed.
MUT="$TMP/version-assign.mutant.sh"
sed 's|^s_anchor=$(sha_at "$ANCHOR")$|s_anchor=$(sha_at "$BASE")|' "$S" > "$MUT"
# CONFIRM THE MUTATION LANDED. A sed that silently matched nothing would make every
# arm below compare the script against ITSELF and report a confident green.
if ! cmp -s "$S" "$MUT" && grep -q 's_anchor=$(sha_at "$BASE")' "$MUT"; then
  ok "I0 CONTROL: the mutant differs from the real script and carries the old base-relative line"
else
  no "I0 mutant" "the mutation did not land — every I arm below would be comparing the script to itself"
fi

# I1 THE FIRST HALF, where broken and fixed AGREE. Both must say OWED; if the mutant
# were simply broken rather than old, this is where it would show.
d=$(mklaunder 0)
real=$( cd "$d" && bash "$S"   HEAD HEAD~1 2>&1 )
mut=$(  cd "$d" && bash "$MUT" HEAD HEAD~1 2>&1 )
grep -q 'ASSIGNMENT OWED' <<<"$real" && ok "I1 at the failed-assign commit, the fixed script reports OWED" || no "I1 real" "$real"
grep -q 'ASSIGNMENT OWED' <<<"$mut"  && ok "I1 CONTROL: and so does the OLD behaviour — this half never discriminated" || no "I1 mut" "$mut"

# I2 THE SECOND HALF — the actual regression. One unrelated doc commit lands on top.
# Measured on the real repo as runs #268 (loud, correct) then #271 (green, wrong).
d=$(mklaunder 1)
real=$( cd "$d" && bash "$S"   HEAD HEAD~1 2>&1 ); rc=$?
mut=$(  cd "$d" && bash "$MUT" HEAD HEAD~1 2>&1 )
(( rc == 0 )) && ok "I2 owed-after-a-doc-commit still exits 0 (a finding, not an error)" || no "I2 rc" "$rc: $real"
grep -q 'ASSIGNMENT OWED' <<<"$real" \
  && ok "I2 REGRESSION: a doc-only commit ON TOP of a failed assignment still reports the debt" || no "I2 real" "$real"
grep -q 'next = 0.16.20' <<<"$real" && ok "I2 and still computes the successor it computed before the failure" || no "I2 next" "$real"
grep -q 'no assignment needed' <<<"$mut" \
  && ok "I2 DIFFERENTIAL: the OLD behaviour calls the same tree green — this arm discriminates" || no "I2 mut" "$mut"

# I3 the debt survives an ARBITRARY number of unrelated pushes, not just one. The
# erasure is permanent in the broken version, so a fix that only looked one commit
# further back would pass I2 and still be wrong.
d=$(mklaunder 5)
real=$( cd "$d" && bash "$S" HEAD HEAD~1 2>&1 )
grep -q 'ASSIGNMENT OWED' <<<"$real" && ok "I3 the debt survives 5 unrelated commits (absolute, not a wider window)" || no "I3" "$real"

# I4 NON-VACUITY. The fix must not answer OWED to everything: once the assignment
# actually lands, doc commits on top must go quiet. Without this arm, `exit 0 after
# echoing OWED` would pass I1-I3.
d=$(mklaunder 1)
printf 'readonly FIVE_VERSION="0.16.20"\n' > "$d/src/header.sh"   # the assignment lands
git -C "$d" add -A; git -C "$d" commit -qm "release: assign 0.16.20 at merge"
printf 'doc after\n' > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm "docs: unrelated"
real=$( cd "$d" && bash "$S" HEAD HEAD~1 2>&1 ); rc=$?
(( rc == 0 )) && grep -q 'no assignment needed' <<<"$real" \
  && ok "I4 NON-VACUITY: once the assignment lands, later doc commits report nothing owed" || no "I4" "$rc: $real"
grep -q 'assigned at' <<<"$real" \
  && ok "I4 and names the commit it measured against, so the claim is checkable" || no "I4 anchor named" "$real"

# J: A TRUNCATED HISTORY MUST REFUSE, NOT GUESS. The anchor walk is only as good as
# the history it can see, and CI checks out with a depth. If the assignment is below
# the graft, "the version never changed here" is indistinguishable from "this is the
# first version" — and quietly picking either restores the fail-open one layer down.
# Depth 2 on purpose: HEAD~1 resolves, so the BASE canary passes and this arm grades
# the ANCHOR path rather than the pre-existing base check.
d=$(mklaunder 3)
sh="$TMP/shallow$RANDOM"
if git clone -q --depth=2 "file://$d" "$sh" 2>/dev/null; then
  [[ "$(git -C "$sh" rev-parse --is-shallow-repository)" == "true" ]] \
    && ok "J CONTROL: the clone really is shallow (otherwise this arm proves nothing)" || no "J control" "not shallow"
  out=$( cd "$sh" && bash "$S" HEAD HEAD~1 2>&1 ); rc=$?
  (( rc == 2 )) && ok "J a shallow history exits 2 rather than reporting a clean tree" || no "J rc" "$rc: $out"
  grep -q 'SHALLOW' <<<"$out" && ok "J and names truncation as the cause, not the version" || no "J msg" "$out"
else
  no "J shallow clone could not be created — the arm did NOT run (this is not a pass)"
fi

echo; echo "DIVE-2118/2230 version-assign: passed: $P  failed: $F"
[ "$F" -eq 0 ]
