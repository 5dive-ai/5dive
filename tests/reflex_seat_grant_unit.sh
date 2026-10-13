#!/usr/bin/env bash
# DIVE-6115 unit: a standard seat reaches reflex through root, never the key.
#
# On a self-hosted box `sudo 5dive config openrouter-key=-` writes the box key
# 640 root:claude-keys (DIVE-5690). A standard seat (clicker) is not in
# claude-keys, so its own `reflex status` read "unknown" and the browser's
# broken-step retry fell back to the name match. The fix: the standard seat
# template grants `reflex status|pick-ref|login-marker` (bare and with args),
# a seat's `reflex status` re-runs itself through that grant, and a root call a
# scoped caller started is narrowed first (built-in backend only, no --out,
# inputs read as the caller).
#
# WHAT IS ASSERTED HERE (one arm per acceptance line)
#   G  the template carries the six lines, still classifies cli-scoped with no
#      extra entries (both classifiers), visudo accepts it, and grants no other
#      reflex verb.
#   S  NEGATIVE CONTROL. Key set, clicker hired: the seat's own `reflex status`
#      (json and text) reads configured true, key set, source connector. With the
#      DIVE-6115 lines removed from its sudoers, or the elevation removed, the
#      same arm reads unknown: it goes red on a revert.
#   P  the browser's exact sequence (bare -l probe, status --json, pick-ref) as
#      the seat reaches Jev with the connector key; the seat itself cannot read
#      the key (a plain, non-sudo pick-ref is refused).
#   N  a scoped root call refuses --backend=<command> and --out, and an input
#      the caller cannot read; stages readable inputs and removes them after. A
#      caller holding the whole CLI is unchanged. Mutant: narrowing removed ->
#      the backend command runs.
#   O  order: key before the hire and after it end in the same status; a seat
#      on the pre-6115 template is re-rendered by the installer's reconcile.
#   H  help text and the file agree: 640 root:claude-keys.
#
# Isolation: src/ sourced, sudo and curl are fakes on PATH, the sudo fake
# matches the rendered sudoers lines with sudo's own rule (the args string
# against the pattern, so `x *` needs at least one argument). Run:
#   bash tests/reflex_seat_grant_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/reflex-seat-grant-unit.XXXXXX")"
trap 'rc=$?; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
chmod 755 "$TMP"

SRCS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh
      lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/verify_policy.sh
      lib/reflex.sh cmd_box_config.sh cmd_reflex.sh cmd_reflex_pick_ref.sh cmd_reflex_login_marker.sh"
for f in $SRCS; do
  # shellcheck source=/dev/null
  source "src/$f"
done
source src/cmd_agent_create.sh
set +e

export STATE_DIR="$TMP/state" BOX_CONFIG="$TMP/box.json"
export TASKS_DIR="$STATE_DIR/tasks" TASKS_DB="$STATE_DIR/tasks/tasks.db"
export FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/etc/reflex-openrouter.key"
export FIVEDIVE_REFLEX_ENDPOINT_KEY_FILE="$TMP/etc/reflex-endpoint.key"
export ROOT_CONNECTORS="$TMP/root-view/connectors" SEAT_CONNECTORS="$TMP/seat-view/connectors"
export CONNECTORS_DIR="$ROOT_CONNECTORS"
mkdir -p "$TASKS_DIR" "$TMP/etc" "$ROOT_CONNECTORS" "$SEAT_CONNECTORS" "$TMP/fakebin" "$TMP/rootonly"
printf '{}\n' >"$BOX_CONFIG"
unset FIVEDIVE_REFLEX_RECEIPTS FIVEDIVE_REFLEX_SHADOW FIVEDIVE_REFLEX_SHADOW_BACKEND FIVEDIVE_REFLEX_OPENROUTER_URL
require_root() { return 0; }
audit_log() { return 0; }
chown() { return 0; }
JSON_MODE=0

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

# ── fakes ────────────────────────────────────────────────────────────────────
# The CLI as one process: what /usr/local/bin/5dive is on a box. FAKE_ROOT marks
# the process sudo started (EUID cannot be faked); FAKE_HOLDS_CLI is a caller
# whose sudoers hold the whole CLI; FAKE_NO_ELEVATE / FAKE_NO_NARROW are the
# revert mutants.
export DRIVER="$TMP/5dive-driver.sh"
cat >"$DRIVER" <<EOF
cd "$ROOT" || exit 2
for f in $(printf '%s ' $SRCS); do source "src/\$f"; done
set +e
trap _five_run_exit_handlers EXIT
_reflex_is_root()          { [[ -n "\${FAKE_ROOT:-}" ]]; }
_reflex_caller_holds_cli() { [[ -n "\${FAKE_HOLDS_CLI:-}" ]]; }
# The caller cannot read anything under rootonly/, as a seat cannot read root's files.
_reflex_as_caller() { local a; for a in "\$@"; do [[ "\$a" == "$TMP/rootonly/"* ]] && return 1; done; "\$@"; }
[[ -n "\${FAKE_NO_ELEVATE:-}" ]] && reflex_status_elevate() { return 0; }
[[ -n "\${FAKE_NO_NARROW:-}" ]] && reflex_scoped_args() { shift; REFLEX_ARGS=("\$@"); }
JSON_MODE=0
[[ "\$1" == reflex ]] && shift   # /usr/local/bin/5dive reflex <verb>, as sudo runs it
cmd_reflex "\$@"
EOF

# sudo: -n [-l] /usr/local/bin/5dive <args>. A command runs only when a line of
# \$FAKE_SUDOERS for agent-clicker matches the whole "path args" string.
cat >"$TMP/fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -n ]] && shift
list=0; [[ "$1" == -l ]] && { list=1; shift; }
s="$*"; hit=1
while IFS= read -r line; do
  [[ "$line" == "agent-clicker ALL=(root) NOPASSWD: "* ]] || continue
  pat="${line#*NOPASSWD: }"
  # shellcheck disable=SC2053  # the pattern IS a glob, as sudoers matches it
  [[ "$s" == $pat ]] && { hit=0; break; }
done <"$FAKE_SUDOERS"
(( hit == 0 )) || { echo "sudo: a password is required" >&2; exit 1; }
(( list )) && { echo "$s"; exit 0; }
printf '%s\n' "$s" >>"$FAKE_SUDO_LOG"
[[ "$1" == /usr/local/bin/5dive ]] || exit 1
shift
exec env FIVEDIVE_CONNECTOR_DIR="$ROOT_CONNECTORS" FAKE_ROOT=1 SUDO_UID=4242 SUDO_USER=agent-clicker bash "$DRIVER" "$@"
EOF
# OpenRouter's Decisions API: logs the Authorization header FILE and picks the first option.
cat >"$TMP/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out="" body="" url="" auth="" model=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -H) [[ "$2" == @* ]] && auth=$(cat "${2#@}" 2>/dev/null); shift ;;
    --data-binary) body="${2#@}"; shift ;;
    -m|-w|-X) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
model=$(jq -r '.model // ""' "$body" 2>/dev/null)
printf 'URL=%s MODEL=%s AUTH=[%s]\n' "$url" "$model" "$auth" >>"$FAKE_CURL_LOG"
jq -c '.questions.decision.criteria | keys_unsorted | first as $k
  | {model: "typesafe/jev-1.13", answers: {decision: {type: "choice", choice: $k,
     probabilities: {($k): 0.95}, confidence: 0.95}}, usage: {cost: 0.00001}}' "$body" >"$out"
printf 200
EOF
chmod +x "$TMP/fakebin/sudo" "$TMP/fakebin/curl"
export PATH="$TMP/fakebin:$PATH"
export FAKE_SUDOERS="$TMP/sudoers.clicker" FAKE_SUDO_LOG="$TMP/sudo.log" FAKE_CURL_LOG="$TMP/curl.log"
: >"$FAKE_SUDO_LOG"; : >"$FAKE_CURL_LOG"

# The seat: the same CLI with the seat's view of /etc/5dive/connectors, where
# the key file exists and is not readable (640 root:claude-keys, seat not in it).
seat() { env FIVEDIVE_CONNECTOR_DIR="$SEAT_CONNECTORS" bash "$DRIVER" "$@"; }
seat_view_sync() {
  rm -f "$SEAT_CONNECTORS/openrouter.env"
  if [[ -e "$ROOT_CONNECTORS/openrouter.env" ]]; then
    cp "$ROOT_CONNECTORS/openrouter.env" "$SEAT_CONNECTORS/openrouter.env"; chmod 000 "$SEAT_CONNECTORS/openrouter.env"
  fi
}
(( EUID == 0 )) && printf 'note - running as root: a mode-000 file stays readable to root, so S/P control arms are not meaningful here; run as a non-root user\n'

KEY="sk-or-v1-SEATGRANT$(date +%s%N)abc"
set_key()  { printf '%s\n' "$KEY" | ( JSON_MODE=1; cmd_box_config openrouter-key=- ) >"$TMP/setkey.out" 2>&1; seat_view_sync; }
hire()     { render_standard_sudoers agent-clicker 0 0 >"$FAKE_SUDOERS"; }
pre6115()  { render_standard_sudoers agent-clicker 0 0 | grep -v 'NOPASSWD: /usr/local/bin/5dive reflex '; }

# ── G: the template ──────────────────────────────────────────────────────────
SUD=$(render_standard_sudoers agent-clicker 0 0)
n=0
for want in 'reflex status' 'reflex status \*' 'reflex pick-ref' 'reflex pick-ref \*' 'reflex login-marker' 'reflex login-marker \*'; do
  grep -qE "^agent-clicker ALL=\(root\) NOPASSWD: /usr/local/bin/5dive ${want}$" <<<"$SUD" && n=$((n+1))
done
check "G the standard template grants reflex status, pick-ref and login-marker, each bare and with arguments (6 lines)" \
  "$([[ $n == 6 ]]; echo $?)" "found $n of 6"
check "G no other reflex verb is granted (replay, report, log, fake run as the seat or not at all)" \
  "$([[ $(grep -cE 'NOPASSWD: /usr/local/bin/5dive reflex ' <<<"$SUD") == 6 ]]; echo $?)"
check "G the template still classifies cli-scoped with no extra entries (the installer reconcile keeps re-rendering it)" \
  "$([[ "$(classify_sudo_grant <<<"$SUD")" == "cli-scoped|root|0" ]]; echo $?)" "$(classify_sudo_grant <<<"$SUD")"
pyok=0
for c in 'reflex status' 'reflex status *' 'reflex pick-ref' 'reflex pick-ref *' 'reflex login-marker' 'reflex login-marker *'; do
  grep -qF "\"/usr/local/bin/5dive $c\"" src/cmd_agent.sh || pyok=1
done
check "G the agent survey's classifier knows the six lines too (else every seat reads 'custom')" "$pyok"
if command -v visudo >/dev/null 2>&1; then
  printf '%s\n' "$SUD" >"$TMP/visudo.in"
  check "G visudo accepts the template" "$(visudo -cf "$TMP/visudo.in" >/dev/null 2>&1; echo $?)" "$(visudo -cf "$TMP/visudo.in" 2>&1)"
else
  printf 'skip - G visudo not installed here\n'
fi
hire
check "G the browser's probe (sudo -n -l <5dive> reflex pick-ref, no further args) is granted" \
  "$("$TMP/fakebin/sudo" -n -l /usr/local/bin/5dive reflex pick-ref >/dev/null 2>&1; echo $?)"
check "G config is not granted (the seat cannot set or read the key through this)" \
  "$("$TMP/fakebin/sudo" -n -l /usr/local/bin/5dive config openrouter-key=- >/dev/null 2>&1; [[ $? != 0 ]]; echo $?)"

# ── S: the seat's own status (NEGATIVE CONTROL) ─────────────────────────────
set_key
check "S fixture: the root view has the key, the seat view cannot read it" \
  "$([[ -s "$ROOT_CONNECTORS/openrouter.env" && -e "$SEAT_CONNECTORS/openrouter.env" ]] && (( EUID == 0 )) || [[ ! -r "$SEAT_CONNECTORS/openrouter.env" ]]; echo $?)"
: >"$FAKE_SUDO_LOG"
SJ=$(seat status --json 2>"$TMP/s.err")
check "S clicker's own 'reflex status --json' reads configured true, key set, source connector" \
  "$(jq -e '.configured == true and .key == "set" and .key_source == "connector"' <<<"$SJ" >/dev/null; echo $?)" "$SJ $(cat "$TMP/s.err")"
check "S …through the grant (sudo ran reflex status as root, once)" \
  "$([[ "$(cat "$FAKE_SUDO_LOG")" == "/usr/local/bin/5dive reflex status --json" ]]; echo $?)" "$(cat "$FAKE_SUDO_LOG")"
ST=$(seat status 2>&1)
check "S the text form (no arguments, the bare grant) reads 'configured    true'" \
  "$(grep -qx 'configured    true' <<<"$ST"; echo $?)" "$ST"
check "S status prints no key" "$([[ "$SJ$ST" != *"$KEY"* ]]; echo $?)"
pre6115 >"$FAKE_SUDOERS"
CJ=$(seat status --json 2>/dev/null)
check "S CONTROL: on the pre-6115 sudoers the same arm reads configured unknown (null)" \
  "$(jq -e '.configured == null' <<<"$CJ" >/dev/null; echo $?)" "$CJ"
hire
MJ=$(FAKE_NO_ELEVATE=1 seat status --json 2>/dev/null)
check "S CONTROL: with the elevation reverted the same arm reads configured unknown (null)" \
  "$(jq -e '.configured == null' <<<"$MJ" >/dev/null; echo $?)" "$MJ"
rm -f "$SEAT_CONNECTORS/openrouter.env"; cp "$ROOT_CONNECTORS/openrouter.env" "$SEAT_CONNECTORS/openrouter.env"; chmod 640 "$SEAT_CONNECTORS/openrouter.env"
: >"$FAKE_SUDO_LOG"
AJ=$(seat status --json 2>/dev/null)
check "S a seat that can read the key (admin) answers itself: no sudo at all" \
  "$(jq -e '.configured == true' <<<"$AJ" >/dev/null && [[ ! -s "$FAKE_SUDO_LOG" ]]; echo $?)" "$AJ | $(cat "$FAKE_SUDO_LOG")"
seat_view_sync

# ── P: the browser's broken-step retry reaches Jev ───────────────────────────
TREE="$TMP/seat-tree.json"
cat >"$TREE" <<'EOF'
{"url":"https://example.test/compose","title":"Compose","nodes":[
 {"ref":"e1","role":"button","name":"Send message"},
 {"ref":"e2","role":"link","name":"Home"}]}
EOF
: >"$FAKE_CURL_LOG"
probe=$("$TMP/fakebin/sudo" -n -l /usr/local/bin/5dive reflex pick-ref >/dev/null 2>&1; echo $?)
cfgd=$(timeout 20 "$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex status --json 2>/dev/null | jq -r '.configured')
PR=$("$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TREE" --op=click --intent="send the message" --json </dev/null 2>"$TMP/p.err")
check "P the browser's sequence as the seat: probe granted, status configured, pick-ref answers with a ref" \
  "$([[ $probe == 0 && $cfgd == true ]] && jq -e '.choice != "none" and (.ref | type) == "string"' <<<"$PR" >/dev/null; echo $?)" \
  "probe=$probe configured=$cfgd $PR $(cat "$TMP/p.err")"
check "P …the decision went to Jev (typesafe/jev-1.13) with the box connector key, root-side" \
  "$(grep -q "MODEL=typesafe/jev-1.13 AUTH=\[Bearer $KEY\]\|MODEL=typesafe/jev-1.13 AUTH=\[.*$KEY" "$FAKE_CURL_LOG"; echo $?)" "$(cat "$FAKE_CURL_LOG")"
check "P the key never reaches the seat's stdout or stderr" "$([[ "$PR$(cat "$TMP/p.err")" != *"$KEY"* ]]; echo $?)"
SP=$(seat pick-ref example.test "--tree=$TREE" --op=click --intent="send the message" --json 2>&1)
check "P the seat itself cannot read the key: a plain pick-ref is refused and names sudo" \
  "$([[ "$SP" == *"not readable by"* && "$SP" == *"sudo 5dive reflex pick-ref"* ]]; echo $?)" "$SP"

# ── N: a scoped root call is narrowed ────────────────────────────────────────
PWN="$TMP/pwned"
cp "$TREE" "$TMP/rootonly/tree.json"
NB=$("$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TREE" --op=click --intent=x "--backend=touch $PWN" --json 2>&1)
check "N --backend=<command> through the seat grant is refused and runs nothing" \
  "$([[ ! -e "$PWN" && "$NB" == *"would run that command as root"* ]]; echo $?)" "$NB"
NO=$("$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex login-marker example.test "--logged-out=$TREE" "--url=https://example.test/" "--out=$TMP/written" --backend=fake:first 2>&1)
check "N --out through the seat grant is refused and writes nothing" \
  "$([[ ! -e "$TMP/written" && "$NO" == *"does not take --out"* ]]; echo $?)" "$NO"
NR=$("$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TMP/rootonly/tree.json" --op=click --intent=x --json 2>&1)
check "N an input the seat cannot read is refused (root does not read it for the seat)" \
  "$([[ "$NR" == *"agent-clicker cannot read"* ]]; echo $?)" "$NR"
before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name '5dive-reflex-in.*' 2>/dev/null | wc -l)
NF=$("$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TREE" --op=click --intent=x --backend=fake:first --json 2>&1)
after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name '5dive-reflex-in.*' 2>/dev/null | wc -l)
check "N a readable input is staged as the seat, used, and the staging removed" \
  "$(jq -e '.choice == "r1"' <<<"$NF" >/dev/null && [[ $before == "$after" ]]; echo $?)" "$NF before=$before after=$after"
NA=$(FAKE_HOLDS_CLI=1 "$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TREE" --op=click --intent=x "--backend=touch $PWN; echo '{\"choice\":\"r1\"}'" --json 2>&1)
check "N a caller holding the whole CLI (admin, owner) is unchanged: its --backend command runs" \
  "$([[ -e "$PWN" ]]; echo $?)" "$NA"
rm -f "$PWN"
FAKE_NO_NARROW=1 "$TMP/fakebin/sudo" -n /usr/local/bin/5dive reflex pick-ref example.test "--tree=$TREE" --op=click --intent=x "--backend=touch $PWN" --json >/dev/null 2>&1
check "N MUTANT: with the narrowing removed the seat's --backend command runs as root (the arm above sees it)" \
  "$([[ -e "$PWN" ]]; echo $?)"
rm -f "$PWN"

# ── O: order does not matter ─────────────────────────────────────────────────
rm -f "$ROOT_CONNECTORS/openrouter.env"; seat_view_sync
hire; set_key
A=$(seat status --json 2>/dev/null | jq -c '{configured, key, key_source}')
rm -f "$ROOT_CONNECTORS/openrouter.env" "$FAKE_SUDOERS"; seat_view_sync
set_key; hire
B=$(seat status --json 2>/dev/null | jq -c '{configured, key, key_source}')
check "O hire then key, and key then hire, end the same: configured true" \
  "$([[ "$A" == "$B" ]] && jq -e '.configured == true' <<<"$A" >/dev/null; echo $?)" "hire-first=$A key-first=$B"
export SUDOERS_D="$TMP/sudoers.d"; mkdir -p "$SUDOERS_D"
pre6115 >"$SUDOERS_D/agent-clicker"
write_standard_sudoers() { render_standard_sudoers "$1" "$2" "$3" >"$SUDOERS_D/$1"; }
r=$(_reconcile_standard_sudoers_one agent-clicker)
check "O a seat hired before the grant is re-rendered by the installer reconcile and gains it" \
  "$([[ "$r" == updated ]] && grep -q 'NOPASSWD: /usr/local/bin/5dive reflex pick-ref \*$' "$SUDOERS_D/agent-clicker"; echo $?)" "$r"
check "O a second reconcile is a no-op" "$([[ "$(_reconcile_standard_sudoers_one agent-clicker)" == current ]]; echo $?)"

# ── H: the help text and the file agree ──────────────────────────────────────
HELP=$(cmd_box_config --help 2>&1)
check "H config --help says 640 root:claude-keys for openrouter-key, not root:claude" \
  "$(grep -qF 'written 640 root:claude-keys to' <<<"$HELP" && ! grep -qE 'written 640 root:claude( |$)' <<<"$HELP"; echo $?)" "$(grep -n 'written 640' <<<"$HELP")"
# The write's posture with the OS faked: the group it lands in and its mode.
(
  _sp_group_exists() { return 0; }
  _sp_chgrp()        { printf '%s' "$1" >"$2.grp"; }
  _sp_setfacl()      { return 0; }
  _sp_user_exists()  { return 1; }
  rm -f "$ROOT_CONNECTORS/openrouter.env"
  printf '%s\n' "$KEY" | ( JSON_MODE=1; cmd_box_config openrouter-key=- ) >/dev/null 2>&1
  [[ "$(cat "$ROOT_CONNECTORS/openrouter.env.grp" 2>/dev/null)" == claude-keys \
     && "$(stat -c %a "$ROOT_CONNECTORS/openrouter.env")" == 640 ]]
)
check "H the write lands 640, group claude-keys (what the help now says)" "$?"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
