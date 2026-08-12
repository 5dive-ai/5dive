#!/usr/bin/env bash
# DIVE-2604 — the unguarded-probe-substitution class, graded by RUNNING it.
#
# THE CLASS. Under `set -euo pipefail` (src/header.sh) a bare `var=$(… grep …)`
# DIES when the probe finds nothing. Nothing prints: the death happens before the
# handler that would have explained it. Three shipped in one day — DIVE-2566
# (`5dive push`, `curl -f` rc=22), DIVE-2603 (`5dive task done`, pipeline ending
# in grep), DIVE-2598 (the same line measured from outside: rc=1, 0 bytes on both
# streams). Each was a probe ALLOWED to find nothing, so the failure fires on the
# QUIET path — the ordinary case, not the exceptional one.
#
# WHY THIS FILE RUNS THE SHAPES INSTEAD OF GREPPING FOR GUARDS. A guard on line N
# says nothing about line N+1, and a string survives dead code. So:
#   A/B/C  execute each shape under the real flags, each with a POSITIVE CONTROL
#          (the matching input), because "rc=1" proves nothing if the arm would
#          have produced rc=1 on any input.
#   D      grades the SCANNER against synthetic bad/good input — a lint that
#          silently stopped matching reports a clean tree, which is the same
#          evidence as a clean tree.
#   E      runs the scanner on the real tree AND asserts it examined a plausible
#          number of substitutions, so a scanner that walks nothing cannot pass.
#   F      MUTATION: strips the guard off each site this ticket fixed, in a COPY
#          of the tree, and requires the scanner to name that exact file:line.
#          That is the only arm that proves the scanner grades THESE fixes rather
#          than some other property of the tree.
# Run: bash tests/unguarded_probe_substitution_unit.sh (no root, no network).
set -uo pipefail
# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
SCAN="$ROOT/scripts/unguarded-probe-scan.sh"
TMP="$(mktemp -d /tmp/unguarded-probe.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

[[ -r "$SCAN" ]] || { bad_t "scripts/unguarded-probe-scan.sh exists" "not at $SCAN"; \
                      printf 'unguarded_probe_substitution_unit: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# ── A. the class is fatal, per shape, with a positive control ─────────────────
# Each probe runs under the bundle's real flags. REACHED is printed only if the
# statement AFTER the assignment executes. The control feeds matching input to
# the SAME script, so a shape that could never reach REACHED is caught here.
run_shape() { # $1=body  -> prints "<rc>|<stdout>"
  local out rc
  out=$(bash -c "set -euo pipefail
$1
printf 'REACHED[%s]\n' \"\$v\"" 2>"$TMP/err"); rc=$?
  printf '%s|%s' "$rc" "$out"
}

declare -A SHAPE=(
  [pipeline-ends-in-grep]='in="__NOMATCH__"; v=$(printf "%s\n" "$in" | grep -oE "DIVE-[0-9]+" | head -1)'
  [grep-dash-c-counter]='in=""; v=$(printf "%s\n" "$in" | grep -c .)'
  [grep-into-cut]='printf "OTHER=1\n" >"'"$TMP"'/f.env"; v=$(grep -E "^WANTED=" "'"$TMP"'/f.env" 2>/dev/null | tail -1 | cut -d= -f2-)'
  [herestring-grep-grep]='out="nothing here"; v=$(grep -oE "[0-9]+ wired" <<<"$out" | head -1 | grep -oE "^[0-9]+")'
)
declare -A CONTROL=(
  [pipeline-ends-in-grep]='in="DIVE-2604 filed"; v=$(printf "%s\n" "$in" | grep -oE "DIVE-[0-9]+" | head -1)'
  [grep-dash-c-counter]='in="a"; v=$(printf "%s\n" "$in" | grep -c .)'
  [grep-into-cut]='printf "WANTED=yes\n" >"'"$TMP"'/g.env"; v=$(grep -E "^WANTED=" "'"$TMP"'/g.env" 2>/dev/null | tail -1 | cut -d= -f2-)'
  [herestring-grep-grep]='out="corpus 293 wired"; v=$(grep -oE "[0-9]+ wired" <<<"$out" | head -1 | grep -oE "^[0-9]+")'
)

for k in "${!SHAPE[@]}"; do
  r=$(run_shape "${SHAPE[$k]}"); rc="${r%%|*}"; body="${r#*|}"
  if [[ "$rc" == "1" && "$body" != *REACHED* ]]; then
    ok_t "A/$k: no-match DIES (rc=1) before the next statement"
  else
    bad_t "A/$k: no-match must die with rc=1 and never reach the next statement" "rc=$rc out=[$body]"
  fi
  # The death is SILENT — that is the property that made DIVE-2603 unreportable.
  if [[ ! -s "$TMP/err" ]]; then ok_t "A/$k: …and prints ZERO bytes on stderr"
  else bad_t "A/$k: the death must print nothing on stderr" "stderr=[$(cat "$TMP/err")]"; fi

  r=$(run_shape "${CONTROL[$k]}"); rc="${r%%|*}"; body="${r#*|}"
  if [[ "$rc" == "0" && "$body" == *REACHED* ]]; then
    ok_t "A/$k: POSITIVE CONTROL — matching input reaches the next statement"
  else
    bad_t "A/$k: control must survive; the arm above grades nothing otherwise" "rc=$rc out=[$body]"
  fi
done

# ── B. the prescribed remedy survives the quiet path with a STATED value ──────
for k in "${!SHAPE[@]}"; do
  case "$k" in grep-dash-c-counter) z='v=0'; want='REACHED[0]';; *) z='v=""'; want='REACHED[]';; esac
  r=$(run_shape "${SHAPE[$k]} || $z"); rc="${r%%|*}"; body="${r#*|}"
  if [[ "$rc" == "0" && "$body" == *"$want"* ]]; then
    ok_t "B/$k: \`|| $z\` survives no-match and leaves the stated post-condition"
  else
    bad_t "B/$k: guarded form must reach the next statement with $want" "rc=$rc out=[$body]"
  fi
done

# ── C. `grep -c .` is the nastiest: it PRINTS the right answer and still dies ──
c_out=$(printf '%s\n' "" | grep -c . 2>/dev/null); c_rc=$?
if [[ "$c_out" == "0" && "$c_rc" == "1" ]]; then
  ok_t "C: grep -c . on empty input prints 0 AND exits 1 (correct value, fatal status)"
else
  bad_t "C: grep -c . must print 0 and exit 1" "printed=[$c_out] rc=$c_rc"
fi

# ── D. the scanner itself, graded against synthetic input ─────────────────────
mkdir -p "$TMP/synth/src"
cat >"$TMP/synth/src/bad.sh" <<'BADEOF'
#!/usr/bin/env bash
f() {
  local hit
  hit=$(grep -oE 'DIVE-[0-9]+' <<<"$1" | head -1)
  printf '%s\n' "$hit"
}
BADEOF
# The compact form of the RECOMMENDED habit: declaration split from assignment, but
# onto the same line. Six live sites wore this and the first scanner — anchored at
# line start — reported the tree clean. Keying on the shape of the instance you
# already found is how a class survives its own sweep.
cat >"$TMP/synth/src/bad_oneline.sh" <<'BAD2EOF'
#!/usr/bin/env bash
f() {
  local n; n=$(printf '%s\n' "$1" | grep -c .)
  [[ -n "$2" ]] && ref=$(printf '%s\n' "$1" | grep -E '^v[0-9]' | tail -1)
  printf '%s %s\n' "$n" "${ref:-}"
}
BAD2EOF
cat >"$TMP/synth/src/good.sh" <<'GOODEOF'
#!/usr/bin/env bash
f() {
  local hit n raw
  hit=$(grep -oE 'DIVE-[0-9]+' <<<"$1" | head -1) || hit=""
  n=$(printf '%s\n' "$1" | grep -c .) || n=0
  raw=$({ grep -F -- "x" /dev/null || true; } | tail -1)
  # `local x=$(…)` MASKS rather than kills — a different defect, not this one.
  local masked=$(grep -c . </dev/null)
  printf '%s %s %s %s\n' "$hit" "$n" "$raw" "$masked"
}
GOODEOF
out=$(cd "$TMP/synth" && bash "$SCAN" --root=src 2>&1); rc=$?
if (( rc == 1 )) && [[ "$out" == *"src/bad.sh:4"* ]]; then
  ok_t "D: scanner FLAGS a synthetic unguarded probe at the right line (non-vacuity)"
else
  bad_t "D: scanner must flag src/bad.sh:4 with rc=1" "rc=$rc out=[${out//$'\n'/ }]"
fi
if [[ "$out" == *"src/bad_oneline.sh:3"* ]]; then
  ok_t "D: …and the compact \`local n; n=\$(…)\` form on ONE line (the 6-site blind spot)"
else
  bad_t "D: scanner must flag the same-line split declaration at src/bad_oneline.sh:3" "out=[${out//$'\n'/ }]"
fi
if [[ "$out" == *"src/bad_oneline.sh:4"* ]]; then
  ok_t "D: …and an assignment after \`&&\`, where set -e still kills the list"
else
  bad_t "D: scanner must flag the \`[[ … ]] && var=\$(…)\` form at src/bad_oneline.sh:4" "out=[${out//$'\n'/ }]"
fi
if [[ "$out" != *"src/good.sh"* ]]; then
  ok_t "D: scanner does NOT flag guarded forms, \`{ …||true; }|…\`, or \`local x=\$(…)\`"
else
  bad_t "D: false positive on src/good.sh — a lint that cries wolf gets switched off" "out=[${out//$'\n'/ }]"
fi
rm -f "$TMP/synth/src/bad.sh" "$TMP/synth/src/bad_oneline.sh"
out=$(cd "$TMP/synth" && bash "$SCAN" --root=src 2>&1); rc=$?
if (( rc == 0 )); then ok_t "D: scanner exits 0 on a clean tree"
else bad_t "D: scanner must exit 0 when only guarded forms remain" "rc=$rc out=[${out//$'\n'/ }]"; fi

# ── E. the real tree is clean, and the scanner actually walked it ─────────────
stats=$(bash "$SCAN" --root=src --root=scripts --stats 2>/dev/null); rc=$?
examined=$(sed -E 's/.*examined=([0-9]+).*/\1/' <<<"$stats"); examined="${examined:-0}"
if (( rc == 0 )); then ok_t "E: src/ + scripts/ carry ZERO unguarded probe substitutions"
else bad_t "E: the tree must be clean" "rc=$rc — run: bash scripts/unguarded-probe-scan.sh"; fi
# A scanner whose walk breaks (a heredoc mis-detection swallowed 112 assignments
# during this ticket) reports a clean tree. The count is the liveness signal.
if (( examined >= 1000 )); then
  ok_t "E: scanner examined $examined bare \$( ) assignments (walk is live)"
else
  bad_t "E: scanner examined only $examined assignments — its walk is broken, not the tree clean" "stats=[$stats]"
fi

# ── E2. tests/ is held to the SAME gate, and the discriminator is `set -e` ────
# The first pass of this scanner reported 128 offenders in tests/ and they were
# almost all FALSE: 282 of 303 harnesses run `set -uo pipefail` with no `-e`, and
# WITHOUT `-e` the shape is untidy, not fatal — the assignment just leaves an
# empty value and execution continues. Only 2 were real, and both are fixed here,
# so tests/ is a gate at ZERO rather than a ratchet at a made-up number.
#
# This is the arm worth reading twice. A lint that accuses 128 files gets
# switched off, and a "debt ceiling" pinned at 128 would have ENSHRINED 126
# non-defects as work owed. The population a count names is part of the count.
tstats=$(bash "$SCAN" --root=tests --stats --quiet 2>/dev/null || true)
toff=$(sed -E 's/.*offenders=([0-9]+).*/\1/' <<<"$tstats"); toff="${toff:-999}"
tskip=$(sed -E 's/.*skipped=([0-9]+).*/\1/' <<<"$tstats"); tskip="${tskip:-0}"
if (( toff == 0 )); then
  ok_t "E2: tests/ carries ZERO unguarded probe substitutions ($tskip files skipped: no set -e)"
else
  bad_t "E2: tests/ carries $toff unguarded probe substitution(s)" \
        "guard with \`|| var=\"\"\`: bash scripts/unguarded-probe-scan.sh --root=tests"
fi

# ── E3. the `set -e` discriminator itself, both directions ───────────────────
# A scanner that ignores `set -e` cries wolf on most of the tree; one that gets
# the src/ exception wrong goes blind on the whole product, because src/*.sh
# carry NO `set` line of their own — build.sh concatenates them under
# src/header.sh's `set -euo pipefail`. Both directions are graded.
mkdir -p "$TMP/sete/src" "$TMP/sete/scripts"
BADLINE='hit=$(grep -oE "DIVE-[0-9]+" <<<"$1" | head -1)'
# NOTE the assignment is on its OWN line in every fixture. The scanner only reads
# assignments that START a line — a documented limitation, and the fixture must not
# quietly exercise a shape the scanner never claimed to see, or these arms would be
# grading the limitation instead of the discriminator.
printf '#!/usr/bin/env bash\nset -uo pipefail\nf() {\n  local hit\n  %s\n}\n' "$BADLINE" > "$TMP/sete/scripts/no_errexit.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nf() {\n  local hit\n  %s\n}\n' "$BADLINE" > "$TMP/sete/scripts/with_errexit.sh"
# No `set` line at all, under src/ — in scope via the bundle header.
printf '#!/usr/bin/env bash\nf() {\n  local hit\n  %s\n}\n' "$BADLINE" > "$TMP/sete/src/bundle_member.sh"
sout=$(cd "$TMP/sete" && bash "$SCAN" --root=src --root=scripts 2>&1)
if [[ "$sout" != *no_errexit.sh* ]]; then
  ok_t "E3: a scripts/ file WITHOUT set -e is not accused (the shape is not fatal there)"
else
  bad_t "E3: false positive on a no-errexit script" "out=[${sout//$'\n'/ }]"
fi
if [[ "$sout" == *with_errexit.sh* ]]; then
  ok_t "E3: the IDENTICAL line WITH set -e is accused (the arm above is not blanket-silence)"
else
  bad_t "E3: adding set -e must make the same line an offender" "out=[${sout//$'\n'/ }]"
fi
if [[ "$sout" == *bundle_member.sh* ]]; then
  ok_t "E3: a src/ member with NO set line is in scope (build.sh puts it under header.sh)"
else
  bad_t "E3: src/ members must be judged by the bundle header, not their own text" "out=[${sout//$'\n'/ }]"
fi

# ── F. MUTATION: strip each fix, require the scanner to name it back ──────────
# file:line:VAR — the sites DIVE-2604 guarded. A fix that is reverted, moved, or
# re-merged into a `local` must make this arm red, or the guard is decorative.
SITES=(
  # DIVE-3278: was "src/cmd_task.sh:n". The four `n` guard sites split across TWO
  # files; this arm follows the two in src/task/gate_evidence.sh, which are the ones
  # the scanner actually flags. MEASURED, so nobody reads the other file as
  # forgotten: stripping the two `n` guards in src/task/notify.sh produces NO scanner
  # finding (rc=0, empty output) — they were never detectable, on main either, where
  # this entry passed on the gate_evidence sites alone. Coverage is preserved exactly,
  # not widened.
  "src/cmd_objective.sh:n"      "src/task/gate_evidence.sh:n"  "src/cmd_selfcheck.sh:nwired"
  "src/cmd_supervisor.sh:task"  "src/cmd_pack.sh:found"      "src/cmd_account.sh:base_url"
  "src/cmd_agent_telegram.sh:token" "src/cmd_cos.sh:atok"    "src/cmd_selfupdate.sh:start_line"
  "src/cmd_doctor.sh:last_event" "src/cmd_loop_pack.sh:ident" "src/cmd_agent_config.sh:token_for_install"
)
cp -a "$ROOT/src" "$TMP/mut-src"
for site in "${SITES[@]}"; do
  f="${site%:*}"; v="${site##*:}"; base="$(basename "$f")"
  # DIVE-3278: `task` moved to src/task/*.sh, so a site is no longer always
  # directly under src/. Address it by its RELATIVE PATH, not its basename.
  mdir="$TMP/m/$base.$v"; mkdir -p "$mdir"; cp -a "$TMP/mut-src" "$mdir/src"
  # Remove ONLY this variable's guard suffix, and confirm the removal landed —
  # an inert mutation and a working scanner leave identical evidence.
  before=$(grep -c " || ${v}=" "$mdir/$f") || before=0
  sed -i -E "s/\) \|\| ${v}=(\"\"|''|0)$/)/" "$mdir/$f"
  after=$(grep -c " || ${v}=" "$mdir/$f") || after=0
  if (( after >= before )); then
    bad_t "F/$base:$v: mutation landed" "guard count did not drop ($before -> $after) — the fix moved or its shape changed"
    continue
  fi
  mout=$(cd "$mdir" && bash "$SCAN" --root=src 2>&1); mrc=$?
  if (( mrc == 1 )) && [[ "$mout" == *"$f"* && "$mout" == *"$v=\$("* ]]; then
    ok_t "F/$base: stripping \`|| $v=…\` makes the scanner name it (differential)"
  else
    bad_t "F/$base: scanner must flag $v after its guard is stripped" "rc=$mrc out=[${mout//$'\n'/ }]"
  fi
done

# ── G. the two shipped instances stay guarded ────────────────────────────────
# DIVE-2603's `_gate_branch_refs_from_text` caller and DIVE-2566's per-repo
# installation lookup are the incidents this class is named after. They are in
# the same tree the scanner just cleared, so E covers them — but only by name
# here, so a future reader can see they were not forgotten.
for pair in "src/task/gate_evidence.sh:_gate_branch_refs_from_text" "src/cmd_push.sh:installation"; do
  f="${pair%:*}"; needle="${pair##*:}"
  if grep -q "$needle" "$ROOT/$f"; then
    ok_t "G: $(basename "$f") still carries the $needle site (E cleared it)"
  else
    bad_t "G: $needle vanished from $f" "the anchor moved — re-derive this arm rather than deleting it"
  fi
done

printf 'unguarded_probe_substitution_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
