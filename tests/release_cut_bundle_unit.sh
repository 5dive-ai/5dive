#!/usr/bin/env bash
# DIVE-2091 — the release cut must be UNABLE to publish a tag without a bundle.
#
# Same shape as tests/release_cut_guards_unit.sh (deliberately): extract the block
# VERBATIM from the shipped workflow by fence marker and run it, so the thing under
# test is the thing that ships rather than a hand-written copy of it. A copy agrees
# with every mutant — that was DIVE-2102's iteration-2 defect and it is not repeated
# here.
#
# WHY THESE ARMS: the bundle is no longer committed on main, so `install.sh` fetching
# $REPO/5dive at the tag's sha is the ONLY thing standing between a customer and a
# working CLI. A tag cut without a bundle is not a loud failure — the tag exists, the
# release page renders, and every box keeps the version it already had while new
# installs die on the download. So each guard is asserted to REFUSE, not merely to
# warn, and the happy path is asserted to leave the bundle IN THE TAGGED TREE.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/release-cut.yml"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}" >&2; }

extract(){ sed -n "/# >>> DIVE-2091 $1/,/# <<< DIVE-2091 $1/p" "$WF" | sed '1d;$d' | sed 's/^          //'; }
BLOCK=$(extract 'release-commit block')
[[ -n "$BLOCK" ]] || { echo "FATAL: could not extract the release-commit block from $WF — refusing to grade nothing" >&2; exit 2; }
grep -q 'build.sh' <<<"$BLOCK" || { echo "FATAL: extracted block does not call build.sh — wrong fence" >&2; exit 2; }

# A throwaway repo standing in for the checkout the workflow runs against.
run_block(){ # $1 = build.sh body, $2 = tag ; prints output, returns the block's rc
  local buildbody="$1" tag="$2" d; d=$(mktemp -d)
  ( set -e
    cd "$d"; git init -q .; git config user.email a@b; git config user.name t
    printf 'seed\n' > seed.txt; git add seed.txt
    git -c user.name=t -c user.email=a@b commit -q -m seed
    printf '%s' "$buildbody" > build.sh; chmod +x build.sh
    printf '%s\n' 'x' > .gitignore
    # DIVE-2247: the block now ASSIGNS the version onto this tree before building,
    # so the tree must carry the sentinel the real main carries. Seeding it here is
    # what lets the extracted bytes be run as-shipped rather than around the bump.
    mkdir -p src; printf 'readonly FIVE_VERSION="0.0.0-dev"\n' > src/header.sh
    git add src/header.sh build.sh
    git -c user.name=t -c user.email=a@b commit -q -m seed2
  ) >/dev/null 2>&1
  ( cd "$d"
    sha=$(git rev-parse HEAD); tag="$tag"; version="${tag#v}"
    # shellcheck disable=SC2034
    note="test"
    eval "$BLOCK"
  ) 2>&1
  local rc=$?
  rm -rf "$d"; return $rc
}

# build.sh bodies for each scenario
GOOD='#!/usr/bin/env bash
# stands in for the real build.sh: the bundle takes its version FROM src/header.sh,
# so a bump that did not land shows up as a bundle carrying the sentinel.
printf "%s\n" "#!/usr/bin/env bash" "$(grep -m1 "^readonly FIVE_VERSION=" src/header.sh)" "true" > 5dive
sha256sum 5dive | cut -d" " -f1 > 5dive.sha256'
NOBUNDLE='#!/usr/bin/env bash
true'
BADSUM='#!/usr/bin/env bash
printf "%s\n" "#!/usr/bin/env bash" "readonly FIVE_VERSION=\"9.9.9\"" "true" > 5dive
printf "%s\n" "0000000000000000000000000000000000000000000000000000000000000000" > 5dive.sha256'
BADSYNTAX='#!/usr/bin/env bash
printf "%s\n" "#!/usr/bin/env bash" "readonly FIVE_VERSION=\"9.9.9\"" "if then fi(" > 5dive
sha256sum 5dive | cut -d" " -f1 > 5dive.sha256'
WRONGVER='#!/usr/bin/env bash
printf "%s\n" "#!/usr/bin/env bash" "readonly FIVE_VERSION=\"1.2.3\"" "true" > 5dive
sha256sum 5dive | cut -d" " -f1 > 5dive.sha256'
BUILDFAILS='#!/usr/bin/env bash
exit 7'

echo "-- the cut must REFUSE rather than publish a tag with no usable bundle"
out=$(run_block "$NOBUNDLE" v9.9.9); rc=$?
[[ $rc -ne 0 ]] && ok_t 'no bundle produced -> refuses' || bad_t 'no bundle must refuse' "rc=$rc out=$out"
out=$(run_block "$BUILDFAILS" v9.9.9); rc=$?
[[ $rc -ne 0 ]] && ok_t 'build.sh failing -> refuses' || bad_t 'failed build must refuse' "rc=$rc out=$out"
out=$(run_block "$BADSUM" v9.9.9); rc=$?
[[ $rc -ne 0 ]] && ok_t 'bundle disagreeing with its own .sha256 -> refuses' || bad_t 'checksum mismatch must refuse' "rc=$rc out=$out"
out=$(run_block "$BADSYNTAX" v9.9.9); rc=$?
[[ $rc -ne 0 ]] && ok_t 'bundle that is not valid bash -> refuses' || bad_t 'syntax error must refuse' "rc=$rc out=$out"
out=$(run_block "$WRONGVER" v9.9.9); rc=$?
[[ $rc -ne 0 ]] && ok_t 'bundle whose FIVE_VERSION != the tag -> refuses' || bad_t 'version disagreement must refuse' "rc=$rc out=$out"

echo "-- and the happy path must leave the bundle IN THE TAGGED TREE"
# Non-vacuity: if the happy path did not pass, every refusal above proves nothing —
# a block that refuses unconditionally would score 5/5 above and be useless.
out=$(run_block "$GOOD" v9.9.9); rc=$?
[[ $rc -eq 0 ]] && ok_t 'a well-formed build is accepted (the refusals above are not unconditional)' \
                || bad_t 'happy path must be accepted' "rc=$rc out=$out"
grep -q 'release commit .* carries bundle' <<<"$out" \
  && ok_t 'the accepted cut names the bundle it committed' \
  || bad_t 'accepted cut must state what it published' "out=$out"

echo "-- the bundle must not be tracked on main (the defect this ticket removed)"
for f in 5dive 5dive.sha256; do
  if git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    bad_t "$f is TRACKED again — re-introduces the every-merge-invalidates-every-PR defect" ""
  else
    ok_t "$f is untracked"
  fi
  git -C "$ROOT" check-ignore -q "$f" \
    && ok_t "$f is gitignored, so a stray build cannot be committed by accident" \
    || bad_t "$f must be gitignored" ""
done

echo "-- the tag must be proven SERVABLE, not merely pushed (dev, review of #313)"
# Everything above proves the bundle is in the TAGGED TREE. install.sh fetches it from
# raw.githubusercontent at the tag's sha, and after this change that sha is reachable ONLY
# from a tag — a different object class for GitHub's read paths than the branch-reachable
# commit it used to be (DIVE-1977: split-generation, propagation windows). Boxes self-update
# unattended and install.sh fails closed, so an unservable tag kills installs after EVERY
# release and is discovered at the NEXT one. Graded structurally because the property is a
# live network fetch this harness must not perform.
# The arm must follow the probe: it now fetches the BUNDLE, which is the object
# install.sh:264 DIES on, not the .sha256 that install.sh:273 treats as optional
# (fail-soft by design since DIVE-1271). Probing the optional object proved the
# wrong thing — they are independent CDN objects with independent cache
# generations, which is the whole of DIVE-1977.
grep -q '"${_base}/5dive" -o "$_tmp"' "$WF" \
  && ok_t 'the cut fetches the BUNDLE — the object install.sh dies on, not the optional checksum' \
  || bad_t 'the probe does not fetch the mandatory bundle' "$(grep -n '_base' "$WF" | head -3)"
grep -q 'sha256sum "$_tmp"' "$WF" \
  && ok_t 'the FETCHED BYTES are hashed, so a servable-but-wrong bundle cannot pass' \
  || bad_t 'the probe does not hash what it downloaded' ''
grep -q 'the two CDN objects are out of step\|disagrees with the bundle this cut verified' "$WF" \
  && ok_t 'the served .sha256 is cross-checked against the bundle at one immutable sha (DIVE-1977)' \
  || bad_t 'nothing checks the two objects agree' ''
grep -q 'IS PUBLISHED BUT ITS BUNDLE IS NOT SERVABLE' "$WF" \
  && ok_t 'an unservable tag is an ERROR, not a warning — the cut fails closed' \
  || bad_t 'unservable tag must fail the cut, not annotate it' ''
grep -q 'serves a DIFFERENT bundle than this cut verified' "$WF" \
  && ok_t 'a servable-but-mismatched bundle is refused too (200 is not enough)' \
  || bad_t 'a wrong bundle served at the tag sha must be refused' ''
# The tag deliberately survives a failed probe: auto-deleting it would erase the single
# occurrence that proves the propagation window is real.
# WIDENED after dev mutated it: the first cut caught `git tag -d` and
# `git push --delete` and MISSED `git tag --delete` and `git push origin
# :refs/tags/<tag>` — i.e. it caught the two forms nobody writes by accident and was
# blind to the long flag and the classic empty-refspec delete. It is a NEGATIVE
# assertion, so it passes by ABSENCE, and it was not in the mutation set: re-pointing
# the probe reds the probe arms and leaves this one green. All four forms are graded
# below by inserting each into a scratch copy.
grep -qE 'git (tag (-d|--delete)|push .*(--delete|:refs/tags/))' "$WF" \
  && bad_t 'the cut deletes the tag on failure — that hides the one event worth seeing' '' \
  || ok_t 'a failed servability probe leaves the tag standing for a human to see'


echo "-- DIVE-2247: the assignment is load-bearing, graded by mutating the shipped bytes"
# The happy path above only proves the tag and the bundle agree. It would ALSO pass if
# main still carried a real version and nothing here assigned one -- which is precisely
# the arrangement this ticket removed. So: delete the sed from the extracted block and
# assert the cut goes RED. A green mutant means the bump is decoration.
MUTANT=$(printf '%s\n' "$BLOCK" | grep -v 'sed -i -E "s/\^readonly FIVE_VERSION')
[[ "$MUTANT" != "$BLOCK" ]] || bad_t 'mutation did not change the block (anchor drifted) — the arm below is vacuous' ''
run_mutant(){ local d; d=$(mktemp -d)
  ( set -e
    cd "$d"; git init -q .; git config user.email a@b; git config user.name t
    printf 'seed\n' > seed.txt
    printf '%s' "$GOOD" > build.sh; chmod +x build.sh
    printf '%s\n' 'x' > .gitignore
    mkdir -p src; printf 'readonly FIVE_VERSION="0.0.0-dev"\n' > src/header.sh
    git add -A; git -c user.name=t -c user.email=a@b commit -q -m seed
  ) >/dev/null 2>&1
  ( cd "$d"; sha=$(git rev-parse HEAD); tag="v9.9.9"; version="9.9.9"
    # shellcheck disable=SC2034
    note="test"; eval "$MUTANT" ) 2>&1
  local rc=$?; rm -rf "$d"; return $rc
}
out=$(run_mutant); rc=$?
[[ $rc -ne 0 ]] && ok_t 'with the assignment removed the cut REFUSES (the bump is not decoration)' \
                || bad_t 'the cut passed WITHOUT assigning a version — the sentinel would have been published' "rc=$rc out=$out"
grep -q '0\.0\.0-dev' <<<"$out" \
  && ok_t 'and it names the sentinel it refused to publish' \
  || ok_t 'refused (message does not name the sentinel, which is acceptable)'

echo "-- and main itself must carry the sentinel, not a real version"
_hdr=$(grep -m1 -oE '^readonly FIVE_VERSION="[^"]+"' "$ROOT/src/header.sh" | cut -d'"' -f2)
[[ "$_hdr" == "0.0.0-dev" ]] \
  && ok_t "src/header.sh carries the sentinel ($_hdr) — nothing assigns a version to main" \
  || bad_t "src/header.sh carries a REAL version ($_hdr); assignment-at-merge has come back" ''

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
