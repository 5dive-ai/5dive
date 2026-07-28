#!/usr/bin/env bash
# DIVE-1977: install.sh must fetch the bundle and its .sha256 from ONE immutable
# commit sha, not from the mutable `main` ref — two independent CDN objects under
# /main can be served from different cache generations for a window after every
# release, which fails the checksum guard with a tamper-shaped message on an
# unattended nightly self-update.
#
# DIVE-2144: and the sha it pins must come from the newest RELEASE TAG, not from
# the tip of main. Merging must stage; cutting a tag must publish. Two failure
# modes here succeed-in-appearance rather than erroring, so both are asserted by
# MUTATION at the bottom of this file rather than by a happy-path check alone:
#   (a) resolving main instead of a tag  — publishes every unreviewed merge
#   (b) `sort` instead of `sort -V`      — resolves v0.9.9 as "newest" and ships
#                                          every box a six-minor DOWNGRADE, exit 0
#
# Hermetic by construction: the pin-resolution block is extracted verbatim from
# install.sh and run against STUBBED git/curl on PATH, so this harness makes no
# network calls and asserts the real shipped code, not a paraphrase of it.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# TAG_OLD sorts LEXICALLY ABOVE TAG_NEW ("9" > "1"), which is the real shape of
# the repo: `sort | tail -1` over its 285 tags returns v0.9.9, `sort -V` returns
# v0.15.34. Every tag-resolution case below would pass under a lexical sort if
# the fixtures did not straddle that boundary.
TAG_NEW="v0.15.34"
TAG_OLD="v0.9.9"
SHA_NEW="1111111111111111111111111111111111111111"
SHA_OLD="2222222222222222222222222222222222222222"
SHA_TAGOBJ="9999999999999999999999999999999999999999"   # annotated tag OBJECT — raw/ does not serve it
SHA_DIRECT="3333333333333333333333333333333333333333"

block="$(sed -n '/^# >>> DIVE-1977 pin-resolution block/,/^# <<< DIVE-1977 pin-resolution block/p' install.sh)"
if [[ -n "$block" ]] && grep -q 'resolve_gh_sha()' <<<"$block" && grep -q 'resolve_gh_tag()' <<<"$block"; then
  ok_t "pin-resolution block is extractable from install.sh"
else
  bad_t "pin-resolution block missing" "markers '# >>> / # <<< DIVE-1977 pin-resolution block' (with resolve_gh_tag + resolve_gh_sha) not found in install.sh"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Run an extracted block under install.sh's real flags (`set -euo pipefail`,
# line 6) with $2/$3 as the git/curl stub behaviour, and echo the resolved
# REPO + GH_PINNED_SHA. Stubs shadow the real binaries via PATH. stdout and
# stderr are BOTH captured (the fail-closed cases assert on stderr) and the exit
# status is appended as RC=<n>.
run_block_with() { # $1=block  $2=git stub  $3=curl stub  [$4=REPO] [$5=GH_SHA] [$6=argv1]
  local blk="$1" stubs out rc; stubs="$(mktemp -d)"
  if [[ -n "$2" ]]; then printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stubs/git"; chmod +x "$stubs/git"; fi
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$stubs/curl"; chmod +x "$stubs/curl"
  # PATH is stubs-first but keeps the real tools the block needs (awk/sed/head/
  # grep/sort). A stub that exits nonzero stands in for "git present but can't
  # resolve" and for "git absent" alike: both leave the ladder empty.
  out="$(env -i PATH="$stubs:/usr/bin:/bin" GH_ORG="testorg" \
    ${4+REPO="$4"} ${5+GH_SHA="$5"} \
    bash -c "set -euo pipefail
$blk
printf 'REPO=%s\nPIN=%s\n' \"\$REPO\" \"\$GH_PINNED_SHA\"" install.sh ${6:+"$6"} 2>&1)"
  rc=$?
  rm -rf "$stubs"
  printf '%s\nRC=%s\n' "$out" "$rc"
}
run_block() { run_block_with "$block" "$@"; }

# --- stubs -------------------------------------------------------------------
# git: the tag LIST query carries --refs; the per-tag sha query does not.
# TAG_NEW is annotated (tag object + ^{} peel), TAG_OLD is lightweight.
git_stub='case "$*" in
  *--refs*) printf "aaaaaaa\trefs/tags/'"$TAG_OLD"'\nbbbbbbb\trefs/tags/'"$TAG_NEW"'\n" ;;
  *"refs/tags/'"$TAG_NEW"'"*) printf "'"$SHA_TAGOBJ"'\trefs/tags/'"$TAG_NEW"'\n'"$SHA_NEW"'\trefs/tags/'"$TAG_NEW"'^{}\n" ;;
  *"refs/tags/'"$TAG_OLD"'"*) printf "'"$SHA_OLD"'\trefs/tags/'"$TAG_OLD"'\n" ;;
  *) exit 1 ;;
esac'
# curl: tags.atom lists both tags; commits/<tag>.atom yields that tag's commit.
atom_stub='case "$*" in
  *tags.atom*) printf "<id>tag:github.com,2008:Repository/1239570688/'"$TAG_OLD"'</id>\n<title>'"$TAG_OLD"' — a release headline</title>\n<id>tag:github.com,2008:Repository/1239570688/'"$TAG_NEW"'</id>\n<title>'"$TAG_NEW"' — a release headline</title>\n" ;;
  *commits/'"$TAG_NEW"'.atom*) printf "<id>tag:github.com,2008:Grit::Commit/'"$SHA_NEW"'</id>\n" ;;
  *commits/'"$TAG_OLD"'.atom*) printf "<id>tag:github.com,2008:Grit::Commit/'"$SHA_OLD"'</id>\n" ;;
  *) exit 22 ;;
esac'
# curl: api.github.com only — the last rung of both ladders.
api_stub='case "$*" in
  *api.github.com*/tags*) printf "{\"name\": \"'"$TAG_OLD"'\"}\n{\"name\": \"'"$TAG_NEW"'\"}\n" ;;
  *api.github.com*commits/'"$TAG_NEW"'*) printf "{\"sha\": \"'"$SHA_NEW"'\", \"commit\": {}}\n" ;;
  *api.github.com*commits/'"$TAG_OLD"'*) printf "{\"sha\": \"'"$SHA_OLD"'\", \"commit\": {}}\n" ;;
  *) exit 22 ;;
esac'

# The tag-rail property, factored out so the mutants below are graded by the
# SAME assertion the real block is graded by.
pins_newest_tag() { # $1=block ; 0 = REPO pinned to the newest tag's commit sha
  local out; out="$(run_block_with "$1" "$git_stub" "exit 22")"
  [[ "$out" == *"REPO=https://raw.githubusercontent.com/testorg/5dive/$SHA_NEW"* && "$out" == *"PIN=$SHA_NEW"* ]]
}

# 1. git resolves → REPO pinned to the NEWEST tag's commit, version-sorted, and
#    peeled through the annotated tag object.
if pins_newest_tag "$block"; then
  ok_t "git ls-remote pins REPO to the newest release tag's commit ($TAG_NEW, not $TAG_OLD, not main)"
else
  bad_t "newest release tag did not pin REPO" "got: $(run_block "$git_stub" "exit 22" | tr '\n' '|')"
fi

# 2. git absent/broken → tags.atom + commits/<tag>.atom fallback pins the same tag.
out="$(run_block "exit 1" "$atom_stub")"
if [[ "$out" == *"PIN=$SHA_NEW"* ]]; then
  ok_t "atom-feed fallback resolves the same newest tag (fresh box, git not installed yet)"
else
  bad_t "atom-feed fallback did not pin the newest tag" "got: ${out//$'\n'/ | }"
fi

# 3. git + atom both fail → api.github.com last resort pins the same tag.
out="$(run_block "exit 1" "$api_stub")"
if [[ "$out" == *"PIN=$SHA_NEW"* ]]; then
  ok_t "api.github.com is the last-resort tag resolver"
else
  bad_t "api.github.com fallback did not pin the newest tag" "got: ${out//$'\n'/ | }"
fi

# 4. DIVE-2144: NO TAG RESOLVES → FAIL CLOSED. Never fall back to ungated main.
#    This is a no-op, not a brick: an installed box keeps the CLI it has, which
#    is where it already was. The error must name both explicit valves out
#    (GH_SHA, REPO) so an operator leaves the guarantee by choosing to.
out="$(run_block "exit 1" "exit 22")"
if [[ "$out" != *"REPO=https"* ]] && [[ "$out" == *"RC=1"* ]] \
   && [[ "$out" == *"NO RELEASE TAG RESOLVED"* ]] \
   && [[ "$out" == *"GH_SHA"* && "$out" == *"REPO=<base url>"* ]]; then
  ok_t "no tag resolvable fails CLOSED, naming GH_SHA and REPO — never falls back to /main"
else
  bad_t "unresolvable tag did not fail closed" "got: ${out//$'\n'/ | }"
fi

# 5. Tag resolves but its commit does not → also fail closed, and say which tag.
half_stub='case "$*" in
  *--refs*) printf "bbbbbbb\trefs/tags/'"$TAG_NEW"'\n" ;;
  *) exit 1 ;;
esac'
out="$(run_block "$half_stub" "exit 22")"
if [[ "$out" != *"REPO=https"* ]] && [[ "$out" == *"RC=1"* ]] && [[ "$out" == *"$TAG_NEW RESOLVED BUT ITS COMMIT DID NOT"* ]]; then
  ok_t "tag-without-commit fails closed and names the tag"
else
  bad_t "tag-without-commit did not fail closed" "got: ${out//$'\n'/ | }"
fi

# 6. A lightweight (unannotated) tag has no ^{} peel — its own sha IS the commit.
light_stub='case "$*" in
  *--refs*) printf "aaaaaaa\trefs/tags/'"$TAG_OLD"'\n" ;;
  *"refs/tags/'"$TAG_OLD"'"*) printf "'"$SHA_OLD"'\trefs/tags/'"$TAG_OLD"'\n" ;;
  *) exit 1 ;;
esac'
out="$(run_block "$light_stub" "exit 22")"
if [[ "$out" == *"PIN=$SHA_OLD"* ]]; then
  ok_t "lightweight tag pins its own sha (no ^{} peel to prefer)"
else
  bad_t "lightweight tag did not pin" "got: ${out//$'\n'/ | }"
fi

# 7. A caller-supplied REPO (offline smoke bundle, enterprise mirror) is never
#    re-pinned, never claims a pin, and is NOT subject to the tag rail — the
#    offline install-smoke must keep working with no tags in sight.
out="$(run_block "exit 1" "exit 22" "file:///opt/5dive-bundle")"
if [[ "$out" == *"REPO=file:///opt/5dive-bundle"* && "$out" == *"PIN="$'\n'* && "$out" == *"RC=0"* ]]; then
  ok_t "explicit REPO override is untouched, claims no pin, and survives an unresolvable tag"
else
  bad_t "explicit REPO override was clobbered, falsely claimed a pin, or was failed closed" "got: ${out//$'\n'/ | }"
fi

# 8. GH_SHA pins directly with zero resolution (works with no git and no network).
out="$(run_block "exit 1" "exit 22" "" "$SHA_DIRECT")"
if [[ "$out" == *"REPO=https://raw.githubusercontent.com/testorg/5dive/$SHA_DIRECT"* && "$out" == *"PIN=$SHA_DIRECT"* ]]; then
  ok_t "GH_SHA pins directly without any resolution (rollback / CI / air-gap valve)"
else
  bad_t "GH_SHA did not pin" "got: ${out//$'\n'/ | }"
fi
# (case 8 passes REPO="" explicitly — assert the empty override is treated as unset)

# 9. The bundle and its checksum must be fetched from the SAME base. A future
#    edit that reintroduces a hardcoded /main URL for either one re-opens the race.
if grep -nE '^\s*(curl .*|_want="\$\(curl .*)"?https://raw\.githubusercontent\.com/[^"]*/main/5dive' install.sh; then
  bad_t "a fetch of the bundle or its sha256 hardcodes the mutable /main ref" "must go through \$REPO"
else
  ok_t "bundle + sha256 are both fetched through \$REPO (one pinned base)"
fi

# 10. The guard is NOT weakened — mismatch is still fatal — but the message no
#     longer collapses cache skew into tampering.
if grep -q 'checksum mismatch' install.sh && grep -cq 'die "5dive bundle checksum mismatch' install.sh; then
  ok_t "mismatch is still fatal (die), guard not weakened"
else
  bad_t "mismatch guard weakened or removed"
fi
pinned_msg="$(grep -c 'immutable tree \$GH_PINNED_SHA' install.sh)"
skew_msg="$(grep -c 'different CDN cache generations' install.sh)"
if [[ "$pinned_msg" -ge 1 && "$skew_msg" -ge 1 ]]; then
  ok_t "mismatch message distinguishes pinned bad-bytes from unpinned cache skew"
else
  bad_t "mismatch message still collapses stale-mirror into tampering" \
    "pinned-branch=$pinned_msg skew-branch=$skew_msg (want >=1 each)"
fi

# 11. --uninstall must NOT be gated on the release rail. Fail-closed exists to
#     stop us publishing ungated code, not to trap a box with software it wants
#     to remove: "we cannot publish right now" must never become "you cannot
#     uninstall". Total-failure stubs + --uninstall must still exit 0.
out="$(run_block_with "$block" "exit 1" "exit 22" "" "" "--uninstall")"
if [[ "$out" == *"RC=0"* ]] && [[ "$out" != *"NO RELEASE TAG RESOLVED"* ]]; then
  ok_t "--uninstall is not gated on tag resolution (fail-closed never traps a removal)"
else
  bad_t "--uninstall was blocked by the tag rail" "got: ${out//$'\n'/ | }"
fi

# --- NON-VACUITY: the two ways to get DIVE-2144 wrong must both go RED --------
# An instrument that only distinguishes tag-from-main has graded HALF the change:
# it passes happily while the resolver returns the WRONG tag. Both mutants are
# sed edits on the REAL extracted block, and each mutation is asserted to have
# actually changed something first — a mutant that failed to apply grades green
# for the same reason a passing test does, which is exactly the trap.
mutant_red() { # $1=label  $2=sed expr
  local mutant; mutant="$(sed "$2" <<<"$block")"
  if [[ "$mutant" == "$block" ]]; then
    bad_t "mutation '$1' did not apply" "sed '$2' changed nothing — the arm is vacuous, not passing"
    return
  fi
  if pins_newest_tag "$mutant"; then
    bad_t "mutation '$1' still passes" "the tag assertion cannot detect this bug"
  else
    ok_t "mutation '$1' is caught (assertion is non-vacuous)"
  fi
}
# (a) publish from mutable main, i.e. the pre-2144 behaviour this ticket retires.
mutant_red "pins main instead of the tag" 's#/5dive/\$GH_PINNED_SHA#/5dive/main#'
# (b) lexical sort — resolves v0.9.9 as "newest" and ships a downgrade, exit 0.
mutant_red "lexical sort picks v0.9.9 as newest" 's/sort -V/sort/'

echo; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
