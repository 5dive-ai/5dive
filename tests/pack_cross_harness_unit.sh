#!/usr/bin/env bash
# DIVE-2568 isolated unit harness — a marketplace pack lands on codex and
# opencode, not only Claude.
#
# Grades the PURE half of the row (no root, no network, no agent user):
#   1. _pack_targets_from / _pack_harness_targets — the DERIVED harness set, its
#      TYPE_PERSONA_FILE floor, and the manifest's narrow-only override.
#   2. _pack_disclosure_json / _pack_disclosure_print — the set reaching the
#      install-time disclosure that `agent inspect`, import and market all render.
#   3. _pack_unapplied_on / _pack_inline_memory_into_doc — the two things that
#      differ on a foreign seat: the claude-only settings.json keys (named, not
#      dropped) and distilled memory (inlined into the instruction file the
#      harness actually reads, since only Claude Code auto-loads 5dive's store).
#
# Sections 3 and 4 are BEHAVIOURAL by design. The first cut of both grepped
# cmd_import for the branch text, and mutation-grading showed a branch disabled
# outright (condition -> false) killed NOTHING — a string survives dead code. Both
# predicates are extracted so the arms execute the shipped path. Same lesson a
# third time in T7g: a file-wide grep for a call passed on the OTHER call site, so
# an assertion about one caller is now evaluated inside that caller's body.
#
# The impure half (cmd_import provisioning a real codex seat) is graded by the
# DIVE-2223 persona-routing arms and by the VM smoke matrix; what this file can
# grade offline is that the SET is right and that nothing drops silently.
# Run: bash tests/pack_cross_harness_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No 2>/dev/null — redirecting the
# source's stderr also swallows the helper's own stderr payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/cross-harness-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_pack.sh is function-defs-only at source time.
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately probe non-zero paths

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1 (want [$3] got [$2])"; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then ok_ "$3"; else bad_ "$3 (missing [$2])"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then bad_ "$3 (unexpectedly present: [$2])"; else ok_ "$3"; fi; }

# ---------------------------------------------------------------- fixtures ---
# A pack that declares itself claude — the shape ALL 19 published packs have.
# Reserved fakes only (host CLAUDE.md rule): no real slug, no real identifier.
mk_manifest() {  # mk_manifest <dir> [<targets-json-or-empty>] [<model>] [<effort>]
  local dir="$1" targets="${2:-}" model="${3:-opus}" effort="${4:-high}"
  mkdir -p "$dir"
  jq -n --arg m "$model" --arg e "$effort" \
        --argjson t "$( [[ -n "$targets" ]] && echo "$targets" || echo 'null' )" '
    { packFormat: 1, agentName: "testpack", createdWith: "0.0.0-test",
      includes: { memory: false, persona: false },
      config: ({ type: "claude", isolation: "standard", model: $m, effort: $e }
               + (if $t == null then {} else { targets: $t } end)),
      plugins: [], skills: [], hooks: {} }' > "$dir/manifest.json"
}

echo "== DIVE-2568 cross-harness import =="

# ---------------------------------------------------- 1. the derived set ------
# The row's decision: TARGET-AGNOSTIC. A pack packed as "claude" must land on the
# non-Claude harnesses too, WITHOUT being republished — that is the entire ask.
AGN=$(_pack_targets_from "")
check "T1a codex is a target"        "$(grep -cxF codex    <<<"$AGN")" "1"
check "T1b opencode is a target"     "$(grep -cxF opencode <<<"$AGN")" "1"
check "T1c claude is still a target" "$(grep -cxF claude   <<<"$AGN")" "1"

# DIVE-2245: hermes and openclaw were probed on live seats and are now mapped,
# so they are targets. These two rows were `0` here until that measurement landed
# — they assert the pack REACHES those harnesses, which is the payoff of the probe.
check "T1d hermes IS a target (DIVE-2245 mapped it)"   "$(grep -cxF hermes   <<<"$AGN")" "1"
check "T1e openclaw IS a target (DIVE-2245 mapped it)" "$(grep -cxF openclaw <<<"$AGN")" "1"

# THE FLOOR, and the reason this is derived rather than declared. devin passes
# is_known_type (it is in TYPE_BIN) but is deliberately absent from
# TYPE_PERSONA_FILE because it was never probe-verified on a live seat
# (DIVE-3129). Import onto it would create a unix account, a home and a unit,
# then drop the persona — the pack's whole payload — and report success. A
# membership assertion alone would pass on any non-empty list, so grade the
# EXCLUSION explicitly; it is the half that can regress silently.
check "T1d2 devin is NOT a target (no persona path)" "$(grep -cxF devin <<<"$AGN")" "0"
# ...and prove the exclusion is caused by the persona map, not by an empty list:
# devin IS a known type, so is_known_type cannot be what filtered it.
if is_known_type devin; then ok_ "T1f devin IS a known type — so the persona map is what excluded it"
else bad_ "T1f devin unexpectedly not a known type — T1d2 proves nothing"; fi

# Every emitted target must have a persona path. This is the invariant, stated
# as a property rather than as a list, so adding a harness cannot quietly break it.
_bad=0
while IFS= read -r t; do [[ -n "${TYPE_PERSONA_FILE[$t]:-}" ]] || _bad=$((_bad+1)); done <<<"$AGN"
check "T1g every target has a TYPE_PERSONA_FILE entry" "$_bad" "0"

# T1d/T1e/T1g above are satisfied by the ITERATION SOURCE alone — _pack_targets_from
# walks ${!TYPE_PERSONA_FILE[@]}, so an absent key can never be emitted and the
# non-empty guard inside the loop is never what excluded devin. Mutation-graded
# and confirmed: deleting that guard kills none of them. The guard is not dead,
# though — it catches the OTHER way a harness can be unmapped, which is a key
# present with an EMPTY value. header.sh documents devin as "deliberately
# unmapped"; today that is by absence, and the natural way to make the intent
# explicit later is `[devin]=""`, which the iteration source alone would then
# happily emit. Inject exactly that shape so the guard is load-bearing for a
# defect no other arm can see.
TYPE_PERSONA_FILE[t2568empty]=""
TYPE_BIN[t2568empty]="/nonexistent/t2568"
TYPE_PERSONA_FILE[t2568mapped]=".t2568/AGENTS.md"
TYPE_BIN[t2568mapped]="/nonexistent/t2568m"
INJ=$(_pack_targets_from "")
# DIFFERENTIAL: the empty-valued key is dropped WHILE a mapped key injected the
# same way lands. Without the second half, "dropped" also passes on a function
# that emits nothing at all.
check "T1h a key mapped to an EMPTY persona path is not a target" "$(grep -cxF t2568empty  <<<"$INJ")" "0"
check "T1i ...while a mapped injected key IS a target"            "$(grep -cxF t2568mapped <<<"$INJ")" "1"
unset 'TYPE_PERSONA_FILE[t2568empty]' 'TYPE_BIN[t2568empty]'
unset 'TYPE_PERSONA_FILE[t2568mapped]' 'TYPE_BIN[t2568mapped]'
# is_known_type is the other filter and it too must be load-bearing: a persona
# path for a type with no binary is not a hostable seat.
TYPE_PERSONA_FILE[t2568nobin]=".t2568/AGENTS.md"
check "T1j persona path without a TYPE_BIN entry is not a target" \
      "$(grep -cxF t2568nobin <<<"$(_pack_targets_from "")")" "0"
unset 'TYPE_PERSONA_FILE[t2568nobin]'

# ------------------------------------------- 2. narrow-only manifest override --
mk_manifest "$TMP/agnostic"
mk_manifest "$TMP/narrow" '["claude","codex"]'
# DIVE-2245 moved hermes/openclaw INTO the map, so they are no longer the
# unmapped-but-known example this arm needs — devin is. Using a mapped type here
# would have turned "cannot widen" into a test that widens successfully.
mk_manifest "$TMP/widen"  '["devin"]'

A=$(_pack_harness_targets "$TMP/agnostic/manifest.json")
N=$(_pack_harness_targets "$TMP/narrow/manifest.json")
W=$(_pack_harness_targets "$TMP/widen/manifest.json")

check "T2a no targets key -> full agnostic set" "$A" "$AGN"
check "T2b narrowed set has exactly 2"          "$(grep -c . <<<"$N")" "2"
check "T2c narrowed keeps codex"                "$(grep -cxF codex    <<<"$N")" "1"
check "T2d narrowed drops opencode"             "$(grep -cxF opencode <<<"$N")" "0"
# CANNOT WIDEN: a pack asking for harnesses this CLI has no persona path for
# gets an EMPTY set, not those harnesses. Without this a publisher could assert
# compatibility the box cannot honour, and the import would half-land.
check "T2e cannot widen past the persona map"   "$(grep -c . <<<"$W")" "0"
check "T2f declared-narrowing is detected"      "$(_pack_targets_declared "$TMP/narrow/manifest.json"; echo $?)"   "0"
check "T2g absent targets is NOT declared"      "$(_pack_targets_declared "$TMP/agnostic/manifest.json"; echo $?)" "1"

# A malformed targets value must not widen either, and must not crash the render.
mk_manifest "$TMP/junk" '["codex",7,null]'
J=$(_pack_harness_targets "$TMP/junk/manifest.json")
check "T2h non-string targets entries ignored, codex survives" "$J" "codex"

# --------------------------------------------- 3. disclosure carries the set --
# One answer, three renders (inspect / import / market). Grade the JSON and the
# human print separately — a field present in the object and missing from the
# print is exactly the "silently dropped" shape this row is about.
D=$(_pack_disclosure_json "$TMP/agnostic")
check "T3a disclosure landsOn has codex"    "$(jq -r '[.landsOn[]|select(.=="codex")]|length'    <<<"$D")" "1"
check "T3b disclosure landsOn has opencode" "$(jq -r '[.landsOn[]|select(.=="opencode")]|length' <<<"$D")" "1"
check "T3c declaredType is reported"        "$(jq -r '.declaredType' <<<"$D")" "claude"
check "T3d agnostic pack is not narrowed"   "$(jq -r '.narrowed'     <<<"$D")" "false"

DN=$(_pack_disclosure_json "$TMP/narrow")
check "T3e narrowed pack reports narrowed"  "$(jq -r '.narrowed' <<<"$DN")" "true"
check "T3f narrowed disclosure drops opencode" "$(jq -r '[.landsOn[]|select(.=="opencode")]|length' <<<"$DN")" "0"

P=$(_pack_disclosure_print "$D" 2>&1)
has  "$P" "lands on:" "T3g the human disclosure states the harness set"
has  "$P" "codex"     "T3h ...and names codex in it"
PN=$(_pack_disclosure_print "$DN" 2>&1)
has  "$PN" "narrowed by the pack" "T3i a narrowed pack says so in the print"
hasnt "$PN" "opencode"            "T3j ...and does not offer opencode"

# DIFFERENTIAL, not just "says claude": the print must show the packed type as
# context WITHOUT it reading as the only option. Both facts in one render.
has "$P" "packed as claude" "T3k print names the packed type as context"

# ---------------------------------------- 4. the model/effort silent drop ------
# The bug this row removes. settings.json is Claude Code's file and the ONLY sink
# for a pack's model/effort/hooks/plugins; on a codex seat they have nowhere to
# go. That is fine — the SILENCE was not. cmd_import's warn is the fix, and the
# branch is graded here by replaying its exact predicate over a real manifest, so
# the assertion moves if the manifest keys move.
#
# NOT a message-only assertion (feedback: a message assertion grades the
# rendering, not the condition): each arm asserts the CONDITION that produced the
# message — the manifest genuinely carries the value that has no sink.
mf="$TMP/agnostic/manifest.json"
check "T4a fixture pack really pins a model"  "$(jq -r '.config.model'  "$mf")" "opus"
check "T4b fixture pack really pins effort"   "$(jq -r '.config.effort' "$mf")" "high"
# The claude branch is the ONLY writer of these keys — prove it by grepping the
# one sink rather than by trusting the comment above it. If a second sink ever
# appears, the premise of the whole report changes and this arm says so.
SINK=$(grep -c 'effortLevel:\$effort' "$SRC/cmd_pack.sh")
check "T4c exactly one settings.json sink for effort" "$SINK" "1"

# BEHAVIOURAL, not textual. An earlier cut of these arms grepped cmd_import for
# the warn string; mutation-grading showed that disabling the branch outright
# (condition -> false) killed NOTHING, because the text survives a dead branch.
# The predicate is extracted for exactly this reason and is executed here.
U_CODEX=$(_pack_unapplied_on codex opus high 0 "$mf")
U_CLAUDE=$(_pack_unapplied_on claude opus high 0 "$mf")
check "T4d codex seat reports the model by VALUE"  "$(grep -cxF 'model=opus'  <<<"$U_CODEX")" "1"
check "T4e codex seat reports the effort by VALUE" "$(grep -cxF 'effort=high' <<<"$U_CODEX")" "1"
# DIFFERENTIAL: a claude seat reports NOTHING, because on claude the keys DO
# land. Without this arm, a function that reports everything always would pass.
check "T4f claude seat reports nothing (the keys land there)" "$(grep -c . <<<"$U_CLAUDE")" "0"
check "T4g opencode behaves like codex" \
      "$(_pack_unapplied_on opencode opus high 0 "$mf" | grep -cxF 'model=opus')" "1"
# The RESOLVED value is reported, not the manifest's — an operator who passed
# --model=sonnet must be told sonnet is unapplied, not opus. This is the arm
# that pins the signature to resolved inputs.
check "T4h an overridden model is reported as the OVERRIDE" \
      "$(_pack_unapplied_on codex sonnet "" 0 "$mf" | grep -cxF 'model=sonnet')" "1"
# hooks and plugins are the other two claude-only keys.
check "T4i hooks reported when present"     "$(_pack_unapplied_on codex "" "" 1 "$mf" | grep -cxF hooks)" "1"
check "T4j hooks NOT reported when absent"  "$(_pack_unapplied_on codex "" "" 0 "$mf" | grep -cxF hooks)" "0"
mk_manifest "$TMP/plug"; jq '.plugins=["p@mkt"]' "$TMP/plug/manifest.json" > "$TMP/plug/m2" && mv "$TMP/plug/m2" "$TMP/plug/manifest.json"
check "T4k plugins reported when the pack ships them" \
      "$(_pack_unapplied_on codex "" "" 0 "$TMP/plug/manifest.json" | grep -cxF plugins)" "1"
check "T4l plugins NOT reported for a plugin-less pack" \
      "$(_pack_unapplied_on codex "" "" 0 "$mf" | grep -cxF plugins)" "0"
# A pack with nothing claude-only in it produces an EMPTY report on codex — the
# warn must not fire on a pack that loses nothing.
mk_manifest "$TMP/bare" '' '' ''
check "T4m a pack with no claude-only keys drops nothing" \
      "$(_pack_unapplied_on codex "" "" 0 "$TMP/bare/manifest.json" | grep -c .)" "0"
# It is a REPORT, never a refusal: the persona, memory, avatar and skills are the
# payload and they all land on a codex seat. Grade the rc, not the prose.
_pack_unapplied_on codex opus high 1 "$mf" >/dev/null
check "T4n the report exits 0 — it never gates the import" "$?" "0"
# ...and cmd_import consumes it rather than re-implementing it (the extraction is
# only worth anything if the shipped path is the graded path).
if grep -q 'mapfile -t _nc < <(_pack_unapplied_on "\$type"' "$SRC/cmd_pack.sh"; then
  ok_ "T4o cmd_import calls the graded predicate (no second copy)"
else bad_ "T4o cmd_import does not call _pack_unapplied_on — this file grades dead code"; fi

# --------------------------------- 4B. can the imported agent think at all? ---
# DIVE-2676. Section 4 grades which claude-only KEYS are dropped. That report is
# correct and still let the worse outcome through: an import onto an API-key-only
# seat produced an agent with no credential and no model, reported OK, and every
# ask timed out at 120s. _pack_seat_needs_key is the predicate that separates
# "auth deferred to a sign-in that exists" from "auth omitted, permanently".
#
# DIFFERENTIAL BY CONSTRUCTION: the arms below are the reason this can't be a
# "not claude" test. codex, pi and grok are all non-claude AND all have a real
# sign-in flow, so a predicate that answered `type != claude` would pass T4p and
# fail T4q/T4r/T4s. That is the whole content of the row.
_needs() { if _pack_seat_needs_key "$1"; then echo yes; else echo no; fi; }
check "T4p opencode: API key is the only route (no TYPE_AUTH entry)" "$(_needs opencode)" "yes"
check "T4q codex: has an interactive sign-in, so deferring auth is honest"  "$(_needs codex)"  "no"
check "T4r pi: API-key type BUT has a sign-in flow — not inert"             "$(_needs pi)"     "no"
check "T4s grok: same shape as pi"                                          "$(_needs grok)"   "no"
check "T4t claude: the baseline seat"                                       "$(_needs claude)" "no"
# In NEITHER map: hermes has no api-file row at all, so there is no key route to
# assert. Silence is right — the predicate must not fire on "I don't know".
check "T4u hermes: absent from TYPE_API_FILE, so no claim is made" "$(_needs hermes)" "no"
# Pins the derivation to the MAPS, not to a hardcoded name list. A type that
# gains a sign-in flow must drop out of the predicate on the spot.
#
# Save/restore in THIS shell rather than wrapping the check in ( ) — a subshell
# swallows the FAIL increment, so the arm prints red and the harness still exits
# 0. Caught by mutation-grading this very file: the always-fires mutant printed
# six FAIL lines and reported fail=4.
_SV_AUTH_OC="${TYPE_AUTH[opencode]:-}"
TYPE_AUTH[opencode]="/tmp/sentinel-not-read"
check "T4v a type that GAINS a TYPE_AUTH row stops being inert" "$(_needs opencode)" "no"
if [[ -n "$_SV_AUTH_OC" ]]; then TYPE_AUTH[opencode]="$_SV_AUTH_OC"; else unset 'TYPE_AUTH[opencode]'; fi

_SV_API_CODEX="${TYPE_API_FILE[codex]:-}"
unset 'TYPE_API_FILE[codex]'
check "T4w a type that LOSES its api-file row makes no claim" "$(_needs codex)" "no"
[[ -n "$_SV_API_CODEX" ]] && TYPE_API_FILE[codex]="$_SV_API_CODEX"
# The restore is itself graded — a leaked mutation would silently rewrite the
# premise of every arm after it (and of section 5, which reads the same maps).
check "T4v2 TYPE_AUTH restored (opencode inert again)"      "$(_needs opencode)" "yes"
check "T4w2 TYPE_API_FILE restored (codex api-file back)"   "${TYPE_API_FILE[codex]:-MISSING}" "openai.env"
# ...and the shipped path consumes it. Same dead-code lesson as T4o.
if grep -q '_pack_seat_needs_key "\$type"' "$SRC/cmd_pack.sh"; then
  ok_ "T4x cmd_import calls the graded predicate"
else bad_ "T4x cmd_import does not call _pack_seat_needs_key — this section grades dead code"; fi
# The verdict must reach BOTH readers. A warn alone is invisible to the dashboard,
# which renders the JSON envelope and would keep showing an inert seat as a hire.
check "T4y canThink rides in the ok envelope" \
      "$(grep -c 'canThink:\$ct' "$SRC/cmd_pack.sh")" "1"
# MUTUAL EXCLUSION, graded by line order: cmd_create hard-fails
# "--defer-auth and --provider/--api-key are mutually exclusive", so the BYO
# branch must add the creds and the non-BYO branch must add --defer-auth. If
# --defer-auth were unconditional again, every BYO import would die at create.
L_BYO=$(grep -n -- '--provider=\$p_provider' "$SRC/cmd_pack.sh" | head -1 | cut -d: -f1)
L_DEFER=$(grep -n -- 'cargs+=("--defer-auth")' "$SRC/cmd_pack.sh" | head -1 | cut -d: -f1)
if [[ -n "$L_BYO" && -n "$L_DEFER" ]] && (( L_BYO < L_DEFER )); then
  ok_ "T4z --defer-auth is the ELSE of the BYO branch, not unconditional"
else bad_ "T4z BYO creds and --defer-auth are not exclusive branches (byo=$L_BYO defer=$L_DEFER)"; fi

# ------------------------------------------- 5. the import-time target fence ---
# cmd_import must refuse an unhostable target BEFORE cmd_create makes an account.
# Grade the ORDER, not just the presence — a fence below the create is not a
# fence. Line numbers, because "both strings appear" passes on either order.
L_FENCE=$(grep -n 'this pack cannot be imported onto a' "$SRC/cmd_pack.sh" | head -1 | cut -d: -f1)
L_CREATE=$(grep -n 'cmd_create "\${cargs\[@\]}"' "$SRC/cmd_pack.sh" | head -1 | cut -d: -f1)
if [[ -n "$L_FENCE" && -n "$L_CREATE" ]] && (( L_FENCE < L_CREATE )); then
  ok_ "T5a target fence sits ABOVE the create call ($L_FENCE < $L_CREATE)"
else bad_ "T5a target fence not proven above cmd_create (fence=$L_FENCE create=$L_CREATE)"; fi
# The refusal must name the set it WILL land on — a bare "unsupported" leaves the
# operator with no next step, and the next step is the whole point of the row.
if grep -q 'It lands on: \${_lands\[\*\]' "$SRC/cmd_pack.sh"; then
  ok_ "T5b the refusal names the harnesses it DOES land on"
else bad_ "T5b the refusal does not name the landable set"; fi

# ------------------------------------------------- 6. the envelope contract ----
# A dashboard renders a cross-harness hire from these; assert they are wired to
# the derived values and not to a hardcoded string.
if grep -q 'persona_target "\$as" "\$type"' "$SRC/cmd_pack.sh"; then
  ok_ "T6a import reports where the persona ACTUALLY landed for this type"
else bad_ "T6a import does not resolve the per-type persona path for its envelope"; fi
if grep -q 'notApplied:\$nap' "$SRC/cmd_pack.sh"; then
  ok_ "T6b the not-applied list is machine-readable in the ok envelope"
else bad_ "T6b notApplied missing from the import envelope"; fi

# ------------------------------------- 7. memory IN EFFECT on a foreign seat --
# The row's acceptance criterion is that a pack hired onto codex/opencode comes up
# with the persona AND any distilled memory IN EFFECT. Import seeds facts into
# ~/.claude/projects/<slug>/memory — reachable by `5dive memory search` on any
# harness, but only Claude Code AUTO-LOADS that store. On a codex seat the facts
# would be present and not in effect, which is the settings.json drop one layer
# up. The fix reuses the DIVE-2565 renderer on the import direction.
MSTAGE="$TMP/mem"; mk_manifest "$MSTAGE"; mkdir -p "$MSTAGE/memory"
printf '# Ada\n\nYou are Ada.\n' > "$MSTAGE/CLAUDE.md"
cat > "$MSTAGE/memory/a-fact.md" <<'EOF'
---
name: a-fact
metadata:
  type: reference
---
The build runs green only after the index is rebuilt.
EOF
printf 'second fact, no trailing newline' > "$MSTAGE/memory/b-fact.md"

MEMOUT=$(_agents_md_render_memory "$MSTAGE")
has "$MEMOUT" "a-fact.md"   "T7a the extracted memory renderer emits fact one"
has "$MEMOUT" "b-fact.md"   "T7b ...and fact two"
has "$MEMOUT" "The build runs green" "T7c ...with the fact BODY, not just the filename"
# A fact with no trailing newline must not swallow its closing fence — the
# renderer's own guard, now exercised through the extracted entry point.
check "T7d fence count is balanced across both facts" \
      "$(( $(grep -c '^~~~' <<<"$MEMOUT") % 2 ))" "0"
# EMPTY-STAGE LIVENESS: emits nothing (so callers may call it unconditionally),
# and rc is still 0 — a non-zero here would abort cmd_import under set -e.
EMPTY=$(_agents_md_render_memory "$TMP/agnostic"); _rc=$?
check "T7e no memory dir -> empty output" "$(grep -c . <<<"$EMPTY")" "0"
check "T7f ...and rc 0 (never aborts the import)" "$_rc" "0"

# The EXPORT format must be unchanged by the extraction. pack_agents_md_unit.sh
# grades that across 52 arms and is the real check (mutation-confirmed: breaking
# the delegation reds 3 of its arms). This arm only pins that the export path
# still routes THROUGH the shared function rather than growing a second copy.
#
# SCOPED TO THE FUNCTION BODY ON PURPOSE. A file-wide grep for the call passes on
# cmd_import's call site — the string occurs twice — so the first cut of this arm
# stayed green through a mutation that removed the export delegation entirely.
# An assertion about one caller has to be evaluated inside that caller.
RENDER_FN=$(awk '/^_agents_md_render\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC/cmd_pack.sh")
if [[ $(grep -c . <<<"$RENDER_FN") -gt 20 ]]; then
  ok_ "T7g-live _agents_md_render body extracted ($(grep -c . <<<"$RENDER_FN") lines)"
else bad_ "T7g-live could not extract _agents_md_render — T7g would grade nothing"; fi
has "$RENDER_FN" '_agents_md_render_memory "$stage"' \
    "T7g _agents_md_render itself delegates to the shared memory emitter"
# ...and the two call sites are genuinely distinct, which is what made the
# file-wide grep unsound. Count them rather than assert "at least one".
check "T7g2 exactly two call sites (export + import)" \
      "$(grep -c '_agents_md_render_memory "\$stage"' "$SRC/cmd_pack.sh")" "2"

# THE DECISION AND THE REWRITE, both BEHAVIOURAL. An earlier cut replayed the
# guard in the test and grepped cmd_import for the branch text; a mutant that
# stopped inlining altogether killed only a call-site count. The rewrite is
# extracted so these arms execute the shipped code path on a real stage.
# The stage dir comes back in a global, not on stdout: the function under test
# writes step/warn to stderr and the rc is the verdict, so multiplexing both onto
# one captured line is how the first cut of this helper silently mis-split.
INL_ST=""; _inl_n=0
inl() {  # inl <type> <mem_inc> — fresh stage each call; rewrites $INL_ST/CLAUDE.md in place
  local t="$1" mi="$2"
  _inl_n=$((_inl_n+1)); INL_ST="$TMP/inl.$_inl_n"
  mkdir -p "$INL_ST/memory"
  cp "$MSTAGE/manifest.json" "$MSTAGE/CLAUDE.md" "$INL_ST/"
  cp "$MSTAGE"/memory/*.md "$INL_ST/memory/"
  _pack_inline_memory_into_doc "$INL_ST" "$t" "$mi" >/dev/null 2>&1
}
inl codex distilled
check "T7h codex + distilled memory -> inlined (rc 0)" "$?" "0"
has "$(cat "$INL_ST/CLAUDE.md")" "The build runs green" "T7h2 ...the FACT BODY is now in the persona doc"
has "$(cat "$INL_ST/CLAUDE.md")" "You are Ada"          "T7h3 ...and the original persona survived"
has "$(cat "$INL_ST/CLAUDE.md")" "5dive:memory-file: a-fact.md" \
    "T7h4 ...carried by the DIVE-2565 sentinels, not a bespoke format"
inl opencode distilled
check "T7i opencode + distilled memory -> inlined" "$?" "0"
# CLAUDE IS EXCLUDED, and differentially: rc says no AND the doc is UNCHANGED.
# rc alone would pass on a function that rewrote the file and then returned 1.
inl claude distilled
check "T7j claude is EXCLUDED (store is auto-loaded)" "$?" "1"
check "T7j2 ...and claude's persona doc is byte-identical" \
      "$(cmp -s "$INL_ST/CLAUDE.md" "$MSTAGE/CLAUDE.md" && echo same || echo CHANGED)" "same"
inl codex false
check "T7k no distilled memory -> no inline" "$?" "1"
# A memory-less pack: same type, same mem_inc, no facts.
STMP="$TMP/nomem"; mkdir -p "$STMP"; cp "$MSTAGE/manifest.json" "$STMP/"; cp "$MSTAGE/CLAUDE.md" "$STMP/"
_pack_inline_memory_into_doc "$STMP" codex distilled >/dev/null 2>&1
check "T7l memory-less pack -> no inline" "$?" "1"
# IDEMPOTENCE is not claimed and must not be assumed: import runs this once, on a
# fresh stage. Pin that the doc grows exactly one Memory section per call so a
# future second caller is a visible change rather than a silent duplication.
inl codex distilled
check "T7m exactly one Memory section per inline" \
      "$(grep -c '^# Memory$' "$INL_ST/CLAUDE.md")" "1"
# ...and cmd_import consumes the graded function rather than a second copy.
if grep -q 'if _pack_inline_memory_into_doc "\$stage" "\$type" "\$mem_inc"' "$SRC/cmd_pack.sh"; then
  ok_ "T7m2 cmd_import calls the graded inline (no second copy)"
else bad_ "T7m2 cmd_import does not call _pack_inline_memory_into_doc"; fi
if grep -q 'memoryInEffect:\$me' "$SRC/cmd_pack.sh"; then
  ok_ "T7n the envelope reports WHICH mechanism put memory in effect"
else bad_ "T7n memoryInEffect missing from the import envelope"; fi

echo
echo "  pass=$PASS fail=$FAIL"
(( FAIL == 0 )) || exit 1
