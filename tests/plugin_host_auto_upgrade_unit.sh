#!/usr/bin/env bash
# DIVE-6618 — self-update moves box-wide plugins the way the managed fleet does.
#
# A self-installed (curl) box ran `5dive self-update` every night and never moved
# a box-wide plugin: nothing refreshed /var/lib/5dive/plugins/marketplaces/<name>
# and nothing ran `plugin upgrade`, so voice sat on 1.8.0 under a published
# 1.10.0 whose setup carried the edge-tts fix, and every `5dive-speak` 403'd.
# `update --check` said nothing, because it only looked at the CLI.
#
# What is graded here, against real git clones served through the github seam:
#   T1  an official plugin one version behind is upgraded; a community one is
#       reported and NOT upgraded (accept 1)
#   T2  setup: inputs moved + never run here -> named as owed; inputs moved +
#       run here before -> run again; only a README moved -> nothing
#   T3  never touched: a disabled official plugin, a marketplace offering LOWER
#   T4  a plugin that cannot move is the verb's own non-zero exit with a reason
#   T5  `update --check` lists a host plugin behind, from a clone nobody refreshed
#       (accept 3)
#   T6  install.sh --upgrade runs it from the fresh CLI, survives its failure,
#       and skips an older CLI that lacks the verb
#
# LABELS. [D] = red on the pre-fix tree (origin/main 95e38edb; accept 2, the
# negative control). [C] = a control, green on both trees. [F] = a fence that
# passes on both (a "not listed" / "carried on" that an absent feature also
# satisfies), labelled so nobody reads it as evidence. On the old tree the [D]
# arms are red by absence of the verb, and T6 by absence of the installer block.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
# shellcheck source=/dev/null
source src/cmd_selfupdate.sh
set +e -o pipefail   # header.sh turns errexit on; run() below needs it off

require_root() { :; }
# The seat walk is not the subject and must never touch a real seat on the host.
plugin_seat_apply() { return 0; }
plugin_seat_is_seat_facing() { return 1; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"
unset FIVEDIVE_PLUGIN_REGISTRY
export GH_ORG=5dive-ai; unset _GH_ORG_RESOLVED
JSON_MODE=0

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

OUT=""; ERR=""; RC=0
run() {
  local o="$TMP/.o" e="$TMP/.e"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  return 0
}
ver() { jq -r --arg k "$1" '.[$k].version // "ABSENT"' "$(_plugin_installed_json)"; }

# shellcheck source=/dev/null
. tests/lib/github_fixture.sh
G="$TMP/github"
gh_fixture_seam "$G"

# mkrepo <owner>/<repo> <plugin> <version> <review> [<setup-command>]
mkrepo() {
  local d="$G/$1.git" p="$2" v="$3" r="$4" setup="${5:-}"
  mkdir -p "$d/.claude-plugin" "$d/$p/.claude-plugin" "$d/$p/bin"
  jq -cn --arg p "$p" --arg v "$v" --arg r "$r" --arg s "$setup" \
    '{name:$p, version:$v, description:"fixture", author:{name:"t"},
      fivedive:{contract:"1", capabilities:["channel"], grants:["network"],
                trust:{publisher:"t", did:"did:key:t", review:$r}}}
     | if $s != "" then .fivedive.setup = {hint:"engine", command:$s} else . end' \
    > "$d/$p/.claude-plugin/plugin.json"
  printf '#!/bin/sh\necho engine %s\n' "$v" > "$d/$p/bin/installer"
  jq -cn --arg p "$p" '{name:$p, owner:{name:"t"}, plugins:[{name:$p, description:"f", source:("./" + $p)}]}' \
    > "$d/.claude-plugin/marketplace.json"
  gh_fixture_publish "$d" >/dev/null
}
# bump <owner>/<repo> <plugin> <version> [engine|readme|badgrant]
bump() {
  local d="$G/$1.git" p="$2" v="$3" what="${4:-engine}"
  jq --arg v "$3" '.version=$v' "$d/$p/.claude-plugin/plugin.json" > "$TMP/x" && mv "$TMP/x" "$d/$p/.claude-plugin/plugin.json"
  case "$what" in
    engine)   printf '#!/bin/sh\necho engine %s\n' "$v" > "$d/$p/bin/installer" ;;
    readme)   printf 'notes for %s\n' "$v" > "$d/$p/README.md" ;;
    badgrant) jq '.fivedive.grants = ["not-a-grant"]' "$d/$p/.claude-plugin/plugin.json" > "$TMP/x" \
                && mv "$TMP/x" "$d/$p/.claude-plugin/plugin.json" ;;
  esac
  gh_fixture_publish "$d" >/dev/null
}

SETUP_MARK="$TMP/setup-ran"
mkrepo 5dive-ai/5dive-plugins regplug 1.0.0 official           # the registry itself
mkrepo 5dive-ai/5dive-voice   voice   1.8.0 official "touch $SETUP_MARK"
mkrepo 5dive-ai/5dive-good    good    1.0.0 official
mkrepo 5dive-ai/5dive-off     off     1.0.0 official
mkrepo acme/third             third   1.0.0 community

for r in 5dive-ai/5dive-voice 5dive-ai/5dive-good 5dive-ai/5dive-off acme/third; do
  run cmd_plugin_add "$r" --yes
  [[ "$RC" == 0 ]] || { echo "fixture: plugin add $r failed: $ERR"; exit 1; }
done
run cmd_plugin_disable off@5dive-off
t "T0a [C] fixtures installed at their first versions" "1.8.0|1.0.0|1.0.0|1.0.0" \
  "$(ver voice@5dive-voice)|$(ver good@5dive-good)|$(ver off@5dive-off)|$(ver third@third)"
t "T0b [C] voice is official, third is community (tier from the SOURCE)" "official|community" \
  "$(jq -r '.["voice@5dive-voice"].review + "|" + .["third@third"].review' "$(_plugin_installed_json)")"

# =============================================================================
# T5 first — `update --check` reads what is PUBLISHED from a clone nobody has
# refreshed (the state the reporting box was in for twelve nights).
# =============================================================================
bump 5dive-ai/5dive-voice voice 1.10.0 engine
bump acme/third third 1.1.0 engine
bump 5dive-ai/5dive-off off 1.1.0 engine
t "T5a [C] the box's own clone still offers voice 1.8.0 (nothing refreshed it)" "1.8.0" \
  "$(jq -r .version "$STATE_DIR/plugins/marketplaces/5dive-voice/voice/.claude-plugin/plugin.json")"
HB="$(_plugin_host_behind 2>/dev/null)"
tc "T5b [D] update --check's survey sees voice 1.8.0 -> 1.10.0, official" $'voice@5dive-voice\t1.8.0\t1.10.0\tofficial' "$HB"
tc "T5c [D] ...and third 1.0.0 -> 1.1.0, community" $'third@third\t1.0.0\t1.1.0\tcommunity' "$HB"
tn "T5d [F] ...and not a DISABLED plugin" "off@5dive-off" "$HB"
tn "T5e [F] ...and not one that is current" "good@5dive-good" "${HB:-<empty>}"
t "T5f [C] the survey reset nothing: the clone still holds 1.8.0" "1.8.0" \
  "$(jq -r .version "$STATE_DIR/plugins/marketplaces/5dive-voice/voice/.claude-plugin/plugin.json")"

_published_cli_probe() { printf 'consistent\n%s\nfixture\n' "$FIVE_VERSION"; }
_cli_freeze_observe() { printf 'unknown\n\nfixture\nyes\n'; }
export CLI_TARGET_RECEIPT_FILE="$TMP/no-receipt"
run cmd_update_check
t  "T5g [C] update --check still answers for the CLI" "0" "$RC"
tc "T5h [D] update --check prints the stale official host plugin and who moves it" \
  "voice@5dive-voice 1.8.0 -> 1.10.0 (official: sudo 5dive self-update moves it)" "$OUT"
tc "T5i [D] ...and the community one with the command its owner runs" \
  "third@third 1.0.0 -> 1.1.0 (community: sudo 5dive plugin upgrade third@third)" "$OUT"
JSON_MODE=1; run cmd_update_check; JSON_MODE=0
t  "T5j [D] --json carries hostPluginsBehind" "2|voice@5dive-voice" \
  "$(jq -r '(.data.hostPluginsBehind | length|tostring) + "|" + .data.hostPluginsBehind[0].plugin' <<<"$OUT" 2>/dev/null)"

# =============================================================================
# T1 — the self-update pass: official moves, community is reported
# =============================================================================
run cmd_plugin_auto_upgrade
t  "T1a [D] auto-upgrade exits 0 when every official plugin moved" "0" "$RC"
t  "T1b [D] the stale OFFICIAL plugin is upgraded 1.8.0 -> 1.10.0" "1.10.0" "$(ver voice@5dive-voice)"
t  "T1c [D] ...and the enabled pointer is the 1.10.0 copy" "$STATE_DIR/plugins/cache/5dive-voice/voice/1.10.0" \
  "$(readlink "$STATE_DIR/plugins/enabled/voice@5dive-voice")"
t  "T1d [C] the COMMUNITY plugin is NOT upgraded" "1.0.0" "$(ver third@third)"
tc "T1e [D] ...it is reported, with the command its owner runs" \
  "third@third at 1.0.0, the marketplace offers 1.1.0 — a community plugin moves only when you run: sudo 5dive plugin upgrade third@third" "$ERR"
tc "T1f [D] the upgrade is said per plugin" "upgraded voice@5dive-voice 1.8.0 -> 1.10.0" "$ERR"
# T2a: voice's engine changed and nobody on this box ever ran its setup.
tc "T2a [D] a moved setup input never run here is NAMED as owed, with its command" \
  "voice@5dive-voice 1.10.0 changed its host setup" "$ERR"
t  "T2b [C] ...and it was not run behind the owner's back" "absent" "$([[ -e "$SETUP_MARK" ]] && echo ran || echo absent)"
t  "T3a [C] a DISABLED official plugin is left alone" "1.0.0" "$(ver off@5dive-off)"
tn "T3b [C] ...and no upgrade line names it" "upgraded off@5dive-off" "$ERR"
t  "T3c [C] an up-to-date plugin is untouched" "1.0.0" "$(ver good@5dive-good)"

JSON_MODE=1; run cmd_plugin_auto_upgrade; JSON_MODE=0
t  "T1g [D] a second pass is a no-op that still answers in JSON" "0|0|1" \
  "$RC|$(jq -r '.data.upgraded | length' <<<"$OUT" 2>/dev/null)|$(jq -r '.data.behind | length' <<<"$OUT" 2>/dev/null)"

# =============================================================================
# T2 — setup runs again when THIS box ran it before and its inputs moved
# =============================================================================
jq '.["voice@5dive-voice"].setup = {ok:true, rc:0}' "$(_plugin_installed_json)" > "$TMP/x" \
  && mv "$TMP/x" "$(_plugin_installed_json)"
bump 5dive-ai/5dive-voice voice 1.11.0 engine
run cmd_plugin_auto_upgrade
t  "T2c [D] voice 1.10.0 -> 1.11.0" "0|1.11.0" "$RC|$(ver voice@5dive-voice)"
t  "T2d [D] its engine moved and setup ran here before: setup runs again" "ran" "$([[ -e "$SETUP_MARK" ]] && echo ran || echo absent)"
tc "T2e [D] ...and says why" "re-ran voice@5dive-voice's host setup" "$ERR"
rm -f "$SETUP_MARK"
bump 5dive-ai/5dive-voice voice 1.12.0 readme
run cmd_plugin_auto_upgrade
t  "T2f [D] a README-only release still upgrades" "0|1.12.0" "$RC|$(ver voice@5dive-voice)"
t  "T2g [C] ...but its setup inputs did not move, so setup does not run" "absent" "$([[ -e "$SETUP_MARK" ]] && echo ran || echo absent)"

# =============================================================================
# T3d — never downwards
# =============================================================================
bump 5dive-ai/5dive-good good 0.9.0 engine
run cmd_plugin_auto_upgrade
t  "T3d [D] a marketplace offering a LOWER version is left alone" "0|1.0.0" "$RC|$(ver good@5dive-good)"

# =============================================================================
# T4 — a plugin that cannot move is the verb's own exit, with its own reason
# =============================================================================
bump 5dive-ai/5dive-good good 1.1.0 badgrant
run cmd_plugin_auto_upgrade
t  "T4a [F] an official upgrade that fails exits non-zero" "nonzero" "$([[ "$RC" != 0 ]] && echo nonzero || echo "rc=$RC")"
tc "T4b [D] ...naming the plugin and the versions" "could not upgrade good@5dive-good 1.0.0 -> 1.1.0" "$ERR"
tc "T4c [D] ...and the summary says which failed" "1 FAILED (good@5dive-good)" "$ERR"
t  "T4d [C] ...and the plugin stays where it was" "1.0.0" "$(ver good@5dive-good)"

# =============================================================================
# T6 — install.sh --upgrade runs it, from the fresh CLI, and survives it
# =============================================================================
BLOCK="$(sed -n '/^  # >>> DIVE-6618 host plugins/,/^  # <<< DIVE-6618 host plugins/p' install.sh)"
t "T6a [D] the installer block is extractable" "yes" "$([[ "$BLOCK" == *'plugin auto-upgrade'* ]] && echo yes || echo no)"
# stub <dir> <has-verb 0|1> <auto-upgrade rc>
stub() {
  mkdir -p "$1"
  cat > "$1/5dive" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$1/calls"
if [[ "\$*" == "plugin --help" ]]; then
  echo "  5dive plugin upgrade <plugin>"
  (( $2 )) && echo "  5dive plugin auto-upgrade"
  exit 0
fi
[[ "\$*" == "plugin auto-upgrade" ]] && { echo "error: stub failed" >&2; exit $3; }
exit 0
STUB
  chmod +x "$1/5dive"
}
runblock() {  # <bin-dir>
  ( set -euo pipefail; say() { echo "→ $*"; }; BIN_DIR="$1"; eval "$BLOCK"; echo "AFTER-BLOCK" ) 2>&1
}
stub "$TMP/b-ok" 1 0;   O1="$(runblock "$TMP/b-ok")"
t  "T6b [D] --upgrade calls 'plugin auto-upgrade' on the fresh CLI" "yes" \
  "$(grep -qx 'plugin auto-upgrade' "$TMP/b-ok/calls" 2>/dev/null && echo yes || echo no)"
tc "T6c [F] ...under set -euo pipefail and carries on" "AFTER-BLOCK" "$O1"
stub "$TMP/b-fail" 1 1; O2="$(runblock "$TMP/b-fail")"
tc "T6d [F] its failure never stops the upgrade" "AFTER-BLOCK" "$O2"
tc "T6e [D] ...and is said in its own words" "box plugins: some did not upgrade" "$O2"
stub "$TMP/b-old" 0 0;  O3="$(runblock "$TMP/b-old")"
t  "T6f [F] an older CLI without the verb is skipped, not failed" "no|yes" \
  "$(grep -qx 'plugin auto-upgrade' "$TMP/b-old/calls" 2>/dev/null && echo yes || echo no)|$([[ "$O3" == *AFTER-BLOCK* ]] && echo yes || echo no)"
LINE_AU=$(grep -n 'plugin auto-upgrade 2>&1' install.sh | head -1 | cut -d: -f1)
LINE_RP=$(grep -n '"$BIN_DIR/5dive-refresh-plugins.sh" 2>&1' install.sh | head -1 | cut -d: -f1)
t  "T6g [D] it runs BEFORE the seat refresh, so seats re-pin at the new version" "yes" \
  "$([[ -n "$LINE_AU" && -n "$LINE_RP" && "$LINE_AU" -lt "$LINE_RP" ]] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
