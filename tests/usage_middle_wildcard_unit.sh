#!/usr/bin/env bash
# DIVE-3419 unit: the MIDDLE wildcard of `projects/*/*.jsonl` in BOTH transcript
# readers in cmd_usage.sh — `usage_collect` (guarded top and bottom, unguarded in
# the middle) and `activity_collect` (unguarded at every level).
#
# The defect: glob.glob() performs the middle directory listing itself and
# SWALLOWS every OSError, yielding nothing for the entry. So a project subdir
# this uid cannot read left the agent in the READABLE set with a total that is a
# FRACTION of the truth and `coverage.complete` still true — every "⚠ NOT checked
# — burn is unknown (not 0)" surface built on that flag stayed quiet.
#
# WHY THE ARMS ARE BUILT THIS WAY (DIVE-3345/3417 rules, applied):
#  * ANCHOR FIRST. A healthy arm asserting a specific NON-ZERO total, on the same
#    code path. Every refusal arm below is VACUOUS while the anchor is red: a
#    zero from an empty fixture is indistinguishable from a zero from a clean
#    check, which is the bug being fixed.
#  * PAIRED SICK/HEALED. Each sick fixture is re-run healed, and the heal arm
#    must recompute the real non-zero total THROUGH THE SAME CODE — proving the
#    sick arm reported blindness and not emptiness.
#  * ANY-UID ARM. EACCES is only expressible unprivileged, so a uid-0 CI run
#    would skip the point. ENOTDIR does not work at THIS level (it is a
#    legitimate skip here), so the any-uid vehicle is ELOOP: a self-referential
#    symlink where a project dir belongs, which root cannot resolve either.
#  * OVER-FIRE CONTROLS. A fix that flags idle agents disables coverage exactly
#    as thoroughly as the fail-open did. Legitimate-zero arms are not padding.
#
#   bash tests/usage_middle_wildcard_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/usage-midwild.XXXXXX)"

# Extract each collector's python. usage_collect is the FIRST heredoc in the
# file; activity_collect's is taken from inside its own function body, because
# grabbing "the first PY block" would silently grade the wrong subject.
awk "/python3 - <<'PY'/{f=1;next} f&&/^PY\$/{exit} f" src/cmd_usage.sh > "$TMP/collect.py"
awk '/^activity_collect\(\) \{/{g=1} g&&/python3 - <<.PY./{f=1;next} f&&/^PY$/{exit} f' \
  src/cmd_usage.sh > "$TMP/activity.py"
[[ -s "$TMP/collect.py"  ]] || { echo "FAIL - could not extract usage_collect python";  exit 1; }
[[ -s "$TMP/activity.py" ]] || { echo "FAIL - could not extract activity_collect python"; exit 1; }
grep -q 'A_AGENT' "$TMP/activity.py" || { echo "FAIL - extracted the wrong python for activity_collect"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

NOW="$(date +%s)"; TS="$(date -u -d @"$NOW" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"agents":{"alpha":{"type":"claude"}}}' > "$TMP/reg.json"

# one project subdir worth exactly 30000 total tokens (in+out+cache-write), and
# one Bash tool_use so the activity trail has something to be short OF.
mk_proj() { # mk_proj <home> <projname> [<sessionfilename>]
  local d="$1/.claude/projects/$2"; mkdir -p "$d"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$TS\",\"message\":{\"model\":\"m\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"echo $2\",\"description\":\"d\"}}],\"usage\":{\"input_tokens\":20000,\"output_tokens\":10000}}}" \
    > "$d/${3:-session.jsonl}"
}
collect()  { REGISTRY="$TMP/reg.json" TASK_DB="$TMP/none.db" USAGE_SINCE="$((NOW-3600))" \
             USAGE_HOME_ROOT="$1" python3 "$TMP/collect.py" 2>/dev/null; }
activity() { A_AGENT=alpha A_SINCE="$((NOW-3600))" A_TSTART=- A_TEND=- A_HOME_ROOT="$1" \
             python3 "$TMP/activity.py" 2>"$TMP/act.err"; }

# ============ ANCHOR — two readable project dirs, 60000, complete. ============
A="$TMP/anchor"; H="$A/agent-alpha"; mk_proj "$H" p1; mk_proj "$H" p2
OA="$(collect "$A")"
[[ "$(jq -r '[.agents[].total]|add' <<<"$OA")" == "60000" ]] \
  && ok_t "ANCHOR usage_collect sums BOTH project dirs (60000) — refusal arms below are vacuous while this is red" \
  || bad_t "ANCHOR usage total" "$(jq -c '.agents' <<<"$OA")"
[[ "$(jq -r '.coverage.complete' <<<"$OA")" == "true" ]] \
  && ok_t "ANCHOR a fully readable agent is coverage.complete=true" || bad_t "ANCHOR complete" "$(jq -c .coverage <<<"$OA")"
AA="$(activity "$A")"
[[ "$(jq -r '.tokens.total' <<<"$AA")" == "60000" && "$(jq -r '.counts.bash' <<<"$AA")" == "2" ]] \
  && ok_t "ANCHOR activity_collect sees both dirs (60000 tok, 2 commands)" || bad_t "ANCHOR activity" "$AA"
[[ "$(jq -r '(.partial//[])|length' <<<"$AA")" == "0" ]] \
  && ok_t "ANCHOR a complete activity trail carries an EMPTY partial list" || bad_t "ANCHOR partial" "$AA"

# ==== CORE (EACCES) — one of two project dirs chmod 000. Unprivileged only. ====
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'skip - EACCES arms not runnable as root (the ELOOP arms below cover any uid) — NOT faked\n'
else
  E="$TMP/eacces"; H="$E/agent-alpha"; mk_proj "$H" p1; mk_proj "$H" p2
  chmod 000 "$H/.claude/projects/p2"
  OE="$(collect "$E")"
  [[ "$(jq -r '.coverage.complete' <<<"$OE")" == "false" ]] \
    && ok_t "EACCES an unreadable project SUBDIR makes coverage INCOMPLETE (was: true, with a half total)" \
    || bad_t "EACCES complete" "$(jq -c .coverage <<<"$OE")"
  [[ "$(jq -r '.coverage.unreadable[0].name' <<<"$OE")" == "alpha" ]] \
    && ok_t "EACCES the agent is NAMED in coverage.unreadable, not left in the READABLE set" \
    || bad_t "EACCES named" "$(jq -c .coverage <<<"$OE")"
  [[ "$(jq -r '.coverage.unreadable[0].reason' <<<"$OE")" == *"p2"* ]] \
    && ok_t "EACCES the reason names the exact subdir that could not be read" \
    || bad_t "EACCES reason" "$(jq -c .coverage <<<"$OE")"
  [[ "$(jq -r '[.agents[].total]|add // 0' <<<"$OE")" != "30000" ]] \
    && ok_t "EACCES no agent row carries the 30000 HALF-TOTAL as if it were a measurement" \
    || bad_t "EACCES half total still emitted as complete" "$(jq -c '.agents' <<<"$OE")"
  AE="$(activity "$E")"
  [[ "$(jq -r '(.partial//[])|length' <<<"$AE")" -ge 1 && "$(jq -r '(.partial//[])|join(" ")' <<<"$AE")" == *"p2"* ]] \
    && ok_t "EACCES activity_collect NAMES the unread level in .partial (was: bare continue)" \
    || bad_t "EACCES activity partial" "$AE"
  [[ "$(jq -r '.counts.bash' <<<"$AE")" == "1" ]] \
    && ok_t "EACCES the activity trail is still RENDERED (1 cmd) — reported short, not refused" \
    || bad_t "EACCES activity trail" "$AE"
  # --- HEALED: same fixture, permission restored, through the same code. ---
  chmod 755 "$H/.claude/projects/p2"
  OH="$(collect "$E")"; AH="$(activity "$E")"
  [[ "$(jq -r '[.agents[].total]|add' <<<"$OH")" == "60000" && "$(jq -r '.coverage.complete' <<<"$OH")" == "true" ]] \
    && ok_t "HEALED the same fixture recomputes the full 60000 and complete=true (so the sick arm read blindness, not emptiness)" \
    || bad_t "HEALED usage" "$(jq -c '{c:.coverage.complete,t:[.agents[].total]}' <<<"$OH")"
  [[ "$(jq -r '(.partial//[])|length' <<<"$AH")" == "0" && "$(jq -r '.tokens.total' <<<"$AH")" == "60000" ]] \
    && ok_t "HEALED activity partial empties and the trail recomputes 60000" || bad_t "HEALED activity" "$AH"
fi

# ==== ANY-UID (ELOOP) — root can read every bit and still cannot resolve a
#      self-referential symlink. ENOTDIR is NOT usable at this level: a regular
#      file in projects/ is a legitimate skip here (see the over-fire arm below).
L="$TMP/eloop"; H="$L/agent-alpha"; mk_proj "$H" p1
ln -s p2 "$H/.claude/projects/p2"
OL="$(collect "$L")"
[[ "$(jq -r '.coverage.complete' <<<"$OL")" == "false" \
   && "$(jq -r '.coverage.unreadable[0].name' <<<"$OL")" == "alpha" ]] \
  && ok_t "ANY-UID a project dir that cannot be listed for a non-permission reason (ELOOP) is reported — a uid-0 run cannot be a vacuous green" \
  || bad_t "ANY-UID eloop" "$(jq -c .coverage <<<"$OL")"
AL="$(activity "$L")"
[[ "$(jq -r '(.partial//[])|join(" ")' <<<"$AL")" == *"p2"* ]] \
  && ok_t "ANY-UID activity_collect names the ELOOP level too" || bad_t "ANY-UID activity" "$AL"
rm -f "$H/.claude/projects/p2"
OLH="$(collect "$L")"
[[ "$(jq -r '.coverage.complete' <<<"$OLH")" == "true" && "$(jq -r '[.agents[].total]|add' <<<"$OLH")" == "30000" ]] \
  && ok_t "ANY-UID HEALED removing the loop restores complete=true and a real 30000" || bad_t "ANY-UID healed" "$OLH"

# ==== OVER-FIRE CONTROLS — the legitimate zeros. A fix that flags these has
#      disabled coverage in the other direction and will look green in every arm above.
Z="$TMP/idle"; mkdir -p "$Z/agent-alpha"          # home exists, never ran: ENOENT on projects/
OZ="$(collect "$Z")"
[[ "$(jq -r '.coverage.complete' <<<"$OZ")" == "true" ]] \
  && ok_t "OVER-FIRE an agent that has never run stays READ (ENOENT on projects/ is idle, not blind)" \
  || bad_t "OVER-FIRE idle slandered" "$(jq -c .coverage <<<"$OZ")"
[[ "$(jq -r '(.partial//[])|length' <<<"$(activity "$Z")")" == "0" ]] \
  && ok_t "OVER-FIRE an idle agent's activity trail is empty, NOT partial" || bad_t "OVER-FIRE idle activity" "$(activity "$Z")"
N="$TMP/notdir"; H="$N/agent-alpha"; mk_proj "$H" p1
printf 'stray' > "$H/.claude/projects/README"     # a regular FILE in projects/: ENOTDIR
ON="$(collect "$N")"
[[ "$(jq -r '.coverage.complete' <<<"$ON")" == "true" && "$(jq -r '[.agents[].total]|add' <<<"$ON")" == "30000" ]] \
  && ok_t "OVER-FIRE a regular file in projects/ (ENOTDIR) is a real skip — it cannot hold <it>/*.jsonl" \
  || bad_t "OVER-FIRE notdir" "$(jq -c '{c:.coverage.complete,t:[.agents[].total]}' <<<"$ON")"
[[ "$(jq -r '(.partial//[])|length' <<<"$(activity "$N")")" == "0" ]] \
  && ok_t "OVER-FIRE activity_collect does not flag the ENOTDIR skip either" || bad_t "OVER-FIRE notdir activity" "$(activity "$N")"

# ==== WIDENING — glob hid dot-prefixed names at BOTH levels; listdir does not. ====
D="$TMP/dot"; H="$D/agent-alpha"; mk_proj "$H" p1; mk_proj "$H" .hidden ".s.jsonl"
OD="$(collect "$D")"
[[ "$(jq -r '[.agents[].total]|add' <<<"$OD")" == "60000" ]] \
  && ok_t "WIDENING a dot-prefixed project dir AND a dot-prefixed session file are counted (glob hid both)" \
  || bad_t "WIDENING dotfiles" "$(jq -c '.agents' <<<"$OD")"
[[ "$(jq -r '.tokens.total' <<<"$(activity "$D")")" == "60000" ]] \
  && ok_t "WIDENING activity_collect counts them too" || bad_t "WIDENING activity dotfiles" "$(activity "$D")"

# ==== ACCEPTANCE 4 — the GUESSED /home/agent-<name> fallback is gone. =========
# Without A_HOME_ROOT and with no such account, the old code invented a path,
# read nothing, and rendered "did nothing". It must now refuse and say why.
if A_AGENT="nosuchagent-dive3419" A_SINCE=0 A_TSTART=- A_TEND=- python3 "$TMP/activity.py" >"$TMP/g.out" 2>"$TMP/g.err"; then
  bad_t "GUESSED-HOME an unresolvable agent must NOT return a clean empty trail" "$(cat "$TMP/g.out")"
else
  [[ ! -s "$TMP/g.out" ]] && grep -qi "unresolvable" "$TMP/g.err" \
    && ok_t "GUESSED-HOME an agent with no account on this host: non-zero rc, EMPTY stdout, named cause on stderr" \
    || bad_t "GUESSED-HOME all three halves" "out=$(cat "$TMP/g.out") err=$(cat "$TMP/g.err")"
fi
grep -q '"/home/agent-" + agent' "$TMP/activity.py" \
  && bad_t "GUESSED-HOME the literal /home/agent-<name> guess is still in activity_collect" \
  || ok_t "GUESSED-HOME the literal guessed-path fallback is absent from the source"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
