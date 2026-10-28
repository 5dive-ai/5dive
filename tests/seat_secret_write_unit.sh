#!/usr/bin/env bash
# DIVE-7168: a standard seat saves an API key it made itself.
#   * the browser seat signs up for a supplier and makes the key; `secret write`
#     is root, so on the rerun box (10-28) Clicker could not keep CJ_API_KEY
#   * now `5dive secret write <KEY> --connector=tools` from a seat with no root
#     crosses ONE exact-path grant (`_seat_secret`): key and value on stdin, the
#     seat from SUDO_UID, tools only, the reserved-name rule as for root
#   * it adds a new key or replaces one THIS seat saved; one the owner or another
#     seat saved is refused (it cannot swap anyone's key for its own)
# Isolation: src/ sourced into a throwaway connectors dir; `sudo` and `5dive` are
# stubs on PATH; no root, no network.
# Run: bash tests/seat_secret_write_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/seat-secret-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR" "$TMP/bin"
cat > "$TMP/bin/5dive" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/answer.log"
EOF
# The caller half's sudo: `-l` says whether the grant is there; a call records
# its argv and stdin.
cat > "$TMP/bin/sudo" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "-n -l /usr/local/bin/5dive _seat_secret" ]] && { [[ -f "$TMP/grant" ]]; exit \$?; }
printf '%s\n' "\$*" > "$TMP/sudo.args"; cat > "$TMP/sudo.stdin"; exit 0
EOF
chmod +x "$TMP/bin/5dive" "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/actor.sh cmd_tool.sh cmd_secret.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
# header.sh puts the sbin dirs first, and tests/lib/env_isolation.sh shadows sudo
# with a function that refuses every call: the stub must win over both.
export PATH="$TMP/bin:$PATH"
unset -f sudo
TOOLS_WRITE_LOCK="$TMP/tool.lock"
SECRET_WRITE_LOCK="$TMP/secret.lock"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
F="$TOOLS_ENV_FILE"; W="$FIVEDIVE_CONNECTOR_DIR/tools.writers"
seen() { BASH_ENV="$F" /bin/bash -c "printf '%s' \"\${$1:-}\""; }
# The root half for <seat>, as root runs it after the uid check. `fail` exits.
sput() { ( _seat_secret_put "$1" "$2" "$3" ) 2>&1; }
# A root write by the owner (the gate's one-time link), the path that exists today.
oput() { ( require_root() { :; }; printf '%s\n' "$2" | _secret_write "$1" --connector=tools ) 2>&1; }

# --- W1: a new key, saved by the seat that made it ------------------------------
out=$(sput clicker CJ_API_KEY cj_FAKE_0001); rc=$?
[[ $rc -eq 0 && "$(seen CJ_API_KEY)" == cj_FAKE_0001 ]] && ok_t "W1 a seat saves a new key; every agent's bash sees it" || bad_t "W1 write" "rc=$rc $out"
[[ "$(cat "$W" 2>/dev/null)" == "CJ_API_KEY clicker" && "$(stat -c %a "$W" 2>/dev/null)" == 600 ]] && ok_t "W1 tools.writers names the seat, 600" || bad_t "W1 ledger" "$(ls -l "$W" 2>&1; cat "$W" 2>&1)"
[[ "$out" == *"saved by clicker"* && "$out" != *cj_FAKE* ]] && ok_t "W1 says where and who, never the value" || bad_t "W1 message" "$out"
[[ ! -s "$TMP/answer.log" ]] && ok_t "W1 no gate is marked provided by a person" || bad_t "W1 gate clear" "$(cat "$TMP/answer.log")"

# --- W2: the same seat replaces its own -----------------------------------------
out=$(sput clicker CJ_API_KEY cj_FAKE_0002); rc=$?
[[ $rc -eq 0 && "$(seen CJ_API_KEY)" == cj_FAKE_0002 && "$out" == *updated* && "$(grep -c '' "$W")" == 1 ]] \
  && ok_t "W2 the seat that saved it replaces it (updated, one ledger line)" || bad_t "W2 replace" "rc=$rc $out $(cat "$W")"

# --- W3: another seat cannot ----------------------------------------------------
out=$(sput dude CJ_API_KEY evil_FAKE); rc=$?
[[ $rc -ne 0 && "$(seen CJ_API_KEY)" == cj_FAKE_0002 && "$out" == *"already saved on this box by clicker"* ]] \
  && ok_t "W3 another seat cannot replace it (refused, value kept)" || bad_t "W3 must refuse" "rc=$rc $out"

# --- W4: nor a key the owner saved ----------------------------------------------
oput ELEVENLABS_API_KEY el_OWNER_1 >/dev/null
out=$(sput clicker ELEVENLABS_API_KEY el_EVIL); rc=$?
[[ $rc -ne 0 && "$(seen ELEVENLABS_API_KEY)" == el_OWNER_1 && "$out" == *"by the owner"* ]] \
  && ok_t "W4 a key the owner saved is refused (value kept)" || bad_t "W4 must refuse" "rc=$rc $out"
# ...and once the owner replaces a seat's key, it is the owner's from then on.
oput CJ_API_KEY cj_OWNER_3 >/dev/null
out=$(sput clicker CJ_API_KEY cj_FAKE_0004); rc=$?
[[ $rc -ne 0 && "$(seen CJ_API_KEY)" == cj_OWNER_3 ]] \
  && ok_t "W4 a seat's key the owner replaced is the owner's now" || bad_t "W4 owner replace" "rc=$rc $out $(cat "$W")"

# --- W5/W6: names and values a root write also refuses ----------------------------
for k in ANTHROPIC_API_KEY PATH CLAUDE_CODE_OAUTH_TOKEN; do
  out=$(sput clicker "$k" x_FAKE); rc=$?
  [[ $rc -ne 0 && "$(grep -c "^export $k=" "$F")" == 0 ]] && ok_t "W5 reserved name refused: $k" || bad_t "W5 must refuse $k" "rc=$rc"
done
before=$(cat "$F")
for v in '' $'one\ntwo' "x';touch $TMP/pwned;'"; do
  out=$(sput clicker FAL_KEY "$v"); rc=$?
  [[ $rc -ne 0 && "$(cat "$F")" == "$before" && ! -e "$TMP/pwned" ]] && ok_t "W6 refused value: ${v:0:12}" || bad_t "W6 must refuse" "rc=$rc"
done

# --- W7: the root half's own gate -----------------------------------------------
out=$( cmd_seat_secret_write <<<"" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"privileged internal primitive"* ]] && ok_t "W7 not root: refused" || bad_t "W7 root gate" "rc=$rc $out"
out=$( _gate_is_root() { return 0; }; SUDO_UID=0 cmd_seat_secret_write <<<"" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"requires sudo from an agent seat"* ]] && ok_t "W7 no agent caller: refused" || bad_t "W7 caller" "rc=$rc $out"
out=$( _gate_is_root() { return 0; }; _gate_uid_to_agent() { printf ''; }; SUDO_UID=1234 cmd_seat_secret_write <<<"" 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"is not an agent seat"* ]] && ok_t "W7 a non-agent uid: refused" || bad_t "W7 non-agent" "rc=$rc $out"
out=$( _gate_is_root() { return 0; }; _gate_uid_to_agent() { printf 'clicker'; }; printf 'SHIP_KEY\0shp_FAKE_9' | SUDO_UID=1234 cmd_seat_secret_write 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(seen SHIP_KEY)" == shp_FAKE_9 && "$(awk '$1=="SHIP_KEY"{print $2}' "$W")" == clicker ]] \
  && ok_t "W7 an agent caller: key and value from stdin, the seat from the uid" || bad_t "W7 good call" "rc=$rc $out"
out=$( _gate_is_root() { return 0; }; _gate_uid_to_agent() { printf 'clicker'; }; SUDO_UID=1234 cmd_seat_secret_write X_KEY 2>&1 <<<"" ); rc=$?
[[ $rc -ne 0 && "$out" == *"takes no arguments"* ]] && ok_t "W7 an argument is refused" || bad_t "W7 args" "rc=$rc $out"

# --- W8: the grant ----------------------------------------------------------------
r=$(render_standard_sudoers agent-clicker 0 0)
[[ "$(grep -c '^agent-clicker ALL=(root) NOPASSWD: /usr/local/bin/5dive _seat_secret$' <<<"$r")" == 1 ]] \
  && ok_t "W8 the standard grant has the one exact line, no args" || bad_t "W8 sudoers" "$(grep _seat_secret <<<"$r")"
[[ "$(classify_sudo_grant <<<"$r")" == "cli-scoped|root|0" ]] && ok_t "W8 the classifier still reads it cli-scoped, nothing extra" || bad_t "W8 classify" "$(classify_sudo_grant <<<"$r")"

# --- W9: the caller half ------------------------------------------------------------
rm -f "$TMP/sudo.stdin"; touch "$TMP/grant"
out=$( _gate_is_root() { return 1; }; printf 'cj_FAKE_CALLER\n' | _secret_write CJ2_API_KEY --connector=tools 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(cat "$TMP/sudo.args" 2>/dev/null)" == "-n /usr/local/bin/5dive _seat_secret" ]] && ok_t "W9 a seat with the grant crosses it with no argument" || bad_t "W9 cross" "rc=$rc $out $(cat "$TMP/sudo.args" 2>&1)"
[[ "$(od -An -c "$TMP/sudo.stdin" 2>/dev/null | tr -s ' ' | tr -d '\n')" == " C J 2 _ A P I _ K E Y \0 c j _ F A K E _ C A L L E R" ]] && ok_t "W9 key, NUL, value on stdin; the value is not on argv" || bad_t "W9 wire" "$(od -c "$TMP/sudo.stdin" 2>&1)"
rm -f "$TMP/grant" "$TMP/sudo.args"
out=$( _gate_is_root() { return 1; }; printf 'v\n' | _secret_write CJ3_API_KEY --connector=tools 2>&1 ); rc=$?
[[ $rc -ne 0 && ! -e "$TMP/sudo.args" ]] && ok_t "W9 no grant: today's root-only refusal" || bad_t "W9 no grant" "rc=$rc $out"
touch "$TMP/grant"
out=$( _gate_is_root() { return 1; }; printf 'v\n' | _secret_write OPENAI_KEY --connector=openai 2>&1 ); rc=$?
[[ $rc -ne 0 && ! -e "$TMP/sudo.args" ]] && ok_t "W9 any connector but tools stays root-only" || bad_t "W9 connector" "rc=$rc $out"
out=$( _gate_is_root() { return 1; }; printf 'v\n' | _secret_write CJ4_API_KEY --connector=tools --task=DIVE-1 2>&1 ); rc=$?
[[ $rc -ne 0 && ! -e "$TMP/sudo.args" ]] && ok_t "W9 --task (a person's drop) stays root-only" || bad_t "W9 task" "rc=$rc $out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
