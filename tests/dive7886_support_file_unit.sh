#!/usr/bin/env bash
# DIVE-7886 — the Support file: an office box with no internet saves the bug
# report `5dive bug` would send, and IT carries it out to Support in the app.
#
#   B. `5dive bug --save=<path>`: the file is BYTE-IDENTICAL to what an approved
#      `--file` hands the transport (_bug_post → curl --data-binary); its keys
#      are exactly the allowlist; a PII marker planted in selfcheck's free-text
#      fields never reaches it; --argv is redacted the same way.
#   N. NEGATIVE: no description → refused, no file; token-shaped text →
#      refused, no file; --save with --file → refused.
#   Z. nothing leaves the box: --save never reaches _bug_post or curl, never
#      spools, never writes the owner-asked ledger.
#   P. the panel verb `support-file` (src/cmd_local_panel.sh): in the verb
#      table with no arguments; the description rides stdin; the reply's
#      .data.file is the same bytes `5dive bug --save` writes; the description
#      is not in the audit line; empty and token-shaped text get marketing's
#      lines. The REAL cmd_bug runs behind the stand-in CLI.
#   W. the page: the route, the Settings card with marketing's words, and the
#      panel page's script still parses.
#
# Hermetic: selfcheck's dispatch is a fixture table, the transport is stubbed,
# every file is under a temp dir. No network.
set -uo pipefail
trap 'rc=$?; [[ -n "${T:-}" ]] && rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT=$PWD
T=$(mktemp -d)
export XDG_STATE_HOME="$T/state" FIVE_BUG_ASKED_LEDGER="$T/asked.tsv" FIVE_SUPPORT_CODE_FILE="$T/no-support-code"
export GH_ORG="5dive-ai"
for f in header.sh lib/error_codes.sh lib/output.sh lib/self.sh cmd_selfcheck.sh cmd_bug.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
set +e

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }
yes_()   { if eval "$2" >/dev/null 2>&1; then ok_t "$1"; else fail_t "$1 — $2"; fi }

MARK="PII-MARKER-7886-alice.example.com-/home/alice"
_sc_dispatch() { printf '%s\n' "pass||detail $MARK"; }
POSTED="$T/posted.bin"; CALLS="$T/net-calls"
_bug_post() { printf '%s' "$1" >"$POSTED"; echo "_bug_post" >>"$CALLS"; _BUG_HTTP=201; _BUG_ID=7; return 0; }
_bug_drain() { echo 0; }
curl() { echo "curl $*" >>"$CALLS"; return 7; }

WHAT=$'The office chat stopped answering after the update.\nRestarted twice, same.'
ARGV='5dive local serve --token=abc123'

# ── B. byte identity with what --file sends ───────────────────────────────────
F="$T/support-file.json"
out=$( (cmd_bug --verb=support-file --what="$WHAT" --argv="$ARGV" --save="$F") 2>&1 ); rc=$?
chk "B1 --save exits 0" 0 "$rc"
yes_ "B1 --save says nothing was sent" '[[ "$out" == *"Nothing was sent"* ]]'
: >"$CALLS"
( cmd_bug --verb=support-file --what="$WHAT" --argv="$ARGV" --file --owner-approved </dev/null ) >/dev/null 2>&1
yes_ "B2 the approved --file reached the (stubbed) transport" '[[ -s "$POSTED" ]]'
if cmp -s "$F" "$POSTED"; then ok_t "B3 the Support file is BYTE-IDENTICAL to what --file sends"; else fail_t "B3 Support file differs from the sent payload: $(diff <(jq -S . "$F") <(jq -S . "$POSTED") | head -5)"; fi
chk "B4 no trailing newline (curl --data-binary sends none)" "$(tail -c 1 "$POSTED" | od -An -c | tr -d ' ')" "$(tail -c 1 "$F" | od -An -c | tr -d ' ')"
chk "B5 keys are EXACTLY the allowlist" \
  '["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]' "$(jq -cS keys "$F")"
chk "B6 probes carry probe+verdict only" '[["probe","verdict"]]' "$(jq -c '[.probes[] | keys] | unique' "$F")"
if grep -qF -- "$MARK" "$F"; then fail_t "B7 the planted PII marker reached the file"; else ok_t "B7 the PII marker in selfcheck's free text never reaches the file"; fi
yes_ "B8 the token in --argv is redacted in the file, as in what is sent" 'grep -qF -- "--token=<redacted>" <<<"$(jq -r .invocation "$F")" && ! grep -qF abc123 "$F"'
chk "B9 the description is the caller's own text" "$WHAT" "$(jq -r .what "$F")"
perm=$(stat -c %a "$F")
chk "B10 the file is private to whoever saved it (0600)" 600 "$perm"
JSON_MODE=1 j=$( (cmd_bug --verb=support-file --what="$WHAT" --save="$T/j.json") 2>/dev/null )
yes_ "B11 --json says saved, the path and the size" '[[ "$(jq -r .data.saved <<<"$j")" == true && "$(jq -r .data.path <<<"$j")" == "$T/j.json" && "$(jq -r .data.bytes <<<"$j")" == "$(wc -c <"$T/j.json")" ]]'
JSON_MODE=0

# ── N. refusals ───────────────────────────────────────────────────────────────
rm -f "$T/n1.json"
( cmd_bug --save="$T/n1.json" </dev/null ) >/dev/null 2>&1; rc=$?
yes_ "N1 no description → refused, no file" '(( rc != 0 )) && [[ ! -e "$T/n1.json" ]]'
( cmd_bug --what="   " --save="$T/n2.json" </dev/null ) >/dev/null 2>&1; rc=$?
yes_ "N2 a blank description → refused, no file" '(( rc != 0 )) && [[ ! -e "$T/n2.json" ]]'
TOK="ghp_$(printf 'A%.0s' {1..24})"
err=$( (cmd_bug --what="my key is $TOK" --save="$T/n3.json" </dev/null) 2>&1 ); rc=$?
yes_ "N3 token-shaped text → refused, no file" '(( rc != 0 )) && [[ ! -e "$T/n3.json" ]] && [[ "$err" == *token-shaped* ]]'
( cmd_bug --what="x" --save="$T/n4.json" --file --owner-approved </dev/null ) >/dev/null 2>&1; rc=$?
yes_ "N4 --save with --file → refused, nothing written" '(( rc != 0 )) && [[ ! -e "$T/n4.json" ]]'
( cmd_bug --what="x" --save= </dev/null ) >/dev/null 2>&1; rc=$?
yes_ "N5 --save with no path → refused" '(( rc != 0 ))'

# ── Z. nothing leaves the box ─────────────────────────────────────────────────
: >"$CALLS"; rm -rf "$XDG_STATE_HOME" "$FIVE_BUG_ASKED_LEDGER"
( cmd_bug --verb=support-file --what="$WHAT" --save="$T/z.json" </dev/null ) >/dev/null 2>&1
yes_ "Z1 --save saved the file" '[[ -s "$T/z.json" ]]'
chk "Z2 --save never reached the transport or curl" "" "$(cat "$CALLS")"
yes_ "Z3 --save never spooled a report to send later" '[[ -z "$(ls -A "$XDG_STATE_HOME/5dive/bug-spool" 2>/dev/null)" ]]'
yes_ "Z4 --save never wrote the owner-asked ledger" '[[ ! -s "$FIVE_BUG_ASKED_LEDGER" ]]'

# ── P. the panel verb ─────────────────────────────────────────────────────────
# The stand-in CLI runs the REAL cmd_bug with the same fixture selfcheck.
export FIVE_LOCAL_CHAT_ROOT="$T/root" FIVE_PANEL_CLI="$T/fake5dive"
mkdir -p "$T/root"
cat >"$FIVE_PANEL_CLI" <<FAKE
#!/usr/bin/env bash
cd "$ROOT" || exit 2
export XDG_STATE_HOME="$T/state" FIVE_BUG_ASKED_LEDGER="$T/asked.tsv" FIVE_SUPPORT_CODE_FILE="$T/no-support-code" GH_ORG=5dive-ai
for f in header.sh lib/error_codes.sh lib/output.sh lib/self.sh cmd_selfcheck.sh cmd_bug.sh; do source "src/\$f"; done
set +e
_sc_dispatch() { printf '%s\n' "pass||detail $MARK"; }
_bug_post() { echo "_bug_post" >>"$CALLS"; return 1; }
curl() { echo "curl \$*" >>"$CALLS"; return 7; }
echo "\$*" >>"$T/cli.log"
[[ "\$1" == --json ]] && { JSON_MODE=1; shift; }
[[ "\$1" == bug ]] || { echo "fake: only bug" >&2; exit 2; }
shift; cmd_bug "\$@"
FAKE
chmod +x "$FIVE_PANEL_CLI"
for f in lib/validation.sh lib/local_only.sh cmd_local_chat.sh cmd_local_chat_server.sh cmd_local_panel.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
set +e
require_root() { :; }
JSON_MODE=0

yes_ "P1 support-file is in the verb table, with no arguments" '_lp_validate support-file'
yes_ "P2 support-file with an argument is refused" '! _lp_validate support-file extra'
: >"$CALLS"
PW='Approvals tab is empty since Tuesday; the agents still run.'
out=$(printf '%s' "$PW" | ( _lp_exec support-file ))
yes_ "P3 the panel answers ok with a file and a name" '[[ "$(jq -r .ok <<<"$out")" == true ]] && [[ "$(jq -r .data.name <<<"$out")" == 5dive-support-file-*.json ]]'
jq -j .data.file <<<"$out" >"$T/panel.json"
( cmd_bug --verb=support-file --what="$PW" --save="$T/direct.json" </dev/null ) >/dev/null 2>&1
if cmp -s "$T/panel.json" "$T/direct.json"; then ok_t "P4 the panel's file is BYTE-IDENTICAL to 5dive bug --save"; else fail_t "P4 panel file differs: $(diff "$T/panel.json" "$T/direct.json" | head -3)"; fi
chk "P5 the description reached cmd_bug as --what, verb support-file" "$PW/support-file" "$(jq -r .what "$T/panel.json")/$(jq -r .verb "$T/panel.json")"
chk "P6 the panel path never reached the transport or curl" "" "$(cat "$CALLS")"
AUD="$T/root/var/log/5dive/local-panel.log"
yes_ "P7 the call is audited, and the description is not in the audit line" 'grep -q "support-file" "$AUD" && ! grep -qF "Approvals tab" "$AUD"'
out=$(printf '   ' | ( _lp_exec support-file ))
chk "P8 an empty description gets marketing's line" "Describe the problem first." "$(jq -r .error <<<"$out")"
out=$(printf 'the key is %s' "$TOK" | ( _lp_exec support-file ))
chk "P9 token-shaped text gets marketing's line" "Remove the password or key from your text first." "$(jq -r .error <<<"$out")"
out=$(head -c 2001 /dev/zero | tr '\0' a | ( _lp_exec support-file ))
yes_ "P11 a description over 2000 characters is refused" '[[ "$(jq -r .ok <<<"$out")" == false ]]'
out=$(printf '{"argv":["support-file"],"device":"0011aabb"}\nfrom the socket' | ( _lp_exec --socket ))
yes_ "P12 the socket form: the description after the JSON line" '[[ "$(jq -r .ok <<<"$out")" == true ]] && [[ "$(jq -r .data.file <<<"$out" | jq -r .what)" == "from the socket" ]]'

# ── W. the page ───────────────────────────────────────────────────────────────
TS=$(_local_chat_server_ts)
yes_ "W1 the server routes POST /api/panel/support-file to the panel verb, description as input" \
  'grep -qF "panelExec([\"support-file\"], dev.id, what" <<<"$TS"'
for s in "Need help?" "No internet on this server? Save a support file, then attach it in Support in the 5dive app from any computer." \
         "What went wrong?" "Save support file" "Saved. Now attach it in Support in the 5dive app." "Describe the problem first." \
         "It holds this server&#39;s version and system details, its health checks and your text. Nothing else."; do
  yes_ "W2 marketing's words on the page: ${s:0:40}" 'grep -qF -- "$s" <<<"$TS"'
done
# The page's script must still parse: render the template literal, pull the
# <script>, and let node compile it (nothing runs).
printf '%s' "$TS" >"$T/server.ts"
if command -v node >/dev/null 2>&1; then
  node -e '
    const s = require("fs").readFileSync(process.argv[1], "utf8");
    const a = s.indexOf("const PANEL_PAGE = /*html*/ `"); if (a < 0) process.exit(3);
    const b = s.indexOf("</html>`;", a); const page = eval("`" + s.slice(s.indexOf("`", a) + 1, b) + "</html>`");
    const js = page.slice(page.indexOf("<script>") + 8, page.lastIndexOf("</script>"));
    new Function(js);
    if (!/Need help\?/.test(page) || !/id="sb"/.test(page)) process.exit(4);
  ' "$T/server.ts"; rc=$?
  chk "W3 the panel page renders and its script parses" 0 "$rc"
else
  fail_t "W3 node is needed to parse the page script"
fi

echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
