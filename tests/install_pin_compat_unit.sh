#!/usr/bin/env bash
# DIVE-4350 — grade the two halves of "install.sh comes from main, its downloads
# come from the pin".
#
#   ARMS A-E  scripts/install-pin-compat.sh, the CI guard: does it FAIL on the
#             exact shape of DIVE-4349 (a fail-closed download of a path the pin
#             does not carry), PASS when the same download is routed through the
#             tolerant helper, and REFUSE — never silently pass — when it cannot
#             resolve a pin or cannot read its input.
#   ARMS F-J  fetch_optional_at_pin, extracted VERBATIM from install.sh and
#             driven against a stubbed curl: 404 is a named skip, and anything
#             that is NOT a 404 is fatal. That second half is quinn's finding on
#             #908 — `curl -fsSL … 2>/dev/null` collapses a connection refusal
#             into the same exit as a 404, so a network blip silently un-wired
#             DIVE-4306's teardown hook and logged a false cause.
#
# Hermetic: the guard arms run against a synthetic git repo built here (its own
# tag, its own install.sh), never the network and never this repo's real pin.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

GUARD="$ROOT/scripts/install-pin-compat.sh"
[[ -x $GUARD ]] || { bad_t "scripts/install-pin-compat.sh is executable" "not found or not +x"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

WORK="$(mktemp -d)"; trap 'rc=$?; rm -rf "$WORK"; echo "HARNESS-RC=$rc"' EXIT

# ---------------------------------------------------------------- synthetic repo
# A tag that ships `hooks/old.sh` and NOT `hooks/new.sh` — the DIVE-4349 shape
# with the real names removed, so the arms stay true when the real pin moves.
REPO_DIR="$WORK/repo"
mkdir -p "$REPO_DIR/hooks" "$REPO_DIR/.github"
cd "$REPO_DIR" || exit 1
git init -q .
git config user.email t@example.com; git config user.name t
echo old > hooks/old.sh
printf 'v1.0.0\n' > .github/fleet-pin
git add -A; git commit -qm base
git tag -a v1.0.0 -m v1.0.0
echo new > hooks/new.sh           # first shipped AFTER the pin
git add -A; git commit -qm later

mk_install() { # $1 = body of the download section
  cat > "$REPO_DIR/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
die() { echo "error: \$*" >&2; exit 1; }
$1
EOF
}

run_guard() { INSTALL_PIN_COMPAT_NO_NETWORK=1 GITHUB_STEP_SUMMARY=/dev/null bash "$GUARD" "$@" 2>&1; }

echo "# ARM A — a fail-closed download of a path the pin does not carry FAILS"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'hooks/new.sh' <<<"$out"; then
  ok_t "ARM A: fail-closed hooks/new.sh at pin v1.0.0 is refused, and named"
else
  bad_t "ARM A: fail-closed hooks/new.sh at pin v1.0.0 is refused, and named" "rc=$rc out=$out"
fi
if grep -q 'hooks/old.sh' <<<"$out" && ! grep -q 'FAIL - hooks/old.sh' <<<"$out"; then
  ok_t "ARM A: hooks/old.sh, which the pin does carry, passes"
else
  bad_t "ARM A: hooks/old.sh, which the pin does carry, passes" "out=$out"
fi

echo "# ARM B — the SAME path routed through the tolerant helper passes"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  fetch_optional_at_pin "hooks/new.sh" "$LIB_DIR/new.sh" || rm -f "$LIB_DIR/new.sh"'
out="$(run_guard)"; rc=$?
[[ $rc -eq 0 ]] && ok_t "ARM B: tolerant hooks/new.sh is not a failure" \
                || bad_t "ARM B: tolerant hooks/new.sh is not a failure" "rc=$rc out=$out"

echo "# ARM C — a for-loop hook list is expanded, not skipped as 'a variable'"
mk_install '  for hook in old.sh new.sh; do
    curl -fsSL "$REPO/hooks/$hook" -o "$LIB_DIR/$hook"
  done'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'FAIL - hooks/new.sh' <<<"$out"; then
  ok_t "ARM C: the fail-closed for-list is expanded and graded"
else
  bad_t "ARM C: the fail-closed for-list is expanded and graded" "rc=$rc out=$out"
fi

echo "# ARM D — no resolvable pin REFUSES; it does not pass quietly"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"'
out="$(run_guard --recorded=/nonexistent/fleet-pin)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qi 'no fleet pin' <<<"$out"; then
  ok_t "ARM D: an unresolvable pin is a refusal with a named reason"
else
  bad_t "ARM D: an unresolvable pin is a refusal with a named reason" "rc=$rc out=$out"
fi

echo "# ARM E — a pin that is not an object here REFUSES rather than grading vacuously"
out="$(run_guard --pin=v9.9.9)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'v9.9.9' <<<"$out"; then
  ok_t "ARM E: a pin tag absent from the clone is a refusal, not 21 vacuous passes"
else
  bad_t "ARM E: a pin tag absent from the clone is a refusal, not 21 vacuous passes" "rc=$rc out=$out"
fi

echo "# ARM E2 — an extractor that reads ZERO fail-closed sites refuses"
mk_install '  : nothing is downloaded here'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qi 'ZERO fail-closed' <<<"$out"; then
  ok_t "ARM E2: zero extracted sites is the extractor breaking, and it refuses"
else
  bad_t "ARM E2: zero extracted sites is the extractor breaking, and it refuses" "rc=$rc out=$out"
fi

# --------------------------------------------------------- ARMS K-N (iteration 2)
# quinn's finding on iteration 1: the classifier treated fail-closed as the
# UNASSERTED COMPLEMENT of four tolerance rules, so three ordinary fail-closed
# idioms were reported as "tolerated" and never graded — the guard greened the
# exact DIVE-4349 shape. Arms A-E all stayed green through that hole because they
# only ever exercised the ONE shape #890 used (a bare curl in a for-list). These
# arms are the hole itself, one arm per idiom.
echo "# ARMS K1-K3 — the three fail-closed idioms iteration 1 called 'tolerant'"

echo '# ARM K1 — captured in $(…) with an assignment fallback; the die is deferred'
mk_install '  _x="$(curl -fsSL "$REPO/hooks/new.sh" 2>/dev/null)" || _x=""
  [[ -n "$_x" ]] || die "absent"'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'FAIL - hooks/new.sh' <<<"$out"; then
  ok_t "ARM K1: \$(curl …) || _x=\"\" is GRADED (the handler that dies is on a later line)"
else
  bad_t "ARM K1: \$(curl …) || _x=\"\" is GRADED (the handler that dies is on a later line)" \
        "this is how install.sh fetches 5dive.sha256; iteration 1 reported it as tolerated; rc=$rc out=$out"
fi

echo '# ARM K2 — a negated if whose body dies'
mk_install '  if ! curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    die "failed"
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'FAIL - hooks/new.sh' <<<"$out"; then
  ok_t "ARM K2: an if-construct containing die is GRADED, not tolerated"
else
  bad_t "ARM K2: an if-construct containing die is GRADED, not tolerated" \
        "iteration 1's blanket ^if/elif rule called every condition tolerant; rc=$rc out=$out"
fi

echo '# ARM K3 — a || brace block that exits WITHOUT the literal token `die `'
mk_install '  curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh" || { echo "nope" >&2; exit 1; }'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'FAIL - hooks/new.sh' <<<"$out"; then
  ok_t "ARM K3: a || block that exits is GRADED — the test is die OR exit OR return, not the token 'die '"
else
  bad_t "ARM K3: a || block that exits is GRADED — the test is die OR exit OR return, not the token 'die '" \
        "rc=$rc out=$out"
fi

echo "# ARM L — an if-construct that demonstrably CANNOT abort is still tolerant"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  if curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    chmod 644 "$LIB_DIR/new.sh"
  else
    echo "warn: not staged" >&2
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -eq 0 ]]; then
  ok_t "ARM L: T2 survives the tightening — no die/exit/return in the whole construct is genuinely soft"
else
  bad_t "ARM L: T2 survives the tightening — no die/exit/return in the whole construct is genuinely soft" \
        "over-tightening turns every fail-soft site into a permanent red; rc=$rc out=$out"
fi

echo "# ARM M — a shape in NEITHER set is a third outcome that FAILS, not a pass"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh" || echo "warn" >&2'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'UNCLASSIFIED' <<<"$out"; then
  ok_t "ARM M: an ungrounded shape refuses; fail-closed is no longer an unasserted complement"
else
  bad_t "ARM M: an ungrounded shape refuses; fail-closed is no longer an unasserted complement" \
        "rc=$rc out=$out"
fi

echo "# ARM N — 5dive.sha256's own shape lands in CHECKED, and never in tolerated"
mk_install '  _want="$(curl -fsSL "$REPO/hooks/old.sh" 2>/dev/null | tr -d "[:space:]")" || _want=""
  if [[ -n "$_want" ]]; then
    :
  else
    die "failed to fetch required checksum"
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q '^ok   - hooks/old.sh' <<<"$out" && grep -q 'checked=1 ' <<<"$out"; then
  ok_t "ARM N: the 5dive.sha256 shape is in the checked column (checked=1), not the tolerated one"
else
  bad_t "ARM N: the 5dive.sha256 shape is in the checked column (checked=1), not the tolerated one" \
        "the PR body names {5dive, 5dive.sha256} as the fail-closed set; iteration 1 never checked the second; rc=$rc out=$out"
fi

echo "# ARMS O-Q — T2 now needs POSITIVE evidence of absorption (quinn, iteration 2)"
echo "# ARM O — collect-then-check: no abort token INSIDE the construct, dies two lines later"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  if ! curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    _failed=1
  fi
  [[ -n "${_failed:-}" ]] && die "new.sh missing"'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'UNCLASSIFIED' <<<"$out"; then
  ok_t "ARM O: a failure branch that RECORDS the failure is not absorption — refused, not tolerated"
else
  bad_t "ARM O: a failure branch that RECORDS the failure is not absorption — refused, not tolerated" \
        "this aborts the whole install on a 404 at the pin, which is DIVE-4349 exactly; rc=$rc out=$out"
fi

echo "# ARM P — the failure branch calls a local aborting function: not the token die/exit/return"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  bail() { echo "fatal: $*" >&2; exit 1; }
  if ! curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    bail "new.sh missing"
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'UNCLASSIFIED' <<<"$out"; then
  ok_t "ARM P: a non-log-only failure branch is refused even when it carries no die/exit/return token"
else
  bad_t "ARM P: a non-log-only failure branch is refused even when it carries no die/exit/return token" \
        "an absence-of-token test cannot see bail(); only positive evidence of absorption can; rc=$rc out=$out"
fi

echo "# ARM Q — no else branch at all: nothing absorbs the failure, so nothing to claim"
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  if curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    chmod 644 "$LIB_DIR/new.sh"
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'UNCLASSIFIED' <<<"$out"; then
  ok_t "ARM Q: an if-construct with no else branch shows no absorption and is refused"
else
  bad_t "ARM Q: an if-construct with no else branch shows no absorption and is refused" \
        "rc=$rc out=$out"
fi

echo "# ARM R — the REAL pii-guard shape: assignment + nested if inside, log-only else. Still tolerant."
mk_install '  curl -fsSL "$REPO/hooks/old.sh" -o "$LIB_DIR/old.sh"
  if curl -fsSL "$REPO/hooks/new.sh" -o "$LIB_DIR/new.sh"; then
    chmod 644 "$LIB_DIR/new.sh"
    if _out="$(cat "$LIB_DIR/new.sh" 2>&1)"; then
      echo "ok ${_out}"
    else
      echo "warn: could not read it" >&2
    fi
  else
    echo "warn: not staged this run" >&2
  fi'
out="$(run_guard)"; rc=$?
if [[ $rc -eq 0 ]]; then
  ok_t "ARM R: absorption is about the failure branch, not about assignments in the body"
else
  bad_t "ARM R: absorption is about the failure branch, not about assignments in the body" \
        "the naive 'body contains an assignment => not tolerant' rule reds install.sh:1332 pii-guard, which is genuinely fail-soft; rc=$rc out=$out"
fi

cd "$ROOT" || exit 1

# ------------------------------------------- fetch_optional_at_pin, verbatim
echo "# ARMS F-J — fetch_optional_at_pin extracted VERBATIM from install.sh"
HELPER="$WORK/helper.sh"
awk '/^# >>> DIVE-4350 optional-at-pin download contract$/,/^# <<< DIVE-4350 optional-at-pin download contract$/' \
  "$ROOT/install.sh" > "$WORK/helper.body"
if [[ -s "$WORK/helper.body" ]] && grep -q '%{http_code}' "$WORK/helper.body"; then
  ok_t "the helper block is extractable from install.sh and captures %{http_code}"
else
  bad_t "the helper block is extractable from install.sh and captures %{http_code}" \
        "markers moved, or the http_code capture (quinn's required clause on DIVE-4350) is gone"
fi

# Stub curl: $STUB_CODE is the status written to stdout by -w, $STUB_RC its exit.
drive() { # $1 code  $2 rc  -> prints "RC=<rc> STDERR=<...>" of one helper call
  cat > "$HELPER" <<EOF
set -uo pipefail
die() { echo "error: \$*" >&2; exit 1; }
REPO="https://example.invalid/repo"
GH_PINNED_TAG="v1.0.0"
curl() {
  local out=""
  while [[ \$# -gt 0 ]]; do [[ "\$1" == "-o" ]] && { out="\$2"; shift; }; shift; done
  [[ -n "\$out" ]] && printf 'body' > "\$out"
  printf '%s' "$1"
  return $2
}
EOF
  cat "$WORK/helper.body" >> "$HELPER"
  printf 'fetch_optional_at_pin "hooks/new.sh" "%s/dest"; echo "RC=$?"\n' "$WORK" >> "$HELPER"
  bash "$HELPER" 2>&1
}

rm -f "$WORK/dest"; out="$(drive 200 0)"
if grep -q 'RC=0' <<<"$out" && [[ -f "$WORK/dest" ]]; then
  ok_t "ARM F: HTTP 200 installs the file and returns 0"
else
  bad_t "ARM F: HTTP 200 installs the file and returns 0" "out=$out"
fi

rm -f "$WORK/dest"; out="$(drive 404 0)"
if grep -q 'RC=1' <<<"$out" && grep -q 'not shipped at this pin' <<<"$out" && [[ ! -f "$WORK/dest" ]]; then
  ok_t "ARM G: HTTP 404 is a NAMED skip (rc 1, nothing installed)"
else
  bad_t "ARM G: HTTP 404 is a NAMED skip (rc 1, nothing installed)" "out=$out"
fi

# THE FINDING. Each of these is what `curl -fsSL … 2>/dev/null` called "not
# shipped at this pin". None of them is.
for pair in "000 7:connection refused" "000 28:timeout" "500 0:server error" "403 0:proxy refusal"; do
  code="${pair%% *}"; rest="${pair#* }"; rc="${rest%%:*}"; what="${rest#*:}"
  rm -f "$WORK/dest"; out="$(drive "$code" "$rc")"
  if ! grep -q 'RC=' <<<"$out" && grep -q 'error:' <<<"$out" && [[ ! -f "$WORK/dest" ]]; then
    ok_t "ARM H: $what (http $code, curl rc $rc) is FATAL, not 'absent at the pin'"
  else
    bad_t "ARM H: $what (http $code, curl rc $rc) is FATAL, not 'absent at the pin'" \
          "the helper swallowed it — that is the #908 defect, a blip silently un-wires the hook; out=$out"
  fi
done

rm -f "$WORK/dest"; out="$(drive 000 7)"
if ! grep -qi 'not shipped at this pin' <<<"$out"; then
  ok_t "ARM I: a transient failure does NOT log the false 'not shipped at this pin' cause"
else
  bad_t "ARM I: a transient failure does NOT log the false 'not shipped at this pin' cause" "out=$out"
fi

echo "# ARM J — install.sh's tolerant hook loop goes through the helper, not a bare curl"
blk="$(awk '/>>> DIVE-4349\/DIVE-4350 hooks newer than the fleet pin/,/<<< DIVE-4349\/DIVE-4350/' "$ROOT/install.sh")"
if grep -q 'fetch_optional_at_pin' <<<"$blk" && ! grep -qE 'curl .*2>/dev/null' <<<"$blk"; then
  ok_t "ARM J: the optional-hook loop uses the helper and no bare tolerant curl"
else
  bad_t "ARM J: the optional-hook loop uses the helper and no bare tolerant curl" \
        "a second tolerant shape defeats the whole convention; blk=$blk"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
