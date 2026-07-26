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
git -C "$REPO" checkout -q -b "$B" 2>/dev/null
v0=$(grep -m1 -oE 'FIVE_VERSION="[^"]+"' "$REPO/src/header.sh")
printf '\n# version-assign apply probe\n' >> "$REPO/src/cmd_task.sh"
( cd "$REPO" && ./build.sh >/dev/null 2>&1 )
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qam "probe: bundle moves, version does not"
out=$( cd "$REPO" && bash "$SNAP" HEAD HEAD~1 --apply 2>&1 ); rc=$?
if grep -q 'applied 0.16.20 -> 0.16.21' <<<"$out"; then ok "F --apply bumps the real repo 0.16.20 -> 0.16.21"; else no "F apply" "$out"; fi
grep -q 'NO TAG' <<<"$out" && ok "F --apply states NO TAG (releases are batched)" || no "F tag" "$out"
if grep -q 'FIVE_VERSION="0.16.21"' "$REPO/5dive"; then ok "F the new version is EMBEDDED in the rebuilt bundle"; else no "F embed" "bundle not rebuilt with the bump"; fi
built=$(sha256sum "$REPO/5dive" | cut -d' ' -f1)
[[ "$built" == "$(cut -d' ' -f1 < "$REPO/5dive.sha256")" ]] && ok "F rebuilt bundle matches 5dive.sha256" || no "F sha" "mismatch"
git -C "$REPO" reset -q --hard HEAD~1 2>/dev/null
git -C "$REPO" checkout -q - 2>/dev/null; git -C "$REPO" branch -qD "$B" 2>/dev/null
[[ "$(grep -m1 -oE 'FIVE_VERSION="[^"]+"' "$REPO/src/header.sh")" == "$v0" ]] \
  && ok "F the probe left the working tree at its original version" || no "F cleanup" "tree not restored"

echo; echo "DIVE-2118 version-assign: passed: $P  failed: $F"
[ "$F" -eq 0 ]
