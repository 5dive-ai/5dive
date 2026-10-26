# shellcheck shell=bash
# ── DIVE-6935/6938: the devteam plugin's code, loaded into 5dive itself ───────
#
# PR delivery, graders, gate evidence, proof badges, `gh`, `push` and `deploy`
# exist for 5dive's OWN software process, not for every box that hires agents.
# They live in one plugin, `devteam@5dive-plugins`, and the core no longer
# carries a copy (DIVE-6938; phase 1, DIVE-6935, ran the fleet from the plugin
# first and removed nothing).
#
# WHY NOT A PLUGIN VERB. A plugin verb is an exec'd binary, and core calls into
# these files in-process (status.sh, heartbeat, loops, crud, routing). An
# executable cannot hand bash functions back to the process that ran it
# (community/wiki/a-deprecation-shim-that-keeps-the-verb-name-blocks-the-
# plugin-that-replaces-it.md, second half). So the plugin ships the files under
# `core/` and the core reads them in.
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
#   - it ships every module below. A phase-1 copy (0.1.x) has no lib/gh_config.sh
#     and still carries the pace half of grader_pool.sh, which now lives in the
#     core (src/lib/pace.sh); reading it would put week-old pace code over the
#     core's, so it is refused whole until it is upgraded.
#
# HOW IT LOADS. On a box with the plugin, `_devteam_init` (once per run, before
# main) defines one stub per function the plugin's files define, the same shape
# as the bundle's own autoload stubs. The first call to any of them reads all
# the files, in the order the core used to concatenate them, and re-runs the
# call. A run that never touches the dev-team tools (most heartbeat ticks, every
# `task ls`) pays one stat, one jq and one grep, and never parses them.
# Measured on poke-two, 10 runs of `task ls` each (DIVE-6938): main before this
# change ~600ms; no plugin ~405ms; plugin with these stubs ~485ms; plugin read
# eagerly at startup ~1200ms.
#
# A BOX WITHOUT THE PLUGIN defines none of these functions, and that IS the
# answer: every core call into them asks `devteam_loaded` or `declare -F` first
# and has its own no-plugin answer next to it. The verbs (`proof`, `gh`, `push`,
# `deploy`, `task deliver|reject|merge…`) print one line instead:
#   <verb> is in the devteam plugin: 5dive plugin install devteam
#
# FIVEDIVE_DEVTEAM=0 skips the plugin for one run (a way out if a bad plugin
# version ever ships to the fleet).

readonly DEVTEAM_PLUGIN_KEY="devteam@5dive-plugins"

# The modules, in the order the core used to concatenate them (gh_config was a
# core file, so it is read first). module -> its file under the plugin's core/,
# in _DEVTEAM_REL (a variable, not stdout: no subshell per lookup).
_DEVTEAM_REL=""
_devteam_module_file() {
  case "$1" in
    lib__gh_config)       _DEVTEAM_REL="lib/gh_config.sh" ;;
    task__gate_evidence)  _DEVTEAM_REL="task/gate_evidence.sh" ;;
    task__grader_pool)    _DEVTEAM_REL="task/grader_pool.sh" ;;
    task__grader_process) _DEVTEAM_REL="task/grader_process.sh" ;;
    task__delivery)       _DEVTEAM_REL="task/delivery.sh" ;;
    cmd_proof)            _DEVTEAM_REL="cmd_proof.sh" ;;
    cmd_push)             _DEVTEAM_REL="cmd_push.sh" ;;
    cmd_deploy)           _DEVTEAM_REL="cmd_deploy.sh" ;;
    cmd_gh)               _DEVTEAM_REL="cmd_gh.sh" ;;
    *) _DEVTEAM_REL=""; return 1 ;;
  esac
}
readonly DEVTEAM_MODULES="lib__gh_config task__gate_evidence task__grader_pool task__grader_process task__delivery cmd_proof cmd_push cmd_deploy cmd_gh"

# The core's lazy modules whose top-level names the plugin's files read
# (`_GRADER_FLOOR_*` and the meter's knobs from pace, `_GATE_ASK_MAX_WORDS` from
# need). The build cannot see the plugin, so it cannot compute this edge; the
# plugin's harness recomputes it against the core and fails if one is missing.
readonly DEVTEAM_CORE_DEPS="lib__pace task__need"

# The top-level verbs that live in the plugin, hidden root-only halves included.
# Reserved: no other plugin may claim one (cmd_plugin.sh), and the fallthrough
# in main() hands them to this file before any plugin verb is looked up — four
# of them are reached through NOPASSWD root grants, so "whichever plugin claims
# the name" would be root for any seat (DIVE-6934).
readonly DEVTEAM_VERBS="proof gh push deploy _gh_do _push_do _deploy_do _merge_do"

# <path>... -> rc 0 iff every one is owned by root or by us and nobody else can
# write it; _DEVTEAM_UNSAFE names the first that is not. One `stat` for all of
# them: on a loaded box each fork costs milliseconds, and this runs every time.
_DEVTEAM_UNSAFE=""
_devteam_path_safe() {
  _DEVTEAM_UNSAFE=""
  local line uid mode path n=0
  while IFS=' ' read -r uid mode path; do
    n=$((n + 1))
    # group and other write bits (mode is octal, e.g. 755 or 2775)
    if [[ "$uid" != 0 && "$uid" != "$EUID" ]] || (( (8#$mode & 8#022) != 0 )); then
      _DEVTEAM_UNSAFE="$path"; return 1
    fi
  done < <(stat -L -c '%u %a %n' -- "$@" 2>/dev/null)
  # A path stat could not read printed nothing: unreadable is not safe.
  (( n == $# )) || { _DEVTEAM_UNSAFE="${1}"; return 1; }
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
  local m rel f
  local -a paths=("$dir" "$dir/core")
  for m in $DEVTEAM_MODULES; do
    _devteam_module_file "$m"; rel="$_DEVTEAM_REL"
    f="$dir/core/$rel"
    if [[ ! -f "$f" ]]; then
      _DEVTEAM_WHY="it is older than this 5dive (no core/$rel). Upgrade it: sudo 5dive plugin upgrade $DEVTEAM_PLUGIN_KEY"
      return 1
    fi
    paths+=("$f")
    [[ "$rel" != */* ]] || paths+=("${f%/*}")
  done
  if ! _devteam_path_safe "${paths[@]}"; then
    _DEVTEAM_WHY="${_DEVTEAM_UNSAFE#"$dir/"} is writable by someone other than root. Reinstall: sudo 5dive plugin upgrade $DEVTEAM_PLUGIN_KEY"
    return 1
  fi
  _DEVTEAM_DIR="$dir"
}

_DEVTEAM_LOADED=0

# Once per run, before main: on a plugin box, one stub per plugin function.
# A plugin that defines a name the core already defines is refused whole: it
# adds the dev-team tools, it never replaces core code (phase 1's overlay did,
# and that is the drift DIVE-6935 had to fence with hashes). Its stubs are
# defined only once every name has passed.
_DEVTEAM_INIT_DONE=0
_devteam_init() {
  _DEVTEAM_LOADED=0; _DEVTEAM_INIT_DONE=1
  _devteam_resolve || return 0
  local -a files=() names=(); local -A seen=(); local m fn
  for m in $DEVTEAM_MODULES; do _devteam_module_file "$m"; files+=("$_DEVTEAM_DIR/core/$_DEVTEAM_REL"); done
  # `{` on the line, or cmd_proof's embedded python (`print()`) reads as a
  # definition and every run would carry a bash `print` stub.
  while IFS= read -r fn; do
    fn="${fn%%(*}"
    [[ -n "$fn" && -z "${seen[$fn]:-}" ]] || continue
    seen[$fn]=1
    if declare -F "$fn" >/dev/null 2>&1; then
      _DEVTEAM_WHY="it defines $fn(), which is a core function. Upgrade it: sudo 5dive plugin upgrade $DEVTEAM_PLUGIN_KEY"
      _DEVTEAM_DIR=""
      return 0
    fi
    names+=("$fn")
  done < <(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' "${files[@]}" 2>/dev/null)
  for fn in "${names[@]}"; do
    eval "${fn}(){ _devteam_load ${fn}; ${fn} \"\$@\"; }"
  done
}

# <function> — read every plugin file (and the core modules they read names
# from), then return so the stub re-runs the call. Runs inside a function, which
# is why the plugin's files, like the core's lazy modules, write `declare -gA`.
_devteam_load() {
  if (( _DEVTEAM_LOADED )); then
    printf '5dive: internal error: %s() is not defined by the devteam plugin it was indexed from.\n' "$1" >&2
    printf '  Reinstall it: sudo 5dive plugin upgrade %s\n' "$DEVTEAM_PLUGIN_KEY" >&2
    exit 70
  fi
  _DEVTEAM_LOADED=1
  if declare -F _load_module >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    _load_module $DEVTEAM_CORE_DEPS
  fi
  local __dt_m
  for __dt_m in $DEVTEAM_MODULES; do
    [[ -z "${FIVE_LAZY_TRACE:-}" ]] \
      || printf '5dive[lazy] devteam load %s\n' "$__dt_m" >&2
    # shellcheck source=/dev/null
    _devteam_module_file "$__dt_m"
    # shellcheck source=/dev/null
    source "$_DEVTEAM_DIR/core/$_DEVTEAM_REL"
  done
}

# Read the plugin's files now if it is here; rc 1 if it is not. For the few
# core readers of a plugin VALUE rather than a function (answer.sh's escalation
# options), which no stub can pull in.
devteam_require() {
  devteam_loaded || return 1
  (( _DEVTEAM_LOADED )) || [[ -z "$_DEVTEAM_DIR" ]] || _devteam_load devteam_require
  return 0
}

_devteam_is_verb() { [[ " $DEVTEAM_VERBS " == *" ${1:-} "* ]]; }

# main()'s fallthrough, before any plugin verb is looked up: run a devteam verb
# from the pinned plugin, or refuse with the line.
_devteam_verb() {  # <verb> [args...]
  local verb="$1"; shift
  devteam_loaded || devteam_refuse "$verb"
  case "$verb" in
    gh)
      # DIVE-2792: gh's own exit status (4 not logged in, 8 checks pending) is
      # the answer, so it is passed through explicitly.
      AUDIT_CMD="gh"; AUDIT_ARGS=("$@")
      cmd_gh "$@"; exit $? ;;
    push)
      # `push setup` (DIVE-1461) is the BYO-GitHub-App onboarding sub-verb —
      # intercepted before cmd_push so "setup" isn't parsed as a task id.
      if [[ "${1:-}" == "setup" ]]; then
        shift
        AUDIT_CMD="push setup"; AUDIT_ARGS=("$@")
        cmd_push_setup "$@"
      else
        AUDIT_CMD="push"; AUDIT_ARGS=("$@")
        cmd_push "$@"
      fi ;;
    deploy)
      AUDIT_CMD="deploy"; AUDIT_ARGS=("$@")
      cmd_deploy "$@" ;;
    proof)       cmd_proof "$@" ;;
    # The hidden root-only halves, each reached ONLY through its exact NOPASSWD
    # grant (render_standard_sudoers). Not audited themselves; the parent verb is.
    _merge_do)   cmd_task_merge_do; exit $? ;;
    _gh_do)      cmd_gh_do "$@"; exit $? ;;
    _deploy_do)  cmd_deploy_do "$@"; exit $? ;;
    _push_do)    cmd_push_do "$@"; exit $? ;;
  esac
}

# One line for `5dive doctor` (check name: devteam): where the dev-team tools
# come from on this box.
devteam_status_line() {
  (( _DEVTEAM_INIT_DONE )) || _devteam_init
  if [[ -n "$_DEVTEAM_DIR" ]]; then
    printf 'loaded from %s (%s modules)\n' \
      "$_DEVTEAM_DIR" "$(wc -w <<<"$DEVTEAM_MODULES" | tr -d ' ')"
  elif [[ "$_DEVTEAM_WHY" == "not installed" ]]; then
    printf 'not installed — this box has no dev-team tools (proof, gh, push, deploy, task deliver/merge)\n'
  else
    printf '%s — the dev-team tools are off on this box\n' "$_DEVTEAM_WHY"
  fi
}
