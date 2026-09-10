#!/usr/bin/env bash
# DIVE-3998 — `--type=<harness>` on `up` / `team import`: a company import stops
# being Claude-Code-only.
#
# Every bundled team template hard-sets `defaults.type: claude`, so `5dive team
# import content-studio` could only ever produce Claude Code seats, even though
# `agent create` has long accepted the other harnesses in TYPE_BIN. This pins
# the flag's two halves:
#
#   1. WITH the flag, the whole roster moves — including agents that name their
#      own `type:`, and including the character-pack path, which deliberately
#      does NOT forward `type:` in any other circumstance.
#   2. WITHOUT the flag, nothing changes. That is the load-bearing claim of the
#      row, so it is a negative control on every behavioural arm, not a footnote.
#
# The pin-dropping arms are not decoration. `agent config set effort=` REFUSES on
# a non-claude type (loud), but `model=` is ACCEPTED for codex/grok/antigravity
# and only charset-validated — so without T5 a `--type=codex` import would write
# a resolved `claude-opus-5` into a codex seat's runtime config and hand the user
# five quietly broken agents with a green summary.
#
# COVERAGE LIMIT, said plainly: these arms drive the argv/spec transforms and the
# real binary's flag validation. They do NOT provision agents — that needs real
# unix users on the host — so "the created seat actually boots as codex" is not
# claimed here. What IS claimed is that `agent create` is invoked with
# `--type=codex` for every agent, which is the whole of this diff's contribution.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# is_known_type lives here; the built CLI concatenates every source file so it
# is always in scope there, but a sourced harness has to ask for it. Without it
# the --type guard fails OPEN-looking: it reports "unknown --type: codex" for a
# type that IS known, which reads like a product bug.
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
source src/cmd_compose.sh
# The sourced CLI turns errexit ON. Several helpers here legitimately end on a
# false [[ ]] (`_compose_create_args` does, and its real call sites slurp it
# through a process substitution that never sees the status) — under errexit
# that would silently truncate this harness mid-run and still print a green
# tail. Same family as the subshell-errexit trap in memory. Turn it back off.
set +e

TMP="$(mktemp -d)"
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# Reserved fakes only (never a real token): the template references per-role
# ${*_TG_TOKEN} vars and _compose_parse hard-errors on any unset ${VAR}. These
# exist to get PAST the parser; nothing below asserts on their values.
export TEAM_AUTH_PROFILE=fixture
export EDITOR_TG_TOKEN='1234567890:AAAAfake-not-a-real-bot-token'
export WRITER_TG_TOKEN="$EDITOR_TG_TOKEN"
export SEO_TG_TOKEN="$EDITOR_TG_TOKEN"
export DESIGNER_TG_TOKEN="$EDITOR_TG_TOKEN"
export DISTRIBUTOR_TG_TOKEN="$EDITOR_TG_TOKEN"

TPL="$ROOT/tests/fixtures/team-templates/content-studio.5dive.yaml"

# --- T0 preconditions: the arms below are not reading an empty file ----------
if [[ -s "$TPL" ]] && declare -F _compose_apply_type_override >/dev/null; then
  ok_t 'T0 the shipped content-studio template and the override function are both present'
else
  bad_t 'T0 precondition failed — every arm below is vacuous' "tpl=$TPL"
fi

BASE="$(_compose_parse "$TPL")" || bad_t 'T0b _compose_parse failed on the shipped template' ''
NAMES="$(jq -r '.agents | keys | join(",")' <<<"$BASE")"
eq_t 'T0c the shipped template still has the five roles the row names' \
     'designer,distributor,editor,seo,writer' "$NAMES"

# --- T1 the whole roster moves ----------------------------------------------
# "the whole roster" is the claim; one agent left on claude is a half-migrated
# company, which is worse than no flag at all.
OVR="$(_compose_apply_type_override "$BASE" codex)"
eq_t 'T1 --type=codex sets every agent type to codex' \
     '["codex","codex","codex","codex","codex"]' \
     "$(jq -c '[.agents[].type]' <<<"$OVR")"
eq_t 'T1b defaults.type follows, so a dump of the spec does not contradict the roster' \
     'codex' "$(jq -r '.defaults.type' <<<"$OVR")"

# --- T2 NEGATIVE CONTROL: no flag, no change --------------------------------
# The row's hard requirement. Compared as canonical JSON so key order cannot
# fake a pass or a fail.
eq_t 'T2 without the override the parsed spec is untouched (every agent still claude)' \
     '["claude","claude","claude","claude","claude"]' \
     "$(jq -c '[.agents[].type]' <<<"$BASE")"

# --- T3 an agent that names its OWN type is overridden too -------------------
# defaults.type is already merged into each agent by _compose_parse, so keying
# the override on `defaults` alone would silently spare any agent with an
# explicit `type:`. This is the arm that fails if someone "simplifies" it there.
cat > "$TMP/own-type.yaml" <<'YAML'
version: "2"
defaults:
  type: claude
agents:
  a: {role: "A"}
  b: {role: "B", type: opencode}
YAML
OWN="$(_compose_apply_type_override "$(_compose_parse "$TMP/own-type.yaml")" codex)"
eq_t 'T3 an explicit per-agent type: is overridden, not just defaults.type' \
     '{"a":"codex","b":"codex"}' \
     "$(jq -c '.agents | map_values(.type)' <<<"$OWN")"

# --- T4 the create argv actually carries it ---------------------------------
# The transform is only worth anything if it reaches `agent create`.
ARGS_OVR="$(_compose_create_args "$(jq -c '.agents.editor' <<<"$OVR")" editor "$TMP")"
ARGS_BASE="$(_compose_create_args "$(jq -c '.agents.editor' <<<"$BASE")" editor "$TMP")"
eq_t 'T4 agent create is invoked with --type=codex under the override' \
     '--type=codex' "$(grep -m1 '^--type=' <<<"$ARGS_OVR")"
eq_t 'T4b NEGATIVE CONTROL: without the override it is still --type=claude' \
     '--type=claude' "$(grep -m1 '^--type=' <<<"$ARGS_BASE")"

# --- T5 Claude-only pins are dropped, and REPORTED ---------------------------
# `model=` is accepted for codex and only charset-validated, so a surviving
# `opus` becomes a resolved claude-opus-5 written into a codex seat's config:
# a quietly broken agent under a green summary. `effort=` is claude-only and
# would merely warn, but a pin that cannot apply should not be carried either.
eq_t 'T5 a Claude model alias is dropped when the target harness is not claude' \
     'null' "$(jq -r '.agents.editor.model // "null"' <<<"$OVR")"
eq_t 'T5b effort (claude-only config) is dropped with it' \
     'null' "$(jq -r '.agents.editor.effort // "null"' <<<"$OVR")"
# Reported in SPEC order, not sorted — the user reads it against the file they
# wrote. `keys` would sort; `to_entries` preserves. Pinned so a refactor to
# `keys` cannot quietly reorder the line.
eq_t 'T5c the dropped pins are NAMED to the user, in spec order, not swallowed' \
     'editor, writer, seo, designer, distributor' \
     "$(_compose_type_override_pins "$BASE" codex)"

# --- T6 NEGATIVE CONTROL: --type=claude drops nothing ------------------------
# The drop is keyed on the TARGET harness. A user re-asserting claude must get
# the template they asked for, pins intact.
CLA="$(_compose_apply_type_override "$BASE" claude)"
eq_t 'T6 --type=claude keeps the model pin (the drop is keyed on the target)' \
     'opus' "$(jq -r '.agents.editor.model // "null"' <<<"$CLA")"
eq_t 'T6b --type=claude keeps effort too' \
     'high' "$(jq -r '.agents.editor.effort // "null"' <<<"$CLA")"
eq_t 'T6c and it reports no dropped pins' '' "$(_compose_type_override_pins "$BASE" claude)"

# --- T7 NEGATIVE CONTROL: a non-Claude model string survives -----------------
# Dropping every model under a non-claude target would break the user who
# already writes a real codex / BYO model in their own spec. The rule is
# "Claude alias or claude-* id", not "any model".
cat > "$TMP/byo.yaml" <<'YAML'
version: "2"
agents:
  a: {type: claude, model: "openrouter/some-model"}
  b: {type: claude, model: "claude-opus-5"}
YAML
BYO="$(_compose_apply_type_override "$(_compose_parse "$TMP/byo.yaml")" codex)"
eq_t 'T7 a vendor/model BYO string is NOT a Claude alias and survives the override' \
     'openrouter/some-model' "$(jq -r '.agents.a.model // "null"' <<<"$BYO")"
eq_t 'T7b a full claude-* id IS dropped' \
     'null' "$(jq -r '.agents.b.model // "null"' <<<"$BYO")"

# --- T8 the character-pack path ----------------------------------------------
# `agent import <pack>` normally takes its harness FROM the pack, and this diff
# must not change that. But an explicit roster-wide override has to reach it, or
# `--type=codex` yields a mixed company: plain agents codex, pack agents not.
PACK_SPEC='{"pack":"someslug","channels":"none"}'
PK_OVR="$(_compose_import_args "$PACK_SPEC" alice someslug "$TMP" codex)"
PK_BASE="$(_compose_import_args "$PACK_SPEC" alice someslug "$TMP")"
eq_t 'T8 the pack path forwards the override to agent import' \
     '--type=codex' "$(grep -m1 '^--type=' <<<"$PK_OVR")"
eq_t 'T8b NEGATIVE CONTROL: with no override the pack path emits NO --type at all' \
     '0' "$(grep -c '^--type=' <<<"$PK_BASE")"

# --- T9 the real binary rejects an unknown harness BEFORE touching state ------
# Left to `agent create`, a typo'd --type fails once per agent, halfway through
# a partly-provisioned roster. Driven through the built ./5dive so this arm also
# proves the flag survives the build, not just the source tree.
if [[ -x "$ROOT/5dive" ]]; then
  OUT="$("$ROOT/5dive" up --type=definitely-not-a-harness -f "$TPL" 2>&1)"; RC=$?
  if (( RC != 0 )) && grep -qi 'unknown --type' <<<"$OUT"; then
    ok_t "T9 the built CLI rejects an unknown --type up front (rc=$RC)"
  else
    bad_t 'T9 an unknown --type was not rejected before provisioning' "rc=$RC out=$OUT"
  fi
  # ...and the flag is DISCOVERABLE from the command that carries it. Before this
  # row `team import --help` answered "unknown flag: --help".
  HLP="$("$ROOT/5dive" team import --help 2>&1)"
  if grep -q -- '--type=<harness>' <<<"$HLP"; then
    ok_t 'T9b `team import --help` documents --type (it used to reject --help outright)'
  else
    bad_t 'T9b the flag is undocumented where it is used' "$HLP"
  fi
else
  bad_t 'T9 SKIPPED-AS-FAIL: ./5dive is not built, so the binary-level arms proved nothing' \
        'run ./build.sh first — an unbuilt tree silently skips e2e blocks and fakes a green'
fi

# --- T10 the SEAM: cmd_compose_up actually applies the override -------------
# T1-T8 drive the transform and the argv builders directly. A mutation that
# parses --type, validates it, and then never applies it to the spec survives
# all of them (measured: killed_by=0). So drive the real command, with the
# child `5dive` swapped for a recorder: _compose_self is the single point every
# child invocation goes through, and registry_read/ensure_state are stubbed so
# nothing is provisioned. This arm is what makes the flag's WIRING graded.
cat > "$TMP/two.yaml" <<'YAML'
version: "2"
defaults:
  type: claude
  channels: none
agents:
  one: {role: "One"}
  two: {role: "Two"}
YAML
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state()  { :; }
registry_read() { printf '%s' '{"agents":{}}'; }

export REC="$TMP/rec-ovr.log"; : > "$REC"
cmd_compose_up -f "$TMP/two.yaml" --type=codex >/dev/null 2>&1
eq_t 'T10 cmd_compose_up applies the override — both agents created as codex' \
     '2' "$(grep -c 'agent create .*--type=codex' "$REC")"
eq_t 'T10b and no agent slipped through as claude' \
     '0' "$(grep -c -- '--type=claude' "$REC")"

export REC="$TMP/rec-base.log"; : > "$REC"
cmd_compose_up -f "$TMP/two.yaml" >/dev/null 2>&1
eq_t 'T10c NEGATIVE CONTROL: no flag — both agents created as claude, as today' \
     '2' "$(grep -c 'agent create .*--type=claude' "$REC")"
eq_t 'T10d and nothing was created as codex' \
     '0' "$(grep -c -- '--type=codex' "$REC")"

# --- T11 the OTHER seam: `team import` forwards the flag ---------------------
# `team import` is the command the dashboard hands out and the one the row is
# named for; `up` is the engine underneath. A mutation that parses --type in
# cmd_team and then calls cmd_compose_up without it survives T10 completely
# (measured: killed_by=0), and the user gets a claude roster having asked for
# codex. Same recorder, one level up.
export REC="$TMP/rec-team.log"; : > "$REC"
cmd_team import "$TMP/two.yaml" --type=codex >/dev/null 2>&1
eq_t 'T11 team import forwards --type to the engine — both agents codex' \
     '2' "$(grep -c 'agent create .*--type=codex' "$REC")"

export REC="$TMP/rec-team-base.log"; : > "$REC"
cmd_team import "$TMP/two.yaml" >/dev/null 2>&1
eq_t 'T11b NEGATIVE CONTROL: team import with no flag is unchanged (claude)' \
     '2' "$(grep -c 'agent create .*--type=claude' "$REC")"

# And it validates before provisioning anything, same as `up` — cmd_team is a
# thin wrapper on purpose, so the guard must not be duplicated OR bypassed.
OUT="$( (cmd_team import "$TMP/two.yaml" --type=definitely-not-a-harness) 2>&1 )"
if grep -qi 'unknown --type' <<<"$OUT"; then
  ok_t 'T11c team import rejects an unknown harness through the same guard'
else
  bad_t 'T11c team import accepted an unknown harness' "$OUT"
fi

# --- T12 `ps` reads the spec the same way, or it invents drift -----------------
# `ps` reports the DECLARED type straight out of the spec. Left alone it would
# say claude for a roster brought up as codex — drift reported where there is
# none, on the one command whose whole job is to compare declared against real.
ensure_state_ro() { :; }
JSON_MODE=1
PS_OVR="$(cmd_compose_ps -f "$TMP/two.yaml" --type=codex 2>/dev/null)"
PS_BASE="$(cmd_compose_ps -f "$TMP/two.yaml" 2>/dev/null)"
eq_t 'T12 ps --type=codex reports the roster as codex' \
     'codex codex' \
     "$(jq -r '[.. | objects | select(has("name") and has("type")) | .type] | join(" ")' <<<"$PS_OVR" 2>/dev/null)"
eq_t 'T12b NEGATIVE CONTROL: ps with no flag still reports the spec (claude)' \
     'claude claude' \
     "$(jq -r '[.. | objects | select(has("name") and has("type")) | .type] | join(" ")' <<<"$PS_BASE" 2>/dev/null)"
OUT="$( (cmd_compose_ps -f "$TMP/two.yaml" --type=definitely-not-a-harness) 2>&1 )"
if grep -qi 'unknown --type' <<<"$OUT"; then
  ok_t 'T12c ps rejects an unknown harness through the same guard as up'
else
  bad_t 'T12c ps accepted an unknown harness' "$OUT"
fi
JSON_MODE=0

# --- T13 every help that carries the flag RENDERS ----------------------------
# These heredocs use an UNQUOTED delimiter so ${!TYPE_BIN[*]} interpolates. That
# also makes a backtick a command substitution: the first `ps --help` shipped
# `up --type=<harness>` in prose, bash ran it, `<harness>` parsed as a
# redirection, and the help printed a syntax error and swallowed the phrase.
# shellcheck SC1073 caught it in CI; nothing in T0-T12 did, because none of them
# had ever asked a help text to render. Driven through the built CLI.
if [[ -x "$ROOT/5dive" ]]; then
  for _cmd in "up" "ps" "team import"; do
    # shellcheck disable=SC2086
    _h="$("$ROOT/5dive" $_cmd --help 2>&1)"
    if grep -qiE 'syntax error|command substitution|unexpected token' <<<"$_h"; then
      bad_t "T13 '5dive $_cmd --help' renders without a shell error" "$_h"
    elif grep -q -- '--type=<harness>' <<<"$_h"; then
      ok_t "T13 '5dive $_cmd --help' renders cleanly and documents --type"
    else
      bad_t "T13 '5dive $_cmd --help' does not mention --type" "$_h"
    fi
  done
else
  bad_t 'T13 SKIPPED-AS-FAIL: ./5dive is not built' 'run ./build.sh first'
fi

printf '\n%s\n' "team_import_type_override_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
