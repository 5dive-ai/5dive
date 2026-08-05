#!/usr/bin/env bash
# DIVE-2743 unit: the effective-workdir folder-trust seed in `5dive-agent-start`.
#
# The defect: preseed_claude_agent() writes exactly ONE trusted project into
# ~/.claude.json ("/home/claude/projects"), but a sandboxed agent's workdir
# defaults to /home/agent-<name>, and any agent created with --workdir=<path
# outside the projects root> lands elsewhere at EVERY isolation tier. tmux
# launches claude with -c "$WORKDIR", so those agents come up in an untrusted
# directory and park on the interactive folder-trust dialog, which a headless
# agent cannot answer.
#
# This runs the REAL block, extracted from the real script by its exact guard
# line, against a fake $HOME and fake workdir roots under $TMPDIR. Pure: no root,
# no network, no claude binary, no host paths.
#   bash tests/workdir_trust_seed_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
START=5dive-agent-start
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workdir-trust-seed-unit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }

MARKER='if [[ "$TYPE" == "claude" && -n "${WORKDIR:-}" ]]; then'

# --- non-vacuity, first ------------------------------------------------------
# Every assertion below runs an EXTRACTED block. If the marker ever drifts, awk
# emits nothing, every fixture is "unchanged", and a suite that only asserts
# outcomes goes green while grading an empty string. Prove the extraction found
# real code before trusting a single result.
extract() { awk -v m="$MARKER" '$0 == m {on=1} on {print} on && $0 == "fi" {exit}' "$1"; }
BLOCK="$(extract "$START")"
check "marker present in $START exactly once" "$(grep -cFx "$MARKER" "$START")" "1"
check "extracted block is non-empty and closed" \
  "$([[ -n "$BLOCK" && "$(tail -1 <<<"$BLOCK")" == "fi" ]] && echo yes || echo no)" "yes"
check "extracted block really seeds hasTrustDialogAccepted" \
  "$(grep -q 'hasTrustDialogAccepted' <<<"$BLOCK" && echo yes || echo no)" "yes"
check "extracted block reads the existing config (read-modify-write)" \
  "$(grep -q 'jq -e .type == .object' <<<"$BLOCK" && echo yes || echo no)" "yes"

# Fake roots. The trusted root and the workdirs are all under $TMP so the suite
# never depends on /home existing or being readable.
ROOT="$TMP/projects"; mkdir -p "$ROOT/5dive"
OUTSIDE="$TMP/srv/work";  mkdir -p "$OUTSIDE"
SANDBOX="$TMP/home/agent-probe"; mkdir -p "$SANDBOX"

# What preseed_claude_agent() actually writes today, with the fake root standing
# in for /home/claude/projects. If the seed clobbers this instead of merging, the
# agent re-arms the theme picker AND loses root trust — worse than the stall.
preseed() {
  jq -nc --arg r "$ROOT" '{
    theme:"dark", hasCompletedOnboarding:true,
    projects: { ($r): {hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true} }
  }'
}
# A LIVE config: preseed plus Claude Code's own state. Without these keys an
# assertion cannot SEE a clobber — a jq -n rewrite would still produce a valid
# config with the right trust entry and pass.
live() {
  preseed | jq -c '. + {
    numStartups: 41, machineID: "m-abc", userID: "u-xyz",
    seenNotifications: ["tips"], pluginUsage: {"telegram": 3}
  }'
}

# run <case> <TYPE> <workdir> [initial-json|__none__] [block]
#   -> echoes the fake $HOME it wrote into
run() {
  local case="$1" type="$2" wd="$3" initial="${4:-$(preseed)}" blk="${5:-$BLOCK}"
  local home="$TMP/$case"
  mkdir -p "$home"
  [[ "$initial" == "__none__" ]] || printf '%s\n' "$initial" > "$home/.claude.json"
  (
    set -euo pipefail   # the real script runs under set -e: a seed failure must
                        # never abort the launch, so the subshell must exit 0
    HOME="$home"; NAME="probe"; TYPE="$type"
    WORKDIR="$wd"; DEFAULT_WORKDIR="$ROOT"
    eval "$blk"
  ) 2>"$home/.stderr"
  echo "$?" > "$home/.rc"
  printf '%s' "$home"
}

jqf() { jq -r "$2" "$1/.claude.json" 2>/dev/null; }
trusted() { jq -r --arg d "$2" '.projects[$d].hasTrustDialogAccepted' "$1/.claude.json" 2>/dev/null; }
# Byte-for-byte against the exact fixture bytes `run` wrote — not a jq re-render,
# which would hide a rewrite that happens to be semantically equal.
unchanged() { diff -q <(printf '%s\n' "$2") "$1/.claude.json" >/dev/null && echo same || echo changed; }

# --- 1. the reported case: sandboxed, workdir outside the trusted root --------
H=$(run sandboxed claude "$SANDBOX")
check "sandboxed: workdir entry is TRUSTED (the field, not just the key)" \
  "$(trusted "$H" "$SANDBOX")" "true"
check "sandboxed: workdir entry carries project onboarding" \
  "$(jqf "$H" ".projects[\"$SANDBOX\"].hasCompletedProjectOnboarding")" "true"
check "sandboxed: root trust preseed SURVIVES"  "$(trusted "$H" "$ROOT")" "true"
check "sandboxed: theme preseed survives"       "$(jqf "$H" '.theme')" "dark"
check "sandboxed: onboarding preseed survives"  "$(jqf "$H" '.hasCompletedOnboarding')" "true"
check "sandboxed: config stays mode 600"        "$(stat -c '%a' "$H/.claude.json")" "600"
check "sandboxed: exits 0 under set -e"         "$(cat "$H/.rc")" "0"
check "sandboxed: no WARN on the happy path"    "$(grep -c 'WARN' "$H/.stderr")" "0"
check "sandboxed: announces which path it took" \
  "$(grep -c "trusted workdir $SANDBOX" "$H/.stderr")" "1"

# --- 2. WIDER THAN SANDBOXED: explicit --workdir at any isolation tier --------
# Nothing about this defect is sandbox-specific. A guard keyed on the sandboxed
# branch would pass arm 1 and fail here.
H=$(run explicit claude "$OUTSIDE")
check "explicit workdir: entry is TRUSTED"      "$(trusted "$H" "$OUTSIDE")" "true"
check "explicit workdir: root trust survives"   "$(trusted "$H" "$ROOT")" "true"
check "explicit workdir: exits 0"               "$(cat "$H/.rc")" "0"

# --- 3. plain standard: must be byte-for-byte UNCHANGED ----------------------
H=$(run standard claude "$ROOT")
check "standard: config is untouched" "$(unchanged "$H" "$(preseed)")" "same"
check "standard: only the trusted root is listed" "$(jqf "$H" '.projects | length')" "1"

# --- 4. a workdir UNDER the root is already covered by the parent walk --------
# Measured in the 2.1.222 bundle: the trust check walks cwd's parents, so
# $ROOT/5dive inherits $ROOT's entry. Adding one would be noise, not a fix.
H=$(run underroot claude "$ROOT/5dive")
check "under-root workdir: no redundant entry added" "$(jqf "$H" '.projects | length')" "1"
check "under-root workdir: config untouched" "$(unchanged "$H" "$(preseed)")" "same"

# --- 5. ASSERT THE FIELD, NOT THE KEY ----------------------------------------
# Claude Code creates the project entry itself on first visit with
# hasTrustDialogAccepted FALSE, which is why a live probe saw the dialog re-arm
# on an agent whose config already had the workdir key. A seed that only adds a
# missing key leaves such an agent stranded forever.
STRANDED=$(preseed | jq -c --arg d "$SANDBOX" '.projects[$d] = {hasTrustDialogAccepted:false, projectOnboardingSeenCount:2}')
H=$(run stranded claude "$SANDBOX" "$STRANDED")
check "stranded: false flag is flipped to TRUE" "$(trusted "$H" "$SANDBOX")" "true"
check "stranded: unrelated entry fields survive the merge" \
  "$(jqf "$H" ".projects[\"$SANDBOX\"].projectOnboardingSeenCount")" "2"

# --- 6. the clobber detector: Claude Code's own live state must survive -------
H=$(run liveconf claude "$SANDBOX" "$(live)")
check "live config: workdir trusted"        "$(trusted "$H" "$SANDBOX")" "true"
check "live config: numStartups survives"   "$(jqf "$H" '.numStartups')" "41"
check "live config: machineID survives"     "$(jqf "$H" '.machineID')" "m-abc"
check "live config: userID survives"        "$(jqf "$H" '.userID')" "u-xyz"
check "live config: seenNotifications survives" "$(jqf "$H" '.seenNotifications | join(",")')" "tips"
check "live config: pluginUsage survives"   "$(jqf "$H" '.pluginUsage.telegram')" "3"

# --- 7. idempotent across boots ----------------------------------------------
H=$(run idem claude "$SANDBOX" "$(live)")
FIRST=$(cat "$H/.claude.json")
( set -euo pipefail; HOME="$H"; NAME=probe; TYPE=claude; WORKDIR="$SANDBOX"; DEFAULT_WORKDIR="$ROOT"; eval "$BLOCK" ) 2>>"$H/.stderr"
check "idempotent: second boot is a no-op" \
  "$([[ "$FIRST" == "$(cat "$H/.claude.json")" ]] && echo same || echo changed)" "same"

# --- 8. degraded inputs must WARN and fall through, never abort the launch ----
H=$(run malformed claude "$SANDBOX" 'not json at all {{{')
check "malformed config: warns"            "$(grep -c 'WARN' "$H/.stderr")" "1"
check "malformed config: seeds a fresh one" "$(trusted "$H" "$SANDBOX")" "true"
check "malformed config: exits 0"          "$(cat "$H/.rc")" "0"

H=$(run nonobject claude "$SANDBOX" '[1,2,3]')
check "non-object config: warns"            "$(grep -c 'WARN' "$H/.stderr")" "1"
check "non-object config: seeds a fresh one" "$(trusted "$H" "$SANDBOX")" "true"
check "non-object config: exits 0"          "$(cat "$H/.rc")" "0"

H=$(run missing claude "$SANDBOX" '__none__')
check "missing config: created and trusted" "$(trusted "$H" "$SANDBOX")" "true"
check "missing config: mode 600"            "$(stat -c '%a' "$H/.claude.json")" "600"
check "missing config: exits 0"             "$(cat "$H/.rc")" "0"

# unwritable home: mktemp beside the target fails. Warn, launch anyway.
UW="$TMP/unwritable"; mkdir -p "$UW"; printf '%s\n' "$(preseed)" > "$UW/.claude.json"; chmod 500 "$UW"
( set -euo pipefail; HOME="$UW"; NAME=probe; TYPE=claude; WORKDIR="$SANDBOX"; DEFAULT_WORKDIR="$ROOT"; eval "$BLOCK" ) 2>"$TMP/unwritable.stderr"
UW_RC=$?; chmod 700 "$UW"
check "unwritable home: exits 0 (never blocks a launch)" "$UW_RC" "0"
check "unwritable home: warns"  "$(grep -c 'WARN' "$TMP/unwritable.stderr")" "1"
check "unwritable home: leaves the config intact" "$(unchanged "$UW" "$(preseed)")" "same"

# --- 9. other agent types are not touched ------------------------------------
H=$(run codex codex "$SANDBOX")
check "codex agent: config untouched" "$(unchanged "$H" "$(preseed)")" "same"

# --- 10. canonicalization: a symlinked workdir seeds the resolved path --------
# The bundle canonicalizes every key it compares and the cwd claude reports is
# already symlink-resolved, so seeding the literal link path would miss.
mkdir -p "$TMP/real/work"; ln -sfn "$TMP/real/work" "$TMP/linked"
H=$(run symlink claude "$TMP/linked")
check "symlinked workdir: seeds the RESOLVED path" "$(trusted "$H" "$TMP/real/work")" "true"
check "symlinked workdir: does not seed the link path" "$(trusted "$H" "$TMP/linked")" "null"

# A workdir that does not exist degrades to the literal rather than to a guess.
H=$(run ghostdir claude "$TMP/gone/missing")
check "nonexistent workdir: falls back to the literal path" \
  "$(trusted "$H" "$TMP/gone/missing")" "true"
check "nonexistent workdir: exits 0" "$(cat "$H/.rc")" "0"

# --- 11. MUTATION GRADING ----------------------------------------------------
# An assertion that cannot go red proves nothing. Each mutation below is a patch
# someone could plausibly write instead of this one; every one must break at
# least one arm above. Mutants are derived from the EXTRACTED block, so they
# grade the shipped bytes, not a copy.
mut_red() { # mut_red <label> <mutated-block> <case> <workdir> <initial> <jq> <bad-value-that-must-NOT-appear>
  local label="$1" blk="$2" case="$3" wd="$4" init="$5" filter="$6" want="$7"
  local home; home=$(run "mut-$case" claude "$wd" "$init" "$blk")
  local got; got=$(jq -r "$filter" "$home/.claude.json" 2>/dev/null)
  if [[ "$got" != "$want" ]]; then
    echo "ok: mutation '$label' goes RED as required (got=$got want-of-good-code=$want)"
  else
    echo "FAIL: mutation '$label' stayed GREEN — the arm it should break is vacuous"; fail=1
  fi
}

# M1 — no fix at all. The baseline: if this stays green nothing here is graded.
mut_red "fix reverted entirely" ':' revert "$SANDBOX" "$(preseed)" \
  ".projects[\"$SANDBOX\"].hasTrustDialogAccepted" "true"

# M2 — write instead of read-modify-write (the `jq -n` shape the addendum warns
# about). Valid config, correct trust entry, and every live key gone.
M2="${BLOCK//_wtr_base=\$(cat \"\$_wtr_cfg\")/_wtr_base='{}'}"
mut_red "jq -n style rewrite (clobbers live state)" "$M2" clobber "$SANDBOX" "$(live)" \
  '.numStartups' "41"

# M3 — add the KEY without the FIELD. This is the mutant that a presence-only
# assertion cannot see, and it is exactly what a stranded live agent looks like.
M3="${BLOCK//hasTrustDialogAccepted: true,/}"
mut_red "entry added without the trust boolean" "$M3" fieldless "$SANDBOX" "$(preseed)" \
  ".projects[\"$SANDBOX\"].hasTrustDialogAccepted" "true"

# M4 — the sandboxed special case the ticket explicitly forbids. Passes the
# sandboxed arm, strands every explicit --workdir agent.
M4="${BLOCK//\"\$_wtr_dir\" != \"\$_wtr_root\" \&\& \"\$_wtr_dir\" != \"\$_wtr_root\"\/\*/\"\$_wtr_dir\" == *\/home\/agent-*}"
mut_red "keyed on the sandboxed path shape, not on the workdir" "$M4" sandboxonly "$OUTSIDE" "$(preseed)" \
  ".projects[\"$OUTSIDE\"].hasTrustDialogAccepted" "true"

# M5 — skip only on exact equality with the root, ignoring the parent walk.
# Harmless-looking, but it grows a redundant entry per project subdir forever.
M5="${BLOCK// \&\& \"\$_wtr_dir\" != \"\$_wtr_root\"\/\*/}"
mut_red "equality-only skip (ignores the bundle's parent walk)" "$M5" eqonly "$ROOT/5dive" "$(preseed)" \
  '.projects | length' "1"

# Every mutant must actually differ from the block, or mut_red graded a typo.
for m in M2 M3 M4 M5; do
  check "mutant $m really differs from the shipped block" \
    "$([[ "${!m}" != "$BLOCK" ]] && echo differs || echo identical)" "differs"
done

echo
if (( fail )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
