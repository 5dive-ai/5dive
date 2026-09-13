#!/usr/bin/env bash
# DIVE-4466 — the catalogue and the installer must agree on the install UNIT.
#
# lodar, 2026-09-13, on /dashboard/plugins: "what if i press on dashboard /
# buzz / telegram - all are per agent plugins - thats a mixup to voice and
# browser". Two defects behind that one sentence, one arm family each:
#
#   T1  `plugin add` refused a built-in channel only for a BARE ref. The
#       dashboard always sends the QUALIFIED one, so the guard never fired for
#       the only caller that reaches it from a browser.
#
#       MEASURED CORRECTION to the row's premise, and it is why these arms are
#       written as a REGRESSION FENCE and not as a differential: today the
#       qualified ref is still refused, by the trust gate two steps later, because
#       telegram/dashboard/buzz carry no `fivedive.trust.review` in the registry
#       (checked 2026-09-13 on 5dive-ai/5dive-plugins@main — only voice and
#       browser declare `official`). So the box-wide install the row predicted
#       does NOT happen. What was true is that the refusal rested on a field in
#       somebody else's manifest: add `"review":"official"` to telegram and the
#       guard evaporates. DIVE-4466 moves it to where it cannot — before
#       resolution, before the trust gate, keyed on our own constant.
#
#       T1a-T1e DO pass on origin/main, and that is exactly their limit: with
#       the later trust gate live, a refusal is a refusal and no arm can say
#       WHICH of the two produced it. Reverting only the new pre-resolution
#       guard to main's bare-only form leaves them all green (measured). T1f is
#       the arm that can tell: it stubs the trust gate out — the same way this
#       harness already stubs require_root — so the guard under test is the only
#       thing left that can refuse. Under that isolation the mutant does not
#       merely fail to refuse, it INSTALLS telegram box-wide, which is the dead
#       install this row was filed about.
#   T2  `market --kind=plugin --json` carried no field saying which unit a row
#       installs into, so no consumer could have got it right. THIS is the live
#       defect behind lodar's sentence, and T2a plus the derivation arms are the
#       differential: on origin/main `installs` is null on every row and
#       _plugin_is_builtin_channel_ref does not exist (5 arms red, measured).
#
# Every arm drives the shipping functions. T1d and T1e are the negative controls:
# the refusal must NOT spread to a box-level plugin, nor to a third-party
# marketplace that happens to publish one of our channel names.
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
source src/cmd_plugin.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh

# header.sh turns errexit on in THIS shell; the refusals below are the subject,
# so they must not take the harness down. Same fix as plugin_verb_dispatch_unit.
set +e -o pipefail

require_root() { :; }

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state"

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

# ---- fixtures ---------------------------------------------------------------
# A registered clone of the real registry's SHAPE: the three channel plugins and
# the two box-level ones, with the categories they actually carry — which is the
# point of T2b, since `category` splits the wrong way.
MKTDIR="$(_plugin_mkt_dir)/$(_plugin_registry_name)/.claude-plugin"
mkdir -p "$MKTDIR"
cat > "$MKTDIR/marketplace.json" <<'JSON'
{
  "name": "5dive-plugins",
  "plugins": [
    {"name": "telegram",  "category": "productivity", "description": "Telegram channel."},
    {"name": "dashboard", "category": "productivity", "description": "Dashboard channel."},
    {"name": "buzz",      "category": "productivity", "description": "Buzz channel."},
    {"name": "voice",     "category": "channel",      "description": "Voice notes."},
    {"name": "browser",   "category": "channel",      "description": "A real browser."}
  ]
}
JSON

# A SECOND marketplace publishing a name that collides with one of ours. The
# constant pins each channel to 5dive-plugins, so this one is a stranger.
THIRD="$(_plugin_mkt_dir)/acme/.claude-plugin"
mkdir -p "$THIRD"
cat > "$THIRD/marketplace.json" <<'JSON'
{"name":"acme","plugins":[{"name":"telegram","category":"productivity","description":"Not ours."}]}
JSON

echo "== T1: plugin add refuses a built-in channel, bare AND qualified =="

run cmd_plugin_add telegram --yes
t  "T1a bare ref refused (rc)"            "$E_USAGE" "$RC"
tc "T1a names the per-agent path"         "installed per AGENT"                 "$ERR"
tc "T1a names the verb that works"        "5dive agent create <name> --channels=telegram" "$ERR"

# The qualified ref the dashboard actually sends. This arm pins the refusal and
# its wording; it does NOT pin which guard produced them — today the trust gate
# would refuse it too, because telegram carries no `fivedive.trust.review` (see
# the MEASURED CORRECTION above; the row's premise that it passed the gate as
# `official` was wrong). T1f is where that ambiguity is removed.
run cmd_plugin_add telegram@5dive-plugins --yes
t  "T1b qualified ref refused (rc)"       "$E_USAGE" "$RC"
tc "T1b names the per-agent path"         "installed per AGENT"                 "$ERR"
tn "T1b never reached resolution"         "no plugin"                           "$ERR"

for p in dashboard buzz; do
  run cmd_plugin_add "$p@5dive-plugins" --yes
  t  "T1c $p@5dive-plugins refused (rc)"  "$E_USAGE" "$RC"
  tc "T1c $p names the per-agent path"    "installed per AGENT"                 "$ERR"
done

# NEGATIVE CONTROL 1: a box-level plugin must NOT inherit the refusal. It fails
# later (this fixture carries no plugin tree), and "later" is the assertion —
# the message must not be the channel one.
run cmd_plugin_add voice@5dive-plugins --yes
tn "T1d voice not refused as a channel"   "installed per AGENT"                 "$ERR"
run cmd_plugin_add browser@5dive-plugins --yes
tn "T1d browser not refused as a channel" "installed per AGENT"                 "$ERR"

# NEGATIVE CONTROL 2: the marketplace half of the match. A stranger publishing
# `telegram` is not our channel, and claiming it is would be a lie about someone
# else's plugin. A guard that matched on the name alone fails this arm.
run cmd_plugin_add telegram@acme --yes
tn "T1e foreign telegram@acme not ours"   "installed per AGENT"                 "$ERR"

# T1f — THE DISCRIMINATING ARM. Everything above is blind to which of two
# refusals fired. Neutralise the later catcher and only the pre-resolution guard
# is left standing. Measured on this fixture, ref `telegram@5dive-plugins`:
#   branch code      -> rc=2, refused, "installed per AGENT"
#   bare-only mutant -> rc=0, "OK — telegram@5dive-plugins 0.5.52 installed"
#                       plus "installed and inert" — the dead box-wide install.
# Saved and restored rather than left stubbed, so T2 below still runs against
# the shipping gate.
_tg_orig="$(declare -f _plugin_trust_gate)"
_plugin_trust_gate() { :; }
run cmd_plugin_add telegram@5dive-plugins --yes
t  "T1f guard refuses ALONE, trust gate stubbed (rc)"  "$E_USAGE" "$RC"
tc "T1f and the refusal is the guard's own"            "installed per AGENT" "$ERR"
tn "T1f nothing was installed"                         "installed and inert" "$ERR"
tn "T1f no success line"                               "installed"           "$OUT"
eval "$_tg_orig"

echo "== T2: market --kind=plugin --json says which unit each row installs into =="

JSON_MODE=1
run cmd_market_plugins --kind=plugin
JSON_MODE=0
t "T2 listing succeeded (rc)" "0" "$RC"

got=$(jq -r '[.data.plugins[] | "\(.name)=\(.installs)"] | sort | join(" ")' <<<"$OUT" 2>/dev/null)
t "T2a installs is agent for the three channels, box for the two others" \
  "browser=box buzz=agent dashboard=agent telegram=agent voice=box" "$got"

# The field must be its own answer, not a rename of `category`: telegram is
# `productivity` and voice is `channel`, so a consumer keying on category gets
# the split exactly backwards.
cat_split=$(jq -r '[.data.plugins[] | select(.category=="channel") | .name] | sort | join(",")' <<<"$OUT")
t  "T2b category splits the OTHER way (why installs had to exist)" "browser,voice" "$cat_split"

# NEGATIVE CONTROL: `installs` is DERIVED, not a constant. The listing reads one
# marketplace (the registry clone — one source, DIVE-4202), so the derivation is
# asked directly here rather than through a second marketplace the listing would
# never show: the marketplace half of the match is what a mutant drops first.
_plugin_is_builtin_channel_ref telegram acme; t "T2c' derivation: telegram@acme is not a channel" "1" "$?"
_plugin_is_builtin_channel_ref telegram 5dive-plugins; t "T2c' derivation: telegram@5dive-plugins is" "0" "$?"
_plugin_is_builtin_channel_ref voice 5dive-plugins; t "T2c' derivation: voice@5dive-plugins is not" "1" "$?"
_plugin_is_builtin_channel_ref telegram ""; t "T2c' derivation: bare telegram still is" "0" "$?"

# T2d — the OTHER row builder. This listing assembles rows in two places: the
# registered clone read above, and the published manifest it FETCHES when a box
# has no clone yet — which is every fresh box, and the path T2a cannot reach.
# The field shipped as two copies of one jq expression; this arm drives the copy
# nobody was testing (it is now one shared expression, and this is what keeps it
# one). A fresh STATE_DIR means no local marketplace, so the fetch branch runs.
_st_save="$STATE_DIR"
export STATE_DIR="$TMP/state-remote"
curl() {
  cat <<'JSON'
{"name":"5dive-plugins","plugins":[
  {"name":"telegram","category":"productivity","description":"Telegram channel."},
  {"name":"voice","category":"channel","description":"Voice notes."}]}
JSON
}
JSON_MODE=1
run cmd_market_plugins --kind=plugin
JSON_MODE=0
unset -f curl
export STATE_DIR="$_st_save"
t "T2d remote-index listing succeeded (rc)" "0" "$RC"
remote_got=$(jq -r '[.data.plugins[] | "\(.name)=\(.installs)/\(.ready)"] | sort | join(" ")' <<<"$OUT" 2>/dev/null)
t "T2d fetched rows carry installs too (and are not ready)" \
  "telegram=agent/false voice=box/false" "$remote_got"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
