#!/usr/bin/env bash
# DIVE-2039 ACCEPTANCE — selfcheck proven by MUTATION, not by a green run.
#
# This is the whole ticket's acceptance criterion, and it is not a formality. A green
# run cannot distinguish a probe that asserts the rail from a probe that asserts
# nothing — that is precisely how heartbeat_gate_shipped_unit.sh shipped unwired for
# three releases while printing "14 passed, 2 failed" and exiting 0 (DIVE-2003), and
# how the ship-flag epoch guard produced an identical signature deleted and working.
# A prover for the succeeding-in-appearance defect class that could itself succeed in
# appearance would be the joke writing itself.
#
# So for each rail: BREAK IT FOR REAL, require selfcheck goes red AND names the
# breakage; restore, require green. "It passed" is not evidence here.
#
# Method: the repo is copied to a throwaway dir, the mutation is applied to the COPY's
# src/ (or tests/), a throwaway bundle is built from it, and that bundle is run. The
# live tree is never mutated — a harness that edits the source it is grading can
# leave a box broken when it dies halfway.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"

command -v sqlite3 >/dev/null 2>&1 || { printf 'skip - sqlite3 absent\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sc-mut.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# A pristine copy of the tree, rebuilt into its own bundle.
WORK="$TMP/repo"
mkdir -p "$WORK"
cp -R "$REPO/src" "$REPO/tests" "$REPO/build.sh" "$WORK/" 2>/dev/null
cp "$REPO/5dive.sha256" "$WORK/" 2>/dev/null || true
rebuild() { (cd "$WORK" && bash build.sh >/dev/null 2>&1); }
rebuild || { printf 'FAIL: could not build the pristine copy\n'; exit 1; }

# Run one probe against the throwaway bundle, with the probes that read a checkout
# pointed at the throwaway checkout rather than the live one.
SC_SUDO=""   # set to "sudo -n" for the probes that can only be measured as root
SC_ENV=()    # extra env the probe under test needs (e.g. a fixture ops repo)
probe() { # probe <probe-id> -> RC/OUT
  OUT=$($SC_SUDO env SELFCHECK_REPO_ROOT="$WORK" "${SC_ENV[@]+"${SC_ENV[@]}"}" \
        bash "$WORK/5dive" selfcheck --only="$1" 2>&1); RC=$?
}
# Full restore. `rm -rf` first: `cp -R src "$WORK/"` onto an existing dir nests it as
# src/src, which would leave the mutation live in the tree it claims to have restored.
restore() {
  rm -rf "$WORK/src" "$WORK/tests"
  cp -R "$REPO/src" "$REPO/tests" "$WORK/"
  rebuild
}

# assert_mutation <probe> <label> <mutator-fn> <expected-substring>
# The MUTATOR owns rebuilding, because not every mutation survives one: build.sh
# regenerates 5dive.sha256, so rebuilding after the bundle-integrity mutation would
# silently repair it and the probe would "pass" a mutation that was never applied.
assert_mutation() {
  local p="$1" label="$2" mut="$3" want="$4"
  probe "$p"
  if [[ $RC -eq 0 ]]; then ok_t "[$p] green before the mutation"
  else fail_t "[$p] NOT green before the mutation, so a red after it would prove nothing: $OUT"; return; fi

  "$mut" || { fail_t "[$p] mutation '$label' could not be applied — the probe is UNPROVEN, not passing"; restore; return; }
  probe "$p"
  if [[ $RC -ne 0 ]]; then ok_t "[$p] RED when $label"
  else fail_t "[$p] STILL GREEN when $label — this probe asserts nothing: $OUT"; fi
  if grep -qi -- "$want" <<<"$OUT"; then ok_t "[$p] the red output names the breakage"
  else fail_t "[$p] red, but for an unnamed reason (wanted /$want/): $OUT"; fi

  restore
  probe "$p"
  if [[ $RC -eq 0 ]]; then ok_t "[$p] green again once restored"
  else fail_t "[$p] did not recover after restore — the mutation leaked: $OUT"; fi
}

# ── rail 1: gate delivery ────────────────────────────────────────────────────
# Remove the DIVE-1968 delivery assertion: the wrapper stops synthesising a row for a
# notify path that recorded nothing. The gate is filed, reports OK, records NOTHING —
# the exact live state that left 194 undelivered rows.
mut_gate() {
  grep -q 'if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then' "$WORK/src/cmd_task.sh" || return 1
  sed -i 's/if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then/if false; then/' "$WORK/src/cmd_task.sh"
  rebuild
}
assert_mutation gate-delivery "the gate delivery assertion is removed" mut_gate "reported as pinged"

# ── rail 2: the audit log ────────────────────────────────────────────────────
# Reinstate DIVE-1989: gate the audit append on $EUID, so an agent running a verb as
# ITSELF writes no row while the identical command under sudo writes one. Measured
# from the non-root side, which is the side the defect hid on.
mut_audit() {
  grep -q '^_emit_audit_line() {' "$WORK/src/lib/audit.sh" || return 1
  sed -i 's/^_emit_audit_line() {/_emit_audit_line() {\n  [[ $EUID -eq 0 ]] || return 0/' "$WORK/src/lib/audit.sh"
  rebuild
}
if [[ $EUID -ne 0 ]]; then
  assert_mutation audit-nonroot "an agent's own actions are gated out of the audit log" mut_audit "leaves no trace"
else
  printf 'skip - audit-nonroot mutation needs an unprivileged uid (this run is root)\n'
fi

# ── rail 3: test harness verdicts ────────────────────────────────────────────
# Strand a harness's verdict behind an unconditional `exit 0` — the DIVE-2003 shape
# verbatim. The harness still prints its failures; CI and `task verify --cmd` both
# grade on $? and both go blind.
mut_harness() {
  local h="$WORK/tests/heartbeat_gate_shipped_unit.sh"
  [[ -r "$h" ]] || return 1
  printf '\nexit 0\n' >> "$h"
}
assert_mutation harness-verdicts "a harness's exit status is stranded behind exit 0" mut_harness "UNWIRED"

# ── rail 4: bundle integrity (cheap, and the same lesson) ────────────────────
# A checksum that describes a different bundle is the DIVE-1977 two-cache-generations
# state made local: the pair is self-consistent and neither half is the code.
# NB: no rebuild — build.sh REGENERATES 5dive.sha256, so a rebuild here would repair
# the mutation and hand the probe a green run it never earned.
mut_bundle() {
  printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$WORK/5dive.sha256"
}
assert_mutation bundle-integrity "the tracked checksum describes another bundle" mut_bundle "different generations"

# ── rail 5: the audit log, PRIVILEGED half ───────────────────────────────────
# Same mutation as rail 2, measured from the other side. Skipped-not-silent when
# there is no passwordless sudo: naming what went unproven is the entire point of
# this file, so an unmeasured probe must never fall off the bottom of the output.
#
# NOT the DIVE-1989 mutation used for the non-root leg: `[[ $EUID -eq 0 ]] || return 0`
# is a NO-OP when you are root, so it cannot break this leg and the first cut of this
# case accused a sound probe of asserting nothing. That is the sharp edge of mutation
# testing and worth stating rather than quietly fixing — **a mutation that does not
# change behaviour is indistinguishable from a probe that does not assert**, and the
# harness will always blame the probe. Pick a mutation that provably breaks the
# asserted EFFECT for the actor under test: here, drop every append unconditionally.
if sudo -n true 2>/dev/null; then
  SC_SUDO="sudo -n"
  mut_audit_drop() {
    grep -q '^_emit_audit_line() {' "$WORK/src/lib/audit.sh" || return 1
    sed -i 's/^_emit_audit_line() {/_emit_audit_line() {\n  return 0/' "$WORK/src/lib/audit.sh"
    rebuild
  }
  assert_mutation audit-root "the audit append is dropped for every actor" mut_audit_drop "leaves no trace"
  SC_SUDO=""
else
  printf 'SKIP - audit-root mutation needs passwordless sudo; this probe is UNPROVEN in this run\n'
fi

# ── rail 6: scorecard honesty ────────────────────────────────────────────────
# THE ONE THAT WAS BLIND (found by main against 93f2ca9, and the reason this section
# exists). Render every metric as a constant instead of its NO DATA marker: the
# scorecard then reports 0.42 for dimensions with NO SOURCE AT ALL — autonomous
# rollback rate has none, DIVE-1923 is open for exactly that — and the published
# autonomy badge is computed from these rows. The probe reported ok through it,
# because it shelled out to `command -v 5dive` and graded the healthy INSTALLED
# binary rather than the mutated bundle it was part of. Invisible in CI, where no
# 5dive is installed and `$0` won. This case is the regression test for that.
mut_scorecard() {
  local ln
  ln=$(grep -n "NO DATA — {m\['nodata'\]}" "$WORK/src/cmd_proof.sh" | head -1 | cut -d: -f1)
  [[ -n "$ln" ]] || return 1
  sed -i "${ln}s|NO DATA — {m\['nodata'\]}|0.42|" "$WORK/src/cmd_proof.sh"
  rebuild
}
assert_mutation scorecard-honesty "every metric renders a constant instead of NO DATA" \
  mut_scorecard "rendering as results"

# The same defect stated directly, so a future refactor of the resolver reds HERE and
# not only through the mutation above: the probe must grade the bundle it is part of.
probe scorecard-honesty
if grep -q "graded $WORK/5dive" <<<"$OUT"; then
  ok_t "[scorecard-honesty] grades the bundle under test, not whatever \`5dive\` is on PATH"
else
  fail_t "[scorecard-honesty] graded the wrong artifact: $(grep -o 'graded [^]]*' <<<"$OUT")"
fi

# ── rail 7: snapshot rails ───────────────────────────────────────────────────
# Against a FIXTURE ops repo, never the live one — the real crontab-snapshot commits
# to a shared git repo, and a prover that mutates a shared surface is the thing this
# verb exists to prevent. The fixture is a byte copy of the real script with only its
# REPO constant repointed, which is the same one-line isolation the probe itself
# asserts (and refuses to grade if the copy differs by more than that).
OPS="$TMP/ops"
mkfixture_ops() {
  local real="${SELFCHECK_SNAPSHOT_SH:-/home/claude/projects/5dive/ops/bin/crontab-snapshot.sh}" u live
  [[ -r "$real" ]] || return 1
  mkdir -p "$OPS/bin" "$OPS/crontabs"
  sed "s|^REPO=\".*\"$|REPO=\"$OPS\"|" "$real" > "$OPS/bin/crontab-snapshot.sh"
  local n=0
  for u in root claude $(ls /home 2>/dev/null | grep -E '^agent-' || true); do
    id "$u" >/dev/null 2>&1 || continue
    live=$(sudo -n crontab -l -u "$u" 2>/dev/null) || continue
    [[ -n "$live" ]] || continue
    printf '%s\n' "$live" > "$OPS/crontabs/$u.crontab"; n=$((n+1))
  done
  (( n > 0 ))
}
if mkfixture_ops; then
  SC_ENV=(SELFCHECK_SNAPSHOT_SH="$OPS/bin/crontab-snapshot.sh")
  mut_snapshot() {
    # A committed snapshot that no longer matches the live crontab — i.e. the rail
    # reported "saved" and did not save this. Restored by rewriting it, not by the
    # shared `restore`, since the fixture lives outside $WORK.
    local f; f=$(ls "$OPS/crontabs/"*.crontab 2>/dev/null | head -1) || return 1
    [[ -n "$f" ]] || return 1
    cp "$f" "$f.orig"
    printf '# selfcheck mutation: this snapshot no longer matches the live crontab\n' >> "$f"
  }
  restore() { local f; for f in "$OPS/crontabs/"*.crontab.orig; do [[ -e "$f" ]] && mv "$f" "${f%.orig}"; done
              rm -rf "$WORK/src" "$WORK/tests"; cp -R "$REPO/src" "$REPO/tests" "$WORK/"; rebuild; }
  assert_mutation snapshot-rails "a committed snapshot no longer matches the live crontab" \
    mut_snapshot "differs from its live crontab"
  SC_ENV=()
else
  printf 'SKIP - snapshot-rails mutation needs a readable crontab-snapshot.sh and `sudo -n crontab -l`; this probe is UNPROVEN in this run\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
