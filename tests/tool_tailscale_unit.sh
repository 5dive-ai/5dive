#!/usr/bin/env bash
# DIVE-7996: `5dive tool set|rm tailscale` — the Mini App's Tailscale tile joins
# the server to the owner's tailnet with a pasted auth key.
#   * a key without the tskey-auth- prefix is refused before tailscale runs
#   * the join is shields-up, keeps the box's DNS and routes, and names the box
#   * the key never reaches argv or the answer; its file is gone afterwards
#   * missing tailscale is installed through 5dive-ensure-cli first
#   * rm logs out; ls reads tailscaled's BackendState
# Isolation: a stub `tailscale` and a stub installer in a throwaway dir; no root,
# no network, never the host's own tailscale.
# Negative control: delete --shields-up from src/cmd_tool.sh and T3 goes red.
# Run: bash tests/tool_tailscale_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/tool-tailscale-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR" "$TMP/bin"
export STUB_LOG="$TMP/calls" STUB_STATE="$TMP/state"

# The stub: records each call's argv, and for `up` the key file's contents at
# the moment tailscale would read it. STUB_FAIL makes `up` fail loudly, echoing
# the key the way a careless error message could.
cat > "$TMP/bin/tailscale" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  status) printf '{"BackendState":"%s"}\n' "$(cat "$STUB_STATE" 2>/dev/null || echo NeedsLogin)" ;;
  up)
    for a in "$@"; do
      [[ "$a" == --auth-key=file:* ]] && { f="${a#--auth-key=file:}"; printf 'keyfile=%s mode=%s\n' "$(cat "$f")" "$(stat -c %a "$f")" >> "$STUB_LOG"; printf '%s\n' "$f" > "$STUB_LOG.kf"; }
    done
    if [[ -n "${STUB_FAIL:-}" ]]; then echo "backend error: invalid key: $(cat "${f:-/dev/null}") not valid" >&2; exit 1; fi
    echo Running > "$STUB_STATE"; echo "Success." ;;
  logout) echo NeedsLogin > "$STUB_STATE" ;;
esac
STUB
cat > "$TMP/bin/ensure" <<'STUB'
#!/usr/bin/env bash
printf 'ensure %s\n' "$*" >> "$STUB_LOG"
cp "$(dirname "$0")/tailscale.off" "$(dirname "$0")/tailscale" && chmod +x "$(dirname "$0")/tailscale"
STUB
chmod +x "$TMP/bin/tailscale" "$TMP/bin/ensure"
cp "$TMP/bin/tailscale" "$TMP/bin/tailscale.off"

export FIVEDIVE_TAILSCALE_BIN="$TMP/bin/tailscale" FIVEDIVE_ENSURE_CLI="$TMP/bin/ensure" FIVEDIVE_TAILSCALE_KEY_DIR="$TMP/keys"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_tool.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
TOOLS_WRITE_LOCK="$TMP/lock"
TOOL_GCLOUD_CONFIG="$TMP/gcloud"
require_root() { :; }
JSON_MODE=1
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { ( cmd_tool "$@" ) 2>&1; }
ts_connected() { run ls | jq -r '.data.tools[] | select(.id=="tailscale") | .connected'; }
KEY="tskey-auth-kAbC123CNTRL-Zz9yXwVuTsRqPoNmLkJiHg"

# --- T1: ls lists tailscale (before google), not connected ------------------------
out=$(run ls)
row=$(jq -c '.data.tools[] | select(.id=="tailscale")' <<<"$out")
last=$(jq -r '.data.tools[-1].id' <<<"$out")
[[ "$row" == '{"id":"tailscale","kind":"network","env":[],"connected":false}' && "$last" == google ]] \
  && ok_t "T1 ls lists tailscale as a network row, not connected, google still last" || bad_t "T1 ls row" "$out"

# --- T2: a wrong-prefix key, or two lines, is refused before tailscale runs --------
: > "$STUB_LOG"
for bad in "tskey-api-kAbC123CNTRL-Zz9yXwVu" "ghp_FAKE1234567890" "tskey-auth-x';touch\${IFS}$TMP/pwned;'"; do
  out=$(printf '%s\n' "$bad" | run set tailscale); rc=$?
  [[ $rc -ne 0 && "$out" == *"tskey-auth-"* && ! -s "$STUB_LOG" ]] && ok_t "T2 refused before tailscale ran: ${bad:0:20}…" || bad_t "T2 must refuse: $bad" "rc=$rc $out $(cat "$STUB_LOG")"
done
out=$(printf '%s\n%s\n' "$KEY" "$KEY" | run set tailscale); rc=$?
[[ $rc -ne 0 && "$out" == *"takes 1 value"* && ! -s "$STUB_LOG" ]] && ok_t "T2 two lines refused" || bad_t "T2 two lines" "rc=$rc $out"
out=$(printf '%s\n' "$KEY" | run set tailscale --env=TS_AUTHKEY); rc=$?
[[ $rc -ne 0 && ! -s "$STUB_LOG" ]] && ok_t "T2 --env on tailscale refused" || bad_t "T2 --env" "rc=$rc $out"
[[ ! -e "$TMP/pwned" ]] && ok_t "T2 nothing executed" || bad_t "T2 injection ran"

# --- T3: a good key joins shields-up, DNS and routes untouched -------------------
: > "$STUB_LOG"
out=$(printf '%s\n' "$KEY" | run set tailscale); rc=$?
up=$(grep -m1 '^up ' "$STUB_LOG")
[[ $rc -eq 0 && "$out" == *'"connected":true'* ]] && ok_t "T3 set answers connected" || bad_t "T3 set" "rc=$rc $out"
[[ " $up " == *" --shields-up "* ]] && ok_t "T3 joins with --shields-up" || bad_t "T3 shields-up missing" "$up"
[[ " $up " == *" --accept-dns=false "* && " $up " == *" --accept-routes=false "* ]] && ok_t "T3 keeps the box's DNS and routes" || bad_t "T3 dns/routes" "$up"
[[ " $up " == *" --hostname="?* && " $up " == *" --reset "* ]] && ok_t "T3 names the box and resets old flags" || bad_t "T3 hostname/reset" "$up"
[[ "$(ts_connected)" == true ]] && ok_t "T3 ls reads connected once tailscaled is Running" || bad_t "T3 ls connected" "$(run ls)"

# --- T4: the key never in argv, the answer, or left on disk ----------------------
grep -q "keyfile=$KEY mode=600" "$STUB_LOG" && ok_t "T4 tailscale read the key from a 0600 file" || bad_t "T4 key file" "$(cat "$STUB_LOG")"
! grep -v '^keyfile=' "$STUB_LOG" | grep -q "$KEY" && ok_t "T4 the key is in no argv" || bad_t "T4 key in argv" "$(cat "$STUB_LOG")"
[[ "$out" != *"$KEY"* ]] && ok_t "T4 the answer never prints the key" || bad_t "T4 key in answer" "$out"
kf=$(cat "$STUB_LOG.kf"); [[ -n "$kf" && ! -e "$kf" && -z "$(ls -A "$TMP/keys")" ]] && ok_t "T4 the key file is gone afterwards" || bad_t "T4 key file left" "$kf $(ls -A "$TMP/keys")"
[[ ! -s "$TOOLS_ENV_FILE" ]] || ! grep -q tskey "$TOOLS_ENV_FILE" && ok_t "T4 the key is not saved in the agents' key file" || bad_t "T4 in tools.sh"

# --- T5: a failing join scrubs the key from tailscale's own words ---------------
: > "$STUB_LOG"
out=$(printf '%s\n' "$KEY" | STUB_FAIL=1 run set tailscale); rc=$?
kf=$(cat "$STUB_LOG.kf")
[[ $rc -ne 0 && "$out" == *"did not connect"* && "$out" != *"$KEY"* ]] && ok_t "T5 a failed join reports, without the key" || bad_t "T5 failed join" "rc=$rc $out"
[[ ! -e "$kf" ]] && ok_t "T5 the key file is gone after a failure too" || bad_t "T5 key file left" "$kf"

# --- T6: rm logs out ---------------------------------------------------------------
echo Running > "$STUB_STATE"; : > "$STUB_LOG"
out=$(run rm tailscale); rc=$?
[[ $rc -eq 0 && "$out" == *'"connected":false'* ]] && grep -qx logout "$STUB_LOG" && ok_t "T6 rm runs tailscale logout" || bad_t "T6 rm" "rc=$rc $out $(cat "$STUB_LOG")"
[[ "$(ts_connected)" == false ]] && ok_t "T6 ls reads not connected after rm" || bad_t "T6 ls after rm" "$(run ls)"

# --- T7: no tailscale yet -> installed through 5dive-ensure-cli, then joined -----
rm -f "$TMP/bin/tailscale" "$STUB_STATE"; : > "$STUB_LOG"
[[ "$(ts_connected)" == false ]] && ok_t "T7 ls answers on a box with no tailscale" || bad_t "T7 ls without tailscale" "$(run ls)"
out=$(printf '%s\n' "$KEY" | run set tailscale); rc=$?
[[ $rc -eq 0 && "$(head -1 "$STUB_LOG")" == "ensure tailscale" ]] && grep -q '^up ' "$STUB_LOG" \
  && ok_t "T7 installs tailscale first, then joins" || bad_t "T7 install path" "rc=$rc $out $(cat "$STUB_LOG")"
rm -f "$TMP/bin/tailscale"; : > "$STUB_LOG"
out=$(run rm tailscale); rc=$?
[[ $rc -eq 0 && ! -s "$STUB_LOG" ]] && ok_t "T7 rm with no tailscale is a no-op success" || bad_t "T7 rm none" "rc=$rc $out"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
