#!/usr/bin/env bash
# DIVE-7730: local-only mode silences the OTHER agent runtimes, not only Claude Code.
#
#   H1  the agent drop-in carries every runtime's own off-switch (pi, opencode,
#       openclaw), one Environment= line each
#   C1  `on` writes codex's managed config WITH the [features] table that stops
#       its plugin-catalog lookups (github.com, chatgpt.com — measured on codex
#       0.153.3 in a no-network sandbox: the DIVE-7557 file alone leaked both)
#   C2  a managed config WE wrote before (DIVE-7557 shape) is brought up to date
#   C3  an owner's own managed config is still never touched (control)
#   C4  `check` calls the old file a LEAK and the new one ok
#   M1  mutant: a check that looks only at check_for_update_on_startup passes the
#       old file — C4 must go red on it
#
# Seams as in local_only_unit.sh: a scratch root, systemctl/snap/ss PATH stubs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dive7730.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "PASS=$PASS FAIL=$FAIL"; echo "HARNESS-RC=$rc"' EXIT
export FIVE_LOCAL_ONLY_FILE="$TMPD/root/etc/5dive/local-only"
export FIVE_LOCAL_ONLY_ROOT="$TMPD/root"
export FIVE_LOCAL_ONLY_TICK=0
mkdir -p "$TMPD/root/etc/5dive" "$TMPD/bin" "$TMPD/units"
# shellcheck disable=SC1090
for f in lib/error_codes.sh lib/output.sh lib/local_only.sh cmd_local_only.sh; do source "src/$f"; done
require_root() { return 0; }
JSON_MODE=0
cat > "$TMPD/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
U="$STUB_UNITS"; echo "systemctl $*" >> "$U/.log"
case "$1" in
  is-enabled) [[ -f "$U/$2" ]] || { echo not-found; exit 4; }; s=$(cat "$U/$2"); echo "$s"; [[ $s == enabled ]] ;;
  disable) echo disabled > "$U/$3" ;;
  enable)  echo enabled  > "$U/$3" ;;
  *) exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "snap $*" >> "$STUB_UNITS/.log"\n' > "$TMPD/bin/snap"
printf '#!/usr/bin/env bash\ncat "$STUB_SS" 2>/dev/null\n' > "$TMPD/bin/ss"
chmod +x "$TMPD/bin/"*
export STUB_UNITS="$TMPD/units" STUB_SS="$TMPD/ss.txt" PATH="$TMPD/bin:$PATH"
: > "$TMPD/ss.txt"

# ── H1 ────────────────────────────────────────────────────────────────────────
body=$(_lo_dropin_body); n=0
for kv in PI_OFFLINE=1 PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 OPENCODE_DISABLE_AUTOUPDATE=1 \
          OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
          OPENCODE_DISABLE_DEFAULT_PLUGINS=1 OPENCLAW_NO_AUTO_UPDATE=1; do
  grep -qxF "Environment=$kv" <<<"$body" || { n=$((n+1)); echo "  missing: $kv"; }
done
(( n == 0 )) && ok_ "H1 the drop-in carries every runtime's off-switch (pi, opencode, openclaw)" || bad_ H1 "$n missing"

# ── C1 ────────────────────────────────────────────────────────────────────────
( _lo_on ) >"$TMPD/on.out" 2>&1
cx=$(_lo_codex)
grep -q '^\[features\]' "$cx" && grep -qx 'plugins = false' "$cx" && grep -qx 'remote_plugin = false' "$cx" \
  && grep -qx 'apps = false' "$cx" && grep -q 'check_for_update_on_startup = false' "$cx" \
  && ok_ "C1 on writes codex's managed config with plugins, remote plugins and apps off" || bad_ C1 "$(cat "$cx" 2>&1)"
check_says() { ( _lo_check --watch=0 --status ) 2>/dev/null | grep -E 'codex' ; }
grep -qE '^ok .*codex' <<<"$(check_says)" && ok_ "C4a check: the new file is ok" || bad_ C4a "$(check_says)"

# ── C2 / C4 ───────────────────────────────────────────────────────────────────
old=$(printf '%s\n' "$_LO_CODEX_MARK" "check_for_update_on_startup = false" "" "[analytics]" "enabled = false" "" "[feedback]" "enabled = false")
printf '%s\n' "$old" > "$cx"
grep -qE 'LEAK .*codex' <<<"$(check_says)" && ok_ "C4b check: the DIVE-7557 file (no [features]) is a LEAK" || bad_ C4b "$(check_says)"
( _lo_on ) >/dev/null 2>&1
grep -qx 'plugins = false' "$cx" && [[ $(grep -c "$_LO_CODEX_MARK" "$cx") == 1 ]] \
  && ok_ "C2 on brings a managed config we wrote before up to date (once)" || bad_ C2 "$(cat "$cx")"

# ── C3 ────────────────────────────────────────────────────────────────────────
( _lo_off ) >/dev/null 2>&1
[[ ! -e "$cx" ]] && ok_ "C2b off still removes the file it wrote" || bad_ C2b "left behind"
mkdir -p "$(dirname "$cx")"; printf 'model = "mine"\n' > "$cx"
( _lo_on; _lo_off ) >/dev/null 2>&1
[[ $(cat "$cx") == 'model = "mine"' ]] && ok_ "C3 an owner's own codex managed config is never touched" || bad_ C3 "$(cat "$cx")"
rm -f "$cx"

# ── M1 ────────────────────────────────────────────────────────────────────────
( _lo_on ) >/dev/null 2>&1; printf '%s\n' "$old" > "$cx"
mut=$(declare -f _lo_check | sed "s/&& grep -q '\^plugins \*= \*false' \"\$(_lo_codex)\"//")
if [[ "$mut" != "$(declare -f _lo_check)" ]]; then
  r=$( eval "$mut"; ( _lo_check --watch=0 --status ) 2>/dev/null | grep codex )
  grep -qE '^ok .*codex' <<<"$r" && ok_ "M1 mutant (check ignores [features]) passes the old file, so C4b is what catches it" || bad_ M1 "mutant did not pass: $r"
else bad_ M1 "mutation did not apply"; fi
( _lo_off ) >/dev/null 2>&1
(( FAIL == 0 ))
