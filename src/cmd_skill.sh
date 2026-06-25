
# -------- skills (per-agent, via npx skills, type-aware) --------
#
# Each agent user has its own per-type skills dir (.claude/skills for claude,
# .hermes/skills for hermes, .agents/skills for codex/opencode, plain
# ./skills for openclaw). `npx skills add` with `--agent <id>` lands the skill
# in the right place — see SKILLS_AGENT_ID / SKILLS_INSTALL_DIR at the top of
# this file. The dashboard's Skills block calls these subcommands through
# /agents/exec so install/list/remove all flow through the same auditable
# path as the rest of agent management.

# Validate `<owner>/<repo>` for skill source. The github URL passed to
# `npx skills add` is built from this; constraining the regex keeps the
# command line free of shell metacharacters even before bash quoting.
valid_skill_source() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

# Bare skill ids in --with-skills default to the 5dive skills repo (e.g.
# `5dive-cli` → `<org>/skills:5dive-cli`, org resolved by gh_org). Keeps the
# common path short while leaving the door open for third-party skill repos.

# parse_skill_spec <spec> -> "<source> <skill>"
# Accepts either bare `<id>` (defaults to the skills repo) or `<owner/repo>:<id>`.
# Caller splits the result on space.
parse_skill_spec() {
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    printf '%s %s\n' "${spec%%:*}" "${spec#*:}"
  else
    printf '%s %s\n' "$(gh_org)/skills" "$spec"
  fi
}

# Validate skill id (the directory name that will end up under the per-type
# skills dir, e.g. .claude/skills/<id>). Same character class skills.sh uses.
valid_skill_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# cmd_skill <agent-name>|--all <action> [args...]
# Dispatcher mirrors the auth subcommand shape so main()'s case stays flat.
#
# `--all list` is a bulk variant: it lists installed skills for EVERY agent
# in the registry in a single invocation, looping serially. The dashboard
# uses it instead of firing one exec per agent — the per-agent fan-out
# spawned N concurrent sudo+npx processes and saturated swap-bound boxes.
cmd_skill() {
  local name="${1:-}"
  [[ -n "$name" ]] \
    || fail "$E_USAGE" "usage: 5dive agent skill <name>|--all add|list|rm [...]"
  shift
  # --all only supports `list` (bulk read); add/rm stay per-agent so the
  # blast radius of a mutation is always a single named agent.
  if [[ "$name" == "--all" ]]; then
    local action="${1:-list}"
    [[ "$action" == "list" ]] \
      || fail "$E_USAGE" "--all only supports 'list' (got '$action')"
    cmd_skill_list_all
    return
  fi
  require_agent "$name"
  local action="${1:-}"
  [[ -n "$action" ]] \
    || fail "$E_USAGE" "usage: 5dive agent skill $name add|list|rm [...]"
  shift
  case "$action" in
    add)       cmd_skill_add  "$name" "$@" ;;
    list)      cmd_skill_list "$name" "$@" ;;
    rm|remove) cmd_skill_rm   "$name" "$@" ;;
    *) fail "$E_USAGE" "unknown skill action: $action (use add | list | rm)" ;;
  esac
}

cmd_skill_add() {
  local name="$1"; shift
  local source="" skill="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source=*) source="${1#--source=}" ;;
      --skill=*)  skill="${1#--skill=}" ;;
      --force)    force=1 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  [[ -n "$source" && -n "$skill" ]] \
    || fail "$E_USAGE" "usage: 5dive agent skill $name add --source=<owner/repo> --skill=<id> [--force]"
  valid_skill_source "$source" \
    || fail "$E_VALIDATION" "invalid source: '$source' (expected owner/repo)"
  valid_skill_id "$skill" \
    || fail "$E_VALIDATION" "invalid skill id: '$skill'"

  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  local type agent_id install_dir
  type=$(agent_type "$name")
  [[ -n "$type" ]] || fail "$E_NOT_FOUND" "agent '$name' has no type recorded in registry"
  agent_id="${SKILLS_AGENT_ID[$type]:-claude-code}"
  install_dir="${SKILLS_INSTALL_DIR[$type]:-.claude/skills}"

  # Determine isolation so we can choose the right install strategy.
  local isolation
  isolation=$(grep -oP '(?<=AGENT_ISOLATION=)\S+' "${ENV_DIR}/${name}.env" 2>/dev/null || echo "admin")

  step "Installing skill '$skill' from '$source' for agent '$name' (--agent $agent_id)"
  # Same pattern as install_channel_plugin_for_agent: non-login shell,
  # CLAUDE_CONFIG_DIR unset so $HOME is the install target root, nvm
  # sourced manually so npx is on PATH. Output mirrored to stderr only.
  #
  # Sandboxed agents are not in the claude group, so /home/claude/ is
  # inaccessible to them and the claude binary can't be found on PATH.
  # For those agents we run the install as root (which has full access)
  # with HOME overridden to the agent's own home, then re-own the result.
  #
  # Manual-install types (grok today, see _skill_needs_manual_install in
  # lib/agent_setup.sh): upstream `npx skills add` rejects --agent grok with
  # "Invalid agents: grok", so we git-clone + cp -r the skill dir directly
  # into $HOME/$INSTALL_DIR. Bypasses the sandboxed branch too — git is
  # available everywhere npm/npx is.
  if _skill_needs_manual_install "$type"; then
    local run_as="sudo -u $user -H"
    [[ "$isolation" == "sandboxed" ]] && run_as=""
    if ! $run_as env HOME="$home" SOURCE="$source" SKILL="$skill" INSTALL_DIR="$install_dir" bash -s >&2 <<'SKILL_ADD_MANUAL'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
cd "$HOME"
TMPDIR=$(mktemp -d -t skill-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
timeout 60 git clone --depth=1 "https://github.com/$SOURCE.git" "$TMPDIR/repo" >/dev/null 2>&1
SRC_DIR=""
for d in "$TMPDIR/repo/$SKILL" "$TMPDIR/repo/skills/$SKILL"; do
  if [ -f "$d/SKILL.md" ]; then SRC_DIR="$d"; break; fi
done
[ -n "$SRC_DIR" ] || { echo "ERROR: skill '$SKILL' not found in $SOURCE (looked at top-level and skills/)" >&2; exit 1; }
mkdir -p "$HOME/$INSTALL_DIR"
rm -rf "$HOME/$INSTALL_DIR/$SKILL"
cp -r "$SRC_DIR" "$HOME/$INSTALL_DIR/$SKILL"
[ -d "$HOME/$INSTALL_DIR/$SKILL" ] || { echo "ERROR: $INSTALL_DIR/$SKILL missing after install" >&2; exit 1; }
echo "manual-installed $SKILL → $HOME/$INSTALL_DIR/$SKILL"
SKILL_ADD_MANUAL
    then
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
    [[ "$isolation" == "sandboxed" ]] && chown -R "${user}:${user}" "$home/$install_dir/$skill" 2>/dev/null || true
    ok "skill '$skill' installed for agent '$name'." \
       '{name:$n, source:$s, skill:$k, agent:$a, action:"add", strategy:"manual"}' \
       --arg n "$name" --arg s "$source" --arg k "$skill" --arg a "$agent_id"
    return 0
  fi

  if [[ "$isolation" == "sandboxed" ]]; then
    if ! HOME="$home" \
         SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" FORCE="$force" \
         bash -s >&2 <<'SKILL_ADD_SANDBOXED'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
# --force: drop the existing copy so a pinned/managed skill actually upgrades
# rather than npx no-op'ing on an already-present dir (DIVE-698).
[ "${FORCE:-0}" = 1 ] && rm -rf "$INSTALL_DIR/$SKILL"
timeout 180 npx -y skills add "https://github.com/$SOURCE" --skill "$SKILL" --agent "$AGENT_ID" --yes 2>&1 | tail -25
[ -d "$INSTALL_DIR/$SKILL" ] || { echo "ERROR: $INSTALL_DIR/$SKILL missing after install" >&2; exit 1; }
SKILL_ADD_SANDBOXED
    then
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
    chown -R "${user}:${user}" "$home/$install_dir/$skill" 2>/dev/null || true
  else
    if ! sudo -u "$user" -H env SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" FORCE="$force" bash -s >&2 <<'SKILL_ADD'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
# --force: drop the existing copy so a pinned/managed skill actually upgrades
# rather than npx no-op'ing on an already-present dir (DIVE-698).
[ "${FORCE:-0}" = 1 ] && rm -rf "$INSTALL_DIR/$SKILL"
timeout 180 npx -y skills add "https://github.com/$SOURCE" --skill "$SKILL" --agent "$AGENT_ID" --yes 2>&1 | tail -25
[ -d "$INSTALL_DIR/$SKILL" ] || { echo "ERROR: $INSTALL_DIR/$SKILL missing after install" >&2; exit 1; }
SKILL_ADD
    then
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
  fi

  ok "skill '$skill' installed for agent '$name'." \
     '{name:$n, source:$s, skill:$k, agent:$a, action:"add"}' \
     --arg n "$name" --arg s "$source" --arg k "$skill" --arg a "$agent_id"
}

# _skill_list_json <name> -> prints the installed-skills JSON array for one
# agent (always valid JSON, "[]" on any failure). Shared by the single-agent
# `list` and the bulk `--all list` so both paths derive the list identically.
_skill_list_json() {
  local name="$1"
  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] && id -u "$user" &>/dev/null || { echo "[]"; return; }

  local type agent_id install_dir
  type=$(agent_type "$name")
  agent_id="${SKILLS_AGENT_ID[$type]:-claude-code}"
  install_dir="${SKILLS_INSTALL_DIR[$type]:-.claude/skills}"

  # `npx skills list --json` prints clean JSON when available. If the
  # skills CLI isn't reachable (no network, npx cache cold) we fall back
  # to a directory scan so the dashboard always has a list to render.
  local out
  out=$(sudo -u "$user" -H bash -s 2>/dev/null <<'SKILL_LIST' || true
set -uo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
timeout 30 npx -y skills list --json 2>/dev/null
SKILL_LIST
)
  local list
  list=$(jq -c '.' <<<"$out" 2>/dev/null || true)
  if [[ -z "$list" ]]; then
    # Fallback: enumerate the per-type skills dir in the agent home. Marks
    # each entry with the agent_id we'd pass to `skills add` so callers can
    # tell which CLI a skill is bound to without re-deriving the type.
    list=$(sudo -u "$user" env INSTALL_DIR="$install_dir" AGENT_ID="$agent_id" bash -c '
      shopt -s nullglob
      out="[]"
      for d in "$HOME"/"$INSTALL_DIR"/*/; do
        n=$(basename "$d")
        out=$(jq -c --arg n "$n" --arg p "$d" --arg a "$AGENT_ID" \
          ". + [{name:\$n, path:\$p, scope:\"project\", agents:[\$a]}]" <<<"$out")
      done
      echo "$out"
    ' 2>/dev/null || echo "[]")
  fi
  printf '%s' "${list:-[]}"
}

cmd_skill_list() {
  local name="$1"; shift
  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  local list
  list=$(_skill_list_json "$name")

  if (( JSON_MODE )); then
    jq -cn --argjson list "$list" --arg n "$name" \
      '{ok:true, data:{name:$n, skills:$list}}'
  else
    if [[ "$list" == "[]" || -z "$list" ]]; then
      echo "no skills installed for '$name'"
    else
      jq -r '.[] | [.name, (.path // "-")] | @tsv' <<<"$list" | column -t -s $'\t'
    fi
  fi
}

# cmd_skill_list_all — installed skills for every registry agent, looped
# serially. Replaces the dashboard's per-agent exec fan-out (one concurrent
# sudo+npx per agent saturated swap-bound boxes → shelld timeout → 502).
# Best-effort per agent: a failure yields an empty list, never aborts the loop.
cmd_skill_list_all() {
  local reg names
  reg=$(registry_read 2>/dev/null || echo '{}')
  names=$(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null || true)

  # Build the {name: [skills]} object incrementally so one slow/failed agent
  # never discards the others already collected.
  local agents_json="{}" name list
  for name in $names; do
    list=$(_skill_list_json "$name")
    agents_json=$(jq -c --arg n "$name" --argjson l "${list:-[]}" \
      '.[$n] = $l' <<<"$agents_json" 2>/dev/null || printf '%s' "$agents_json")
  done

  if (( JSON_MODE )); then
    jq -cn --argjson agents "$agents_json" '{ok:true, data:{agents:$agents}}'
  else
    local n
    for n in $(jq -r 'keys[]' <<<"$agents_json"); do
      local count
      count=$(jq -r --arg n "$n" '.[$n] | length' <<<"$agents_json")
      printf '%s\t%s skill(s)\n' "$n" "$count"
    done | column -t -s $'\t'
  fi
}

cmd_skill_rm() {
  local name="$1"; shift
  local skill=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skill=*) skill="${1#--skill=}" ;;
      *) [[ -z "$skill" ]] && skill="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$skill" ]] || fail "$E_USAGE" "usage: 5dive agent skill $name rm <skill_id>"
  valid_skill_id "$skill" || fail "$E_VALIDATION" "invalid skill id: '$skill'"

  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  local type install_dir
  type=$(agent_type "$name")
  install_dir="${SKILLS_INSTALL_DIR[$type]:-.claude/skills}"

  step "Removing skill '$skill' from agent '$name'"
  # `npx skills remove` is interactive without a flag; fall straight to
  # rm -rf since the skill is just a directory under the per-type skills dir.
  if ! sudo -u "$user" -H env SKILL="$skill" INSTALL_DIR="$install_dir" bash -s >&2 <<'SKILL_REMOVE'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
cd "$HOME"
target="$INSTALL_DIR/$SKILL"
if [ -e "$target" ] || [ -L "$target" ]; then
  rm -rf "$target"
  echo "Removed $target"
else
  echo "Skill not found: $target" >&2
  exit 4
fi
SKILL_REMOVE
  then
    fail "$E_NOT_FOUND" "skill '$skill' not installed on agent '$name'"
  fi

  ok "skill '$skill' removed for agent '$name'." \
     '{name:$n, skill:$k, action:"rm"}' \
     --arg n "$name" --arg k "$skill"
}
