#!/usr/bin/env bash
# DIVE-2088 unit harness: `agent list` — the SURVEY surface — must carry the
# MEASURED sudo grant, not only the stored `isolation` label.
#
# The defect this pins: DIVE-2079 made the per-agent DRILL-DOWN (`agent info`)
# honest, but `list` still emitted `isolation` (a stored label the DIVE-1002
# v1->v2 migration stamped `admin` on every legacy agent WITHOUT reading its
# sudoers file) with nothing measured beside it. So the command you run to
# NOTICE a privilege difference rendered three genuinely different privilege
# levels identically, while the fixed command was the one you only run once you
# already suspect something.
#
# Sources the src/ libs directly and drives cmd_list against a FIXTURE registry
# and a FIXTURE sudoers dir (the documented SUDOERS_D seam), so every class is
# exercised deterministically — no root, no adduser, no real sudo, no network.
# All live I/O cmd_list would otherwise do (state dir, systemd, per-agent model
# and channel reads) is stubbed, so the harness asserts ONLY the grant wiring.
#
# Run: bash tests/agent_list_sudo_unit.sh
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
SRC=src

TMP="$(mktemp -d /tmp/agent-list-sudo-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"   # agent_sudo_grant + classify + implied-label
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"          # cmd_list, the subject

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
# A bare `!=` is the one assertion shape that PASSES when the field it names is
# absent: jq renders a missing key as the string `null`, which differs from any
# real label, so the arm would go green on the very tree it exists to red.
# `differs` requires the value PRESENT first, then different (DIVE-2136).
differs(){
  if   [[ -z "$2" || "$2" == null ]]; then bad "$1" "a present value, anything but '$3'" "${2:-<empty>}"
  elif [[ "$2" != "$3" ]];            then ok  "$1"
  else                                     bad "$1" "anything but '$3'" "$2"; fi
}
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must NOT contain: $3" "$2"; }

# ---------------------------------------------------------------------------
# Fixture sudoers dir — the three populations that all read `isolation: admin`
# on this box today, plus one agent with no drop-in at all.
#
# The dir is READABLE and `legacylabel`'s file is ABSENT on purpose: that is the
# one case sudo_grant_lines may legitimately call `none` rather than `unknown`.
# ---------------------------------------------------------------------------
export SUDOERS_D="$TMP/sudoers.d"
mkdir -p "$SUDOERS_D"

# Pre-DIVE-1002 blanket grant. Labelled `admin`, but WIDER than admin — this is
# the row that must be visibly different from `scoped` below.
cat > "$SUDOERS_D/agent-legacyfull" <<'EOF'
agent-legacyfull ALL=(ALL) NOPASSWD: ALL
EOF
# Exactly what write_admin_sudoers emits today. Labelled `admin`, and IS admin.
cat > "$SUDOERS_D/agent-scoped" <<'EOF'
agent-scoped ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
EOF
# A standard agent MISLABELLED `admin` in the registry — divergence in the other
# direction (label wider than the grant), which must also be flagged.
cat > "$SUDOERS_D/agent-narrow" <<'EOF'
agent-narrow ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _deliver *
agent-narrow ALL=(root) NOPASSWD: /usr/local/bin/5dive _audit_append
EOF
# Recognised grant PLUS a hand-added entry — must not be silently absorbed.
cat > "$SUDOERS_D/agent-drifted" <<'EOF'
agent-drifted ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
agent-drifted ALL=(root) NOPASSWD: /usr/bin/apt-get
EOF

# ---------------------------------------------------------------------------
# Stub every live dependency cmd_list has EXCEPT the grant measurement.
# Deliberately CLEARING state, not no-ops: a stub that returned nothing would
# let a broken subject pass by accident.
# ---------------------------------------------------------------------------
REG=$(jq -nc '{agents: {
  legacyfull: {type:"claude", channels:"none", isolation:"admin",  createdAt:"2026-05-15"},
  scoped:     {type:"claude", channels:"none", isolation:"admin",  createdAt:"2026-07-22"},
  narrow:     {type:"claude", channels:"none", isolation:"admin",  createdAt:"2026-07-22"},
  drifted:    {type:"claude", channels:"none", isolation:"admin",  createdAt:"2026-07-22"},
  legacylabel:{type:"claude", channels:"none",                     createdAt:"2026-05-01"}
}}')
ensure_state_ro()      { :; }
registry_read()        { printf '%s\n' "$REG"; }
# Report every unit as active/enabled rather than letting the probe come back
# empty. Not cosmetic: an empty probe renders ACTIVE and ENABLED as the literal
# "unknown", which is also this feature's unmeasured-grant value — the table
# assertions below would then pass by matching the WRONG column.
systemctl() {
  local u
  for u in legacyfull scoped narrow drifted legacylabel; do
    printf 'Id=5dive-agent@%s.service\nActiveState=active\nUnitFileState=enabled\n\n' "$u"
  done
}
resolve_agent_model()  { printf ''; }
resolve_agent_effort() { printf ''; }
DEFAULT_WORKDIR="/home/claude/projects"

# ---------------------------------------------------------------------------
# 1. --json carries a MEASURED grant per agent, beside (never instead of) the
#    stored label. This is the field the dashboard reads.
# ---------------------------------------------------------------------------
echo "1. agent list --json — measured grant beside the stored label"
JSON_MODE=1
out=$(cmd_list 2>/dev/null)
g() { jq -r --arg n "$1" ".data[] | select(.name==\$n) | $2" <<<"$out"; }

is "legacyfull: label still reported as admin" "$(g legacyfull .isolation)" "admin"
is "legacyfull: measured grant is root-all"    "$(g legacyfull .sudo.grant)" "root-all"
is "legacyfull: runas breadth is 'any'"        "$(g legacyfull .sudo.runas)" "any"
is "legacyfull: implies beyond-admin"          "$(g legacyfull .sudo.impliedIsolation)" "beyond-admin"
is "legacyfull: DIVERGES from its admin label" "$(g legacyfull .sudo.diverges)" "true"

is "scoped: measured grant is cli-root"        "$(g scoped .sudo.grant)" "cli-root"
is "scoped: runas is root only (no -u claude)" "$(g scoped .sudo.runas)" "root"
is "scoped: label and grant AGREE"             "$(g scoped .sudo.diverges)" "false"

is "narrow: measured grant is cli-scoped"      "$(g narrow .sudo.grant)" "cli-scoped"
is "narrow: implies standard, not admin"       "$(g narrow .sudo.impliedIsolation)" "standard"
is "narrow: DIVERGES (label wider than grant)" "$(g narrow .sudo.diverges)" "true"

is "drifted: widest class still reported"      "$(g drifted .sudo.grant)" "cli-root"
is "drifted: extra entries NOT absorbed"       "$(g drifted .sudo.extraEntries)" "true"

# The whole point: two agents with an IDENTICAL stored label must be
# distinguishable in list's own output.
is "identical labels, different measurements" \
   "$(g legacyfull .isolation)=$(g scoped .isolation) but $(g legacyfull .sudo.grant)!=$(g scoped .sudo.grant)" \
   "admin=admin but root-all!=cli-root"

# ---------------------------------------------------------------------------
# 2. Absence of evidence is reported as absence, never as the label.
#    An UNREADABLE sudoers dir is `unknown`; a readable dir with no drop-in for
#    the user is a genuine `none`. Conflating the two is the original defect in
#    miniature, so they are asserted apart.
# ---------------------------------------------------------------------------
echo "2. unmeasured reads as unknown, and unknown is never divergence"
is "legacylabel: no drop-in, dir readable -> none" "$(g legacylabel .sudo.grant)" "none"
is "legacylabel: measured=true (a real none)"      "$(g legacylabel .sudo.measured)" "true"

SUDOERS_D="$TMP/does-not-exist"
out=$(cmd_list 2>/dev/null)
is "unreadable sudoers dir -> grant unknown"   "$(g scoped .sudo.grant)" "unknown"
is "unknown is measured=false"                 "$(g scoped .sudo.measured)" "false"
is "unknown never claims divergence"           "$(g scoped .sudo.diverges)" "false"
# DIVE-2098 (merged after this branch was cut) changed the unmeasurable case from
# `custom` to `unknown`, and that is strictly the better answer: `custom` is a
# GENUINE class, so returning it for a grant nobody could read is this ticket's own
# defect one layer down. The expectation moved with it. Both arms are asserted,
# because "not the label" and "not a genuine class" are different properties and
# the value `unknown` is the only one that satisfies both.
is "unknown does NOT fall back to the label"   "$(g scoped .sudo.impliedIsolation)" "unknown"
differs "impliedIsolation is PRESENT and is not the stored label" \
        "$(g scoped .sudo.impliedIsolation)" "$(g scoped .isolation)"
is "stored label still reported alongside"     "$(g scoped .isolation)" "admin"
SUDOERS_D="$TMP/sudoers.d"

# ---------------------------------------------------------------------------
# 3. The human table: a survey signal, with the detail left to `agent info`.
# ---------------------------------------------------------------------------
echo "3. table column + legend"
JSON_MODE=0
tbl=$(cmd_list 2>/dev/null)
has "table has a SUDO column"                  "$tbl" "SUDO"
has "legacyfull row shows root-all + '!'"      "$tbl" "root-all!"
has "narrow row shows cli-scoped + '!'"        "$tbl" "cli-scoped!"
has "drifted row shows the '+' extras marker"  "$tbl" "cli-root+"
hasnt "an agreeing row carries NO marker"      "$(grep -E '^scoped ' <<<"$tbl")" "!"
has "'!' legend explains which to trust"       "$tbl" "trust the grant"
has "legend points at info for the detail"     "$tbl" "5dive agent info"
hasnt "no unknowns here -> no unknown legend"  "$tbl" "not measurable as"

SUDOERS_D="$TMP/does-not-exist"
tbl=$(cmd_list 2>/dev/null)
has "unmeasurable rows print 'unknown'"        "$tbl" "unknown"
has "unknown legend says how to measure"       "$tbl" "re-run as root"
hasnt "nothing measured -> no divergence claim" "$tbl" "trust the grant"
SUDOERS_D="$TMP/sudoers.d"

echo
printf 'agent_list_sudo_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
