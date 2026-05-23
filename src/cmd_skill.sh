
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

# Default GitHub source applied to bare skill ids in --with-skills (e.g.
# `5dive-cli` → `5dive-com/skills:5dive-cli`). Keeps the common path short
# while leaving the door open for third-party skill repos.
DEFAULT_SKILL_SOURCE="5dive-com/skills"

# parse_skill_spec <spec> -> "<source> <skill>"
# Accepts either bare `<id>` (uses DEFAULT_SKILL_SOURCE) or `<owner/repo>:<id>`.
# Caller splits the result on space.
parse_skill_spec() {
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    printf '%s %s\n' "${spec%%:*}" "${spec#*:}"
  else
    printf '%s %s\n' "$DEFAULT_SKILL_SOURCE" "$spec"
  fi
}

# Validate skill id (the directory name that will end up under the per-type
# skills dir, e.g. .claude/skills/<id>). Same character class skills.sh uses.
valid_skill_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# cmd_skill <agent-name> <action> [args...]
# Dispatcher mirrors the auth subcommand shape so main()'s case stays flat.
cmd_skill() {
  local name="${1:-}"
  [[ -n "$name" ]] \
    || fail "$E_USAGE" "usage: 5dive agent skill <name> add|list|rm [...]"
  shift
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
  local source="" skill=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source=*) source="${1#--source=}" ;;
      --skill=*)  skill="${1#--skill=}" ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  [[ -n "$source" && -n "$skill" ]] \
    || fail "$E_USAGE" "usage: 5dive agent skill $name add --source=<owner/repo> --skill=<id>"
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
  if [[ "$isolation" == "sandboxed" ]]; then
    if ! HOME="$home" \
         SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" \
         bash -s >&2 <<'SKILL_ADD_SANDBOXED'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
timeout 180 npx -y skills add "https://github.com/$SOURCE" --skill "$SKILL" --agent "$AGENT_ID" --yes 2>&1 | tail -25
[ -d "$INSTALL_DIR/$SKILL" ] || { echo "ERROR: $INSTALL_DIR/$SKILL missing after install" >&2; exit 1; }
SKILL_ADD_SANDBOXED
    then
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
    chown -R "${user}:${user}" "$home/$install_dir/$skill" 2>/dev/null || true
  else
    if ! sudo -u "$user" -H env SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" bash -s >&2 <<'SKILL_ADD'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
export NVM_DIR="/home/claude/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/home/claude/.local/bin:$PATH"
cd "$HOME"
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

cmd_skill_list() {
  local name="$1"; shift
  local user="agent-${name}" home="/home/agent-${name}"
  [[ -d "$home" ]] || fail "$E_GENERIC" "agent home missing: $home"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

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
