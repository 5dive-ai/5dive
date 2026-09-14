#!/usr/bin/env bash
# DIVE-4522 — a box-level `plugin add` must reach the seats that already exist.
#
# THE DEFECT THIS GRADES. browser@5dive-plugins declares `skill` and ships
# skills/connect-site. It was enabled box-wide on lodar's canary from the Sep 11
# provision, and on 2026-09-14 none of that box's four agents could see it: every
# seat's ~/.claude/plugins/installed_plugins.json carried telegram + dashboard
# only. Per-seat registration ran once, at agent create, for CHANNEL plugins —
# so a plugin added after a seat exists reached nobody, and a seat created after
# a `plugin add` reached nothing. Two directions, one gap.
#
# WHAT IS STUBBED AND WHAT IS NOT. Exactly one thing is replaced:
# `plugin_seat_run_as`, the privilege drop. Everything above it — the walker, the
# capability predicate, the per-type persona resolution, the marker writer, the
# registration read — runs for real against a temp home tree through the
# PERSONA_HOME_ROOT seam that persona_target() already owns. The stub records the
# script it was handed, so the CLAUDE_CONFIG_DIR trap (the one that cost ten
# minutes on the canary) is graded as text rather than assumed.
#
# NEGATIVE CONTROLS, five, because a green here must not be reachable by
# widening anything: M1 cuts the seat-facing test out of the shipping walker and
# proves the walk stops happening; M2 cuts `unset CLAUDE_CONFIG_DIR` out of the
# shipping registration and proves the trap arm reds; M3 cuts the walker call out
# of `cmd_plugin_add` and proves the call-site arm reds; M4 cuts the trailing
# registration READ — the sole detector of "the install did not take", since
# every line of the seat heredoc ends in `|| true` — and proves T14 reds; M5 puts
# back the whole-file AGENTS.md emit and proves T7c sees it accrete.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/lib/agent_setup.sh
# shellcheck source=/dev/null
source src/lib/plugin_seats.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh

# header.sh:14 is `set -euo pipefail`; sourcing it turns errexit on HERE, where a
# refusal we mean to grade would take the harness down. Same fix as the sibling
# plugin harnesses.
set +e -o pipefail

require_root() { :; }
# grep -c prints "0" AND exits 1 on no match, so a `|| echo 0` fallback emits the
# count TWICE. Count through one helper instead.
nblk() { [[ -f "${1:-}" ]] || { echo 0; return 0; }; grep -c -- '5dive:browser:begin' "$1" 2>/dev/null; return 0; }

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tnc(){ if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
export PERSONA_HOME_ROOT="$TMP/home"
mkdir -p "$PERSONA_HOME_ROOT"
_plugin_ensure_store

# ---- the box: one marketplace, one skill plugin, one channel plugin ---------
jq -n '{"5dive-plugins":{source:"5dive-ai/5dive-plugins",kind:"git",ref:"",added_at:"t"},
        "localmkt":{source:"/tmp/whatever",kind:"local",ref:"",added_at:"t"}}' \
  > "$(_plugin_mkt_json)"
jq -n '{"browser@5dive-plugins":{plugin:"browser",marketplace:"5dive-plugins",version:"1.3.0",
          enabled:true,capabilities:["channel","verb","skill"]},
        "telegram@5dive-plugins":{plugin:"telegram",marketplace:"5dive-plugins",version:"1.0.0",
          enabled:true,capabilities:["channel"]},
        "off@5dive-plugins":{plugin:"off",marketplace:"5dive-plugins",version:"1.0.0",
          enabled:false,capabilities:["skill"]},
        "mcponly@5dive-plugins":{plugin:"mcponly",marketplace:"5dive-plugins",version:"1.0.0",
          enabled:true,capabilities:["mcp"]}}' \
  > "$(_plugin_installed_json)"

# the enabled plugin dir, with the AGENTS.md section browser really ships
PDIR="$TMP/plugins/browser"; mkdir -p "$PDIR/skills/connect-site"
{ echo '<!-- 5dive:browser:begin -->'
  echo '# Browser — logging a human into a site'
  echo 'The viewer link belongs to the human.'
  echo '<!-- 5dive:browser:end -->'; } > "$PDIR/AGENTS.md"
mkdir -p "$(_plugin_enabled_dir)"
ln -sfn "$PDIR" "$(_plugin_enabled_dir)/browser@5dive-plugins"

# ---- the seats -------------------------------------------------------------
# Two claude seats and a codex seat, the shape the row's ACCEPT names.
registry_read() {
  jq -n '{agents:{ceo:{type:"claude"}, devops:{type:"claude"}, researcher:{type:"codex"},
                  ghost:{type:"claude"}}}'
}
for s in ceo devops researcher; do mkdir -p "$PERSONA_HOME_ROOT/agent-$s"; done
# `ghost` deliberately has NO home: a registry row whose home is gone must be
# skipped, not counted as a failure.

# ---- the one stub: the privilege drop --------------------------------------
# Records the seat and the script, and SIMULATES what `claude plugin install`
# does — writes the seat's own installed_plugins.json. Nothing else is faked.
SEAT_SCRIPTS="$TMP/seat-scripts"; : > "$SEAT_SCRIPTS"
STUB_MODE=install
plugin_seat_run_as() {
  local user="$1"; shift
  local var plugin="" mkt=""
  for var in "$@"; do
    case "$var" in PLUGIN=*) plugin="${var#PLUGIN=}" ;; MARKETPLACE=*) mkt="${var#MARKETPLACE=}" ;; esac
  done
  { printf '=== %s %s@%s\n' "$user" "$plugin" "$mkt"; cat; } >> "$SEAT_SCRIPTS"
  # STUB_MODE=noop: the drop RAN and wrote nothing. That is not a contrived
  # state — every line of the shipping heredoc ends in `|| true` (the clone, the
  # PREREG python, the marketplace update/add, the install itself), so a real
  # `claude plugin install` that fails leaves exactly this. T14 grades it.
  [[ "$STUB_MODE" == noop ]] && return 0
  local home="$PERSONA_HOME_ROOT/${user}" f
  f="$home/.claude/plugins/installed_plugins.json"
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || echo '{"plugins":{}}' > "$f"
  local tmpf; tmpf=$(mktemp)
  if [[ "$STUB_MODE" == install ]]; then
    jq --arg k "${plugin}@${mkt}" --arg p "$home/.claude/plugins/cache/${mkt}/${plugin}/1.3.0" \
       '.plugins[$k] = [{installPath:$p}]' "$f" > "$tmpf" && mv "$tmpf" "$f"
  else
    jq --arg k "${plugin}@${mkt}" 'del(.plugins[$k])' "$f" > "$tmpf" && mv "$tmpf" "$f"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# T1 — the capability predicate. This IS the line-339 warning's other half.
# ---------------------------------------------------------------------------
t "T1a a plugin declaring 'skill' is seat-facing"        "yes" "$(plugin_seat_is_seat_facing "channel verb skill" && echo yes || echo no)"
t "T1b a plugin declaring 'mcp' is seat-facing"          "yes" "$(plugin_seat_is_seat_facing "mcp" && echo yes || echo no)"
t "T1c MUTANT: channel+verb only registers with NOBODY"  "no"  "$(plugin_seat_is_seat_facing "channel verb" && echo yes || echo no)"
t "T1d MUTANT: no declared capability registers with NOBODY" "no" "$(plugin_seat_is_seat_facing "" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# T2 — seats come from the REGISTRY, with their types
# ---------------------------------------------------------------------------
rows=$(plugin_seat_rows)
tc "T2a the walker reads the registry, not a /home glob" "researcher	codex" "$rows"
t  "T2b every registered seat is enumerated" "4" "$(grep -c . <<<"$rows")"

# ---------------------------------------------------------------------------
# T3 — registration is read from the SEAT's file, never the box's
# ---------------------------------------------------------------------------
t "T3a a seat with no claude config is NOT registered" "no" \
  "$(plugin_seat_registered ceo browser 5dive-plugins && echo yes || echo no)"
mkdir -p "$PERSONA_HOME_ROOT/agent-ceo/.claude/plugins"
jq -n '{plugins:{"telegram@5dive-plugins":[{installPath:"/x"}]}}' \
  > "$PERSONA_HOME_ROOT/agent-ceo/.claude/plugins/installed_plugins.json"
t "T3b a seat carrying only telegram is NOT registered for browser" "no" \
  "$(plugin_seat_registered ceo browser 5dive-plugins && echo yes || echo no)"
t "T3c ...and IS registered for telegram (the read works at all)" "yes" \
  "$(plugin_seat_registered ceo telegram 5dive-plugins && echo yes || echo no)"

# ---------------------------------------------------------------------------
# T4 — registering one claude seat, and the trap
# ---------------------------------------------------------------------------
plugin_seat_register_claude ceo browser 5dive-plugins 2>/dev/null
t "T4a the seat is registered afterwards" "yes" \
  "$(plugin_seat_registered ceo browser 5dive-plugins && echo yes || echo no)"
script=$(cat "$SEAT_SCRIPTS")
tc "T4b THE TRAP: the seat script unsets CLAUDE_CONFIG_DIR (a login shell reads claude's config and dies on 'not found in marketplace')" \
   "unset CLAUDE_CONFIG_DIR" "$script"
tc "T4c it installs the QUALIFIED ref, so a second marketplace cannot capture it" \
   'plugin install "${PLUGIN}@${MARKETPLACE}"' "$script"
tc "T4d it pre-registers the marketplace (headless 'marketplace add' crashes for a seat that never ran a session — DIVE-248)" \
   "known_marketplaces.json" "$script"
tnc "T4e it does NOT npm-install or patch a start script (that is the CHANNEL installer's job, and doing it here would half-install a service)" \
   "npm install" "$script"

# ---------------------------------------------------------------------------
# T5 — a marketplace a seat cannot clone is refused, loudly, not silently skipped
# ---------------------------------------------------------------------------
err=$(plugin_seat_register_claude devops browser localmkt 2>&1 >/dev/null); rc=$?
t  "T5a a LOCAL marketplace cannot be registered with a seat" "2" "$rc"
tc "T5b ...and it says so rather than reporting success" "NOT registered" "$err"

# ---------------------------------------------------------------------------
# T6 — a non-claude seat gets the AGENTS.md section, at ITS harness's path
# ---------------------------------------------------------------------------
plugin_seat_doc_install researcher codex browser "$PDIR" >/dev/null 2>&1
CODEX_MD="$PERSONA_HOME_ROOT/agent-researcher/.codex/AGENTS.md"
t  "T6a the section lands at TYPE_PERSONA_FILE[codex], not .claude/*" "yes" \
   "$([[ -f "$CODEX_MD" ]] && echo yes || echo no)"
t  "T6b nothing was written under .claude for a codex seat" "no" \
   "$([[ -e "$PERSONA_HOME_ROOT/agent-researcher/.claude/CLAUDE.md" ]] && echo yes || echo no)"
tc "T6c the block is delimited by the plugin's own markers" "<!-- 5dive:browser:begin -->" "$(cat "$CODEX_MD")"
tc "T6d ...and carries the publisher's text" "The viewer link belongs to the human." "$(cat "$CODEX_MD")"

# ---------------------------------------------------------------------------
# T7 — re-running converges instead of accreting
# ---------------------------------------------------------------------------
plugin_seat_doc_install researcher codex browser "$PDIR" >/dev/null 2>&1
plugin_seat_doc_install researcher codex browser "$PDIR" >/dev/null 2>&1
t "T7a three installs leave exactly ONE block" "1" "$(grep -c -- '5dive:browser:begin' "$CODEX_MD")"

# T7b-e — ACCRETION, the shape the browser fixture above CANNOT see. browser's
# real AGENTS.md carries its markers on the first and last line, so "the
# delimited region" and "the whole file" are the same string and the two cases
# collapse into one. The moment a publisher adds a heading, a licence footer, or
# delimits only PART of the file, they stop being the same: doc_install replaces
# the begin..end region with whatever doc_block returns, so returning the whole
# file re-inserts every out-of-marker byte INSIDE the markers on every run, and
# `plugin add` / `plugin upgrade` / the agent-create backfill each add a copy to
# the file the agent reads every turn. Measured 1/2/3 copies over three installs.
PDIR2="$TMP/plugins/wrapped"; mkdir -p "$PDIR2"
{ echo '# Browser plugin — notes for maintainers'
  echo '<!-- 5dive:browser:begin -->'
  echo 'The viewer link belongs to the human.'
  echo '<!-- 5dive:browser:end -->'
  echo 'Published by 5dive-ai. Licence: MIT.'; } > "$PDIR2/AGENTS.md"
rm -f "$CODEX_MD"
for _i in 1 2 3; do plugin_seat_doc_install researcher codex browser "$PDIR2" >/dev/null 2>&1; done
t "T7b three installs of a PARTIALLY delimited AGENTS.md leave ONE block" "1" "$(nblk "$CODEX_MD")"
t "T7c ...and the publisher's text ABOVE its markers is not copied in at all" "0" \
  "$(grep -c 'notes for maintainers' "$CODEX_MD")"
t "T7d ...nor the footer BELOW them" "0" "$(grep -c 'Licence: MIT' "$CODEX_MD")"
tc "T7e ...while the delimited text itself did land" "The viewer link belongs to the human." "$(cat "$CODEX_MD")"
rm -f "$CODEX_MD"; plugin_seat_doc_install researcher codex browser "$PDIR" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# T8 — removal is exact: the block goes, operator text around it stays
# ---------------------------------------------------------------------------
printf '\n# my own notes\n' >> "$CODEX_MD"
plugin_seat_doc_remove researcher codex browser >/dev/null 2>&1
t  "T8a the block is gone" "0" "$(nblk "$CODEX_MD")"
tc "T8b the operator's own text survived" "# my own notes" "$(cat "$CODEX_MD")"

# ---------------------------------------------------------------------------
# T9 — the whole walk, which is the row's ACCEPT clause
# ---------------------------------------------------------------------------
rm -rf "$PERSONA_HOME_ROOT/agent-ceo/.claude" "$PERSONA_HOME_ROOT/agent-devops/.claude" "$CODEX_MD"
: > "$SEAT_SCRIPTS"
walkout=$(plugin_seat_apply browser 5dive-plugins "channel verb skill" register "$PDIR" 2>&1)
t "T9a claude seat 1 carries browser after the walk" "yes" \
  "$(plugin_seat_registered ceo browser 5dive-plugins && echo yes || echo no)"
t "T9b claude seat 2 carries browser after the walk" "yes" \
  "$(plugin_seat_registered devops browser 5dive-plugins && echo yes || echo no)"
t "T9c the codex seat carries the instructions section" "1" \
  "$(nblk "$CODEX_MD")"
tc "T9d the walk REPORTS per seat (the old silence is the defect)" "ceo (claude): browser@5dive-plugins registered" "$walkout"
tc "T9e a registry row whose home is gone is skipped, not failed" "0 failed" "$walkout"

# MUTANT: the same walk for a plugin that declares no seat-facing capability
rm -rf "$PERSONA_HOME_ROOT/agent-ceo/.claude"; : > "$SEAT_SCRIPTS"
plugin_seat_apply telegram 5dive-plugins "channel" register "$PDIR" >/dev/null 2>&1
t "T9f MUTANT: a channel-only plugin registers with NOBODY (line 339's warning stays true)" "yes" \
  "$([[ ! -s "$SEAT_SCRIPTS" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# T10 — the state doctor reports: enabled here, invisible there
# ---------------------------------------------------------------------------
miss=$(plugin_seat_unregistered_rows)
tc "T10a the seat with no registration is named"       "ceo	claude	browser@5dive-plugins" "$miss"
tnc "T10b a seat that IS registered is not named"      "devops	claude	browser" "$miss"
tnc "T10c a channel-only plugin is never reported missing" "telegram@5dive-plugins" "$miss"
tnc "T10d a DISABLED skill plugin is never reported missing" "off@5dive-plugins" "$miss"
tnc "T10e a codex seat CARRYING the section is not reported (it is graded by its markers, not by installed_plugins.json)" "researcher	codex" "$miss"
tnc "T10f a registry row whose home is gone is NOT reported — the walker skips it, so a finding here would name a seat whose stated fix (re-run the walk) skips it again" \
    "ghost" "$miss"
tnc "T10g a seat-facing plugin shipping no AGENTS.md is not a finding against a codex seat (there is nothing to give that harness)" \
    "researcher	codex	mcponly@5dive-plugins" "$miss"
tc  "T10h ...but it IS a finding against a claude seat, which registers it as a plugin" \
    "ceo	claude	mcponly@5dive-plugins" "$miss"
mv "$CODEX_MD" "$CODEX_MD.bak"
miss_codex=$(plugin_seat_unregistered_rows)
tc "T10i a codex seat MISSING the plugin's instructions section IS reported — the half of this fix that serves non-claude harnesses has a surface too" \
   "researcher	codex	browser@5dive-plugins" "$miss_codex"
mv "$CODEX_MD.bak" "$CODEX_MD"
t  "T10j the seats doctor COUNTS are the seats it GRADED (ghost has no home, so 3 not 4)" "3" \
   "$(plugin_seat_graded_rows | grep -c .)"

# ---------------------------------------------------------------------------
# T11 — the other direction: a seat created AFTER the box installed the plugin
# ---------------------------------------------------------------------------
mkdir -p "$PERSONA_HOME_ROOT/agent-newbie"
plugin_seat_backfill newbie claude >/dev/null 2>&1
t  "T11a a brand-new claude seat gets the already-enabled skill plugin" "yes" \
   "$(plugin_seat_registered newbie browser 5dive-plugins && echo yes || echo no)"
t  "T11b ...and NOT the channel plugin (that is install_channel_for_agent's job)" "no" \
   "$(plugin_seat_registered newbie telegram 5dive-plugins && echo yes || echo no)"
t  "T11c ...and NOT a disabled one" "no" \
   "$(plugin_seat_registered newbie off 5dive-plugins && echo yes || echo no)"
mkdir -p "$PERSONA_HOME_ROOT/agent-newcodex"
plugin_seat_backfill newcodex codex >/dev/null 2>&1
t  "T11d a brand-new codex seat gets the instructions section" "1" \
   "$(nblk "$PERSONA_HOME_ROOT/agent-newcodex/.codex/AGENTS.md")"

# ---------------------------------------------------------------------------
# T12 — unregister, the reverse walk `plugin remove` owes
# ---------------------------------------------------------------------------
STUB_MODE=uninstall
plugin_seat_apply browser 5dive-plugins "channel verb skill" unregister "$PDIR" >/dev/null 2>&1
t "T12a the claude seat no longer carries it" "no" \
  "$(plugin_seat_registered devops browser 5dive-plugins && echo yes || echo no)"
t "T12b the codex seat's section is gone" "0" \
  "$(nblk "$CODEX_MD")"
STUB_MODE=install

# ---------------------------------------------------------------------------
# CALL SITES — a walker nothing calls is the defect wearing a test suite
# ---------------------------------------------------------------------------
add_src=$(declare -f cmd_plugin_add)
rm_src=$(declare -f cmd_plugin_remove)
up_src=$(declare -f cmd_plugin_upgrade)
tc "T13a cmd_plugin_add walks the seats"      "plugin_seat_apply" "$add_src"
tc "T13b cmd_plugin_remove reverses the walk" "plugin_seat_apply" "$rm_src"
tc "T13c cmd_plugin_upgrade re-pins the seats" "plugin_seat_apply" "$up_src"
tc "T13d agent create backfills a new seat"   "plugin_seat_backfill" \
   "$(grep -c 'plugin_seat_backfill' src/cmd_agent_create.sh >/dev/null && grep -h 'plugin_seat_backfill' src/cmd_agent_create.sh || echo NONE)"
tc "T13e doctor reports the gap"              "plugin_seat_unregistered_rows" \
   "$(grep -h 'plugin_seat_unregistered_rows' src/cmd_doctor.sh || echo NONE)"
tc "T13f the lib is in the bundle"            "src/lib/plugin_seats.sh" \
   "$(grep -h 'plugin_seats.sh' build.sh || echo NONE)"

# ---------------------------------------------------------------------------
# T14 — THE HONEST FAILURE, and the one line that produces it
# ---------------------------------------------------------------------------
# Every line of the seat heredoc ends in `|| true` BY DESIGN — the clone, the
# PREREG python, the marketplace update/add, the install itself — so the exit
# status of the privilege drop carries no information whatsoever. The trailing
# `plugin_seat_registered` read is therefore the SOLE detector of "the install
# did not take", and it is what turns a silent failure into
# "NOT registered — run 'sudo 5dive doctor'". Until STUB_MODE=noop existed, no
# arm ever reached the drop and failed: the stub always wrote the seat's file,
# and T5a/T5b grade the _plugin_seat_mkt_repo early return, a different branch
# BEFORE the drop. In a delivery whose only on-box arm is signed as owed, this
# suite is the entire evidence base, and this was the line inside it that could
# be deleted green.
STUB_MODE=noop
rm -rf "$PERSONA_HOME_ROOT/agent-ceo/.claude"
plugin_seat_register_claude ceo browser 5dive-plugins >/dev/null 2>&1; noop_rc=$?
t "T14a a registration whose drop ran and wrote nothing returns NON-ZERO" "1" "$noop_rc"
noopwalk=$( registry_read() { jq -n '{agents:{ceo:{type:"claude"}}}'; }
            plugin_seat_apply browser 5dive-plugins "channel verb skill" register "$PDIR" 2>&1 )
tc "T14b ...and the walk says so rather than claiming a success it did not get" \
   "ceo (claude): browser@5dive-plugins NOT registered" "$noopwalk"
tc "T14c ...and the tally agrees"        "0 ok, 1 failed" "$noopwalk"
t  "T14d ...and the walk returns non-zero" "1" \
   "$( registry_read() { jq -n '{agents:{ceo:{type:"claude"}}}'; }
       plugin_seat_apply browser 5dive-plugins "channel verb skill" register "$PDIR" >/dev/null 2>&1; echo $? )"
STUB_MODE=install

# ---------------------------------------------------------------------------
# T15 — DOCTOR'S OWN LINE, run rather than grepped
# ---------------------------------------------------------------------------
# T13e only proves doctor MENTIONS the walker. The sentence doctor prints is its
# own claim, and a green one that counts seats it never graded is this row's
# defect one layer out: `plugin add` said "registers: skill" about a box while it
# was false about every agent on it, and "registered with all 3 seat(s)" while
# two were measured is the same sentence. So the function is extracted and RUN,
# against a stub doctor_add that records the verdict it was handed.
eval "$(sed -n '/^doctor_check_plugin_seat_registration()/,/^}/p' src/cmd_doctor.sh)"
DOCTOR_OUT=""
doctor_add() { DOCTOR_OUT="$3|$4"; }

# Make every GRADED seat carry every enabled seat-facing plugin, so the report is
# silent and doctor takes its ok path. mcponly ships no AGENTS.md, so it is
# nothing to give the codex seat and is not owed there.
for s in ceo devops; do
  mkdir -p "$PERSONA_HOME_ROOT/agent-$s/.claude/plugins"
  jq -n '{plugins:{"browser@5dive-plugins":[{installPath:"/x"}],
                   "mcponly@5dive-plugins":[{installPath:"/x"}]}}' \
    > "$PERSONA_HOME_ROOT/agent-$s/.claude/plugins/installed_plugins.json"
done
rm -f "$CODEX_MD"; plugin_seat_doc_install researcher codex browser "$PDIR" >/dev/null 2>&1
DOCTOR_OUT=""; doctor_check_plugin_seat_registration
t  "T15a with nothing missing doctor is green"  "ok" "${DOCTOR_OUT%%|*}"
tc "T15b ...and counts the seats it GRADED, not the registry rows (ghost has no home: 3, not 4)" \
   "all 3 graded seat(s)" "$DOCTOR_OUT"
tnc "T15c ...so it never claims coverage of a seat it skipped" "all 4" "$DOCTOR_OUT"

# And the warn path, whose remedy must be reachable: the seat it names is one the
# walk will actually act on.
rm -f "$PERSONA_HOME_ROOT/agent-ceo/.claude/plugins/installed_plugins.json"
DOCTOR_OUT=""; doctor_check_plugin_seat_registration
t  "T15d a seat missing a plugin is a warn"     "warn" "${DOCTOR_OUT%%|*}"
tc "T15e ...naming the seat and the plugin"     "ceo:browser@5dive-plugins" "$DOCTOR_OUT"
tnc "T15f ...and never naming the homeless row the fix cannot reach" "ghost:" "$DOCTOR_OUT"

# No seats at all is UNKNOWN, not green: absent is not clean.
DOCTOR_OUT=""; ( registry_read() { jq -n '{agents:{}}'; }
                 doctor_check_plugin_seat_registration
                 printf '%s' "$DOCTOR_OUT" ) > "$TMP/doc-empty"
t  "T15g no gradeable seat reads UNKNOWN, not ok" "warn" "$(cut -d'|' -f1 "$TMP/doc-empty")"
tc "T15h ...and says nothing was measured" "nothing was measured" "$(cat "$TMP/doc-empty")"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROLS — cut a named term out of the SHIPPING function's own text
# and prove the cut landed and the arm it protects goes red.
# ---------------------------------------------------------------------------
# M1: remove the seat-facing gate from the walker. Without it the walk would run
# for a channel-only plugin, which T9f forbids.
m1=$(declare -f plugin_seat_apply | sed 's/plugin_seat_is_seat_facing "\$caps" || return 0/: /')
t "M1a the mutation landed (the gate is gone from the mutant's text)" "0" \
  "$(grep -c 'plugin_seat_is_seat_facing "\$caps"' <<<"$m1")"
( eval "$m1"; : > "$SEAT_SCRIPTS"
  plugin_seat_apply telegram 5dive-plugins "channel" register "$PDIR" >/dev/null 2>&1
  [[ -s "$SEAT_SCRIPTS" ]] ) \
  && { PASS=$((PASS+1)); } \
  || { FAIL=$((FAIL+1)); printf 'FAIL: M1b cutting the seat-facing gate did NOT make the channel-only plugin register — T9f is vacuous\n'; }
: > "$SEAT_SCRIPTS"

# M2: remove the CLAUDE_CONFIG_DIR unset from the shipping registration.
m2=$(declare -f plugin_seat_register_claude | sed '/^unset CLAUDE_CONFIG_DIR$/d')
t "M2a the mutation landed" "0" "$(grep -c '^unset CLAUDE_CONFIG_DIR$' <<<"$m2")"
( eval "$m2"; : > "$SEAT_SCRIPTS"
  plugin_seat_register_claude ceo browser 5dive-plugins >/dev/null 2>&1
  ! grep -q 'unset CLAUDE_CONFIG_DIR' "$SEAT_SCRIPTS" ) \
  && { PASS=$((PASS+1)); } \
  || { FAIL=$((FAIL+1)); printf 'FAIL: M2b cutting the unset did NOT red the trap arm — T4b is vacuous\n'; }

# M3: remove the walker call from cmd_plugin_add. T13a must then fail.
m3=$(declare -f cmd_plugin_add | sed 's/plugin_seat_apply/: NOTCALLED/')
t "M3a the mutation landed" "0" "$(grep -c 'plugin_seat_apply' <<<"$m3")"
if [[ "$m3" == *"plugin_seat_apply"* ]]; then
  FAIL=$((FAIL+1)); printf 'FAIL: M3b the call-site arm cannot distinguish a walker call from its absence\n'
else
  PASS=$((PASS+1))
fi

# M4: replace the SOLE honest-failure detector — the trailing
# `plugin_seat_registered` in plugin_seat_register_claude — with a bare success.
# The shipping behaviour is correct; before T14 existed it was protected by
# nothing, and this mutant survived the suite at full green.
m4=$(declare -f plugin_seat_register_claude | sed 's|plugin_seat_registered "$name" "$plugin" "$mkt"|return 0|')
t "M4a the mutation landed (the detector is gone from the mutant's text)" "0" \
  "$(grep -c 'plugin_seat_registered' <<<"$m4")"
STUB_MODE=noop
( eval "$m4"
  rm -rf "$PERSONA_HOME_ROOT/agent-ceo/.claude"
  plugin_seat_register_claude ceo browser 5dive-plugins >/dev/null 2>&1 ); m4rc=$?
STUB_MODE=install
if (( m4rc == 0 )); then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); printf 'FAIL: M4b cutting the final plugin_seat_registered did NOT make a drop that wrote nothing report success — T14a is vacuous\n'
fi

# M5: put back the whole-file emit doc_block used to return for an
# already-delimited AGENTS.md, and prove T7c sees the accretion it was written
# for. The mutant must leave >= 2 copies of the publisher's out-of-marker text.
m5=$(declare -f plugin_seat_doc_block | sed 's|_plugin_seat_doc_region "$body" "$b" "$e"|printf "%s" "$body"|')
t "M5a the mutation landed (the region extraction is gone)" "0" \
  "$(grep -c '_plugin_seat_doc_region' <<<"$m5")"
m5n=$( eval "$m5"
       rm -f "$CODEX_MD"
       for _i in 1 2 3; do plugin_seat_doc_install researcher codex browser "$PDIR2" >/dev/null 2>&1; done
       grep -c 'notes for maintainers' "$CODEX_MD" 2>/dev/null; true )
if (( ${m5n:-0} >= 2 )); then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); printf 'FAIL: M5b returning the whole AGENTS.md did NOT accrete (%s copies) — T7c is vacuous\n' "${m5n:-0}"
fi

printf 'plugin_seat_registration_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 && "$PASS" -ge 40 ]]
