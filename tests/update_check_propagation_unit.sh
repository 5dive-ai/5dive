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
for t in bash mktemp sha256sum awk grep sed rm cp cat timeout sort head date tr tail cut; do
  p="$(command -v "$t")" && ln -sf "$p" "$TOOLS/$t"
done

mk_curl() { # $1=file served as /5dive  $2=file served as /5dive.sha256 ('' both = fail every fetch)
  if [[ -z "${1:-}" ]]; then printf 'exit 22\n'; return; fi
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

GIT_PINS="printf '%s\trefs/heads/main\n' '$SHA_MAIN'"
GIT_BROKEN='exit 128'   # git present, cannot reach the remote

line() { sed -n "$2p" <<<"$1"; }

# ------------------------------------------------------------------ cases --

# 1. THE REGRESSION. Stale bundle (0.15.34) beside the FRESH checksum — the
#    literal bytes raw.githubusercontent served on 2026-07-26. The old code
#    returned 0.15.34 here and the caller rendered "up to date".
out="$(run_probe '' "$(mk_curl "$FIX/bundle-old" "$FIX/sum-new")")"
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
if [[ "$(line "$out" 3)" == *"different CDN cache generations"* ]]; then
  ok_t "unpinned mismatch is explained as cache skew, not tampering"
else
  bad_t "unpinned mismatch reason is wrong" "'$(line "$out" 3)'"
fi

# 2. Pinned + mismatch. Both objects came from ONE immutable tree, so cache skew
#    cannot explain it — the message must NOT blame the CDN, and must name the
#    sha so the claim is checkable (DIVE-1977's branching-message rule).
out="$(run_probe "$GIT_PINS" "$(mk_curl "$FIX/bundle-old" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == indeterminate && "$(line "$out" 3)" == *"does not match its own checksum"* \
      && "$(line "$out" 3)" == *"${SHA_MAIN:0:12}"* ]]; then
  ok_t "pinned mismatch names the sha and does not blame cache generations"
else
  bad_t "pinned mismatch message is wrong" "'$(line "$out" 3)'"
fi

# 3. Pinned + consistent: the normal path. Both fetches must come from raw/<sha>/.
out="$(run_probe "$GIT_PINS" "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 2)" == "0.15.35" \
      && "$(line "$out" 3)" == "$SHA_MAIN" ]]; then
  ok_t "pinned + consistent => version 0.15.35 sourced from the resolved sha"
else
  bad_t "pinned happy path wrong" "state '$(line "$out" 1)' ver '$(line "$out" 2)' ref '$(line "$out" 3)'"
fi

# 4. git absent => unpinned fallback, NOT a failure. A hardened probe that
#    bricks is worse than the race it avoids.
out="$(run_probe '' "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 3)" == "main" ]]; then
  ok_t "git absent falls back to /main and still answers"
else
  bad_t "unpinned fallback broken" "state '$(line "$out" 1)' ref '$(line "$out" 3)'"
fi

# 5. git present but unable to resolve => same fallback, no hang, no failure.
out="$(run_probe "$GIT_BROKEN" "$(mk_curl "$FIX/bundle-new" "$FIX/sum-new")")"
if [[ "$(line "$out" 1)" == consistent && "$(line "$out" 3)" == "main" ]]; then
  ok_t "unresolvable git ls-remote falls back to /main"
else
  bad_t "broken-git fallback wrong" "state '$(line "$out" 1)' ref '$(line "$out" 3)'"
fi

# 6. Cannot fetch at all => UNAVAILABLE, distinct from indeterminate: one means
#    "the source disagrees with itself", the other "I never reached it".
out="$(run_probe "$GIT_PINS" "$(mk_curl '')")"
if [[ "$(line "$out" 1)" == unavailable && -n "$(line "$out" 3)" ]]; then
  ok_t "unreachable source => UNAVAILABLE with a reason"
else
  bad_t "unreachable source misclassified" "state '$(line "$out" 1)'"
fi

# 7. Internally consistent but carrying no version => still cannot answer.
out="$(run_probe "$GIT_PINS" "$(mk_curl "$FIX/bundle-nover" "$FIX/sum-nover")")"
if [[ "$(line "$out" 1)" == indeterminate && "$(line "$out" 3)" == *"no FIVE_VERSION"* ]]; then
  ok_t "consistent bundle with no FIVE_VERSION => INDETERMINATE"
else
  bad_t "versionless bundle misclassified" "state '$(line "$out" 1)' detail '$(line "$out" 3)'"
fi

# 8. The probe never fails its caller — every state is a normal return, so a
#    supervisor pass cannot be aborted by a flaky CDN.
run_probe "$GIT_PINS" "$(mk_curl '')" >/dev/null; rc=$?
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
render_check() { # $1=local version  $2=bundle file  $3=sha256 file -> prints output, returns rc
  local stubs; stubs="$(mktemp -d)"
  printf '#!/usr/bin/env bash\n%s\n' "$(mk_curl "$2" "$3")" > "$stubs/curl"; chmod +x "$stubs/curl"
  # Shims for the three helpers cmd_update_check takes from elsewhere in the
  # bundle; everything else is the shipped body, extracted verbatim.
  env -i PATH="$stubs:$TOOLS" HOME="$stubs" bash -c "set -euo pipefail
E_USAGE=2; E_GENERIC=1; E_NOT_FOUND=4; FIVE_VERSION='$1'
readonly UPDATE_STALE_AFTER_SECS=\$((36 * 3600))
gh_org() { printf 'testorg\n'; }
fail() { local c=\"\$1\"; shift; printf 'error: %s\n' \"\$*\"; exit \"\$c\"; }
ok() { printf 'OK — %s\n' \"\$1\"; }
version_lt() { [[ \"\$1\" != \"\$2\" && \"\$(printf '%s\n%s\n' \"\$1\" \"\$2\" | sort -V | head -n1)\" == \"\$1\" ]]; }
$block
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
fi

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
