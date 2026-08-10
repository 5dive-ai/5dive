
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

# DIVE-2370: valid_skill_id and skill_target_within MOVED to src/lib/validation.sh.
# They are not skill-verb-local — five sibling id->path sites in cmd_pack.sh and
# lib/agent_setup.sh build the identical string, and one of them (_install_bundled_skill)
# `rm -rf`s the result. validation.sh is concatenated BEFORE agent_setup.sh and every
# cmd_*.sh in build.sh, so a single definition there is visible to all of them. The
# DIVE-2338 rationale travels WITH the functions rather than staying at this call site.

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

# _skill_read_result <result-file>
# Hydrate SKILL_RES_* from the JSON line an install heredoc left behind
# (DIVE-2282). Best-effort: a missing/garbage file just leaves the defaults, so
# a successful install is never downgraded to a failure over its own reporting.
_skill_read_result() {
  local f="$1"
  SKILL_RES_CHANGED="false"; SKILL_RES_CONTENT=""; SKILL_RES_RESOLVED=""; SKILL_RES_PREV=""
  if [[ -s "$f" ]]; then
    # `if .changed == true` (not `.changed // false`) so the value is always a
    # bare true/false literal — it's fed to jq as --argjson.
    SKILL_RES_CHANGED=$(jq -r 'if .changed == true then "true" else "false" end' "$f" 2>/dev/null || echo "false")
    SKILL_RES_CONTENT=$(jq -r '.content_sha256 // empty' "$f" 2>/dev/null || true)
    SKILL_RES_RESOLVED=$(jq -r '.resolved_sha // empty' "$f" 2>/dev/null || true)
    SKILL_RES_PREV=$(jq -r '.previous_content_sha256 // empty' "$f" 2>/dev/null || true)
  fi
  [[ "$SKILL_RES_CHANGED" == "true" ]] || SKILL_RES_CHANGED="false"
  rm -f "$f"
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
  #
  # DIVE-2218: the old `|| echo "admin"` spelled a read failure as a real tier.
  # Every test below is `== "sandboxed"`, so the POLARITY it produced was already
  # the safe one and is kept: an unmeasured agent takes the non-sandboxed strategy
  # and the install runs as the agent user. Guessing the other way would run a
  # freshly-cloned repo's install as ROOT for an agent that may not be sandboxed --
  # a functional failure is the correct thing to degrade to, an escalation is not.
  # What changes is that the hole is no longer NAMED like a measurement: the value
  # stays `unknown:*` so nothing downstream can read it as a tier, the registry
  # gets a chance to answer first, and the guess is announced instead of silent.
  local isolation isolation_pair isolation_src
  isolation_pair="$(agent_isolation_2src "$name")"
  isolation="${isolation_pair%%$'\t'*}"; isolation_src="${isolation_pair#*$'\t'}"
  if [[ "$isolation" == unknown:* ]]; then
    warn "agent '$name': isolation not measured ($isolation_src) — using the non-sandboxed install strategy; if this agent IS sandboxed the install will fail rather than silently run as root"
  elif [[ "$isolation_src" == env:disagrees-registry:* ]]; then
    warn "agent '$name': isolation disagrees across sources ($isolation_src) — using the env file's value"
  fi

  # Channel for the install heredoc to hand its manifest numbers back to us:
  # heredoc stdout is mirrored to stderr for humans, so the machine-readable
  # result travels through a temp file instead (DIVE-2282). Owned by the agent
  # user because the admin strategy runs the heredoc as that user.
  local result_file
  result_file=$(mktemp -t skill-result-XXXXXX)
  chown "$user" "$result_file" 2>/dev/null || true

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
    if ! $run_as env HOME="$home" SOURCE="$source" SKILL="$skill" INSTALL_DIR="$install_dir" RESULT_FILE="$result_file" bash -s >&2 <<'SKILL_ADD_MANUAL'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
cd "$HOME"
TMPDIR=$(mktemp -d -t skill-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
timeout 60 git clone --depth=1 "https://github.com/$SOURCE.git" "$TMPDIR/repo" >/dev/null 2>&1
# Read the commit off the clone while it's still around — the EXIT trap only
# fires when this shell ends, but the manifest write below wants the sha.
RESOLVED_SHA=$(/usr/bin/git -C "$TMPDIR/repo" rev-parse HEAD 2>/dev/null || echo "")
SRC_DIR=""
for d in "$TMPDIR/repo/$SKILL" "$TMPDIR/repo/skills/$SKILL"; do
  if [ -f "$d/SKILL.md" ]; then SRC_DIR="$d"; break; fi
done
[ -n "$SRC_DIR" ] || { echo "ERROR: skill '$SKILL' not found in $SOURCE (looked at top-level and skills/)" >&2; exit 1; }
mkdir -p "$HOME/$INSTALL_DIR"
rm -rf "$HOME/$INSTALL_DIR/$SKILL"
cp -r "$SRC_DIR" "$HOME/$INSTALL_DIR/$SKILL"
[ -d "$HOME/$INSTALL_DIR/$SKILL" ] || { echo "ERROR: $INSTALL_DIR/$SKILL missing after install" >&2; exit 1; }
# DIVE-2282 manifest write. Absolute tool paths: the agent's PATH is whatever
# its login shell/nvm left behind, and this must not depend on that.
MANIFEST="$HOME/$INSTALL_DIR/.skills-manifest.json"
if ! /usr/bin/jq -e . "$MANIFEST" >/dev/null 2>&1; then echo '{}' > "$MANIFEST" 2>/dev/null || true; fi
PREV_SHA=$(/usr/bin/jq -r --arg k "$SKILL" '.[$k].content_sha256 // ""' "$MANIFEST" 2>/dev/null || echo "")
# Relative paths + sorted list => same tree hashes the same anywhere.
CONTENT_SHA=$(cd "$HOME/$INSTALL_DIR/$SKILL" && find . -type f -print0 | sort -z | xargs -0 -r /usr/bin/sha256sum | /usr/bin/sha256sum | cut -d' ' -f1) || CONTENT_SHA=""
CHANGED=false
if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "$CONTENT_SHA" ]; then CHANGED=true; fi
if /usr/bin/jq --arg k "$SKILL" --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
     --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.[$k] = {source:$s, resolved_sha:$r, content_sha256:$c, installed_at:$t}' \
     "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null; then
  mv "$MANIFEST.tmp" "$MANIFEST"
else
  rm -f "$MANIFEST.tmp"
  echo "warn: could not update $MANIFEST for $SKILL" >&2
fi
[ -n "${RESULT_FILE:-}" ] && /usr/bin/jq -cn --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
  --arg p "$PREV_SHA" --argjson ch "$CHANGED" \
  '{source:$s, resolved_sha:$r, content_sha256:$c, previous_content_sha256:$p, changed:$ch}' \
  > "$RESULT_FILE" 2>/dev/null || true
echo "manual-installed $SKILL → $HOME/$INSTALL_DIR/$SKILL"
SKILL_ADD_MANUAL
    then
      rm -f "$result_file"
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
    [[ "$isolation" == "sandboxed" ]] && chown -R "${user}:${user}" "$home/$install_dir/$skill" "$home/$install_dir/.skills-manifest.json" 2>/dev/null || true
    _skill_read_result "$result_file"
    ok "skill '$skill' installed for agent '$name'." \
       '{name:$n, source:$s, skill:$k, agent:$a, action:"add", strategy:"manual", changed:$ch, content_sha256:$cs, previous_content_sha256:$ps, resolved_sha:$rs}' \
       --arg n "$name" --arg s "$source" --arg k "$skill" --arg a "$agent_id" \
       --argjson ch "$SKILL_RES_CHANGED" --arg cs "$SKILL_RES_CONTENT" \
       --arg ps "$SKILL_RES_PREV" --arg rs "$SKILL_RES_RESOLVED"
    return 0
  fi

  if [[ "$isolation" == "sandboxed" ]]; then
    if ! HOME="$home" \
         SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" FORCE="$force" \
         RESULT_FILE="$result_file" \
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
# DIVE-2282 manifest write. No local clone on the npx path, so the commit is
# best-effort over the network; an empty sha never fails the install. Absolute
# tool paths so this doesn't depend on what nvm put on PATH.
RESOLVED_SHA=$(timeout 20 /usr/bin/git ls-remote "https://github.com/$SOURCE.git" HEAD 2>/dev/null | cut -f1 || echo "")
MANIFEST="$HOME/$INSTALL_DIR/.skills-manifest.json"
if ! /usr/bin/jq -e . "$MANIFEST" >/dev/null 2>&1; then echo '{}' > "$MANIFEST" 2>/dev/null || true; fi
PREV_SHA=$(/usr/bin/jq -r --arg k "$SKILL" '.[$k].content_sha256 // ""' "$MANIFEST" 2>/dev/null || echo "")
# Relative paths + sorted list => same tree hashes the same anywhere.
CONTENT_SHA=$(cd "$HOME/$INSTALL_DIR/$SKILL" && find . -type f -print0 | sort -z | xargs -0 -r /usr/bin/sha256sum | /usr/bin/sha256sum | cut -d' ' -f1) || CONTENT_SHA=""
CHANGED=false
if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "$CONTENT_SHA" ]; then CHANGED=true; fi
if /usr/bin/jq --arg k "$SKILL" --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
     --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.[$k] = {source:$s, resolved_sha:$r, content_sha256:$c, installed_at:$t}' \
     "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null; then
  mv "$MANIFEST.tmp" "$MANIFEST"
else
  rm -f "$MANIFEST.tmp"
  echo "warn: could not update $MANIFEST for $SKILL" >&2
fi
[ -n "${RESULT_FILE:-}" ] && /usr/bin/jq -cn --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
  --arg p "$PREV_SHA" --argjson ch "$CHANGED" \
  '{source:$s, resolved_sha:$r, content_sha256:$c, previous_content_sha256:$p, changed:$ch}' \
  > "$RESULT_FILE" 2>/dev/null || true
SKILL_ADD_SANDBOXED
    then
      rm -f "$result_file"
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
    chown -R "${user}:${user}" "$home/$install_dir/$skill" "$home/$install_dir/.skills-manifest.json" 2>/dev/null || true
  else
    if ! sudo -u "$user" -H env SOURCE="$source" SKILL="$skill" AGENT_ID="$agent_id" INSTALL_DIR="$install_dir" FORCE="$force" RESULT_FILE="$result_file" bash -s >&2 <<'SKILL_ADD'
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
# DIVE-2282 manifest write. No local clone on the npx path, so the commit is
# best-effort over the network; an empty sha never fails the install. Absolute
# tool paths so this doesn't depend on what nvm put on PATH.
RESOLVED_SHA=$(timeout 20 /usr/bin/git ls-remote "https://github.com/$SOURCE.git" HEAD 2>/dev/null | cut -f1 || echo "")
# >>> DIVE-2282 skill manifest block (extracted verbatim by tests/skill_manifest_unit.sh)
MANIFEST="$HOME/$INSTALL_DIR/.skills-manifest.json"
if ! /usr/bin/jq -e . "$MANIFEST" >/dev/null 2>&1; then echo '{}' > "$MANIFEST" 2>/dev/null || true; fi
PREV_SHA=$(/usr/bin/jq -r --arg k "$SKILL" '.[$k].content_sha256 // ""' "$MANIFEST" 2>/dev/null || echo "")
# Relative paths + sorted list => same tree hashes the same anywhere.
CONTENT_SHA=$(cd "$HOME/$INSTALL_DIR/$SKILL" && find . -type f -print0 | sort -z | xargs -0 -r /usr/bin/sha256sum | /usr/bin/sha256sum | cut -d' ' -f1) || CONTENT_SHA=""
CHANGED=false
if [ -n "$PREV_SHA" ] && [ "$PREV_SHA" != "$CONTENT_SHA" ]; then CHANGED=true; fi
if /usr/bin/jq --arg k "$SKILL" --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
     --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.[$k] = {source:$s, resolved_sha:$r, content_sha256:$c, installed_at:$t}' \
     "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null; then
  mv "$MANIFEST.tmp" "$MANIFEST"
else
  rm -f "$MANIFEST.tmp"
  echo "warn: could not update $MANIFEST for $SKILL" >&2
fi
[ -n "${RESULT_FILE:-}" ] && /usr/bin/jq -cn --arg s "$SOURCE" --arg r "$RESOLVED_SHA" --arg c "$CONTENT_SHA" \
  --arg p "$PREV_SHA" --argjson ch "$CHANGED" \
  '{source:$s, resolved_sha:$r, content_sha256:$c, previous_content_sha256:$p, changed:$ch}' \
  > "$RESULT_FILE" 2>/dev/null || true
# <<< DIVE-2282 skill manifest block
SKILL_ADD
    then
      rm -f "$result_file"
      fail "$E_GENERIC" "skill install failed for '$skill' on agent '$name'"
    fi
  fi

  _skill_read_result "$result_file"
  ok "skill '$skill' installed for agent '$name'." \
     '{name:$n, source:$s, skill:$k, agent:$a, action:"add", changed:$ch, content_sha256:$cs, previous_content_sha256:$ps, resolved_sha:$rs}' \
     --arg n "$name" --arg s "$source" --arg k "$skill" --arg a "$agent_id" \
     --argjson ch "$SKILL_RES_CHANGED" --arg cs "$SKILL_RES_CONTENT" \
     --arg ps "$SKILL_RES_PREV" --arg rs "$SKILL_RES_RESOLVED"
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

  # DIVE-2338: assert the CONCATENATED path stays inside the install dir. The name check
  # above is exact but is a refusal of two tokens; this is the structural one, and it is
  # what still holds if someone widens the regex later.
  skill_target_within "$home/$install_dir" "$skill" \
    || fail "$E_VALIDATION" "skill id '$skill' escapes the skills directory — refusing (DIVE-2338)"

  step "Removing skill '$skill' from agent '$name'"
  # `npx skills remove` is interactive without a flag; fall straight to
  # rm -rf since the skill is just a directory under the per-type skills dir.
  # DIVE-2338: ship the REAL predicate into the heredoc rather than re-implementing it.
  # `declare -f` emits skill_target_within's own source as of this run, so there is exactly
  # ONE implementation and drift is impossible by construction instead of by discipline.
  # It also fixes the mutation table: reverting the function now reds the caller arm AND
  # the heredoc arm together, which is the coupling we want — the two sites are one control
  # applied twice, not two independent belts. (dev, review of PR #311.)
  if ! sudo -u "$user" -H env SKILL="$skill" INSTALL_DIR="$install_dir" \
       CONTAINMENT_FN="$(declare -f skill_target_within)" bash -s >&2 <<'SKILL_REMOVE'
set -euo pipefail
unset CLAUDE_CONFIG_DIR
cd "$HOME"
target="$INSTALL_DIR/$SKILL"
# DIVE-2338: re-assert containment HERE, where the rm -rf actually happens — a guard that
# lives only in the caller protects every path except the one doing the deleting. The
# predicate is not re-implemented: $CONTAINMENT_FN carries the caller's own
# skill_target_within source, so this is the SAME function, not a copy of it.
eval "${CONTAINMENT_FN:?containment predicate not supplied — refusing to delete}"
skill_target_within "$INSTALL_DIR" "$SKILL" \
  || { echo "refusing: '$SKILL' resolves outside $INSTALL_DIR ($(readlink -m -- "$target"))" >&2; exit 3; }
if [ -e "$target" ] || [ -L "$target" ]; then
  rm -rf "$target"
  # Drop the skill's manifest entry too, so the record can't outlive the dir
  # it describes (DIVE-2282). Best-effort: never fails the removal.
  MANIFEST="$INSTALL_DIR/.skills-manifest.json"
  if [ -f "$MANIFEST" ]; then
    /usr/bin/jq --arg k "$SKILL" 'del(.[$k])' "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null \
      && mv "$MANIFEST.tmp" "$MANIFEST" || rm -f "$MANIFEST.tmp"
  fi
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
