#!/usr/bin/env bash
# DIVE-2042: `5dive update --check` reported "OK — CLI 0.15.34 is up to date"
# twice, minutes apart, while main was already publishing 0.15.35. It fetched
# ONLY the bundle from raw/main, read a version off the stale cache generation,
# found it equal to the local version and rendered a confident green — to an
# operator asking exactly the question it could not answer.
#
# The window opens on EVERY push to main and main HEAD is what customer boxes
# self-update from, so this is not a control-host quirk. What is a defect rather
# than cache physics is reporting the window as "up to date": the check must
# answer in THREE states — up-to-date / behind / INDETERMINATE.
#
# Hermetic by construction, in the shape DIVE-1977 established: the probe block
# is extracted VERBATIM from src/cmd_selfupdate.sh between its fence markers and
# run against STUBBED git/curl on a minimal PATH, so this harness makes no
# network calls and asserts the shipped bytes rather than a paraphrase of them.
# sha256sum is the REAL one — the consistency check is genuinely exercised.
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SHA_MAIN="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4"
# DIVE-2287: the probe resolves the newest release TAG, because that is what
# install.sh installs. `main` is no longer a ref this block will ever read.
TAG_NEW="v0.15.35"

block="$(sed -n '/^# >>> DIVE-2042 published-version probe/,/^# <<< DIVE-2042 published-version probe/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_published_cli_probe()' <<<"$block"; then
  ok_t "probe block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "probe block missing" "markers '# >>> / # <<< DIVE-2042 published-version probe' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------- fixtures --
# Two real bundles a release apart, and the REAL sha256 of each. Serving
# bundle-old beside sum-new is the exact split the CDN produced on 2026-07-26.
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="0.15.34"\n' > "$FIX/bundle-old"
printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="0.15.35"\n' > "$FIX/bundle-new"
printf '#!/usr/bin/env bash\n# a bundle with no version line\n'  > "$FIX/bundle-nover"
for b in old new nover; do
  sha256sum "$FIX/bundle-$b" | awk '{print $1}' > "$FIX/sum-$b"
done

# A PATH containing ONLY the tools the block legitimately needs. This is what
# makes "git is absent" a real condition rather than a simulated one — omitting
# a stub while /usr/bin is on PATH would still find the host's git.
TOOLS="$FIX/tools"; mkdir -p "$TOOLS"
for t in bash mktemp sha256sum awk grep sed rm cp cat timeout sort head date tr tail cut jq dirname mkdir touch stat; do
  p="$(command -v "$t")" && ln -sf "$p" "$TOOLS/$t"
done

mk_curl() { # $1=file served as /5dive  $2=file served as /5dive.sha256 ('' both = fail every fetch)
            # $3=tags to serve on the atom feed ('' = the feed 404s too)
  local atom="${3:-}"
  if [[ -z "${1:-}" ]]; then
    # Fetches fail, but the atom rung may still resolve a tag — otherwise the
    # "unreachable bundle" case would be indistinguishable from "no tag".
    cat <<EOF
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
case "\$url" in
  *tags.atom) $( [[ -n "$atom" ]] && printf 'printf "%s"' "$(printf '<id>tag:github.com,2008:Repository/1/%s</id>\\n' $atom)" || printf 'exit 22' ) ;;
  *) exit 22 ;;
esac
exit 0
EOF
    return
  fi
  cat <<EOF
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2;;
    --max-time) shift 2;;
    -*) shift;;
    *) url="\$1"; shift;;
  esac
done
case "\$url" in
  *tags.atom) $( [[ -n "$atom" ]] && printf 'printf "%s"' "$(printf '<id>tag:github.com,2008:Repository/1/%s</id>\\n' $atom)" || printf 'exit 22' ) ;;
  */5dive.sha256) cp "$2" "\$out" ;;
  */5dive)        cp "$1" "\$out" ;;
  *) exit 22 ;;
esac
exit 0
EOF
}

run_probe() { # $1=git stub body ('' = git ABSENT)  $2=curl stub body
  local stubs; stubs="$(mktemp -d)"
  if [[ -n "$1" ]]; then printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stubs/git"; chmod +x "$stubs/git"; fi
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$stubs/curl"; chmod +x "$stubs/curl"
  # gh_org is stubbed rather than extracted: it lives in header.sh and does its
  # own network probe, which is not what this harness is grading.
  env -i PATH="$stubs:$TOOLS" HOME="$stubs" bash -c "set -euo pipefail
gh_org() { printf 'testorg\n'; }
$block
_published_cli_probe"
  local rc=$?; rm -rf "$stubs"; return $rc
}

# Deliberately UNSORTED and carrying a non-release tag: the block must pick the
# newest vX.Y.Z by `sort -V`, and must never advertise an rc as "latest" — the
# same filter install.sh applies before installing one.
GIT_TAGS="printf '%s\trefs/tags/v0.15.34\n%s\trefs/tags/v0.15.9\n%s\trefs/tags/$TAG_NEW\n%s\trefs/tags/v0.16.0-rc1\n' '$SHA_MAIN' '$SHA_MAIN' '$SHA_MAIN' '$SHA_MAIN'"
GIT_BROKEN='exit 128'   # git present, cannot reach the remote

line() { sed -n "$2p" <<<"$1"; }

# ------------------------------------------------------------------ cases --

# 1. THE REGRESSION. Stale bundle (0.15.34) beside the FRESH checksum — the
#    literal bytes raw.githubusercontent served on 2026-07-26. The old code
#    returned 0.15.34 here and the caller rendered "up to date".
out="$(run_probe "$GIT_TAGS" "$(mk_curl "$FIX/bundle-old" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == indeterminate ]]; then
  ok_t "stale bundle + fresh checksum => INDETERMINATE (the shipped bug)"
else
  bad_t "stale bundle + fresh checksum must not resolve" "got state '$(line "$out" 1)' version '$(line "$out" 2)'"
fi
if [[ "$(line "$out" 2)" != *0.15.34* ]]; then
  ok_t "no version is emitted from a split-generation read"
else
  bad_t "leaked the stale version" "line 2 was '$(line "$out" 2)'"
fi

# 2. Mismatch names the REF the claim is about (DIVE-1977's rule: a message may
#    only assert the cause it can justify). Both objects came from one immutable
#    tag, so a freshly cut tag mid-propagation and bad bytes are both live and
#    the message may not pick — but it must be checkable.
if [[ "$(line "$out" 3)" == *"does not match its own checksum"* && "$(line "$out" 3)" == *"$TAG_NEW"* ]]; then
  ok_t "mismatch names the tag the bundle came from"
else
  bad_t "mismatch message is wrong" "'$(line "$out" 3)'"
fi

# 3. The normal path. Both fetches come from raw/<tag>/, and the ref reported is
#    the tag — the same string install.sh resolved to install it.
out="$(run_probe "$GIT_TAGS" "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 2)" == "0.15.35" \
      && "$(line "$out" 3)" == "$TAG_NEW" ]]; then
  ok_t "consistent read => version 0.15.35 sourced from the newest release tag"
else
  bad_t "happy path wrong" "state '$(line "$out" 1)' ver '$(line "$out" 2)' ref '$(line "$out" 3)'"
fi

# 3b. DIVE-2287, THE DEFECT ITSELF. `main` is not a ref this block may read: it
#     is where the untagged 0.17.2 lived while the newest tag was v0.17.1, and
#     reading it is what told an operator they were behind a version no
#     installer could deliver. The stub serves ONLY the tag path — any fetch
#     from /main 404s — so a regression to main cannot resolve at all.
grep_main_free=1
out="$(run_probe "$GIT_TAGS" "$(cat <<EOF
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) out="\$2"; shift 2;; --max-time) shift 2;; -*) shift;; *) url="\$1"; shift;; esac
done
case "\$url" in
  */$TAG_NEW/5dive.sha256) cp "$FIX/sum-new" "\$out" ;;
  */$TAG_NEW/5dive)        cp "$FIX/bundle-new" "\$out" ;;
  *) exit 22 ;;
esac
exit 0
EOF
)")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 3)" == "$TAG_NEW" ]]; then
  ok_t "the probe fetches from raw/<tag>/ only — a read of main cannot resolve"
else
  bad_t "probe did not fetch from the tag path" "state '$(line "$out" 1)' ref '$(line "$out" 3)' — is it still reading main?"
fi

# 3c. `sort -V`, never lexical, and release tags only. v0.15.9 must not beat
#     v0.15.35, and v0.16.0-rc1 must never become the advertised latest.
if [[ "$(line "$out" 3)" == "$TAG_NEW" ]]; then
  ok_t "newest tag chosen by version sort; a pre-release tag is not advertised"
else
  bad_t "tag selection wrong" "'$(line "$out" 3)'"
fi

# 4. git absent => the atom rung resolves the tag. A hardened probe that bricks
#    is worse than the race it avoids — but the fallback is another way to the
#    SAME question, never a fallback to main, which answers a different one.
out="$(run_probe '' "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new" "v0.15.34 $TAG_NEW")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 3)" == "$TAG_NEW" ]]; then
  ok_t "git absent => the tags atom feed resolves the same tag"
else
  bad_t "atom fallback broken" "state '$(line "$out" 1)' ref '$(line "$out" 3)'"
fi

# 5. git present but unable to resolve => same fallback, no hang, no failure.
out="$(run_probe "$GIT_BROKEN" "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new" "$TAG_NEW")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 3)" == "$TAG_NEW" ]]; then
  ok_t "unresolvable git ls-remote falls through to the atom feed"
else
  bad_t "broken-git fallback wrong" "state '$(line "$out" 1)' ref '$(line "$out" 3)'"
fi

# 5b. NO tag resolves on any rung => UNAVAILABLE, and it must NOT quietly answer
#     from main. install.sh fails CLOSED on exactly this condition; a checker
#     that stayed open here would be advertising the uninstallable again.
out="$(run_probe "$GIT_BROKEN" "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == unavailable && "$(line "$out" 3)" == *"no release tag"* ]]; then
  ok_t "no resolvable release tag => UNAVAILABLE, never a fallback to main"
else
  bad_t "no-tag case did not fail closed" "state '$(line "$out" 1)' ver '$(line "$out" 2)' detail '$(line "$out" 3)'"
fi

# 6. Cannot fetch at all => UNAVAILABLE, distinct from indeterminate: one means
#    "the source disagrees with itself", the other "I never reached it".
out="$(run_probe "$GIT_TAGS" "$(mk_curl '')")"
if [[ "$(line "$out" 1)" == unavailable && -n "$(line "$out" 3)" ]]; then
  ok_t "unreachable source => UNAVAILABLE with a reason"
else
  bad_t "unreachable source misclassified" "state '$(line "$out" 1)'"
fi

# 7. Internally consistent but carrying no version => still cannot answer.
out="$(run_probe "$GIT_TAGS" "$(mk_curl "$FIX/bundle-nover" "$FIX/sum-nover")")"
if [[ "$(line "$out" 1)" == indeterminate && "$(line "$out" 3)" == *"no FIVE_VERSION"* ]]; then
  ok_t "consistent bundle with no FIVE_VERSION => INDETERMINATE"
else
  bad_t "versionless bundle misclassified" "state '$(line "$out" 1)' detail '$(line "$out" 3)'"
fi

# 8. The probe never fails its caller — every state is a normal return, so a
#    supervisor pass cannot be aborted by a flaky CDN.
run_probe "$GIT_TAGS" "$(mk_curl '')" >/dev/null; rc=$?
if (( rc == 0 )); then ok_t "probe returns 0 in every state (callers branch on line 1)"
else bad_t "probe failed its caller" "exit $rc"; fi

# ---------------------------------------------- the shipped command itself --
# The block above proves the probe. This proves cmd_update_check RENDERS all
# three states, and it is graded as a SET: the indeterminate assertions ("no
# green here") are only meaningful if this same harness can reach a green at
# all. Without the two positive controls below, a command that crashed for an
# unrelated reason — a missing tool on the minimal PATH, say — would satisfy
# every negative assertion while proving nothing. That is not hypothetical: the
# first cut of this harness passed those three exactly that way.
CHECK_SRC="$(sed -n '/^cmd_update_check()/,/^}/p' src/cmd_selfupdate.sh)"
# DIVE-2287: cmd_update_check also calls the freeze observer now. Extracted
# VERBATIM from the same file rather than shimmed — a stub here would let every
# render assertion below pass over a broken observer.
FREEZE_SRC="$(sed -n '/^# >>> DIVE-2287 version-freeze observer/,/^# <<< DIVE-2287 version-freeze observer/p' src/cmd_selfupdate.sh)"
render_check() { # $1=local version  $2=bundle file  $3=sha256 file -> prints output, returns rc
  local stubs; stubs="$(mktemp -d)"
  printf '#!/usr/bin/env bash\n%s\n' "$(mk_curl "$2" "$3" "$TAG_NEW")" > "$stubs/curl"; chmod +x "$stubs/curl"
  # Shims for the three helpers cmd_update_check takes from elsewhere in the
  # bundle; everything else is the shipped body, extracted verbatim.
  env -i PATH="$stubs:$TOOLS" HOME="$stubs" bash -c "set -euo pipefail
E_USAGE=2; E_GENERIC=1; E_NOT_FOUND=4; FIVE_VERSION='$1'
STATE_DIR='$stubs'
readonly UPDATE_STALE_AFTER_SECS=\$((36 * 3600))
gh_org() { printf 'testorg\n'; }
fail() { local c=\"\$1\"; shift; printf 'error: %s\n' \"\$*\"; exit \"\$c\"; }
ok() { printf 'OK — %s\n' \"\$1\"; }
version_lt() { [[ \"\$1\" != \"\$2\" && \"\$(printf '%s\n%s\n' \"\$1\" \"\$2\" | sort -V | head -n1)\" == \"\$1\" ]]; }
$block
$FREEZE_SRC
$CHECK_SRC
cmd_update_check" 2>&1
  local rc=$?; rm -rf "$stubs"; return $rc
}

if [[ -z "$CHECK_SRC" ]]; then
  bad_t "cmd_update_check not extractable" "function body not found"
else
  # POSITIVE CONTROL A — genuinely up to date. This is the assertion that makes
  # the negatives below mean something: the harness CAN produce a green.
  render="$(render_check 0.15.35 "$FIX/bundle-new" "$FIX/sum-new")"; rc=$?
  if (( rc == 0 )) && [[ "$render" == *"OK — "*"0.15.35 is up to date"* ]]; then
    ok_t "consistent read, same version => green 'up to date', exit 0"
  else
    bad_t "up-to-date path did not render a green" "rc=$rc output: $render"
  fi

  # POSITIVE CONTROL B — genuinely behind. Second state, still exit 0.
  render="$(render_check 0.15.34 "$FIX/bundle-new" "$FIX/sum-new")"; rc=$?
  if (( rc == 0 )) && [[ "$render" == *"is behind (latest 0.15.35)"* ]]; then
    ok_t "consistent read, older local version => 'behind', exit 0"
  else
    bad_t "behind path did not render" "rc=$rc output: $render"
  fi

  # THE THIRD STATE — stale bundle beside a fresh checksum, local version equal
  # to the stale one. This is the reported incident, byte for byte.
  render="$(render_check 0.15.34 "$FIX/bundle-old" "$FIX/sum-new")"; rc=$?
  if (( rc != 0 )); then ok_t "update --check exits non-zero when the read is indeterminate"
  else bad_t "update --check exited 0 on an indeterminate read" "output: $render"; fi
  # `ok()` is the only thing that prints the green envelope, so ANY "OK — " on
  # this path is the defect back.
  if [[ "$render" != *"OK — "* ]]; then
    ok_t "update --check emits no green envelope from a split-generation read"
  else
    bad_t "update --check still reports success during propagation" "output: $render"
  fi
  # Weaker, but it catches a half-grep of a nightly log — which is how the
  # original was read as a pass twice in a row.
  if [[ "$render" != *"up to date"* ]]; then
    ok_t "the indeterminate line does not contain the string 'up to date'"
  else
    bad_t "indeterminate prose contains a pass-shaped substring" "output: $render"
  fi
  if [[ "$render" == *"cannot determine"* && "$render" == *"retry"* ]]; then
    ok_t "update --check says it cannot determine, and to retry"
  else
    bad_t "indeterminate prose is unhelpful" "output: $render"
  fi

  # DIVE-2287 — THE FOURTH STATE. A box ABOVE the newest release tag. Before
  # this change it fell into the `up to date` else-branch, which is how an
  # operator ended up holding two correct and contradictory messages: "up to
  # date" from the checker and "refusing to DOWNGRADE" from the installer. It
  # must name the condition and say who owes what.
  render="$(render_check 0.15.36 "$FIX/bundle-new" "$FIX/sum-new")"; rc=$?
  if (( rc == 0 )) && [[ "$render" == *AHEAD* && "$render" == *"0.15.35"* ]]; then
    ok_t "local version above the newest release => AHEAD, naming the release it is ahead of"
  else
    bad_t "ahead-of-release path did not render" "rc=$rc output: $render"
  fi
  # And it must not read as a pass. This is the whole failure mode: the state
  # where the installer refuses every upgrade must not be spelled "up to date".
  if [[ "$render" != *"up to date"* ]]; then
    ok_t "the ahead state is not spelled 'up to date'"
  else
    bad_t "a box the installer will refuse is being reported as up to date" "output: $render"
  fi
  if [[ "$render" == *"refuse"* ]]; then
    ok_t "the ahead line says the installer will refuse to move it"
  else
    bad_t "ahead prose does not explain the consequence" "output: $render"
  fi
fi

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
