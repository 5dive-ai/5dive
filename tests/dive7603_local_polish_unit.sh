#!/usr/bin/env bash
# DIVE-7603: small issues from the fully-local run-6 proof (DIVE-7578). Each arm
# group fails on the tree before the fix (v0.116.0).
#
#   N2 a disk update keeps every plugin's packages (node_modules) out of a
#      seat checkout's history — the first one committed 41,682 files (+38 MB)
#      into a checkout built offline with no .gitignore; packages an earlier
#      update committed leave the index; "nothing changed" still owes no restart.
#   N3 the panel's update install keeps what it printed: the whole output in
#      install.log, its last lines in the status the Update card reads.
#   N4 the guide saves the office AI BEFORE `local-only on` (on a two-network
#      box the chat page picks the office network only then).
#   n5's arms (no terminal flag in the panel's refusal) are in
#   tests/self_update_offline_unit.sh, beside the refusal they guard.
#
# No network, no root, no systemd.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dive7603.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
g() { git -c safe.directory='*' -C "$@"; }

# ── N2. packages stay out of a seat checkout's history ──────────────────────
source src/lib/offline_update.sh; set +e
# The checkout agent_setup's offline fallback builds: git init, no .gitignore.
co="$TMPD/co"; mkdir -p "$co/.claude-plugin" "$co/plugins/dashboard"
printf '{}\n' >"$co/.claude-plugin/marketplace.json"; printf 'v1\n' >"$co/plugins/dashboard/server.ts"
g "$co" init -q && g "$co" add -A && g "$co" -c user.name=t -c user.email=t@example.com commit -qm init
src="$TMPD/upd"; mkdir -p "$src/.claude-plugin" "$src/plugins/dashboard/node_modules/@m/sdk" "$src/plugins/buzz/node_modules/x"
cp "$co/.claude-plugin/marketplace.json" "$src/.claude-plugin/"
printf 'v2\n' >"$src/plugins/dashboard/server.ts"; printf 'b\n' >"$src/plugins/buzz/server.ts"
printf 'pkg\n' >"$src/plugins/dashboard/node_modules/@m/sdk/index.js"; printf 'pkg\n' >"$src/plugins/buzz/node_modules/x/index.js"
_ou_refresh_checkout "$src" "$co"; r=$?
check 'N2a the update commits its plugin code (rc 0, one new commit)' '(( r == 0 )) && (( $(g "$co" rev-list --count HEAD) == 2 )) && g "$co" ls-files --error-unmatch plugins/buzz/server.ts'
check 'N2b no node_modules file is in the commit' '[[ -z "$(g "$co" ls-tree -r --name-only HEAD | grep node_modules)" ]]'
check 'N2c the packages are still on disk for the seat to run' '[[ -f "$co/plugins/dashboard/node_modules/@m/sdk/index.js" ]]'
check 'N2d the exclude is local to the checkout (.git/info/exclude), never committed' 'grep -qx "node_modules/" "$co/.git/info/exclude" && ! g "$co" ls-files --error-unmatch .gitignore'
_ou_refresh_checkout "$src" "$co"; r=$?
check 'N2e the same update again: rc 3 (no restart owed), no commit' '(( r == 3 )) && (( $(g "$co" rev-list --count HEAD) == 2 ))'
# A checkout an earlier update already filled (the v0.116.0 shape).
co2="$TMPD/co2"; cp -a "$co" "$co2"; rm -f "$co2/.git/info/exclude"
g "$co2" add -f plugins/dashboard/node_modules && g "$co2" -c user.name=t -c user.email=t@example.com commit -qm "old update"
_ou_refresh_checkout "$src" "$co2"; r=$?
check 'N2f packages an earlier update committed leave the index; the files stay on disk' '(( r == 0 )) && [[ -z "$(g "$co2" ls-files | grep node_modules)" ]] && [[ -f "$co2/plugins/dashboard/node_modules/@m/sdk/index.js" ]]'

# ── N3. the panel update keeps its install output ──────────────────────────
# The subshell only RUNS the install (it sources the panel's code, which must
# not leak into this shell); every check runs here, so PASS/FAIL never leave
# this shell. A dead subshell leaves no install.log/status.json: N3a-c go red.
# shellcheck disable=SC2034  # st is read inside the check strings
d="$TMPD/root/var/lib/5dive/panel-update"; st="$d/status.json"
(
  set +u
  . src/lib/error_codes.sh 2>/dev/null; . src/lib/output.sh 2>/dev/null
  source src/cmd_local_chat.sh; source src/cmd_local_panel.sh; set +e
  export FIVE_LOCAL_CHAT_ROOT="$TMPD/root" FIVE_PANEL_CLI="$TMPD/fake5dive"
  mkdir -p "$TMPD/root"
  cat >"$FIVE_PANEL_CLI" <<'CLI'
#!/usr/bin/env bash
[[ "$*" == *--version* ]] && { echo '{"ok":true,"data":{"version":"9.9.9"}}'; exit 0; }
for i in 1 2 3 4 5 6; do echo "==> stage $i" >&2; done
echo "! failed to stage /usr/local/lib/5dive/dashboard" >&2
echo "panel=${FIVEDIVE_PANEL_UPDATE:-unset}" >&2
echo "line after the warning" >&2
echo '{"ok":true,"data":null}'
CLI
  chmod +x "$FIVE_PANEL_CLI"
  require_root() { :; }; _lp_audit() { :; }
  [[ "$(_lp_update_dir)" == "$d" ]] || exit 1
  install -d "$d"; printf 'x' >"$d/update.tar"
  _lp_update_run
) >/dev/null 2>&1
check 'N3a the whole install output is kept (install.log, 0600)' '[[ "$(grep -c "" "$d/install.log")" == 9 && "$(stat -c %a "$d/install.log")" == 600 ]]'
check 'N3b the status the Update card reads carries the warning, not just the last 3 lines' 'jq -e ".state == \"done\" and (.log | contains(\"failed to stage\")) and (.log | contains(\"stage 1\"))" "$st"'
check 'N3c the install runs marked as the panel (so its refusals name no terminal flag)' 'jq -e ".log | contains(\"panel=1\")" "$st"'
pg=src/cmd_local_chat_server.sh
check 'N3e the Update card shows what the last install said, also after a reload' 'grep -q "What the last install said" "$pg" && grep -q "else if (u && u.state !== \"none\") updateDone(u)" "$pg"'
check 'N3f the page promises no agent restart before the verdict (a refusal restarts nothing)' '! grep -q "Agents restart once" "$pg"'

# ── N4. the guide's order works on a two-network box ───────────────────────
gd=docs/guide.md
sec=$(sed -n '/^## Local-only mode/,/^### Updates by disk/p' "$gd")
# shellcheck disable=SC2034  # read inside the check strings
acc=$(grep -n 'account add office-ai' <<<"$sec" | head -1 | cut -d: -f1)
# shellcheck disable=SC2034
on=$(grep -n 'config local-only on' <<<"$sec" | head -1 | cut -d: -f1)
check 'N4a the guide saves the office AI before it turns local-only on' '[[ -n "$acc" && -n "$on" ]] && (( acc < on ))'
check 'N4b it says how to start the chat page when the order was the other way' 'grep -q "local serve --addr=<office IP>" <<<"$sec"'

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
