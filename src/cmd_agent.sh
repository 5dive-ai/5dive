
# -------- agent CRUD --------

cmd_list() {
  # DIVE-1074: rootless read (mirrors account list / DIVE-1035). `agent list` is
  # pure-read, and a standard-isolation agent (group claude, so it can read the
  # registry) needs it to DISCOVER peers before it can send/ask them. ensure_state_ro
  # skips require_root when the registry already exists.
  ensure_state_ro
  local reg
  reg=$(registry_read)
  # Enrich with live systemd state.
  local out
  out=$(echo "$reg" | jq -c '.agents')
  local enriched="{}"
  # DIVE-352: collapse the per-agent systemd probe — was 2 systemctl spawns per
  # agent (is-active + is-enabled), i.e. 2N process spawns per `agent list`, which
  # the dashboard polls every 30s — into ONE `systemctl show` over every unit.
  # Keeps `agent list` a single cheap shell-out at any fleet size. Missing units
  # fall through to the "// unknown" default in the merge below.
  local -A _active_map=() _enabled_map=()
  local _svc_args=() _an
  for _an in $(echo "$out" | jq -r 'keys[]' 2>/dev/null); do
    _svc_args+=("5dive-agent@${_an}.service")
  done
  if (( ${#_svc_args[@]} )); then
    local _show _line _id="" _as="" _ufs="" _n
    _show=$(systemctl show --property=Id,ActiveState,UnitFileState --no-page "${_svc_args[@]}" 2>/dev/null || true)
    while IFS= read -r _line; do
      case "$_line" in
        Id=*)            _id="${_line#Id=}" ;;
        ActiveState=*)   _as="${_line#ActiveState=}" ;;
        UnitFileState=*) _ufs="${_line#UnitFileState=}" ;;
        "")              if [[ "$_id" == 5dive-agent@*.service ]]; then
                           _n="${_id#5dive-agent@}"; _n="${_n%.service}"
                           _active_map["$_n"]="$_as"; _enabled_map["$_n"]="$_ufs"
                         fi
                         _id=""; _as=""; _ufs="" ;;
      esac
    done <<< "$_show"
    # systemctl show emits no trailing blank line, so flush the final block.
    if [[ "$_id" == 5dive-agent@*.service ]]; then
      _n="${_id#5dive-agent@}"; _n="${_n%.service}"
      _active_map["$_n"]="$_as"; _enabled_map["$_n"]="$_ufs"
    fi
  fi
  for name in $(echo "$out" | jq -r 'keys[]' 2>/dev/null); do
    local svc="5dive-agent@${name}"
    local active sub
    active="${_active_map[$name]:-unknown}"
    sub="${_enabled_map[$name]:-unknown}"
    # Surface bot-to-bot status (DIVE-161) so the dashboard can flag which agents
    # can message bots outside the team — without N per-agent access fetches.
    # It lives in the agent's access.json, not the registry; read it here (root).
    local b2b="false" ltype lchan lsd
    ltype=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    lchan=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
    if [[ "$lchan" == "telegram" ]]; then
      lsd=$(_tg_access_state_dir "agent-${name}" "$ltype" 2>/dev/null || echo "")
      if [[ -n "$lsd" && -f "$lsd/access.json" ]]; then
        b2b=$(jq -r '.botToBot.enabled // false' "$lsd/access.json" 2>/dev/null || echo "false")
      fi
    fi
    # Surface the configured model + reasoning effort (DIVE-211) so the dashboard
    # can render a per-row model badge + picker without an N×`agent info` fan-out.
    # Same best-effort reads `info` uses; empty -> null (model unset / non-claude
    # effort). Two extra per-agent file reads, in line with the systemctl + b2b
    # reads this loop already does.
    local amodel aeffort
    # `|| true`: belt-and-suspenders with the resolvers' own exit-0 contract so a
    # best-effort per-agent config read can never abort the whole list under
    # `set -e` (DIVE-230).
    amodel=$(resolve_agent_model "$ltype" "$name" || true)
    aeffort=$(resolve_agent_effort "$ltype" "$name" || true)
    enriched=$(jq -c --arg n "$name" --arg a "$active" --arg e "$sub" --argjson b2b "$b2b" \
      --arg model "$amodel" --arg effort "$aeffort" \
      '.[$n] = {active: $a, enabled: $e, botToBotEnabled: $b2b,
                model: (if $model == "" then null else $model end),
                effort: (if $effort == "" then null else $effort end)}' <<<"$enriched")
  done
  local merged
  merged=$(jq -c --arg default_wd "$DEFAULT_WORKDIR" --argjson live "$enriched" '.agents | to_entries | map({
    name: .key,
    type: .value.type,
    channels: .value.channels,
    workdir: (.value.workdir // $default_wd),
    authProfile: (.value.authProfile // null),
    botUsername: (.value.botUsername // null),
    isolation: (.value.isolation // "admin"),
    heartbeat: (.value.heartbeat // null),
    createdAt: .value.createdAt,
    active: ($live[.key].active // "unknown"),
    enabled: ($live[.key].enabled // "unknown"),
    botToBotEnabled: ($live[.key].botToBotEnabled // false),
    model: ($live[.key].model // null),
    effort: ($live[.key].effort // null)
  })' <<<"$reg")
  if (( JSON_MODE )); then
    echo "$merged" | jq -c '{ok:true, data: .}'
  else
    echo "$merged" | jq -r '
      if length == 0 then "no agents" else
        (["NAME","TYPE","CHANNELS","PROFILE","ACTIVE","ENABLED"] | @tsv),
        (.[] | [(.name + (if (.heartbeat.enabled // false) then " ∿" + ((.heartbeat.everyMin // 30)|tostring) + "m" else "" end)), .type, .channels, (.authProfile // "-"), .active, .enabled] | @tsv)
      end' | column -t -s $'\t'
  fi
}

# Resolve the coding-CLI version string for an agent type from its TYPE_BIN
# binary. Best-effort: returns "" if the binary is missing or doesn't answer
# --version in time. Runs as `claude` (owns the binaries + their caches) through
# a login shell so node/nvm-based CLIs (codex) inherit their PATH, capped at 5s
# so a wedged CLI can't hang `info`.
resolve_cli_version() {
  local type="$1"
  local bin="${TYPE_BIN[$type]:-}"
  [[ -n "$bin" ]] || { printf ''; return; }
  timeout 5 sudo -u claude bash -lc "$(printf '%q' "$bin") --version 2>/dev/null | head -1" 2>/dev/null || printf ''
}

# Resolve the model an agent is configured to use, read from the per-type
# runtime config the CLI actually loads (codex/grok TOML, claude/antigravity
# JSON). Best-effort: returns "" when the runtime doesn't persist a model
# (grok/antigravity fall back to the CLI's built-in pick), so callers should
# render "—"/null rather than treat empty as an error.
resolve_agent_model() {
  local type="$1" name="$2"
  local home="/home/agent-${name}"
  # MUST stay exit-0 on a missing/unreadable config: the caller assigns this in
  # `amodel=$(resolve_agent_model …)`, and under the bundle's `set -e` a non-zero
  # here aborts the whole command. A `--defer-auth` antigravity agent has no
  # settings.json until its first boot writes it, so the jq below exits non-zero
  # and (DIVE-230) crashed `agent list`/`info` mid-build → empty output → callers
  # read it as "agent missing". The `|| true` on every file read keeps the
  # contract: absent value → "" → exit 0. (sed|head needs it too: under
  # `pipefail` a missing config.toml propagates sed's non-zero status.)
  case "$type" in
    claude)
      sudo jq -r '.model // empty' "$home/.claude/settings.json" 2>/dev/null || true ;;
    codex)
      { sudo sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*[^"# ])"?.*/\1/p' \
        "$home/.codex/config.toml" 2>/dev/null | head -1; } || true ;;
    grok)
      { sudo sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*[^"# ])"?.*/\1/p' \
        "$home/.grok/config.toml" 2>/dev/null | head -1; } || true ;;
    antigravity)
      sudo jq -r '.model // .selectedModel // empty' \
        "$home/.gemini/antigravity-cli/settings.json" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

# Resolve the reasoning effort an agent is configured with — claude-only
# (`effortLevel` in settings.json). Best-effort: returns "" for non-claude types
# or when unset (Claude Code then uses its built-in default), so callers render
# "—"/null rather than treat empty as an error.
resolve_agent_effort() {
  local type="$1" name="$2"
  case "$type" in
    claude)
      sudo jq -r '.effortLevel // empty' "/home/agent-${name}/.claude/settings.json" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

# Write the selected model into the per-type runtime config the CLI loads, so
# `config set model=` is the single uniform path the forks' /model shells out to
# (replacing each plugin's own per-runtime config write). TOML (codex/grok) and
# JSON (claude/antigravity) are handled distinctly:
#   - TOML: split at the first table header; replace an existing top-level
#     `model = ...` in the preamble, else prepend one above the first [table] —
#     so the key stays document-root-level, never binds to a [section] and never
#     duplicates (matches telegram-{codex,grok} writeConfigModel()).
#   - JSON: merge-write the top-level `.model` key, preserving every other key.
# The runtime config must already exist (every provisioned+started agent has
# one) — we refuse to create it, both because a bare new file would drop the
# other required settings and because pre-seeding codex's config.toml would make
# 5dive-agent-start skip its approval_policy/sandbox baseline. Atomic (tmp +
# rename) with the existing owner:group + 600 mode preserved.
write_runtime_model() {
  local type="$1" name="$2" model="$3"
  local home="/home/agent-${name}" file fmt
  case "$type" in
    claude)      file="$home/.claude/settings.json"; fmt=json ;;
    codex)       file="$home/.codex/config.toml";     fmt=toml ;;
    grok)        file="$home/.grok/config.toml";       fmt=toml ;;
    antigravity) file="$home/.gemini/antigravity-cli/settings.json"; fmt=json ;;
    *) fail "$E_VALIDATION" "type '$type' has no model config (can't set model=)" ;;
  esac
  [[ -f "$file" ]] \
    || fail "$E_NOT_FOUND" "no $type runtime config at $file yet — start agent '$name' once before setting model"
  local dir own
  dir=$(dirname "$file")
  own=$(stat -c '%U:%G' "$file")
  local tmp
  tmp=$(mktemp -p "$dir" .model.XXXXXX) || fail "$E_GENERIC" "mktemp failed in $dir"
  if ! MODEL_FMT="$fmt" MODEL_VAL="$model" MODEL_SRC="$file" python3 - "$tmp" <<'PY'
import os, sys, json, re
fmt, val, src, tmp = os.environ["MODEL_FMT"], os.environ["MODEL_VAL"], os.environ["MODEL_SRC"], sys.argv[1]
with open(src) as f: orig = f.read()
if fmt == "json":
    try:
        data = json.loads(orig) if orig.strip() else {}
    except ValueError:
        sys.stderr.write("existing %s is not valid JSON\n" % src); sys.exit(3)
    if not isinstance(data, dict):
        sys.stderr.write("existing %s is not a JSON object\n" % src); sys.exit(3)
    data["model"] = val
    out = json.dumps(data, indent=2) + "\n"
else:  # toml — only ever touch the preamble before the first [table] header
    m = re.search(r'^\s*\[', orig, re.M)
    head = orig if m is None else orig[:m.start()]
    tail = "" if m is None else orig[m.start():]
    line = 'model = "%s"' % val
    if re.search(r'^[ \t]*model[ \t]*=.*$', head, re.M):
        head = re.sub(r'^[ \t]*model[ \t]*=.*$', line, head, count=1, flags=re.M)
    else:
        head = line + "\n" + head
    out = head + tail
with open(tmp, "w") as f: f.write(out)
PY
  then
    rm -f "$tmp"; fail "$E_GENERIC" "failed to write model into $file"
  fi
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Write the reasoning effort into claude's settings.json (`effortLevel`) — the
# same key Claude Code reads and the telegram plugin's /effort writes. Claude-only
# (other types have no effort knob). Same atomic merge-write contract as
# write_runtime_model: refuse to create a missing file, preserve owner:group + 600.
write_runtime_effort() {
  local name="$1" effort="$2"
  local file="/home/agent-${name}/.claude/settings.json"
  [[ -f "$file" ]] \
    || fail "$E_NOT_FOUND" "no claude runtime config at $file yet — start agent '$name' once before setting effort"
  local dir own tmp
  dir=$(dirname "$file")
  own=$(stat -c '%U:%G' "$file")
  tmp=$(mktemp -p "$dir" .effort.XXXXXX) || fail "$E_GENERIC" "mktemp failed in $dir"
  if ! EFFORT_VAL="$effort" EFFORT_SRC="$file" python3 - "$tmp" <<'PY'
import os, sys, json
val, src, tmp = os.environ["EFFORT_VAL"], os.environ["EFFORT_SRC"], sys.argv[1]
with open(src) as f: orig = f.read()
try:
    data = json.loads(orig) if orig.strip() else {}
except ValueError:
    sys.stderr.write("existing %s is not valid JSON\n" % src); sys.exit(3)
if not isinstance(data, dict):
    sys.stderr.write("existing %s is not a JSON object\n" % src); sys.exit(3)
data["effortLevel"] = val
with open(tmp, "w") as f: f.write(json.dumps(data, indent=2) + "\n")
PY
  then
    rm -f "$tmp"; fail "$E_GENERIC" "failed to write effortLevel into $file"
  fi
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Single-agent detail: registry identity/config + live systemd state, plus the
# resolved coding-CLI version and selected model. Added so each fork's /status
# reads one uniform source (cliName/cliVersion/model) instead of shelling each
# runtime's config itself — the version/model live in different files per type
# and the binaries aren't on the agent user's PATH.
cmd_info() {
  ensure_state
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent info <name> [--json]"
  require_agent "$name"

  local reg
  reg=$(registry_read)

  local svc="5dive-agent@${name}"
  local active enabled
  active=$(systemctl is-active "$svc" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)

  local type
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")

  local cli_version model effort
  cli_version=$(resolve_cli_version "$type")
  # `|| true`: a best-effort per-agent config read must never abort `info` under
  # `set -e` when the file is absent (e.g. --defer-auth agy pre-boot — DIVE-230).
  model=$(resolve_agent_model "$type" "$name" || true)
  effort=$(resolve_agent_effort "$type" "$name" || true)

  local obj
  obj=$(jq -c \
    --arg n "$name" \
    --arg default_wd "$DEFAULT_WORKDIR" \
    --arg active "${active:-unknown}" \
    --arg enabled "${enabled:-unknown}" \
    --arg cliName "$type" \
    --arg cliVersion "$cli_version" \
    --arg model "$model" \
    --arg effort "$effort" \
    '.agents[$n] as $a | {
      name: $n,
      type: $a.type,
      channels: ($a.channels // "none"),
      workdir: ($a.workdir // $default_wd),
      authProfile: ($a.authProfile // null),
      botUsername: ($a.botUsername // null),
      isolation: ($a.isolation // "admin"),
      heartbeat: ($a.heartbeat // null),
      createdAt: $a.createdAt,
      active: $active,
      enabled: $enabled,
      cliName: $cliName,
      cliVersion: (if $cliVersion == "" then null else $cliVersion end),
      model: (if $model == "" then null else $model end),
      effort: (if $effort == "" then null else $effort end)
    }' <<<"$reg")

  if (( JSON_MODE )); then
    jq -cn --argjson d "$obj" '{ok:true, data:$d}'
  else
    jq -r '
      "name:        \(.name)",
      "type:        \(.type)",
      "cli:         \(.cliName) \(.cliVersion // "unknown")",
      "model:       \(.model // "—")\(if .effort then " · effort \(.effort)" else "" end)",
      "channels:    \(.channels)\(if .botUsername then " (@\(.botUsername))" else "" end)",
      "profile:     \(.authProfile // "-")",
      "workdir:     \(.workdir)",
      "isolation:   \(.isolation)",
      "state:       \(.active) / \(.enabled)",
      "created:     \(.createdAt // "unknown")"
    ' <<<"$obj"
  fi
}

