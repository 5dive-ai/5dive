#!/usr/bin/env bash
# tests/local_selfref_scan_unit.sh — DIVE-4067.
#
# Grades scripts/local-selfref-scan.sh, the scanner for the shape that took every
# agent on every box down on 2026-09-07:
#
#     local dir="$HOME/.5dive" f="$dir/delivery.env" tmp
#
# `local` is a builtin, so bash expands ALL of its arguments before performing ANY
# of its assignments — the `$dir` resolves against the ENCLOSING scope. In
# `write_delivery_declaration()` (DIVE-4036) no caller held a `dir`, and under the
# launcher's `set -euo pipefail` that is a fatal unbound-variable exit before the
# pane starts. `bash -n` accepts the file; the unit corpus never runs the launcher;
# install-smoke does not start an agent; `5dive doctor` does not hash the launcher.
# Nothing in the release path could see it, which is why the instrument exists.
#
# WEIGHTED TOWARD THE FALSE-CLEAN DIRECTION, because that is the direction that
# costs a fleet. A scanner that never accuses passes every day and is worth nothing.
# So ARM 1 proves it FIRES, ARM 6 proves the SHIPPED TREE is the thing it fires on,
# and ARMS 7-8 close the two ways it could report clean without having looked.
#
# ARM 5 is the one that is easy to leave out and is the whole reason this file is
# not just "run the scanner": the scanner MUST contain the defective shape (its
# canary needs it), so it excludes its own path from the default sweep. A
# self-exclusion that silently widened would make every future instance invisible.
# ARM 5 therefore grades both halves — the sweep stays clean, and a COPY of the
# scanner is still accused, which is only true if the skip is keyed on identity
# rather than on content.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

SCAN="$PWD/scripts/local-selfref-scan.sh"
[[ -r "$SCAN" ]] || { printf 'FAIL: %s not found\n' "$SCAN"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lsr.XXXXXX") || exit 2
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n     %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# ARM 1 — IT FIRES. The exact line, verbatim, that emptied the boxes.
# ---------------------------------------------------------------------------
cat > "$TMP/violating.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
write_delivery_declaration() {
  local dir="$HOME/.5dive" f="$dir/delivery.env" tmp
  echo "$f$tmp"
}
STUB
out=$(bash "$SCAN" "$TMP/violating.sh" 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'VIOLATION' <<<"$out"; then
  ok "the DIVE-4067 line is a VIOLATION and the scan exits 1"
else bad "the DIVE-4067 line is a VIOLATION and the scan exits 1" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 2 — THE FIX IS ACCEPTED. One statement per name is correct and must pass;
# a guard that cannot be satisfied by the documented remedy is worse than none.
# ---------------------------------------------------------------------------
cat > "$TMP/healthy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
write_delivery_declaration() {
  local dir="$HOME/.5dive"
  local f="$dir/delivery.env"
  local tmp
  echo "$f$tmp"
}
STUB
out=$(bash "$SCAN" "$TMP/healthy.sh" 2>&1); rc=$?
if (( rc == 0 )); then
  ok "the split form is clean and the scan exits 0"
else bad "the split form is clean and the scan exits 0" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 3 — IT DOES NOT OVER-FIRE, and these are the three shapes that would make it
# unusable. A single-quoted `$name` expands nothing. A read of a name declared in a
# DIFFERENT statement is correct and ordinary. A positional is always bound.
# ---------------------------------------------------------------------------
cat > "$TMP/noisy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
g() {
  local a="$1" b="$2" c
  local msg='$a is printed literally, not expanded'
  local d="$a/$b"
  declare -A m
  echo "$c$msg$d${m[*]}"
}
STUB
out=$(bash "$SCAN" "$TMP/noisy.sh" 2>&1); rc=$?
if (( rc == 0 )); then
  ok "single quotes, cross-statement reads and positionals do not fire"
else bad "single quotes, cross-statement reads and positionals do not fire" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 4 — THE OTHER DECLARATION BUILTINS. `local` is where it bit us, but `declare`,
# `typeset`, `export` and `readonly` are the same builtin class with the same
# expand-then-assign order, and at file scope `export A=1 B="$A"` fails identically.
# ---------------------------------------------------------------------------
for kw in declare typeset export readonly; do
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s A="x" B="$A/y"\necho "$B"\n' "$kw" > "$TMP/kw.sh"
  out=$(bash "$SCAN" "$TMP/kw.sh" 2>&1); rc=$?
  if (( rc == 1 )); then
    ok "\`$kw\` carries the same defect and fires"
  else bad "\`$kw\` carries the same defect and fires" "rc=$rc — $out"; fi
done

# ---------------------------------------------------------------------------
# ARM 5 — SELF-EXCLUSION, BOTH HALVES. The scanner must contain the defective shape
# to carry its canary, so it skips its own path in the default sweep. Grading only
# the "sweep is clean" half would pass just as well if the skip had widened to
# everything; grading only the copy would pass if the skip had stopped working. The
# pair is what pins it: skip by IDENTITY, and nothing else.
# ---------------------------------------------------------------------------
cp "$SCAN" "$TMP/copy-of-scanner.sh"
out=$(bash "$SCAN" "$TMP/copy-of-scanner.sh" 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'VIOLATION' <<<"$out"; then
  ok "a COPY of the scanner is still accused — the skip is by path, not by content"
else bad "a COPY of the scanner is still accused — the skip is by path, not by content" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 6 — THE SHIPPED TREE IS CLEAN. This is the regression arm: it reds the moment
# anyone reintroduces the shape into the launcher, the installer, src/ or scripts/.
# ---------------------------------------------------------------------------
out=$(bash "$SCAN" 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'clean over' <<<"$out"; then
  ok "the default sweep over shipped shell is clean"
else bad "the default sweep over shipped shell is clean" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 7 — "COULD NOT SCAN" IS A THIRD OUTCOME. An unreadable target must not read as
# clean; that is the failure mode a rename produces and it is silent by nature.
# ---------------------------------------------------------------------------
out=$(bash "$SCAN" "$TMP/does-not-exist.sh" 2>&1); rc=$?
if (( rc == 2 )); then
  ok "an unreadable target is exit 2, not a pass"
else bad "an unreadable target is exit 2, not a pass" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 8 — THE CANARY CAN REFUSE. Break the scanner's own core and it must exit 2
# rather than report clean, because a scanner that cannot see the defect it was
# built for reports exactly what a clean tree reports.
# ---------------------------------------------------------------------------
sed 's/^DECL = re.compile.*/DECL = re.compile(r"^\\uFFFF_never_matches")/' "$SCAN" > "$TMP/blinded.sh"
out=$(bash "$TMP/blinded.sh" "$TMP/violating.sh" 2>&1); rc=$?
if (( rc == 2 )) && grep -qi 'canary failed' <<<"$out"; then
  ok "a blinded scanner refuses (exit 2) instead of reporting clean"
else bad "a blinded scanner refuses (exit 2) instead of reporting clean" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 9 — THE INCIDENT LINE ITSELF, named rather than inferred. ARM 6 would catch a
# reintroduction anywhere; this says out loud which function it was, so a future
# reader of a red does not have to reconstruct the incident from a line number.
# ---------------------------------------------------------------------------
if [[ -r 5dive-agent-start ]]; then
  if grep -q 'local dir="\$HOME/\.5dive" f=' 5dive-agent-start; then
    bad "write_delivery_declaration() still declares dir and f in one statement" \
        "this is the DIVE-4067 fleet outage, reintroduced"
  else
    ok "write_delivery_declaration() declares dir and f in separate statements"
  fi
else
  skip "write_delivery_declaration() declares dir and f in separate statements" \
       "5dive-agent-start not present in this tree"
fi

printf -- '-----\nRESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
