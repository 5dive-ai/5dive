#!/usr/bin/env bash
# DIVE-4087 — the bundle stopped parsing itself whole, and these are the arms
# that stop that from becoming a fleet outage.
#
# THE CHANGE BEING GUARDED. The installed `5dive` is one file. bash parses a
# script before it runs any of it, so at 93,846 lines EVERY call — heartbeat
# tick, `task ls`, `agent send` — paid 0.20s to reach a dispatcher that then used
# one module. The bundle now ends its executable region with a top-level `exit`
# and carries `src/cmd_*.sh` / `src/task/*.sh` BELOW it as unparsed text, read
# back a line range at a time by `_load_module`. Core is 14,281 lines; measured
# on this host, `5dive --version` went 214ms -> 45ms and `5dive whoami`
# 290ms -> 82ms.
#
# WHY THE ARMS ARE SHAPED LIKE THIS. Almost every way this can break presents as
# NOTHING — an empty dep table looks exactly like "no module shares a global",
# an unparsed payload region looks exactly like a working bundle until a cold
# path runs, and a missing stub looks like a working bundle for every command
# except one. So each arm below is written against a specific silent failure,
# and the two scan arms (T4, T5) carry POSITIVE CONTROLS: they construct the
# defect and require the scanner to reject it, because a scanner that finds
# nothing is the thing we are most likely to ship by accident.
#
#   T1  the payload really is unparsed: a deliberate syntax error placed BELOW
#       the exit line does not stop the CLI from running. This is the mechanism;
#       if bash ever reads ahead, every other arm here is beside the point.
#   T2  every function the payload defines at column 0 has a stub in the core,
#       and every stub names the module that actually defines it. A wrong entry
#       here is `cmd_foo: command not found` on one verb.
#   T3  the dep table is non-empty and contains the edges that are known to
#       exist. An empty table builds, installs and dies on a cold path with
#       `unbound variable` — the exact shape of a silent under-report.
#   T4  the assignment scanner refuses an unterminated heredoc rather than
#       silently reporting nothing for the rest of the file (positive control:
#       a real file, mutated).
#   T5  every heredoc word in src/ is uppercase — the convention the scanner's
#       one-line regex depends on to tell `<<EOF` from `(1 << attempts)`
#       (positive control: a lowercase one is rejected).
#   T6  no column-0 `declare` without `-g` in a payload module. `_load_module`
#       evals inside a function, where a plain `declare -A` is LOCAL, so the map
#       would exist only for the duration of the load.
#   T7  no function is defined at column 0 by two payload modules — today's
#       bundle resolves that by cat order, and lazy loading cannot.
#   T8  the built bundle parses (`bash -n`) and the core region ends in the
#       `exit` + marker pair build.sh promises.
#   T9  startup budget for `--version`, spent RELATIVE to this bundle's own
#       `bash -n` time, so a slow runner scales both halves and cancels: it must
#       cost under 75% of a full parse. Eager was 119%, lazy is 29-30%. Only a
#       probe whose cost IS the parse belongs here — `whoami` does not, and it
#       red-gated at 78% inside a contended --tier=core run; it is graded
#       against the eager control in T10 instead.
#   T10 LOAD-PATH budget: a verb that loads SEVERAL modules, timed against an
#       eager bundle built from the same src/, interleaved. T9 cannot see this
#       class by construction — it probes the two verbs that load nothing and
#       one module — and iteration 1 of this row shipped a real regression
#       underneath it: `task ls` and `agent list` were SLOWER than eager because
#       a module whose first call lands inside `$( )` is re-read on every call.
#   T12 the SECOND load-path budget. T10 caps `task ls` only, and quinn's
#       iteration-2 read found `heartbeat ls` at ~117% of eager with nothing
#       watching it — a disclosed residual with no arm is a residual that grows.
#       `heartbeat ls` has the widest closure of any cheap verb (7 modules).
#   T13 the bundle refuses to be PIPED into a shell with a reason. It reads its
#       modules back out of $0, so `cat 5dive | bash -s -- whoami` cannot work;
#       before this it died `sed: can't read /.../bash`, a message about the
#       wrong thing. Unsupported, but it must fail legibly.
#   T14 the integrity check still fires on a REWRITTEN bundle. Iteration 3 made
#       it 20x cheaper by grepping the frame lines out first; this arm is what
#       says cheaper did not become vacuous.
#   T11 the preload table exists, is capped, and names known call edges. It is
#       what keeps T10 green, and an empty one reads exactly like "nothing calls
#       across a module boundary" — the same silent shape as T3.
#   T15 the ratio arms' DENOMINATOR FLOOR skips instead of failing. T10's floor
#       shipped as a bad_t, and on 2026-09-09 a lean runner reading a 146ms
#       control red-gated a required context on main and held release-cut with
#       10 commits uncut — while the ratio at that reading was 61-63% against a
#       110% cap. The branch is unreachable on a fat box, so it is graded here
#       with synthetic readings, in both directions.
#
# Run: bash tests/lazy_dispatch_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/lazy-dispatch-unit.XXXXXX)"

PASS=0; FAIL=0; SKIPPED=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# A GUARD THAT CANNOT MEASURE MUST NOT RETURN A VERDICT.
#
# Iteration 3 of this row shipped the opposite and it stopped the fleet. The
# ratio arms below refuse to divide by a control that is too small, and that
# refusal was spelled bad_t — a FAILURE, worded as if the load path were over
# budget. On 2026-09-09 a lean runner read the control at 146ms where this fat
# box reads ~690ms, `core-pristine (2)` went red on main at bd650aef with
# 30 passed / 1 failed, `release-cut` gates on main being green, and 10 merged
# commits sat uncut on every managed box. Nothing was wrong with the code: the
# ratio at that reading was 61-63% against a 110% cap.
#
# skip_t is the third verdict that was missing. NOT MEASURED is not NOT WORKING,
# and a harness that cannot tell them apart will eventually accuse the code for
# the runner's speed. Skips do not count toward FAIL and do not change the exit
# code; they are printed so the log says plainly that an arm graded nothing.
skip_t() { SKIPPED=$((SKIPPED+1)); printf 'skip - %s\n   %s\n' "$1" "${2:-}"; }

# THE DENOMINATOR FLOOR, and why it is 60 and not 150.
#
# Every timing arm here is a RATIO against an eager control built from the same
# src/ and measured in the same seconds, so the runner cancels out. What does
# not cancel is the cost of the measurement itself — two `date +%s%N` calls plus
# a fork and exec, ~5ms on this class of box. Below some control reading that
# stops being a rounding error, so the arms refuse to grade. This is that
# threshold, and it is now ONE constant: this file carrying a 60ms floor on
# `whoami` and a 150ms floor on `task ls`, off the same timer, was the tell.
#
# 150 was wrong in the dangerous direction. It was picked on this fat host,
# where `task ls` costs ~690ms (~550ms of it sqlite) and 150 looks like a fifth
# of nothing. Across the shards of the last green run the SAME control measured
# 175/177/185/186/192ms, so the floor sat ~15% below the low end of its own
# observed distribution — and the sibling `heartbeat ls` arm cleared it by 2ms
# in the same job. Which of the two arms tripped was a per-run coin flip.
#
# WHY 60 IS THE RIGHT DIRECTION TO BE WRONG IN. The ~5ms overhead is ADDITIVE
# and it lands on BOTH halves of the ratio. For a lazy reading below its control
# — every case this file is trying to hold — (l+e)/(c+e) > l/c, so the overhead
# biases the ratio UPWARD, toward the cap. It can make a passing arm read worse;
# it cannot let a regression through. Combined with min-of-5, which already
# suppresses the upward tail, the floor is therefore not what protects the cap
# from noise. Its only job is to stop a division that is mostly overhead. At
# 60ms the overhead is 8% of the denominator; below that the reading is more
# timer than probe. Raising the floor "to be safe" is not safe — it is how the
# LEAN runner, the only box where the load path is a large enough share of the
# call to see at all, silently loses the arm that caught a real 117% regression
# in iteration 2.
#
# Overridable so the skip path can be graded (T15) without re-running the file.
RATIO_FLOOR_MS="${LAZY_RATIO_FLOOR_MS:-60}"

# The verdict half of every ratio arm, split from the measurement half so the
# sub-floor branch can be exercised with synthetic readings. On this host the
# floor cannot fire naturally, which is precisely why the bad_t shipped.
_ratio_verdict() { # <what> <control_ms> <lazy_ms> <cap_pct> <regression_hint>
  local what="$1" c="$2" l="$3" cap="$4" hint="$5" pct
  if (( c < RATIO_FLOOR_MS )); then
    skip_t "$what: NOT MEASURED — the eager control is under the ${RATIO_FLOOR_MS}ms floor" \
           "control ${c}ms, lazy ${l}ms (resampled, still under). At this size the ratio is mostly the timer, so this arm graded NOTHING. This is not a statement about the load path and must not be read as one."
    return 0
  fi
  pct=$(( l * 100 / c ))
  if (( pct <= cap )); then
    ok_t "$what costs ${l}ms = ${pct}% of the eager control's ${c}ms (budget ${cap}%)"
  else
    bad_t "$what stays within ${cap}% of the eager control" \
          "${l}ms against ${c}ms = ${pct}%. $hint"
  fi
}

# Interleaved min-of-N, control and lazy alternating inside one loop so a
# scheduling gust lands on both. Unchanged sampling: the min-of-5 IS the arm's
# non-flakiness margin and this row is not permitted to spend it.
_min_pair() { # <samples> <verb...> -> "<control_ms> <lazy_ms>"
  local n="$1"; shift
  local bc=999999 bl=999999 t0 t1 d i
  for (( i = 0; i < n; i++ )); do
    t0=$(date +%s%N); "$CONTROL" "$@" >/dev/null 2>&1 || true; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); if (( d < bc )); then bc=$d; fi
    t0=$(date +%s%N); "$BUNDLE"  "$@" >/dev/null 2>&1 || true; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); if (( d < bl )); then bl=$d; fi
  done
  printf '%s %s\n' "$bc" "$bl"
}

# SKIP *AND* RESAMPLE, in that order. A single sub-floor read can be one lucky
# scheduling window rather than a genuinely fast box, so the second min-of-5 is
# paid only on runs that were about to grade nothing anyway.
_timed_ratio_arm() { # <what> <cap_pct> <hint> <verb...>
  local what="$1" cap="$2" hint="$3"; shift 3
  local c l
  read -r c l < <(_min_pair 5 "$@")
  if (( c < RATIO_FLOOR_MS )); then
    read -r c l < <(_min_pair 5 "$@")
  fi
  _ratio_verdict "$what" "$c" "$l" "$cap" "$hint"
}

# shellcheck source=scripts/lib/lazy-dispatch.sh
. scripts/lib/lazy-dispatch.sh

# The file lists are read out of build.sh rather than restated here: a copy of
# them in this harness would go stale exactly when a module moves between the
# eager and lazy regions, which is the change most worth grading.
mapfile -t LAZY_FILES < <(sed -n '/^LAZY_FILES=(/,/^)/p' build.sh | grep -oE 'src/[A-Za-z0-9_/]+\.sh')
mapfile -t CORE_FILES < <(sed -n '/^CORE_FILES=(/,/^)/p' build.sh | grep -oE 'src/[A-Za-z0-9_/]+\.sh')
if ((${#LAZY_FILES[@]} > 50 && ${#CORE_FILES[@]} > 10)); then
  ok_t "build.sh names both regions (${#CORE_FILES[@]} core + ${#LAZY_FILES[@]} lazy files)"
else
  bad_t "build.sh names both regions" \
        "core=${#CORE_FILES[@]} lazy=${#LAZY_FILES[@]} — the sed that reads them has stopped matching"
fi

# A bundle to grade. Never ./5dive: that is the developer's working artifact and
# BUILD_OUT inside the repo is refused (DIVE-2681), so build outside it.
BUNDLE="$TMP/5dive"
if ! BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "build.sh produces a bundle" "$(tail -5 "$TMP/build.log")"
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIPPED"
  exit 1
fi
MARKER_LINE=$(grep -n '^# ==== 5dive lazy payload' "$BUNDLE" | head -1 | cut -d: -f1)

# --- T1: the payload is genuinely unparsed -----------------------------------
# The claim the whole design rests on is "bash does not read past a top-level
# exit". Assert it on the real artifact, with a real syntax error, rather than
# on a toy: append `fi` with no `if` — which `bash -n` rejects — below the
# marker, and require the CLI to still answer.
cp "$BUNDLE" "$TMP/5dive-poisoned"
printf 'fi\n' >>"$TMP/5dive-poisoned"
chmod +x "$TMP/5dive-poisoned"
if bash -n "$TMP/5dive-poisoned" 2>/dev/null; then
  bad_t "the payload region is not parsed at run time" \
        "control failed: the poison line is not a syntax error, so this arm proves nothing"
elif out=$("$TMP/5dive-poisoned" --version 2>&1) && [[ "$out" == 5dive* ]]; then
  ok_t "the payload region is not parsed at run time (a syntax error below the exit is inert)"
else
  bad_t "the payload region is not parsed at run time" "--version said: $out"
fi

# --- T2: every payload function has a stub, pointing at the right module ------
: >"$TMP/expected"
for f in "${LAZY_FILES[@]}"; do
  # src/cmd_task.sh is a loader with no definitions of its own and no index
  # entry; see build.sh. It contributes no stubs.
  [[ "$f" == src/cmd_task.sh ]] && continue
  m="$(lazy_mod_name "$f")"
  lazy_funcs "$f" | sed "s|\$| $m|" >>"$TMP/expected"
done
sort -o "$TMP/expected" "$TMP/expected"
# The stub is emitted as `name(){` with no space so that harness rewrites
# anchored on `^name() {` cannot hit it — see scripts/lib/lazy-dispatch.sh.
sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)(){ _lazy_autoload \([A-Za-z0-9_]*\) .*/\1 \2/p' \
  "$BUNDLE" | sort >"$TMP/actual"
if diff -u "$TMP/expected" "$TMP/actual" >"$TMP/stubdiff" 2>&1; then
  ok_t "all $(wc -l <"$TMP/expected" | tr -d ' ') payload functions have a stub naming their own module"
else
  bad_t "all payload functions have a stub naming their own module" \
        "$(head -20 "$TMP/stubdiff")"
fi

# Every stub must sit ABOVE the payload marker, or it is itself unparsed text.
STUBS_BELOW=$(awk -v m="$MARKER_LINE" 'NR > m && /^[A-Za-z_][A-Za-z0-9_]*\(\)\{ _lazy_autoload /' "$BUNDLE" | wc -l)
if [[ "$STUBS_BELOW" -eq 0 ]]; then
  ok_t "no stub was emitted below the payload marker"
else
  bad_t "no stub was emitted below the payload marker" "$STUBS_BELOW stub(s) are in the unparsed region"
fi

# --- T3: the dep table is populated, and holds the edges we know exist --------
# `sort -u FILE >FILE` once truncated the core-name list, and the ONLY symptom
# was an empty __MODDEPS — which reads as "no module shares a global with
# another". Pin both the shape and a sample of the content.
sed -n '/^declare -gA __MODDEPS=(/,/^)/p' "$BUNDLE" >"$TMP/deps"
NEDGE=$(grep -c '^  \[' "$TMP/deps" || true)
if [[ "$NEDGE" -ge 10 ]]; then
  ok_t "__MODDEPS carries $NEDGE dependant modules"
else
  bad_t "__MODDEPS carries dependant modules" \
        "only $NEDGE — an empty or near-empty table is how an under-report looks"
fi
# Three edges, each read off a DIFFERENT global so one lucky match cannot carry
# the arm: cmd_heartbeat reads cmd_selfupdate's _PR_FIRED; task/notify.sh reads
# cmd_agent_runtime's MIRROR_POST_*; cmd_supervisor reads cmd_watch's WATCH_*.
for pair in "cmd_heartbeat cmd_selfupdate" "task__notify cmd_agent_runtime" "cmd_supervisor cmd_watch"; do
  set -- $pair
  if grep -qE "^  \[$1\]=.*\b$2\b" "$TMP/deps"; then
    ok_t "dep edge $1 -> $2 is in the table"
  else
    bad_t "dep edge $1 -> $2 is in the table" "$(grep -E "^  \[$1\]=" "$TMP/deps" || echo '<no row for '"$1"'>')"
  fi
done

# --- T4: the assignment scan refuses an unterminated heredoc ------------------
# POSITIVE CONTROL. A heredoc the scanner opens and never closes makes it skip
# the rest of the file, so every global below vanishes and the dep edge with it.
# That happened for real on a `# <<< DIVE-3172` comment. The scanner must exit
# non-zero rather than answer partially.
{ head -20 src/cmd_watch.sh; printf 'cat <<NEVERCLOSED\nbody\n'; } >"$TMP/mutant.sh"
if lazy_assigns "$TMP/mutant.sh" >/dev/null 2>"$TMP/mutant.err"; then
  bad_t "an unterminated heredoc is a scan failure, not a partial answer" \
        "lazy_assigns returned 0 on a file with an open heredoc"
elif grep -q 'never closed' "$TMP/mutant.err"; then
  ok_t "an unterminated heredoc is a scan failure, not a partial answer"
else
  bad_t "an unterminated heredoc is a scan failure, not a partial answer" \
        "exited non-zero but said: $(cat "$TMP/mutant.err")"
fi
# The negative twin: the same file WITHOUT the mutation must scan clean, so the
# arm above is grading the mutation and not the temp directory.
if lazy_assigns src/cmd_watch.sh >/dev/null 2>&1; then
  ok_t "the unmutated twin scans clean (the control grades the defect, not the fixture)"
else
  bad_t "the unmutated twin scans clean" "src/cmd_watch.sh itself fails the scan"
fi

# --- T5: heredoc words in src/ are uppercase ---------------------------------
# The scanner tells a heredoc from an arithmetic left shift by requiring an
# UPPERCASE word: `(1 << attempts)` in cmd_supervisor.sh and `(1 << to)` in
# cmd_agent_buzz_join.sh are shifts, and taking either for a heredoc swallowed
# the rest of that file. A new lowercase heredoc word would re-open the hole,
# and it would fail silently, so the convention is enforced here.
LOWER=$(grep -rnE '<<-?[[:space:]]*("[a-z]|'"'"'[a-z]|[a-z][A-Za-z0-9_]*$)' src/ \
        | grep -v '<<<' | grep -vE '^\S+:[0-9]+:[[:space:]]*#' || true)
if [[ -z "$LOWER" ]]; then
  ok_t "every heredoc word in src/ is uppercase (what makes the scanner's regex safe)"
else
  bad_t "every heredoc word in src/ is uppercase" "$LOWER"
fi
# POSITIVE CONTROL for the scan above: it must actually flag a lowercase word.
printf 'cat <<lower\nx\nlower\n' >"$TMP/lowerdoc.sh"
if grep -qE '<<-?[[:space:]]*[a-z][A-Za-z0-9_]*$' "$TMP/lowerdoc.sh"; then
  ok_t "the uppercase-word scan can fire (control)"
else
  bad_t "the uppercase-word scan can fire (control)" "the pattern missed a deliberate lowercase heredoc"
fi

# --- T6: column-0 `declare` in a payload module must carry -g -----------------
# _load_module evals a module INSIDE a function. A plain `declare -A M=(...)`
# there is a LOCAL, so the map is gone the moment the load returns — and the
# five that exist (cmd_agent_runtime, cmd_loop, cmd_supervisor x3) are read on
# ordinary paths. `readonly`, `export` and a bare assignment all reach the
# global from function scope; `declare` is the one that does not.
BADDECL=$(grep -nE '^declare[[:space:]]+-[a-zA-Z]*[Aai][a-zA-Z]*[[:space:]]' "${LAZY_FILES[@]}" \
          | grep -vE '^\S+:[0-9]+:declare[[:space:]]+-[a-zA-Z]*g' || true)
if [[ -z "$BADDECL" ]]; then
  ok_t "no column-0 \`declare\` without -g in a lazily loaded module"
else
  bad_t "no column-0 \`declare\` without -g in a lazily loaded module" "$BADDECL"
fi

# --- T7: no function defined at column 0 by two payload modules ---------------
DUPES=$(awk '{print $1}' "$TMP/expected" | sort | uniq -d)
if [[ -z "$DUPES" ]]; then
  ok_t "no function is defined at column 0 by two payload modules"
else
  bad_t "no function is defined at column 0 by two payload modules" "$DUPES"
fi

# --- T8: the artifact's shape ------------------------------------------------
if bash -n "$BUNDLE" 2>"$TMP/parse.err"; then
  ok_t "the built bundle parses end to end (payload included)"
else
  bad_t "the built bundle parses end to end" "$(head -3 "$TMP/parse.err")"
fi
if [[ -n "$MARKER_LINE" ]] && [[ "$(sed -n "$((MARKER_LINE - 1))p" "$BUNDLE")" == 'exit $?' ]]; then
  ok_t "the executable region ends with \`exit \$?\` immediately above the payload marker"
else
  bad_t "the executable region ends with \`exit \$?\` above the payload marker" \
        "marker at line ${MARKER_LINE:-<absent>}, line above: $(sed -n "$((${MARKER_LINE:-2} - 1))p" "$BUNDLE")"
fi

# --- T9: the startup budget, spent in a RELATIVE unit -------------------------
# The whole row exists for this number, so it gets a tripwire — but not an
# absolute one. A fixed millisecond cap on `whoami` red-gated at 124ms against a
# measured 82ms on the first contended run, which is the failure CLAUDE.md's
# tiering section already describes: a cap that stops measuring the corpus and
# starts measuring the VM.
#
# So spend it in units of THIS bundle's own full parse: `bash -n` on the whole
# file is exactly the work lazy dispatch exists to stop paying, and it scales
# with the box. Eagerly, a command cost that parse PLUS its own work, so the
# ratio was above 1 (measured on an eager control built from the same src/:
# --version 214ms against a 180ms parse = 1.19, whoami 290ms = 1.61). Lazily it
# is a fraction (45ms = 0.26, 82ms = 0.48). A threshold of 0.75 sits in the gap
# with room on both sides, and no VM speed moves it.
parse_ms() {
  local t0 t1 d best=999999 i
  for i in 1 2 3; do
    t0=$(date +%s%N); bash -n "$BUNDLE"; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); [[ "$d" -lt "$best" ]] && best=$d
  done
  echo "$best"
}
run_ms() { # <args...> -> best of 5, in ms. Contention only ever adds, so the
           # low sample is the least contaminated estimate (DIVE-2592's rule).
  local t0 t1 d best=999999 i
  for i in 1 2 3 4 5; do
    t0=$(date +%s%N); "$BUNDLE" "$@" >/dev/null 2>&1 || true; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); [[ "$d" -lt "$best" ]] && best=$d
  done
  echo "$best"
}
PARSE=$(parse_ms)
if [[ "$PARSE" -lt 20 ]]; then
  bad_t "the full-parse reference is measurable" \
        "bash -n on the bundle read ${PARSE}ms — too small to divide by; the ratio arms below would be noise"
else
  ok_t "full parse of the bundle is ${PARSE}ms (the cost lazy dispatch exists to avoid)"
  # ONLY `--version` is graded against the parse unit, and that is a correction,
  # not a narrowing. The relative unit cancels the box only for a probe whose
  # cost IS the parse: `--version` is 29-30% of it here and 119% eagerly, so the
  # two regimes are three-fold apart and no amount of contention closes that.
  # `whoami` is not that probe — it forks, execs and reads identity, so its own
  # work is most of its 94ms, and contention inflates a fork-heavy numerator
  # much harder than it inflates a pure `bash -n` denominator. It measured 69%
  # standalone and 78% against the same 75% cap inside a full --tier=core run,
  # i.e. the arm was grading the runner, which is the exact failure the relative
  # unit exists to end. It moves down to T10 and is graded against an EAGER
  # CONTROL instead: same work on both sides, contention hits both.
  ms=$(run_ms "--version")
  pct=$(( ms * 100 / PARSE ))
  if [[ "$pct" -le 75 ]]; then
    ok_t "\`5dive --version\` costs ${ms}ms = ${pct}% of a full parse (budget 75%)"
  else
    bad_t "\`5dive --version\` stays under 75% of a full parse" \
          "${ms}ms against a ${PARSE}ms parse = ${pct}%. Eager was 119-161%; a module has moved back into the eager core."
  fi
fi

# --- T11: the preload table -------------------------------------------------
# `__MODCALLS` is what makes T10 pass. It is a HINT, not a contract: a missing
# entry costs one more `sed` and a wrong one costs one more module, because the
# autoload stubs resolve the call either way. That is exactly why it must be
# graded by CONTENT — an empty table is a valid, working, and 25% slower bundle,
# and it reads identically to "nothing calls across a module boundary" (the same
# silent shape as T3, and the shape `sort -u "$f" >"$f"` actually produced once).
CALLS_BLOCK=$(sed -n '/^declare -gA __MODCALLS=(/,/^)/p' "$BUNDLE")
CALLS_N=$(grep -cE '^  \[' <<<"$CALLS_BLOCK" || true)
if [[ "$CALLS_N" -ge 20 ]]; then
  ok_t "the preload table names $CALLS_N modules"
else
  bad_t "the preload table is populated" \
        "only $CALLS_N entries. An empty or near-empty __MODCALLS builds and runs; it just puts every multi-module verb back behind the eager bundle (T10)."
fi
# By content, and these three are read out of src/ rather than restated: the
# edge must still be a real call site, not a name this harness remembers.
CALLS_MISSING=""
for edge in "cmd_agent cmd_auth" "task__crud task__inbox" "cmd_agent cmd_agent_runtime"; do
  set -- $edge
  grep -qE "^  \[$1\]=.*$2" <<<"$CALLS_BLOCK" || CALLS_MISSING+="$1 -> $2 "
done
if [[ -z "$CALLS_MISSING" ]]; then
  ok_t "the preload table holds the measured thrash edges by content"
else
  bad_t "the preload table holds the measured thrash edges by content" \
        "absent: $CALLS_MISSING — these are the edges that took \`agent list\` from +656ms to parity."
fi
# And the cap holds. A module that calls into many others is a DISPATCHER, and
# preloading a dispatcher's whole surface is the eager bundle with extra steps:
# uncapped, cmd_heartbeat (13 callees) took `heartbeat ls` from 1352ms to 1980.
CAP_MAX=$(awk -F= '/^  \[/ { gsub(/\\/, "", $2); n = split($2, a, " ");
                    if (n > m) { m = n; w = $1; gsub(/[][ ]/, "", w) } }
                  END { print m+0, w }' <<<"$CALLS_BLOCK")
CAP_N="${CAP_MAX%% *}"
if [[ "$CAP_N" -ge 1 && "$CAP_N" -le 6 ]]; then
  ok_t "no module preloads more than 6 others (widest: ${CAP_MAX#* } with $CAP_N)"
else
  bad_t "no module preloads more than 6 others" \
        "widest is ${CAP_MAX#* } with $CAP_N. The fan-out cap in scripts/lib/lazy-dispatch.sh has moved or stopped applying."
fi

# --- T10: the LOAD-PATH budget, against an eager control from the same src ----
# T9 probes `--version` and `whoami`: the verbs that load NOTHING and ONE
# module. It is blind to the load path by construction, and iteration 1 of this
# row shipped a real regression underneath it — quinn measured `task ls`
# 621 -> 755ms and `agent list` 2590 -> 3390ms while startup was 5x faster,
# because a module whose first call lands inside `$( )` is re-read on every
# call. This arm is the one that can see that.
#
# It is graded against an EAGER bundle built from the SAME src/, interleaved,
# min-of-N: both halves meet the same contention in the same seconds, so the
# ratio is the measurement and the runner's speed cancels. Same relative-unit
# argument as T9 — a fixed millisecond cap here would be measuring the VM.
CONTROL="$TMP/5dive-eager-control"
cat "${CORE_FILES[@]}" "${LAZY_FILES[@]}" src/main.sh >"$CONTROL" 2>/dev/null
chmod +x "$CONTROL"
if ! "$CONTROL" --version >/dev/null 2>&1; then
  bad_t "an eager control bundle builds from the same src/" \
        "$CONTROL does not run; without it this arm cannot separate a lazy regression from a slow box."
else
  ok_t "an eager control bundle builds from the same src/ ($(wc -l <"$CONTROL" | tr -d ' ') lines)"
  # STARTUP, graded against the control rather than against `bash -n` (see T9).
  # `whoami` loads exactly one module, so it is the cheapest probe that still
  # touches the load path at all, and against an eager twin the comparison is
  # like-for-like: both forks, both sqlite reads, both contended in the same
  # seconds. Measured 266ms eager -> 94ms lazy = 35%; the budget is 75%.
  # This arm carried the SAME sub-floor bad_t as T10 and T12 — it simply never
  # fired, because `whoami` is cheap enough that 60 was already the derived
  # number. Routed through the shared verdict so the three cannot drift again.
  _timed_ratio_arm '`whoami`' 75 \
    'Startup has moved back toward the eager bundle: a module is being parsed that no longer needs to be.' \
    whoami
  # Non-vacuity, checked and not assumed: the probe has to be a MULTI-module
  # verb or this arm grades the same thing T9 already does.
  LOADED=$(FIVE_LAZY_TRACE=1 "$BUNDLE" task ls 2>&1 >/dev/null \
           | sed -n 's/^5dive\[lazy\] load //p' | tr ' ' '\n' | sort -u | grep -c .)
  if [[ "$LOADED" -ge 3 ]]; then
    ok_t "\`task ls\` is a multi-module probe (loads $LOADED modules)"
  else
    bad_t "\`task ls\` is a multi-module probe" \
          "it loaded $LOADED. This arm only grades the load path while the probe uses it; pick a wider verb."
  fi
  _timed_ratio_arm '`task ls`' 110 \
    'A module is being re-read out of a `$( )`: run with FIVE_LAZY_TRACE=1 and look for the same module loading twice. Iteration 1 of DIVE-4087 measured 124% here.' \
    task ls

  # --- T12: the SECOND load-path budget --------------------------------------
  # WHY A SECOND ONE. T10 caps `task ls`, and on iteration 2 that left
  # `heartbeat ls` sitting at ~117% of eager with no arm on it at all — quinn
  # found it by hand and correctly refused to accept a disclosed residual that
  # nothing would notice growing. `heartbeat ls` is the right second probe
  # because it has the widest closure of any verb cheap enough to time (7
  # modules against `task ls`'s 6) AND it is the one the fan-out cap
  # deliberately keeps OUT of the preload table, so it exercises the load path
  # in its unassisted shape. Same relative unit and the same 110% cap as T10.
  HB_LOADED=$(FIVE_LAZY_TRACE=1 "$BUNDLE" heartbeat ls 2>&1 >/dev/null \
              | sed -n 's/^5dive\[lazy\] load //p' | tr ' ' '\n' | sort -u | grep -c .)
  if [[ "$HB_LOADED" -ge 3 ]]; then
    ok_t "\`heartbeat ls\` is a multi-module probe (loads $HB_LOADED modules)"
  else
    bad_t "\`heartbeat ls\` is a multi-module probe" \
          "it loaded $HB_LOADED. This arm only grades the load path while the probe uses it; pick a wider verb."
  fi
  _timed_ratio_arm '`heartbeat ls`' 110 \
    'Iteration 2 measured 117% here with no arm to catch it; the load path has regressed for the widest-closure verb.' \
    heartbeat ls
fi

# --- T13: piped into a shell, it refuses with a reason -----------------------
# `cat 5dive | bash -s -- whoami` gives the loader no file to read its modules
# out of, so it cannot work — and until this row it died `sed: can't read
# /.../bash`, which names the wrong thing entirely. It is not a supported
# invocation (install.sh pipes the INSTALLER, never the bundle); the contract is
# only that it fails legibly and does not look like a broken install.
PIPED="$(cat "$BUNDLE" | bash -s -- whoami 2>&1 || true)"
if [[ "$PIPED" == *"is a file, not a stream"* ]]; then
  ok_t "piping the bundle into bash refuses with a reason, not a sed ENOENT"
elif [[ "$PIPED" == *"can't read"* || "$PIPED" == *"No such file"* ]]; then
  bad_t "piping the bundle into bash refuses with a reason" \
        "it died on the loader's own sed instead: ${PIPED:0:200}"
else
  bad_t "piping the bundle into bash refuses with a reason" \
        "unexpected output: ${PIPED:0:200}"
fi
if [[ "$PIPED" != *"exited"*"without reporting a reason"* ]]; then
  ok_t "that refusal goes through fail(), so the exit-backstop stays quiet"
else
  bad_t "that refusal goes through fail()" \
        "the DIVE-2598 backstop fired on top of it, which reads as a CLI bug rather than an unsupported invocation."
fi

# --- T14: the integrity check still fires on a rewritten bundle --------------
# The frame check is the reason a bundle someone else edited does not run a
# module sliced mid-function (`line 11582: name: No such file or directory`).
# Iteration 3 made it ~20x cheaper by grepping the ~14 frame lines out of the
# slice before matching, instead of scanning the whole 444KB slice twice per
# module. CHEAPER MUST NOT MEAN VACUOUS, so: delete lines from the CORE of a
# built bundle — exactly what tests/buzz_by_design_rc3_not_a_panic_unit.sh does
# — which slides every payload offset, and assert the CLI still answers.
REWRITTEN="$TMP/5dive-rewritten"
awk 'NR>=200 && NR<=260 && /^#/ { next } { print }' "$BUNDLE" >"$REWRITTEN"
chmod +x "$REWRITTEN"
SLID=$(( $(grep -c "" "$BUNDLE") - $(grep -c "" "$REWRITTEN") ))
if [[ "$SLID" -lt 5 ]]; then
  bad_t "the rewrite really slides the payload offsets" \
        "it removed $SLID lines; with no slide this arm proves nothing."
else
  ok_t "the rewrite slides every payload offset by $SLID lines (control)"
  # Graded against the PRISTINE bundle's own answer, not against a literal: this
  # arm is about the loader recovering, and a runner with no task store must not
  # be able to red it (or green it) for a reason that is not the loader's.
  RW_RC=0; RW_OUT="$("$REWRITTEN" task ls --json 2>&1)" || RW_RC=$?
  OK_RC=0; OK_OUT="$("$BUNDLE" task ls --json 2>&1)"     || OK_RC=$?
  if [[ "$RW_RC" == "$OK_RC" && "$RW_OUT" == "$OK_OUT" ]]; then
    ok_t "a rewritten bundle answers identically to the pristine one (the frame fallback recovered)"
  else
    bad_t "a rewritten bundle still loads its modules" \
          "the offsets slid by $SLID and the frame fallback did not recover: rc $RW_RC vs $OK_RC, out ${RW_OUT:0:160}"
  fi
fi


# --- T15: the sub-floor branch SKIPS, and it can still FAIL ------------------
# WHAT THIS EXISTS FOR. The defect that red-gated main was not a wrong number,
# it was a wrong VERDICT CLASS: "I could not measure" printed as "the load path
# is over budget". That branch is unreachable on this fat host — `task ls` here
# is ~690ms — which is exactly why it shipped and why quinn could only reproduce
# it by editing the constant. So grade the verdict function DIRECTLY with
# synthetic readings: microseconds, no rebuild, and it fires on every box.
#
# BOTH DIRECTIONS ARE ASSERTED. A guard that never fails is the other way to
# ship this bug, and "make the red go away" is the failure mode a fix to a red
# is most likely to have. Each call runs in a `$( )` so the corpus counters are
# untouched, and the counts are read back out of the subshell.
_t15_under="$( PASS=0; FAIL=0; SKIPPED=0
  RATIO_FLOOR_MS=60 _ratio_verdict '`synthetic`' 10 9 110 'unreachable hint'
  printf '::%d/%d/%d' "$PASS" "$FAIL" "$SKIPPED" )"
_t15_over="$( PASS=0; FAIL=0; SKIPPED=0
  RATIO_FLOOR_MS=60 _ratio_verdict '`synthetic`' 200 300 110 'unreachable hint'
  printf '::%d/%d/%d' "$PASS" "$FAIL" "$SKIPPED" )"
_t15_ok="$( PASS=0; FAIL=0; SKIPPED=0
  RATIO_FLOOR_MS=60 _ratio_verdict '`synthetic`' 200 100 110 'unreachable hint'
  printf '::%d/%d/%d' "$PASS" "$FAIL" "$SKIPPED" )"

if [[ "$_t15_under" == *"::0/0/1" && "$_t15_under" == *"skip - "* ]]; then
  ok_t "a sub-floor control SKIPS: it adds nothing to FAIL and cannot red a shard"
else
  bad_t "a sub-floor control SKIPS rather than failing" \
        "counts were ${_t15_under##*::} (want 0/0/1). A control too small to divide by must not be spelled as a load-path verdict — that is the bug this arm exists for."
fi

# ASK 3: the message has to name the lazy reading too. Without it CI could not
# even show that the ratio WOULD have passed, so the log said "too small to
# divide by" and nothing else — undiagnosable from the artifact alone.
if [[ "$_t15_under" == *"control 10ms, lazy 9ms"* ]]; then
  ok_t "the sub-floor message prints BOTH readings, so the next one is diagnosable from the log"
else
  bad_t "the sub-floor message prints both readings" \
        "it said: ${_t15_under%::*}"
fi

if [[ "$_t15_over" == *"::0/1/0" && "$_t15_over" == *"FAIL - "* ]]; then
  ok_t "an over-cap ratio still FAILS (300 of 200 = 150% against a 110% cap)"
else
  bad_t "an over-cap ratio still fails" \
        "counts were ${_t15_over##*::} (want 0/1/0). Skipping is not allowed to become the way every reading is answered."
fi

if [[ "$_t15_ok" == *"::1/0/0" ]]; then
  ok_t "an in-budget ratio still PASSES (100 of 200 = 50%)"
else
  bad_t "an in-budget ratio still passes" \
        "counts were ${_t15_ok##*::} (want 1/0/0)."
fi

# The floor is ONE constant now, reached by all three probes. Two floors off the
# same timer, 60 and 150, is what let the wrong one hide behind the right one for
# a whole iteration. Both patterns are split across a string concatenation so
# this arm cannot match its own source lines and grade itself green.
_t15_arms=$(grep -cE "_timed""_ratio_arm '" "$0" || true)
_t15_legacy=$(grep -cE -- "-lt 1""50" "$0" || true)
if (( _t15_arms == 3 && _t15_legacy == 0 )); then
  ok_t "all 3 ratio probes route through one derived floor (${RATIO_FLOOR_MS}ms); no hand-picked 150 survives"
else
  bad_t "the denominator floor is a single derived constant reached by every ratio arm" \
        "found $_t15_arms ratio arms and $_t15_legacy legacy 150ms literals (want 3 and 0)."
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIPPED"
[[ "$FAIL" -eq 0 ]]
