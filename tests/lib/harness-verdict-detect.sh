#!/usr/bin/env bash
# DIVE-3679: ONE verdict detector, sourced by BOTH callers.
#
# `tests/meta/harness-verdict-probe.sh` (empirical, DIVE-2013) and
# `tests/meta/harness-verdict-toplevel.sh` (static, this row) must agree on WHICH
# line is the harness's verdict, because the static guard's whole claim is about the
# line the probe would mutate. Two copies of the detector are two detectors as soon
# as one of them is edited — the same argument .github/scripts/simulate-installed-
# host.sh carries for the installed-host seeding. So `counter_verdict` moved here
# verbatim (comments and all) and the probe now sources this file; extracting it
# without rewiring the original caller would have armed nothing.
#
# Lives in tests/lib/, which `tests/*.sh` does not glob and which the
# `changed-harnesses` diff filter explicitly excludes — so this is a library, not a
# harness, and it is never probed as one.

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

# DIVE-3679: the STATIC half — is the probe's INJECTION POINT at top level?
#
# WHICH INSTRUMENT THIS IS, because the row asks explicitly and "leading indentation
# is a proxy, not a parse": this is A REAL PARSE, PERFORMED BY BASH ITSELF. Neither
# indentation nor a hand-rolled lexer.
#
# THE CLAIM, spelled exactly. harness-verdict-probe.sh inserts its canary and its
# mutation immediately BEFORE the terminal verdict-shaped line (`awk NR==n{...}`), so
# what has to be true is not a property of that line's whitespace but of the position
# ahead of it: lines 1..n-1 must be a COMPLETE bash program. If they are, the
# injection lands at a top-level statement boundary and executes in every environment
# the harness runs in. If they are not, the injection lands inside an unclosed
# construct — an arm no CI runner enters (DIVE-3675), or mid-way through a `\`
# continuation, where the inserted lines break the statement outright.
#
# So: `head -n $((n-1)) file | bash -n`. Bash's own grammar answers the question, and
# "syntax error: unexpected end of file" IS the finding. A prefix of a file that
# already parses cannot fail for any other reason.
#
# WHY NOT THE HAND-ROLLED VERSION. It was written first — an awk keyword-balance
# scanner over if/case/while/until/for/select/{ with quote and heredoc state — and
# measured against this parse on all 444 harnesses on origin/main. It cost three
# rounds of false accusations (19, then 48, then 6: a `\` continuation swallowing its
# own `done`, a whole-line skip losing the `}` that followed a closing quote, and a
# `<<'TAG'` written inside a quoted string wedging the heredoc state forever). Every
# one of those was an ACCUSATION against a correctly-wired harness, which is the
# failure mode DIVE-2039 exists to prevent and the reason DIVE-3678's guard was
# rejected. Bash's parser has none of them by construction. The lesson generalises:
# a guard whose instrument is a re-implementation of a parser the platform already
# ships is a guard whose false-positive rate is its author's bug count.
#
# NOT A SUBSTITUTE FOR THE PROBE. harness-verdict-probe.sh's own header records that
# static analysis cannot close the DIVE-2013 class — three instruments measured, all
# agreeing, none sound; none can see a harness whose assertions never fire, a verdict
# placed before the last assertion, or a `set -e` verdict bypassed. "The injection
# point is at top level" is a STRICTLY NARROWER claim than "the verdict is wired", so
# it does not inherit that refutation — and it must never be cited as doing the
# probe's job.
#
# verdict_injection_point_top_level <file> <lineno>
#   exit 0 = top level; exit 1 = not, with bash's own complaint on stdout.
verdict_injection_point_top_level() {
  local f="$1" n="$2" pfx err
  # A verdict on line 1 has an empty prefix, which is trivially complete.
  (( n <= 1 )) && return 0
  pfx=$(mktemp) || return 2
  err=$(mktemp) || { rm -f "$pfx"; return 2; }
  head -n $(( n - 1 )) "$f" > "$pfx"
  if bash -n "$pfx" 2>"$err"; then rm -f "$pfx" "$err"; return 0; fi
  # Re-point bash's line numbers at the real file: the prefix has the same numbering,
  # only a different name, so only the path is rewritten.
  sed -e "s#$pfx#$f#g" "$err" | tail -2
  rm -f "$pfx" "$err"
  return 1
}
