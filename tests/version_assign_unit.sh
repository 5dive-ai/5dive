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
d=$(mk 0.16.19 aaa 0.16.20 bbb); out=$(run "$d")
grep -q 'no assignment needed' <<<"$out" && grep -q 'already moved' <<<"$out" \
  && ok "B version already assigned -> nothing owed" || no "B" "$out"

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
# restores ONLY the paths it touches, never -a and never --hard, and the SENTINEL
# below grades that. A harness that eats your working tree gets run once.
PROBE_FILES=(src/cmd_task.sh src/header.sh 5dive 5dive.sha256)
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
tail -1 "$REPO/$SENTINEL" | grep -q 'harness sentinel' \
  && ok "F SENTINEL: an unrelated uncommitted edit survived the probe (no commit -a, no reset --hard)" \
  || no "F sentinel" "the probe ate an unrelated working-tree modification — it did exactly this during iteration 2"
git -C "$REPO" checkout -q -- "$SENTINEL"

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

echo; echo "DIVE-2118 version-assign: passed: $P  failed: $F"
[ "$F" -eq 0 ]
