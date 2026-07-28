#!/usr/bin/env bash
# DIVE-2210 unit: the a2a envelope's tier= field must never be silently OMITTED.
#
# THE DEFECT. `tier=` is the ONE unforgeable field in `[5dive-msg from=X id=Y
# tier=Z]`. `from=` is caller-supplied (`--from=`) and only format-validated, so
# tier= is what actually catches a cross-tier peer. Every stamping site wrote it
# as:
#
#     t="$(registry_read | jq -r ... 2>/dev/null)"
#     [[ -n "$t" ]] && header+=" tier=${t}"
#
# `2>/dev/null` plus "omit if empty" makes FOUR different outcomes produce
# byte-identical output:
#   (1) no sudo caller at all, so no lookup ran      -> not measured
#   (2) registry unreadable / truncated              -> not measured
#   (3) jq failed on the body                        -> not measured
#   (4) sender genuinely has no isolation recorded   -> measured, absent
# A receiver seeing `[5dive-msg from=community id=...]` cannot tell (4) from
# (1)-(3). That is a fail-open on the only real control: the forgeable field
# survives and the unforgeable one disappears without a trace.
#
# WHAT IS ASSERTED HERE:
#   A. envelope_tier() NEVER returns empty, and each not-measured cause returns a
#      DISTINCT `unknown:<reason>` — so the four outcomes above stop colliding.
#   B. registry_read_checked() separates "read failed" from "empty fleet", which
#      plain registry_read() cannot (it manufactures `{"agents":{}}` for both).
#   C. Structural: no envelope-building site is allowed to append tier=
#      conditionally again, and `ask`'s direct path (which carried no tier at all)
#      now carries one.
#
# NOT MEASURED, declared: this does NOT drive tmux, sudo or a real send. It
# exercises the resolver and the header shape, not delivery. Nothing here proves
# which of (1)-(3) produced any specific message observed in the field on
# 2026-07-27 — see the ticket; the audit log has no `agent send` rows to check
# against, so that attribution is open and this suite does not pretend to close it.
#
# Pure: fixture registries in a tmpdir, no root, no network, no tmux.
#   bash tests/envelope_tier_provenance_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { # eq_t <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi
}

# Source the SHIPPED resolvers out of the real source file so this test cannot
# drift from the code that runs. Same technique as
# agent_send_credential_guard_unit.sh / heartbeat_idle_marker_unit.sh.
SRC=src/lib/registry.sh
for fn in registry_read registry_read_checked envelope_tier; do
  eval "$(awk -v f="^${fn}\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$SRC")"
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: could not extract ${fn} from $SRC (function missing?)"; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# A. envelope_tier(): every path yields a non-empty, self-describing value.
# ---------------------------------------------------------------------------
REGISTRY="$TMP/agents.json"
cat > "$REGISTRY" <<'JSON'
{"agents":{"community":{"isolation":"admin"},"worker":{"isolation":"standard"},
           "ghost":{},"weird":{"isolation":"admin tier=root"}}}
JSON

eq_t "registered admin sender stamps its real tier"     "admin"    "$(envelope_tier community)"
eq_t "registered standard sender stamps its real tier"  "standard" "$(envelope_tier worker)"

# (1) no sudo caller -> the cmd_send `--from=X` fail-open. This is the one that
# used to render a clean `[5dive-msg from=community id=...]` with no tier.
eq_t "empty caller is a REASON, not an omission"  "unknown:no-caller" "$(envelope_tier "")"
eq_t "absent caller arg is a REASON"              "unknown:no-caller" "$(envelope_tier)"

# (4) genuine absence — must be DISTINCT from (1)-(3), which is the whole point.
eq_t "registered-but-untiered is its own reason"  "unknown:unregistered" "$(envelope_tier ghost)"
eq_t "unknown name is its own reason"             "unknown:unregistered" "$(envelope_tier nosuchagent)"

# (2) registry unreadable / missing.
REGISTRY="$TMP/does-not-exist.json"
eq_t "missing registry is a REASON"  "unknown:no-registry" "$(envelope_tier community)"

REGISTRY="$TMP/agents.json"
if [[ $EUID -eq 0 ]]; then
  # chmod is inert against root: root reads a 000 file fine, so this probe would
  # pass vacuously. Skip rather than assert something we did not measure.
  ok_t "SKIP unreadable-registry probe (running as root; chmod cannot deny root)"
else
  chmod 000 "$REGISTRY"
  eq_t "unreadable registry is a REASON"  "unknown:registry-unreadable" "$(envelope_tier community)"
  chmod 640 "$REGISTRY"
fi

# (3) body present but not JSON (truncated / partial write).
printf '%s' '{"agents":{"community":{"isolat' > "$TMP/trunc.json"
REGISTRY="$TMP/trunc.json"
eq_t "truncated registry is a REASON"  "unknown:registry-unparsable" "$(envelope_tier community)"

# Field injection: a tier value carrying a space would forge extra envelope
# fields ("tier=admin tier=root" parses as two). Reject rather than paste through.
REGISTRY="$TMP/agents.json"
eq_t "space-bearing tier value is refused, not pasted"  "unknown:malformed-tier" "$(envelope_tier weird)"

# The invariant behind all of the above, stated once directly.
REGISTRY="$TMP/agents.json"
_empty=0
for c in community worker ghost nosuchagent "" ; do
  [[ -n "$(envelope_tier "$c")" ]] || _empty=1
done
REGISTRY="$TMP/nope.json";   [[ -n "$(envelope_tier community)" ]] || _empty=1
REGISTRY="$TMP/trunc.json";  [[ -n "$(envelope_tier community)" ]] || _empty=1
(( _empty == 0 )) && ok_t "envelope_tier never returns empty on any measured path" \
                  || bad_t "envelope_tier returned empty — the omission is back"

# All reasons are distinct AND all are bare tokens safe for a space-delimited header.
REGISTRY="$TMP/agents.json"
_reasons=("$(envelope_tier "")" "$(envelope_tier ghost)" "$(envelope_tier weird)")
REGISTRY="$TMP/nope.json";  _reasons+=("$(envelope_tier community)")
REGISTRY="$TMP/trunc.json"; _reasons+=("$(envelope_tier community)")
_uniq=$(printf '%s\n' "${_reasons[@]}" | sort -u | wc -l)
eq_t "the not-measured causes do not collide onto one value" "5" "$_uniq"
_bad=0
for r in "${_reasons[@]}"; do [[ "$r" =~ ^[a-z][a-z0-9_:-]*$ ]] || _bad=1; done
(( _bad == 0 )) && ok_t "every reason is a bare header-safe token" \
                || bad_t "a reason contains a character that would break the envelope"

# ---------------------------------------------------------------------------
# B. registry_read_checked vs registry_read: the collapse that hid the failure.
# ---------------------------------------------------------------------------
REGISTRY="$TMP/nope.json"
_rc=0; registry_read_checked >/dev/null || _rc=$?
eq_t "checked read reports missing registry"   "3" "$_rc"
eq_t "plain registry_read invents a body instead" '{"agents":{}}' "$(registry_read)"

REGISTRY="$TMP/trunc.json"
_rc=0; registry_read_checked >/dev/null || _rc=$?
eq_t "checked read reports unparsable registry" "5" "$_rc"

REGISTRY="$TMP/agents.json"
_rc=0; registry_read_checked >/dev/null || _rc=$?
eq_t "checked read passes a good registry through" "0" "$_rc"
if [[ "$(registry_read_checked | jq -r '.agents.community.isolation')" == "admin" ]]; then
  ok_t "checked read emits the real body"
else
  bad_t "checked read did not emit the registry body"
fi

# Liveness: an ALWAYS-3 (or always-5) stub would satisfy the two rc probes above
# without reading anything. The rc-0 case just above is that liveness proof, and
# so is this: an EMPTY fleet must be rc 0, not an error — "empty" is a real answer.
printf '%s' '{"agents":{}}' > "$TMP/empty.json"
REGISTRY="$TMP/empty.json"
_rc=0; registry_read_checked >/dev/null || _rc=$?
eq_t "an empty-but-valid registry reads OK (not an error)" "0" "$_rc"
eq_t "and an empty fleet still yields the unregistered reason" \
     "unknown:unregistered" "$(envelope_tier community)"

# ---------------------------------------------------------------------------
# C. Structural: the omission cannot be reintroduced at a stamping site.
#
# Behaviour tests above cover the resolver. They cannot see a NEW envelope site
# that reverts to `[[ -n "$t" ]] && header+=" tier=..."`, which is precisely how
# this shipped — three sites, each written separately, one of them (ask) never
# given a tier at all. So assert on the source shape too.
# ---------------------------------------------------------------------------
RT=src/cmd_agent_runtime.sh

_cond=$(grep -cE '\[\[ -n "\$_?tier" \]\].*header\+=" tier=' "$RT")
eq_t "no site appends tier= conditionally" "0" "$_cond"

# Count only the SHELL header builders (`header="[5dive-msg from=...`), not the
# embedded python/awk helpers that merely match the literal string.
_sites=$(grep -cE '^\s*local header="\[5dive-msg from=' "$RT")
_stamped=$(grep -cE '^\s*(local header="\[5dive-msg from=.*tier=|header\+=" tier=)' "$RT")
(( _sites > 0 )) || bad_t "found no envelope builders at all in $RT — probe is broken"
eq_t "every [5dive-msg builder in $RT is matched by a tier stamp" "$_sites" "$_stamped"

if grep -q 'header="\[5dive-msg from=\${sender} id=\${msg_id} tier=' "$RT"; then
  ok_t "ask's direct-inject envelope now carries tier= (it carried none)"
else
  bad_t "ask's direct-inject envelope has no tier= field"
fi

# The old swallow-and-omit idiom must be gone from the envelope paths entirely.
if grep -qE "registry_read \| jq -r --arg n .*isolation // empty" "$RT"; then
  bad_t "an envelope site still does its own stderr-swallowing registry lookup"
else
  ok_t "envelope sites all go through envelope_tier (no local swallowed lookup)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
