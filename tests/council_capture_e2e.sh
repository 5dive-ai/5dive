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
