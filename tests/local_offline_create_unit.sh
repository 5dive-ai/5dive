#!/usr/bin/env bash
# DIVE-7566 defect 7: `agent create --channels=dashboard` on a local-only box.
#
# It always cloned the plugin marketplace from GitHub, so once the box was
# offline the create failed (DIVE-7560 proof: four clone tries, then
# "dashboard plugin install failed"). With local-only on, the seat's checkout
# is now seeded from a copy the box holds and nothing dials out.
#
# Drives the REAL install_channel_plugin_for_agent, its heredoc script included,
# with the outside world as seams on PATH:
#   git     real git, except a clone/fetch/pull of an http(s) URL fails like a box with no network
#   claude  logs its argv; `plugin install` installs from the local catalog
#   npm     logs that it was called (offline it would fail)
# sudo/chown/id are functions (no root here). Every address is a file path.
#
#   O1-O8  local-only ON, no claude checkout: a one-plugin marketplace built
#          from the staged dashboard copy; no URL, no update/add, no npm,
#          packages copied, origin names GitHub, stage removed
#   O9-O11 local-only ON with the claude user's checkout: cloned from it
#   C1     control: local-only OFF takes the GitHub path (this harness's
#          offline git refuses it), i.e. the arms above are red on the old code
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/offline-create.XXXXXX")"
trap 'rc=$?; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
export FIVE_LOCAL_ONLY_FILE="$T/local-only"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/local_only.sh lib/agent_setup.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=0
REAL_GIT=$(command -v git)

# ── the outside world ────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/home"
LOG="$T/calls.log"; : >"$LOG"
cat >"$T/bin/git" <<EOF
#!/usr/bin/env bash
# Only a verb that DIALS fails; \`remote set-url <url>\` just writes config.
dials=0; for a in "\$@"; do case "\$a" in clone|fetch|pull|ls-remote|push) dials=1 ;; esac; done
for a in "\$@"; do
  case "\$a" in http://*|https://*) (( dials )) || continue
    echo "git-url \$*" >>"$LOG"; echo "fatal: unable to access '\$a': Could not resolve host" >&2; exit 128 ;; esac
done
exec "$REAL_GIT" "\$@"
EOF
cat >"$T/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >>"$LOG"; exit 1
EOF
cat >"$T/bin/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >>"$LOG"
case "\$1 \$2" in
  "plugin marketplace") exit 1 ;;   # update/add dial GitHub: offline they fail
  "plugin install")
    mkt="\$HOME/.claude/plugins/marketplaces/5dive-plugins"
    # DIVE-7574: what Claude Code sees when it runs bun install in the checkout.
    echo "claude-install-env REG=\${NPM_CONFIG_REGISTRY:-} CHECKOUT_PKGS=\$([ -f "\$mkt/plugins/dashboard/node_modules/dep/package.json" ] && echo yes || echo no)" >>"$LOG"
    dest="\$HOME/.claude/plugins/cache/5dive-plugins/dashboard/1"
    mkdir -p "\$dest" && cp -a "\$mkt/plugins/dashboard/." "\$dest/" || exit 1
    printf '{"version":2,"plugins":{"dashboard@5dive-plugins":[{"installPath":"%s"}]}}' "\$dest" \
      >"\$HOME/.claude/plugins/installed_plugins.json" ;;
esac
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export FIVEDIVE_CLAUDE_BIN="$T/bin/claude" TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

# The staged dashboard copy (install.sh puts it at /usr/local/lib/5dive/dashboard).
DASH="$T/staged-dashboard"
mkdir -p "$DASH/.claude-plugin" "$DASH/node_modules/dep"
printf 'console.log(1)\n' >"$DASH/server.ts"
printf '{"name":"dashboard","version":"0.5.25"}\n' >"$DASH/.claude-plugin/plugin.json"
printf '{"name":"d","scripts":{"start":"test -f /etc/5dive/local-only -a -d node_modules || bun install --no-summary; bun start.ts"},"dependencies":{"dep":"^1.0.0"}}\n' >"$DASH/package.json"
printf 'x\n' >"$DASH/node_modules/dep/index.js"
printf '{"name":"dep","version":"1.0.0"}\n' >"$DASH/node_modules/dep/package.json"
export FIVEDIVE_OFFLINE_DASHBOARD_DIR="$DASH"

id() { return 0; }
ensure_bun_for_agent() { return 0; }
chown() { return 0; }
sudo() {
  [[ "${1:-}" == -u ]] && shift 2
  [[ "${1:-}" == -H ]] && shift
  HOME="$SEAT_HOME" "$@"
}

run_install() {   # <seat home>
  SEAT_HOME="$1"; mkdir -p "$SEAT_HOME"
  ( install_channel_plugin_for_agent dashboard tap ) >"$T/out" 2>&1
}
MKT_OF() { printf '%s/.claude/plugins/marketplaces/5dive-plugins' "$1"; }

# ── O: local-only ON, no claude checkout → built from the staged copy ───────
touch "$FIVE_LOCAL_ONLY_FILE"
export FIVEDIVE_OFFLINE_MKT_SRC="$T/no-such-checkout"
: >"$LOG"; run_install "$T/home/a"; rc=$?
M=$(MKT_OF "$T/home/a")
[[ $rc == 0 ]] && ok_ 'O1 local-only on: the dashboard install succeeds with no network' || bad_ 'O1 install rc' "rc=$rc $(tail -5 "$T/out")"
! grep -q '^git-url' "$LOG" && ok_ 'O2 no git call names a URL (nothing to GitHub)' || bad_ 'O2 a URL was dialled' "$(grep '^git-url' "$LOG")"
! grep -q '^claude plugin marketplace' "$LOG" && ok_ 'O3 no marketplace update/add (they dial GitHub)' || bad_ 'O3 marketplace update/add ran' "$(grep marketplace "$LOG")"
grep -q '^claude plugin install dashboard@5dive-plugins' "$LOG" && ok_ 'O4 the plugin is installed from the local catalog' || bad_ 'O4 plugin install' "$(cat "$LOG")"
! grep -q '^npm' "$LOG" && ok_ 'O5 no npm install offline' || bad_ 'O5 npm ran' "$(grep npm "$LOG")"
PD="$T/home/a/.claude/plugins/cache/5dive-plugins/dashboard/1"
[[ -f "$PD/node_modules/dep/index.js" ]] && ok_ 'O6 packages copied from the staged copy' || bad_ 'O6 node_modules' "$(ls -la "$PD" 2>&1)"
[[ "$(git -C "$M" remote get-url origin 2>/dev/null)" == "https://github.com/$(gh_org)/5dive-plugins.git" \
   && -f "$M/.claude-plugin/marketplace.json" && -f "$M/plugins/dashboard/server.ts" ]] \
  && ok_ 'O7 the checkout is a marketplace whose origin names GitHub (a later online update works)' \
  || bad_ 'O7 checkout shape' "origin=$(git -C "$M" remote get-url origin 2>&1)"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok_ 'O8 the stage dir is removed' || bad_ 'O8 stage left' "$(ls -A "$TMPDIR")"
# DIVE-7574 (N1): Claude Code runs a directory-source plugin IN PLACE, from the checkout.
grep -q 'claude-install-env .*CHECKOUT_PKGS=yes' "$LOG" && [[ -f "$M/plugins/dashboard/node_modules/dep/package.json" ]] \
  && ok_ 'N1a the checkout Claude Code runs the plugin from has its packages, BEFORE plugin install' \
  || bad_ 'N1a checkout packages' "$(grep claude-install-env "$LOG") / $(ls -la "$M/plugins/dashboard" 2>&1)"
# DIVE-7574 (N2): plugin install's own `bun install` looks up the npm registry unless pointed here.
grep -q 'claude-install-env REG=http://127.0.0.1:9/ ' "$LOG" \
  && ok_ 'N2a plugin install runs with the npm registry on this box (no registry lookup)' \
  || bad_ 'N2a registry env' "$(grep claude-install-env "$LOG")"
# The self-check reads what the owner will see: a chat that can start.
FIVEDIVE_AGENT_HOME_ROOT="$T/selfcheck"; mkdir -p "$T/selfcheck"; ln -sfn "$T/home/a" "$T/selfcheck/agent-tap"
printf '{"%s":{"source":{"source":"directory","path":"%s"}}}' 5dive-plugins "$M" >"$T/home/a/.claude/plugins/known_marketplaces.json"
export FIVEDIVE_AGENT_HOME_ROOT
eval "$(sed -n '/^selfcheck_chat_plugin_ready() {/,/^}/p' src/cmd_agent_create.sh)"
[[ "$(selfcheck_chat_plugin_ready tap dashboard)" == ok:* ]] && ok_ 'SC1 self-check: chat plugin can start' \
  || bad_ 'SC1 selfcheck ok' "$(selfcheck_chat_plugin_ready tap dashboard)"
rm -rf "$M/plugins/dashboard/node_modules"; mkdir "$M/plugins/dashboard/node_modules"   # what a blocked first start leaves
[[ "$(selfcheck_chat_plugin_ready tap dashboard)" == "issue:dashboard chat plugin CANNOT START"* ]] \
  && ok_ 'SC2 self-check: an empty node_modules where Claude Code runs it is an issue, never PASS (run 3 printed PASS)' \
  || bad_ 'SC2 selfcheck empty' "$(selfcheck_chat_plugin_ready tap dashboard)"
# N1b: a second install (or an existing seat) with that empty folder gets it refilled.
: >"$LOG"; run_install "$T/home/a"; rc=$?
[[ $rc == 0 && -f "$M/plugins/dashboard/node_modules/dep/package.json" ]] && grep -q 'CHECKOUT_PKGS=yes' "$LOG" \
  && ok_ 'N1b an EMPTY node_modules (a failed start) in the checkout is replaced, not taken as installed' \
  || bad_ 'N1b refill' "rc=$rc $(grep claude-install-env "$LOG")"
printf '{"plugin:dashboard:dashboard":{"timestamp":1}}' >"$T/home/a/.claude/mcp-needs-auth-cache.json"
[[ "$(selfcheck_chat_plugin_ready tap dashboard)" == "issue:dashboard chat plugin FAILED to start"* ]] \
  && ok_ "SC3 self-check: Claude Code's cached start failure is an issue" || bad_ 'SC3 selfcheck cache' "$(selfcheck_chat_plugin_ready tap dashboard)"
rm -f "$T/home/a/.claude/mcp-needs-auth-cache.json"
# N1c: an EXISTING seat switched by `local-only on` (seat_marketplaces_local) gets its checkout filled.
H2="$T/home/b"; M2=$(MKT_OF "$H2"); C2="$H2/.claude/plugins/cache/5dive-plugins/dashboard/0.5.0"
mkdir -p "$M2/.claude-plugin" "$M2/plugins/dashboard" "$C2/node_modules/dep"
cp "$DASH/package.json" "$M2/plugins/dashboard/"; cp "$DASH/package.json" "$C2/"
printf '{"name":"dep","from":"cache"}\n' >"$C2/node_modules/dep/package.json"
printf '{"name":"5dive-plugins","plugins":[{"name":"dashboard","source":"./plugins/dashboard"}]}' >"$M2/.claude-plugin/marketplace.json"
printf '{"version":2,"plugins":{"dashboard@5dive-plugins":[{"installPath":"%s"}]}}' "$C2" >"$H2/.claude/plugins/installed_plugins.json"
printf '{"5dive-plugins":{"source":{"source":"github","repo":"5dive-ai/5dive-plugins"},"installLocation":"%s"}}' "$M2" >"$H2/.claude/plugins/known_marketplaces.json"
printf '{"x":1}' >"$H2/.claude/mcp-needs-auth-cache.json"
seat_marketplaces_local "$H2" on 2>"$T/sml.err"
grep -q '"from":"cache"' "$M2/plugins/dashboard/node_modules/dep/package.json" 2>/dev/null && [[ ! -e "$H2/.claude/mcp-needs-auth-cache.json" ]] && [[ ! -s "$T/sml.err" ]] \
  && ok_ "N1c local-only on: an existing seat's checkout gets its own cache copy's packages; failure cache dropped" \
  || bad_ 'N1c existing seat' "$(cat "$T/sml.err") $(ls -la "$M2/plugins/dashboard" 2>&1)"

# ── O9-O11: the claude user's own checkout is preferred ─────────────────────
SRC="$T/claude-checkout"
mkdir -p "$SRC/.claude-plugin" "$SRC/plugins/dashboard"
printf '{"name":"5dive-plugins","plugins":[{"name":"dashboard","source":"./plugins/dashboard"}]}\n' >"$SRC/.claude-plugin/marketplace.json"
cp -a "$DASH/server.ts" "$DASH/package.json" "$DASH/.claude-plugin" "$SRC/plugins/dashboard/"
"$REAL_GIT" -C "$SRC" init -q && "$REAL_GIT" -C "$SRC" add -A \
  && "$REAL_GIT" -C "$SRC" -c user.name=t -c user.email=t@example.com commit -qm "claude's checkout"
export FIVEDIVE_OFFLINE_MKT_SRC="$SRC"
: >"$LOG"; run_install "$T/home/b"; rc=$?
M=$(MKT_OF "$T/home/b")
[[ $rc == 0 ]] && ok_ "O9 with the claude user's checkout: succeeds" || bad_ 'O9 rc' "rc=$rc $(tail -5 "$T/out")"
[[ "$(git -C "$M" rev-parse HEAD 2>/dev/null)" == "$("$REAL_GIT" -C "$SRC" rev-parse HEAD)" ]] \
  && ok_ "O10 the seat's checkout is that checkout's commit" || bad_ 'O10 HEAD' "$(git -C "$M" log -1 --oneline 2>&1)"
! grep -q '^git-url\|^claude plugin marketplace\|^npm' "$LOG" && ok_ 'O11 still nothing dialled' || bad_ 'O11 dialled' "$(cat "$LOG")"

# ── C1: control — local-only OFF is the GitHub path, refused by this offline git
rm -f "$FIVE_LOCAL_ONLY_FILE"
marketplace_checkout_settled() { git clone -q --depth 1 "$1" "$2"; }   # one try, not four
: >"$LOG"; run_install "$T/home/c"; rc=$?
if (( rc != 0 )) && grep -q '^git-url' "$LOG"; then ok_ 'C1 control: without local-only the install dials GitHub and fails offline (the old behaviour, on every box)'
else bad_ 'C1 control' "rc=$rc $(cat "$LOG")"; fi

# ── P1: bash 5.1 (Ubuntu 22.04) reads a heredoc body from the line right after
# the `<<` line, so a `\`-continued pipe below it is swallowed as script text and
# the install runs nothing (and a non-`then` command after the terminator breaks
# the whole bundle's parse). The seat pipeline must sit on the heredoc's line.
hd=$(grep -n "cat <<'AGENT_PLUGIN_INSTALL'" src/lib/agent_setup.sh)
if [[ -n "$hd" && "$hd" != *'\' && "$hd" == *'| "${seat_sh[@]}"'* ]]; then
  ok_ 'P1 the seat pipeline is on the heredoc line (bash 5.1 would swallow a continued one)'
else bad_ 'P1 heredoc line' "$hd"; fi

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
