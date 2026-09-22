#!/usr/bin/env bash
# DIVE-4811 — the CORPUS-WIDE twin of board_contract_unit.sh's E7 arm.
#
# THE CLASS. A reader that closes a pipe before the writer has finished kills the
# writer with SIGPIPE. Under `set -o pipefail` the pipeline reports the RIGHTMOST
# non-zero status, so a `grep -q` that FOUND its string can hand the caller 141 —
# the assertion reports the opposite of what it measured. It is a scheduling race,
# so it fires one run in many and never the one you re-run. It froze the release
# cut on 2026-09-21 (DIVE-4806, tests/board_contract_unit.sh E5).
#
# WHY THIS FILE EXISTS. DIVE-4806's E7 greps `"$0"` — it can only ever see the one
# harness it lives in, and it encodes `printf` as the writer although the writer's
# identity is not one of the three ingredients. The corpus kept the hazard. Reading
# 40 archived CI runs for `write error: Broken pipe` found THIRTEEN distinct live
# sites outside that file, in `src/` as well as `tests/`, and in a SECOND syntactic
# shape the E7 pattern cannot express:
#
#     while IFS= read -r x; do … return 0; done < <(some_function)
#
# — the early `return` closes the process substitution under an unfinished writer.
# Measured in src/lib/actor.sh, src/task/routing.sh and src/task/notify.sh; the
# EPIPE surfaced on the stderr of whoever called `5dive`, four to five times per
# CI run, on every shard, on main.
#
# WHAT IS GRADED HERE. Three detectors, each with a POSITIVE control (an arm that
# greps for nothing passes by finding nothing) and a NEGATIVE control (a fixture
# holding the repaired form, so the detector is shown not to fire on the fix):
#
#   A  the strict repaired shape  `printf … | grep -q`     — corpus count MUST be 0
#   B  the wide ingredient        `<anything> | grep -q`   — RATCHET, must not grow
#   C  the process-substitution shape `done < <(fn …)` with an early exit in the
#      loop body — RATCHET, and the three files repaired by this row must be ABSENT
#
# The B and C ratchets are counts, and a count ratchet can be gamed by deleting one
# site while adding another. That is a known and accepted weakness: it is stated
# here rather than papered over. A is not a ratchet — it is zero, and it stays zero.
#
# Isolation: pure static reads of the checkout plus a throwaway fixture tree under
# mktemp. No root, no network, no state dir, nothing written inside the repo.
# Run: bash tests/epipe_corpus_guard_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/epipe-corpus-guard.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ── the detectors ────────────────────────────────────────────────────────────
# Every line this file writes that CONTAINS one of the patterns is tagged
# EPIPE-SELF and filtered out, or the detectors match themselves and this harness
# is red forever. Comment lines are excluded too: prose ABOUT the shape (there is
# a lot of it, in this file and in the ones DIVE-4806 touched) is not a site.
_strict_pat="printf '%s(\\\\n)?' \"\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\" *\\| *grep -q"   # EPIPE-SELF
_wide_pat='\| *grep -q'                                                                  # EPIPE-SELF

_scan_dirs() {  # _scan_dirs <root> -> the trees a 5dive checkout ships
  local r="$1" d
  for d in src tests scripts; do [[ -d "$r/$d" ]] && printf '%s\n' "$r/$d"; done
}

# _sites_strict <root> — file:line of every strict `printf … | grep -q`
_sites_strict() {
  local r="$1"; local -a dirs=(); mapfile -t dirs < <(_scan_dirs "$r")
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  grep -rnE "$_strict_pat" "${dirs[@]}" 2>/dev/null \
    | grep -v 'EPIPE-SELF' | grep -vE ':[0-9]+: *#' || true
}

# _sites_wide <root> — file:line of every `… | grep -q`, whatever the writer
_sites_wide() {
  local r="$1"; local -a dirs=(); mapfile -t dirs < <(_scan_dirs "$r")
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  grep -rnE "$_wide_pat" "${dirs[@]}" 2>/dev/null \
    | grep -v 'EPIPE-SELF' | grep -vE ':[0-9]+: *#' || true
}

# _sites_procsub <root> — `done < <(NAME …)` where NAME is a function DEFINED in
# the tree (a shell function is a multi-write writer; `jq`/`db`/`git` finish in one
# flush far more often) and the loop body contains an early exit. Written in awk so
# the loop-body walk is one pass per file rather than a subshell per hit.
_sites_procsub() {
  local r="$1" f; local -a dirs=(); mapfile -t dirs < <(_scan_dirs "$r")
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  local fns="$TMP/fns.$$"
  grep -rhoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' "${dirs[@]}" 2>/dev/null \
    | sed -E 's/[[:space:]]*\(\).*//; s/^[[:space:]]*//' | sort -u > "$fns" || true
  while IFS= read -r f; do
    awk -v FN="$fns" -v F="$f" '
      BEGIN { while ((getline l < FN) > 0) known[l]=1 }
      { line[NR]=$0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (line[i] !~ /done[[:space:]]*<[[:space:]]*<\(/) continue
          s = line[i]; sub(/.*done[[:space:]]*<[[:space:]]*<\([[:space:]]*/, "", s)
          name = s; sub(/[^A-Za-z0-9_].*/, "", name)
          if (!(name in known)) continue
          body = ""; 
          for (j = i - 1; j >= 1 && j > i - 60; j--) {
            body = line[j] "\n" body
            if (line[j] ~ /^[[:space:]]*(while|for)[[:space:](]/) break
          }
          if (body ~ /(^|[^A-Za-z0-9_])(break|return|exit)([^A-Za-z0-9_]|$)/)
            printf "%s:%d: %s\n", F, i, line[i]
        }
      }' "$f"
  done < <(grep -rl 'done' "${dirs[@]}" --include='*.sh' 2>/dev/null) || true
}

# ── fixture tree: a known-bad sample and its repaired twin ───────────────────
mkdir -p "$TMP/bad/src" "$TMP/bad/tests" "$TMP/good/src" "$TMP/good/tests"
# The known-bad line is ASSEMBLED, never written literally, so this file does not
# itself become a site of the shape it forbids. Tagging it EPIPE-SELF instead would
# tag the FIXTURE too, and A1 — the positive control — would stop firing.
_PIPE='|'
{ echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo 'helpout=$("$BIN" --help)'
  printf '%s %s %s\n' "printf '%s' \"\$helpout\"" "$_PIPE" "grep -q 'install line' && echo ok || echo no"
} > "$TMP/bad/tests/sample_unit.sh"
cat > "$TMP/bad/src/sample.sh" <<'BAD'
walk() {
  local n u
  while IFS=: read -r n _ u _; do
    [[ "$u" == "$1" ]] && { printf '%s' "$n"; return; }
  done < <(stream_it)
}
stream_it() { printf '%s\n' "$(</etc/passwd)"; }
BAD
cat > "$TMP/good/tests/sample_unit.sh" <<'GOOD'
#!/usr/bin/env bash
set -uo pipefail
helpout=$("$BIN" --help)
grep -q 'install line' <<<"$helpout" && echo ok || echo no
GOOD
cat > "$TMP/good/src/sample.sh" <<'GOOD'
walk() {
  local n u body; body=$(stream_it)
  while IFS=: read -r n _ u _; do
    [[ "$u" == "$1" ]] && { printf '%s' "$n"; return; }
  done <<<"$body"
}
stream_it() { printf '%s\n' "$(</etc/passwd)"; }
GOOD

echo "── A: the strict shape is EXTINCT in this corpus ──"
_n=$(_sites_strict "$TMP/bad" | wc -l)
[[ "$_n" == "1" ]] \
  && ok_t "A1 positive control: the strict detector fires on the known-bad sample (1 hit)" \
  || bad_t "A1 positive control" "the detector found $_n hits in the bad fixture, expected 1 — every A arm below would pass vacuously"
_n=$(_sites_strict "$TMP/good" | wc -l)
[[ "$_n" == "0" ]] \
  && ok_t "A2 negative control: it does NOT fire on the repaired herestring form" \
  || bad_t "A2 negative control" "$_n hit(s) on the repaired fixture — the detector is grading syntax it should accept"
_hits=$(_sites_strict "$ROOT")
_n=$(printf '%s' "$_hits" | grep -c . || true)
[[ "$_n" == "0" ]] \
  && ok_t "A3 zero \`printf … | grep -q\` sites in src/, tests/ and scripts/ — a matching grep cannot score as a miss" \
  || bad_t "A3 the strict shape is back" "$_n site(s):
$(printf '%s\n' "$_hits" | head -20)"

echo "── B: the wide ingredient — a RATCHET, not a zero ──"
# The writer's identity is not one of the three ingredients, so the honest census
# is every `| grep -q`. Most are inert (the writer finishes before the reader can
# close) and "N files match a regex" is not N defects — so this arm holds the line
# rather than demanding zero. Raise the baseline only with the reason written here.
_WIDE_BASELINE=165   # measured 2026-09-22 on DIVE-4811's tree, AFTER the 153-site sweep (it was 308 before)
_n=$(_sites_wide "$TMP/bad" | wc -l)
[[ "$_n" -ge 1 ]] \
  && ok_t "B1 positive control: the wide detector fires on the known-bad sample ($_n hit)" \
  || bad_t "B1 positive control" "the wide detector matches nothing — B2 would pass vacuously"
_n=$(_sites_wide "$TMP/good" | wc -l)
[[ "$_n" == "0" ]] \
  && ok_t "B2 negative control: the wide detector does not fire on the repaired form" \
  || bad_t "B2 negative control" "$_n hit(s) on the repaired fixture"
_n=$(_sites_wide "$ROOT" | grep -c . || true)
[[ "$_n" -le "$_WIDE_BASELINE" ]] \
  && ok_t "B3 the \`| grep -q\` census is $_n, at or under the $_WIDE_BASELINE baseline" \
  || bad_t "B3 the census grew" "$_n sites, baseline $_WIDE_BASELINE — write the new one as \`grep -q PAT <<<\"\$var\"\` (no writer process, nothing to SIGPIPE), or raise the baseline in this file with the reason"

echo "── C: the process-substitution shape the E7 pattern cannot express ──"
_PROCSUB_BASELINE=28   # measured 2026-09-22 after this row repaired 3 of 31
_n=$(_sites_procsub "$TMP/bad" | wc -l)
[[ "$_n" == "1" ]] \
  && ok_t "C1 positive control: the procsub detector fires on the known-bad sample (1 hit)" \
  || bad_t "C1 positive control" "$_n hits in the bad fixture, expected 1 — every C arm below would pass vacuously"
_n=$(_sites_procsub "$TMP/good" | wc -l)
[[ "$_n" == "0" ]] \
  && ok_t "C2 negative control: it does NOT fire once the stream is captured first" \
  || bad_t "C2 negative control" "$_n hit(s) on the repaired fixture"
_ps=$(_sites_procsub "$ROOT")
_n=$(printf '%s' "$_ps" | grep -c . || true)
[[ "$_n" -le "$_PROCSUB_BASELINE" ]] \
  && ok_t "C3 the procsub census is $_n, at or under the $_PROCSUB_BASELINE baseline" \
  || bad_t "C3 the procsub census grew" "$_n sites, baseline $_PROCSUB_BASELINE — capture the stream first (\`body=\$(fn); … done <<<\"\$body\"\`) or mapfile it"
# C4 is the MUTATION-RESISTANT arm and the reason C is not just a count. These
# three files are where the EPIPE was MEASURED in archived CI logs (11 harness
# files carried the fixture that made it visible; the defect was in these three).
# Revert any one repair and this arm reds by name, whatever the total count does.
# C3 grades the CLASS. C4 is a regression pin on the two writers whose EPIPE is in
# the archived logs, and it is deliberately named: a pin is allowed to name the
# instance, a detector is not. Both writers are shell functions that emit a
# multi-KB / multi-line stream, and every consumer must drain before it can stop.
_c4_bad=""
for _w in _gate_passwd_stream _task_escalation_chain; do
  _n4=$(grep -rnE "done[[:space:]]*<[[:space:]]*<\\([[:space:]]*$_w" "$ROOT/src" 2>/dev/null | grep -vE ':[0-9]+: *#' | grep -c . || true)
  [[ "$_n4" == "0" ]] || _c4_bad+="$_w($_n4) "
done
[[ -z "$_c4_bad" ]] \
  && ok_t "C4 the MEASURED repairs hold: no consumer reads _gate_passwd_stream or _task_escalation_chain from an interruptible process substitution" \
  || bad_t "C4 a measured repair was reverted" "back to \`done < <(…)\`: $_c4_bad— these are the writers whose \`write error: Broken pipe\` is in the archived logs (run 35675798411 and siblings)"

printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
