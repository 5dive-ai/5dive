#!/usr/bin/env bash
# TIER: nightly — 70.7s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"

command -v sqlite3 >/dev/null 2>&1 || { printf 'skip - sqlite3 absent\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sc-mut.XXXXXX") || exit 2
PASS=0; FAIL=0
# DIVE-2783: record WHICH rail each arm belonged to, so the end of the run can prove
# the corpus was exercised. `$FAIL -eq 0` alone cannot: it is equally true of a run
# that proved six rails and of a run that proved nothing, which is the
# succeeding-in-appearance shape this whole harness exists to catch — and is exactly
# how it failed, dying before any arm ran.
RAILS_SEEN=""
_rail() { case "$1" in \[*\]*) RAILS_SEEN="$RAILS_SEEN ${1%%]*}]" ;; esac; }
ok_t()   { PASS=$((PASS+1)); _rail "$1"; printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); _rail "$1"; printf 'FAIL - %s\n' "$1"; }

# A pristine copy of the tree, rebuilt into its own bundle.
WORK="$TMP/repo"
mkdir -p "$WORK"
cp -R "$REPO/src" "$REPO/tests" "$REPO/build.sh" "$WORK/" 2>/dev/null
cp "$REPO/5dive.sha256" "$WORK/" 2>/dev/null || true
# DIVE-2783: build.sh has hard-required a resolvable source commit since DIVE-2603
# (#488) — `git rev-parse --verify 'HEAD^{commit}'` or exit 1. This copy is
# deliberately NOT a git repo (it is a throwaway precisely so the prover never
# mutates the tree it grades), so every rebuild() failed and the harness died at the
# line below before a single arm ran — on BOTH full-sweep shards, main's only red.
#
# Give the copy its own one-commit history rather than teaching build.sh to build
# without one: the identity stamp is the whole point of DIVE-2603, and weakening it
# to accommodate a test fixture is the tail wagging the dog. Mutations after this
# point leave the copy dirty, which build.sh stamps `<sha>-dirty` BY DESIGN — that
# is a stamp, not a refusal, so every later rebuild() still succeeds.
git -C "$WORK" init -q \
  && git -C "$WORK" add -A \
  && git -C "$WORK" -c user.name='harness' -c user.email='harness@example.com' \
       -c commit.gpgsign=false commit -qm 'throwaway baseline for the mutation prover' -q \
  || { printf 'FAIL: could not give the pristine copy a git identity (build.sh needs one since DIVE-2603)\n'; exit 1; }
rebuild() { (cd "$WORK" && bash build.sh >/dev/null 2>&1); }
# Name the reason. The bare message here cost a full triage cycle: it says the build
# failed but not why, so a red on a shard nobody can shell into is unattributable and
# gets guessed at from commit timing instead of read off the error.
rebuild || {
  printf 'FAIL: could not build the pristine copy:\n%s\n' \
    "$( (cd "$WORK" && bash build.sh 2>&1) | tail -5 )"
  exit 1
}

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

# ── rail 3b: the CORPUS is a dimension too (DIVE-2061) ───────────────────────
# harness-verdicts was mutation-covered and STILL had a hole, because every mutation
# above varies the HARNESS and none varied the CORPUS — it always ran with a good one
# present. `0 wired, no failures` then read as pass, so a stale cwd graded nothing and
# reported ok (found by main on the rolled 0.16.0: same binary, different cwd).
#
# The lesson is not "add this case"; it is that MUTATION COVERAGE IS PER-DIMENSION.
# A probe reads several inputs — the artifact, the corpus, the actor, the environment —
# and breaking one of them proves nothing about the others. "This probe is
# mutation-covered" is not a property of the probe, it is a property of (probe, input).
# The sample list is READ FROM THE BUNDLE UNDER TEST, never restated here. Two lists in
# two places are one contract with two authors, and a drifted copy would delete the
# wrong files and "prove" the probe sound (DIVE-2004's lesson, applied to a fixture).
mut_corpus_missing_sample() {
  local sample h n=0
  sample=$(grep -m1 -oP '(?<=^SELFCHECK_HARNESS_SAMPLE=")[^"]+' "$WORK/5dive") || return 1
  [[ -n "$sample" ]] || return 1
  for h in ${sample//,/ }; do
    [[ -e "$WORK/tests/$h" ]] && { rm -f "$WORK/tests/$h"; n=$((n+1)); }
  done
  # The mutation must have actually removed something, or this case would accuse a
  # sound probe of asserting nothing — the audit-root trap from earlier in this file.
  (( n > 0 ))
}
assert_mutation harness-verdicts "the corpus contains none of the sampled harnesses" \
  mut_corpus_missing_sample "probed ZERO harnesses"

# Zero probed must never read as pass, and the two zero-causes must not be conflated:
# an EMPTY corpus is environmental (not-reached, exits 0 alone but never satisfies the
# union), while a POPULATED corpus that yielded nothing means we graded the wrong tree
# (error, exits non-zero). Collapsing them would either excuse a misdirected
# measurement or falsely accuse an absent one.
EMPTY="$TMP/emptycorpus"
mkdir -p "$EMPTY/tests/meta"
cp "$REPO/tests/meta/harness-verdict-probe.sh" "$EMPTY/tests/meta/" 2>/dev/null
OUT=$(SELFCHECK_REPO_ROOT="$EMPTY" bash "$WORK/5dive" selfcheck --only=harness-verdicts 2>&1); RC=$?
if grep -q 'NOT-REACHED' <<<"$OUT" && grep -q 'empty-corpus' <<<"$OUT"; then
  ok_t "[harness-verdicts] an EMPTY corpus is not-reached (environmental), not a pass"
else
  fail_t "[harness-verdicts] empty corpus did not report not-reached/empty-corpus: $OUT"
fi
grep -q 'pass' <<<"$(sed -n '3p' <<<"$OUT")" && fail_t "[harness-verdicts] empty corpus read as pass" \
  || ok_t "[harness-verdicts] empty corpus is never rendered as ok"

# And the corpus must be NAMED — the fix that makes all of the above checkable from one
# run instead of two runs and a diff. Same property probe 7 gained with [graded <path>].
probe harness-verdicts
if grep -q "corpus $WORK" <<<"$OUT"; then
  ok_t "[harness-verdicts] names the corpus it graded, and how it was resolved"
else
  fail_t "[harness-verdicts] does not name the corpus: $(grep -o 'corpus [^]]*' <<<"$OUT")"
fi
probe bundle-integrity
grep -q "tree $WORK" <<<"$OUT" \
  && ok_t "[bundle-integrity] names the tree it graded (same resolver, same hazard)" \
  || fail_t "[bundle-integrity] does not name the tree: $OUT"

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

# ── rail 8: the sealed lead-clear allowlist (DIVE-2233) ──────────────────────
# This probe cannot be proven the way the others are. Its mutation is not a code edit:
# the rail it grades is a SEALED DOCUMENT, so the only breakage that matters is the
# document ceasing to match the digest sealed into the council lineage. And the ARMED
# branch is unreachable on any box we run this on — nothing has convened the council
# motion that seals `gate_clear_leads`, which is the ticket's own property, not a gap.
# So the fixture supplies a sealed constitution via STATE_DIR and drives all three
# states in one place. Without this the probe would ship having only ever emitted
# "INERT" — indistinguishable from a probe hard-coded to say INERT.
SC_LC="$(mktemp -d "${TMPDIR:-/tmp}/5dive-lcseal.XXXXXX")"
sc_lc_seal() {  # re-seal whatever bytes are on disk right now
  mkdir -p "$SC_LC/council"
  printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
    "$(sha256sum < "$SC_LC/constitution.yaml" | awk '{print $1}')" > "$SC_LC/council/lineage.jsonl"
}
printf 'ship:\ncomms:\nauthority:\n  gate_clear_leads:\n    - main\n' > "$SC_LC/constitution.yaml"
sc_lc_seal
SC_ENV=(STATE_DIR="$SC_LC")

probe lead-clear-seal
if [[ $RC -eq 0 ]] && grep -q 'ARMED' <<<"$OUT"; then
  ok_t "[lead-clear-seal] a SEALED allowlist reports ARMED and names the lead"
else
  fail_t "[lead-clear-seal] a sealed allowlist did not report ARMED (rc=$RC): $OUT"
fi
# NON-VACUITY for the INERT message the live box emits: the same probe, same code,
# must say something DIFFERENT here. A probe that always printed INERT would pass
# every assertion the live run can make.
grep -q 'INERT' <<<"$OUT" && fail_t "[lead-clear-seal] reported INERT while a lead WAS sealed — the probe does not read the document" \
                          || ok_t "[lead-clear-seal] ARMED and INERT are distinguishable (not a fixed string)"

# THE MUTATION: tamper the sealed bytes without re-sealing. This is the
# tamper-is-self-defeating property — the legitimate holder loses the clearance too.
printf '    - rogue\n' >> "$SC_LC/constitution.yaml"
probe lead-clear-seal
if [[ $RC -ne 0 ]]; then ok_t "[lead-clear-seal] RED when the constitution is tampered without re-sealing"
else fail_t "[lead-clear-seal] STILL GREEN with a drifted constitution — this probe asserts nothing: $OUT"; fi
if grep -qi 'drift' <<<"$OUT"; then ok_t "[lead-clear-seal] the red names DRIFT, not a generic config gap"
else fail_t "[lead-clear-seal] red for an unnamed reason (wanted /drift/): $OUT"; fi
# And it must NOT read as the benign inert state — those demand opposite responses
# (investigate a tamper vs. convene a motion).
grep -q 'INERT' <<<"$OUT" && fail_t "[lead-clear-seal] a DRIFTED constitution reported as benign INERT" \
                          || ok_t "[lead-clear-seal] drift is not conflated with the benign inert state"

# Recovery: re-sealing the tampered bytes restores it — the seal is the variable.
sc_lc_seal
probe lead-clear-seal
if [[ $RC -eq 0 ]] && grep -q 'ARMED' <<<"$OUT"; then
  ok_t "[lead-clear-seal] green again once the same bytes are re-sealed (the seal is the variable)"
else
  fail_t "[lead-clear-seal] did not recover after re-sealing (rc=$RC): $OUT"
fi

# The INERT branch, proven against a real empty state dir rather than assumed.
rm -f "$SC_LC/constitution.yaml" "$SC_LC/council/lineage.jsonl"
probe lead-clear-seal
if [[ $RC -eq 0 ]] && grep -q 'INERT' <<<"$OUT"; then
  ok_t "[lead-clear-seal] an unsealed box reports INERT and stays GREEN (fail-closed is not a failure)"
else
  fail_t "[lead-clear-seal] an unsealed box did not report a green INERT (rc=$RC): $OUT"
fi
SC_ENV=()
rm -rf "$SC_LC"

# DIVE-2783: prove the corpus RAN. Every rail below is unconditional on every box;
# audit-nonroot is deliberately absent from the list because it self-skips as root,
# and a floor that reds on a legitimate skip would be its own false signal.
#
# This is the arm that makes the fix gradeable. Restoring the build and leaving the
# prover silent — an early exit, a copy that builds but produces no bundle, a rail
# that stops being invoked — passes `$FAIL -eq 0` and fails here.
for _r in gate-delivery harness-verdicts bundle-integrity scorecard-honesty lead-clear-seal; do
  case "$RAILS_SEEN" in
    *"[$_r]"*) ;;
    *) fail_t "[corpus] rail '$_r' produced NO arm at all — the prover was SILENT on it, which is indistinguishable from a pass on \$FAIL alone" ;;
  esac
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
