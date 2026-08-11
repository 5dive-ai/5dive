#!/usr/bin/env bash
# DIVE-2183 unit: `--from=<a registered agent's name>` must be REFUSED, at BOTH
# acceptors, when the caller is not that agent.
#
# WHAT THIS IS THE OTHER HALF OF. DIVE-2552 shipped `via=`, a MARKER, and wrote
# down why it stopped short of a refusal: the broad guard ("reject --from=X unless
# X is the caller") breaks the legitimate synthetic-label senders — `comment-watch`,
# `blocker-push`, `community-heartbeat`, `host-updates`, `loop`, `task-engine`,
# `council`, `verifier`, `ask` — none of which are agent names. That argument rules
# out the BROAD guard only. This ticket ships the NARROW one: refuse a claim on a
# name the REGISTRY knows, which has no legitimate caller but that agent itself.
#
# So the load-bearing assertion here is not "the spoof is refused" — it is that the
# spoof is refused AND the nine synthetic labels are not, from the same function, on
# the same fixture. Section B grades that as a DIFFERENTIAL against a mirror of the
# broad guard, because "narrow" is a claim about what the guard leaves alone and an
# arm that only checks refusals cannot see it.
#
# WHAT IS ASSERTED:
#   A. envelope_peer_forgery() partitions every outcome, and no verdict is empty.
#      The DIVE-2210 property again: "could not check" is spelled differently from
#      "checked, and fine". Includes the tier_unmeasured() trap — a REGISTERED agent
#      whose isolation field is missing is still a registered name, and must refuse.
#   B. Differential: the broad guard refuses 9 synthetic labels, the shipped guard
#      refuses 0 of them and still refuses the forged peer. Both counts asserted, so
#      neither direction can pass vacuously.
#   C. Seam: cmd_send and cmd_ask each call the guard with the SAME claimed variable
#      that builds from=, and a measured variable assigned from `_envelope_caller`
#      in that same function. A site fed some other pair would satisfy a bare
#      "is it called?" grep and check nothing.
#   D. ACCEPTOR CENSUS: every function in cmd_agent_runtime.sh that parses `--from=`
#      calls the guard. This is the lesson of
#      community/wiki/a-control-partitions-a-population-and-populations-drift.md
#      written as a test — DIVE-2182 scoped its finding to `send`, and `ask` turned
#      out to be a second, weaker acceptor nobody had enumerated. A THIRD acceptor
#      added later goes red here instead of being found by the next audit.
#   E. Live (conditional): the SHIPPED binary refuses a forged peer and does NOT
#      refuse a synthetic label, on a target that cannot receive either way. Skipped
#      loudly where there is no populated registry (CI), never silently.
#
# NOT MEASURED, declared: no message is ever delivered here. A and B drive the
# extracted resolver against a FIXTURE registry, not the live one, so the fleet's
# tier mix cannot change the result. E runs the real CLI but only against a
# nonexistent target, so it grades the refusal ORDER (guard before delivery), not a
# delivery. Nothing here proves the sudoers/scoped path cannot forge — it re-derives
# the envelope in `_deliver` and never sees `--from` at all.
#
# Pure (A-D): no root, no tmux, no live registry.
#   bash tests/envelope_peer_forgery_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one EXIT trap, fires on every path.
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n' "$1"; }
eq_t()   { # eq_t <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi
}

RT=src/cmd_agent_runtime.sh
SRC=src/lib/registry.sh

# Source the SHIPPED resolvers out of the real source file so this harness cannot
# drift from the code that runs. Same technique as envelope_divergence_marker_unit.sh.
extract() { awk -v f="^$1\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$SRC"; }
for fn in registry_read_checked envelope_via agent_tier tier_unmeasured envelope_peer_forgery; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null \
    || { echo "FAIL: could not extract $fn from $SRC (renamed or reshaped?)"; exit 1; }
done

# FIXTURE registry. Reserved-fake names only where a name is invented; `dev`/`main`
# are the two the ticket's own repro uses. `untiered` and `spacey` exist for the
# tier_unmeasured trap in A: both are REGISTERED, and neither has a usable tier.
REGISTRY="$TMP/agents.json"
cat > "$REGISTRY" <<'JSON'
{ "agents": {
    "dev":      { "isolation": "admin" },
    "main":     { "isolation": "admin" },
    "example1": { "isolation": "standard" },
    "untiered": { "type": "claude" },
    "spacey":   { "isolation": "admin root" }
} }
JSON

# The synthetic labels the narrow guard exists to preserve. Every one is a live
# `agent send --from=` label (the first four measured in-tree/on-host) or a rail
# sender named in the DIVE-2552 comment. None is an agent name, and the guard's
# entire safety argument is that this stays true.
SYNTHETIC=(comment-watch blocker-push community-heartbeat host-updates loop task-engine council verifier ask)

# ---------------------------------------------------------------------------
# A. Verdicts are partitioned, and none is empty.
# ---------------------------------------------------------------------------
eq_t "forged peer: dev claiming main is REFUSED, naming the real caller" \
     "refuse:dev" "$(envelope_peer_forgery main dev)"
eq_t "and it is symmetric — main claiming dev is refused too" \
     "refuse:main" "$(envelope_peer_forgery dev main)"
eq_t "own name still sends" \
     "ok:corroborated" "$(envelope_peer_forgery dev dev)"
eq_t "cross-tier does not change the answer (standard peer, same refusal)" \
     "refuse:dev" "$(envelope_peer_forgery example1 dev)"
eq_t "nothing claimed (--raw / --from=) is not a forgery" \
     "ok:unclaimed" "$(envelope_peer_forgery "" dev)"

# Root / human keeps the override, which is the DIVE-2182 scope decision: with no
# derivable caller there is no peer to impersonate FROM.
eq_t "no measurable caller (root, human at a TTY) keeps the override" \
     "ok:unmeasured:no-caller" "$(envelope_peer_forgery main "")"
eq_t "a caller that is not a bare token is unmeasured, not refused" \
     "ok:unmeasured:malformed-caller" "$(envelope_peer_forgery main "dev tier=root")"

# THE tier_unmeasured() TRAP. Both of these are registry HITS with no usable tier.
# Routing the decision through tier measurability instead of registration would
# wave them through — a real peer's name, claimable because that peer had no tier.
eq_t "a REGISTERED agent with no isolation field is still a registered name" \
     "refuse:dev" "$(envelope_peer_forgery untiered dev)"
eq_t "a REGISTERED agent with a malformed tier is still a registered name" \
     "refuse:dev" "$(envelope_peer_forgery spacey dev)"
# ...and the polarity above is not free: tier_unmeasured() calls both UNMEASURED, so
# this pins the two predicates apart rather than trusting them to agree.
_tu=0; tier_unmeasured "$(agent_tier untiered)" && _tu=1
eq_t "the trap is real: tier_unmeasured() DOES call that name unmeasured" "1" "$_tu"

# Registry-level failure: cannot tell a peer name from a synthetic label. Fails OPEN
# to DIVE-2552's via= marker rather than taking out every divergent send on a box
# with one bad file mode.
mv "$REGISTRY" "$TMP/hidden.json"
eq_t "no registry: unmeasured, so the marker carries it instead of a refusal" \
     "ok:unmeasured:no-registry" "$(envelope_peer_forgery main dev)"
printf 'not json' > "$REGISTRY"
eq_t "unparsable registry: says which, and still does not refuse" \
     "ok:unmeasured:registry-unparsable" "$(envelope_peer_forgery main dev)"
mv "$TMP/hidden.json" "$REGISTRY"
if (( EUID != 0 )); then
  chmod 000 "$REGISTRY"
  eq_t "unreadable registry: a distinct reason, not the same one as absent" \
       "ok:unmeasured:registry-unreadable" "$(envelope_peer_forgery main dev)"
  chmod 640 "$REGISTRY"
else
  skip_t "unreadable-registry arm needs a non-root euid (chmod 000 does not stop root)"
fi

# No verdict is ever empty — a caller testing `[[ -z ... ]]` must never see silence,
# and `refuse:` must never be reachable by accident from an unmeasured path.
_empty=0
for pair in "main|dev" "dev|dev" "|dev" "main|" "main|dev tier=root" "untiered|dev" "ask|dev"; do
  [[ -n "$(envelope_peer_forgery "${pair%%|*}" "${pair#*|}")" ]] || _empty=$((_empty+1))
done
eq_t "no input class renders as an empty verdict" "0" "$_empty"
_shape=0
for pair in "main|dev" "dev|dev" "|dev" "main|" "untiered|dev" "ask|dev"; do
  [[ "$(envelope_peer_forgery "${pair%%|*}" "${pair#*|}")" =~ ^(ok|refuse):[a-z][a-z0-9:_-]*$ ]] || _shape=1
done
eq_t "every verdict is a bare ok:/refuse: token" "0" "$_shape"

# ---------------------------------------------------------------------------
# B. Differential: the narrow guard vs the broad one DIVE-2552 refused to ship.
#
# _broad is the guard whose blast radius killed the idea: refuse on any divergence.
# It is here as the BASELINE — without it, "the synthetic labels still work" is an
# assertion about a guard that might simply never refuse anything.
# ---------------------------------------------------------------------------
_broad() { [[ "$1" != "$2" ]] && printf 'refuse\n' || printf 'ok\n'; }

_broad_kills=0 _narrow_kills=0
for label in "${SYNTHETIC[@]}"; do
  [[ "$(_broad "$label" dev)" == refuse ]] && _broad_kills=$((_broad_kills+1))
  [[ "$(envelope_peer_forgery "$label" dev)" == refuse:* ]] && _narrow_kills=$((_narrow_kills+1))
done
eq_t "BASELINE: the broad guard would break all ${#SYNTHETIC[@]} synthetic senders" \
     "${#SYNTHETIC[@]}" "$_broad_kills"
eq_t "the shipped guard breaks none of them" "0" "$_narrow_kills"
# Liveness for the same pair: the narrow guard is not simply permissive.
eq_t "...while still refusing the forged peer the broad one caught" \
     "refuse:dev" "$(envelope_peer_forgery main dev)"
# Each synthetic label individually, so a regression names the label it broke
# rather than only moving a count.
for label in "${SYNTHETIC[@]}"; do
  eq_t "synthetic label '$label' still sends" \
       "ok:synthetic-label" "$(envelope_peer_forgery "$label" dev)"
done

# ---------------------------------------------------------------------------
# C. Seam: each acceptor hands the guard the two values IT holds.
# ---------------------------------------------------------------------------
fnbody() { awk -v f="^$1\\\\(\\\\) \\\\{$" '$0 ~ f { on=1 } on { print } on && $0 == "}" { exit }' "$RT"; }

check_site() { # check_site <label> <fn> <claimed-var> <measured-var>
  local label="$1" fn="$2" claimed="$3" measured="$4" body
  body="$(fnbody "$fn")"
  [[ -n "$body" ]] || { bad_t "$label: could not extract ${fn}() from $RT"; return; }
  grep -qF "from=\${${claimed}}" <<<"$body" \
    || { bad_t "$label: from= is not built from \$${claimed} (site moved?)"; return; }
  grep -qF "${measured}=\"\$(_envelope_caller)\"" <<<"$body" \
    || { bad_t "$label: \$${measured} is not assigned from _envelope_caller — the guard would grade a value the envelope never measured"; return; }
  grep -qF "_agent_refuse_peer_forgery \"\$${claimed}\" \"\$${measured}\"" <<<"$body" \
    || { bad_t "$label: holds \$${claimed} and \$${measured} and does NOT guard on them"; return; }
  ok_t "$label: refuses on from=\$${claimed} vs measured caller \$${measured}"
}
check_site "send" cmd_send sender _caller
check_site "ask"  cmd_ask  sender _gcaller

# The wrapper must consume the RESOLVER, not $SUDO_USER. A SUDO_USER-only guard
# measures nothing for an admin agent — which holds NOPASSWD:ALL and therefore
# invokes `agent send` as its own uid — so it would be green while never firing on
# the exact population the ticket is about. This pins the choice, not the comment.
_w="$(fnbody _agent_refuse_peer_forgery)"
[[ -n "$_w" ]] && grep -qF 'envelope_peer_forgery "$claimed" "$measured"' <<<"$_w" \
  && ok_t "the wrapper delegates the verdict to envelope_peer_forgery" \
  || bad_t "the wrapper does not call envelope_peer_forgery with (claimed, measured)"
grep -qF 'who="$(_envelope_sender_fallback)"' <<<"$(fnbody _envelope_caller)" \
  && ok_t "_envelope_caller still resolves EUID FIRST (the guard can fire without sudo)" \
  || bad_t "_envelope_caller no longer tries the EUID resolver first — an admin agent sending without sudo would measure as no-caller and every forgery would pass"

# ---------------------------------------------------------------------------
# D. Acceptor census: every --from parser guards. (DIVE-2182 missed `ask`.)
# ---------------------------------------------------------------------------
mapfile -t _acceptors < <(
  awk '/^[a-z_]+\(\) \{$/ { fn=$1; sub(/\(\)$/, "", fn) }
       /--from=\*\)/      { if (fn != "") print fn }' "$RT" | sort -u
)
eq_t "the census found acceptors at all (probe is not vacuous)" "2" "${#_acceptors[@]}"
_unguarded=""
for fn in "${_acceptors[@]}"; do
  grep -qF '_agent_refuse_peer_forgery' <<<"$(fnbody "$fn")" || _unguarded+="$fn "
done
eq_t "every --from acceptor in $RT calls the guard" "" "${_unguarded% }"

# ---------------------------------------------------------------------------
# E. Live, conditional: the SHIPPED binary, on a target that cannot receive.
#
# The two runs differ ONLY in the --from label. The target does not exist, so
# neither can deliver anything — what is graded is which failure comes first.
# ---------------------------------------------------------------------------
LIVE_REG=/var/lib/5dive/agents.json
_peer=""
if [[ -x ./5dive && -r "$LIVE_REG" ]] && command -v jq >/dev/null 2>&1; then
  # A registered peer that is NOT this caller, chosen from the live registry.
  _self="$(id -un)"; _self="${_self#agent-}"
  _peer="$(jq -r --arg me "$_self" '.agents|keys[]|select(. != $me)' "$LIVE_REG" 2>/dev/null | head -1)"
fi
if [[ -z "$_peer" ]]; then
  skip_t "live arm needs a built ./5dive and a populated registry with a peer (absent here — A-D are the graded set)"
else
  _t="nonexistent-target-2183"
  ./5dive agent ask "$_t" "probe" --from="$_peer" --timeout=1 >/dev/null 2>&1; _rc_forged=$?
  ./5dive agent ask "$_t" "probe" --from=comment-watch --timeout=1 >/dev/null 2>&1; _rc_synth=$?
  eq_t "LIVE: a forged peer is refused with E_PERMISSION (10) before delivery is attempted" \
       "10" "$_rc_forged"
  [[ "$_rc_synth" != "10" ]] \
    && ok_t "LIVE: the synthetic label is NOT refused (rc=$_rc_synth — it failed later, at the missing target)" \
    || bad_t "LIVE: the synthetic label was refused too — the guard is the broad one"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
