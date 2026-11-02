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
printf '{"name":"d","scripts":{"start":"test -f /etc/5dive/local-only -a -d node_modules || bun install --no-summary; bun start.ts"}}\n' >"$DASH/package.json"
printf 'x\n' >"$DASH/node_modules/dep/index.js"
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
   && -f "$M/.claude-plugin/marketplace.json" && -f "$M/plugins/dashboard/server.ts" && ! -e "$M/plugins/dashboard/node_modules" ]] \
  && ok_ 'O7 the checkout is a marketplace whose origin names GitHub (a later online update works)' \
  || bad_ 'O7 checkout shape' "origin=$(git -C "$M" remote get-url origin 2>&1)"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok_ 'O8 the stage dir is removed' || bad_ 'O8 stage left' "$(ls -A "$TMPDIR")"

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
