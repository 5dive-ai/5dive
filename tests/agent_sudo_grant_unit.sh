#!/usr/bin/env bash
# DIVE-2079 unit harness: `agent info` must report the ENFORCED sudo grant, not
# only the stored isolation label.
#
# The defect this pins: the registry's `isolation` field is a stored label with
# nothing keeping it honest (the DIVE-1002 v1->v2 migration stamped
# isolation:"admin" on every legacy agent without reading its sudoers file), so
# an agent holding `(ALL) NOPASSWD: ALL` and an agent holding the CLI-scoped
# grant both printed `isolation: admin`.
#
# Sources the src/ libs directly — no root, no adduser, no sudo, no network.
# The grant is read from a FIXTURE sudoers dir via the documented SUDOERS_D
# seam, so every class is exercised deterministically and identically whether
# the harness runs as root or as an unprivileged agent.
#
# Run: bash tests/agent_sudo_grant_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-sudo-grant-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"   # DIVE-2098: cmd_info owns the --json projection

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

# --- DIVE-2135: stub the privileged-read seam -------------------------------
# WHY THIS EXISTS. DIVE-2135 gave sudo_grant_lines a last-resort `sudo -n` read,
# so "this directory is unreadable" stopped being a property of the FIXTURE and
# became a property of the RUNNER: a caller who can escalate reads the fixture's
# 0000 dir anyway, finds no drop-in, and honestly reports `none`. Measured on one
# commit, same host, clean extractions, only the caller differing:
#   as a cli-scoped agent  -> 37 passed / 0 failed
#   as a full-sudo account -> 30 passed / 7 failed
# The assertions were sound when written and became UNDERSPECIFIED, not wrong:
# they ask "is the dir unreadable" AND "is the caller unable to escalate", and
# only the first is about this code. So the harness now drives the seam itself
# and the runner's own sudo policy never enters the answer.
#
# `granted` deliberately reads the REAL fixture (bypassing the mode the way a
# privileged reader does) rather than inventing content, so a granted read still
# proves the parse, not just the branch.
PRIV_MODE=denied
install_priv_stub() {
  sudoers_privileged_dump() {
    local dir="$1" one="${2:-}" f _m
    [[ "$PRIV_MODE" == "granted" ]] || return 1
    _m=$(stat -c %a "$dir" 2>/dev/null) || return 1
    chmod u+rx "$dir" 2>/dev/null
    printf '%s\n' "$_SUDOERS_DUMP_OK"
    if [[ -n "$one" ]]; then
      if [[ -f "$dir/$one" ]]; then
        printf '%s%s\n' "$_SUDOERS_DUMP_FILE" "$one"; cat "$dir/$one"
      fi
    else
      for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        printf '%s%s\n' "$_SUDOERS_DUMP_FILE" "${f##*/}"; cat "$f"
      done
    fi
    printf '%s\n' "$_SUDOERS_DUMP_END"
    chmod "$_m" "$dir" 2>/dev/null
  }
}
install_priv_stub

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }

# ---------------------------------------------------------------------------
# 1. classify_sudo_grant over each real-world grant shape.
#    Inputs are verbatim sudoers-file text, so a drift in what the writers emit
#    shows up here rather than as a quietly mislabelled agent.
# ---------------------------------------------------------------------------
echo "1. classify_sudo_grant — every grant shape on this box"

# The pre-DIVE-1002 grant still held by agent-dev/main/olivia/marketing/
# community/creative (measured on poke-two 2026-07-26). Wider than `admin`.
legacy='agent-dev ALL=(ALL) NOPASSWD: ALL'
is "legacy (ALL) NOPASSWD: ALL       -> root-all|any" \
   "$(printf '%s\n' "$legacy" | classify_sudo_grant)" "root-all|any|0"

# Exactly what write_admin_sudoers emits today.
admin_now="$(cat <<'EOF'
# Managed by 5dive (DIVE-1002/1088). Fleet-management scope for admin agent agent-dev3.
agent-dev3 ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
EOF
)"
is "current write_admin_sudoers       -> cli-root|root" \
   "$(printf '%s\n' "$admin_now" | classify_sudo_grant)" "cli-root|root|0"

# Exactly what render_standard_sudoers emits today, both without and with
# --can-push. Generated rather than pasted so a new grant line cannot drift out
# of the recognised set without reddening this test.
is "render_standard_sudoers           -> cli-scoped|root" \
   "$(render_standard_sudoers agent-quinn 0 | classify_sudo_grant)" "cli-scoped|root|0"
is "render_standard_sudoers --can-push -> cli-scoped|root" \
   "$(render_standard_sudoers agent-quinn 1 | classify_sudo_grant)" "cli-scoped|root|0"

is "no entries                        -> none|-" \
   "$(printf '' | classify_sudo_grant)" "none|-|0"

is "hand-added entry                  -> custom|root" \
   "$(printf 'agent-x ALL=(root) NOPASSWD: /usr/bin/apt\n' | classify_sudo_grant)" "custom|root|0"

# A wider recognised class must NOT silently absorb an unrecognised entry:
# extra=1 is what stops `+ /usr/bin/apt` from vanishing into "cli-root".
is "cli-root + hand-added entry       -> cli-root|root|extra" \
   "$(printf 'agent-x ALL=(root) NOPASSWD: /usr/local/bin/5dive *\nagent-x ALL=(root) NOPASSWD: /usr/bin/apt\n' \
      | classify_sudo_grant)" "cli-root|root|1"

# The runas split that actually separates the two `admin` populations: a
# CLI-scoped grant with an ALL runas can still become the claude user.
is "cli-root with (ALL) runas         -> cli-root|any" \
   "$(printf 'agent-x ALL=(ALL) NOPASSWD: /usr/local/bin/5dive *\n' | classify_sudo_grant)" "cli-root|any|0"

# `sudo -l` output, not a sudoers file — the same parser must handle both,
# including the parenless "Matching Defaults entries" preamble.
sudo_l="$(cat <<'EOF'
Matching Defaults entries for agent-dev3 on poke-two:
    env_reset, mail_badpass,
    secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin\:/snap/bin,
    use_pty

User agent-dev3 may run the following commands on poke-two:
    (root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
EOF
)"
is "sudo -l output parses like a file -> cli-root|root" \
   "$(printf '%s\n' "$sudo_l" | classify_sudo_grant)" "cli-root|root|0"

# A `*` in a grant must not be glob-expanded against the cwd during parsing.
cd "$TMP" || exit 1
: > "5dive"; : > "decoy-file"
is "wildcard is not globbed vs cwd    -> cli-root|root" \
   "$(printf 'agent-x ALL=(root) NOPASSWD: /usr/local/bin/5dive *\n' | classify_sudo_grant)" "cli-root|root|0"
cd - >/dev/null || exit 1

# ---------------------------------------------------------------------------
# 2. isolation_implied_by_grant — the label each class would justify.
#    root-all maps to NO label: nothing this CLI provisions is that wide, and
#    rounding it down to `admin` is exactly the misreport being fixed.
# ---------------------------------------------------------------------------
echo "2. isolation_implied_by_grant"
is "root-all   -> beyond-admin" "$(isolation_implied_by_grant root-all)"   "beyond-admin"
is "cli-root   -> admin"        "$(isolation_implied_by_grant cli-root)"   "admin"
is "cli-scoped -> standard"     "$(isolation_implied_by_grant cli-scoped)" "standard"
is "none       -> sandboxed"    "$(isolation_implied_by_grant none)"       "sandboxed"
# DIVE-2098: `unknown` is the ABSENCE of a measurement, not a class. It used to
# fall through the catch-all into `custom`, which IS a real class in this
# vocabulary — so an unmeasurable grant rendered as a confident privilege claim.
is "unknown    -> unknown"      "$(isolation_implied_by_grant unknown)"    "unknown"
is "unrecognised class -> unknown (catch-all claims nothing)" \
   "$(isolation_implied_by_grant not-a-class)" "unknown"
is "custom     -> custom (still a real class)" "$(isolation_implied_by_grant custom)" "custom"

# ---------------------------------------------------------------------------
# 3. agent_sudo_grant end-to-end over the SUDOERS_D seam, including the two
#    "absence" cases that must be told apart: a readable dir with no drop-in
#    (genuinely no sudo) versus an unreadable one (not measurable).
# ---------------------------------------------------------------------------
echo "3. agent_sudo_grant via the SUDOERS_D seam"
FIX="$TMP/sudoers.d"; mkdir -p "$FIX"
printf '%s\n' "$legacy" > "$FIX/agent-legacy"
printf '%s\n' "$admin_now" > "$FIX/agent-modern"
render_standard_sudoers agent-scoped 0 > "$FIX/agent-scoped"

is "legacy drop-in  -> root-all"   "$(SUDOERS_D="$FIX" agent_sudo_grant agent-legacy)" "root-all|any|0"
is "modern drop-in  -> cli-root"   "$(SUDOERS_D="$FIX" agent_sudo_grant agent-modern)" "cli-root|root|0"
is "scoped drop-in  -> cli-scoped" "$(SUDOERS_D="$FIX" agent_sudo_grant agent-scoped)" "cli-scoped|root|0"
is "absent drop-in, readable dir -> none" \
   "$(SUDOERS_D="$FIX" agent_sudo_grant agent-sandboxed)" "none|-|0"

# Unreadable dir: absence of evidence is NOT evidence of `none`. Skipped under
# root, which can read anything and so cannot produce this case.
if [[ "$(id -u)" != "0" ]]; then
  NOREAD="$TMP/noread"; mkdir -p "$NOREAD"; chmod 000 "$NOREAD"
  NOREAD_FULL="$TMP/noread-full"; mkdir -p "$NOREAD_FULL"
  printf '%s\n' "$admin_now" > "$NOREAD_FULL/agent-modern"; chmod 000 "$NOREAD_FULL"

  # ARM 1 — the privileged read is DENIED. Nothing could see the directory, so
  # absence of evidence stays `unknown`. This is the original assertion, with
  # the term that used to be implicit now stated.
  PRIV_MODE=denied
  is "unreadable dir + privileged read DENIED -> unknown, NOT none" \
     "$(SUDOERS_D="$NOREAD" agent_sudo_grant agent-modern)" "unknown|-|0"

  # ARM 2 — the privileged read is GRANTED and the dump is COMPLETE, so the
  # whole directory really was seen and holds no drop-in. `none` here is a
  # measurement, not a guess, and reporting `unknown` would now be the lie.
  PRIV_MODE=granted
  is "unreadable dir + GRANTED complete dump, no drop-in -> none" \
     "$(SUDOERS_D="$NOREAD" agent_sudo_grant agent-modern)" "none|-|0"

  # ARM 3 — granted must not be a synonym for `none`. Same escalation, same
  # unreadable dir, but the drop-in IS there: the real class must come back, or
  # arm 2 would pass just as well against a fallback that returns nothing.
  is "unreadable dir + GRANTED, drop-in present -> the measured class" \
     "$(SUDOERS_D="$NOREAD_FULL" agent_sudo_grant agent-modern)" "cli-root|root|0"

  # ARM 4 — a TRUNCATED dump (no END marker) is not a partial answer, it is no
  # answer: absent-vs-forbidden must survive a read that half-succeeded.
  sudoers_privileged_dump() { printf '%s\n' "$_SUDOERS_DUMP_OK"; }
  is "unreadable dir + TRUNCATED dump -> unknown, NOT none" \
     "$(SUDOERS_D="$NOREAD_FULL" agent_sudo_grant agent-modern)" "unknown|-|0"
  install_priv_stub    # restore the seam. Do NOT wrap the above in a subshell:
                       # `is` increments PASS/FAIL and a subshell discards both,
                       # so the assertion would report nothing and never fail.

  PRIV_MODE=denied
  chmod 755 "$NOREAD" "$NOREAD_FULL"
else
  printf '  skip unreadable-dir case (running as root)\n'
fi

# ---------------------------------------------------------------------------
# 4. The divergence verdict itself — the actual product of this task. This is
#    the jq `diverges` predicate from cmd_info, fed the same fields.
#    NON-VACUITY: case (a) is the exact fleet state that surfaced the defect and
#    MUST come out true; if the predicate were stubbed to `false` it would red.
# ---------------------------------------------------------------------------
echo "4. divergence verdict (label vs measured grant)"
diverges() { # <stored-label> <grant-class>
  local implied; implied=$(isolation_implied_by_grant "$2")
  jq -rn --arg label "$1" --arg class "$2" --arg implied "$implied" \
    '($class != "unknown" and $implied != $label)'
}
is "(a) label admin + root-all grant  -> DIVERGES" "$(diverges admin root-all)"     "true"
is "(b) label admin + cli-root grant  -> agrees"   "$(diverges admin cli-root)"     "false"
is "(c) label standard + cli-scoped   -> agrees"   "$(diverges standard cli-scoped)" "false"
is "(d) label standard + cli-root     -> DIVERGES" "$(diverges standard cli-root)"  "true"
is "(e) label admin + unmeasured      -> no claim" "$(diverges admin unknown)"      "false"

# ---------------------------------------------------------------------------
# 5. DIVE-2098 — the REAL `agent info --json` projection, run as a NON-ROOT
#    caller, must not emit a definite privilege class for an UNMEASURED grant.
#
#    Why this section drives cmd_info instead of re-implementing the jq (as
#    section 4 does): the defect lived in the projection itself, one line above
#    a `diverges` guard that DID check `measured`. A copy of the predicate
#    cannot catch a field the copy does not contain.
#
#    Why NON-ROOT: root can read any sudoers.d and therefore always gets a
#    measurement. The unmeasurable branch is unreachable for a root caller —
#    which is precisely why the defect shipped. Under root we force the same
#    input through the documented `sudo_grant_lines` failure seam so the guard
#    is still graded, and say so out loud.
# ---------------------------------------------------------------------------
echo "5. agent info --json: unmeasured grant must not imply a class (DIVE-2098)"

INFO_TMP="$TMP/info"; mkdir -p "$INFO_TMP"
STATE_DIR="$INFO_TMP"; REGISTRY="$STATE_DIR/agents.json"; JSON_MODE=1
DEFAULT_WORKDIR="${DEFAULT_WORKDIR:-/home/claude/projects}"
cat > "$REGISTRY" <<'JSON'
{"agents":{"probe":{"type":"claude","isolation":"admin","channels":"none","createdAt":"2026-07-26T00:00:00Z"}}}
JSON
# require_agent lives in a lib this harness does not source; supply a REAL check
# (a no-op stub would let a typo'd agent name silently produce an empty object).
require_agent() {
  jq -e --arg n "$1" '.agents[$n] // empty' <<<"$(registry_read)" >/dev/null \
    || { printf 'require_agent: no such agent: %s\n' "$1" >&2; return 1; }
}

UNREAD="$TMP/unreadable"; mkdir -p "$UNREAD"; chmod 000 "$UNREAD"
info_unmeasured() {   # run cmd_info with a grant that cannot be measured
  if [[ "$(id -u)" != "0" ]]; then
    SUDOERS_D="$UNREAD" cmd_info probe 2>/dev/null | jq -c '.data.sudo'
  else
    ( sudo_grant_lines() { return 1; }; cmd_info probe 2>/dev/null | jq -c '.data.sudo' )
  fi
}
info_measured() {     # control: a real, readable cli-root drop-in
  SUDOERS_D="$FIX" cmd_info probe 2>/dev/null | jq -c '.data.sudo'
}
[[ "$(id -u)" == "0" ]] && printf '  note running as ROOT: unmeasurable case forced via the sudo_grant_lines seam, not a real unreadable dir\n'

# rename the fixture drop-in onto the probe agent for the measured control
cp "$FIX/agent-modern" "$FIX/agent-probe"

UNMEAS="$(info_unmeasured)"; MEAS="$(info_measured)"

is "unmeasured: measured=false"            "$(jq -r '.measured'         <<<"$UNMEAS")" "false"
is "unmeasured: grant=unknown"             "$(jq -r '.grant'            <<<"$UNMEAS")" "unknown"
is "unmeasured: impliedIsolation IS null"  "$(jq -r '.impliedIsolation | type' <<<"$UNMEAS")" "null"
is "unmeasured: impliedIsolation is not ANY definite class" \
   "$(jq -r '[.impliedIsolation] | inside(["beyond-admin","admin","standard","sandboxed","custom"])' <<<"$UNMEAS")" "false"
is "unmeasured: diverges makes no claim"   "$(jq -r '.diverges'         <<<"$UNMEAS")" "false"

# NON-VACUITY: the same call path on a MEASURABLE grant must still produce a
# definite class. Without this, "impliedIsolation is never a class" would pass
# on a projection that had stopped emitting the field at all.
is "measured control: measured=true"       "$(jq -r '.measured'         <<<"$MEAS")"   "true"
is "measured control: impliedIsolation=admin (a real class)" \
   "$(jq -r '.impliedIsolation'  <<<"$MEAS")" "admin"

# ---------------------------------------------------------------------------
# 5b. MUTATION GRADE. A negative assertion passes on empty output, so each of
#     the two guard layers is regressed in a throwaway copy and REQUIRED to
#     bring the wrong answer back. Each mutation asserts it actually applied
#     first — a pattern that silently missed reports a confident fake green.
# ---------------------------------------------------------------------------
echo "5b. mutation grade — reverting each guard must restore the defect"

# PRECONDITION. The whole grade below is conditional on the baseline really
# being UNMEASURED. Under a privileged runner with an unstubbed seam it silently
# was not: control (B) failed, and control (A) kept PASSING for the wrong reason
# (a measured `none` implies "sandboxed", a string, which is all (A) checked).
# A control that has stopped grading must say so rather than report a number.
if [[ "$(jq -r '.grant' <<<"$UNMEAS")" != "unknown" ]]; then
  bad "mutation grade PRECONDITION: baseline is unmeasured" \
      "grant=unknown before mutating" "$(jq -r '.grant' <<<"$UNMEAS")"
fi

MUT="$TMP/mutant"; mkdir -p "$MUT"

# (A) revert ONLY the jq guard. The helper still refuses to invent a class, so
#     the field comes back as the STRING "unknown" — not null, so the type
#     assertion above reds. This grades the projection-level guard.
sed 's/impliedIsolation: (if $grantClass == "unknown" then null else $grantImplied end),/impliedIsolation: $grantImplied,/' \
  "$SRC/cmd_agent.sh" > "$MUT/cmd_agent.sh"
if grep -q 'impliedIsolation: \$grantImplied,' "$MUT/cmd_agent.sh"; then
  MUT_A="$( set +u; source "$MUT/cmd_agent.sh"; install_priv_stub; info_unmeasured )"
  is "(A) jq guard reverted -> impliedIsolation stops being null" \
     "$(jq -r '.impliedIsolation | type' <<<"$MUT_A")" "string"
else
  bad "(A) mutation did not apply — grade is vacuous" "patched cmd_agent.sh" "unchanged"
fi

# (B) revert BOTH layers (the pre-fix tree): the catch-all swallows `unknown`
#     and the projection emits it verbatim, so an UNMEASURED grant renders as
#     `custom` — a genuine class, indistinguishable from a measurement. This is
#     the shipped defect, reproduced.
sed "s/^    custom)   printf 'custom.*$/    NEVERMATCH) : ;;/; s/^    \*)        printf 'unknown.*$/    *)        printf 'custom\\\\n' ;;/" \
  "$SRC/cmd_agent_create.sh" > "$MUT/cmd_agent_create.sh"
if grep -q "^    \*)        printf 'custom" "$MUT/cmd_agent_create.sh"; then
  MUT_B="$( set +u; source "$MUT/cmd_agent_create.sh"; source "$MUT/cmd_agent.sh"; install_priv_stub; info_unmeasured )"
  is "(B) both guards reverted -> the shipped defect returns (custom)" \
     "$(jq -r '.impliedIsolation' <<<"$MUT_B")" "custom"
  # and the helper alone, which is what section 2 pins
  is "(B) helper alone reverted -> unknown maps to custom again" \
     "$( set +u; source "$MUT/cmd_agent_create.sh"; isolation_implied_by_grant unknown )" "custom"
else
  bad "(B) mutation did not apply — grade is vacuous" "catch-all emits custom" "unchanged"
fi

chmod 755 "$UNREAD"

echo
printf 'agent_sudo_grant_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
