#!/usr/bin/env bash
# DIVE-2013: a harness whose EXIT STATUS is not wired to its own assertions can
# never fail CI, no matter how loudly it prints FAIL. That is not hypothetical:
# heartbeat_gate_shipped_unit.sh shipped that way for three consecutive releases
# (0.15.26/27/28) printing "14 passed, 2 failed" and exiting 0, because a tally
# `printf` had been moved after the verdict line. CI runs `for t in tests/*.sh`
# and `5dive task verify --cmd` grades on exit 0 — both were blind.
#
# Static analysis CANNOT close this (olivia measured three instruments, all
# agreeing, none sound): none can see a harness whose assertions never fire, a
# verdict placed before the last assertion, or a `set -e` verdict bypassed. So
# this is EMPIRICAL — it induces a failure and demands the harness report it.
#
# For each tests/*.sh:
#   1. establish it is green clean (or take that from a prior suite run with
#      --assume-clean, which is what CI does since the `test` job just proved it)
#   2. identify the verdict variable from the final verdict expression
#   3. inject `<VAR>=$((<VAR>+1))` immediately BEFORE the verdict line
#   4. require exit != 0
#
# A harness whose verdict variable cannot be identified is reported UNPROBEABLE
# and FAILS the check. A silent skip here would be the exact defect class the
# check exists to find — that is the whole lesson of DIVE-2003.
#
# Lives in tests/meta/ deliberately: `tests/*.sh` does not glob subdirectories,
# so the suite never runs this, and this never recurses into itself.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
ASSUME_CLEAN=0; ONLY=""; REPORT=""; LABEL=""; TIMEOUT=${PROBE_TIMEOUT:-180}
for a in "$@"; do case "$a" in
  --assume-clean) ASSUME_CLEAN=1 ;;
  --only=*) ONLY="${a#--only=}" ;;      # one basename, or a comma-separated list
  # DIVE-2018: a machine-readable verdict per harness, so the UNION of several
  # environments can be asserted to cover the corpus. NOT-REACHED is correctly not
  # a failure in any single run (a skip is not an accusation), which is precisely
  # why no single run can establish coverage — see harness-verdict-union.sh.
  --report=*) REPORT="${a#--report=}" ;;
  --label=*)  LABEL="${a#--label=}" ;;  # names the environment in union failures
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

# Allowlisted UNPROBEABLE, BY NAME with a reason — the cmd_init.sh heredoc pattern:
# still detected and still reported, just permitted. A NEW unprobeable harness is
# not covered by this and reds the check, which is the property olivia asked for
# (a silent skip here is the defect the check exists to find).
#
#   council_amend_e2e.sh          hand-verified by olivia: exits 1 at `if (( fail ))`
#                                 and only reaches its hardcoded "0 failed" echo when
#                                 fail==0.
#   schema_sync_unit.sh           hand-verified by olivia: ends in `EOF` closing a
#                                 python heredoc whose own `sys.exit(1 if fail else 0)`
#                                 propagates.
#   council_roster_lineage_e2e.sh READ, NOT EMPIRICALLY PROVEN: `set -uo pipefail` with
#                                 per-assertion `|| { echo "FAIL: …"; exit 1; }`, so it
#                                 is wired by explicit exit — but it has no verdict
#                                 variable and no `set -e`, so neither mutation applies
#                                 and this probe cannot demonstrate it. Weaker evidence
#                                 than the other two; say so rather than imply parity.
ALLOW_UNPROBEABLE="council_amend_e2e.sh council_roster_lineage_e2e.sh schema_sync_unit.sh"

WIRED=(); UNWIRED=(); UNPROBEABLE=(); ALREADY_RED=(); ALLOWED=(); NOT_REACHED=()

# Extract the verdict variable from a harness's last executable line.
# Prints "<var>\t<lineno>" or nothing. Handles the shapes olivia's census found:
# [[ "$V" -eq N ]] / [[ $V -eq N ]] / [ "$V" -eq N ] / (( V == N )) /
# [[ "$V" == "N" ]] / exit $V.
# TWO harness families need TWO mutations, and conflating them is how this probe
# produced three FALSE POSITIVES on its first run (byo_model_create, codex_bin_
# resolution, openclaw_runtime — all `set -euo pipefail` with bare `[[ ]]`
# assertions). Their exit status IS wired; the probe had grabbed a STRING operand
# out of the last `[[ ]]` and "incremented" it, which proves nothing. Ground truth:
# breaking a real assertion in byo_model_create by hand exits 1.
#
#   COUNTER family  — a numeric counter initialised to a number AND incremented,
#                     consumed by a final verdict expression. Mutation: bump it.
#   ABORT family    — `set -e` with assertions that exit on failure and no counter.
#                     Mutation: inject a bare `false`, which set -e must turn into
#                     a non-zero exit. (Wrong for the counter family, where a bare
#                     `false` changes no counter and the harness correctly exits 0
#                     — which is exactly the false positive, inverted.)
#
# Picking the wrong mutation gives a confident wrong answer, which is the defect
# class this check exists to find. So the counter test is STRICT and `false` is
# only used when no counter exists AND `set -e` is in force.
counter_verdict() {   # -> "<var>\t<lineno>\t<last|not-last>"
  local f="$1" n line var="" last_exec=""
  last_exec=$(grep -nvE '^[[:space:]]*(#|$)' "$f" | tail -1 | cut -d: -f1)
  while read -r n; do
    line=$(sed -n "${n}p" "$f")
    # An INVERTED verdict (-ne / !=) is SATISFIED by incrementing — refuse to guess.
    [[ "$line" =~ (-ne|\!=)[[:space:]] ]] && continue
    var=""
    # Regexes live in VARIABLES: an unquoted `)` or `[^)]` inside [[ =~ ]] is a
    # bash syntax error, not a regex. `exit $(( FAIL > 0 ))` is matched first —
    # the bare `exit $VAR` form below would miss it entirely.
    # Anchored right after `$((` — a greedy `.*` here backtracks to the shortest
    # suffix and captures 'L' out of 'FAIL', which is a silently WRONG variable
    # rather than no match. Same trap as everything else tonight: the broken form
    # succeeds at something.
    local re_arith='exit[[:space:]]+\$\(\([[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*[><=!]'
    local re_exit='exit[[:space:]]+\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?'
    local re_dbl='\(\([[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=='
    local re_test='\[\[?[[:space:]]+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?[[:space:]]+(-eq|==)'
    if   [[ "$line" =~ $re_arith ]]; then var="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $re_exit  ]]; then var="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $re_dbl   ]]; then var="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $re_test  ]]; then var="${BASH_REMATCH[1]}"
    fi
    [[ -n "$var" ]] || continue
    # STRICT, and this is the line that separates a real verdict from the STRING
    # operand that produced three false positives: every assignment to the
    # variable must be a NUMERIC LITERAL or an arithmetic expression over itself.
    # A counter (`FAIL=0` … `FAIL=$((FAIL+1))`) and a flag (`fail=0` … `fail=1`)
    # both qualify; `setup_src=$(cat …)` does not, because incrementing a captured
    # string proves nothing about whether the exit status is wired.
    # Assignments must be matched in STATEMENT POSITION. Matching the bare
    # substring `VAR=` also hits `echo "... FAIL=$FAIL"`, which is text inside a
    # string, not an assignment — that false hit made 12 correctly-wired harnesses
    # look UNPROBEABLE, a regression I introduced while fixing five others and did
    # not see because I re-tested only the five.
    local asn="(^[[:space:]]*(local[[:space:]]+)?|[;&|][[:space:]]*)${var}="
    grep -qE "${asn}[0-9]+([[:space:]]|;|\)|$)" "$f" || continue
    # Every statement-position assignment must be a numeric literal or arithmetic
    # over the variable itself. A counter (FAIL=0 … FAIL=$((FAIL+1))) and a flag
    # (fail=0 … fail=1) both qualify; `setup_src=$(cat …)` does not — incrementing
    # a captured string proves nothing about whether the exit status is wired, and
    # that is what produced three false UNWIRED verdicts on the first run.
    if grep -oE "${asn}[^[:space:];]*" "$f" \
       | grep -qvE "${var}=([0-9]+|\\\$\(\(.*${var}.*\)\))$"; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$var" "$n" "$([[ "$n" == "$last_exec" ]] && echo last || echo not-last)"
    return 0
  done < <(grep -nvE '^[[:space:]]*(#|$)' "$f" | tail -12 | cut -d: -f1 | tac)
  return 1
}

CORPUS_N=0; for t in tests/*.sh; do [[ -e "$t" ]] && CORPUS_N=$(( CORPUS_N + 1 )); done
only_set=" ${ONLY//,/ } "
for t in tests/*.sh; do
  b=$(basename "$t")
  # --only takes a LIST so a second environment can re-probe exactly the harnesses
  # the first one skipped, instead of paying for the whole corpus twice.
  [[ -n "$ONLY" && "$only_set" != *" $b "* ]] && continue
  if (( ! ASSUME_CLEAN )); then
    if ! timeout "$TIMEOUT" bash "$t" >/dev/null 2>&1; then ALREADY_RED+=("$b"); continue; fi
  fi
  if spec=$(counter_verdict "$t"); then
    IFS=$'\t' read -r var ln pos <<<"$spec"
    strategy="counter '$var' at line $ln ($pos executable line)"
    inject="${var}=\$((${var}+1))"
  elif grep -qE '^set -[a-z]*e' "$t"; then
    ln=$(grep -nvE '^[[:space:]]*(#|$)' "$t" | tail -1 | cut -d: -f1)
    strategy="injected 'false' before line $ln under set -e"
    inject="false"
  else
if [[ " $ALLOW_UNPROBEABLE " == *" $b "* ]]; then ALLOWED+=("$b"); else UNPROBEABLE+=("$b"); fi; continue
  fi
  # The mutant lives in tests/ as a DOTFILE: `tests/*.sh` will not glob it, and
  # keeping it in the same directory preserves every harness's
  # `cd "$(dirname "$0")/.."` and its relative fixture paths.
  mutant="tests/.probe-${b}"
  # CANARY: a mutation that never EXECUTED proves nothing, and calling that
  # "unwired" is a false accusation. Harnesses that skip early in one environment
  # (no 5dive installed, not root) exit 0 long before the verdict — which is
  # exactly how three correctly-wired files were reported UNWIRED on the CI runner
  # while passing on this box. So the injected line announces itself, and a run
  # that never reached it is NOT-REACHED, never UNWIRED.
  # (community/wiki/test-harness-credential-reach-and-transcript-durability.md:
  #  a canary proves the extractor RAN; the fixture proves it is still RIGHT.)
  awk -v n="$ln" -v inj="$inject" 'NR==n{print inj; print "printf \x27__PROBE_REACHED__\\n\x27 >&2"} {print}' "$t" > "$mutant"
  out=$(timeout "$TIMEOUT" bash "$mutant" 2>&1 >/dev/null); rc=$?
  rm -f "$mutant"
  if ! grep -q '__PROBE_REACHED__' <<<"$out"; then
    NOT_REACHED+=("$b (verdict line $ln never executed — harness exits early in this environment)")
    continue
  fi
  if (( rc == 0 )); then
    UNWIRED+=("$b — $strategy")
  else WIRED+=("$b"); fi
done

printf 'harness-verdict-probe: %d wired, %d UNWIRED, %d UNPROBEABLE, %d allowlisted, %d not-reached, %d already-red\n' \
  "${#WIRED[@]}" "${#UNWIRED[@]}" "${#UNPROBEABLE[@]}" "${#ALLOWED[@]}" "${#NOT_REACHED[@]}" "${#ALREADY_RED[@]}"
for x in "${UNWIRED[@]:-}";     do [[ -n "$x" ]] && printf 'UNWIRED      %s — exit status is NOT wired to its assertions; it cannot fail CI\n' "$x"; done
for x in "${UNPROBEABLE[@]:-}"; do [[ -n "$x" ]] && printf 'UNPROBEABLE  %s — no identifiable verdict variable; NOT counted clean\n' "$x"; done
for x in "${NOT_REACHED[@]:-}";  do [[ -n "$x" ]] && printf 'not-reached  %s — skipped before the verdict here; probed in an environment where it runs\n' "$x"; done
for x in "${ALLOWED[@]:-}";     do [[ -n "$x" ]] && printf 'allowlisted  %s — unprobeable, permitted by name with a recorded reason\n' "$x"; done
for x in "${ALREADY_RED[@]:-}"; do [[ -n "$x" ]] && printf 'ALREADY-RED  %s — failed its own clean run; reported, not probed\n' "$x"; done

# DIVE-2018: the machine-readable half. `not-reached` is still not a failure HERE
# — a skip is not an accusation — so this run cannot establish coverage on its own.
# It records what it actually observed and lets harness-verdict-union.sh assert the
# invariant that does hold: every harness is probed in SOME environment.
# The corpus size and the allowlist travel WITH the verdicts, because the defect
# this closes is two green runs describing different corpora with nothing saying so.
if [[ -n "$REPORT" ]]; then
  {
    printf '# harness-verdict-probe report — one line per harness observed by THIS run\n'
    printf '# corpus=%d\n' "$CORPUS_N"
    printf '# allowlist=%s\n' "${ALLOW_UNPROBEABLE// /,}"
    printf '# label=%s\n' "${LABEL:-$(uname -n)}"
    # Basename is field 1 in every array: the annotated entries are "<name> — …"
    # and "<name> (…)", the rest are bare names.
    for x in "${WIRED[@]:-}";       do [[ -n "$x" ]] && printf 'wired\t%s\n'        "${x%% *}"; done
    for x in "${UNWIRED[@]:-}";     do [[ -n "$x" ]] && printf 'UNWIRED\t%s\n'      "${x%% *}"; done
    for x in "${UNPROBEABLE[@]:-}"; do [[ -n "$x" ]] && printf 'UNPROBEABLE\t%s\n'  "${x%% *}"; done
    for x in "${ALLOWED[@]:-}";     do [[ -n "$x" ]] && printf 'allowlisted\t%s\n'  "${x%% *}"; done
    for x in "${NOT_REACHED[@]:-}"; do [[ -n "$x" ]] && printf 'not-reached\t%s\n'  "${x%% *}"; done
    for x in "${ALREADY_RED[@]:-}"; do [[ -n "$x" ]] && printf 'already-red\t%s\n'  "${x%% *}"; done
    # Terminating `:` is load-bearing. A brace group's status is its LAST command's,
    # and every loop above ends on `[[ -n "$x" ]] && printf` — which is FALSE, not an
    # error, whenever that category is empty. Without this the guard below fired on a
    # perfectly good report and exited 1: a false failure whose only cause was reading
    # the wrong exit status, which is the same defect this whole check exists to find,
    # committed inside the fix for it. With `:`, a failed redirect (bash aborts the
    # group before running anything) is the only thing that can make this non-zero.
    :
  } > "$REPORT" || { printf 'probe: FAILED to write report %s\n' "$REPORT" >&2; exit 1; }
  # …and corroborate the EFFECT rather than trust that status: a mid-write failure
  # (full disk) leaves a truncated file that the redirect status cannot see. The row
  # count must match what we classified, or the report is not usable as evidence.
  rows=$(grep -cv '^#' "$REPORT")
  want=$(( ${#WIRED[@]} + ${#UNWIRED[@]} + ${#UNPROBEABLE[@]} + ${#ALLOWED[@]} + ${#NOT_REACHED[@]} + ${#ALREADY_RED[@]} ))
  if (( rows != want )); then
    printf 'probe: report %s has %d rows, classified %d — refusing to emit a partial report\n' "$REPORT" "$rows" "$want" >&2
    exit 1
  fi
  printf 'report written: %s (%d harness rows)\n' "$REPORT" "$rows"
fi
(( ${#UNWIRED[@]} == 0 && ${#UNPROBEABLE[@]} == 0 ))
