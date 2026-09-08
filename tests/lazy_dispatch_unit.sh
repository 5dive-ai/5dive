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
#   T9  startup budget, spent RELATIVE to this bundle's own `bash -n` time, so a
#       slow runner scales both halves and cancels: a command must cost under
#       75% of a full parse. Eager was 119-161% of it, lazy is 26-48%.
#   T10 LOAD-PATH budget: a verb that loads SEVERAL modules, timed against an
#       eager bundle built from the same src/, interleaved. T9 cannot see this
#       class by construction — it probes the two verbs that load nothing and
#       one module — and iteration 1 of this row shipped a real regression
#       underneath it: `task ls` and `agent list` were SLOWER than eager because
#       a module whose first call lands inside `$( )` is re-read on every call.
#   T11 the preload table exists, is capped, and names known call edges. It is
#       what keeps T10 green, and an empty one reads exactly like "nothing calls
#       across a module boundary" — the same silent shape as T3.
#
# Run: bash tests/lazy_dispatch_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/lazy-dispatch-unit.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

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
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
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
  for probe in "--version" "whoami"; do
    ms=$(run_ms "$probe")
    pct=$(( ms * 100 / PARSE ))
    if [[ "$pct" -le 75 ]]; then
      ok_t "\`5dive $probe\` costs ${ms}ms = ${pct}% of a full parse (budget 75%)"
    else
      bad_t "\`5dive $probe\` stays under 75% of a full parse" \
            "${ms}ms against a ${PARSE}ms parse = ${pct}%. Eager was 119-161%; a module has moved back into the eager core."
    fi
  done
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
  bc=999999; bl=999999
  for i in 1 2 3 4 5; do
    t0=$(date +%s%N); "$CONTROL" task ls >/dev/null 2>&1 || true; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); [[ "$d" -lt "$bc" ]] && bc=$d
    t0=$(date +%s%N); "$BUNDLE"  task ls >/dev/null 2>&1 || true; t1=$(date +%s%N)
    d=$(( (t1 - t0) / 1000000 )); [[ "$d" -lt "$bl" ]] && bl=$d
  done
  if [[ "$bc" -lt 150 ]]; then
    bad_t "the eager control is measurable" \
          "\`task ls\` on the eager control read ${bc}ms — too small to divide by, so the ratio below would be noise."
  else
    pct=$(( bl * 100 / bc ))
    if [[ "$pct" -le 110 ]]; then
      ok_t "\`task ls\` costs ${bl}ms = ${pct}% of the eager control's ${bc}ms (budget 110%)"
    else
      bad_t "\`task ls\` stays within 110% of the eager control" \
            "${bl}ms against ${bc}ms = ${pct}%. A module is being re-read out of a \`\$( )\`: run with FIVE_LAZY_TRACE=1 and look for the same module loading twice. Iteration 1 of DIVE-4087 measured 124% here."
    fi
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
