#!/usr/bin/env bash
# DIVE-7573: a fully-local box still dialed out (DIVE-7560 run 2: 494 dropped
# outbound tries in 38 min, `local-only check` red). One arm per defect, each red
# on the pre-fix tree; the controls prove the online path is unchanged.
#
#   D1  G1-G3   gh_org never probes GitHub with local-only on (control: it does off)
#   D2  Q1-Q4   every Claude Code run 5dive makes as a seat carries the quiet env
#               (the create-time plugin install, plugin registration, the mod
#               probe); nothing extra with the switch off
#   D3  M1-M8   no GitHub marketplace for a local-only seat: the preseed names
#               none, the install registers the box's copy as a `directory`
#               marketplace, `local-only on` rewrites existing seats and `off`
#               puts them back, and `check` names a seat that still has one
#   D4  T1-T5   tool search off for a custom-endpoint profile (never for a
#               catalog vendor, never over the operator's own value) and in the
#               local-only drop-in, which `on` rewrites on a box that has the old one
#   DIVE-7624 Q5-Q9  a custom-endpoint profile (also via the Your-own-AI save)
#               gets DISABLE_TELEMETRY + DISABLE_ERROR_REPORTING with local-only
#               OFF; never a catalog vendor, never over the operator's own value
#
# Seams: curl/git/claude/systemctl are PATH stubs, sudo/chown/id are functions;
# no root, no network, no real seat. Every path is under a temp dir; the custom
# endpoint is an example.com name (any URL outside the vendor catalog is custom).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dive7573.XXXXXX")"
trap 'rc=$?; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
export FIVE_LOCAL_ONLY_FILE="$T/local-only"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh lib/local_only.sh \
         lib/agent_setup.sh lib/plugin_seats.sh lib/mod_seat.sh cmd_agent_create.sh cmd_local_only.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=0
REAL_GIT=$(command -v git)
CUSTOM_URL="https://llm.example.com/anthropic"
on()  { touch "$FIVE_LOCAL_ONLY_FILE"; unset _GH_ORG_RESOLVED; }
off() { rm -f "$FIVE_LOCAL_ONLY_FILE"; unset _GH_ORG_RESOLVED; }
step() { :; }
warn() { :; }

mkdir -p "$T/bin" "$T/home" "$T/tmp"
LOG="$T/calls.log"; : >"$LOG"
cat >"$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >>"$LOG"; exit 7
EOF
cat >"$T/bin/git" <<EOF
#!/usr/bin/env bash
dials=0; for a in "\$@"; do case "\$a" in clone|fetch|pull|ls-remote|push) dials=1 ;; esac; done
for a in "\$@"; do
  case "\$a" in http://*|https://*) (( dials )) || continue
    echo "git-url \$*" >>"$LOG"; exit 128 ;; esac
done
exec "$REAL_GIT" "\$@"
EOF
# claude logs its argv AND the three quiet variables it was given.
cat >"$T/bin/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$* | NET=\${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-} AU=\${DISABLE_AUTOUPDATER:-} OFF=\${CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL:-}" >>"$LOG"
case "\$1 \$2" in
  "plugin marketplace") exit 1 ;;
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
export FIVEDIVE_CLAUDE_BIN="$T/bin/claude" TMPDIR="$T/tmp"

# ── D1: gh_org ───────────────────────────────────────────────────────────────
unset GH_ORG
on;  : >"$LOG"; org=$(gh_org)
[[ "$org" == 5dive-ai ]] && ! grep -q '^curl' "$LOG" \
  && ok_ 'G1 local-only on: gh_org = 5dive-ai with no GitHub probe' \
  || bad_ 'G1 gh_org on' "org=$org calls=$(cat "$LOG")"
off; : >"$LOG"; org=$(gh_org)
[[ "$org" == 5dive-com ]] && grep -q 'raw.githubusercontent.com' "$LOG" \
  && ok_ 'G2 control: switch off still probes (offline it falls back to 5dive-com)' \
  || bad_ 'G2 gh_org off' "org=$org calls=$(cat "$LOG")"

# ── the create-time plugin install (real function, heredoc included) ────────
DASH="$T/staged-dashboard"
mkdir -p "$DASH/.claude-plugin" "$DASH/node_modules/dep"
printf 'console.log(1)\n' >"$DASH/server.ts"
printf '{"name":"dashboard","version":"0.5.26"}\n' >"$DASH/.claude-plugin/plugin.json"
printf '{"name":"d","scripts":{"start":"bun start.ts"}}\n' >"$DASH/package.json"
export FIVEDIVE_OFFLINE_DASHBOARD_DIR="$DASH" FIVEDIVE_OFFLINE_MKT_SRC="$T/no-such-checkout"
id() { return 0; }
ensure_bun_for_agent() { return 0; }
chown() { return 0; }
sudo() {
  [[ "${1:-}" == -u ]] && shift 2
  [[ "${1:-}" == -H ]] && shift
  HOME="$SEAT_HOME" "$@"
}
on; : >"$LOG"
SEAT_HOME="$T/home/a"; mkdir -p "$SEAT_HOME/.claude"
printf '{"model":"qwen3:8b"}\n' >"$SEAT_HOME/.claude/settings.json"   # what the local-only preseed writes
( install_channel_plugin_for_agent dashboard tap ) >"$T/out" 2>&1; rc=$?
M="$SEAT_HOME/.claude/plugins/marketplaces/5dive-plugins"
inst=$(grep '^claude plugin install' "$LOG")
[[ $rc == 0 && "$inst" == *'NET=1 AU=1 OFF=1'* ]] \
  && ok_ 'Q1 create-time plugin install runs Claude Code with all three quiet variables' \
  || bad_ 'Q1 install env' "rc=$rc $inst $(tail -3 "$T/out")"
jq -e --arg m "$M" '."5dive-plugins".source == {source: "directory", path: $m} and ."5dive-plugins".installLocation == $m' \
  "$SEAT_HOME/.claude/plugins/known_marketplaces.json" >/dev/null \
  && ok_ 'M1 the seat knows 5dive-plugins as a directory marketplace (its own checkout), not GitHub' \
  || bad_ 'M1 known_marketplaces' "$(cat "$SEAT_HOME/.claude/plugins/known_marketplaces.json" 2>&1)"
jq -e --arg m "$M" '.extraKnownMarketplaces == {"5dive-plugins": {source: {source: "directory", path: $m}}} and .model == "qwen3:8b"' \
  "$SEAT_HOME/.claude/settings.json" >/dev/null \
  && ok_ 'M2 its settings name only that directory marketplace (and keep everything else)' \
  || bad_ 'M2 settings' "$(cat "$SEAT_HOME/.claude/settings.json")"
[[ "$(git -C "$M" remote get-url origin 2>/dev/null)" == https://github.com/5dive-ai/5dive-plugins.git ]] \
  && ok_ 'G3 the checkout origin names the current org (5dive-ai), not 5dive-com' \
  || bad_ 'G3 origin' "$(git -C "$M" remote get-url origin 2>&1)"

# Q2/Q3: the other two ways 5dive runs Claude Code as a seat.
sudo() { printf 'SUDO %s\n' "$*" >>"$LOG"; cat >/dev/null; return 0; }
on;  : >"$LOG"; plugin_seat_run_as agent-x PLUGIN=p </dev/null; mod_seat_probe_run x "$T/dbg"
n=$(grep -c 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1' "$LOG")
[[ $n == 2 ]] && ok_ 'Q2 plugin registration and the mod probe pass the quiet env as the seat' \
  || bad_ 'Q2 seat runs' "matched $n of 2: $(cat "$LOG")"
off; : >"$LOG"; plugin_seat_run_as agent-x PLUGIN=p </dev/null; mod_seat_probe_run x "$T/dbg"
! grep -q 'DISABLE_' "$LOG" && grep -q 'SUDO -u agent-x -H env PLUGIN=p bash -s' "$LOG" \
  && ok_ 'Q3 control: switch off adds nothing (online behaviour byte for byte)' \
  || bad_ 'Q3 off' "$(cat "$LOG")"
on; [[ -n "${LOCAL_ONLY_CLAUDE_ENV[*]:-}" && "$(local_only_claude_env | paste -sd' ')" == "${LOCAL_ONLY_CLAUDE_ENV[*]}" ]]; a=$?
off; [[ -z "$(local_only_claude_env)" ]]; b=$?
(( a == 0 && b == 0 )) && ok_ 'Q4 local_only_claude_env: the list when on, nothing when off' || bad_ 'Q4 helper' "on=$a off=$b"

# ── D3: the preseed ──────────────────────────────────────────────────────────
pre_agent="dive7573-${BASHPID}"
fail() { [[ "$*" == *"agent home missing: /home/agent-${pre_agent}"* ]] && return 0; printf 'unexpected fail(): %s\n' "$*" >&2; return 1; }
sudo() {
  if [[ "$*" == *"tee /home/agent-${pre_agent}/.claude/settings.json"* ]]; then cat >"$T/preseed.json"
  elif [[ "$*" == *'tee '* ]]; then cat >/dev/null; fi
  return 0
}
chmod() { :; }
install_default_skill_for_agent() { :; }
on;  preseed_claude_agent "$pre_agent" dashboard qwen3:8b low >/dev/null 2>&1
jq -e 'has("extraKnownMarketplaces") | not' "$T/preseed.json" >/dev/null \
  && jq -e '.enabledPlugins["dashboard@5dive-plugins"] == true' "$T/preseed.json" >/dev/null \
  && ok_ 'M3 local-only preseed names no GitHub marketplace (the plugin stays enabled)' \
  || bad_ 'M3 preseed on' "$(jq -c '.extraKnownMarketplaces' "$T/preseed.json" 2>&1)"
off; preseed_claude_agent "$pre_agent" dashboard qwen3:8b low >/dev/null 2>&1
jq -e '.extraKnownMarketplaces["5dive-plugins"].source.source == "github" and .extraKnownMarketplaces["claude-plugins-official"].source.repo == "anthropics/claude-plugins-official"' \
  "$T/preseed.json" >/dev/null \
  && ok_ 'M4 control: switch off keeps both GitHub marketplaces' \
  || bad_ 'M4 preseed off' "$(jq -c '.extraKnownMarketplaces' "$T/preseed.json" 2>&1)"
unset -f chmod sudo fail

# ── D3: existing seats, on/off/check ────────────────────────────────────────
H="$T/root/home/agent-ada"; MK="$H/.claude/plugins/marketplaces"
mkdir -p "$MK/5dive-plugins"     # a checkout for ours; none for the official one
cat >"$H/.claude/settings.json" <<'EOF'
{"model":"m","extraKnownMarketplaces":{
  "claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"}},
  "5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"}}}}
EOF
cat >"$H/.claude/plugins/known_marketplaces.json" <<EOF
{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"},"installLocation":"$MK/claude-plugins-official"},
 "5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"},"installLocation":"$MK/5dive-plugins"}}
EOF
command chmod 600 "$H/.claude/settings.json"
export FIVE_LOCAL_ONLY_ROOT="$T/root"
before=$(_lo_seat_remote_mkts "$H")
seat_marketplaces_local "$H" on
jq -e --arg m "$MK/5dive-plugins" '.extraKnownMarketplaces == {"5dive-plugins": {source: {source: "directory", path: $m}}} and .model == "m"' "$H/.claude/settings.json" >/dev/null \
  && jq -e --arg m "$MK/5dive-plugins" '(keys == ["5dive-plugins"]) and ."5dive-plugins".source.source == "directory" and ."5dive-plugins".installLocation == $m' "$H/.claude/plugins/known_marketplaces.json" >/dev/null \
  && [[ "$(stat -c %a "$H/.claude/settings.json")" == 600 ]] \
  && ok_ 'M5 local-only on, existing seat: ours points at its checkout, the official one (no checkout) is dropped, mode kept' \
  || bad_ 'M5 seat on' "$(cat "$H/.claude/settings.json" "$H/.claude/plugins/known_marketplaces.json")"
after=$(_lo_seat_remote_mkts "$H")
[[ "$before" == "5dive-plugins,claude-plugins-official" && -z "$after" ]] \
  && ok_ 'M6 check names the remote marketplaces before, none after' \
  || bad_ 'M6 check' "before=$before after=$after"
off; export GH_ORG=5dive-ai
seat_marketplaces_local "$H" off
jq -e '.extraKnownMarketplaces["5dive-plugins"].source == {source: "github", repo: "5dive-ai/5dive-plugins"} and .extraKnownMarketplaces["claude-plugins-official"].source.source == "github"' "$H/.claude/settings.json" >/dev/null \
  && jq -e '."5dive-plugins".source == {source: "github", repo: "5dive-ai/5dive-plugins"}' "$H/.claude/plugins/known_marketplaces.json" >/dev/null \
  && ok_ 'M7 local-only off puts both back on GitHub, as an online create writes them' \
  || bad_ 'M7 seat off' "$(cat "$H/.claude/settings.json" "$H/.claude/plugins/known_marketplaces.json")"
unset GH_ORG

# ── D4 + the `on` pass end to end, under a mocked root ──────────────────────
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == is-enabled ]] && { echo disabled; exit 1; }
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/snap"; command chmod +x "$T/bin/systemctl" "$T/bin/snap"
require_root() { return 0; }
cat >"$H/.claude/settings.json" <<'EOF'
{"extraKnownMarketplaces":{"5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"}}}}
EOF
DI=$(_lo_dropin); mkdir -p "$(dirname "$DI")"
printf '%s\n' "# 5dive local-only (DIVE-7557)" "[Service]" "Environment=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "Environment=DISABLE_AUTOUPDATER=1" >"$DI"
( _lo_on ) >"$T/on.out" 2>&1; rc=$?
grep -qx 'Environment=ENABLE_TOOL_SEARCH=false' "$DI" && grep -qx 'Environment=CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1' "$DI" \
  && grep -qx 'Environment=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$DI" && [[ $rc == 0 ]] \
  && ok_ 'T1 local-only on rewrites an old drop-in: tool search off + the official-marketplace switch' \
  || bad_ 'T1 drop-in' "rc=$rc $(cat "$DI") $(tail -3 "$T/on.out")"
[[ -z "$(_lo_seat_remote_mkts "$H")" ]] && grep -qx 'seat-marketplaces' "$(_lo_undo)" \
  && ok_ 'M8 local-only on rewrites every existing seat and records it for off' \
  || bad_ 'M8 on pass' "$(_lo_seat_remote_mkts "$H") / $(cat "$(_lo_undo)" 2>&1)"
unset FIVE_LOCAL_ONLY_ROOT

# _apply_byo_claude: the profile writes, captured.
cap="$T/profile.cap"; : >"$cap"
profile_set_var() { local v; v=$(cat); printf '%s %s=%s\n' "$1" "$2" "$v" >>"$cap"; }
fail() { printf 'FAIL[%s] %s\n' "$1" "$2" >&2; exit "$1"; }
PROFILE_ENV_SEED=""
profile_env_value() { [[ "$2" == ENABLE_TOOL_SEARCH ]] && printf '%s' "$PROFILE_ENV_SEED"; return 0; }
( _apply_byo_claude custom k office-llm qwen3:8b "$CUSTOM_URL" ) >/dev/null 2>&1
grep -qx 'office-llm ENABLE_TOOL_SEARCH=false' "$cap" \
  && ok_ 'T2 a custom endpoint profile gets ENABLE_TOOL_SEARCH=false' || bad_ 'T2 custom' "$(cat "$cap")"
: >"$cap"; ( _apply_byo_claude openrouter sk-or-x or-prof "" ) >/dev/null 2>&1
grep -q 'ANTHROPIC_BASE_URL' "$cap" && ! grep -q ENABLE_TOOL_SEARCH "$cap" \
  && ok_ 'T3 a catalog vendor (openrouter) is left alone' || bad_ 'T3 catalog' "$(cat "$cap")"
: >"$cap"; PROFILE_ENV_SEED=true; ( _apply_byo_claude custom k office-llm qwen3:8b "$CUSTOM_URL" ) >/dev/null 2>&1
grep -q 'ANTHROPIC_BASE_URL' "$cap" && ! grep -q ENABLE_TOOL_SEARCH "$cap" \
  && ok_ "T4 an operator's own ENABLE_TOOL_SEARCH is never overwritten" || bad_ 'T4 operator value' "$(cat "$cap")"
[[ "$(_lo_dropin_body | grep -c '^Environment=')" == 15 ]] \
  && ok_ 'T5 the drop-in body is the three env lists (Claude 4 + other runtimes 10 + tool search 1, DIVE-7730), one Environment= line each' || bad_ 'T5 body' "$(_lo_dropin_body)"


# ── DIVE-7624: no usage stats or error reports from a custom-endpoint seat, ──
# on ANY box (local-only off here). Q5-Q7 are red on the pre-fix tree.
rm -f "$FIVE_LOCAL_ONLY_FILE"
declare -A SEED=()
profile_env_value() { printf '%s' "${SEED[$2]:-}"; return 0; }
quiet_both() { grep -qx "$1 DISABLE_TELEMETRY=1" "$cap" && grep -qx "$1 DISABLE_ERROR_REPORTING=1" "$cap"; }
: >"$cap"; ( _apply_byo_claude custom k office-llm qwen3:8b "$CUSTOM_URL" ) >/dev/null 2>&1
quiet_both office-llm && ! grep -q DISABLE_AUTOUPDATER "$cap" && ! grep -q NONESSENTIAL "$cap" \
  && ok_ 'Q5 a custom endpoint profile gets DISABLE_TELEMETRY=1 + DISABLE_ERROR_REPORTING=1, updates left on (local-only off)' \
  || bad_ 'Q5 custom quiet' "$(cat "$cap")"
: >"$cap"; ( _apply_byo_claude openrouter sk-or-x or-prof "" ) >/dev/null 2>&1
grep -q 'ANTHROPIC_BASE_URL' "$cap" && ! grep -q 'DISABLE_TELEMETRY\|DISABLE_ERROR_REPORTING' "$cap" \
  && ok_ 'Q6 a catalog vendor (openrouter) gets neither' || bad_ 'Q6 catalog quiet' "$(cat "$cap")"
: >"$cap"; SEED[DISABLE_TELEMETRY]=0
( _apply_byo_claude custom k office-llm qwen3:8b "$CUSTOM_URL" ) >/dev/null 2>&1
! grep -q 'DISABLE_TELEMETRY' "$cap" && grep -qx 'office-llm DISABLE_ERROR_REPORTING=1' "$cap" \
  && grep -qx 'office-llm ENABLE_TOOL_SEARCH=false' "$cap" \
  && ok_ "Q7 an operator's own DISABLE_TELEMETRY survives; the unset vars are still written" \
  || bad_ 'Q7 operator value' "$(cat "$cap")"
SEED=()
# The «Your own AI» tile's save (DIVE-7568/7569: `account add --provider=custom
# --harness=claude`) reaches the same branch.
source src/cmd_account_custom.sh
ensure_profile_dir() { return 0; }
: >"$cap"; ( custom_ai_save my-ai claude http://192.168.1.20:11434 qwen3:8b "" ) >/dev/null 2>&1
quiet_both my-ai && grep -q '^my-ai ANTHROPIC_BASE_URL=http://192.168.1.20:11434' "$cap" \
  && ok_ 'Q8 the Your-own-AI save (harness claude) writes both vars' || bad_ 'Q8 tile path' "$(cat "$cap")"
: >"$cap"; ( custom_ai_save my-ai codex http://192.168.1.20:11434 qwen3:8b "" ) >/dev/null 2>&1
! grep -q 'DISABLE_TELEMETRY' "$cap" && grep -q FIVEDIVE_CUSTOM_HARNESS=codex "$cap" \
  && ok_ 'Q9 a non-Claude harness on the same save is untouched' || bad_ 'Q9 codex' "$(cat "$cap")"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
