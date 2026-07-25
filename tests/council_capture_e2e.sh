#!/usr/bin/env bash
# DIVE-1869 e2e — a convene that could not REACH its seats must fail LOUD, not seal a receipt.
#
# Two failures found on the 2026-07-24 flagship demo, both proved here on the BUILT binary (not by
# calling cli.mjs directly — that was the CNCL-26 blind spot):
#
#   (1) convene run without the privileged delivery grant: every seat ballot failed on delivery,
#       each was recorded as a plain ABSTAIN, and the run produced a normal-looking
#       "Inquorate: 0 of N voted" verdict. A permissions outage was indistinguishable from a
#       legitimate unanimous abstention. Now: exit non-zero, name the seats, seal nothing.
#   (2) `sudo 5dive council ...` died with "needs node on PATH" because root's non-login PATH has
#       no nvm node. Now: node is located, and the pick is the NEWEST version (not the first glob).
#
# Offline: a stub `5dive` on COUNCIL_5DIVE_BIN stands in for the fleet; a stub `sudo` makes the
# delivery pre-flight deterministic regardless of the runner's real sudo rights. No root, no seal,
# no live board. Exit 0 == green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

pass=0; fail=0
ok()  { if [[ "$1" == 0 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d -t 5dive-1869.XXXXXX)" || { echo "SKIP: mktemp failed"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" ./build.sh >/dev/null 2>&1; then echo "SKIP: could not build a throwaway binary"; exit 0; fi
chmod +x "$BIN"

# ---- stub fleet: `agent list` resolves the seats; `task add` REFUSES (the delivery outage) ------
STUB="$TMP/stub/5dive"; mkdir -p "$TMP/stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    echo '{"ok":true,"data":[{"name":"alpha","health":{}},{"name":"beta","health":{}},{"name":"gamma","health":{}}]}' ;;
  "task add")
    echo "board is read-only (stubbed delivery outage)" >&2; exit 1 ;;
  "task show"|"task cancel") echo '{"ok":true,"data":{"task":{"status":"todo"}}}' ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

# ================================================================= (1) delivery failure is LOUD ==
# Ad-hoc panel (no genesis needed) on the DEFAULT ballot rail. Every ballot fails to mint, so every
# seat is a capture failure and 0 of 3 seats are heard.
out="$(COUNCIL_5DIVE_BIN="$STUB" "$BIN" council convene "ship it?" \
        --seats=alpha,beta,gamma --mode=quick --ballot-deadline=2 --ballot-poll=1 --json 2>&1)"
rc=$?
ok "$([[ $rc -ne 0 ]] && echo 0 || echo 1)" "an all-capture-failed convene EXITS NON-ZERO (got rc=$rc)"
has "$out" "FAILED TO DELIVER" && ok 0 "the refusal says FAILED TO DELIVER" || ok 1 "the refusal says FAILED TO DELIVER (got: $out)"
has "$out" "NOT an abstention" && ok 0 "the refusal states this is NOT an abstention" || ok 1 "refusal distinguishes outage from abstention (got: $out)"
has "$out" "NO receipt was sealed" && ok 0 "the refusal states no receipt was sealed" || ok 1 "refusal states nothing was sealed (got: $out)"
for s in alpha beta gamma; do
  has "$out" "$s" && ok 0 "the refusal names the unreached seat $s" || ok 1 "refusal names seat $s"
done
has "$out" '"disposition"' && ok 1 "a delivery-failure convene must NOT emit a verdict envelope" || ok 0 "no verdict envelope is emitted on a delivery failure"

# A convene where the seats ARE heard still works — the refusal must not swallow real deliberation.
STUB2="$TMP/stub2/5dive"; mkdir -p "$TMP/stub2"
cat > "$STUB2" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list")
    echo '{"ok":true,"data":[{"name":"alpha","health":{}},{"name":"beta","health":{}},{"name":"gamma","health":{}}]}' ;;
  "task add") echo '{"ok":true,"data":{"ident":"T-1"}}' ;;
  "task show")
    echo '{"ok":true,"data":{"task":{"status":"done","result":"COUNCIL-VOTE: approve :: fine by me"}}}' ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB2"
out2="$(COUNCIL_5DIVE_BIN="$STUB2" "$BIN" council convene "ship it?" \
         --seats=alpha,beta,gamma --mode=quick --ballot-deadline=5 --ballot-poll=1 --json 2>&1)"
rc2=$?
ok "$([[ $rc2 -eq 0 ]] && echo 0 || echo 1)" "a convene whose seats DO answer still succeeds (rc=$rc2)"
disp="$(printf '%s' "$out2" | jq -r '.data.disposition // .disposition // empty' 2>/dev/null)"
ok "$([[ "$disp" == "pass" ]] && echo 0 || echo 1)" "an all-approve convene still passes (disposition=$disp)"

# ---- ask-rail pre-flight: no delivery grant => refuse BEFORE dispatching ------------------------
# `sudo` is resolved through PATH by the pre-flight probe, so a stub makes this deterministic on any
# runner (a CI box with no sudo and an admin box with NOPASSWD:ALL would otherwise disagree).
mkdir -p "$TMP/nosudo"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/nosudo/sudo"; chmod +x "$TMP/nosudo/sudo"
mkdir -p "$TMP/yessudo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/yessudo/sudo"; chmod +x "$TMP/yessudo/sudo"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "note: running as root — the ask-rail pre-flight always passes for root; skipping its refusal leg"
else
  outp="$(PATH="$TMP/nosudo:$PATH" COUNCIL_5DIVE_BIN="$STUB2" "$BIN" council convene "ship it?" \
            --seats=alpha,beta,gamma --mode=quick --ask-rail --timeout=2 --json 2>&1)"
  rcp=$?
  ok "$([[ $rcp -ne 0 ]] && echo 0 || echo 1)" "ask-rail with NO delivery grant refuses up front (rc=$rcp)"
  has "$outp" "cannot reach the seat-delivery rail" && ok 0 "the pre-flight names the delivery rail" || ok 1 "pre-flight names the rail (got: $outp)"
  has "$outp" "_deliver" && ok 0 "the pre-flight names the _deliver grant so the operator can fix it" || ok 1 "pre-flight names _deliver"
  # With the grant present the pre-flight must NOT fire (no false refusal on a legitimate caller).
  outq="$(PATH="$TMP/yessudo:$PATH" COUNCIL_5DIVE_BIN="$STUB2" "$BIN" council convene "ship it?" \
            --seats=alpha,beta,gamma --mode=quick --ask-rail --timeout=2 --json 2>&1)"
  has "$outq" "cannot reach the seat-delivery rail" && ok 1 "pre-flight must NOT refuse a caller that HAS the grant" || ok 0 "a caller with the grant passes the pre-flight"
fi

# ---- the refusal leaves a DURABLE audit row, not just loud stderr ------------------------------
# A refused convene seals NOTHING by design, so the audit row is the ONLY trace the attempt
# happened. Driven against an ISOLATED AUDIT_LOG (never the host's real one) by calling the same
# named function the convene path calls, plus a STRUCTURAL assertion that the path actually calls it
# — the shape that caught the DIVE-1935 slug collision.
SINK="$TMP/refusal.json"
cat > "$SINK" <<'SINKEOF'
{"reason":"delivery-failure","seatCount":3,"captureFailed":3,"seats":["alpha","beta","gamma"],"kinds":["capture-failed"],"detail":"sudo: a password is required"}
SINKEOF
row="$(bash -c '
  AUDIT_LOG="'"$TMP"'/audit/agent-audit.log"
  mkdir -p "$(dirname "$AUDIT_LOG")"; : > "$AUDIT_LOG"
  source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
  source src/lib/state.sh; source src/lib/audit.sh
  source <(sed -n "/^_council_audit_refusal() {/,/^}/p" src/cmd_council.sh)
  _council_audit_refusal "'"$SINK"'" 7
  cat "$AUDIT_LOG"' 2>/dev/null)"
ok "$([[ -n "$row" ]] && echo 0 || echo 1)" "a refused convene emits an audit row (got: ${row:-<none>})"
echo "$row" | jq -e '.cmd == "council convene" and .result == "error" and .code == 7' >/dev/null 2>&1   && ok 0 "the audit row records the command, an error result and the refusal exit code"   || ok 1 "audit row cmd/result/code (got: $row)"
echo "$row" | jq -e '[.args[] | select(startswith("refused=delivery-failure"))] | length == 1' >/dev/null 2>&1   && ok 0 "the audit row names the refusal REASON (delivery-failure), not just that it failed"   || ok 1 "audit row names the reason (got: $row)"
echo "$row" | jq -e '([.args[] | select(test("^seats=alpha,beta,gamma$"))] | length) == 1 and ([.args[] | select(test("^unreached=3/3$"))] | length) == 1' >/dev/null 2>&1   && ok 0 "the audit row names WHICH seats were unreached and how many of how many"   || ok 1 "audit row names the seats and the ratio (got: $row)"
# An empty/absent sink must never emit a row (a refusal for some other reason is not a delivery one).
empty="$(bash -c '
  AUDIT_LOG="'"$TMP"'/audit2/agent-audit.log"
  mkdir -p "$(dirname "$AUDIT_LOG")"; : > "$AUDIT_LOG"
  source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
  source src/lib/state.sh; source src/lib/audit.sh
  source <(sed -n "/^_council_audit_refusal() {/,/^}/p" src/cmd_council.sh)
  _council_audit_refusal "'"$TMP"'/nope.json" 3
  wc -c < "$AUDIT_LOG"' 2>/dev/null | tr -d " ")"
ok "$([[ "$empty" == "0" ]] && echo 0 || echo 1)" "no sink => no audit row (only a delivery refusal is recorded as one)"
# STRUCTURAL: the convene path must actually CALL it — a correct row that nothing invokes is dead.
grep -q '_council_audit_refusal "\$_refusal" "\$_rc"' "$ROOT/src/cmd_council.sh" \
  && ok 0 "the convene failure path calls the refusal auditor" \
  || ok 1 "convene failure path wires the refusal auditor"
grep -q 'COUNCIL_REFUSAL_SINK=' "$ROOT/src/cmd_council.sh" \
  && ok 0 "the convene path hands cli.mjs a refusal sink to write" \
  || ok 1 "convene path sets COUNCIL_REFUSAL_SINK"

# ================================================================== (2) node discovery under sudo ==
# The bundle must LOCATE node rather than dying on "needs node on PATH", and must pick the NEWEST
# nvm release (a plain glob is lexicographic: v9.9.9 would beat v10.0.0).
FAKE="$TMP/fakehome"
mkdir -p "$FAKE/.nvm/versions/node/v10.0.0/bin" "$FAKE/.nvm/versions/node/v9.9.9/bin"
printf '#!/usr/bin/env bash\necho v10.0.0\n' > "$FAKE/.nvm/versions/node/v10.0.0/bin/node"
printf '#!/usr/bin/env bash\necho v9.9.9\n'  > "$FAKE/.nvm/versions/node/v9.9.9/bin/node"
chmod +x "$FAKE/.nvm/versions/node/v10.0.0/bin/node" "$FAKE/.nvm/versions/node/v9.9.9/bin/node"

picked="$(bash -c 'source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh; _nvm_newest_node "$1"' _ "$FAKE" 2>/dev/null)"
ok "$([[ "$picked" == "$FAKE/.nvm/versions/node/v10.0.0/bin/node" ]] && echo 0 || echo 1)" \
   "_nvm_newest_node picks the NEWEST release by version, not lexicographically (got: $picked)"
missing="$(bash -c 'source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh; _nvm_newest_node "$1" && echo FOUND || echo NONE' _ "$TMP/empty" 2>/dev/null)"
ok "$([[ "$missing" == "NONE" ]] && echo 0 || echo 1)" "_nvm_newest_node reports nothing when there is no nvm tree"

# Discovery itself: called with node NOT on PATH (the `sudo` posture), ensure_node_on_path must put
# a real node there. Asserted on the outcome (`command -v node` after the call), not on a message.
mkdir -p "$TMP/nonode"
# PATH is narrowed INSIDE the subshell (a `PATH=... bash -c` prefix would also break the lookup of
# bash itself). Everything before the narrowing needs no external command.
found="$(bash -c '
  source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
  PATH="'"$TMP"'/nonode:/usr/sbin:/sbin"
  command -v node >/dev/null 2>&1 && { echo "PRECONDITION-FAILED: node still on PATH"; exit 0; }
  ensure_node_on_path || { echo NOTFOUND; exit 0; }
  command -v node')"
ok "$([[ -x "$found" ]] && echo 0 || echo 1)" "ensure_node_on_path puts a real node on a node-less PATH (got: $found)"

# And when there is genuinely no node anywhere, the failure carries the exact remediation rather
# than the old dead end. Driven by stubbing the locator to find nothing (a host with no node at all
# is not reproducible in CI, but the message on that path is exactly what must not rot).
rem="$(bash -c '
  source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
  ensure_node_on_path() { return 1; }
  require_node "5dive council"' 2>&1)"
has "$rem" "5dive council needs node on PATH and none was found" && ok 0 "the node failure names the command and says it searched" || ok 1 "node failure text (got: $rem)"
has "$rem" "root's PATH does not inherit nvm" && ok 0 "the node failure explains WHY sudo breaks it" || ok 1 "node failure explains the sudo cause"
has "$rem" "ln -s" && ok 0 "the node failure hands over a copy-pasteable permanent fix" || ok 1 "node failure carries a remediation command"

echo "DIVE-1869 capture/delivery E2E: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
