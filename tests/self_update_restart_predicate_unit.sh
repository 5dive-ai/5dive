#!/usr/bin/env bash
# DIVE-3172: `5dive self-update` used to `systemctl restart` EVERY running agent
# unconditionally, on a nightly schedule. A restart mid-turn drops the agent's
# session and its in-flight work, and leaves no record distinguishable from an
# agent that simply went quiet — lodar reported it as "our nightly updates kills
# some active agents mid tasks" (2026-08-10).
#
# The restart was buying nothing on most nights: the 5dive CLI is exec'd per
# command, so a binary swap propagates with zero restarts (MEASURED on the host,
# 0.19.10 -> 0.19.14, every agent reporting the new version on its next
# invocation). Only what the agent PROCESS holds — plugins, skills, CLAUDE.md,
# settings — needs a bounce.
#
# So the predicate is a CONTENT fingerprint of that payload, taken before and
# after the upgrade. This harness grades the two ways it can be wrong, and they
# fail in opposite directions:
#
#   FALSE CHANGE  — the predicate fires when nothing moved, and the fleet gets
#                   restarted every night exactly as before, but now behind a
#                   conditional that makes it LOOK fixed. The live trap is real
#                   and specific: install.sh's refresh_managed_files() swaps the
#                   managed files in unconditionally (`mv -f`), so mtime and
#                   ctime move every single night on files whose bytes did not.
#   FALSE SAME    — the predicate stays quiet when the payload DID move, and a
#                   plugin fix ships but never loads. That is the quieter and
#                   worse failure, so the unreadable/empty cases are graded to
#                   restart rather than to skip.
#
# Hermetic in the shape DIVE-2042 established: the predicate block is extracted
# VERBATIM from src/cmd_selfupdate.sh between its fence markers and run as the
# shipped bytes, against temp directories. sha256sum/find/getent are the REAL
# ones; no systemd, no network, no agent is touched.
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-3172 agent payload fingerprint/,/^# <<< DIVE-3172 agent payload fingerprint/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_agent_payload_fingerprint()' <<<"$block" && grep -q '_agent_home()' <<<"$block"; then
  ok_t "predicate block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "predicate block missing" "markers '# >>> / # <<< DIVE-3172 agent payload fingerprint' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The predicate DERIVES its payload paths from the installer's own per-type maps, so
# the harness must supply the real ones or it would grade a .claude-only fallback and
# reproduce the blind spot it exists to catch. Extracted VERBATIM from src/header.sh
# for the same reason the function block is: a map restated here could drift from the
# map the installer actually writes through, and the drift would be invisible.
maps="$(sed -n '/^declare -A SKILLS_INSTALL_DIR=(/,/^)$/p; /^declare -A TYPE_PERSONA_FILE=(/,/^)$/p' \
  src/header.sh)"
if grep -q 'SKILLS_INSTALL_DIR=(' <<<"$maps" && grep -q 'TYPE_PERSONA_FILE=(' <<<"$maps" \
   && grep -q '\.agents/skills' <<<"$maps" && grep -q '\.codex/AGENTS\.md' <<<"$maps"; then
  ok_t "per-type payload maps are extractable from src/header.sh (non-.claude paths present)"
else
  bad_t "per-type payload maps missing" \
        "SKILLS_INSTALL_DIR / TYPE_PERSONA_FILE not extractable — the derived-path arms below would grade a .claude-only fallback and pass vacuously"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

WORK="$(mktemp -d)"

# fp <home> <lib> -> the fingerprint, running the SHIPPED bytes.
fp() {
  bash -c "set -uo pipefail
$maps
$block
_agent_payload_fingerprint \"\$1\" \"\$2\"" _ "$1" "$2"
}
home_of() {
  bash -c "set -uo pipefail
$block
_agent_home \"\$1\"" _ "$1"
}

# ---- a populated agent home + shared lib, the shape a real box has ----------
H="$WORK/home/agent-fixture"
L="$WORK/lib"
# MIXED ON PURPOSE. creative and marketing are real, live examples of a type=claude
# agent that carries BOTH .claude/skills and .agents/skills (measured 2026-08-10:
# creative 15/7, marketing 3/8). A fix that merely swaps one literal for another
# passes an .agents-only fixture and breaks exactly this case, so the primary home
# is mixed and the .agents-only shape is graded separately below.
mkdir -p "$H/.claude/plugins" "$H/.claude/skills/demo" "$H/.agents/skills/agentsdemo" \
         "$H/.codex" "$L/skills/notify-user"
printf 'agents-dir skill body\n'                  > "$H/.agents/skills/agentsdemo/SKILL.md"
printf '# codex agent rules\n'                    > "$H/.codex/AGENTS.md"
printf '{"plugins":{"telegram@5dive":"0.4.1"}}\n' > "$H/.claude/plugins/installed_plugins.json"
printf 'model: opus\n'                            > "$H/.claude/settings.json"
printf '# agent rules\n'                          > "$H/.claude/CLAUDE.md"
printf 'skill body\n'                             > "$H/.claude/skills/demo/SKILL.md"
printf 'notify\n'                                 > "$L/skills/notify-user/SKILL.md"

base="$(fp "$H" "$L")"
if [[ -n "$base" && "$base" =~ ^[0-9a-f]{64}$ ]]; then
  ok_t "a populated home fingerprints to a sha256"
else
  bad_t "populated home did not fingerprint" "got '${base}'"
fi

if [[ "$(fp "$H" "$L")" == "$base" ]]; then
  ok_t "the fingerprint is stable across calls (no clock, no ordering wobble)"
else
  bad_t "fingerprint is not deterministic" "two calls on an untouched tree disagreed"
fi

# ---- ACCEPTANCE 1: a CLI-ONLY update must move nothing ----------------------
# The CLI binary is not part of the payload, so replacing it — and touching every
# managed file the way `mv -f` does — must leave the fingerprint where it was.
printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="0.19.14"\n' > "$WORK/5dive-binary"
if [[ "$(fp "$H" "$L")" == "$base" ]]; then
  ok_t "ACCEPTANCE 1 — a CLI-only update leaves the payload fingerprint unchanged (0 restarts)"
else
  bad_t "CLI-only update moved the fingerprint" "the predicate would restart the fleet on a CLI-only night"
fi

# The sharp half of the same case. install.sh rewrites the managed files
# unconditionally, so re-writing IDENTICAL bytes with a fresh mtime is what a
# real nightly does to a file nobody changed.
for f in "$H/.claude/settings.json" "$H/.claude/CLAUDE.md" "$L/skills/notify-user/SKILL.md"; do
  cp "$f" "$f.tmp" && mv -f "$f.tmp" "$f"
done
touch -d '2030-01-01 00:00:00' "$H/.claude/settings.json" "$L/skills/notify-user/SKILL.md"
if [[ "$(fp "$H" "$L")" == "$base" ]]; then
  ok_t "an unconditional rewrite of identical bytes (new mtime/ctime) does NOT count as a change"
else
  bad_t "the predicate reads mtime, not content" \
        "refresh_managed_files() mv -f's every file every night — this restarts the whole fleet nightly"
fi

# ---- ACCEPTANCE 2: the positive controls — a real payload change DOES fire --
# Without these the conditional could pass acceptance 1 by simply never being
# true, which is the failure mode that ships a plugin fix nobody loads.
assert_moves() {  # assert_moves <label> <mutation-cmd...>
  local label="$1"; shift
  local prev; prev="$(fp "$H" "$L")"
  "$@"
  local now; now="$(fp "$H" "$L")"
  if [[ -n "$now" && "$now" != "$prev" ]]; then
    ok_t "POSITIVE CONTROL — $label moves the fingerprint (agent is restarted)"
  else
    bad_t "$label did NOT move the fingerprint" "a payload change would ship dormant"
  fi
}
assert_moves "a plugin version repoint in installed_plugins.json" \
  bash -c 'printf "{\"plugins\":{\"telegram@5dive\":\"0.5.0\"}}\n" > "$1"' _ "$H/.claude/plugins/installed_plugins.json"
assert_moves "an edit to a staged shared skill" \
  bash -c 'printf "notify v2\n" > "$1"' _ "$L/skills/notify-user/SKILL.md"
assert_moves "a NEW skill file appearing" \
  bash -c 'mkdir -p "$(dirname "$1")" && printf "new\n" > "$1"' _ "$L/skills/added/SKILL.md"
assert_moves "a skill file being REMOVED" \
  rm -f "$L/skills/added/SKILL.md"
assert_moves "an edit to the agent's CLAUDE.md" \
  bash -c 'printf "# agent rules v2\n" > "$1"' _ "$H/.claude/CLAUDE.md"
assert_moves "an edit to the agent's settings.json" \
  bash -c 'printf "model: sonnet\n" > "$1"' _ "$H/.claude/settings.json"

# ---- DERIVED PATHS: the defect the .claude-only fixture could not see ------
# The predicate used to hash ".claude/skills" and ".claude/CLAUDE.md" as literals.
# Skills and the instructions doc are resolved PER TYPE (SKILLS_INSTALL_DIR /
# TYPE_PERSONA_FILE), so for every non-claude type it watched the wrong directory
# and those agents compared EQUAL forever — skipped every night, silently, which is
# the FALSE SAME failure this file's header calls the worse of the two.
# MEASURED on the fleet 2026-08-10: andy 2, codex 5, ocqa 2 skill dirs under
# .agents/skills with ZERO under .claude/skills; 5 of 13 running agents affected.
# These arms run against the MIXED home above — a .claude-shaped payload is present
# and unchanged throughout, so a fix that swapped one literal for another fails here.
assert_moves "a skill change under .agents/skills, in a home that ALSO has .claude/skills" \
  bash -c 'printf "agents-dir skill v2\n" > "$1"' _ "$H/.agents/skills/agentsdemo/SKILL.md"
assert_moves "a NEW skill appearing under .agents/skills (mixed home)" \
  bash -c 'mkdir -p "$(dirname "$1")" && printf "new\n" > "$1"' _ "$H/.agents/skills/added/SKILL.md"
assert_moves "a skill being REMOVED from .agents/skills (mixed home)" \
  rm -rf "$H/.agents/skills/added"
assert_moves "an edit to a codex agent's .codex/AGENTS.md (the CLAUDE.md analogue)" \
  bash -c 'printf "# codex agent rules v2\n" > "$1"' _ "$H/.codex/AGENTS.md"

# The 100%-invisible shape, graded on its own: a codex/opencode-type home with NO
# .claude directory at all (andy, codex and ocqa are exactly this on the live fleet).
# Under the old literals this home hashed nothing but the shared lib dir, so every
# agent of that shape was permanently unrestartable.
A="$WORK/home/agent-agentsonly"
mkdir -p "$A/.agents/skills/only"
printf 'only\n' > "$A/.agents/skills/only/SKILL.md"
a_base="$(fp "$A" "$L")"
if [[ -n "$a_base" && "$a_base" =~ ^[0-9a-f]{64}$ ]]; then
  ok_t "an .agents-only home (no ~/.claude at all) fingerprints to a sha256 rather than reading as unreadable"
else
  bad_t "an .agents-only home did not fingerprint" "got '${a_base}' — a codex/opencode agent would be invisible to the predicate"
fi
printf 'only v2\n' > "$A/.agents/skills/only/SKILL.md"
if [[ "$(fp "$A" "$L")" != "$a_base" ]]; then
  ok_t "POSITIVE CONTROL — a skill change in an .agents-only home moves the fingerprint (agent is restarted)"
else
  bad_t "an .agents-only home's skill change did NOT move the fingerprint" \
        "andy/codex/ocqa would be SKIPPED every night forever — a plugin fix ships dormant"
fi

# ---- DETERMINISM ACROSS THE DERIVED SET ------------------------------------
# The path list is now built by iterating bash associative arrays, whose order is
# not a contract. If it came out differently on the second snapshot the hash would
# move on an UNCHANGED payload and restart the whole fleet — the FALSE CHANGE
# failure, reintroduced by the fix for the other one. The predicate sorts for this
# reason; this arm is what proves the sort is actually there.
det="$(fp "$H" "$L")"; det_stable=1
for _ in 1 2 3 4 5; do [[ "$(fp "$H" "$L")" == "$det" ]] || det_stable=0; done
if (( det_stable )); then
  ok_t "the derived path set hashes identically across repeated calls (map iteration order cannot leak in)"
else
  bad_t "the derived path set is not order-stable" \
        "an unchanged payload would fingerprint differently between the before and after snapshot and restart every agent"
fi

# ---- UNREADABLE IS NOT UNCHANGED -------------------------------------------
# An empty fingerprint is the caller's signal to fall back to restarting. If a
# home with nothing readable in it returned a hash instead, it would compare
# equal to itself forever and that agent would never be restarted again.
if [[ -z "$(fp "$WORK/home/does-not-exist" "$WORK/lib-does-not-exist")" ]]; then
  ok_t "a home with no readable payload fingerprints EMPTY (caller restarts rather than skips)"
else
  bad_t "an unreadable home returned a hash" "it would compare equal to itself and never restart"
fi
if [[ -z "$(fp "" "$L")" ]]; then
  ok_t "an empty home argument fingerprints EMPTY"
else
  bad_t "empty home argument returned a hash" "got a value where the reading was impossible"
fi

# ---- a path with a space must not split into two hashed entries -------------
S="$WORK/home/agent-spacey"
mkdir -p "$S/.claude/skills/a dir"
printf 'x\n' > "$S/.claude/skills/a dir/SKILL one.md"
sp1="$(fp "$S" "$WORK/lib-none")"
printf 'y\n' > "$S/.claude/skills/a dir/SKILL one.md"
sp2="$(fp "$S" "$WORK/lib-none")"
if [[ -n "$sp1" && -n "$sp2" && "$sp1" != "$sp2" ]]; then
  ok_t "paths containing spaces are hashed whole (edit is still detected)"
else
  bad_t "a spaced path broke the fingerprint" "sp1='$sp1' sp2='$sp2'"
fi

# ---- _agent_home ------------------------------------------------------------
# The root seat runs as `claude` out of /home/claude; assembling
# /home/agent-claude would name a directory that does not exist, read as
# unreadable, and restart that agent every night.
if [[ "$(home_of "claude")" == "$(getent passwd claude 2>/dev/null | cut -d: -f6)" \
   || -z "$(getent passwd claude 2>/dev/null)" ]]; then
  ok_t "_agent_home resolves a real passwd entry rather than assembling /home/agent-<name>"
else
  bad_t "_agent_home ignored passwd for 'claude'" "got '$(home_of claude)'"
fi
if [[ "$(home_of "nosuchagent-xyz")" == "/home/agent-nosuchagent-xyz" ]]; then
  ok_t "_agent_home falls back to the conventional path for an unknown name"
else
  bad_t "_agent_home fallback wrong" "got '$(home_of nosuchagent-xyz)'"
fi

# ---- the caller wires the predicate in the right ORDER ----------------------
# The BEFORE snapshot has to be taken before `--upgrade` runs; after it there is
# nothing left to compare against. A diff that moved the snapshot below the
# installer would pass every case above and skip nobody, forever.
snap_line=$(grep -n '_agent_payload_fingerprint "$(_agent_home' src/cmd_selfupdate.sh | head -1 | cut -d: -f1)
upg_line=$(grep -n 'bash "$installer" --upgrade' src/cmd_selfupdate.sh | head -1 | cut -d: -f1)
if [[ -n "$snap_line" && -n "$upg_line" ]] && (( snap_line < upg_line )); then
  ok_t "the BEFORE fingerprint is taken above the --upgrade call"
else
  bad_t "snapshot order wrong" "before-snapshot line '$snap_line' is not above --upgrade line '$upg_line'"
fi
if grep -q 'skipped+=("$name")' src/cmd_selfupdate.sh \
   && grep -q 'skipped_count' src/cmd_selfupdate.sh; then
  ok_t "skips are reported (a quiet night is distinguishable from an empty box)"
else
  bad_t "skips are not reported" "0-restarts is emitted by both a CLI-only night and a box with no agents"
fi

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
