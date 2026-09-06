#!/usr/bin/env bash
# DIVE-3994 — `5dive team import` must survive an unset bot token.
#
# THE DEFECT: `_compose_parse`'s env expansion treated EVERY unset "${VAR}" as
# fatal, wherever it sat. Every curated template referenced a per-role
# `*_TG_TOKEN`, so importing a company required creating five bots in BotFather
# and exporting five vars first — and the first unset one was `sys.exit(3)`,
# i.e. the import did not partially succeed, it parse-failed. That is why the
# dashboard could only ever offer a copy-to-clipboard command.
#
# THE FIX is key-aware, not name-aware: an unset var in an OPTIONAL CREDENTIAL
# field (telegram_token / discord_token) drops that field and drops the agent's
# `channels` to `none` when that channel was the one the token wired. Anywhere
# else it stays the hard error it was.
#
# These arms are BEHAVIOURAL, not source greps: `_compose_parse` is pure
# python+yaml with no root and no host state, so the parser is exercised for
# real. The arms that cannot be (cmd_compose_up CREATES AGENTS) are marked
# source-level where they appear, and say so.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"
TPL="$ROOT/team-templates"
TMP="$(mktemp -d)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_compose.sh is present — the arms below are not reading an empty file' \
  || { bad_t 'T0 cmd_compose.sh missing — every arm is vacuous' "src=$SRC"; echo "team_import_optional_token_unit: $pass passed, $fail failed"; exit 1; }

command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null \
  || { echo "SKIP - python3+PyYAML not available; _compose_parse cannot run here"; echo "team_import_optional_token_unit: $pass passed, $fail failed"; exit 0; }

# Source ONLY the parser. cmd_compose.sh is a fragment of the concatenated CLI;
# sourcing it defines functions and runs nothing.
# shellcheck disable=SC1090
. "$SRC" >/dev/null 2>&1

# Run the parser with an explicitly controlled env. `env -i` is deliberate: a
# var leaking in from the harness's own shell would make an arm pass for the
# wrong reason — the whole point is what happens when a var is NOT set.
parse() {  # parse <file> [VAR=VAL ...]  -> stdout JSON, exit = parser's exit
  local f="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '. "$0" >/dev/null 2>&1; _compose_parse "$1"' "$SRC" "$f" 2>"$TMP/err"
}

CS="$TPL/content-studio.5dive.yaml"

# --- T1 the whole point: no bot token anywhere, and the import still parses ---
out=$(parse "$CS" TEAM_AUTH_PROFILE=acct); rc=$?
if (( rc == 0 )); then
  ok_t 'T1 content-studio parses with NO *_TG_TOKEN set (today this was exit 3)'
else
  bad_t 'T1 an unset optional bot token still kills the whole import' "rc=$rc $(head -2 "$TMP/err")"
fi

# --- T2 the dropped field takes its channel with it -------------------------
# Half-wiring is worse than not wiring: an agent with channels=telegram and no
# token is a seat that reports a channel it cannot answer on.
if [[ -n "$out" ]]; then
  tok=$(jq -r '.agents.editor.telegram_token // "ABSENT"' <<<"$out")
  chan=$(jq -r '.agents.editor.channels // "ABSENT"' <<<"$out")
  [[ "$tok" == "ABSENT" ]] \
    && ok_t 'T2a the unset telegram_token field is dropped, not left as "${TEAM_TG_TOKEN}"' \
    || bad_t 'T2a the literal placeholder survived into the spec' "telegram_token=$tok"
  [[ "$chan" == "none" ]] \
    && ok_t 'T2b the lead falls back to channels=none rather than half-wired telegram' \
    || bad_t 'T2b the agent keeps a channel it has no credential for' "channels=$chan"
  named=$(jq -r '[.channels_dropped[]? | select(.agent=="editor")] | length' <<<"$out")
  var=$(jq -r '.channels_dropped[0].var // ""' <<<"$out")
  [[ "$named" == "1" && "$var" == "TEAM_TG_TOKEN" ]] \
    && ok_t 'T2c the parser REPORTS which agent lost which channel, and over which var' \
    || bad_t 'T2c a silently channel-less agent — nothing to print a summary line from' "named=$named var=$var"
else
  bad_t 'T2 no parser output to inspect' ''
fi

# --- T3 a token that IS set still wires exactly one role ---------------------
# lodar's revision: one channel per COMPANY. The lead is the customer's single
# point of contact; the rest of the roster must NOT sprout channels.
out3=$(parse "$CS" TEAM_AUTH_PROFILE=acct TEAM_TG_TOKEN=1234567890:FAKE); rc=$?
if (( rc == 0 )); then
  lead_c=$(jq -r '.agents.editor.channels' <<<"$out3")
  lead_t=$(jq -r '.agents.editor.telegram_token' <<<"$out3")
  others=$(jq -r '[.agents | to_entries[] | select(.key!="editor") | .value.channels] | unique | join(",")' <<<"$out3")
  [[ "$lead_c" == "telegram" && "$lead_t" == "1234567890:FAKE" ]] \
    && ok_t 'T3a with TEAM_TG_TOKEN set the LEAD gets the channel and the real token' \
    || bad_t 'T3a the lead did not get its channel' "channels=$lead_c token=$lead_t"
  [[ "$others" == "none" ]] \
    && ok_t 'T3b every other role stays channel-less — one channel per company, not per agent' \
    || bad_t 'T3b a non-lead role acquired a channel' "other channels=$others"
else
  bad_t 'T3 parse failed with the token SET' "rc=$rc $(head -2 "$TMP/err")"
fi

# --- T4 NEGATIVE CONTROL: a non-optional field still hard-fails --------------
# This is the arm that keeps the fix narrow. If it ever passes, the change has
# stopped being "optional credentials are optional" and become "unset vars are
# fine", which would silently create agents on the wrong account.
out4=$(parse "$CS"); rc4=$?
if (( rc4 == 3 )) && grep -q "TEAM_AUTH_PROFILE" "$TMP/err"; then
  ok_t 'T4 NEGATIVE CONTROL an unset var in a NON-optional field (auth_profile) still exits 3'
else
  bad_t 'T4 the hard error was widened — unset vars no longer fail anywhere' "rc=$rc4 $(head -2 "$TMP/err")"
fi

# --- T5 the rule is keyed on the FIELD, not on our template's var name -------
cat > "$TMP/generic.yaml" <<'YML'
version: "2"
agents:
  a:
    type: claude
    channels: discord
    discord_token: "${SOME_OTHER_NAME}"
  b:
    type: claude
    channels: none
    telegram_token: "${ALSO_UNSET}"
YML
out5=$(parse "$TMP/generic.yaml"); rc5=$?
if (( rc5 == 0 )); then
  a_c=$(jq -r '.agents.a.channels' <<<"$out5")
  b_c=$(jq -r '.agents.b.channels' <<<"$out5")
  b_t=$(jq -r '.agents.b.telegram_token // "ABSENT"' <<<"$out5")
  [[ "$a_c" == "none" ]] \
    && ok_t 'T5a discord_token gets the same treatment — the rule is the FIELD, not TEAM_TG_TOKEN' \
    || bad_t 'T5a discord was special-cased out of the fix' "channels=$a_c"
  [[ "$b_c" == "none" && "$b_t" == "ABSENT" ]] \
    && ok_t 'T5b a dropped token whose channel was already none leaves channels alone' \
    || bad_t 'T5b channels was rewritten for a channel the agent never had' "channels=$b_c token=$b_t"
else
  bad_t 'T5 a generic spec with two unset optional creds still failed' "rc=$rc5 $(head -2 "$TMP/err")"
fi

# --- T6 EVERY bundled template, not just the one we edited -------------------
# The row was filed because all four shipped the same shape. A fix proved on one
# template is a fix proved on one template.
allok=1; badf=""
for f in "$TPL"/*.5dive.yaml; do
  parse "$f" TEAM_AUTH_PROFILE=acct >/dev/null || { allok=0; badf+=" $(basename "$f")"; }
done
(( allok == 1 )) \
  && ok_t 'T6 all four bundled templates parse with no bot token set' \
  || bad_t 'T6 a bundled template still requires a token to import' "failed:$badf"

# --- T7 no template asks for a per-ROLE token any more -----------------------
leftover=$(grep -l '_TG_TOKEN' "$TPL"/*.5dive.yaml 2>/dev/null | xargs -r grep -h '_TG_TOKEN' | grep -v 'TEAM_TG_TOKEN' || true)
[[ -z "$leftover" ]] \
  && ok_t 'T7 no template references a per-role *_TG_TOKEN — one optional var for a whole company' \
  || bad_t 'T7 a per-role token var survives, so that template still needs five bots' "$leftover"

# --- T8 --type applies to the WHOLE roster (source-level, see header) --------
# cmd_compose_up creates agents, so the override is graded by running its jq
# expression, which is the whole of the behaviour.
expr_out=$(jq -c --arg t codex '.agents |= with_entries(.value.type = $t)' <<<"$out3" 2>/dev/null \
  | jq -r '[.agents[].type] | unique | join(",")')
[[ "$expr_out" == "codex" ]] \
  && ok_t 'T8a the --type override rewrites every role, not the first one' \
  || bad_t 'T8a --type left a mixed roster' "types=$expr_out"
grep -q 'is_known_type "$type_override"' "$SRC" \
  && ok_t 'T8b --type is validated BEFORE any agent is created (a half-imported company is worse than a refusal)' \
  || bad_t 'T8b an unknown harness would be discovered by the first failing create' ''
[[ "$(jq -r '[.agents[].type] | unique | join(",")' <<<"$out3")" == "claude" ]] \
  && ok_t 'T8c NEGATIVE CONTROL with no --type every role is still claude, as the template declares' \
  || bad_t 'T8c the declared default moved' ''

# --- T9 the browser path never puts a bot token in argv ----------------------
grep -q 'tg_token" == "-"' "$SRC" \
  && ok_t 'T9 team import accepts --telegram-token=- so the secret rides stdin, not argv' \
  || bad_t 'T9 no stdin form — a dashboard import would log the token in shelld audit + /proc cmdline' ''

echo "-----"
echo "team_import_optional_token_unit: $pass passed, $fail failed"
rc=0; [[ $fail -eq 0 ]] || rc=1
exit "$rc"
