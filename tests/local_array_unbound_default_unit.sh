#!/usr/bin/env bash
# DIVE-2104 (gh#211, A-MO7SEN): under `set -u`, a bare `local -a NAME` declares
# the array WITHOUT creating it. `${#NAME[@]}` on it is an unbound-variable
# crash; `"${NAME[@]}"` / `"${!NAME[@]}"` / `"${NAME[*]}"` all survive. So the
# landmine is specifically the LENGTH CHECK, which is why it survived review:
# the same function iterates the same array safely a few lines earlier.
#
# The reported live instance is `team-bot shared`. When zero agents relay (bot
# not yet admin, all agents already wired, …) `wired` is never appended to, and
# step 5's `[[ ${#wired[@]} -gt 0 ]]` crashes — DESTROYING the per-agent status
# report that carries the actual diagnosis. The reporter's words: "my second
# failure had a different cause, which I could not see — that is the real cost
# of this bug." That masking is what arm A grades, not the crash alone.
#
# WHAT THIS HARNESS CORRECTS IN THE TICKET, and it is the load-bearing part:
# the ticket's live-site test was "declared bare AND length-checked nearby",
# which is a GREP heuristic, and it is wrong. `mapfile` and `read -a` are
# ASSIGNMENT builtins: they create the array even on zero input lines
# (`declare -a m=()`). Only a CONDITIONAL population — `+=` inside a loop or
# after `&&` — can leave it uncreated. So the real predicate is:
#
#     bare declaration  AND  population is conditional  AND  a length check
#
# By that predicate exactly ONE of the ten sites is live (teambot `wired`), not
# two. cmd_compose.sh:249 `mgrs`/`reports` is mapfile-populated and CANNOT
# crash. Arm F grades that classification against the real source lines rather
# than asserting it in prose. The independent field proof needs no test at all:
# `_cron_matches` (lib/tasks_db.sh) has a bare `local -a cm` with `${#cm[@]}`
# on the VERY NEXT LINE and runs on every heartbeat tick without crashing.
#
# All ten sites still take `=()` — contract discipline, per DIVE-2076: an audit
# that strips the "unnecessary" ones reintroduces the class the moment somebody
# adds a length check.
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
SRC=src
TMP=$(mktemp -d /tmp/local-array-unbound.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
grade()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (want=$2 got=$3)"; fi; }

# ---------------------------------------------------------------------------
# Arm D — CONTROL PROBE. Everything below is meaningless if `set -u` is not
# actually biting on this bash, so measure the primitive itself first. If these
# ever flip, the rest of the harness is reading green for the wrong reason.
# ---------------------------------------------------------------------------
# Grade on the MESSAGE, never on rc: `[[ ${#w[@]} -gt 0 ]]` returns 1 both when
# the array is legitimately empty and when set -u kills it, so rc alone cannot
# tell "guard says empty" from "guard crashed" — an assertion whose expected
# value is also the failure mode's value can never fail.
# Capture stderr rather than piping it: this harness runs under `pipefail`, so
# `bash -c … | grep -q` takes the CRASHING bash's rc for the whole pipeline and
# inverts the probe — the control silently reporting "survives" on a tree where
# set -u is biting perfectly.
probe() { local d="$1" msg
  msg=$(bash -c "set -u; f(){ local -a $d; $2; }; f" 2>&1 >/dev/null)
  [[ "$msg" == *"unbound variable"* ]] && echo crash || echo survives; }
grade "control: \${#w[@]} on a bare 'local -a' CRASHES"      crash    "$(probe w '[[ ${#w[@]} -gt 0 ]]')"
grade "control: \"\${w[@]}\" on the same array SURVIVES"     survives "$(probe w 'for x in "${w[@]}"; do :; done')"
grade "control: \"\${!w[@]}\" survives"                      survives "$(probe w 'echo "${!w[@]}" >/dev/null')"
grade "control: 'local -a w=()' makes the length check safe" survives "$(probe 'w=()' '[[ ${#w[@]} -gt 0 ]]')"

# ---------------------------------------------------------------------------
# Arms A/B/C — BEHAVIOURAL, against the REAL _team_bot_do_shared.
#
# The function writes to hardcoded /etc/5dive paths, so it is copied to $TMP
# with that ONE literal repointed. Nothing else is rewritten, and the copy's
# declaration + population + length-check lines are asserted byte-identical to
# src/ below, so the thing under test is provably production code and not a
# reimplementation of it. The mutation (arm B) is applied to this same copy —
# i.e. to the file the test SOURCES, never to the built bundle, which would be
# inert and read as a clean pass.
# ---------------------------------------------------------------------------
TBSRC="$SRC/cmd_agent_teambot.sh"
TBCOPY="$TMP/cmd_agent_teambot.sh"
ETCDIR="$TMP/etc5dive"
n_repointed=$(grep -c '/etc/5dive' "$TBSRC")
python3 - "$TBSRC" "$TBCOPY" "$ETCDIR" <<'PY'
import sys
src, dst, etc = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(src).read()
open(dst, "w").write(t.replace("/etc/5dive", etc))
PY
# assert the instrumentation APPLIED — a silently no-op rewrite would let the
# function write to the real /etc/5dive, or fail, and either way mis-grade.
grade "harness: /etc/5dive repointed in the copy (>=4 sites)" \
      "yes" "$([[ $n_repointed -ge 4 && $(grep -c "$ETCDIR" "$TBCOPY") -eq $n_repointed ]] && echo yes || echo no)"
grade "harness: no /etc/5dive literal survives the repoint" \
      0 "$(grep -c '/etc/5dive' "$TBCOPY" || true)"

# Bind the graded lines to source: if upstream moves/renames them, this reds
# rather than silently testing a line that no longer matters.
decl_src=$(grep -n 'local -a wired' "$TBSRC" | head -1)
len_src=$(grep -n '${#wired\[@\]}' "$TBSRC"  | head -1)
grade "bound to source: 'local -a wired=()' is the shipped declaration" \
      "yes" "$([[ "$decl_src" == *'local -a wired=()'* ]] && echo yes || echo no)"
grade "bound to source: the length check on wired still exists" \
      "yes" "$([[ -n "$len_src" ]] && echo yes || echo no)"
grade "bound to source: copy carries the identical declaration" \
      "yes" "$(grep -q 'local -a wired=()' "$TBCOPY" && echo yes || echo no)"

# PATH shims for the boundaries. python3 stands in for the relay block; its
# stdout IS a stubbed boundary format, so arm C pins that format against what
# the real block emits (json.dumps of dicts carrying "agent" and "status").
mkdir -p "$TMP/bin" "$ETCDIR"
cat > "$TMP/bin/python3" <<'SH'
#!/usr/bin/env bash
cat >/dev/null                                  # swallow the heredoc
printf '%s' "${REG_UPDATES_STUB:-{\}}" > "${REG_UPDATES_FILE:-/dev/null}"
printf '%s' "$RELAY_RESULTS"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/chown"
chmod +x "$TMP/bin/python3" "$TMP/bin/systemctl" "$TMP/bin/chown"

REG_JSON='{"agents":{"alpha":{"type":"claude"},"beta":{"type":"claude"}}}'

# run_shared <relay-results-json> -> "<rc>|<stdout>" with stderr folded in
run_shared() {
  local results="$1" mutate="${2:-none}" file="$TBCOPY"
  if [[ "$mutate" == "revert" ]]; then
    file="$TMP/mutated.sh"
    sed 's/local -a wired=()/local -a wired/' "$TBCOPY" > "$file"
    # a mutation that did not apply is a false GREEN, so prove it applied
    if ! grep -q 'local -a wired$' "$file"; then
      printf 'MUTATION-DID-NOT-APPLY' > "$TMP/out.txt"; : > "$TMP/err.txt"
      printf '0'; return
    fi
  fi
  # stdout and stderr are kept SEPARATE: the JSON envelope is stdout, and
  # folding warn/step chatter into it would break `jq -e` and mis-grade a
  # working path as a failure.
  local out rc
  out=$(
    PATH="$TMP/bin:$PATH" RELAY_RESULTS="$results" \
    bash -c '
      set -uo pipefail
      cd "'"$PWD"'"
      for f in header.sh lib/error_codes.sh lib/output.sh lib/tg_access.sh; do
        [[ -f "src/$f" ]] && source "src/$f"
      done
      source "'"$file"'"
      set +e
      JSON_MODE=1
      # header.sh binds ENV_DIR to the real /var/lib/5dive/agents.d. Nothing is
      # written there (write_agent_env is stubbed) but the one-relayed arm READS
      # it, so re-point it at $TMP: CI probes this harness in both a pristine and
      # an installed environment, and a grade must not depend on which.
      STATE_DIR="'"$TMP"'/state"; ENV_DIR="$STATE_DIR/agents.d"; mkdir -p "$ENV_DIR"
      registry_read()             { printf "%s" '"'$REG_JSON'"'; }
      _team_bot_relay_agent_list(){ printf "alpha\nbeta\n"; }
      _tg_access_state_dir()      { printf "%s/state/%s" "'"$TMP"'" "$1"; }
      with_registry_lock()        { "$@"; }
      _team_bot_persist_shared()  { :; }
      _team_bot_install_listener(){ echo "LISTENER-INSTALLED" >&2; }
      install_channel_for_agent() { :; }
      _team_bot_write_sendonly_env() { :; }
      write_agent_env()           { :; }
      channel_in_list()           { return 1; }
      step() { :; }
      set -u
      _team_bot_do_shared "-1001234567890" "" "alpha,beta" "123456:AAaa_bb-cc"
    ' 2>"$TMP/err.txt"
  ); rc=$?
  printf '%s' "$out" > "$TMP/out.txt"
  printf '%s' "$rc"
}
OUT() { cat "$TMP/out.txt"; }   # stdout: the JSON envelope
ERR() { cat "$TMP/err.txt"; }   # stderr: chatter + the crash message
has() { [[ "$(OUT)$(ERR)" == *"$1"* ]] && echo yes || echo no; }

# The zero-relay case as it actually occurs in the field: the relay block DID
# run and DID produce a per-agent diagnosis — none of them reached "relayed".
# This is the shape that masks the cause, not an empty array.
ZERO='[{"agent":"alpha","status":"error","error":"bot is not an administrator of the group"},{"agent":"beta","status":"skipped","error":"already wired to another bot"}]'
ONE='[{"agent":"alpha","status":"relayed","threadId":7},{"agent":"beta","status":"error","error":"bot is not an administrator of the group"}]'

# --- Arm A: FIXED tree, zero relayed -> reports instead of crashing ---------
rc=$(run_shared "$ZERO")
grade "A: zero-relay path exits 0 (no unbound-variable crash)" 0 "$rc"
grade "A: 'wired: unbound variable' is GONE"                   no "$(has 'wired: unbound variable')"
# the point of the fix is the DIAGNOSIS surviving, so grade the diagnosis
grade "A: per-agent status is reported for alpha" \
      "yes" "$(OUT | jq -e '.data.relay[]|select(.agent=="alpha")|select(.status=="error")' >/dev/null 2>&1 && echo yes || echo no)"
grade "A: the masked CAUSE reaches the operator (admin error text)" \
      "yes" "$(has 'not an administrator')"
grade "A: reports 0/2 relayed rather than claiming success" \
      "yes" "$(OUT | jq -e '[.data.relay[]|select(.status=="relayed")]|length==0' >/dev/null 2>&1 && echo yes || echo no)"
grade "A: listener NOT installed when nothing relayed" no "$(has 'LISTENER-INSTALLED')"

# --- Arm B: MUTATION — revert this one `=()` and require the bug back -------
# Reverting must restore BOTH halves: the crash AND the loss of the report.
mrc=$(run_shared "$ZERO" revert)
grade "B: mutation (revert =()) makes the zero-relay path FAIL" \
      "yes" "$([[ "$mrc" -ne 0 ]] && echo yes || echo no)"
grade "B: mutation reproduces the reported message verbatim" yes "$(has 'wired: unbound variable')"
grade "B: mutation DESTROYS the per-agent report (the real cost)" no "$(has 'not an administrator')"

# --- Arm C: POSITIVE CONTROL — the length check must still discriminate -----
# Without this, deleting the `if [[ ${#wired[@]} -gt 0 ]]` block entirely would
# pass arm A. This is the mutation in the OTHER direction.
orc=$(run_shared "$ONE")
grade "C: one-relayed path exits 0" 0 "$orc"
grade "C: listener IS installed when >=1 relayed" yes "$(has 'LISTENER-INSTALLED')"
grade "C: relayed agent appears with status=relayed" \
      "yes" "$(OUT | jq -e '.data.relay[]|select(.agent=="alpha")|select(.status=="relayed")' >/dev/null 2>&1 && echo yes || echo no)"
# format contract for the stubbed boundary: the keys the real python3 block
# emits are the keys the shell reads. If the production jq filter stops
# selecting on .status/.agent, this reds instead of drifting silently.
grade "C: stub format matches the production filter (.status/.agent)" \
      "yes" "$(grep -q 'select(.status=="relayed") | .agent' "$TBSRC" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Arm E — SWEEP. No bare `local -a` may exist in src/. Catches a new one added
# tomorrow, including the inline `local -a x; ...` form that the ticket's own
# line-anchored grep missed on four sites (one of them cmd_loop.sh `results`,
# whose population is conditional on n>0 — the live-shaped one).
# ---------------------------------------------------------------------------
bare=$(grep -rnE 'local +-a +' "$SRC"/*.sh "$SRC"/lib/*.sh | python3 -c '
import sys, re
for line in sys.stdin:
    loc, _, rest = line.partition(":"); ln, _, txt = rest.partition(":")
    m = re.match(r"\s*local\s+-a\s+([^;#]*)", txt)
    if not m: continue
    seg = m.group(1)
    for tok in re.split(r"\s+", seg.strip()):
        if not tok: continue
        if "=" in tok: break        # initializer swallows the rest of the decl
        print(f"{loc}:{ln} {tok}")
' || true)
grade "E: sweep — zero bare 'local -a' declarations remain in src/" "" "$bare"

# ---------------------------------------------------------------------------
# Arm F — CLASSIFICATION, graded by EXECUTION not by prose. For each fixed
# site, lift its real declaration and its real population line out of src/,
# strip the `=()` back off, and run the pair under `set -u` with EMPTY input.
# This is what refutes the ticket's "second live crash in compose": mapfile and
# read -a create the array, `+=` does not. Written as data so a wrong
# expectation reds rather than being argued.
# ---------------------------------------------------------------------------
# file|line|population-shape|expected-crash-without-=()
SITES=(
  "$SRC/cmd_agent_teambot.sh|wired|append|yes"
  "$SRC/cmd_agent_teambot.sh|req|read|no"
  "$SRC/cmd_compose.sh|mgrs|mapfile|no"
  "$SRC/cmd_compose.sh|goals|mapfile|no"
  "$SRC/cmd_loop.sh|tids|append|yes"
  "$SRC/cmd_loop.sh|hids|read|no"
  "$SRC/lib/tasks_db.sh|parts|read|no"
  "$SRC/lib/tasks_db.sh|cm|read|no"
)
for site in "${SITES[@]}"; do
  IFS='|' read -r f var shape want <<<"$site"
  grade "F: $var declared with =() in $(basename "$f")" \
        "yes" "$(grep -qE "local +-a +.*\b${var}=\(\)" "$f" && echo yes || echo no)"
  case "$shape" in
    mapfile) pop="mapfile -t $var < <(printf '')" ;;
    read)    pop="IFS=',' read -ra $var <<<\"\"" ;;
    append)  pop="while IFS= read -r x; do [[ -n \"\$x\" ]] && ${var}+=(\"\$x\"); done < <(printf '')" ;;
  esac
  got=$(bash -c "set -u; f(){ local -a $var; $pop; [[ \${#${var}[@]} -gt 0 ]]; }; f" >/dev/null 2>&1; \
        [[ $? -eq 1 ]] && echo no || echo yes)
  # rc 1 == the length check ran and said "empty"; a crash is rc 1 too under
  # `bash -c`, so distinguish on the MESSAGE, which is the only honest signal.
  msg=$(bash -c "set -u; f(){ local -a $var; $pop; [[ \${#${var}[@]} -gt 0 ]]; }; f" 2>&1 >/dev/null)
  got=$([[ "$msg" == *"unbound variable"* ]] && echo yes || echo no)
  grade "F: $var ($shape) crashes-without-default = $want" "$want" "$got"
done
# The headline correction, stated as a graded assertion so it cannot rot into
# a comment nobody re-checks.
compose_pop=$(grep -A2 'local -a mgrs' "$SRC/cmd_compose.sh" | grep -c 'mapfile -t')
grade "F: compose mgrs/reports are mapfile-populated (=> NOT a live crash)" 2 "$compose_pop"

# ---------------------------------------------------------------------------
# Arm G — the CLASS guard, not the site guard. `local -a` is only one way to
# reach an uncreated array; arm E would not catch `local x` + `${#x[@]}`, or a
# name never declared at all. This resolves EVERY `${#NAME[@]}` read in src/
# against how NAME is created earlier in its own function.
#
# It is non-vacuous: on pristine origin/main it reports exactly ONE unresolved
# read — cmd_agent_teambot.sh:1258 $wired, the reported live crash — and does
# NOT report cmd_compose.sh, which is the whole-codebase confirmation that the
# ticket's "two live sites" count was one too high.
# ---------------------------------------------------------------------------
unresolved=$(python3 - <<'PY'
import re, glob
out = []
for f in sorted(glob.glob("src/*.sh") + glob.glob("src/lib/*.sh")):
    lines = open(f).readlines()
    fstart, cur = {}, 0
    for i, l in enumerate(lines):
        if re.match(r'^[_a-zA-Z][_a-zA-Z0-9]*\(\)\s*\{', l): cur = i
        fstart[i] = cur
    for i, l in enumerate(lines):
        if l.lstrip().startswith('#'): continue
        for m in re.finditer(r'\$\{#([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}', l):
            var = m.group(1)
            # only what executes BEFORE the read can have created it
            created = any(
                re.search(rf'\b(local|declare|typeset)\b[^\n]*\b{var}=', b)
                or re.search(rf'\bmapfile\b[^\n]*\s{var}\b', b)          # assignment builtin
                or re.search(rf'\bread\b[^\n]*-[a-zA-Z]*a[a-zA-Z]*\s+{var}\b', b)  # ditto
                or re.search(rf'^\s*{var}=\(', b)
                or re.search(rf'\bfor\s+{var}\b', b)
                for b in lines[fstart[i]:i])
            if not created: out.append(f"{f}:{i+1} ${var}")
print("\n".join(out))
PY
)
grade "G: class guard — every \${#x[@]} read resolves to a created array" "" "$unresolved"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL" >&2
# Verdict LAST: a tally printf after this line would silently disarm the whole
# harness for CI and `task verify --cmd`, which grade on $? alone.
[[ $FAIL -eq 0 ]]
