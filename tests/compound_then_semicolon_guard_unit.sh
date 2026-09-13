#!/usr/bin/env bash
# DIVE-4430 — `(( ))` / `[[ ]]` followed by `then`/`do` with no `;` between them.
#
# WHAT THIS COSTS WHEN IT IS MISSING, measured on this row. Two iterations of a
# maker→verifier loop, four CI rounds and two people's desk sessions were spent on
# three verbs that answered `--help` with rc 2 inside the install-contract
# container and rc 0 for everyone who tried to reproduce it. The whole difference
# was one line:
#
#     elif (( n >= 1000000 ))    then printf ...
#
# bash 5.2 (this host, and every dev box here) PARSES that. bash 5.1.16 — which is
# what ubuntu:22.04 ships, which is what install.sh installs onto, which is what
# the contract grades — does not:
#
#     syntax error near unexpected token `then'
#
# The bundle carries its command modules as unparsed trailing text (DIVE-4087) and
# evals one on first call, so the error surfaces at RUNTIME on a container, in
# exactly the three verbs whose module happened to contain it, and nowhere else.
# `bash -n` on the dev host is clean. shellcheck says nothing (checked: it emits no
# diagnostic at all for this form). The eager-bundle era would have caught it at
# startup; lazy dispatch is what turned it into a per-verb runtime fault.
#
# So the guard is textual and it is cheap, and it runs where the parser cannot: on
# every developer's 5.2 host, in every pristine lane, with no container and no
# second bash to fetch. It is a lint for ONE shape, not a bash-version matrix —
# that shape is the one that cost the week.
#
# NOT A SUBSTITUTE for install-contract T4, which is the check that actually found
# this and which now prints the stderr behind a non-zero rc (same PR). This is the
# fast arm; that one is the honest one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cts.XXXXXX") || exit 2
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

# The one shape. A compound command that CLOSES on its own line (`))` or `]]`),
# then whitespace, then a reserved word that needs a command terminator in front
# of it.
#
# THE FALSE POSITIVE THIS HAS TO SURVIVE, and it is not hypothetical — it fired
# on three lines the first time this ran. `jq` has its own `if/then/elif` and its
# own parentheses, and src/ embeds jq programs inside quotes and heredocs:
#
#     elif (($h.failure != null) and ($h.bound != true)) then      # cmd_agent.sh
#     elif ($h5 != null and (($h5.pct // -1) >= $wall)) then       # quota_wall.sh
#
# Both are correct jq and neither is shell. A line-oriented scanner cannot know
# it is inside a quoted program, so it discriminates on the SPAN instead: what
# sits between the opener and the closer must be spellable as bash ARITHMETIC.
# Bash arithmetic has no `.` operator and no string literals, so a span carrying
# `.`, a quote or a `#` is not a `(( ))` command whatever it looks like — while
# every real instance of the defect (`n >= 1000000`) passes that filter trivially.
# Arms 5 and 6 grade both halves of this against the real lines.
scan() {
  awk '
    {
      line = $0
      sub(/#.*$/, "", line)                       # a comment cannot be a command
      if (line !~ /(\)\)|\]\]) +(then|do)([ \t]|$)/) next
      # the span between the outermost opener and the closer that precedes then/do
      if (match(line, /(\(\(|\[\[)/) == 0) next
      # `open`/`close` are awk BUILT-IN function names; a local named for one is
      # a syntax error, and with awk stderr suppressed that read as "no matches".
      op = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      cl = (op == "((") ? "))" : "]]"
      i = index(rest, cl)
      if (i == 0) next
      span = substr(rest, 1, i - 1)
      # bash arithmetic: identifiers, numbers, $, operators, nested parens.
      # Anything else (a field access, a quote, a jq filter) is not arithmetic.
      if (span ~ /[."'"'"'`#]/) next
      printf "%s:%d: %s\n", FILENAME, FNR, $0
    }
  ' "$@"
}

# ---------------------------------------------------------------------------
# ARM 1 — IT FIRES. The exact line that shipped, byte for byte.
# ---------------------------------------------------------------------------
# THE FIXTURES ARE COMPOSED, NOT WRITTEN OUT, and that is not a style choice.
# Arm 4 below scans `tests/*.sh` — which includes THIS FILE — so a violating
# fixture spelled literally inside a heredoc here is a hit on the product scan,
# and the guard reds itself the moment it is committed (untracked, `git ls-files`
# does not list it, so it passes at the desk and fails in the rail: the worst
# possible ordering). A guard whose own corpus contains its own negative fixtures
# has to build them, so the reserved word is substituted in at write time and the
# shape never exists as a line in this file.
TH='then'; DO='do'   # quoted: bare words here are SC1010, in the guard that is about them
{ printf '#!/usr/bin/env bash\n_hb_tok_scale() {\n  local n="${1:-}"\n'
  printf '  if   (( n >= 1000000000 )); %s printf \x27%%sB\x27 "$(( n / 1000000000 ))"\n' "$TH"
  printf '  elif (( n >= 1000000 ))    %s printf \x27%%sM\x27 "$(( n / 1000000 ))"\n' "$TH"
  printf '  else printf \x27%%s\x27 "$n"; fi\n}\n'
} > "$TMP/violating.sh"
if out=$(scan "$TMP/violating.sh") && [[ -n "$out" ]]; then
  ok "the shipped form is caught: $(printf '%s' "$out" | head -1 | cut -c1-70)"
else
  bad "the shipped form is caught" "the scanner found nothing in the line that caused this row"
fi

# ...and it is a real parse error, not a style opinion. Graded against a bash that
# actually rejects it if one is reachable; otherwise this arm says so out loud
# rather than reporting clean. (On a 5.2 host `bash -n` ACCEPTS it — which is the
# reason this harness is textual.)
if command -v bash >/dev/null && ! bash -n "$TMP/violating.sh" 2>/dev/null; then
  ok "this host's bash also rejects it outright (${BASH_VERSION})"
else
  ok "this host's bash ${BASH_VERSION} PARSES it — which is why the textual guard exists"
fi

# ---------------------------------------------------------------------------
# ARM 2 — IT DOES NOT FALSE-ALARM on the correct spellings.
# ---------------------------------------------------------------------------
cat > "$TMP/clean.sh" <<'STUB'
#!/usr/bin/env bash
f() {
  local n=1
  if   (( n >= 10 )); then echo a
  elif (( n >= 5 ));  then echo b
  elif [[ "$n" == 3 ]]; then echo c
  fi
  while (( n > 0 )); do n=$(( n - 1 )); done
  if (( n >= 1 ))
  then echo d
  fi
  [[ "$n" == then ]] && echo "the word then in a comparison"
  echo "a string containing )) then and nothing else"
}
STUB
if out=$(scan "$TMP/clean.sh"); [[ -z "$out" ]]; then
  ok "correct spellings, a newline before then, and the bare word 'then' are all clean"
else
  bad "correct spellings are clean" "false positive: $out"
fi

# ---------------------------------------------------------------------------
# ARM 3 — the arithmetic-expansion shape that is NOT this defect.
# `$(( ))` closing mid-command must not be mistaken for a compound command.
# ---------------------------------------------------------------------------
cat > "$TMP/arith.sh" <<'STUB'
#!/usr/bin/env bash
g() {
  local n=4
  printf '%s' "$(( n * 2 ))"
  # a prose comment naming (( n )) then do, which the shell never parses
  case "$n" in 4) echo four ;; esac
}
STUB
if out=$(scan "$TMP/arith.sh"); [[ -z "$out" ]]; then
  ok "arithmetic expansion and comment prose do not trip the scanner"
else
  bad "arithmetic expansion and comment prose do not trip the scanner" "false positive: $out"
fi

# ---------------------------------------------------------------------------
# ARM 4 — THE PRODUCT. Every shipped shell source is clean.
# This is the arm that would have turned red on the delivered head.
# ---------------------------------------------------------------------------
# tests/ IS IN THE CORPUS ON PURPOSE — including this file. A guard that exempts
# itself is a guard nobody grades, and the harnesses ship on the box too.
mapfile -t SRCS < <(git ls-files 'src/*.sh' 'src/**/*.sh' 'scripts/*.sh' 'scripts/**/*.sh' 'tests/*.sh' 2>/dev/null)
if (( ${#SRCS[@]} < 20 )); then
  bad "the product scan enumerated its sources" "only ${#SRCS[@]} files — the enumeration went blind; fix it, do not lower the floor"
else
  ok "${#SRCS[@]} shell sources enumerated"
  if out=$(scan "${SRCS[@]}"); [[ -z "$out" ]]; then
    ok "no shipped source closes (( )) or [[ ]] straight onto then/do"
  else
    bad "no shipped source closes (( )) or [[ ]] straight onto then/do" \
        "these are a syntax error on bash 5.1 (ubuntu:22.04, what install.sh installs onto): $out"
  fi
fi

# ---------------------------------------------------------------------------
# ARM 5 — the jq false positives, PINNED. These two lines are correct jq inside a
# quoted program and the scanner must stay quiet on them. They are reproduced
# here rather than pointed at, so this arm keeps grading if the files move.
# ---------------------------------------------------------------------------
cat > "$TMP/jq.sh" <<'STUB'
#!/usr/bin/env bash
h() {
  jq -r '
    if (($h.failure != null) and ($h.bound != true)) then "a"
    elif ($h5 != null and (($h5.pct // -1) >= $wall)) then {w:"5h", u:$h5}
    else null end'
}
STUB
if out=$(scan "$TMP/jq.sh"); [[ -z "$out" ]]; then
  ok "jq's own if/then inside a quoted program is not mistaken for shell"
else
  bad "jq's own if/then inside a quoted program is not mistaken for shell" "false positive: $out"
fi

# ARM 6 — ...and the filter that buys that is not so wide it swallows the defect.
# The same jq-shaped line with an arithmetic span still fires.
{ printf '#!/usr/bin/env bash\nk() {\n  local n=1 m=2\n'
  printf '  if (( n >= 1 )); %s :; fi\n' "$TH"
  printf '  while (( (n + m) > 0 ))  %s n=$(( n - 1 )); done\n}\n' "$DO"
} > "$TMP/near.sh"
if out=$(scan "$TMP/near.sh") && [[ -n "$out" ]] && grep -q 'while' <<<"$out"; then
  ok "a nested-paren arithmetic span running straight onto 'do' still fires"
else
  bad "a nested-paren arithmetic span running straight onto 'do' still fires" "missed it: ${out:-<nothing>}"
fi

printf -- '-----\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
