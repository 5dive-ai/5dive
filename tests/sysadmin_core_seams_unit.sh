#!/usr/bin/env bash
# DIVE-5247: `5dive sysadmin` left core for the partner plugin
# (5dive-ai/5dive-partner, installed by the partner box profile only). Its own
# harness moved with it. What stays here grades the CORE code the seat relies on:
#   (a) the built-in is gone from every enumeration core keeps, so the plugin's
#       claim of the verb installs (a built-in name refuses it, rc=3);
#   (b) a box without the plugin says so in one line, and does not offer it;
#   (c) a standard seat's sudo reaches neither owner-ask nor sysadmin, and the
#       broker grant — the cross-repo contract string — still classifies as
#       scoped in both of core's recognisers;
#   (d) owner-ask has no route into the sysadmin;
#   (e) agent create lingers seat users only where the sysadmin seat is;
#   (f) account set binds a waiting seat through the plugin's verb, and only on
#       a box whose registry has the seat;
#   (g) `install.sh --upgrade` adds the partner plugin in the same upgrade that
#       removed the built-in, only where the seat is, and only once.
# Arms b4, b5, h4, i4 and i8 of the former tests/sysadmin_unit.sh live here.
# Run: bash tests/sysadmin_core_seams_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/sysadmin-seams.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_plugin.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; REGISTRY="$TMP/agents.json"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The broker grant the plugin writes (partner/bin/sysadmin _sysadmin_sudoers).
# A contract between the two repos: the API's argv and this string never change.
GRANT='agent-sysadmin ALL=(root) NOPASSWD: /usr/local/bin/5dive sysadmin _broker
agent-sysadmin ALL=(root) NOPASSWD: /usr/local/bin/5dive --json sysadmin _broker'

echo "# (a) the built-in is gone"
main_body=$(awk '/^main\(\) \{/{f=1} f' src/main.sh)
[[ ! -e src/cmd_sysadmin.sh ]] && ! grep -q 'cmd_sysadmin' build.sh src/main.sh \
  && ! grep -qE '^    sysadmin\)' <<<"$main_body" \
  && ok_t "a1 no cmd_sysadmin.sh, not in build.sh, no case label in main()" \
  || bad_t "a1 core still carries sysadmin" "$(grep -n 'sysadmin' build.sh; grep -nE '^    sysadmin\)' <<<"$main_body")"
[[ " $FIVEDIVE_BUILTIN_VERBS " != *" sysadmin "* ]] && ! _plugin_verb_is_builtin sysadmin \
  && ok_t "a2 sysadmin is not a built-in verb, so the partner plugin's claim installs" \
  || bad_t "a2 sysadmin still built in" "$FIVEDIVE_BUILTIN_VERBS"

echo "# (b) a box without the plugin"
source <(sed -n '/^_moved_verb_repo() {/,/^}/p; /^_moved_verb_notice() {/,/^}/p' src/main.sh)
note=$(_moved_verb_notice sysadmin 2>&1 >/dev/null)
[[ "$(wc -l <<<"$note")" == 1 ]] && grep -q "'sysadmin' is not installed on this box" <<<"$note" \
  && grep -q '5dive-ai/5dive-partner' <<<"$note" && ! grep -q 'plugin add' <<<"$note" \
  && ok_t "b1 one line: not installed, a partner-box feature — it is not offered to a regular box" \
  || bad_t "b1 notice" "$note"
cnote=$(_moved_verb_notice council 2>&1 >/dev/null)
grep -q 'plugin add 5dive-ai/5dive-council' <<<"$cnote" \
  && ok_t "b2 control: the other moved verbs keep their install line" || bad_t "b2 council notice" "$cnote"

echo "# (c) sudo"
pol=$(render_standard_sudoers agent-maya 0)
! grep -qE 'owner-ask|sysadmin' <<<"$(grep -v '^#' <<<"$pol")" \
  && ok_t "c1 a standard seat's sudo reaches neither owner-ask nor sysadmin (its policy is main's)" \
  || bad_t "c1 seat policy" "$(grep -E 'owner-ask|sysadmin' <<<"$pol")"
[[ "$(classify_sudo_grant <<<"$GRANT" | cut -d'|' -f1)" == cli-scoped ]] \
  && ok_t "c2 the broker grant classifies as scoped" || bad_t "c2 classifier" "$(classify_sudo_grant <<<"$GRANT")"
grep -qF '"/usr/local/bin/5dive sysadmin _broker"|"/usr/local/bin/5dive --json sysadmin _broker"' src/cmd_agent_create.sh \
  && grep -qF '"/usr/local/bin/5dive sysadmin _broker", "/usr/local/bin/5dive --json sysadmin _broker"' src/cmd_agent.sh \
  && ok_t "c3 both recognisers still name the exact broker command the plugin grants" \
  || bad_t "c3 recognisers drifted" ""

echo "# (d) owner-ask"
! grep -q '_sysadmin' src/cmd_owner_ask.sh \
  && ok_t "d1 owner-ask has no route into the sysadmin (the old keyboard path is gone)" \
  || bad_t "d1 owner-ask routes sysadmin" "$(grep -n _sysadmin src/cmd_owner_ask.sh)"

echo "# (e) linger"
grep -q "jq -e '.agents.sysadmin != null'" src/cmd_agent_create.sh && grep -q 'loginctl enable-linger "agent-${name}"' src/cmd_agent_create.sh \
  && ok_t "e1 agent create lingers only where the sysadmin seat is (a partner box)" || bad_t "e1 linger wiring" ""

echo "# (f) account set binds a waiting seat through the plugin's verb"
# The block as shipped, run against a fake 5dive that records its argv.
hook=$(awk '/DIVE-5247: the seat.s code is the partner plugin.s now/{f=1} f{print} f&&/^  fi$/{exit}' src/cmd_account.sh)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/self.log\n' "$TMP" > "$TMP/fake5dive"; chmod +x "$TMP/fake5dive"
run_hook() { ( name="$1"; FIVEDIVE_SELF_BIN="$TMP/fake5dive"; eval "$hook" ); }
if [[ -z "$hook" ]]; then bad_t "f1 hook not found in src/cmd_account.sh" ""
else
  : > "$TMP/self.log"; printf '{"agents":{"maya":{},"sysadmin":{"pendingAuthProfile":"openrouter"}}}\n' > "$REGISTRY"
  run_hook openrouter
  [[ "$(cat "$TMP/self.log")" == 'sysadmin _bind-pending openrouter' ]] \
    && ok_t "f1 a partner box: account set asks the plugin to bind (sysadmin _bind-pending <profile>)" \
    || bad_t "f1 partner box" "$(cat "$TMP/self.log")"
  : > "$TMP/self.log"; printf '{"agents":{"maya":{}}}\n' > "$REGISTRY"
  run_hook openrouter
  [[ ! -s "$TMP/self.log" ]] && ok_t "f2 a regular box (no seat): nothing is spawned" || bad_t "f2 regular box" "$(cat "$TMP/self.log")"
  : > "$TMP/self.log"; rm -f "$REGISTRY"
  run_hook openrouter; rc=$?
  [[ ! -s "$TMP/self.log" && $rc == 0 ]] && ok_t "f3 no registry: nothing spawned, never fatal" || bad_t "f3 no registry" "rc=$rc"
fi
grep -q '_sysadmin_bind_pending' src/cmd_account.sh \
  && bad_t "f4 account set still calls the in-process function core no longer has" "" \
  || ok_t "f4 account set no longer calls a function core does not define"

echo "# (g) the upgrade installs the plugin where the seat already is"
mig=$(sed -n '/# >>> DIVE-5247 partner plugin migration/,/# <<< DIVE-5247 partner plugin migration/p' install.sh)
G="$TMP/g"; mkdir -p "$G/bin" "$G/state"
cat > "$G/bin/5dive" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$G/calls"
[ "\$1" = sysadmin ] && [ -f "$G/has-plugin" ] && exit 0
[ "\$1" = sysadmin ] && exit 2
exit 0
FAKE
chmod +x "$G/bin/5dive"
run_mig() { ( BIN_DIR="$G/bin"; STATE_DIR="$G/state"; GH_ORG=5dive-ai; say() { :; }; eval "$mig" ) >/dev/null 2>&1; }
if [[ -z "$mig" ]]; then bad_t "g1 migration block not found in install.sh" ""
else
  : > "$G/calls"; printf '{"agents":{"maya":{},"sysadmin":{}}}\n' > "$G/state/agents.json"; rm -f "$G/has-plugin"
  run_mig
  grep -qx 'plugin add 5dive-ai/5dive-partner --yes' "$G/calls" \
    && ok_t "g1 a partner box on the new core: the upgrade adds 5dive-ai/5dive-partner" || bad_t "g1 partner box" "$(cat "$G/calls")"
  : > "$G/calls"; touch "$G/has-plugin"; run_mig
  ! grep -q 'plugin add' "$G/calls" && ok_t "g2 the plugin already answers: nothing added (idempotent)" || bad_t "g2 re-run" "$(cat "$G/calls")"
  : > "$G/calls"; rm -f "$G/has-plugin"; printf '{"agents":{"maya":{}}}\n' > "$G/state/agents.json"; run_mig
  [[ ! -s "$G/calls" ]] && ok_t "g3 a regular box (no seat): not even asked" || bad_t "g3 regular box" "$(cat "$G/calls")"
fi

echo "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
