#!/usr/bin/env bash
# DIVE-4919 unit: core's own notify-user skill is retired; every seat's copy now
# comes from the plugins repo.
#
# The defect: core shipped skills/notify-user/SKILL.md (stale — no ~60-word cap)
# and seeded it into ~/.claude/skills on every claude telegram seat, where it
# loaded NEXT TO the telegram plugin's own `telegram:notify-user`. Two playbooks,
# the older one winning half the time.
#
# Arms:
#   1. the file is gone from the tree and install.sh no longer fetches it
#   2. a fresh claude telegram seat, built by the REAL preseed_claude_agent against
#      a fake home, ends with ZERO core copies and the telegram plugin enabled —
#      i.e. exactly one notify-user, the plugin's
#   3. codex/grok/agy seats are seeded from their own channel plugin's copy; pi and
#      opencode (plugins that ship none) fall back to the staged telegram copy
#   4. the upgrade path (5dive-refresh-skills.sh) removes the stale core copy from
#      an existing claude seat that has the telegram plugin, and only from one
#   5. install.sh stages the fallback FROM the telegram plugin, fail-soft
#   6. mutants: each arm above goes red on the patch it exists to refuse
#
# No root, no network, no /home writes.
#   bash tests/notify_user_skill_source_unit.sh
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/notify-user-source-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
export GH_ORG=5dive-ai

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/models.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
set +e

# Not named ok/fail/check: output.sh and error_codes.sh own those names.
n_pass=0 n_fail=0
t_ok()  { echo "ok: $1"; n_pass=$((n_pass+1)); }
t_bad() { echo "FAIL: $1" >&2; n_fail=$((n_fail+1)); }
t_eq()  { if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1 (want=$3 got=$2)"; fi; }

# sudo stub: drop `-u <user>` / `-H` and run the command as us, so the real
# functions write into the fake homes below.
sudo() {
  while [[ $# -gt 0 ]]; do
    case "$1" in -u) shift 2 ;; -H) shift ;; *) break ;; esac
  done
  "$@"
}
step() { :; }
warn() { :; }
install_default_skill_for_agent() { :; }

# Fixtures: a staged (telegram-plugin) copy, and per-channel plugin dirs.
AGENT_SKILLS_DIR="$TMP/lib/skills"
mkdir -p "$AGENT_SKILLS_DIR/notify-user"
printf -- '---\nname: notify-user\n---\nSTAGED-TELEGRAM\n' > "$AGENT_SKILLS_DIR/notify-user/SKILL.md"
mkplugin() {  # mkplugin <name> [with-skill]
  local d="$TMP/plugins/$1"; mkdir -p "$d"; : > "$d/server.ts"
  if [[ -n "${2:-}" ]]; then
    mkdir -p "$d/skills/notify-user"
    printf -- '---\nname: notify-user\n---\nPLUGIN-%s\n' "$1" > "$d/skills/notify-user/SKILL.md"
  fi
  printf '%s' "$d"
}

echo "== 1. the core copy is gone =="
t_eq "skills/notify-user/SKILL.md absent from the tree" \
  "$([[ -e skills/notify-user/SKILL.md ]] && echo present || echo absent)" "absent"
t_eq "install.sh no longer fetches it from this repo" \
  "$(grep -c 'REPO/skills/notify-user' install.sh)" "0"
t_eq "the Dockerfile bundle no longer COPYs skills/" \
  "$(grep -c '^COPY skills ' docker/Dockerfile)" "0"

echo "== 2. a fresh claude telegram seat gets exactly one notify-user =="
# Run the REAL function with its one hardcoded home root pointed at $TMP.
claude_seat() {  # claude_seat <fn-source> <name> -> prints the fake home
  local fn_src="$1" name="$2"
  mkdir -p "$TMP/home/agent-$name"
  eval "${fn_src//\/home\/agent-/$TMP/home/agent-}"
  preseed_claude_agent "$name" telegram >/dev/null 2>&1
  printf '%s' "$TMP/home/agent-$name"
}
count_core_copies() { find "$1/.claude/skills" -mindepth 1 -maxdepth 1 -name notify-user 2>/dev/null | wc -l | tr -d ' '; }
REAL_CLAUDE="$(declare -f preseed_claude_agent)"
H=$(claude_seat "$REAL_CLAUDE" c1)
t_eq "claude seat: settings.json was really written (non-vacuity)" \
  "$([[ -s "$H/.claude/settings.json" ]] && echo yes || echo no)" "yes"
t_eq "claude seat: telegram@5dive-plugins enabled (the one copy it gets)" \
  "$(jq -r '.enabledPlugins["telegram@5dive-plugins"]' "$H/.claude/settings.json")" "true"
t_eq "claude seat: ZERO core notify-user copies in ~/.claude/skills" "$(count_core_copies "$H")" "0"
t_eq "preseed_claude_agent body names no notify-user SKILL.md" \
  "$(grep -c 'notify-user/SKILL.md' <<<"$REAL_CLAUDE")" "0"

echo "== 3. non-claude seats seed from the plugins repo =="
CODEX=$(mkplugin telegram-codex with); GROK=$(mkplugin telegram-grok with); AGY=$(mkplugin telegram-agy with)
PI=$(mkplugin telegram-pi); OPENCODE=$(mkplugin telegram-opencode)
seat() {  # seat <tag> <plugin-dir> -> content of the seeded SKILL.md
  local d="$TMP/seat-$1/.agents/skills"
  seed_notify_user_skill agent-x "$d" "$2"
  sed -n 4p "$d/notify-user/SKILL.md" 2>/dev/null
}
t_eq "codex seat: telegram-codex's own copy"       "$(seat codex "$CODEX")"       "PLUGIN-telegram-codex"
t_eq "grok seat: telegram-grok's own copy"         "$(seat grok "$GROK")"         "PLUGIN-telegram-grok"
t_eq "agy seat: telegram-agy's own copy"           "$(seat agy "$AGY")"           "PLUGIN-telegram-agy"
t_eq "pi seat: staged telegram copy (no own copy)" "$(seat pi "$PI")"             "STAGED-TELEGRAM"
t_eq "opencode seat: staged telegram copy"         "$(seat opencode "$OPENCODE")" "STAGED-TELEGRAM"
t_eq "no plugin dir at all: staged telegram copy"  "$(seat none "")"              "STAGED-TELEGRAM"
# Nothing on the box: a silent no-op, never a failed create.
( AGENT_SKILLS_DIR="$TMP/nowhere"; seed_notify_user_skill agent-x "$TMP/seat-bare" "$PI" ); rc=$?
t_eq "no source anywhere: rc 0"        "$rc" "0"
t_eq "no source anywhere: nothing written" "$([[ -e "$TMP/seat-bare/notify-user" ]] && echo wrote || echo none)" "none"
# Each installer hands the helper ITS OWN resolver — a copy-paste of the codex
# line into the pi installer would still pass every content arm above.
for pair in codex:codex_plugin_dir grok:grok_plugin_dir antigravity:antigravity_plugin_dir \
            opencode:opencode_plugin_dir pi:pi_plugin_dir; do
  t="${pair%%:*}" r="${pair#*:}"
  body="$(declare -f "install_channel_for_${t}_agent")"
  t_eq "install_channel_for_${t}_agent seeds via \$($r)" \
    "$(grep -c "seed_notify_user_skill .*\"\$($r)\"" <<<"$body")" "1"
  t_eq "install_channel_for_${t}_agent has no direct staged-copy cp" \
    "$(grep -c 'AGENT_SKILLS_DIR/notify-user' <<<"$body")" "0"
done

echo "== 4. the upgrade path retires the stale copy =="
REFRESH=5dive-refresh-skills.sh
extract_fn() { awk -v n="$1()" '$1 == n {on=1} on {print} on && $0 == "}" {exit}' "$2"; }
RETIRE="$(extract_fn retire_core_notify_user "$REFRESH")"
t_eq "retire_core_notify_user extracted (non-vacuity)" \
  "$([[ "$RETIRE" == *'rm -rf'* && "$(tail -1 <<<"$RETIRE")" == "}" ]] && echo yes || echo no)" "yes"
t_eq "the per-agent loop calls it" "$(grep -c '^  retire_core_notify_user "\$home"$' "$REFRESH")" "1"
eval "$RETIRE"
old_seat() {  # old_seat <tag> <telegram-enabled:true|false> -> home with a stale copy
  local h="$TMP/old-$1"
  mkdir -p "$h/.claude/skills/notify-user" "$h/.claude/skills/5dive-cli"
  echo stale > "$h/.claude/skills/notify-user/SKILL.md"
  jq -n --argjson t "$2" '{enabledPlugins: {"telegram@5dive-plugins": $t}}' > "$h/.claude/settings.json"
  printf '%s' "$h"
}
H=$(old_seat tg true);  retire_core_notify_user "$H" >/dev/null
t_eq "telegram seat: stale core copy removed"    "$(count_core_copies "$H")" "0"
t_eq "telegram seat: other skills untouched"     "$([[ -d "$H/.claude/skills/5dive-cli" ]] && echo kept || echo gone)" "kept"
H=$(old_seat notg false); retire_core_notify_user "$H" >/dev/null
t_eq "seat without the telegram plugin: copy KEPT (its only one)" "$(count_core_copies "$H")" "1"
H="$TMP/old-nosettings"; mkdir -p "$H/.claude/skills/notify-user"
retire_core_notify_user "$H" >/dev/null
t_eq "seat with no settings.json: copy KEPT" "$(count_core_copies "$H")" "1"
H="$TMP/old-clean"; mkdir -p "$H/.claude"; retire_core_notify_user "$H"; rc=$?
t_eq "already-clean seat: rc 0 (idempotent)" "$rc" "0"
bash -n "$REFRESH" && t_ok "$REFRESH parses" || t_bad "$REFRESH parse error"

echo "== 5. install.sh stages the fallback from the telegram plugin =="
t_eq "default URL is the telegram plugin's copy" \
  "$(grep -c 'NOTIFY_USER_SKILL_URL:-https://raw.githubusercontent.com/$GH_ORG/5dive-plugins/main/plugins/telegram/skills/notify-user/SKILL.md' install.sh)" "1"
STAGE="$(awk '/^  NOTIFY_USER_SKILL_URL=/ {on=1} on {print} on && /^  rm -f "\$_nu_tmp"$/ {exit}' install.sh)"
t_eq "staging block extracted (non-vacuity)" "$(grep -c 'install -m 644' <<<"$STAGE")" "1"
stage() {  # stage <source-file> -> staged content (line 4) or MISSING
  local lib="$TMP/stage-$RANDOM"; mkdir -p "$lib/skills/notify-user"
  [[ -n "${2:-}" ]] && printf 'PREVIOUS\n' > "$lib/skills/notify-user/SKILL.md"
  ( ok() { :; }; LIB_DIR="$lib"; NOTIFY_USER_SKILL_URL="file://$1"; eval "$STAGE" ) 2>/dev/null
  if [[ -f "$lib/skills/notify-user/SKILL.md" ]]; then
    tail -1 "$lib/skills/notify-user/SKILL.md"
  else echo MISSING; fi
}
TG=$(mkplugin telegram with)
t_eq "stages the plugin's copy"                    "$(stage "$TG/skills/notify-user/SKILL.md")" "PLUGIN-telegram"
t_eq "fetch miss keeps the previous staged copy"   "$(stage "$TMP/no-such-file" keep)"         "PREVIOUS"
printf '<html>404</html>\n' > "$TMP/notaskill.html"
t_eq "a non-skill body is refused, previous kept"  "$(stage "$TMP/notaskill.html" keep)"       "PREVIOUS"

echo "== 6. mutants =="
# M1 — restore the claude seed (the row's named mutant). Arm 2 must go red.
SEED_BLOCK='  if channel_in_list telegram "$channels" \&\& [[ -f "$AGENT_SKILLS_DIR/notify-user/SKILL.md" ]]; then\
    sudo -u "$user" mkdir -p "$home/.claude/skills/notify-user"\
    sudo -u "$user" cp "$AGENT_SKILLS_DIR/notify-user/SKILL.md" "$home/.claude/skills/notify-user/SKILL.md"\
  fi'
M1="$(sed "/preseed_default_skills_for_type \"\$name\" claude/i\\
$SEED_BLOCK" <<<"$REAL_CLAUDE")"
t_eq "M1 applied (non-vacuity)" "$(grep -c 'notify-user/SKILL.md' <<<"$M1")" "2"
H=$(claude_seat "$M1" m1)
t_eq "M1 restored claude seed -> one-skill arm RED (a core copy appears)" "$(count_core_copies "$H")" "1"
eval "$REAL_CLAUDE"

# M2 — retire without the telegram guard: the no-plugin seat loses its only copy.
M2="$(grep -v 'jq -e\|"\$home/.claude/settings.json" >/dev/null' <<<"$RETIRE")"
eval "$M2"
H=$(old_seat m2 false); retire_core_notify_user "$H" >/dev/null
t_eq "M2 unguarded retire -> keep arm RED (copy removed)" "$(count_core_copies "$H")" "0"
eval "$RETIRE"

# M3 — a helper that ignores the channel plugin dir: codex gets the telegram copy.
REAL_SRC="$(declare -f notify_user_skill_src)"
notify_user_skill_src() { printf '%s\n' "$AGENT_SKILLS_DIR/notify-user/SKILL.md"; }
t_eq "M3 plugin-blind helper -> codex arm RED" "$(seat m3 "$CODEX")" "STAGED-TELEGRAM"
eval "$REAL_SRC"

echo
echo "$n_pass passed, $n_fail failed"
[[ "$n_fail" -eq 0 ]]
