#!/usr/bin/env bash
# DIVE-6934 — buzz left the core CLI for its plugin.
#
# lodar, 2026-10-25: "did we kill buzz from the core? … can be a plugin?" The
# buzz verbs (src/cmd_buzz.sh, src/cmd_agent_buzz*.sh), the outbound a2a mirror,
# create's buzz wiring check and install.sh's binary download all moved to the
# buzz plugin (5dive-ai/5dive-plugins plugins/buzz, which now declares the `buzz`
# verb). What core keeps is the channel NAME (valid_channel, the channel-plugin
# table, managed settings) and one hand-over: `5dive agent buzz <sub>` runs the
# OFFICIAL plugin's verb as `buzz agent <sub>`, because every standard seat holds
# a root sudo grant for `agent buzz inbound *` and the plugin's bridge calls it.
#
# What this grades, against a BUILT bundle and a throwaway STATE_DIR:
#   A-D  the moved code is gone from src/, build.sh, install.sh and the send path
#   E    a box without the plugin answers every buzz verb with ONE line, rc 2
#   F    with the official plugin, both spellings reach its bin/buzz (recorded)
#   G    NEGATIVE: a different plugin claiming `buzz` is never handed `agent buzz`
#   H    `plugin add buzz` is allowed box-wide only when the manifest ships a verb
#   I    the seat grant and capability for `agent buzz inbound` are still rendered
#   J    Classic's People-page save still exits 0: the dashboard passes --buzz= on
#        EVERY save (lodar 13:09Z: "not to break our 5dive classic dashboard")
#   K    install-contract's --help waiver no longer names buzz (T5 reds on it)
#
# Run: bash tests/buzz_moved_to_plugin_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
WORK=$(mktemp -d)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

LINE="Buzz is a plugin now: 5dive plugin install buzz"

# --- A. the modules are gone and unbundled ----------------------------------
gone=1
for f in cmd_buzz cmd_agent_buzz cmd_agent_buzz_join cmd_agent_buzz_bridge cmd_agent_buzz_pair cmd_agent_buzz_whois; do
  [[ -e "$SRC/$f.sh" ]] && { gone=0; bad_t "A src/$f.sh is gone" "it moved to plugins/buzz/cli"; }
  grep -qE "src/$f\.sh" build.sh && { gone=0; bad_t "A build.sh no longer bundles $f.sh" ""; }
done
(( gone )) && ok_t "A the six buzz modules are gone from src/ and build.sh"

# --- B. `buzz` is released, not a builtin -----------------------------------
# A builtin name can never be claimed by a plugin (_plugin_verb_is_builtin
# refuses it at install), so releasing it is what lets the plugin's verb run.
BV=$(sed -n 's/^readonly FIVEDIVE_BUILTIN_VERBS="\(.*\)"$/\1/p' "$SRC/cmd_plugin.sh")
[[ -n "$BV" ]] || bad_t "B FIVEDIVE_BUILTIN_VERBS was read" "the extractor found nothing — B measured nothing"
[[ -n "$BV" && " $BV " != *" buzz "* ]] \
  && ok_t "B buzz is not in FIVEDIVE_BUILTIN_VERBS" || bad_t "B buzz is not in FIVEDIVE_BUILTIN_VERBS" "$BV"
grep -qE '^    buzz\)' "$SRC/main.sh" \
  && bad_t "B main() has no top-level buzz label" "a label would shadow the plugin's verb" \
  || ok_t "B main() has no top-level buzz label"

# --- C. install.sh downloads nothing buzz -----------------------------------
grep -qE 'stage_buzz_binaries|buzz/releases/download' install.sh \
  && bad_t "C install.sh no longer stages buzz binaries" "$(grep -nE 'stage_buzz_binaries|buzz/releases/download' install.sh)" \
  || ok_t "C install.sh no longer stages buzz binaries"
# ...and deletes nothing: a box that has them keeps them.
grep -qE 'rm[^#]*\$BIN_DIR/buzz' install.sh \
  && bad_t "C install.sh does not delete existing buzz binaries" "$(grep -nE 'rm[^#]*\$BIN_DIR/buzz' install.sh)" \
  || ok_t "C install.sh does not delete existing buzz binaries"

# --- D. the send path no longer calls a buzz mirror -------------------------
git grep -n '_buzz_mirror_outbound' -- "$SRC" | grep -vE ':[0-9]+:\s*#' >"$WORK/mirror" || true
[[ -s "$WORK/mirror" ]] \
  && bad_t "D no _buzz_mirror_outbound call is left in src/" "$(cat "$WORK/mirror")" \
  || ok_t "D no _buzz_mirror_outbound call is left in src/"

# --- build the artifact the arms below run ----------------------------------
BIN="$WORK/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$WORK/build.log" 2>&1; then
  bad_t "the bundle builds" "$(tail -5 "$WORK/build.log")"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
run() { STATE_DIR="$SD" "$BIN" "$@" 2>&1; }

# --- E. no plugin: one line, rc 2, for every spelling -----------------------
SD="$WORK/state-none"; mkdir -p "$SD"
for argv in "buzz" "buzz pair" "agent buzz status x" "agent buzz inbound --pubkey=k --message-file=/x"; do
  # shellcheck disable=SC2086
  out=$(run $argv); rc=$?
  [[ "$rc" == 2 && "$out" == "error: $LINE" ]] \
    && ok_t "E \`5dive $argv\` without the plugin: the one line, rc 2" \
    || bad_t "E \`5dive $argv\` without the plugin: the one line, rc 2" "rc=$rc out=[$out]"
done

# A fake installed plugin whose bin/buzz records its argv.
mk_plugin() { # <state-dir> <key>
  local sd="$1" key="$2" mkt="${2#*@}" dir
  dir="$sd/plugins/cache/$mkt/buzz/9.9.9"
  mkdir -p "$dir/bin" "$sd/plugins/enabled"
  cat >"$dir/bin/buzz" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sd/argv"
EOF
  chmod +x "$dir/bin/buzz"
  ln -sfn "$dir" "$sd/plugins/enabled/$key"
  jq -n --arg k "$key" '{($k): {plugin:"buzz", enabled:true, capabilities:["channel","verb"], verbs:[{name:"buzz"}]}}' \
    >"$sd/plugins/installed.json"
  : >"$sd/argv"
}

# --- F. the official plugin answers both spellings --------------------------
SD="$WORK/state-official"; mk_plugin "$SD" "buzz@5dive-plugins"
out=$(run agent buzz whois abc --role); rc=$?
[[ "$rc" == 0 && "$(tail -1 "$SD/argv")" == "agent whois abc --role" ]] \
  && ok_t "F \`agent buzz whois\` reaches the plugin as \`buzz agent whois\`" \
  || bad_t "F \`agent buzz whois\` reaches the plugin as \`buzz agent whois\`" "rc=$rc out=[$out] argv=[$(cat "$SD/argv")]"
out=$(run buzz pair --timeout=5); rc=$?
[[ "$rc" == 0 && "$(tail -1 "$SD/argv")" == "pair --timeout=5" ]] \
  && ok_t "F \`buzz pair\` reaches the plugin's verb" \
  || bad_t "F \`buzz pair\` reaches the plugin's verb" "rc=$rc out=[$out] argv=[$(cat "$SD/argv")]"

# --- G. NEGATIVE: another plugin claiming `buzz` never gets `agent buzz` ------
# The seat grant runs `agent buzz inbound *` as root; handing that to whatever
# plugin claims the verb would hand every standard seat root in that plugin.
SD="$WORK/state-other"; mk_plugin "$SD" "buzz@someone-else"
out=$(run agent buzz inbound --pubkey=k --message-file=/x); rc=$?
[[ "$rc" == 2 && "$out" == "error: $LINE" && ! -s "$SD/argv" ]] \
  && ok_t "G a non-official \`buzz\` claimant is refused for \`agent buzz\` and never run" \
  || bad_t "G a non-official \`buzz\` claimant is refused for \`agent buzz\` and never run" "rc=$rc out=[$out] argv=[$(cat "$SD/argv")]"
# Positive control for G's fixture: the same record DOES run for the top-level
# verb, which is an ordinary plugin verb the user typed, with no sudo grant on it.
out=$(run buzz owner); rc=$?
[[ "$rc" == 0 && "$(tail -1 "$SD/argv")" == "owner" ]] \
  && ok_t "G control: the same claimant runs for the top-level verb (the fixture is live)" \
  || bad_t "G control: the same claimant runs for the top-level verb (the fixture is live)" "rc=$rc out=[$out]"

# --- H. box-wide install of a channel plugin that ships a verb --------------
(
  set +e
  # shellcheck source=/dev/null
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_plugin.sh; do source "$SRC/$f"; done
  set +e
  STATE_DIR="$WORK/state-h"
  m="$STATE_DIR/plugins/marketplaces/5dive-plugins/plugins"
  mkdir -p "$m/buzz/.claude-plugin" "$m/telegram/.claude-plugin"
  printf '{"name":"buzz","version":"0.2.0","fivedive":{"contract":"1","capabilities":["channel","verb"],"verbs":[{"name":"buzz"}]}}\n' >"$m/buzz/.claude-plugin/plugin.json"
  printf '{"name":"telegram","version":"0.5.0"}\n' >"$m/telegram/.claude-plugin/plugin.json"
  _plugin_channel_ships_verb buzz "" && echo "H1 yes" || echo "H1 no"
  _plugin_channel_ships_verb buzz 5dive-plugins && echo "H2 yes" || echo "H2 no"
  _plugin_channel_ships_verb telegram "" && echo "H3 yes" || echo "H3 no"
  _plugin_channel_ships_verb dashboard "" && echo "H4 yes" || echo "H4 no"
  # shellcheck source=/dev/null
  source "$SRC/cmd_pack.sh" 2>/dev/null; set +e
  _market_channel_verb_rows '[{"name":"buzz","marketplace":"5dive-plugins","installs":"agent"},{"name":"telegram","marketplace":"5dive-plugins","installs":"agent"},{"name":"voice","marketplace":"5dive-plugins","installs":"box"}]' \
    | jq -r '"H5 " + (map(.name + "=" + .installs) | join(","))'
) >"$WORK/h" 2>&1
grep -q '^H1 yes$' "$WORK/h" && grep -q '^H2 yes$' "$WORK/h" \
  && ok_t "H a channel whose registry manifest declares a verb installs box-wide" \
  || bad_t "H a channel whose registry manifest declares a verb installs box-wide" "$(cat "$WORK/h")"
grep -q '^H3 no$' "$WORK/h" && grep -q '^H4 no$' "$WORK/h" \
  && ok_t "H NEGATIVE: a verb-less or unresolvable channel keeps the per-agent refusal" \
  || bad_t "H NEGATIVE: a verb-less or unresolvable channel keeps the per-agent refusal" "$(cat "$WORK/h")"
grep -q '^H5 buzz=box,telegram=agent,voice=box$' "$WORK/h" \
  && ok_t "H the plugin listing marks that channel a box install, and only that one" \
  || bad_t "H the plugin listing marks that channel a box install, and only that one" "$(cat "$WORK/h")"
grep -qE '_plugin_is_builtin_channel_ref "\$_bare" "\$_refmkt" \\$' "$SRC/cmd_plugin.sh" \
  && grep -qE '&& ! _plugin_channel_ships_verb "\$_bare" "\$_refmkt"; then' "$SRC/cmd_plugin.sh" \
  && ok_t "H plugin add consults it before refusing a channel" \
  || bad_t "H plugin add consults it before refusing a channel" "the guard is not wired into cmd_plugin_add"

# --- I. the seat grant the hand-over exists for -----------------------------
# Moved from the bridge harness when the bridge left (its arm 4).
(
  set +e
  # shellcheck source=/dev/null
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh cmd_agent_create.sh lib/capability.sh; do source "$SRC/$f" 2>/dev/null; done
  set +e
  SUDOERS=$(render_standard_sudoers agent-probe 0 0 2>/dev/null)
  grep -q '^agent-probe ALL=(root) NOPASSWD: /usr/local/bin/5dive agent buzz inbound \*$' <<<"$SUDOERS" && echo "I1 yes"
  [[ "$(printf '%s\n' "$SUDOERS" | classify_sudo_grant 2>/dev/null)" == "cli-scoped|root|0" ]] && echo "I2 yes"
  _capability_names_for_standard 0 0 2>/dev/null | grep -qx 'buzz_inbound' && echo "I3 yes"
) >"$WORK/i" 2>&1
grep -q '^I1 yes$' "$WORK/i" && ok_t "I render_standard_sudoers still emits the agent buzz inbound grant" \
  || bad_t "I render_standard_sudoers still emits the agent buzz inbound grant" "$(cat "$WORK/i")"
grep -q '^I2 yes$' "$WORK/i" && ok_t "I classify_sudo_grant still reads the policy as cli-scoped" \
  || bad_t "I classify_sudo_grant still reads the policy as cli-scoped" "$(cat "$WORK/i")"
grep -q '^I3 yes$' "$WORK/i" && ok_t "I the capability registry still names buzz_inbound" \
  || bad_t "I the capability registry still names buzz_inbound" "$(cat "$WORK/i")"

# --- J. Classic's People page still saves -----------------------------------
# lodar/5dive-frontend src/app/dashboard/humans/page.tsx save() runs this argv
# on every save, with every flag present and the empty ones empty (an empty
# value CLEARS that transport). Classic is one Vercel build in front of boxes on
# every CLI version, so if core ever stops parsing --buzz= every People save on
# an updated box fails "unknown flag". The argv below is the page's, verbatim;
# the frontend's cli-contract.test.ts pins the same array from its side.
(
  set +e
  # shellcheck source=/dev/null
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
           lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_human.sh; do
    source "$SRC/$f" 2>/dev/null
  done
  set +e
  require_root() { :; }      # the write is root-only; the parse is what is graded
  audit_log() { :; }
  STATE_DIR="$WORK/j"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
  mkdir -p "$TASKS_DIR"; tasks_db_init >/dev/null 2>&1
  # A new person, Buzz left empty: exactly what the form sends.
  ( cmd_human add alice --name="Alice Example" --telegram=1234567890 --buzz= --discord= ) >/dev/null 2>&1
  echo "J1 rc=$?"
  echo "J2 $(db "SELECT COALESCE(telegram_id,'-')||'|'||COALESCE(buzz_npub,'-')||'|'||COALESCE(discord_id,'-') FROM humans WHERE id='alice';")"
  # An edit of someone who HAS a buzz id, saved with the field emptied: clears it.
  db "INSERT INTO humans (id, buzz_npub) VALUES ('bob','npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqq');"
  ( cmd_human add bob --name="Bob Example" --telegram= --buzz= --discord= ) >/dev/null 2>&1
  echo "J3 rc=$? $(db "SELECT COALESCE(buzz_npub,'-') FROM humans WHERE id='bob';")"
  # NEGATIVE CONTROL: the same harness sees a rejected flag, so J1 is not rc 0 by construction.
  ( cmd_human add carol --name=Carol --slack= ) >/dev/null 2>&1
  echo "J4 rc=$?"
) >"$WORK/jout" 2>&1
grep -q '^J1 rc=0$' "$WORK/jout" \
  && ok_t "J Classic's People-page save with an empty Buzz field exits 0" \
  || bad_t "J Classic's People-page save with an empty Buzz field exits 0" "$(cat "$WORK/jout")"
grep -q '^J2 1234567890|-|-$' "$WORK/jout" \
  && ok_t "J ...and records the person, with no buzz id" \
  || bad_t "J ...and records the person, with no buzz id" "$(cat "$WORK/jout")"
grep -q '^J3 rc=0 -$' "$WORK/jout" \
  && ok_t "J an emptied Buzz field on an edit still clears it, as before" \
  || bad_t "J an emptied Buzz field on an edit still clears it, as before" "$(cat "$WORK/jout")"
grep -qE '^J4 rc=[1-9]' "$WORK/jout" \
  && ok_t "J NEGATIVE: an unknown flag is refused by the same harness" \
  || bad_t "J NEGATIVE: an unknown flag is refused by the same harness" "$(cat "$WORK/jout")"

# --- K. the install-contract waiver lets go of buzz ---------------------------
# T5 there reds on a waived verb that is no longer in the dispatch table — the
# iteration-1 delivery missed it (quinn, 2026-10-25). Graded here so the next
# move of a verb sees it before CI's container job does.
grep -qE "^WAIVED='[^']*\bbuzz\b" scripts/install-contract.sh \
  && bad_t "K install-contract WAIVED no longer names buzz" "$(grep -n '^WAIVED=' scripts/install-contract.sh)" \
  || ok_t "K install-contract WAIVED no longer names buzz"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
