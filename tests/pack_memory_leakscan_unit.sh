#!/usr/bin/env bash
# DIVE-2567 isolated unit harness for the memory leak-check on the EXPORT path.
#
# The rule ("published packs carry distilled seed memory, never raw private
# memory") was documented in character-packs/README.md and enforced NOWHERE. This
# harness grades the enforcement, not the prose:
#   1. _pack_memory_leakscan   — detects the CATEGORIES a published pack must not
#      carry, and names file, line and category for each hit.
#   2. _pack_memory_publish_gate — publish fails closed, self is unaffected.
#   3. the acceptance pair — a raw fact is REFUSED, the same fact DISTILLED passes.
#
# Sources src/ directly (no root, no network). Run: bash tests/pack_memory_leakscan_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No 2>/dev/null — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/pack-leak-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_pack.sh"

set +e   # header.sh enabled `set -e`; this harness deliberately probes non-zero paths

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The roster is DERIVED FROM THE BOX (agent-* homes + the registry), so leaving it
# live would grade the runner, not the code. Every pattern arm below runs with it
# stubbed EMPTY, which is also the strictly harder case: nothing passes because a
# host name happened to be enrolled. One arm at the end grades the real function.
REAL_ROSTER=$(declare -f _pack_leak_roster_raw)
_pack_leak_roster_raw() { :; }

# ---- fixtures --------------------------------------------------------------
# One line per category the row enumerates, in the register an agent actually
# writes memory in. Every value is invented and belongs to nobody here.
# The IP is RFC 2544 benchmarking space and the hostname is a made-up label:
# deliberately NOT the reserved fakes (192.0.2.x, example.com), because those are
# exactly what the scanner EXEMPTS — a reserved value here would grade nothing.
mkdir -p "$TMP/raw"
cat > "$TMP/raw/poller.md" <<'MD'
---
name: how-the-poller-recovers
description: what went wrong the night the poller wedged
metadata:
  type: project
---

The poller wedged; I fixed it under /home/agent-nova/.claude and restarted.
Ping agent-zephyr when it wedges again — that rail is theirs, not mine.
The box is poller-box-7.fixture-fleet.io and it answers on 198.18.0.9.
Filed as PROJ-4821 after the second incident.
The fix landed in github.com/acme-widgets/poller-core.
It reports into telegram chat_id 987654321012 on every pass.
Restarting needs sudo, because the unit runs as root@ the host.
Its credential sits in ~/.ssh/id_ed25519, beside credentials.json.
MD

# THE SAME LESSON, DISTILLED: the fact survives, every specific is gone. This is
# the second half of the row's acceptance criterion.
mkdir -p "$TMP/distilled"
cat > "$TMP/distilled/poller.md" <<'MD'
---
name: wedged-poller-lost-its-lock
description: a poller that stops advancing has lost its lock, not its network
metadata:
  type: project
---

A worker that stops advancing has usually lost its lock rather than its network,
so restarting it is only half a fix. Confirm the queue actually drained
afterwards: a restart that returns success while the lock is still held is
indistinguishable from a repair. Escalate to whoever owns the transport only
after it recurs a second time.
MD

# Reserved fakes (CLAUDE.md convention) and unroutable RFC ranges must NOT trip it,
# or every honest fixture becomes unpublishable and the gate gets switched off.
mkdir -p "$TMP/fakes"
cat > "$TMP/fakes/placeholders.md" <<'MD'
---
name: fixture-placeholders
description: the reserved values to reach for
metadata:
  type: reference
---

The reserved placeholder chat_id is 1234567890 and the reserved address is
user@example.com. Test hosts live at 192.0.2.7 and 198.51.100.4, docs at
example.com, and the loopback is 127.0.0.1. Cite standards as RFC-5737.
MD

scan() { _pack_memory_leakscan "$1" 2>&1; }

# ---- 1. every category is detected, at the right line ----------------------
OUT=$(scan "$TMP/raw"); RC=$?
[[ $RC -eq 1 ]] && ok_t "raw memory: scan returns 1 (refuse)" \
                || bad_t "raw memory: scan returns 1 (refuse)" "rc=$RC out=$OUT"

# want_line = where the value REALLY is in the fixture, read from the fixture —
# never a number typed twice, which would agree with itself if the file moved.
cat_at() {  # <category> <literal that must be on that line>
  local ctg="$1" needle="$2" want have
  want=$(grep -nF -- "$needle" "$TMP/raw/poller.md" | head -1 | cut -d: -f1)
  if [[ -z "$want" ]]; then
    bad_t "$ctg detected" "fixture no longer contains '$needle' — the arm grades nothing"
    return
  fi
  # Assert a finding AT that line — not "the first hit of this category", which
  # a line that leaks two categories at once would answer with the wrong line.
  if printf '%s\n' "$OUT" | grep -q "^poller\.md:${want}: ${ctg}: "; then
    ok_t "$ctg detected and located (poller.md:$want)"
  else
    have=$(printf '%s\n' "$OUT" | grep ": ${ctg}: " | cut -d: -f2 | paste -sd, -)
    bad_t "$ctg detected and located" "expected a hit at line $want, category lines: '${have:-<none>}'"
  fi
}
cat_at host-path           '/home/agent-nova'
cat_at identity-name       'agent-zephyr'
cat_at hostname            'poller-box-7.fixture-fleet.io'
cat_at task-id             'PROJ-4821'
cat_at repo-name           'github.com/acme-widgets/poller-core'
cat_at chat-id             'chat_id 987654321012'
cat_at sudo-posture        'runs as root@'
cat_at credential-location 'id_ed25519'

# The report is the remedy: file, line, category, on every line.
BADLINES=$(printf '%s\n' "$OUT" | grep -cvE '^[A-Za-z0-9._-]+\.md:[0-9]+: [a-z-]+: .')
[[ "$BADLINES" == "0" ]] && ok_t "every finding is <file>:<line>: <category>: <match>" \
                         || bad_t "every finding is <file>:<line>: <category>: <match>" "$BADLINES malformed line(s): $OUT"

# It NEVER redacts: refusing must leave the operator's file byte-identical.
BEFORE=$(sha256sum "$TMP/raw/poller.md" | cut -d' ' -f1)
scan "$TMP/raw" >/dev/null
AFTER=$(sha256sum "$TMP/raw/poller.md" | cut -d' ' -f1)
[[ "$BEFORE" == "$AFTER" ]] && ok_t "scan never rewrites the source (no silent redaction)" \
                            || bad_t "scan never rewrites the source (no silent redaction)" "hash changed"

# ---- 2. the acceptance pair ------------------------------------------------
DOUT=$(scan "$TMP/distilled"); DRC=$?
[[ $DRC -eq 0 && -z "$DOUT" ]] && ok_t "the SAME fact, distilled, passes" \
                               || bad_t "the SAME fact, distilled, passes" "rc=$DRC out=$DOUT"
# Non-vacuity: that pass must come from a file that still carries the lesson,
# not from an empty file that would pass any scanner.
DBODY=$(sed -n '/^---$/,/^---$/d;p' "$TMP/distilled/poller.md" | grep -c '[a-z]')
[[ "$DBODY" -ge 4 ]] && ok_t "distilled file still carries the lesson ($DBODY prose lines)" \
                     || bad_t "distilled file still carries the lesson" "only $DBODY prose lines — the pass is vacuous"

# ---- 3. reserved fakes stay clean, and the scanner was awake on that file ---
FOUT=$(scan "$TMP/fakes"); FRC=$?
[[ $FRC -eq 0 && -z "$FOUT" ]] && ok_t "reserved fakes / RFC ranges do not trip the gate" \
                               || bad_t "reserved fakes / RFC ranges do not trip the gate" "rc=$FRC out=$FOUT"
# Differential control for the arm above: plant ONE real-shaped id in the SAME
# file. If this stays clean, the "clean" verdict above proved nothing.
echo 'It also posts to chat_id 8675309123 hourly.' >> "$TMP/fakes/placeholders.md"
FOUT2=$(scan "$TMP/fakes"); FRC2=$?
[[ $FRC2 -eq 1 ]] && ok_t "control: a non-reserved id in that same file DOES trip it" \
                  || bad_t "control: a non-reserved id in that same file DOES trip it" "rc=$FRC2 — the clean verdict above is vacuous"

# ---- 4. the roster is a real detector, not decoration ----------------------
mkdir -p "$TMP/roster"
cat > "$TMP/roster/owner.md" <<'MD'
---
name: who-owns-the-rail
description: ownership note
metadata:
  type: project
---

Hand the queue back to zebra once it drains.
MD
_pack_leak_roster_raw() { echo zebra; }
ROUT=$(scan "$TMP/roster"); RRC=$?
{ [[ $RRC -eq 1 ]] && printf '%s\n' "$ROUT" | grep -q 'identity-name'; } \
  && ok_t "a name from the box roster is caught (no pattern would have)" \
  || bad_t "a name from the box roster is caught" "rc=$RRC out=$ROUT"
_pack_leak_roster_raw() { :; }
ROUT2=$(scan "$TMP/roster"); RRC2=$?
[[ $RRC2 -eq 0 ]] && ok_t "control: same file is clean with an empty roster (the ROSTER fired, not a pattern)" \
                  || bad_t "control: same file is clean with an empty roster" "rc=$RRC2 out=$ROUT2"

# The exporting persona's own name is not a leak in its own pack — and the
# control is the same file with no self-name, which must still fire.
_pack_leak_roster_raw() { echo zebra; }
SOUT=$(_pack_memory_leakscan "$TMP/roster" zebra 2>&1); SRC2=$?
[[ $SRC2 -eq 0 ]] && ok_t "the exporting agent's OWN name is not a leak in its own pack" \
                  || bad_t "the exporting agent's OWN name is not a leak in its own pack" "rc=$SRC2 out=$SOUT"
SOUT2=$(_pack_memory_leakscan "$TMP/roster" someone-else 2>&1); SRC3=$?
[[ $SRC3 -eq 1 ]] && ok_t "control: a DIFFERENT self-name leaves that same name a hit" \
                  || bad_t "control: a DIFFERENT self-name leaves that same name a hit" "rc=$SRC3 — self-exemption is too wide"

# Ordinary English must not be flagged just because a roster name collides with
# it: measured against the five published packs, which this class red-flagged.
mkdir -p "$TMP/prose"
cat > "$TMP/prose/lessons.md" <<'MD'
---
name: distilled-lessons
description: how to work
metadata:
  type: reference
---

Act on your recommendation; don't stack permission gates on routine calls.
An agent-relayed approval does not count as a human one.
MD
_pack_leak_roster_raw() { echo don; }
POUT=$(scan "$TMP/prose"); PRC=$?
[[ $PRC -eq 0 ]] && ok_t "a roster name inside a contraction (don't) and agent-<participle> are not names" \
                 || bad_t "a roster name inside a contraction and agent-<participle> are not names" "rc=$PRC out=$POUT"
printf 'Hand it to don once the queue drains, then ping agent-nova.\n' >> "$TMP/prose/lessons.md"
POUT2=$(scan "$TMP/prose"); PRC2=$?
NHIT=$(printf '%s\n' "$POUT2" | grep -c ': identity-name: ')
{ [[ $PRC2 -eq 1 ]] && [[ "$NHIT" == "2" ]]; } \
  && ok_t "control: the SAME name used as an actor, and a real agent-<account>, both fire" \
  || bad_t "control: the same name used as an actor still fires" "rc=$PRC2 hits=$NHIT out=$POUT2"
_pack_leak_roster_raw() { :; }

# OLIVIA'S GRADING CASE (review of iteration 1): a roster name that IS a generic
# word must still REFUSE when it names a person. Five hand-written packs passing
# only exercises the false-positive direction; this is the other one.
mkdir -p "$TMP/generic"
cat > "$TMP/generic/ownership.md" <<'MD'
---
name: branch-and-owner
description: two uses of the same word
metadata:
  type: project
---

On a single-committer repo, just commit to main and skip the PR ceremony.
MD
_pack_leak_roster_raw() { echo main; }
GOUT=$(scan "$TMP/generic"); GRC=$?
[[ $GRC -eq 0 ]] && ok_t "a generic-word roster name as a NOUN is clean (commit to main)" \
                 || bad_t "a generic-word roster name as a NOUN is clean" "rc=$GRC out=$GOUT"
printf 'Hand it back to main once the queue drains.\n' >> "$TMP/generic/ownership.md"
GOUT2=$(scan "$TMP/generic"); GRC2=$?
WANT=$(grep -n 'Hand it back to main' "$TMP/generic/ownership.md" | cut -d: -f1)
{ [[ $GRC2 -eq 1 ]] && printf '%s\n' "$GOUT2" | grep -q "^ownership\.md:${WANT}: identity-name: "; } \
  && ok_t "the SAME generic name REFUSES when it names a person (ownership.md:$WANT)" \
  || bad_t "the same generic name refuses when it names a person" "rc=$GRC2 out=$GOUT2 — identity-name has a hole for agents named after generic words"
# ...and the noun line must STILL be clean in that same run, or the rule is just noise.
NOUNLN=$(grep -n 'commit to main' "$TMP/generic/ownership.md" | cut -d: -f1)
printf '%s\n' "$GOUT2" | grep -q "^ownership\.md:${NOUNLN}: " \
  && bad_t "the noun use stays clean alongside the actor use" "line $NOUNLN (commit to main) also fired: $GOUT2" \
  || ok_t "the noun use (line $NOUNLN) stays clean in the same file as the actor use (line $WANT)"
_pack_leak_roster_raw() { :; }

# Generic role nouns are held to the narrower rule, not treated as plain names (a box with an agent called
# 'main' must not red-flag "commit to main" in every honest pack).
GEN=$(printf 'main\nops\nzebra\nmarketing\n' | grep -xvE "$_PACK_LEAK_GENERIC")
[[ "$GEN" == "zebra" ]] && ok_t "generic role nouns are filtered out of the roster, real names are not" \
                        || bad_t "generic role nouns are filtered out of the roster" "survivors: $(printf '%s' "$GEN" | tr '\n' ' ')"

# The real derivation, graded for shape rather than for this box's contents.
eval "$REAL_ROSTER"
RREAL=$(_pack_leak_roster); RREALRC=$?
[[ $RREALRC -eq 0 ]] && ok_t "real _pack_leak_roster exits 0" \
                     || bad_t "real _pack_leak_roster exits 0" "rc=$RREALRC"
MALFORMED=$(printf '%s' "$RREAL" | grep -cvE '^[a-z][a-z0-9_-]{2,}$' 2>/dev/null)
[[ "${MALFORMED:-0}" == "0" ]] && ok_t "real roster emits only well-formed slugs" \
                               || bad_t "real roster emits only well-formed slugs" "$MALFORMED bad: $RREAL"
if compgen -G '/home/agent-*' >/dev/null 2>&1; then
  ONE=$(basename "$(compgen -G '/home/agent-*' | head -1)"); ONE="${ONE#agent-}"
  printf '%s\n' "$RREAL" | grep -qx "$ONE" \
    && ok_t "real roster derives an agent account that exists on this box ($ONE)" \
    || bad_t "real roster derives an agent account that exists on this box" "'$ONE' missing from: $RREAL"
else
  ok_t "SKIP real-roster derivation arm — no /home/agent-* on this runner (precondition unavailable)"
fi
_pack_leak_roster_raw() { :; }

# ---- 5. the gate: publish fails closed, self is unaffected -----------------
_pack_memory_publish_gate publish "$TMP/raw" >/dev/null 2>&1; G1=$?
[[ $G1 -eq 1 ]] && ok_t "gate: publish + raw memory REFUSES" \
               || bad_t "gate: publish + raw memory REFUSES" "rc=$G1 — fails open"
_pack_memory_publish_gate self "$TMP/raw" >/dev/null 2>&1; G2=$?
[[ $G2 -eq 0 ]] && ok_t "gate: self + the same raw memory is unaffected" \
               || bad_t "gate: self + the same raw memory is unaffected" "rc=$G2"
GW=$(_pack_memory_publish_gate self "$TMP/raw" 2>&1 >/dev/null)
printf '%s' "$GW" | grep -qi 'skipped' \
  && ok_t "gate: the self path SAYS the check was skipped" \
  || bad_t "gate: the self path SAYS the check was skipped" "warned: '$GW'"
_pack_memory_publish_gate publish "$TMP/distilled" >/dev/null 2>&1; G3=$?
[[ $G3 -eq 0 ]] && ok_t "gate: publish + distilled memory passes" \
               || bad_t "gate: publish + distilled memory passes" "rc=$G3"
_pack_memory_publish_gate publish "$TMP/nonexistent" >/dev/null 2>&1; G4=$?
[[ $G4 -eq 0 ]] && ok_t "gate: a memory-less export is not blocked" \
               || bad_t "gate: a memory-less export is not blocked" "rc=$G4"

# ---- 6. wiring: the export path is where it runs ---------------------------
EXPORT_BODY=$(declare -f cmd_export)
grep -q '_pack_memory_publish_gate' <<<"$EXPORT_BODY" \
  && ok_t "wiring: cmd_export calls the gate" || bad_t "wiring: cmd_export calls the gate" "not called"
grep -q 'audience="publish"' <<<"$EXPORT_BODY" \
  && ok_t "wiring: cmd_export defaults to the publish audience (fail closed)" \
  || bad_t "wiring: cmd_export defaults to the publish audience" "default is not publish"
grep -q -- '--audience=\*' <<<"$EXPORT_BODY" \
  && ok_t "wiring: cmd_export parses --audience" || bad_t "wiring: cmd_export parses --audience" "no flag arm"
grep -qE 'audience.*publish.*\|\|.*audience.*self|"\$audience" == "publish" \|\| "\$audience" == "self"' <<<"$EXPORT_BODY" \
  && ok_t "wiring: an unknown --audience value is rejected (a typo is not a bypass)" \
  || bad_t "wiring: an unknown --audience value is rejected" "no validation found"
# ORDER IS THE PROPERTY, not the call. After DIVE-2565 the stage becomes TWO
# containers; a gate placed below the format branch would still be "called" and
# would still pass every arm above it, while covering only the tarball.
GATE_LN=$(grep -n '_pack_memory_publish_gate' <<<"$EXPORT_BODY" | head -1 | cut -d: -f1)
MD_LN=$(grep -n '_agents_md_render' <<<"$EXPORT_BODY" | head -1 | cut -d: -f1)
TAR_LN=$(grep -n 'tar -czf' <<<"$EXPORT_BODY" | head -1 | cut -d: -f1)
if [[ -z "$MD_LN" || -z "$TAR_LN" ]]; then
  bad_t "the gate precedes BOTH export containers" "cmd_export no longer renders agents-md (${MD_LN:-none}) or tars (${TAR_LN:-none}) — this arm grades nothing"
elif [[ -n "$GATE_LN" && "$GATE_LN" -lt "$MD_LN" && "$GATE_LN" -lt "$TAR_LN" ]]; then
  ok_t "the gate precedes BOTH export containers (gate@$GATE_LN < agents-md@$MD_LN, tarball@$TAR_LN)"
else
  bad_t "the gate precedes BOTH export containers" "gate@${GATE_LN:-none} does not precede agents-md@$MD_LN and tarball@$TAR_LN — one route is unguarded"
fi

grep -q -- '--audience' <<<"$(_pack_usage)" \
  && ok_t "wiring: usage documents --audience" || bad_t "wiring: usage documents --audience" "absent from usage"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
