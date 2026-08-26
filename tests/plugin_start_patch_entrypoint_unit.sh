#!/usr/bin/env bash
# TIER: core — 1.6s measured on the 5dive control plane (agent-dev seat,
# 2026-08-26, python3 3.12): fits the 300s PR core; stated, not defaulted.
#
# DIVE-3754 — the CLI's plugin-install start-script patch must not decide what
# the plugin LAUNCHES.
#
# install_channel_plugin_for_agent() (src/lib/agent_setup.sh) rewrites the
# installed plugin's `start` script to take a `bun install` off the channel-start
# path. That is correct and it stays: `npm install --omit=dev` has already run in
# the plugin dir, so a second dependency install at start time buys nothing, and
# when the plugin joins it with `&&` a failed install eats the poller SILENTLY.
# DIVE-3748 measured that failure at 2h33m across three seats — the coordinator
# among them — with 9 human gates pending.
#
# THE DEFECT THIS HARNESS GUARDS. It was written as an assignment of the WHOLE
# script (`d["scripts"]["start"] = "bun server.ts"`), which is a second and
# unannounced decision: it pins the entry point too. DIVE-3752 then shipped
# `bun install --no-summary; bun start.ts` — a launcher whose only job is to
# record WHICH of three indistinguishable failures a dead channel had — and this
# patch deleted it on every seat the CLI installs. Item 3 of that row ran nowhere
# the CLI had been, and nothing said so: the install log printed "Patched start
# script: removed bun install" either way.
#
# WHY THE SHIPPED BYTES AND NOT A RE-IMPLEMENTATION. The patch is a python
# heredoc inside a bash heredoc inside a `sudo -u agent-<name> bash -s`, and
# reaching it for real needs an agent user, bun, a marketplace clone and network.
# Re-typing its logic here would grade a copy and leave the caller unarmed
# (`feedback_extracting_a_rule_to_test_it_does_not_arm_the_caller`). So the arms
# below EXTRACT the `PATCHPY` heredoc verbatim from src/lib/agent_setup.sh and
# run it, unmodified, against fixture package.json files in a temp dir — the same
# way tests/poller_liveness_unit.sh extracts the alarm text it grades.
#
# Run: bash tests/plugin_start_patch_entrypoint_unit.sh  (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
AS="$SRC/lib/agent_setup.sh"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || {
  printf 'FAIL - python3 missing; the patch under test IS python3 and cannot be graded without it\n'
  echo "HARNESS-RC=1"; exit 1
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM

# --- LIVENESS FIRST --------------------------------------------------------
# Every arm below runs an extracted block. If the extraction returns nothing,
# `python3 <<< ""` exits 0 and prints nothing, and a "did it rewrite the file?"
# assertion over an unrewritten file is indistinguishable from a correct
# skip-the-clean-script pass. So prove the extraction found real code first.
PATCHPY=$(awk "/^python3 <<'PATCHPY'\$/{f=1;next} /^PATCHPY\$/{f=0} f" "$AS")
if [[ -n "$PATCHPY" ]] && grep -q 'scripts' <<<"$PATCHPY" && grep -q 'bun' <<<"$PATCHPY"; then
  ok_t "LIVENESS: PATCHPY heredoc extracted from $AS ($(wc -l <<<"$PATCHPY") lines)"
else
  bad_t "LIVENESS: PATCHPY heredoc extracted from $AS" \
        "extraction empty or unrecognisable — every arm below would grade nothing. Did the heredoc get renamed or reindented?"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"; echo "HARNESS-RC=1"; exit 1
fi

# run_patch <start-script>  ->  echoes the resulting start script, sets OUT to stdout
run_patch() {
  local start="$1" dir
  dir=$(mktemp -d "$WORK/case.XXXXXX")
  DIR="$dir" START="$start" python3 - <<'MK'
import json, os
json.dump({"name": "fixture", "scripts": {"start": os.environ["START"]}},
          open(os.path.join(os.environ["DIR"], "package.json"), "w"))
MK
  OUT=$( cd "$dir" && python3 <<<"$PATCHPY" 2>&1 )
  python3 - "$dir/package.json" <<'RD'
import json, sys
print(json.load(open(sys.argv[1]))["scripts"]["start"])
RD
}

expect() { # expect <label> <start-in> <start-out-expected>
  local label="$1" in="$2" want="$3" got
  got=$(run_patch "$in")
  if [[ "$got" == "$want" ]]; then ok_t "$label"
  else bad_t "$label" "start was '$in' -> got '$got', expected '$want' (patch said: $OUT)"; fi
}

# --- 1. THE DEFECT: the launcher DIVE-3752 shipped must survive the patch ----
# This is the exact string on 5dive-plugins origin/main for telegram, buzz and
# dashboard, and the exact case that regressed.
expect "3752 launcher survives: 'bun install --no-summary; bun start.ts' -> 'bun start.ts'" \
       'bun install --no-summary; bun start.ts' 'bun start.ts'

# --- 2. The install is still REMOVED, which is the patch's whole job ---------
got=$(run_patch 'bun install --no-summary; bun start.ts')
if [[ "$got" != *"bun install"* ]]; then
  ok_t "the bun install is still stripped (not merely preserved along with the entry point)"
else
  bad_t "the bun install is still stripped" "got '$got' — the patch became a no-op, which re-arms the silent deafener DIVE-3748 measured"
fi

# --- 3. `&&` — the shape that actually eats the poller ----------------------
# An older plugin cache still carries this, and it is why the strip exists.
expect "&&-gated install: 'bun install --no-summary && bun server.ts' -> 'bun server.ts'" \
       'bun install --no-summary && bun server.ts' 'bun server.ts'
expect "&&-gated install in front of the launcher -> the launcher" \
       'bun install --no-summary && bun start.ts' 'bun start.ts'

# --- 4. NEGATIVE CONTROL: a clean script is not touched ---------------------
# The five telegram-<x> variants ship exactly this. A patch that rewrites
# unconditionally would pass every arm above.
expect "NEGATIVE: a clean 'bun server.ts' is left alone" 'bun server.ts' 'bun server.ts'
expect "NEGATIVE: a clean 'bun start.ts' is left alone"  'bun start.ts'  'bun start.ts'
OUT_CLEAN=$(run_patch 'bun server.ts' >/dev/null; printf '%s' "$OUT")
if [[ "$OUT_CLEAN" == *"already clean"* ]]; then
  ok_t "NEGATIVE: a clean script is REPORTED as untouched, not silently rewritten"
else
  bad_t "NEGATIVE: a clean script is REPORTED as untouched" "patch printed: $OUT_CLEAN"
fi

# --- 5. An unrelated entry point is preserved verbatim ----------------------
# The point of the row: the patch must carry whatever the plugin chose, not a
# name this repo knows about. A future `relay.ts` must survive untouched.
expect "an unknown entry point is preserved verbatim" \
       'bun install --no-summary; bun relay.ts --verbose' 'bun relay.ts --verbose'
expect "a multi-step start keeps every non-install step" \
       'bun install; bun x prebuild; bun start.ts' 'bun x prebuild; bun start.ts'

# --- 6. Rejoin must NOT re-introduce a short-circuit ------------------------
# `&&` between the surviving steps would rebuild the exact deafener: a failing
# prebuild would eat the poller as silently as the install used to.
got=$(run_patch 'bun install; bun x prebuild && bun start.ts')
if [[ "$got" != *"&&"* ]]; then
  ok_t "surviving steps are rejoined with ';', never '&&' (no short-circuit back onto the start path)"
else
  bad_t "surviving steps are rejoined with ';'" "got '$got' — a failure in an earlier step silently drops the poller again"
fi

# --- 7. Nothing to launch: refuse rather than guess -------------------------
# A start script that is ONLY an install has no entry point to preserve.
# Guessing one is how this defect was born, so the patch must leave it and say so.
expect "install-only start script is left as-is (no guessed entry point)" \
       'bun install --no-summary' 'bun install --no-summary'
run_patch 'bun install --no-summary' >/dev/null
if [[ "$OUT" == *"WARNING"* ]]; then
  ok_t "install-only start script is reported LOUDLY, not passed over in silence"
else
  bad_t "install-only start script is reported LOUDLY" "patch printed: $OUT"
fi

# --- 8. POSITIVE CONTROL: the retired implementation must FAIL arm 1 --------
# Prove these arms can fire. Reconstruct the pre-DIVE-3754 patch and require it
# to destroy the launcher — otherwise arm 1 is green for reasons unrelated to
# the fix (a monitor that cannot fire is not a monitor:
# [[test-that-a-monitor-can-fire-not-just-that-it-doesnt-false-alarm]]).
OLD_PATCH='import json
with open("package.json") as f:
    d = json.load(f)
start = d.get("scripts", {}).get("start", "")
if "bun install" in start:
    d["scripts"]["start"] = "bun server.ts"
    with open("package.json", "w") as f:
        json.dump(d, f, indent=2)
'
ctl=$(mktemp -d "$WORK/ctl.XXXXXX")
DIR="$ctl" python3 - <<'MK'
import json, os
json.dump({"name": "fixture", "scripts": {"start": "bun install --no-summary; bun start.ts"}},
          open(os.path.join(os.environ["DIR"], "package.json"), "w"))
MK
( cd "$ctl" && python3 <<<"$OLD_PATCH" ) >/dev/null 2>&1
ctl_got=$(python3 - "$ctl/package.json" <<'RD'
import json, sys
print(json.load(open(sys.argv[1]))["scripts"]["start"])
RD
)
if [[ "$ctl_got" == "bun server.ts" ]]; then
  ok_t "POSITIVE CONTROL: the retired patch DOES destroy the launcher (arm 1 can fire)"
else
  bad_t "POSITIVE CONTROL: the retired patch destroys the launcher" \
        "got '$ctl_got' — the control did not reproduce the defect, so arm 1's green means nothing"
fi

# --- 9. The hardcoded assignment is gone from the shipped source ------------
# Arm 1 grades behaviour; this grades the line, so a re-introduction by a future
# edit is named at the place it happens.
# CODE ONLY — the comment block above the patch quotes the retired line on
# purpose, to say what was wrong with it. Grading the comment would make the
# explanation unwritable.
if grep -vE '^[[:space:]]*#' "$AS" | grep -qE '\["scripts"\]\["start"\] = "bun server\.ts"'; then
  bad_t "the hardcoded 'bun server.ts' assignment is gone from $AS" \
        "the patch pins the entry point again — DIVE-3752's launcher is deleted on every seat the CLI installs"
else
  ok_t "the hardcoded 'bun server.ts' assignment is gone from $AS"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
