#!/usr/bin/env bash
# DIVE-2552 unit: the a2a envelope must COMPARE the claimed sender against the
# measured caller, and say so when they diverge.
#
# THE DEFECT. Every `[5dive-msg ...]` stamp site already holds BOTH values at the
# moment it builds the header:
#
#     sender="$from"                       # CLAIMED  — from `--from=`, only format-validated
#     _caller="$(_envelope_caller)"        # MEASURED — EUID/sudo-derived, not settable by a flag
#     _tier="$(envelope_tier "$_caller")"  # ...and the measured one is used, for tier= only
#
# They were never compared. So `5dive agent send X --from=marcus`, run by dev,
# rendered `[5dive-msg from=marcus id=... tier=admin]` — byte-for-byte identical
# to a send marcus actually made.
#
# WHY tier= DOES NOT ALREADY COVER THIS. DIVE-1064 built tier= as the unforgeable
# field and DIVE-2210 stopped it vanishing on a failed lookup. Both defend against
# a CROSS-tier peer. dev and marcus are both `admin`, so on a same-tier spoof the
# unforgeable field AGREES with the forged one and corroborates it. There was no
# tell of any kind.
#
# WHAT IS ASSERTED HERE:
#   A. envelope_via() partitions the outcomes: empty ONLY for measured-and-matched,
#      a named caller when they diverge, and a distinct `unknown:<reason>` for every
#      path that could not measure. This is the DIVE-2210 property applied to the
#      new field: absence must mean exactly one thing, and "we could not check"
#      must never be spelled the same way as "we checked and it matched".
#   B. Differential: the spoof, the genuine send and the unmeasurable-caller send
#      render as THREE distinct envelopes with via=, and as ONE without it.
#   C. Seam: at each of the three stamp sites in cmd_agent_runtime.sh, the SAME
#      variable that builds from= is argument 1 and the SAME variable that feeds
#      envelope_tier is argument 2 — so the site compares the two values it has in
#      hand, not two unrelated ones. Structural, because B renders a mirror of the
#      header rather than driving a real send (see below).
#
# NOT MEASURED, declared: this drives no tmux, no sudo and no real send, so the
# header text in B is built by a local mirror of the shipped format, not by the
# shipped code. That mirror can drift; C is what pins it, by asserting the call
# and its two arguments at every site rather than trusting the mirror. Nothing
# here proves a receiver ACTS on via= — no consumer reads it yet; this ticket
# makes the divergence visible, it does not adjudicate it.
#
# Pure: no root, no network, no tmux, no registry.
#   bash tests/envelope_divergence_marker_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of `2>/dev/null`
# — redirecting the source's stderr also swallows the helper's own stderr line,
# which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { # eq_t <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi
}

RT=src/cmd_agent_runtime.sh
SRC=src/lib/registry.sh

# Source the SHIPPED resolver out of the real source file so this test cannot
# drift from the code that runs. Same technique as envelope_tier_provenance_unit.sh.
eval "$(awk '/^envelope_via\(\) \{$/ { on=1 } on { print } on && $0 == "}" { exit }' "$SRC")"
declare -F envelope_via >/dev/null \
  || { echo "FAIL: could not extract envelope_via from $SRC (function missing?)"; exit 1; }

# ---------------------------------------------------------------------------
# A. envelope_via(): the outcomes are partitioned, and absence means ONE thing.
# ---------------------------------------------------------------------------
eq_t "claim matches the measured caller -> nothing stamped" \
     "" "$(envelope_via dev dev)"
eq_t "claim diverges -> the MEASURED caller is named" \
     "dev" "$(envelope_via marcus dev)"
eq_t "no caller could be derived -> a REASON, never silence" \
     "unknown:no-caller" "$(envelope_via marcus "")"
eq_t "a synthetic label with a real caller behind it still names the caller" \
     "dev" "$(envelope_via task-engine dev)"

# Field injection: the value lands in a SPACE-delimited header, so a caller
# carrying a space would forge a second envelope field (`via=dev tier=root`).
eq_t "space-bearing caller is refused, not pasted through" \
     "unknown:malformed-caller" "$(envelope_via marcus "dev tier=root")"
eq_t "and a caller that is not a bare token at all is refused" \
     "unknown:malformed-caller" "$(envelope_via marcus "../../etc")"

# THE INVARIANT, stated directly: empty is reachable from exactly one input class.
# Without this, "could not measure" would render identically to "measured, matched"
# — the DIVE-2210 collapse, rebuilt on the new field.
_empties=0
for pair in "dev|" "marcus|" "marcus|dev" "ask|" "human|" "marcus|dev tier=root"; do
  [[ -n "$(envelope_via "${pair%%|*}" "${pair#*|}")" ]] || _empties=$((_empties+1))
done
eq_t "no unmeasured path renders as absence" "0" "$_empties"
# ...and liveness for that probe: the matched case IS still empty, so the check
# above is not passing because envelope_via never returns empty at all.
[[ -z "$(envelope_via dev dev)" ]] \
  && ok_t "the matched case is still empty (the probe above is not vacuous)" \
  || bad_t "matched case is no longer empty" "every send would now carry via="

# Every reason is a bare, header-safe token.
_bad=0
for r in "$(envelope_via marcus "")" "$(envelope_via marcus "dev tier=root")"; do
  [[ "$r" =~ ^[a-z][a-z0-9_:-]*$ ]] || _bad=1
done
eq_t "every reason is a bare header-safe token" "0" "$_bad"

# ---------------------------------------------------------------------------
# B. Differential: three causes, three envelopes — one envelope without via=.
#
# _hdr mirrors the shipped header format. It is a MIRROR (see the header note);
# section C pins it to the real stamp sites.
# ---------------------------------------------------------------------------
_hdr() { # _hdr <claimed> <measured> <tier> [--no-via]
  local h="[5dive-msg from=$1 id=deadbeef tier=$3"
  if [[ "${4:-}" != "--no-via" ]]; then
    local v; v="$(envelope_via "$1" "$2")"
    [[ -n "$v" ]] && h+=" via=$v"
  fi
  printf '%s]\n' "$h"
}

# The three causes the receiver has to tell apart. Same claimed sender, same tier
# — because dev and marcus are BOTH admin, which is exactly why tier= cannot help.
_genuine=$(_hdr marcus marcus admin)                 # marcus really sent it
_spoof=$(_hdr   marcus dev    admin)                 # dev asserted --from=marcus
_unmeas=$(_hdr  marcus ""     unknown:no-caller)     # nothing measured the claim

eq_t "genuine send is unchanged (no marker on the ordinary path)" \
     "[5dive-msg from=marcus id=deadbeef tier=admin]" "$_genuine"
eq_t "same-tier spoof names the real caller" \
     "[5dive-msg from=marcus id=deadbeef tier=admin via=dev]" "$_spoof"
eq_t "unverifiable claim says so instead of looking genuine" \
     "[5dive-msg from=marcus id=deadbeef tier=unknown:no-caller via=unknown:no-caller]" "$_unmeas"

_distinct=$(printf '%s\n' "$_genuine" "$_spoof" "$_unmeas" | sort -u | wc -l)
eq_t "the three causes do not collide onto one envelope" "3" "$_distinct"

# The anchor: WITHOUT the field, the genuine send and the spoof are the same bytes.
# This is the baseline that makes the arm above a differential rather than a
# restatement — if it ever reports 2, the defect was never there to fix.
_b_genuine=$(_hdr marcus marcus admin --no-via)
_b_spoof=$(_hdr   marcus dev    admin --no-via)
_baseline=$(printf '%s\n' "$_b_genuine" "$_b_spoof" | sort -u | wc -l)
eq_t "BASELINE: without via=, a spoof is byte-identical to the genuine send" \
     "1" "$_baseline"

# ---------------------------------------------------------------------------
# C. Seam: every stamp site compares the two values IT holds.
#
# B grades a mirror of the header. This grades the real sites: at each one, the
# variable interpolated into from= must be envelope_via's FIRST argument and the
# variable handed to envelope_tier must be its SECOND. A site that called
# `envelope_via` with some other pair would satisfy a bare "is it called?" grep
# and compare nothing.
# ---------------------------------------------------------------------------
check_site() { # check_site <label> <fn> <claimed-var> <measured-var>
  local label="$1" fn="$2" claimed="$3" measured="$4" body
  body="$(awk -v f="^${fn}\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$RT")"
  [[ -n "$body" ]] || { bad_t "$label: could not extract ${fn}() from $RT"; return; }
  grep -qF "from=\${${claimed}}" <<<"$body" \
    || { bad_t "$label: from= is not built from \$${claimed} (site moved?)"; return; }
  grep -qF "envelope_tier \"\$${measured}\"" <<<"$body" \
    || { bad_t "$label: tier= is not measured from \$${measured} (site moved?)"; return; }
  grep -qF "envelope_via \"\$${claimed}\" \"\$${measured}\"" <<<"$body" \
    || { bad_t "$label: holds \$${claimed} and \$${measured} and does NOT compare them"; return; }
  ok_t "$label: compares from=\$${claimed} against measured caller \$${measured}"
}

# The three acceptors. `send` and `ask` both take --from; `_deliver` derives it,
# and is included because its synthetic `from=human` is the same unchecked claim.
# Enumerating ALL of them is the point — DIVE-2182 shipped a finding scoped to
# `send` alone and `ask` turned out to be the weaker path.
check_site "send"     cmd_send     sender  _caller
check_site "ask"      cmd_ask      sender  _dcaller
check_site "_deliver" cmd_deliver  s       _caller

# And no NEW envelope builder may appear without a via= stamp. Counts only the
# shell header builders, mirroring envelope_tier_provenance_unit.sh's probe.
_sites=$(grep -cE '^\s*local header="\[5dive-msg from=' "$RT")
_vias=$(grep -cE '^\s*\[\[ -n "\$_?d?via" \]\] && header\+=" via=' "$RT")
(( _sites > 0 )) || bad_t "found no envelope builders at all in $RT — probe is broken"
eq_t "every [5dive-msg builder in $RT is matched by a via= stamp" "$_sites" "$_vias"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
