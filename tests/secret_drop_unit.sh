#!/usr/bin/env bash
# DIVE-931 isolated unit harness for the secure credential drop wiring:
#   * `task need --type=secret --secret-key=K --connector=C` stores the drop
#     target on the gate row and validates key/connector charsets + pairing.
#   * `_task_mint_drop_link` mints on THIS box (`5dive secret link`, DIVE-5319)
#     and never calls an API (sudo + curl mocked — no network).
#   * `secret write <K> --connector=C --task=DIVE-N` writes the value from stdin
#     and shells `5dive task answer` to auto-resolve the gate (5dive mocked).
# Isolation matches the loop harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched. Run: bash tests/secret_drop_unit.sh
# (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/secret-drop-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Notify is a no-op in isolation (no channel resolves); silence it so `task need`
# doesn't try to DM. We test the mint helper + text separately below.
task_need_notify() { :; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }

# --- T1: secret gate with a drop target stores secret_key + connector ---------
seed_task DIVE-901
cmd_task_need DIVE-901 --type=secret --ask="pypi token" --secret-key=PYPI_TOKEN --connector=pypi >/dev/null 2>&1
got=$(db "SELECT need_type||'|'||COALESCE(secret_key,'')||'|'||COALESCE(connector,'') FROM tasks WHERE ident='DIVE-901';")
[[ "$got" == "secret|PYPI_TOKEN|pypi" ]] && ok_t "T1 secret gate stores secret_key+connector" \
  || bad_t "T1 secret gate stores secret_key+connector" "got: $got"

# --- T2: DIVE-2411 — the no-target secret gate is no longer FILABLE -----------
# This arm asserted the opposite until DIVE-2411 ("legacy secret gate keeps target
# NULL"): both flags omitted was the DEFAULTED out-of-band shape. DIVE-2232 shipped
# on that default and had no path for the value to reach the box at all. The shape
# survives only when CHOSEN (--out-of-band, T2b). Full negative/positive/mutation
# coverage lives in tests/secret_gate_delivery_path_unit.sh.
seed_task DIVE-902
out=$(cmd_task_need DIVE-902 --type=secret --ask="drop it somewhere" 2>&1); rc=$?
got=$(db "SELECT COALESCE(need_type,'null') FROM tasks WHERE ident='DIVE-902';")
[[ $rc -ne 0 && "$out" == *"must name a delivery path"* && "$got" == "null" ]] \
  && ok_t "T2 secret gate with no delivery path is refused at filing (no row written)" \
  || bad_t "T2 secret gate with no delivery path is refused at filing (no row written)" "rc=$rc need_type=$got out=$out"

# --- T2b: the out-of-band shape stays reachable when explicitly chosen ---------
seed_task DIVE-904
cmd_task_need DIVE-904 --type=secret --ask="drop it somewhere" --out-of-band="already in my .env on this box" >/dev/null 2>&1
got=$(db "SELECT need_type||'|'||COALESCE(secret_key,'null')||'|'||COALESCE(secret_oob,'') FROM tasks WHERE ident='DIVE-904';")
[[ "$got" == "secret|null|already in my .env on this box" ]] && ok_t "T2b explicit --out-of-band files and records the declared channel" \
  || bad_t "T2b explicit --out-of-band files and records the declared channel" "got: $got"

# --- T3: validation rejections ------------------------------------------------
seed_task DIVE-903
out=$(cmd_task_need DIVE-903 --type=approval --ask="x" --secret-key=K --connector=c 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"only apply to --type=secret"* ]] && ok_t "T3a target rejected on non-secret gate" \
  || bad_t "T3a target rejected on non-secret gate" "rc=$rc out=$out"

out=$(cmd_task_need DIVE-903 --type=secret --ask="x" --secret-key=PYPI_TOKEN 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"must be given together"* ]] && ok_t "T3b key without connector rejected" \
  || bad_t "T3b key without connector rejected" "rc=$rc out=$out"

out=$(cmd_task_need DIVE-903 --type=secret --ask="x" --secret-key="bad-lower" --connector=pypi 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"invalid --secret-key"* ]] && ok_t "T3c bad secret-key charset rejected" \
  || bad_t "T3c bad secret-key charset rejected" "rc=$rc out=$out"

out=$(cmd_task_need DIVE-903 --type=secret --ask="x" --secret-key=OK_KEY --connector="Bad_Conn" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"invalid --connector"* ]] && ok_t "T3d bad connector charset rejected" \
  || bad_t "T3d bad connector charset rejected" "rc=$rc out=$out"

# --- T4: _task_mint_drop_link is box-local (DIVE-5319) -------------------------
# It mints through `5dive secret link` on THIS box, never 5dive's API: curl is
# mocked to record any call, and every arm requires that record to stay empty.
CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"
curl() { echo "$*" >> "$CURL_LOG"; return 0; }
SUDO_LOG="$TMP/sudo.log"; : > "$SUDO_LOG"
MINT_OUT='{"ok":true,"data":{"url":"https://secrets.box.example.com/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCd","ttl_minutes":30}}'
sudo() { echo "$*" >> "$SUDO_LOG"; printf '%s' "$MINT_OUT"; }
id() { [[ "${1:-}" == -un ]] && { printf 'agent-mailer\n'; return 0; }; command id "$@"; }
SEAT_TIER=admin
agent_tier() { [[ "$1" == mailer ]] && printf '%s\n' "$SEAT_TIER" || printf 'unknown:unregistered\n'; }

got=$(_task_mint_drop_link DIVE-901)
[[ "$got" == "https://secrets.box.example.com/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCd|30" ]] \
  && ok_t "T4a an admin seat (grant already covers 5dive) mints on the box -> url|ttl" \
  || bad_t "T4a an admin seat (grant already covers 5dive) mints on the box -> url|ttl" "got: $got"
[[ "$(cat "$SUDO_LOG")" == "-n 5dive --json secret link DIVE-901" ]] \
  && ok_t "T4b the mint is \`5dive secret link\` on this box, one sudo call, no probe" \
  || bad_t "T4b the mint is \`5dive secret link\` on this box, one sudo call, no probe" "sudo calls: $(cat "$SUDO_LOG")"

for SEAT_TIER in standard sandboxed unknown:unregistered; do
  : > "$SUDO_LOG"
  got=$(_task_mint_drop_link DIVE-901)
  [[ -z "$got" && ! -s "$SUDO_LOG" ]] \
    && ok_t "T4c a ${SEAT_TIER} seat mints nothing and runs NO sudo (a refused sudo mails root)" \
    || bad_t "T4c a ${SEAT_TIER} seat mints nothing and runs NO sudo (a refused sudo mails root)" "got: $got calls: $(cat "$SUDO_LOG")"
done

SEAT_TIER=admin; MINT_OUT='{"ok":true,"data":{"url":"http://secrets.box.example.com/x","ttl_minutes":30}}'
got=$(_task_mint_drop_link DIVE-901)
[[ -z "$got" ]] && ok_t "T4d a non-https link is never put in the alert" \
  || bad_t "T4d a non-https link is never put in the alert" "got: $got"

[[ ! -s "$CURL_LOG" ]] && ok_t "T4e no arm called out to any API (curl never ran)" \
  || bad_t "T4e no arm called out to any API (curl never ran)" "curl: $(cat "$CURL_LOG")"
unset -f curl sudo id agent_tier

# --- T5: secret write --task writes value + auto-resolves the gate ------------
# Mock the box environment: no real root, connectors dir in TMP, and a fake
# `5dive` on PATH that records the `task answer` it receives.
require_root() { :; }
CONNECTORS_DIR="$TMP/connectors"
SECRET_WRITE_LOCK="$TMP/secret-write.lock"
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/5dive" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK5DIVE_LOG"
EOF
chmod +x "$MOCKBIN/5dive"
export MOCK5DIVE_LOG="$TMP/5dive-calls.log"; : > "$MOCK5DIVE_LOG"
PATH="$MOCKBIN:$PATH"

printf 'pypi-AgEIcHl...secret' | _secret_write PYPI_TOKEN --connector=pypi --task=DIVE-901 >/dev/null 2>&1
wrote=$(grep -c '^PYPI_TOKEN=pypi-AgEIcHl...secret$' "$CONNECTORS_DIR/pypi.env" 2>/dev/null)
[[ "$wrote" == "1" ]] && ok_t "T5a value written to connector file from stdin" \
  || bad_t "T5a value written to connector file from stdin" "pypi.env: $(cat "$CONNECTORS_DIR/pypi.env" 2>/dev/null)"

resolved=$(grep -c 'task answer DIVE-901 --human --from=drop' "$MOCK5DIVE_LOG")
[[ "$resolved" == "1" ]] && ok_t "T5b confirmed write auto-resolves the gate" \
  || bad_t "T5b confirmed write auto-resolves the gate" "calls: $(cat "$MOCK5DIVE_LOG")"

# --- T6: secret write WITHOUT --task does not touch any gate -------------------
: > "$MOCK5DIVE_LOG"
printf 'plain-value' | _secret_write OTHER_KEY --connector=misc >/dev/null 2>&1
[[ ! -s "$MOCK5DIVE_LOG" ]] && ok_t "T6 plain secret write triggers no gate resolve" \
  || bad_t "T6 plain secret write triggers no gate resolve" "calls: $(cat "$MOCK5DIVE_LOG")"

# --- T7: DIVE-5384 — a multi-line value lands whole, the .env stays one line ---
# The value file holds the value plus one newline (so $(cat) reads it back
# exactly); the .env gets a single KEY_FILE=<path> line and never a value line.
ENVF="$CONNECTORS_DIR/ovh.env"; VF="$CONNECTORS_DIR/ovh.d/OVH_CREDS"
printf 'OTHER=keep\n' > "$ENVF"
OVH=$'Application key ak16charsxxxxxxx\nApplication secret as32charsxxxxxxxxxxxxxxxxxxxxxxxx\nConsumer Key ck32charsxxxxxxxxxxxxxxxxxxxxxxxx'
printf '%s' "$OVH" | _secret_write OVH_CREDS --connector=ovh > "$TMP/t7.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$VF" <(printf '%s\n' "$OVH") && [[ "$(cat "$VF")" == "$OVH" ]] \
  && ok_t "T7a a 3-line value reads back byte-identical from <connector>.d/<KEY>" \
  || bad_t "T7a a 3-line value reads back byte-identical from <connector>.d/<KEY>" "rc=$rc out=$(cat "$TMP/t7.out") file=$(od -c "$VF" 2>&1 | head -5)"
[[ "$(cat "$ENVF")" == "OTHER=keep"$'\n'"OVH_CREDS_FILE=$VF" ]] \
  && ok_t "T7b the .env carries the other keys plus ONE pointer line, no value line" \
  || bad_t "T7b the .env carries the other keys plus ONE pointer line, no value line" "env=$(cat "$ENVF")"
[[ "$(stat -c %a "$VF")" == 600 && "$(stat -c %a "$CONNECTORS_DIR/ovh.d")" == 750 ]] \
  && ok_t "T7c value file 600, its dir 750 (as the .env and connectors dir)" \
  || bad_t "T7c value file 600, its dir 750 (as the .env and connectors dir)" "$(stat -c '%a %n' "$VF" "$CONNECTORS_DIR/ovh.d")"
! grep -qF 'ak16chars' "$TMP/t7.out" && ok_t "T7d the write's output never carries the value" \
  || bad_t "T7d the write's output never carries the value" "$(cat "$TMP/t7.out")"
# Injection: a value carrying "\nEVIL=1" cannot create a second key.
printf 'innocent\nEVIL=1\nPATH=/tmp' | _secret_write OVH_CREDS --connector=ovh >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -qE '^(EVIL|PATH)=' "$ENVF" && [[ "$(wc -l < "$ENVF")" == 2 ]] \
  && [[ "$(cat "$VF")" == $'innocent\nEVIL=1\nPATH=/tmp' ]] \
  && ok_t "T7e a value with \\nEVIL=1 creates no second key (it is bytes in the value file)" \
  || bad_t "T7e a value with \\nEVIL=1 creates no second key (it is bytes in the value file)" "rc=$rc env=$(cat "$ENVF")"
# Back to one line: the value line returns, the pointer and the file go.
printf 'single-now' | _secret_write OVH_CREDS --connector=ovh >/dev/null 2>&1
[[ "$(cat "$ENVF")" == $'OTHER=keep\nOVH_CREDS=single-now' && ! -e "$VF" ]] \
  && ok_t "T7f a single-line write over a multi-line one drops the pointer and the file" \
  || bad_t "T7f a single-line write over a multi-line one drops the pointer and the file" "env=$(cat "$ENVF") file=$(ls "$CONNECTORS_DIR/ovh.d" 2>&1)"
# Single-line stays byte-identical to the pre-DIVE-5384 shape, and a key that
# merely shares the <KEY>_FILE name (not our pointer) is left alone.
printf 'A=1\nSOLO_FILE=/opt/mine.pem\n' > "$CONNECTORS_DIR/solo.env"
printf 'v1' | _secret_write SOLO --connector=solo >/dev/null 2>&1
printf 'v2' | _secret_write SOLO --connector=solo >/dev/null 2>&1
[[ "$(cat "$CONNECTORS_DIR/solo.env")" == $'A=1\nSOLO_FILE=/opt/mine.pem\nSOLO=v2' && ! -e "$CONNECTORS_DIR/solo.d" ]] \
  && ok_t "T7g single-line writes are unchanged: KEY=value replaced in place, no .d dir, foreign KEY_FILE kept" \
  || bad_t "T7g single-line writes are unchanged: KEY=value replaced in place, no .d dir, foreign KEY_FILE kept" "env=$(cat "$CONNECTORS_DIR/solo.env")"
# Multi-line over single-line: the old value line goes (no stale second reading).
printf 'l1\nl2' | _secret_write SOLO --connector=solo >/dev/null 2>&1
[[ "$(cat "$CONNECTORS_DIR/solo.env")" == "A=1"$'\n'"SOLO_FILE=$CONNECTORS_DIR/solo.d/SOLO" ]] \
  && ok_t "T7h a multi-line write over a single-line one drops the old KEY= line" \
  || bad_t "T7h a multi-line write over a single-line one drops the old KEY= line" "env=$(cat "$CONNECTORS_DIR/solo.env")"

echo
echo "secret-drop unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
