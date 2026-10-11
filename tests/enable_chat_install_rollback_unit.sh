#!/usr/bin/env bash
# DIVE-6005 unit harness: the dashboard's "Enable chat" (`agent config <n> set
# channels=dashboard`) run seconds after a hire.
#
# Seen on DIVE-6000's live arm: the hired seat's own Claude Code was cloning the
# 5dive-plugins marketplace into ~/.claude/plugins/marketplaces/5dive-plugins
# while the CLI ran `rm -rf <dir>; git clone <repo> <dir>` into the same path.
# git aborted ("BUG: refs/files-backend.c: initial ref transaction called with
# existing refs"), the installer's `fail` exited — and the registry write that had
# committed long before it stayed. channels=dashboard with no plugin: the
# dashboard's chatCapability() reads `channels` alone, so it said "ready" and
# never offered Enable chat again.
#
#   R. cmd_config: a failed channel install rolls channels back (registry + env),
#      fires no restart, and the JSON caller gets exactly ONE error envelope.
#      Positive control: a succeeding install keeps the value and restarts.
#   C. marketplace_checkout_settled: real git against a local fixture repo —
#      a concurrent first-boot clone, an in-flight checkout, a transient clone
#      failure, a lost rename race, and exhausted tries.
#      Negative control: the pre-fix clone block, under the same in-flight state.
#
# Run: bash tests/enable_chat_install_rollback_unit.sh  (no root, no network).
# CFG=<file> / AS=<file> grade another copy of cmd_agent_config.sh / agent_setup.sh
# (that is how the pre-fix tree's red was measured).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${T:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
CFG="${CFG:-$SRC/cmd_agent_config.sh}"
AS="${AS:-$SRC/lib/agent_setup.sh}"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git required"; exit 1; }
T=$(mktemp -d)

# ============================================================== R: rollback
# run_cfg <install-mode> <json> -> drives the real cmd_config on seat "chat".
# install-mode: fail = the installer exits through the real `fail` (what the
# aborted clone does); ok = it stages the plugin cache dir the gate polls for.
REG="$T/agents.json"
run_cfg() {
  local mode="$1" json="$2"
  printf '{"agents":{"chat":{"type":"claude","channels":"none"}}}\n' >"$REG"
  rm -rf "$T/agents.d" "$T/restarts"; mkdir -p "$T/agents.d"
  printf 'AGENT_CHANNELS=none\n' >"$T/agents.d/chat.env"
  (
    set +e
    JSON_MODE="$json"
    ENV_DIR="$T/agents.d"; CONNECTORS_DIR="$T/connectors"; mkdir -p "$CONNECTORS_DIR"
    FIVE_REPORTED_FLAG="$T/reported"
    declare -A TYPE_CHANNELS=([claude]=1)
    ensure_state()  { :; }
    registry_read() { cat "$REG"; }
    registry_write(){ cat >"$REG"; }
    install_channel_for_agent() {
      if [[ "$mode" == fail ]]; then
        echo "fatal: BUG: refs/files-backend.c:3055: initial ref transaction called with existing refs" >&2
        fail "$E_GENERIC" "$2 plugin install failed for agent '$3' (see journalctl / stderr above). Run: sudo 5dive doctor"
      fi
      # errexit = an installer step fails WITHOUT calling `fail` (the installer
      # leans on the CLI's set -e for those); it must still abort the install.
      [[ "$mode" == errexit ]] && false
      : >"$T/installed"
    }
    sleep() { :; }
    teardown_telegram_wiring() { :; }
    write_runtime_model() { :; }
    write_runtime_effort() { :; }
    link_agent_profile() { :; }
    write_agent_env() { printf 'AGENT_CHANNELS=%s\n' "$3" >"$ENV_DIR/$1.env"; }
    step() { :; }
    ok()   { printf 'OK-ENVELOPE\n'; }
    systemd-run() { printf 'restart\n' >>"$T/restarts"; }
    # The staging gate polls /home/agent-chat/... — point "ok" at a dir that
    # exists so the positive control reaches the restart.
    # shellcheck source=/dev/null
    source "$CFG"
    if [[ "$mode" == ok ]]; then
      eval "$(declare -f cmd_config | sed 's#/home/agent-\${name}/.claude/plugins/cache#'"$T"'/cache#')"
      mkdir -p "$T/cache/5dive-plugins/dashboard"
    fi
    cmd_config chat set channels=dashboard
  ) >"$T/out" 2>"$T/err"
}

run_cfg fail 1; rc=$?
chan=$(jq -r '.agents.chat.channels' "$REG")
envc=$(cut -d= -f2- "$T/agents.d/chat.env")
envelopes=$(grep -c '^{"ok":false' "$T/out")
(( rc != 0 )) && ok_t "R1 a failed install fails the call (rc=$rc)" \
  || bad_t "R1 a failed install fails the call" "rc=0"
[[ "$chan" == none ]] \
  && ok_t "R2 registry channels rolled back to 'none' — chatCapability() reads 'enableable', Enable chat is still offered" \
  || bad_t "R2 registry channels rolled back" "left at '$chan': the dashboard shows chat 'ready' on a seat with no plugin"
[[ "$envc" == none ]] && ok_t "R3 agents.d env rolled back too (5dive-agent-start reads it)" \
  || bad_t "R3 agents.d env rolled back" "left at '$envc'"
[[ ! -s "$T/restarts" ]] && ok_t "R4 no restart fired" || bad_t "R4 no restart fired" "$(cat "$T/restarts")"
[[ "$envelopes" == 1 ]] \
  && ok_t "R5 the JSON caller (the dashboard's exec tunnel) gets exactly one error envelope" \
  || bad_t "R5 exactly one error envelope" "got $envelopes: $(cat "$T/out")"
grep -q 'rolled back' "$T/out" && grep -q 'dashboard' "$T/out" \
  && ok_t "R6 the error says the change was rolled back" \
  || bad_t "R6 the error says the change was rolled back" "$(cat "$T/out")"
grep -q 'files-backend' "$T/err" \
  && ok_t "R7 the installer's own cause still reaches stderr" \
  || bad_t "R7 the installer's own cause still reaches stderr" "$(cat "$T/err")"

run_cfg errexit 1; rc=$?
chan=$(jq -r '.agents.chat.channels' "$REG")
(( rc != 0 )) && [[ "$chan" == none ]] && [[ ! -e "$T/installed" ]] && [[ ! -s "$T/restarts" ]] \
  && ok_t "R9 an installer step failing without \`fail\` still aborts the install and rolls back (set -e kept inside the wrapper)" \
  || bad_t "R9 set -e kept inside the wrapper" "rc=$rc chan=$chan installed=$([ -e "$T/installed" ] && echo y || echo n)"
rm -f "$T/installed"

# POSITIVE CONTROL: without it R1-R6 pass against a cmd_config that always refuses.
run_cfg ok 0; rc=$?
chan=$(jq -r '.agents.chat.channels' "$REG")
(( rc == 0 )) && [[ "$chan" == dashboard ]] && [[ -s "$T/restarts" ]] \
  && ok_t "R8 POSITIVE: a succeeding install keeps channels=dashboard and restarts" \
  || bad_t "R8 POSITIVE: a succeeding install keeps channels=dashboard and restarts" \
           "rc=$rc chan=$chan restarts=$(cat "$T/restarts" 2>/dev/null) err=$(tail -3 "$T/err")"

# ====================================================== C: concurrent clone
# The function as the installer ships it: `declare -f` piped into `bash -s`.
fn_src=$(sed -n '/^marketplace_checkout_settled() {/,/^}/p' "$AS")
[[ -n "$fn_src" ]] && ok_t "C0 marketplace_checkout_settled is defined in $AS" \
  || bad_t "C0 marketplace_checkout_settled is defined in $AS" "not found"
eval "$fn_src"
inst=$(sed -n '/^install_channel_plugin_for_agent() {/,/^}/p' "$AS")
grep -q 'declare -f marketplace_checkout_settled' <<<"$inst" \
  && grep -q '^marketplace_checkout_settled "\$MKT_REPO" "\$MKT_DIR"' <<<"$inst" \
  && ! grep -qE '^ *git clone .*"\$MKT_DIR"$' <<<"$inst" \
  && ok_t "C0b the install heredoc ships the helper and no longer clones INTO the shared path" \
  || bad_t "C0b the install heredoc ships the helper" "install_channel_plugin_for_agent still clones into \$MKT_DIR, or never calls the helper"

# A fixture marketplace, reached over file:// so --depth behaves as over https.
FIX="$T/fixture"
git init -q -b main "$FIX/src"
mkdir -p "$FIX/src/.claude-plugin" "$FIX/src/plugins/dashboard"
echo '{"name":"5dive-plugins","plugins":[{"name":"dashboard"}]}' >"$FIX/src/.claude-plugin/marketplace.json"
for i in $(seq 1 200); do echo "$i" >"$FIX/src/plugins/dashboard/f$i"; done
git -C "$FIX/src" add -A && git -C "$FIX/src" -c user.email=t@t -c user.name=t commit -qm fixture
git clone -q --bare "$FIX/src" "$FIX/repo.git"
URL="file://$FIX/repo.git"
ready() { [ -d "$1/.git" ] && git -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1 && [ -f "$1/.claude-plugin/marketplace.json" ]; }
# FAST=1 serves each backoff at a tenth of its length: the arms that are not about
# the wait should not pay it on every CI run. C2, which IS about the wait, does not.
as_shipped() {
  { [[ -n "${FAST:-}" ]] && printf '%s\n' 'sleep() { command sleep "$(awk "BEGIN{print $1/10}")"; }'
    declare -f marketplace_checkout_settled
    printf 'marketplace_checkout_settled %q %q %s\n' "$1" "$2" "${3:-4}"; } | bash -s
}

# The pre-fix block, verbatim from origin/main's install heredoc (negative control).
prefix_block() { local MKT_REPO="$1" MKT_DIR="$2"
  if [ ! -d "$MKT_DIR/.git" ]; then
    mkdir -p "$(dirname "$MKT_DIR")"
    rm -rf "$MKT_DIR"
    git clone -q --depth 1 "$MKT_REPO" "$MKT_DIR"
  fi
}

# C1: the incident shape — a first-boot fetcher clones into the same path at the
# same moment. Ten rounds, every one must end ready with rc 0.
c1_bad=0
for r in $(seq 1 10); do
  D="$T/c1-$r/marketplaces/5dive-plugins"; mkdir -p "$(dirname "$D")"
  ( git clone -q --depth 1 "$URL" "$D" 2>/dev/null ) &
  FAST=1 as_shipped "$URL" "$D" 2>>"$T/c1.err"; mrc=$?
  wait
  { (( mrc == 0 )) && ready "$D"; } || c1_bad=$((c1_bad + 1))
done
(( c1_bad == 0 )) && ok_t "C1 10/10 rounds racing a concurrent first-boot clone end with a ready checkout" \
  || bad_t "C1 concurrent first-boot clone" "$c1_bad/10 rounds not ready; $(tail -3 "$T/c1.err")"

# C2: deterministic in-flight state — the other fetcher has made .git and not
# finished (git creates .git first). It finishes ~1.5 s later.
inflight() {
  local D="$1"; mkdir -p "$(dirname "$D")"; git init -q "$D"; : >"$D/.git/OTHER_FETCHER"
  ( sleep 1.5; git -C "$D" fetch -q --depth 1 "$URL" main && git -C "$D" checkout -q FETCH_HEAD ) &
}
D="$T/c2/marketplaces/5dive-plugins"; inflight "$D"
as_shipped "$URL" "$D" 2>"$T/c2.err"; mrc=$?; wait
(( mrc == 0 )) && ready "$D" && [ -e "$D/.git/OTHER_FETCHER" ] \
  && ok_t "C2 an in-flight checkout is waited on, not raced or deleted, and ends ready" \
  || bad_t "C2 in-flight checkout" "rc=$mrc ready=$(ready "$D" && echo y || echo n) $(cat "$T/c2.err")"
D="$T/c2n/marketplaces/5dive-plugins"; inflight "$D"
prefix_block "$URL" "$D" 2>/dev/null; was_ready=$(ready "$D" && echo y || echo n); wait
[[ "$was_ready" == n ]] \
  && ok_t "C2n NEGATIVE CONTROL: the pre-fix block returns on the same in-flight checkout before it is usable" \
  || bad_t "C2n NEGATIVE CONTROL: the pre-fix block should return on a half-made checkout" "it was ready — the arm no longer reproduces the state"

# C3: a transient clone failure (the files-backend abort) is retried.
SHIM="$T/shim"; mkdir -p "$SHIM"; REALGIT=$(command -v git)
cat >"$SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then
  echo x >>"$T/clones"
  if [ "\$(wc -l <"$T/clones")" = 1 ]; then echo "BUG: refs/files-backend.c:3055: initial ref transaction called with existing refs" >&2; exit 134; fi
  if [ -n "\${RACE_DIR:-}" ]; then "$REALGIT" "\$@" && "$REALGIT" clone -q --depth 1 "$URL" "\$RACE_DIR" && : >"\$RACE_DIR/OTHER"; exit; fi
fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$SHIM/git"
D="$T/c3/marketplaces/5dive-plugins"; rm -f "$T/clones"
FAST=1 PATH="$SHIM:$PATH" as_shipped "$URL" "$D" 2>"$T/c3.err"; mrc=$?
(( mrc == 0 )) && ready "$D" && [[ "$(wc -l <"$T/clones")" == 2 ]] \
  && ok_t "C3 an aborted clone is retried and the second one lands" \
  || bad_t "C3 transient clone failure" "rc=$mrc clones=$(wc -l <"$T/clones") $(cat "$T/c3.err")"

# C4: the other fetcher lands its checkout while ours is cloning: our rename must
# lose, ours is discarded, theirs is kept, no private clone dir is left behind.
D="$T/c4/marketplaces/5dive-plugins"; printf 'x\n' >"$T/clones"
FAST=1 RACE_DIR="$D" PATH="$SHIM:$PATH" as_shipped "$URL" "$D" 2>"$T/c4.err"; mrc=$?
left=$(find "$(dirname "$D")" -maxdepth 1 -name '*.5dive-clone.*' | wc -l)
(( mrc == 0 )) && ready "$D" && [ -e "$D/OTHER" ] && (( left == 0 )) \
  && ok_t "C4 a lost rename keeps the other fetcher's checkout and leaves no private clone behind" \
  || bad_t "C4 lost rename race" "rc=$mrc other=$([ -e "$D/OTHER" ] && echo kept || echo gone) leftovers=$left $(cat "$T/c4.err")"

# C5: tries are bounded and the failure is a non-zero return, not a hang.
D="$T/c5/marketplaces/5dive-plugins"
FAST=1 as_shipped "file://$T/no-such-repo.git" "$D" 2 2>"$T/c5.err"; mrc=$?
left=$(find "$(dirname "$D")" -maxdepth 1 -name '*.5dive-clone.*' 2>/dev/null | wc -l)
(( mrc != 0 )) && grep -q 'not ready after 2 tries' "$T/c5.err" && (( left == 0 )) \
  && ok_t "C5 an unreachable marketplace fails after its tries, names why, leaves nothing behind" \
  || bad_t "C5 bounded failure" "rc=$mrc leftovers=$left $(cat "$T/c5.err")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
