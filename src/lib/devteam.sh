# shellcheck shell=bash
# ── DIVE-6935: the devteam plugin's code, loaded into 5dive itself ────────────
#
# PR delivery, graders, gate evidence, proof badges, `gh`, `push` and `deploy`
# exist for 5dive's OWN software process, not for every box that hires agents.
# They are leaving the core for one plugin, `devteam@5dive-plugins`.
#
# WHY NOT A PLUGIN VERB. A plugin verb is an exec'd binary, and core calls into
# these files in-process from ~108 functions (status.sh, heartbeat, loops, crud,
# routing). An executable cannot hand bash functions back to the process that
# ran it (community/wiki/a-deprecation-shim-that-keeps-the-verb-name-blocks-the-
# plugin-that-replaces-it.md, second half). So the plugin ships the files under
# `core/` and the core reads them in, the same way it reads its own lazy
# modules.
#
# WHO MAY DO THIS. Code read in here runs with 5dive's own rights, which under a
# NOPASSWD sudo grant is root. So it is pinned, all of these, or nothing loads:
#   - the exact key devteam@5dive-plugins, enabled;
#   - its install record says review `official` (set at install from where the
#     marketplace came from, never from the manifest's own claim: DIVE-4955)
#     and that it declared the `core` capability (an undeclared surface is
#     inert, contract §2);
#   - the record, the plugin directory and every file read are owned by root or
#     by whoever is running this, and writable by nobody else. Reading a file
#     only you or root can write gives you nothing you did not already have.
# The buzz move (DIVE-6934) is the same lesson: a verb a seat reaches through a
# root grant must never be handed to whichever plugin claims the name.
#
# PHASE 1 (this file's first version) REMOVES NOTHING. The core still carries
# its own copy of every module below. The plugin's copy stands in for it ONLY
# if it is byte-for-byte the file this core was built from (build.sh records
# each one's sha256 in __DEVTEAM_CORE_SHA). Why: until phase 2, fixes keep
# landing in the core's copy every day. A plugin copy cut a week earlier that
# still won would quietly undo them on exactly the boxes that build 5dive. So a
# copy that differs is skipped and the core's newer code runs; `5dive doctor`
# counts how many match.
# A copy that matches is NOT read again: the core just evaluated those exact
# bytes, and five of the modules declare `readonly` at top level, which dies on
# a second read (`_GH_BOT_ENV: readonly variable`, DIVE-6939: it broke gh, push,
# team, up and down on every box with the plugin). So phase 1 proves the pin,
# the install path, the ownership check and the hash, and changes no code.
# A box without the plugin pays one `stat` per run and behaves exactly as before.
# Phase 2 deletes the core copies; with no recorded sha for a module there is
# nothing to compare against, nothing was evaluated before it, and the plugin's
# copy is read as the code. See DIVE-6935 and DIVE-6959.
#
# FIVEDIVE_DEVTEAM=0 skips the plugin for one run (parity checks, and a way out
# if a bad plugin version ever ships to the fleet).

readonly DEVTEAM_PLUGIN_KEY="devteam@5dive-plugins"

# The core's module name -> the file the plugin ships for it, under core/.
# One table, read by the loader and by `5dive doctor`; a module the plugin does
# not ship is simply not overlaid.
_devteam_module_file() {
  case "$1" in
    task__delivery)       echo "task/delivery.sh" ;;
    task__gate_evidence)  echo "task/gate_evidence.sh" ;;
    task__grader_pool)    echo "task/grader_pool.sh" ;;
    task__grader_process) echo "task/grader_process.sh" ;;
    cmd_proof)            echo "cmd_proof.sh" ;;
    cmd_gh)               echo "cmd_gh.sh" ;;
    cmd_push)             echo "cmd_push.sh" ;;
    cmd_deploy)           echo "cmd_deploy.sh" ;;
    *) return 1 ;;
  esac
}
readonly DEVTEAM_MODULES="task__gate_evidence task__grader_pool task__grader_process task__delivery cmd_proof cmd_push cmd_deploy cmd_gh"

# module -> sha256 of the core's own copy. Filled by lines build.sh writes into
# the bundle right after this file; empty in the split tree.
declare -gA __DEVTEAM_CORE_SHA=()

# <module> <file> -> may the plugin's file stand in for the core's?
#   rc 0  yes, and it must be read: the core carries no copy (phase 2);
#   rc 2  yes, and it is already in: the same bytes the core just evaluated;
#   rc 1  no: it differs from this core's copy.
_devteam_copy_current() {
  local want="${__DEVTEAM_CORE_SHA[$1]:-}" got
  [[ -n "$want" ]] || return 0
  got=$(sha256sum <"$2" 2>/dev/null) || return 1
  [[ "${got%% *}" == "$want" ]] || return 1
  return 2
}

# <path> -> rc 0 iff it is owned by root or by us and nobody else can write it.
_devteam_path_safe() {
  local st uid mode
  st=$(stat -L -c '%u %a' -- "$1" 2>/dev/null) || return 1
  uid=${st%% *}; mode=${st##* }
  [[ "$uid" == 0 || "$uid" == "$EUID" ]] || return 1
  # group and other write bits (mode is octal, e.g. 755 or 2775)
  (( (8#$mode & 8#022) == 0 ))
}

# Why the plugin is not loaded, one short reason, or empty when it is.
# _DEVTEAM_DIR holds the directory when it is.
_DEVTEAM_DIR=""
_DEVTEAM_WHY=""
_devteam_resolve() {
  _DEVTEAM_DIR=""; _DEVTEAM_WHY=""
  local root="${STATE_DIR:-/var/lib/5dive}/plugins"
  local link="$root/enabled/$DEVTEAM_PLUGIN_KEY"
  # The common case on a customer box: one stat, no fork, nothing to say.
  if [[ ! -e "$link" ]]; then _DEVTEAM_WHY="not installed"; return 1; fi
  if [[ "${FIVEDIVE_DEVTEAM:-1}" == 0 ]]; then _DEVTEAM_WHY="skipped (FIVEDIVE_DEVTEAM=0)"; return 1; fi
  command -v jq >/dev/null 2>&1 || { _DEVTEAM_WHY="jq is missing"; return 1; }
  local rec="$root/installed.json"
  _devteam_path_safe "$rec" || { _DEVTEAM_WHY="$rec is writable by someone other than root"; return 1; }
  jq -e --arg k "$DEVTEAM_PLUGIN_KEY" \
     '.[$k] | (.enabled == true) and (.review == "official") and ((.capabilities // []) | index("core") != null)' \
     "$rec" >/dev/null 2>&1 \
    || { _DEVTEAM_WHY="its install record is not an enabled, official plugin with the core capability"; return 1; }
  local dir; dir=$(readlink -f -- "$link" 2>/dev/null) || { _DEVTEAM_WHY="broken link $link"; return 1; }
  [[ -d "$dir/core" ]] || { _DEVTEAM_WHY="$dir has no core/ directory"; return 1; }
  if ! _devteam_path_safe "$dir" || ! _devteam_path_safe "$dir/core"; then
    _DEVTEAM_WHY="$dir is writable by someone other than root"; return 1
  fi
  _DEVTEAM_DIR="$dir"
}

# Filled once per run by _devteam_init: module -> plugin file to read after it.
declare -gA __DEVTEAM_OVERLAY=()

_devteam_init() {
  __DEVTEAM_OVERLAY=()
  _devteam_resolve || return 0
  local m rel f
  for m in $DEVTEAM_MODULES; do
    rel=$(_devteam_module_file "$m") || continue
    f="$_DEVTEAM_DIR/core/$rel"
    [[ -f "$f" ]] || continue
    if ! _devteam_path_safe "$f" || ! _devteam_path_safe "$(dirname -- "$f")"; then
      printf '5dive: warning: not loading %s from the devteam plugin — it is writable by someone other than root. Reinstall: sudo 5dive plugin upgrade %s\n' \
        "$rel" "$DEVTEAM_PLUGIN_KEY" >&2
      continue
    fi
    __DEVTEAM_OVERLAY[$m]="$f"
  done
}

# Called by _load_module right after it evals core modules (and only in a
# built bundle; the split tree has no lazy loader). Runs inside that function,
# which is why the plugin's files, like the core's, write `declare -gA`.
_devteam_overlay() {
  local __dt_m __dt_rc
  for __dt_m in "$@"; do
    [[ -n "${__DEVTEAM_OVERLAY[$__dt_m]:-}" ]] || continue
    __dt_rc=0; _devteam_copy_current "$__dt_m" "${__DEVTEAM_OVERLAY[$__dt_m]}" || __dt_rc=$?
    if (( __dt_rc == 1 )); then
      [[ -z "${FIVE_LAZY_TRACE:-}" ]] \
        || printf '5dive[lazy] overlay %s skipped: the plugin copy differs from this core\n' "$__dt_m" >&2
      continue
    fi
    if (( __dt_rc == 2 )); then
      # Same bytes as the core's copy, which is already in: a second read is
      # a no-op at best and dies on a top-level readonly at worst (DIVE-6959).
      [[ -z "${FIVE_LAZY_TRACE:-}" ]] \
        || printf '5dive[lazy] overlay %s in use from %s (same bytes as the core copy, not re-read)\n' "$__dt_m" "${__DEVTEAM_OVERLAY[$__dt_m]}" >&2
      continue
    fi
    [[ -z "${FIVE_LAZY_TRACE:-}" ]] \
      || printf '5dive[lazy] overlay %s from %s\n' "$__dt_m" "${__DEVTEAM_OVERLAY[$__dt_m]}" >&2
    # shellcheck source=/dev/null
    source "${__DEVTEAM_OVERLAY[$__dt_m]}"
  done
}

# One line for `5dive doctor` (check name: devteam): where the dev-team tools
# come from on this box.
devteam_status_line() {
  _devteam_init
  if [[ -n "$_DEVTEAM_DIR" ]]; then
    local m n=0 rc
    for m in "${!__DEVTEAM_OVERLAY[@]}"; do
      rc=0; _devteam_copy_current "$m" "${__DEVTEAM_OVERLAY[$m]}" || rc=$?
      (( rc == 1 )) || n=$((n + 1))
    done
    printf 'loaded from %s (%s of %s modules in use)\n' \
      "$_DEVTEAM_DIR" "$n" "$(wc -w <<<"$DEVTEAM_MODULES" | tr -d ' ')"
  else
    printf '%s — the dev-team tools run from the core copy\n' "$_DEVTEAM_WHY"
  fi
}
