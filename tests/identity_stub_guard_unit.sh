#!/usr/bin/env bash
# TIER: nightly — 11.1s measured on ubuntu-latest by the core/pristine-confirm runner
# itself (run 31554029604, 2026-08-12, the tier report's own top-10 line; 8.2s on the
# faster core/pristine box in the same run). Demoted under the MUTATION-HARNESS RULE
# (DIVE-2867): a mutant-killing grader re-scans a corpus once per mutant, so its cost is
# mutants x corpus-walk BY CONSTRUCTION and does not shrink with tuning. A7 mutates every
# file in population B (53 today) and A8 every file in population A (8), and the header
# below says so in its own words — "this harness gets more expensive with every harness
# anyone adds". That is the class DIVE-2867 already decided is nightly.
#
# WHY IT WAS MISSED THEN AND NOT NOW. DIVE-2867 enumerated the class by FILENAME —
# `tests/*_mutation.sh`, six files, three already nightly and three demoted, explicitly
# "to make the class uniform rather than picking files by size". This file mutates by
# construction and is named `_unit.sh`, so a census keyed on the suffix could not return
# it. The rule was right; its enumeration was keyed on the name instead of the shape.
#
# WHAT IS NOT LOST. The demotion changes WHEN, never WHAT: every arm runs unchanged in
# the nightly sweep, and `changed-harnesses` runs this file on any PR that touches it —
# that job is capped for PROBING only and its plain run "stays uncapped, because the
# harness you touched runs is the promise". So the guard still fires at the moment a
# harness is edited; what stops is paying 11s on the 297 PRs that touch nothing here.
# tests/identity_stub_guard_unit.sh — DIVE-2601.
#
# THE CLASS THIS GUARD CLOSES. Since DIVE-2330 the caller derivation does not read
# `id -un`: `_gate_caller_uid` reports $EUID and `_gate_passwd_stream` walks
# /etc/passwd in pure bash, precisely so a PATH-shimmed `id` cannot answer the
# question "who is calling?". Every harness that still stubs the `-un` branch of
# `id` therefore controls NOTHING — and it does not fail when it stops working. It
# goes quiet and keeps voting PASS while the answer comes from the uid of whoever
# ran the suite. DIVE-2588 is the worst case on record: 19/19 green on an agent box,
# 8 arms red on the CI runner, and the property the file claimed to grade had not
# been graded on either.
#
# THE RULE. A harness whose `id()` stub answers `-un` is making an identity claim.
# It must (1) pin the seams the derivation actually reads, and (2) assert the pin
# took effect THROUGH the real resolver before any arm leans on it. (2) is the part
# that converts this whole class from silent to loud: a pin that yields '' makes
# every "refused" arm below look correct for the wrong reason.
#
# WHY A CORPUS GUARD RATHER THAN 13 FIXES. The 13 were fixed (DIVE-2601). The next
# one gets written next week by someone who has not read this file, and the failure
# mode is silence — nothing in a code review distinguishes a green arm that grades
# something from a green arm that grades nothing.
#
# SELF-EXCLUSION, and it is not a formality. A corpus-wide checker matches its own
# pattern: this file must talk about `id()` stubs in order to look for them. The
# scan therefore skips its own basename, and arm A3 below proves the skip works by
# scanning a COPY of this file — because a self-exclusion that silently stopped
# working would make the guard flag itself forever, and a self-exclusion that was
# never needed would leave A3 passing vacuously. See
# community/wiki/a-consistency-check-cannot-see-a-substitution-that-rewrote-both-sides.md
#
# COST: 9.6s measured on the dev3 worktree (5dive-cli-wt-2601, agent-dev3; three runs
# 9.22/9.56/9.61). Up from well under a second: A7/A8 mutate and re-scan 51 real
# harnesses, and the three construct-anchored predicates run an awk per file across
# four passes over tests/. Stays `core` deliberately — the class this catches is
# silent by construction (a green arm that grades nothing looks exactly like a green
# arm that grades something) and 10s against a 300s per-job budget is not the line
# item worth demoting. If the tier gets tight, A7's 43 mutants are the knob.
#
# DIVE-3302 (2026-08-12): the tier got tight — core was 18s over its 363s cap and
# every merge and cut on 5dive-ai/5dive was frozen behind a red `test-confirm`.
# Reduced WITHOUT touching the knob: the four per-file predicates were 4-6 process
# spawns each, run once per file per mutant (53 A7 + 8 A8) on top of a 388-file
# eligibility walk in each arm. Three are now ONE awk (`_file_facts`); `claims_id`
# stays the original grep trio deliberately (see its call site). 12.04s -> 9.49s
# CPU, 3-run means, same session and box — single-run wall clock on this shared
# host swings 12-19s and cannot resolve a 2.5s change. Population, mutant counts
# and arm count all UNCHANGED (8/53/1, 53, 8, 15/0): a cost change with no coverage
# delta, so A7's mutants are still there for whoever needs the next second.
# Memoising the real-file predicates was implemented, measured and REJECTED —
# 1.21s SLOWER (it swaps a short-circuiting two-predicate test for an
# always-compute-three across 388 files) and it adds a staleness hazard no arm
# catches. ops lost the same optimisation earlier to a vacuous cache guard.

set -u
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SELF="$(basename "${BASH_SOURCE[0]}")"

# Harnesses allowed to answer `-un` without pinning the seams, each with the reason
# it is deliberate. Keep this list short and keep the reasons true: an entry here is
# a claim that the file's `id -un` is read by production code that genuinely still
# calls `id -un`, or that the file is testing `id` itself.
declare -A ALLOW=(
  [proof_identity_guard_unit.sh]='_proof_identity in cmd_proof.sh genuinely still reads `id -un`; this file is its test'
)

# _scan_identity_stubs <dir> — print one `<file>\t<reason>` line per violation.
#
# Taking the directory as an argument is what makes this testable: the same code
# that grades tests/ grades the synthetic fixtures in A1-A3 below. A guard that can
# only be pointed at the real corpus can only be graded by the corpus being clean,
# which is indistinguishable from the guard being broken.
# THE POPULATION PROBLEM, and it is why this function grades TWO populations
# (DIVE-2601 iteration 2). The first cut scanned only files that still carry an
# `id()` stub — which the remediation REMOVES. So every file this ticket fixed
# dropped straight out of the guard's view the moment it was fixed, and the
# remediated set is exactly the set most likely to be one edit away from grading the
# host again. A checker whose population shrinks as its subject is repaired watches
# nobody. Population B below is that set: any harness that PINS the seams, stub or no
# stub. A6 prints both censuses so shrinkage is visible rather than inferred.

# ── the two predicates that must be ANCHORED ON A CONSTRUCT ───────────────────
# THE DEFECT THESE REPLACE (iteration 3, measured by olivia at uid 1011). Both
# rules used to be bare `grep -q <token>` over the whole file — and the remediation
# this guard demands WRITES both tokens into every file it repairs. Rule (0) looked
# for `lib/actor.sh`, which the liveness probe's hint string ends with ("Is
# lib/actor.sh in the source list?") plus two comment lines. Rule (2) looked for
# `_gate_uid_to_agent`, which that same probe names in the message it prints WHEN THE
# RESOLVER IS DEAD. So a repaired file satisfied both rules out of its own prose.
#
# MEASURED: delete ` lib/actor.sh` from the source list of
# gate_tier2_nonce_evidence_unit.sh — the one token rule (0) is about. The harness
# correctly reds rc=1 and this guard stayed green, printing the broken file in the A6
# census as a healthy population-B member. Enrollment worked; DETECTION on an
# enrolled file did not. Rule (2) had a live corpus victim as well:
# gate_lead_standing_unit.sh passed it out of a TRAILING COMMENT (`# not agent-* ->
# _gate_authenticated_actor is EMPTY`) while making no such call anywhere.
#
# This is the lesson already compiled on this ticket's wiki page — anchor an
# applied-check on the LINE THE MUTATION EDITS, never a token the file may mention
# elsewhere — which the guard's own detector had not carried across. A7/A8 below
# mutation-grade the fix on the real corpus, because A2c/A2d prove only that a rule
# is well-formed on synthetic input and say nothing about whether its predicate is
# violable by a real repaired file.

# _sources_actor <file> — does the file actually SOURCE the actor lib? Three
# constructs do it in tests/ today and all three are accepted:
#   (a) `source "$SRC/lib/actor.sh"` / `. src/lib/actor.sh`
#   (b) a `for f in ... lib/actor.sh ...; do source "$SRC/$f"; done` list — the token
#       sits on a CONTINUATION line, so the list is collected from `for` through `do`
#   (c) surgical extraction — `eval "$(sed -n ... src/lib/actor.sh)"`, `_load_from src/lib/actor.sh`
# A prose mention is none of these. Note the `source|\.` preceding-character class
# deliberately excludes `)`: without that, the probe hint's "...(expected probe). Is
# lib/actor.sh..." reads as a `.` command and the hole reopens.
_sources_actor() {
  awk '
    /^[[:space:]]*#/ { next }
    inlist {
      list = list " " $0
      if ($0 ~ /(^|;)[[:space:]]*do([[:space:]]|$)/) { inlist=0; if (list ~ /lib\/(actor|actor_seam)\.sh/) f=1 }
      next
    }
    /^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+in[[:space:]]/ {
      list=$0; inlist=1
      if ($0 ~ /(^|;)[[:space:]]*do([[:space:]]|$)/) { inlist=0; if (list ~ /lib\/(actor|actor_seam)\.sh/) f=1 }
      next
    }
    /lib\/(actor|actor_seam)\.sh/ {
      if ($0 ~ /(^|[;&|({])[[:space:]]*(source|\.)[[:space:]]/) f=1
      else if ($0 ~ /(^|[;&|({[:space:]])(eval[[:space:]]+"?\$\(|_load_from[[:space:]])/) f=1
    }
    END { exit !f }
  ' "$1"
}

# _asserts_resolver <file> — is the pin asserted through a real CALL to the resolver,
# rather than a mention of its name? A call site is in COMMAND POSITION: line start,
# inside `$(`/backtick, or after a `;` `&&` `||` `(` `{` separator. Every prose
# mention in the corpus is preceded by a word character or sentence punctuation
# (`: `, `-> `), which no call site is.
_asserts_resolver() {
  awk '
    /^[[:space:]]*#/ { next }
    /(^|\$\(|`|[;&|({])[[:space:]]*(_gate_authenticated_actor|_gate_uid_to_agent|actor_seam_selftest)([[:space:]]|$|\)|")/ { f=1 }
    END { exit !f }
  ' "$1"
}

# _pins_seams <file> — is this file in population B (it pins the identity seams)?
#
# THE THIRD INSTANCE OF THE SAME SHAPE, closed here rather than at iteration 5. The
# `_gate_(caller_uid|passwd_stream)\(\)` half was always anchored — a function
# DEFINITION at line start is not something prose produces. The `actor_seam_as` half
# was a bare token, so a file that merely NAMED the seam in a comment would enrol in
# population B, and worse: for a file that also stubs `id -un`, a prose `pins=1`
# SUPPRESSES rule (1)'s "stubs `id -un` but never pins" violation. Audited on the
# corpus 2026-08-03: all ~150 occurrences in tests/*.sh are real calls, so there is no
# victim today — this is the shape being closed, not a live defect. A2g is the
# fixture; the guard's own line 353 census listing uses this same function so the two
# cannot drift.
_pins_seams() {
  # DIVE-3302: the grep arm folded into the awk — one spawn, same two predicates.
  awk '
    /^[[:space:]]*_gate_(caller_uid|passwd_stream)\(\)/ { f=1; exit }
    /^[[:space:]]*#/ { next }
    /(^|\$\(|`|[;&|({])[[:space:]]*actor_seam_as([[:space:]]|$)/ { f=1 }
    END { exit !f }
  ' "$1"
}

_file_facts() {   # DIVE-3302: ONE awk for the three per-file predicates that were
  # three separate awk spawns. Each rule is a verbatim copy of the standalone it
  # replaces. `claims_id` is deliberately NOT folded in here — see the note at the
  # call site. Equivalence differential-graded by A9 across the corpus.
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*_gate_(caller_uid|passwd_stream)\(\)/ { pins=1 }
    /(^|\$\(|`|[;&|({])[[:space:]]*actor_seam_as([[:space:]]|$)/ { pins=1 }
    /(^|\$\(|`|[;&|({])[[:space:]]*(_gate_authenticated_actor|_gate_uid_to_agent|actor_seam_selftest)([[:space:]]|$|\)|")/ { asserts=1 }
    inlist {
      list = list " " $0
      if ($0 ~ /(^|;)[[:space:]]*do([[:space:]]|$)/) { inlist=0; if (list ~ /lib\/(actor|actor_seam)\.sh/) srcs=1 }
      next
    }
    /^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+in[[:space:]]/ {
      list=$0; inlist=1
      if ($0 ~ /(^|;)[[:space:]]*do([[:space:]]|$)/) { inlist=0; if (list ~ /lib\/(actor|actor_seam)\.sh/) srcs=1 }
      next
    }
    /lib\/(actor|actor_seam)\.sh/ {
      if ($0 ~ /(^|[;&|({])[[:space:]]*(source|\.)[[:space:]]/) srcs=1
      else if ($0 ~ /(^|[;&|({[:space:]])(eval[[:space:]]+"?\$\(|_load_from[[:space:]])/) srcs=1
    }
    END { printf "%d %d %d", pins, srcs, asserts }
  ' "$1"
}

_claims_id() {   # DIVE-3302: single-spawn replacement for the id()-stub grep trio
  awk '
    /^[[:space:]]*id\(\)/ { seen=1; if ($0 ~ /-un/) { f=1; exit } ; if ($0 ~ /\{/) inblk=1; next }
    inblk { if ($0 ~ /-un/) { f=1; exit } ; if ($0 ~ /\}/) inblk=0 }
    END { exit !(seen && f) }
  ' "$1"
}

_scan_identity_stubs() {
  local dir="$1" f base claims_id pins srcs asrt
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    [[ "$base" == "$SELF" ]] && continue                    # self-exclusion (A3)
    [[ -n "${ALLOW[$base]:-}" ]] && continue

    # Population A — an `id()` stub that ANSWERS -un is making an identity claim. A
    # stub that only handles `id -u` (deploy_unit, agent_git_identity_unit) is pinning
    # a numeric uid for a different guard and is out of scope.
    # DIVE-3302: ONE awk yields all four predicates. Was 4-6 spawns per file, and
    # this runs once per file per mutant (53 A7 mutants + 8 A8), which is where the
    # core tier's overage lived. Equivalence to the four originals is differential-
    # graded by A9 across the whole corpus, not asserted here.
    # claims_id keeps the ORIGINAL grep trio verbatim. My folded awk detected one
    # file the trio misses (its `[^}]*` is blocked by the `}` inside `${1:-}`), which
    # would have RAISED population A 8->9 — a semantic fix smuggled inside a cost fix.
    # Filed separately; this change is performance-only, zero delta.
    claims_id=0
    if grep -qE '^[[:space:]]*id\(\)' "$f" \
       && { grep -qE '^[[:space:]]*id\(\).*\-un' "$f" \
            || grep -qzE 'id\(\)[[:space:]]*\{[^}]*\-un' "$f"; }; then claims_id=1; fi
    read -r pins srcs asrt <<<"$(_file_facts "$f")"

    (( claims_id || pins )) || continue

    # (0) A PIN NEEDS THE FILE IT PINS INTO. The seams and the resolver both live in
    # src/lib/actor.sh. Without it sourced, the override defines a function nothing
    # calls, EVERY assertion through the resolver is a command-not-found that yields
    # '' — so `[[ -z "$pin" ]]` becomes "the empty string is empty" and cannot fail —
    # and the product code under test runs with its actor derivation missing. All
    # three symptoms are silent. Measured in gate_tier2_nonce_evidence_unit.sh.
    if (( pins )) && (( ! srcs )); then
      printf '%s\tpins the identity seams but never sources lib/actor.sh — the override lands on nothing, any assertion through the resolver is command-not-found (yields '"''"', which is the PASS value), and the product code runs with its actor derivation missing\n' "$base"
      continue
    fi
    # (1) the seams the derivation actually reads must be pinned
    if (( claims_id )) && (( ! pins )); then
      printf '%s\tstubs `id -un` but never pins _gate_caller_uid/_gate_passwd_stream — the caller identity comes from the HOST\n' "$base"
      continue
    fi
    # (2) and the pin must be asserted through the real resolver
    if (( claims_id )) && (( ! asrt )); then
      printf '%s\tpins the identity seams but never asserts the pin through the real resolver (_gate_authenticated_actor / _gate_uid_to_agent / actor_seam_selftest)\n' "$base"
    fi
  done
}

# _census <dir> — `<A-count> <B-count>` for the graded populations. Same predicates
# as the scan, deliberately NOT a second implementation of the rules: it counts who
# is LOOKED AT, which is the number a shrinking guard makes disappear quietly.
_census() {
  local dir="$1" f base a=0 b=0 _c _p _s _a
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    [[ "$base" == "$SELF" || -n "${ALLOW[$base]:-}" ]] && continue
    if grep -qE '^[[:space:]]*id\(\)' "$f" \
       && { grep -qE '^[[:space:]]*id\(\).*\-un' "$f" \
            || grep -qzE 'id\(\)[[:space:]]*\{[^}]*\-un' "$f"; }; then a=$((a+1)); fi
    read -r _p _s _a <<<"$(_file_facts "$f")"   # DIVE-3302: one awk for the three
    (( _p )) && b=$((b+1))
  done
  printf '%s %s' "$a" "$b"
}

FIX='tests/gate_enforce_env_bypass_unit.sh:127-154 is the in-tree pattern to copy'

# ── A1 positive control: a violating fixture MUST be flagged ──────────────────
# Without this the whole file could be a no-op that reports a clean corpus.
TMP="$(mktemp -d /tmp/identity-stub-guard.XXXXXX)"
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == violator_unit.sh*never\ pins* ]] \
  && ok_t "A1 a harness that stubs \`id -un\` with no seam pin is flagged" \
  || bad_t "A1 violating fixture is flagged" "scan returned '${got:-<nothing>}' — the guard cannot see the defect it exists for, so a clean corpus below would prove nothing"

# ── A2 the second half of the rule: pinned but unasserted is still a violation ─
cat > "$TMP/violator_unit.sh" <<'EOF'
source "$SRC/lib/actor.sh"
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never asserts the pin"* ]] \
  && ok_t "A2 a pinned-but-unasserted harness is flagged (the DIVE-2588 shape)" \
  || bad_t "A2 pinned-but-unasserted is flagged" "scan returned '${got:-<nothing>}' — a pin that silently yields nothing would pass this guard"

# ── A2c rule (0): pinned, asserted, but lib/actor.sh never sourced ────────────
# The iteration-2 defect, as a fixture. Everything the old guard looked for is
# present — the pin, and the resolver named in an assertion — and NONE of it runs:
# `_gate_uid_to_agent` is command-not-found, the capture is '', and the file's own
# `[[ -z ... ]]` check passes on the failure. This is the arm that would have caught
# it, and it is why rule (0) exists.
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
_pin=$(_gate_uid_to_agent "$(_gate_caller_uid)")
[[ -z "$_pin" ]] || exit 1
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never sources lib/actor.sh"* ]] \
  && ok_t "A2c a pin with no lib/actor.sh source is flagged (the iteration-2 defect)" \
  || bad_t "A2c unsourced-resolver is flagged" "scan returned '${got:-<nothing>}' — an assertion calling a function that does not exist reads as compliant"

# ── A2d rule (0) applies to population B: pinning ALONE is enough to be graded ──
# The remediation removes the `id()` stub. If the population were still gated on that
# stub, every file this ticket fixed would leave the guard's view at the moment it
# was fixed. Same bytes as A2c minus the stub — it must STILL be flagged.
cat > "$TMP/violator_unit.sh" <<'EOF'
_gate_caller_uid() { printf 0; }
_pin=$(_gate_uid_to_agent "$(_gate_caller_uid)")
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never sources lib/actor.sh"* ]] \
  && ok_t "A2d a pinning harness with NO id() stub is still graded (remediated files stay in view)" \
  || bad_t "A2d population B is graded" "scan returned '${got:-<nothing>}' — the guard stops watching a file the moment its stub is removed, which is the moment it is remediated"

# ── A2b negative control: the compliant shape is NOT flagged ──────────────────
cat > "$TMP/violator_unit.sh" <<'EOF'
source "$SRC/lib/actor.sh"
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
_pin=$(_gate_uid_to_agent "$(_gate_caller_uid)")
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ -z "$got" ]] \
  && ok_t "A2b the compliant shape (source + pin + assertion) is not flagged" \
  || bad_t "A2b compliant fixture passes" "scan flagged it: '$got' — a guard that rejects the fix it demands cannot be satisfied"

# ── A2e rule (0) may not be satisfied by PROSE — the iteration-3 defect ──────
# Everything rule (0) used to look for is here and NONE of it sources anything: the
# only `lib/actor.sh` in the file is the hint string the remediation itself writes.
# Under the old whole-file grep this fixture passed. It must be flagged.
cat > "$TMP/violator_unit.sh" <<'EOF'
_gate_caller_uid() { printf 0; }
_probe=$(_gate_uid_to_agent 424242)
[[ "$_probe" == probe ]] || { printf 'NOT OK - resolver not live. Is lib/actor.sh in the source list?\n'; exit 1; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never sources lib/actor.sh"* ]] \
  && ok_t "A2e rule (0) is not satisfied by a prose mention of lib/actor.sh" \
  || bad_t "A2e prose does not satisfy rule (0)" "scan returned '${got:-<nothing>}' — the predicate reads the token the remediation writes, so every repaired file discharges the rule with its own hint string"

# ── A2f rule (2) may not be satisfied by PROSE either ────────────────────────
# The corpus instance was gate_lead_standing_unit.sh, which named the resolver ONLY
# in a trailing comment. Same shape as A2e, other rule.
cat > "$TMP/violator_unit.sh" <<'EOF'
source "$SRC/lib/actor.sh"
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
_gate_caller_uid() { printf 0; }
FAKE_CALLER="claude"   # not agent-* -> _gate_authenticated_actor is EMPTY
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never asserts the pin"* ]] \
  && ok_t "A2f rule (2) is not satisfied by a comment naming the resolver" \
  || bad_t "A2f prose does not satisfy rule (2)" "scan returned '${got:-<nothing>}' — a file that never calls the resolver passes for mentioning it"

# ── A2g the POPULATION predicate may not be satisfied by prose either ────────
# Third instance of the shape. A prose `actor_seam_as` used to set pins=1, which
# SUPPRESSES rule (1) — so naming the seam in a comment bought a file an exemption
# from the rule that it pin the seam. This fixture stubs `id -un`, mentions the seam
# only in a comment, and pins nothing: it must be flagged as UNPINNED, not enrolled.
cat > "$TMP/violator_unit.sh" <<'EOF'
FAKE_CALLER="root"
# this file used to impersonate via actor_seam_as before someone deleted the call
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ "$got" == *"never pins _gate_caller_uid"* ]] \
  && ok_t "A2g a prose mention of actor_seam_as does not enrol a file as pinned" \
  || bad_t "A2g prose does not satisfy the population predicate" "scan returned '${got:-<nothing>}' — naming the seam in a comment exempts a file from having to pin it"

# ── A3 self-exclusion actually works, and is load-bearing ────────────────────
# This file necessarily contains the pattern it hunts for. The pair below is what
# makes the skip observable: IDENTICAL BYTES, one under this file's basename and
# one under another. Copying the real guard would not do it — the guard also
# mentions `_gate_caller_uid` and `_gate_authenticated_actor` in its own greps, so
# it reads as COMPLIANT and A3 would pass whether or not the skip exists. The
# fixture is therefore a known violator wearing the guard's name.
rm -f "$TMP"/*.sh
cat > "$TMP/$SELF" <<'EOF'
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }
EOF
got="$(_scan_identity_stubs "$TMP")"
[[ -z "$got" ]] \
  && ok_t "A3 the guard skips its own basename (a checker matches its own pattern)" \
  || bad_t "A3 self-exclusion" "the guard flags its own basename: '$got'"
mv "$TMP/$SELF" "$TMP/not_the_guard_unit.sh"
got="$(_scan_identity_stubs "$TMP")"
[[ -n "$got" ]] \
  && ok_t "A3b the self-exclusion is load-bearing (same bytes, other name, flagged)" \
  || bad_t "A3b self-exclusion is load-bearing" "the same bytes are not flagged under another name, so A3 passed for free and proves nothing"

# ── A4 the real corpus ────────────────────────────────────────────────────────
rm -f "$TMP"/*.sh
mapfile -t viol < <(_scan_identity_stubs tests)
if (( ${#viol[@]} == 0 )); then
  ok_t "A4 no harness in tests/ stubs \`id -un\` without a pinned, asserted identity"
else
  bad_t "A4 tests/ is free of inert identity stubs" \
    "$(printf '%s violation(s):\n' "${#viol[@]}"; printf '     %s\n' "${viol[@]}"; printf '     %s' "$FIX")"
fi

# ── A5 the allowlist may not rot ──────────────────────────────────────────────
# An entry naming a file that no longer exists is an allowlist nobody is reading.
for base in "${!ALLOW[@]}"; do
  if [[ -f "tests/$base" ]]; then
    ok_t "A5 allowlist entry $base still exists"
  else
    bad_t "A5 allowlist entry $base still exists" "allowlisted file is gone — drop the entry rather than leaving a silent exemption"
  fi
done

# ── A6 the census, PRINTED ────────────────────────────────────────────────────
# A4 says "no violations". That reads identically whether the guard looked at forty
# files or zero, and this guard's population shrinks as its subject is repaired — the
# `id()` stub is what the fix deletes. So print who is being graded. The floor is
# deliberately low: it is a tripwire for the population COLLAPSING (a renamed seam, a
# tightened predicate), not a target to keep topped up.
read -r CA CB < <(_census tests)
printf '     census: population A (stubs `id -un`) = %s, population B (pins the seams) = %s, allowlisted = %s\n' \
  "$CA" "$CB" "${#ALLOW[@]}"
printf '     graded population B:\n'
for f in tests/*.sh; do _pins_seams "$f" && basename "$f"; done | sort | sed 's/^/       /'
(( CB >= 20 )) \
  && ok_t "A6 the guard's population is non-trivial and named (B=$CB files pinning the seams)" \
  || bad_t "A6 population is non-trivial" "only $CB file(s) matched the pin predicate — either the corpus changed shape or the predicate stopped matching, and a guard grading nothing reports the same clean corpus as a guard grading everything"

# ── A7/A8 the rules are VIOLABLE BY THE REAL CORPUS, not only by fixtures ─────
# A1-A2f grade the rules on synthetic input: they prove each rule is well-formed.
# They say NOTHING about whether a rule's predicate can be violated by a file this
# ticket actually repaired — and for three iterations rule (0) could not, because the
# remediation writes the token the predicate reads. A4 cannot see that: a rule nobody
# can violate reports the same clean corpus as a rule that works. So mutate the REAL
# files, one at a time, and require the guard to red on each.
#
# The mutation is olivia's, generalised: strip the anchor token from every line that
# is neither a comment nor a printf — i.e. out of the CONSTRUCT, leaving the prose the
# old predicate was accidentally reading. The count of mutants whose prose SURVIVES is
# reported, because those are the ones that grade the anchoring rather than the token.
rm -f "$TMP"/*.sh
_mutate_and_scan() {   # <basename> <awk-program> — returns the scan output
  local base="$1" prog="$2"
  rm -f "$TMP"/*.sh
  awk "$prog" "tests/$base" > "$TMP/$base"
  _scan_identity_stubs "$TMP"
}
DROP_ACTOR='{ if ($0 ~ /^[[:space:]]*#/ || $0 ~ /printf/) print; else { gsub(/lib\/actor\.sh/,"lib/__absent__.sh"); gsub(/lib\/actor_seam\.sh/,"lib/__absent__.sh"); print } }'
DROP_RESOLVER='{ if ($0 ~ /^[[:space:]]*#/ || $0 ~ /printf/) print; else { gsub(/_gate_authenticated_actor|_gate_uid_to_agent|actor_seam_selftest/,"_gate_absent_resolver"); print } }'

a7_n=0; a7_prose=0; a7_missed=()
for f in tests/*.sh; do
  base="${f##*/}"
  [[ "$base" == "$SELF" || -n "${ALLOW[$base]:-}" ]] && continue
  _pins_seams "$f" || continue
  _sources_actor "$f" || continue                       # only files that currently PASS rule (0)
  got="$(_mutate_and_scan "$base" "$DROP_ACTOR")"
  grep -qE 'lib/actor\.sh' "$TMP/$base" && a7_prose=$((a7_prose+1))
  [[ "$got" == *"never sources lib/actor.sh"* ]] || a7_missed+=("$base")
  a7_n=$((a7_n+1))
done
(( a7_n >= 20 && ${#a7_missed[@]} == 0 )) \
  && ok_t "A7 rule (0) reds on every real repaired file whose source construct is broken ($a7_n mutants, $a7_prose still mention lib/actor.sh in surviving prose)" \
  || bad_t "A7 rule (0) is violable on the real corpus" \
     "$(printf '%s of %s mutant(s) went UNDETECTED:\n' "${#a7_missed[@]}" "$a7_n"; printf '     %s\n' "${a7_missed[@]:-<none — but only $a7_n file(s) were mutable, the population collapsed>}")"

a8_n=0; a8_prose=0; a8_missed=()
for f in tests/*.sh; do
  base="${f##*/}"
  [[ "$base" == "$SELF" || -n "${ALLOW[$base]:-}" ]] && continue
  grep -qE '^[[:space:]]*id\(\)' "$f" \
    && { grep -qE '^[[:space:]]*id\(\).*\-un' "$f" || grep -qzE 'id\(\)[[:space:]]*\{[^}]*\-un' "$f"; } || continue
  _asserts_resolver "$f" || continue                    # only files that currently PASS rule (2)
  got="$(_mutate_and_scan "$base" "$DROP_RESOLVER")"
  grep -qE '_gate_authenticated_actor|_gate_uid_to_agent|actor_seam_selftest' "$TMP/$base" && a8_prose=$((a8_prose+1))
  [[ "$got" == *"never asserts the pin"* ]] || a8_missed+=("$base")
  a8_n=$((a8_n+1))
done
rm -f "$TMP"/*.sh
(( a8_n >= 5 && ${#a8_missed[@]} == 0 )) \
  && ok_t "A8 rule (2) reds on every real \`id -un\` harness whose resolver call is removed ($a8_n mutants, $a8_prose still name it in surviving prose)" \
  || bad_t "A8 rule (2) is violable on the real corpus" \
     "$(printf '%s of %s mutant(s) went UNDETECTED:\n' "${#a8_missed[@]}" "$a8_n"; printf '     %s\n' "${a8_missed[@]:-<none — but only $a8_n file(s) were mutable>}")"

printf '\n%s: %d passed, %d failed\n' "$SELF" "$PASS" "$FAIL"
(( FAIL == 0 ))
