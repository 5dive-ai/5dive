#!/usr/bin/env bash
# DIVE-2278 — the veto principal is redacted AT GENERATION, not per-file.
#
# Council output (roster / init summary / veto-exercise line) is quoted verbatim into
# transcripts and posts. A raw Telegram user id printed there reaches a published artifact
# by default, and redacting one artifact leaves the generator emitting it into the next.
#
# This test pins the display filter itself (not a file's contents):
#   1. a tg:<digits> principal NEVER renders as those digits
#   2. the rendered label is stable and non-empty
#   3. human:<agent> passes through untouched (it is already a name)
#   4. every human-readable veto emitter routes through the filter (shape assertion, so a
#      NEW emitter added later without the filter fails here rather than in a transcript)
#
# Mutation grade: delete the tg:* arm of _council_principal_label and 1 goes red; drop the
# filter from any of the three echo lines and 4 goes red.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src/council/cmd_council.template.sh"
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
no()  { printf '  FAIL %s\n' "$1"; FAILED=1; }

[[ -r "$SRC" ]] || { echo "council template not found: $SRC" >&2; exit 2; }

# --- load just the filter + its two helpers, with no side effects -------------------------
extract() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}' "$SRC"; }
eval "$(extract _council_sha256)"
eval "$(extract _council_principal_agents)"
eval "$(extract _council_principal_label)"
# Stub the resolver: the real one reads paired-channel state we do not have in a unit test.
# Returning nothing forces the OPAQUE path, which is the weakest branch — if the id leaked,
# it would leak here first.
_council_resolve_principal() { :; }

declare -F _council_principal_label >/dev/null || { echo "could not extract _council_principal_label" >&2; exit 2; }

# --- 1. a raw telegram id never survives into the label -----------------------------------
# Placeholder id (never a real one in this repo — see .github/pii-denylist.txt).
ID='1234567890'
L="$(_council_principal_label "tg:$ID")"
[[ -n "$L" ]] || no "label is empty for tg:<id>"
[[ "$L" != *"$ID"* ]] && ok "tg:<id> label does not contain the raw id ($L)" || no "RAW ID LEAKED in label: $L"
L2="$(_council_principal_label "$ID")"
[[ "$L2" != *"$ID"* ]] && ok "bare <id> label does not contain the raw id ($L2)" || no "RAW ID LEAKED for bare id: $L2"

# --- 2. stable + shaped like a handle -----------------------------------------------------
[[ "$L" == "$(_council_principal_label "tg:$ID")" ]] && ok "label is stable across calls" || no "label is not stable"
[[ "$L" =~ ^(human:[a-zA-Z0-9_-]+|tg:#([0-9a-f]{8}|redacted))$ ]] && ok "label is a name or an opaque handle" || no "unexpected label shape: $L"

# --- 3. names pass through ----------------------------------------------------------------
[[ "$(_council_principal_label 'human:main')" == "human:main" ]] && ok "human:<agent> passes through" || no "human:<agent> was mangled"
[[ "$(_council_principal_label 'none')" == "none" ]] && ok "'none' passes through" || no "'none' was mangled"

# --- 4. every human-readable veto emitter routes through the filter -----------------------
# Non-JSON `echo "veto:` lines in the council command must not interpolate a principal
# variable directly. Anything matching $principal/$vprincipal/${offer_principal} raw is a
# new leak site.
LEAKY="$(grep -nE '^[[:space:]]*echo "veto:' "$SRC" | grep -vE '_council_principal_label' || true)"
[[ -z "$LEAKY" ]] && ok "all human-readable veto lines route through the filter" \
  || no "veto line(s) print a principal without the filter:"$'\n'"$LEAKY"

if [[ $FAILED -eq 0 ]]; then echo "council_principal_redaction_unit: PASS"; else echo "council_principal_redaction_unit: FAIL"; fi
exit $FAILED
