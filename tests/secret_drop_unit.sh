#!/usr/bin/env bash
# DIVE-931 isolated unit harness for the secure credential drop wiring:
#   * `task need --type=secret --secret-key=K --connector=C` stores the drop
#     target on the gate row and validates key/connector charsets + pairing.
#   * `_task_mint_drop_link` maps the api /drop/mint response to url|ttl / ONBOX /
#     empty (curl mocked — no network).
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

# --- T4: _task_mint_drop_link response mapping (curl mocked) -------------------
export CONNECTORD_TOKEN="unit-test-box-token"
MOCK_RESP=""
curl() { printf '%s' "$MOCK_RESP"; return 0; }   # mock: echo canned body, ignore args

MOCK_RESP='{"url":"https://api.5dive.com/drop/abc123","expiresAt":"x","ttlMinutes":30}'
got=$(_task_mint_drop_link DIVE-901 PYPI_TOKEN pypi)
[[ "$got" == "https://api.5dive.com/drop/abc123|30" ]] && ok_t "T4a live link -> url|ttl" \
  || bad_t "T4a live link -> url|ttl" "got: $got"

MOCK_RESP='{"useOnBoxPath":true}'
got=$(_task_mint_drop_link DIVE-901 PYPI_TOKEN pypi)
[[ "$got" == "ONBOX" ]] && ok_t "T4b useOnBoxPath -> ONBOX" \
  || bad_t "T4b useOnBoxPath -> ONBOX" "got: $got"

# curl failure (api down) -> empty (caller falls back to legacy text)
curl() { return 7; }
got=$(_task_mint_drop_link DIVE-901 PYPI_TOKEN pypi)
[[ -z "$got" ]] && ok_t "T4c mint failure -> empty (legacy fallback)" \
  || bad_t "T4c mint failure -> empty (legacy fallback)" "got: $got"

# no box identity (token absent, no /etc file on this host) -> empty
unset CONNECTORD_TOKEN
got=$(_task_mint_drop_link DIVE-901 PYPI_TOKEN pypi)
[[ -z "$got" ]] && ok_t "T4d no connectord token -> empty" \
  || bad_t "T4d no connectord token -> empty" "got: $got"
unset -f curl

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

echo
echo "secret-drop unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
