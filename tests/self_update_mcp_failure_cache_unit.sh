#!/usr/bin/env bash
# DIVE-4852: `5dive self-update` restarted seats inside the 15-minute MCP failure
# window it had just opened, and four Claude seats went deaf on Telegram
# (13:19-13:36Z, 2026-09-22; main through three restarts, lodar had to report it).
#
# The chain, in one line: `claude plugin update` STARTS the plugin's MCP server,
# that shell has no TELEGRAM_BOT_TOKEN (the unit launcher injects it, `sudo -u`
# does not), the server dies in ~375ms, and Claude Code 2.1.278 caches the failure
# in ~/.claude/mcp-needs-auth-cache.json and SKIPS the server for 15 minutes on
# every session the seat starts afterwards. The same pass then restarted those
# seats 3-4 minutes later. Full measurement:
# community/wiki/a-plugin-update-that-probes-mcp-without-the-channel-secret-poisons-claude-codes-15-minute-failure-cache.md
#
# THE FIX IS A POSITION, NOT A CALL. Dropping the cache file is one line; dropping
# it BEFORE the probe is a no-op, because the probe re-poisons it microseconds
# later. So the load-bearing arms here are the ORDERING arms (O), which read one
# interleaved log of the shipped `refresh_agent` running against stubs.
#
# Two ways this fix can be wrong, in OPPOSITE directions:
#
#   DEAF    - the clear is absent, fires before the probe, or fires for the wrong
#             seat. The original bug: a restarted seat comes up with its channel
#             skipped and NOTHING says so.
#   FREEZE  - the clear becomes load-bearing for the refresh itself: an unwritable
#             file, a missing home, an empty argument and the nightly pass aborts,
#             leaving the whole fleet on yesterday's plugins. DIVE-3269 measured
#             that direction as the more expensive one on this very script.
#
# So every positive arm is paired with a negative control that only passes because
# the clear did NOT fire, or did NOT abort.
#
# Hermetic in the shape DIVE-4399/DIVE-4033 established: the shipped bytes are
# extracted from the file between its fence markers and eval'd; `sudo`, `claude`,
# `getent` and `rm` are PATH stubs, so no seat, no unit and no real home is touched.
#
# Run: bash tests/self_update_mcp_failure_cache_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` - the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is $? captured at trap time
trap 'rc=$?; rm -rf "${WORK:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - self_update_mcp_failure_cache_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
SCRIPT="$ROOT/5dive-refresh-plugins.sh"
CACHE_REL=".claude/mcp-needs-auth-cache.json"

# ==============================================================================
# E - the shipped bytes are reachable, and something calls them
# ==============================================================================
FENCE="DIVE-4852 clear Claude Code's MCP failure cache after the per-seat plugin probe"
block="$(sed -n "/^# >>> ${FENCE}\$/,/^# <<< ${FENCE}\$/p" "$SCRIPT")"
if [[ -n "$block" ]] && grep -q '_clear_mcp_failure_cache()' <<<"$block"; then
  ok_t "E1 the clear block is extractable from 5dive-refresh-plugins.sh"
else
  bad_t "E1 clear block missing" "markers '# >>> / # <<< $FENCE' not found in $SCRIPT"
  echo; echo "$PASS passed, $FAIL failed"; SUMMARY_PRINTED=1; exit 1
fi

# A fenced block nothing calls is DIVE-1095's shape: a fix that shipped dormant.
callers="$(grep -cE '^[[:space:]]*_clear_mcp_failure_cache "' "$SCRIPT")"
if [[ "$callers" == 1 ]]; then
  ok_t "E2 refresh_agent calls the helper, and it is the file's only call site"
else
  bad_t "E2 wrong number of call sites ($callers)" "$(grep -n '_clear_mcp_failure_cache' "$SCRIPT" | tr '\n' '|')"
fi

WORK="$(mktemp -d)"
mkdir -p "$WORK/bin"

# ==============================================================================
# B - the helper itself, run as the shipped bytes
# ==============================================================================
# seat_home <name> -> a home with a poisoned cache in it
seat_home() {
  local n="$1"; local h="$WORK/home/$n"
  mkdir -p "$h/.claude"
  printf '{"plugin:telegram:telegram":{"timestamp":1,"id":"abc"}}' > "$h/$CACHE_REL"
  printf '%s' "$h"
}
# run_clear <user> <home> [rmstub] -> stdout; stderr in $WORK/err
run_clear() {
  local u="$1" h="$2" stub="${3:-}"
  : > "$WORK/err"
  (
    if [[ "$stub" == failrm ]]; then
      # A `rm` that refuses, whatever the uid. chmod would make this arm pass for
      # the wrong reason under root (root removes from a 0500 directory), and CI
      # roots vary - so the refusal is injected, not arranged.
      mkdir -p "$WORK/failbin"
      cat > "$WORK/failbin/rm" <<'RMSTUB'
#!/bin/bash
exit 1
RMSTUB
      chmod +x "$WORK/failbin/rm"
      PATH="$WORK/failbin:$PATH"
    fi
    unset -f rm 2>/dev/null || true
    export PATH
    eval "$block"
    _clear_mcp_failure_cache "$u" "$h"
  ) 2>"$WORK/err"
}

h="$(seat_home alpha)"; h2="$(seat_home beta)"
out="$(run_clear agent-alpha "$h")"; rc=$?
if [[ ! -e "$h/$CACHE_REL" && "$rc" == 0 ]]; then
  ok_t "B1 a poisoned cache file is removed"
else
  bad_t "B1 the cache survived the clear" "rc=$rc still there: $(ls -l "$h/$CACHE_REL" 2>&1)"
fi
if grep -q "cleared mcp failure cache for agent-alpha" <<<"$out"; then
  ok_t "B2 the pass log carries the receipt the row asked for, naming the seat"
else
  bad_t "B2 no receipt" "out: $(tr '\n' '|' <<<"$out")"
fi
if [[ -e "$h2/$CACHE_REL" ]]; then
  ok_t "B3 NEGATIVE CONTROL - the sibling seat's cache is untouched (this is per-seat, not a fleet wipe)"
else
  bad_t "B3 clearing one seat removed another seat's file" "beta home: $h2"
fi

# An absent file must not print a receipt - a false receipt is worse than none,
# because the receipt is the only surface saying the fix ran.
out="$(run_clear agent-gamma "$WORK/home/gamma-never-existed")"; rc=$?
if [[ "$rc" == 0 ]] && grep -q "nothing cached" <<<"$out" && ! grep -q "cleared mcp failure cache" <<<"$out"; then
  ok_t "B4 an absent cache says 'nothing cached' and does NOT claim a clear"
else
  bad_t "B4 absent-cache path wrong" "rc=$rc out: $(tr '\n' '|' <<<"$out")"
fi

# FREEZE direction. A clear that cannot happen is loud and NOT fatal.
h3="$(seat_home delta)"
out="$(run_clear agent-delta "$h3" failrm)"; rc=$?
err="$(cat "$WORK/err")"
if [[ "$rc" == 0 ]]; then
  ok_t "B5 a refused rm does not abort the refresh (the freeze direction costs the whole fleet)"
else
  bad_t "B5 the helper returned non-zero on a refused rm" "rc=$rc - refresh_agent runs under set -uo pipefail and this would propagate"
fi
if grep -q "WARN" <<<"$err" && grep -q "$h3/$CACHE_REL" <<<"$err" && ! grep -q "cleared mcp failure cache" <<<"$out"; then
  ok_t "B6 a refused rm WARNs on stderr, names the exact path to fix by hand, and claims no clear"
else
  bad_t "B6 silent or mislabelled failure" "err: $(tr '\n' '|' <<<"$err") out: $(tr '\n' '|' <<<"$out")"
fi

# Empty arguments must never resolve to a path. `$home` comes from `getent
# passwd | cut`, which is empty for a seat whose user was deleted mid-pass.
out="$(run_clear "" "")"; rc=$?
if [[ "$rc" == 0 ]] && [[ -z "$out" ]]; then
  ok_t "B7 empty user/home is a silent no-op - it never resolves to '/.claude/...'"
else
  bad_t "B7 empty args did something" "rc=$rc out: $(tr '\n' '|' <<<"$out")"
fi

# ==============================================================================
# O - ORDERING. The whole fix. Behavioural, against the shipped refresh_agent.
# ==============================================================================
# Extract the functions refresh_agent needs, plus refresh_agent itself, and run
# them with `sudo`, `getent` and `rm` stubbed into ONE interleaved log. Nothing
# below asserts on source line numbers: a clear that merely APPEARS after the
# loop in the file could still be hoisted by any later edit, and the log is the
# only thing that answers "which happened first" about the bytes that ran.
fn() { sed -n "/^$1() {\$/,/^}\$/p" "$SCRIPT"; }
mkdir -p "$WORK/obin"
cat > "$WORK/obin/sudo" <<'SUDOSTUB'
#!/bin/bash
# `sudo -u <user> -H <claude> plugin <verb> <key>` - record the verb+key only.
args=("$@"); out=""
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == plugin ]]; then out="plugin ${args[*]:$((i+1))}"; break; fi
done
printf '%s\n' "${out:-sudo ${args[*]}}" >> "${ORDER_LOG:?}"
exit 0
SUDOSTUB
cat > "$WORK/obin/getent" <<'GETENTSTUB'
#!/bin/bash
printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "${SEAT_HOME:?}"
GETENTSTUB
cat > "$WORK/obin/rm" <<'RMSTUB'
#!/bin/bash
case " $* " in *" ${SEAT_CACHE:-__none__} "*) printf 'clear-cache\n' >> "${ORDER_LOG:?}" ;; esac
exec /bin/rm "$@"
RMSTUB
cat > "$WORK/obin/id" <<'IDSTUB'
#!/bin/bash
exit 0
IDSTUB
chmod +x "$WORK/obin"/*

run_refresh_agent() { # <seat-home> -> $WORK/order.log
  local home="$1"
  : > "$WORK/order.log"
  (
    # A PATH stub cannot shadow a shell FUNCTION, and the 5dive test-env isolation
    # guard exports one named `sudo` that refuses with rc 125 (DIVE-3096). Left in
    # place it swallows every probe, so O1's count reads zero — which is why O1 is a
    # control and not an assumption. Dropping the function is safe here precisely
    # because nothing below may reach a real sudo: the stub is the only one wanted.
    unset -f sudo getent rm id 2>/dev/null || true
    export PATH="$WORK/obin:$PATH"
    export ORDER_LOG="$WORK/order.log" SEAT_HOME="$home" SEAT_CACHE="$home/$CACHE_REL"
    # GH_ORG=5dive-com short-circuits migrate_marketplace_org (no network probe).
    GH_ORG=5dive-com CLAUDE_BIN=/nonexistent/claude KEEP_PLUGIN_VERSIONS=2 CHANGED_AGENTS=""
    export GH_ORG CLAUDE_BIN KEEP_PLUGIN_VERSIONS
    eval "$block"
    eval "$(fn snapshot_state)"
    eval "$(fn migrate_marketplace_org)"
    eval "$(fn prune_plugin_cache)"
    eval "$(fn refresh_agent)"
    refresh_agent omega
  ) >"$WORK/refresh.out" 2>&1
}

homega="$WORK/home/omega"
mkdir -p "$homega/.claude/plugins"
printf '{"enabledPlugins":{"telegram@5dive-plugins":true,"browser@5dive-plugins":true}}' > "$homega/.claude/settings.json"
printf '{"plugins":{"telegram@5dive-plugins":[{"version":"1.0.0"}],"browser@5dive-plugins":[{"version":"1.0.0"}]}}' \
  > "$homega/.claude/plugins/installed_plugins.json"
printf '{"plugin:telegram:telegram":{"timestamp":1,"id":"abc"}}' > "$homega/$CACHE_REL"
run_refresh_agent "$homega"
order="$(cat "$WORK/order.log")"

probes="$(grep -c '^plugin ' <<<"$order")"
if [[ "${probes:-0}" -ge 2 ]]; then
  ok_t "O1 NEGATIVE CONTROL - the per-seat plugin probes actually ran ($probes of them); without this every arm below passes vacuously"
else
  bad_t "O1 no plugin probe was observed" "order: $(tr '\n' '|' <<<"$order")  out: $(tail -5 "$WORK/refresh.out" | tr '\n' '|')"
fi
last_probe="$(grep -n '^plugin ' <<<"$order" | tail -1 | cut -d: -f1)"
clear_at="$(grep -n '^clear-cache$' <<<"$order" | head -1 | cut -d: -f1)"
if [[ -n "$last_probe" && -n "$clear_at" && "$clear_at" -gt "$last_probe" ]]; then
  ok_t "O2 the clear runs AFTER the last plugin probe for that seat - a clear before it is a no-op the probe overwrites"
else
  bad_t "O2 the clear does not follow the probes" "last probe at line ${last_probe:-none}, clear at ${clear_at:-none}; order: $(tr '\n' '|' <<<"$order")"
fi
if [[ ! -e "$homega/$CACHE_REL" ]]; then
  ok_t "O3 after refresh_agent the seat's cache file is gone - it can be restarted without being skipped"
else
  bad_t "O3 refresh_agent left the poisoned cache in place" "$(cat "$homega/$CACHE_REL")"
fi
if grep -q "cleared mcp failure cache for agent-omega" "$WORK/refresh.out"; then
  ok_t "O4 the receipt reaches the pass log the operator reads, not just the helper's stdout"
else
  bad_t "O4 no receipt in the refresh output" "out: $(tr '\n' '|' < "$WORK/refresh.out")"
fi

# ==============================================================================
# A - the AUDIT arm. Every seat-facing `claude plugin` caller clears the cache.
# ==============================================================================
# The incident had ONE observed call site, and a fix fenced at one call site is
# fenced at none: `5dive plugin add|upgrade` and `5dive agent create` start the
# same MCP server from the same tokenless `sudo -u` shell, and a seat restarted
# behind either of those is deaf in exactly the same way.
#
# THE SWEEP DELIBERATELY DOES NOT KEY ON `plugin install|update`. The refresh
# script writes `plugin "$verb"` - the verb is a variable - so the obvious
# pattern hides the very file this row was filed over, which is DIVE-4399's
# lesson (a pattern filter hides a file exactly the way a path filter does). It
# keys on the claude binary followed by the `plugin` subcommand, in any form.
#
# Prose is dropped by the quoting, not by a path filter: a help-text or comment
# line naming the command carries a backtick or an apostrophe around it, and a
# real invocation carries neither.
declare -A PLUGIN_CALLERS=(
  [5dive-refresh-plugins.sh]=CLEARS
  [src/lib/plugin_seats.sh]=CLEARS
  [src/lib/agent_setup.sh]=CLEARS
)
_a_candidates(){
  local tracked
  tracked="$(git -C "$ROOT" ls-files -- . 2>/dev/null)" || { echo "__A_GIT_FAILED__"; return 0; }
  [[ -n "$tracked" ]] || { echo "__A_GIT_FAILED__"; return 0; }
  printf '%s\n' "$tracked" \
    | grep -vE '^(tests/|changelog\.d/|docs/|community/|CHANGELOG\.md$|node_modules/)' \
    | while IFS= read -r f; do
        [[ -f "$ROOT/$f" ]] || continue
        grep -E '(\$CLAUDE_BIN|\$CLAUDE|\bclaude)"? plugin ' "$ROOT/$f" 2>/dev/null \
          | grep -vE "^[[:space:]]*#" | grep -vE "[\`']" | grep -q . && printf '%s\n' "$f"
      done | sort -u
}
found=""; a_ok=1
while IFS= read -r f; do
  [[ "$f" == "__A_GIT_FAILED__" ]] && { a_ok=0; continue; }
  [[ -n "$f" ]] && found="${found:+$found }$f"
done < <(_a_candidates)
extra=""; missing=""
for f in $found; do [[ -n "${PLUGIN_CALLERS[$f]:-}" ]] || extra="${extra:+$extra }$f"; done
for f in "${!PLUGIN_CALLERS[@]}"; do [[ " $found " == *" $f "* ]] || missing="${missing:+$missing }$f"; done
if [[ "$a_ok" != 1 ]]; then
  bad_t "A1 the sweep could not run - NOT a clean inventory" \
        "git ls-files returned nothing from $ROOT; an empty candidate set must never read as 'no untriaged callers'"
elif [[ -z "$extra" && -z "$missing" ]]; then
  ok_t "A1 the sweep: all ${#PLUGIN_CALLERS[@]} tracked files that drive \`claude plugin\` for a seat are ones this row triaged"
else
  bad_t "A1 the plugin-caller inventory no longer matches the tree" \
        "UNTRIAGED (a new caller that can poison a seat's MCP cache - decide whether it must clear it): ${extra:-none} | GONE: ${missing:-none}"
fi
blind=""
for f in "${!PLUGIN_CALLERS[@]}"; do
  [[ "${PLUGIN_CALLERS[$f]}" == CLEARS ]] || continue
  grep -q 'mcp-needs-auth-cache.json' "$f" 2>/dev/null || blind="${blind:+$blind }$f"
done
if [[ -z "$blind" ]]; then
  ok_t "A2 every caller marked CLEARS actually drops mcp-needs-auth-cache.json"
else
  bad_t "A2 a CLEARS caller never touches the cache file" "$blind"
fi

# agent_setup.sh had the drop already - but only inside `if [[ "$plugin" == telegram ]]`
# and only once a token was passed, so a seat given any other seat-facing plugin got
# the poisoned cache and no clear. A2 above cannot see that: the string was present
# the whole time it was wrong (the same reason DIVE-4399's A2 could not clear
# cmd_heartbeat.sh). So assert the unconditional drop sits in the install shell.
setup_install_block="$(sed -n "/^  if ! sudo -u \"\$user\" -H env PLUGIN=/,/^AGENT_PLUGIN_INSTALL\$/p" "$ROOT/src/lib/agent_setup.sh")"
if grep -q 'plugin install' <<<"$setup_install_block" && grep -q 'mcp-needs-auth-cache.json' <<<"$setup_install_block"; then
  ok_t "A3 agent-create drops the cache in the SAME seat shell that runs the install, for every plugin - not only telegram"
else
  bad_t "A3 the agent-create clear is not in the install shell" \
        "the pre-existing drop is in the telegram-token branch, which a browser/mod-only seat never reaches"
fi

seat_register_block="$(sed -n "/<<'SEAT_PLUGIN_REGISTER'/,/^SEAT_PLUGIN_REGISTER\$/p" "$ROOT/src/lib/plugin_seats.sh")"
if grep -q 'plugin install' <<<"$seat_register_block" && grep -q 'mcp-needs-auth-cache.json' <<<"$seat_register_block"; then
  ok_t "A4 the plugin add/upgrade seat fan-out drops the cache inside the seat's own shell (so the file keeps the seat's ownership)"
else
  bad_t "A4 plugin_seat_register_claude does not clear the cache it poisons" \
        "block: $(tr '\n' '|' <<<"$seat_register_block")"
fi

echo
echo "$PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
