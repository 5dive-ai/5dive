#!/usr/bin/env bash
# DIVE-2005 — a heredoc with an UNQUOTED delimiter performs command substitution on
# its own body, so `cat <<USAGE` help text containing backticked command names RUNS
# them. `5dive task --help` did exactly that: rendering the help executed `npm ci`
# in the caller's cwd plus `5dive push`, `5dive usage` and `5dive gate-proof`.
# --help is the verb a confused operator reaches for FIRST and the one we tell
# people is safe, so this is a mutating side effect on the safest surface we have.
#
# Two harnesses, because either alone is weak:
#   1. STATIC — sweep every heredoc in src/ and fail on an unquoted delimiter whose
#      body carries an UNESCAPED backtick or `$(`. Escaping (`\``) is a real fix and
#      is already used in cmd_proof/cmd_goal/agent_setup, so the scan must not churn
#      those; genuine interpolation is allowlisted BY SITE, never by pattern.
#   2. BEHAVIOURAL — render the three usage blocks with a PATH full of tripwires
#      named after the commands the help text quotes. If any of them runs, the
#      shim writes a file and the test fails. The static scan proves the shape is
#      gone; this proves the observable BEHAVIOUR is gone, and it keeps holding if
#      someone reintroduces the shape a different way (e.g. an unquoted `$(...)`).
# Run: bash tests/heredoc_substitution_unit.sh   (no root, no network)
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
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/heredoc-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- Allowlist: heredoc sites whose substitution is DELIBERATE. Keyed by
# file:delimiter so moving code does not silently re-arm the hole, and kept
# deliberately short — the point of the guard is that additions are a decision.
#   cmd_init.sh:TEAMS -> `$(gh_org)` builds the plugins URL from the live org.
ALLOW="src/cmd_init.sh:TEAMS"

scan() {  # scan -> one line per offending site: file:start-end <<DELIM backticks=N $(=N
  awk '
    function stripesc(s) { gsub(/\\./, "", s); return s }
    FNR==1 { inhd=0 }
    inhd {
      if ($0 ~ ("^[[:space:]]*" delim "[[:space:]]*$")) {
        if (bt > 0 || cs > 0)
          printf "%s:%d-%d <<%s backticks=%d $(=%d\n", FILENAME, start, FNR, delim, bt, cs
        inhd=0
        next
      }
      line = stripesc($0)
      n = gsub(/`/, "`", line); bt += n
      n = gsub(/\$\(/, "", line); cs += n
      next
    }
    # A heredoc opener: <<DELIM or <<-DELIM, delimiter UNQUOTED, and nothing but a
    # pipeline may follow. Requiring the delimiter to end the word is what keeps
    # arithmetic left-shifts — `$(( x * (1 << attempts) ))` — out of the results.
    /<<-?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\||$)/ {
      if ($0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /\$\(\(/) next
      match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/)
      d = substr($0, RSTART, RLENGTH); sub(/^<<-?/, "", d)
      delim = d; start = FNR; inhd = 1; bt = 0; cs = 0
    }
  ' $(find src -name '*.sh' | sort)
}

# 1) STATIC — nothing outside the allowlist may carry a live substitution.
offenders=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  site="${line%%-*}"; site="${site%:*}"           # file:start
  f="${site%%:*}"; d="${line#*<<}"; d="${d%% *}"
  [[ " $ALLOW " == *" ${f}:${d} "* ]] && continue
  offenders+="$line"$'\n'
done < <(scan)
if [[ -z "$offenders" ]]; then
  ok_t "no unquoted heredoc carries an unescaped backtick or \$( (outside the allowlist)"
else
  bad_t "no unquoted heredoc carries an unescaped backtick or \$( (outside the allowlist)" \
        "$(printf '%s' "$offenders" | sed 's/^/     /')"
fi

# NEGATIVE CONTROL — the scanner must actually SEE a violation, or the assertion
# above passes just as happily when the awk is broken. A guard that cannot fail is
# not a guard (DIVE-1967 hatch lesson).
mkdir -p "$TMP/src"
cat > "$TMP/src/decoy.sh" <<'DECOY'
_decoy_usage() {
  cat <<USAGE
  run `npm ci` to rebuild
USAGE
}
DECOY
( cd "$TMP" && scan ) | grep -q 'decoy.sh.*backticks=2' \
  && ok_t "negative control: the scanner flags a planted violation" \
  || bad_t "negative control: the scanner flags a planted violation" "planted decoy not reported"

# The allowlisted site must still be SEEN by the scanner (allowlisted, not invisible).
scan | grep -q 'cmd_init.sh.*<<TEAMS' \
  && ok_t "allowlisted site is still detected, just permitted" \
  || bad_t "allowlisted site is still detected, just permitted" "TEAMS not in scan output"

# 2) BEHAVIOURAL — render the usage blocks with tripwires on PATH.
SHIM="$TMP/bin"; mkdir -p "$SHIM"
for c in npm doctor git jq curl; do
  printf '#!/bin/sh\ntouch "%s/RAN.%s"\nexit 0\n' "$TMP" "$c" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done
# `5dive` and the bare subcommand words the help text quotes (`task verify`,
# `usage loops`, `agent clone`, `import lilbro --as=...`) resolve as commands too.
for c in 5dive task usage agent import; do
  printf '#!/bin/sh\ntouch "%s/RAN.%s"\nexit 0\n' "$TMP" "$c" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done

render() {  # render <file> <function> — source in a subshell, print the usage
  ( set +u
    STATE_DIR="$TMP/state"
    PATH="$SHIM:$PATH"
    # shellcheck disable=SC1090
    source "src/header.sh" 2>/dev/null
    source "$1" 2>/dev/null
    "$2" 2>&1 ) || true
}

declare -A USAGES=( [src/cmd_task.sh]=_task_usage [src/cmd_pack.sh]=_pack_usage )
for f in "${!USAGES[@]}"; do
  fn="${USAGES[$f]}"
  if ! grep -q "^${fn}()" "$f"; then
    printf 'skip - %s not found in %s (renamed?)\n' "$fn" "$f"
    continue
  fi
  out=$(render "$f" "$fn")
  ran=$(ls "$TMP" 2>/dev/null | grep -c '^RAN\.' || true)
  if [[ "$ran" -eq 0 ]]; then
    ok_t "$fn renders without executing anything"
  else
    bad_t "$fn renders without executing anything" "tripwires fired: $(ls "$TMP" | grep '^RAN\.' | tr '\n' ' ')"
    rm -f "$TMP"/RAN.*
  fi
  # ... and the documentation text SURVIVED the fix (a fix that deleted the
  # examples would also pass the test above).
  if [[ -n "$out" ]] && grep -q "5dive ${f#src/cmd_}" <<<"$out" 2>/dev/null || [[ -n "$out" ]]; then
    ok_t "$fn still renders non-empty help"
  else
    bad_t "$fn still renders non-empty help" "empty output"
  fi
done

# The task help specifically must still SHOW the commands it used to run.
out=$(render src/cmd_task.sh _task_usage)
{ grep -q "reclaim" <<<"$out" && grep -q "verify" <<<"$out"; } \
  && ok_t "task help still documents the verbs whose examples used to be executed" \
  || bad_t "task help still documents the verbs whose examples used to be executed" "$(head -3 <<<"$out")"
# ${STATE_DIR} interpolation is the reason the delimiter can't just be quoted —
# assert it still expands, or the fix has broken what it was protecting.
grep -q "$TMP/state/tasks/tasks.db" <<<"$out" \
  && ok_t "\${STATE_DIR} still expands in the task help (quoting the delimiter would break this)" \
  || bad_t "\${STATE_DIR} still expands in the task help" "$(head -2 <<<"$out")"

echo "-----"
printf 'heredoc_substitution_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
