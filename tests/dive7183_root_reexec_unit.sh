#!/usr/bin/env bash
# DIVE-7183 — a root-only verb run without sudo re-runs itself through `sudo -n`
# when the seat holds the grant, and otherwise names the admin colleague who can.
#
# THE DEFECT: require_root printed "must run as root — try: sudo 5dive <args>".
# Its reader is an agent whose owner has no terminal; a weak model (DIVE-7172)
# read it, stopped, and asked its owner to find root.
#
# Graded on the BUILT BUNDLE with a fake sudo (FIVEDIVE_SUDO) that answers the
# `-n -l` probe from FAKE_GRANT and records what a real re-run would have run,
# with its stdin. FIVEDIVE_BIN names the bundle as "the installed CLI", which is
# the only binary allowed to re-run itself. R1 needs root (the CI runner reaches
# it through its own sudo); every other arm needs a non-root caller.
#
#   bash tests/dive7183_root_reexec_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
ROOT_DIR="$PWD"

TMP="$(mktemp -d /tmp/dive7183.XXXXXX)"
chmod 755 "$TMP"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "P0: a bundle builds" "$(tail -3 "$TMP/build.log")"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
chmod 755 "$BIN"
ok_t "P0: a bundle builds (the artifact the fix ships in)"

cat > "$TMP/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -n && "$2" == -l ]]; then shift 2; printf 'PROBE %s\n' "$*" >>"$FAKE_LOG"; [[ "${FAKE_GRANT:-0}" == 1 ]]; exit; fi
if [[ "$1" == -n ]]; then shift; printf 'EXEC %s\n' "$*" >>"$FAKE_LOG"; printf 'STDIN %s\n' "$(cat)" >>"$FAKE_LOG"; echo REEXECED; exit 0; fi
exit 9
EOF
chmod 755 "$TMP/sudo"
mkdir -p "$TMP/home" "$TMP/state"; chmod 777 "$TMP/home" "$TMP/state"

# run <grant 0|1> <installed bin> <args...> — stdin is the caller's.
run() { local g="$1" inst="$2"; shift 2; : >"$TMP/log"; chmod 666 "$TMP/log"
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" FAKE_LOG="$TMP/log" FAKE_GRANT="$g" \
    FIVEDIVE_SUDO="$TMP/sudo" FIVEDIVE_BIN="$inst" "$BIN" "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
log() { cat "$TMP/log"; }

# --- R) already root: the probe is never reached, so a re-run cannot loop -----
as_root() { if (( EUID == 0 )); then "$@"; elif sudo -n true 2>/dev/null; then sudo -n "$@"; else return 99; fi; }
: >"$TMP/log"; chmod 666 "$TMP/log"
as_root env HOME="$TMP/home" STATE_DIR="$TMP/state" FAKE_LOG="$TMP/log" FAKE_GRANT=1 \
  FIVEDIVE_SUDO="$TMP/sudo" FIVEDIVE_BIN="$BIN" "$BIN" heartbeat on --no-such-flag </dev/null >"$TMP/out" 2>"$TMP/err"
rc=$?
if (( rc == 99 )); then
  printf 'note: no root reachable here — R1 graded only where the harness has root (CI has it)\n'
else
  [[ ! -s "$TMP/log" ]] && ! has "$(cat "$TMP/err")" "must run as root" \
    && ok_t "R1: as root the check passes without a probe or a re-run (rc $rc: the verb's own flag error)" \
    || bad_t "R1: root must not probe or re-run" "rc=$rc log=$(log) err=$(cat "$TMP/err")"
fi

# Everything below grades the NON-root path; as root the check passes on its own.
if (( EUID == 0 )); then
  printf 'note: running as root — the non-root arms below need a non-root runner (the core CI job is one)\n'
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; (( FAIL == 0 )); exit
fi

# --- E) the seat holds the grant: the same argv is re-run through sudo -n ------
rc=$(run 1 "$BIN" heartbeat on --every=5 </dev/null)
[[ "$rc" == 0 ]] && has "$(cat "$TMP/out")" REEXECED \
  && has "$(log)" "PROBE $BIN heartbeat on --every=5" && has "$(log)" "EXEC $BIN heartbeat on --every=5" \
  && ok_t "E1: granted -> probed with sudo -n -l, then exec sudo -n <same argv> (rc 0)" \
  || bad_t "E1: granted seat re-runs" "rc=$rc out=$(cat "$TMP/out") err=$(cat "$TMP/err") log=$(log)"

rc=$(printf 'sk-zzz\n' | run 1 "$BIN" tool set openrouter)
[[ "$rc" == 0 ]] && has "$(log)" "STDIN sk-zzz" && ! has "$(log)" "PROBE $BIN tool set openrouter sk" \
  && ok_t "E2: stdin reaches the re-run intact, and the key never rides argv" \
  || bad_t "E2: stdin passthrough" "rc=$rc log=$(log)"

rc=$(run 1 "$BIN" --json heartbeat on </dev/null)
has "$(log)" "EXEC $BIN --json heartbeat on" \
  && ok_t "E3: the re-run keeps --json where the caller put it" \
  || bad_t "E3: --json kept" "log=$(log)"

# --- S) never a credential on a sudo line (DIVE-5805) -------------------------
rc=$(run 1 "$BIN" heartbeat on --token=sk-SECRET </dev/null)
[[ "$rc" == 10 ]] && ! has "$(log)" sk-SECRET && ! has "$(log)" EXEC && ! has "$(cat "$TMP/err")" sk-SECRET \
  && has "$(cat "$TMP/err")" "sudo -n 5dive heartbeat on --token=-" \
  && ok_t "S1: a key in argv is not re-run, not probed, not echoed; the agent is told to pipe it (rc 10)" \
  || bad_t "S1: secret argv" "rc=$rc err=$(cat "$TMP/err") log=$(log)"

# --- I) a value given as `-` may already have been read: no re-run -------------
rc=$(printf 'x\n' | run 1 "$BIN" heartbeat on --message-file=-)
[[ "$rc" == 10 ]] && ! has "$(log)" EXEC && has "$(cat "$TMP/err")" "reads its input from stdin" \
  && ok_t "I1: a stdin-marked command with piped input is not re-run blind (rc 10)" \
  || bad_t "I1: stdin marker" "rc=$rc err=$(cat "$TMP/err") log=$(log)"

# --- B) only the installed CLI re-runs itself ----------------------------------
rc=$(run 1 /nonexistent/5dive heartbeat on </dev/null)
[[ "$rc" == 10 ]] && ! has "$(log)" PROBE \
  && ok_t "B1: a bundle that is not the installed binary never probes or sudo-runs (rc 10)" \
  || bad_t "B1: worktree bundle stays put" "rc=$rc log=$(log)"

# --- N) no grant: who can, never the owner -------------------------------------
rc=$(run 0 "$BIN" heartbeat on </dev/null)
e=$(cat "$TMP/err")
[[ "$rc" == 10 ]] && has "$e" "must run as root" && has "$e" "Do not ask your owner to run anything" \
  && ! has "$e" "try: sudo" && ! has "$(log)" EXEC \
  && ok_t "N1: no grant -> refused (rc 10), no re-run, no 'try: sudo', the owner is not handed a command" \
  || bad_t "N1: no-grant refusal" "rc=$rc err=$e log=$(log)"

# The colleague naming, graded on the sourced library. `bash -c … <zero>` sets
# $0, which is both "the running CLI" and the lister _root_admin_colleagues runs.
SRC="$ROOT_DIR/src"
LIBS="for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do source \"$SRC/\$f\"; done; set +e"
src_run() { local zero="$1"; shift; : >"$TMP/log"
  FAKE_LOG="$TMP/log" FAKE_GRANT=1 FIVEDIVE_SUDO="$TMP/sudo" FIVEDIVE_BIN="$TMP/lister" \
    bash -c "$LIBS; $*" "$zero" 2>&1 </dev/null; }

o=$(src_run x 'FIVE_ARGV=(heartbeat on --token=sk-SECRET); _root_admin_colleagues() { printf "main ops"; }; ( require_root ); echo RC=$?')
has "$o" "colleague on this box who has it (main, ops)" && has "$o" '5dive agent send main "' \
  && has "$o" "--token=<value>" && ! has "$o" sk-SECRET && has "$o" RC=10 \
  && ok_t "N2: names the admin colleagues, with a ready agent send line, credential redacted" \
  || bad_t "N2: colleague naming" "$o"
o=$(src_run x 'FIVE_ARGV=(heartbeat on); _root_admin_colleagues() { :; }; ( require_root ); echo RC=$?')
has "$o" "No other agent on this box has it either" && ! has "$o" "agent send" && has "$o" RC=10 \
  && ok_t "N3: no admin colleague -> says it cannot be done from this agent" \
  || bad_t "N3: no colleague" "$o"

cat > "$TMP/lister" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "agent list --json" ]] || exit 3
cat <<'J'
{"data":[{"name":"a","active":"inactive","sudo":{"impliedIsolation":"admin"}},{"name":"b","active":"active","sudo":{"impliedIsolation":"standard"}},{"name":"c","active":"active","sudo":{"impliedIsolation":"admin"}},{"name":"me","active":"active","sudo":{"impliedIsolation":"admin"}},{"name":"d","active":"active","sudo":{"impliedIsolation":"beyond-admin"}}]}
J
EOF
chmod 755 "$TMP/lister"
o=$(USER=agent-me src_run "$TMP/lister" 'echo "[$(_root_admin_colleagues)]"')
[[ "$o" == "[d c]" ]] \
  && ok_t "N4: only RUNNING admin seats other than me are named, the lead (beyond-admin) first" \
  || bad_t "N4: colleague filter" "$o"

# Inside $(…) the exec would run the whole command a second time, nested.
o=$(src_run "$TMP/lister" 'FIVE_ARGV=(heartbeat on); _root_admin_colleagues() { :; }; x=$(require_root); echo RC=$?')
sub_log=$(log)
o2=$(src_run "$TMP/lister" 'FIVE_ARGV=(heartbeat on); require_root; echo NOTREACHED')
! has "$sub_log" EXEC && has "$o" RC=10 && has "$(log)" "EXEC $TMP/lister heartbeat on" && ! has "$o2" NOTREACHED \
  && ok_t "L1: inside \$(…) the check refuses instead of re-running; at top level it re-runs (control)" \
  || bad_t "L1: subshell guard" "sub=$o sublog=$sub_log top=$o2 log=$(log)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
