# -------- compose (declarative agents via 5dive.yaml) --------
#
# Docker-Compose-style declarative manager. Define your AI team in a
# 5dive.yaml file and bring it up/down with one command. Re-running `5dive
# up` is idempotent — existing agents are left alone, missing ones are
# created. Drift between spec and live state is logged but not auto-applied;
# tear down + bring up to recreate.
#
# Schema (v1):
#   version: "1"
#   agents:
#     <name>:
#       type:           claude|codex|hermes|openclaw|opencode  (required)
#       channels:       none|telegram|discord                          (default none)
#       telegram_token: "<bot-token>"      # required if channels=telegram
#       discord_token:  "<bot-token>"      # required if channels=discord
#       workdir:        ./relative/or/absolute/path
#       skills:         [skill1, skill2]   # bare ids or owner/repo:id
#       no_skills:      true               # opt out of inherited skills
#       defer_auth:     true               # create without auth gate
#       isolation:      admin|standard|sandboxed
#       auth_profile:   <named-account>
#       provider:       <byo-id>           # hermes/openclaw only
#       api_key:        "<key>"            # hermes/openclaw only
#       pack:           <slug>             # import a character pack instead of a
#                                          # bare create — supplies persona+skills
#                                          # +model/effort (5dive agent import)
#
# Env vars: any "${VAR}" in a string value is expanded from the process env.
# Missing/empty vars fail loudly so a misconfigured shell can't silently
# create agents with literal "${...}" strings as bot tokens.

# Default file: 5dive.yaml then 5dive.yml in cwd. Returns non-zero if neither.
_compose_default_file() {
  if   [[ -f 5dive.yaml ]]; then printf '%s' 5dive.yaml
  elif [[ -f 5dive.yml  ]]; then printf '%s' 5dive.yml
  else return 1
  fi
}

# YAML → JSON via python3 + PyYAML, with strict ${VAR} env expansion.
#
# v1 just normalised the agents map. v2 additionally:
#   - merges a top-level defaults{} into every agent (agent-level keys win),
#   - validates reports_to (targets must resolve to agent names, no self-edge,
#     no cycles) and the instructions / instructions_file XOR,
#   - warns (does not fail) on unknown per-agent keys for forward-compat.
# Output JSON keeps the same {..., agents:{<name>:{merged spec}}} shape so the
# v1 create path is untouched; team{}/defaults{}/version pass through for export.
_compose_parse() {
  local file="$1"
  python3 - "$file" <<'PY'
import yaml, json, sys, os, re
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"error: yaml parse failed: {e}", file=sys.stderr); sys.exit(3)
except OSError as e:
    print(f"error: cannot open {sys.argv[1]}: {e}", file=sys.stderr); sys.exit(4)
if not isinstance(data, dict) or "agents" not in data or not isinstance(data["agents"], dict):
    print("error: spec must have a top-level 'agents:' map", file=sys.stderr); sys.exit(3)

defaults = data.get("defaults") or {}
if not isinstance(defaults, dict):
    print("error: 'defaults:' must be a map", file=sys.stderr); sys.exit(3)

# Known per-agent keys (v1 + v2). Unknown → warn, not fail (forward-compat).
KNOWN = {
    "type","channels","telegram_token","discord_token","workdir","skills",
    "no_skills","defer_auth","isolation","auth_profile","provider","api_key",
    "role","instructions","instructions_file","model","effort","reports_to","goals",
    "pack",  # DIVE-536: import a character pack (5dive agent import <slug>) instead
             # of a bare create — the pack supplies persona+skills+model/effort.
}

agents = data["agents"]
# Merge defaults under each agent (agent keys win). None spec → empty map.
merged = {}
for name, spec in agents.items():
    spec = spec or {}
    if not isinstance(spec, dict):
        print(f"error: agent '{name}' must be a map", file=sys.stderr); sys.exit(3)
    m = dict(defaults); m.update(spec)
    merged[name] = m
    if m.get("instructions") and m.get("instructions_file"):
        print(f"error: agent '{name}': instructions and instructions_file are mutually exclusive", file=sys.stderr); sys.exit(3)
    for k in spec:
        if k not in KNOWN:
            print(f"warning: agent '{name}': unknown key '{k}' (ignored)", file=sys.stderr)
data["agents"] = merged

# reports_to: normalise to a list, validate targets resolve + no self-edge.
names = set(merged)
edges = {}
def rt_list(v):
    if v is None or v == "": return []
    return v if isinstance(v, list) else [v]
for name, m in merged.items():
    mgrs = rt_list(m.get("reports_to"))
    for mgr in mgrs:
        if mgr not in names:
            print(f"error: agent '{name}': reports_to '{mgr}' is not a declared agent", file=sys.stderr); sys.exit(3)
        if mgr == name:
            print(f"error: agent '{name}': cannot report to itself", file=sys.stderr); sys.exit(3)
    edges[name] = mgrs
# Reject cycles in the reporting graph (DFS, colour-marking).
WHITE, GREY, BLACK = 0, 1, 2
colour = {n: WHITE for n in names}
def visit(n, stack):
    colour[n] = GREY
    for mgr in edges.get(n, []):
        if colour[mgr] == GREY:
            cyc = " -> ".join(stack + [n, mgr])
            print(f"error: reporting cycle detected: {cyc}", file=sys.stderr); sys.exit(3)
        if colour[mgr] == WHITE:
            visit(mgr, stack + [n])
    colour[n] = BLACK
for n in names:
    if colour[n] == WHITE:
        visit(n, [])

env_re = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
def expand(v):
    if isinstance(v, str):
        def sub(m):
            k = m.group(1)
            if k not in os.environ or os.environ[k] == "":
                print(f"error: env var '{k}' referenced in spec is unset", file=sys.stderr)
                sys.exit(3)
            return os.environ[k]
        return env_re.sub(sub, v)
    if isinstance(v, dict): return {k: expand(x) for k, x in v.items()}
    if isinstance(v, list): return [expand(x) for x in v]
    return v
print(json.dumps(expand(data)))
PY
}

# Resolve a workdir field. Relative paths are resolved against the directory
# containing the spec file (Docker-Compose convention). realpath -m so the
# target need not exist yet.
_compose_resolve_path() {
  local p="$1" spec_dir="$2"
  [[ "$p" = /* ]] && { printf '%s' "$p"; return; }
  realpath -m "${spec_dir}/${p}"
}

# Build argv for `5dive agent create <name> ...` from a parsed agent spec.
# Echoed one arg per line so the caller can mapfile-slurp into an array
# (handles spaces/quotes in values cleanly).
_compose_create_args() {
  local spec="$1" name="$2" spec_dir="$3"
  printf '%s\n' "$name"
  local type channels tg_token dc_token workdir profile isolation provider api_key
  type=$(jq      -r '.type             // empty' <<<"$spec")
  channels=$(jq  -r '.channels         // empty' <<<"$spec")
  tg_token=$(jq  -r '.telegram_token   // empty' <<<"$spec")
  dc_token=$(jq  -r '.discord_token    // empty' <<<"$spec")
  workdir=$(jq   -r '.workdir          // empty' <<<"$spec")
  profile=$(jq   -r '.auth_profile     // empty' <<<"$spec")
  isolation=$(jq -r '.isolation        // empty' <<<"$spec")
  provider=$(jq  -r '.provider         // empty' <<<"$spec")
  api_key=$(jq   -r '.api_key          // empty' <<<"$spec")
  local no_skills defer_auth
  no_skills=$(jq  -r '.no_skills  // false' <<<"$spec")
  defer_auth=$(jq -r '.defer_auth // false' <<<"$spec")

  printf '%s\n' "--type=${type}"
  [[ -n "$channels"  ]] && printf '%s\n' "--channels=${channels}"
  [[ -n "$tg_token"  ]] && printf '%s\n' "--telegram-token=${tg_token}"
  [[ -n "$dc_token"  ]] && printf '%s\n' "--discord-token=${dc_token}"
  if [[ -n "$workdir" ]]; then
    local wd_abs
    wd_abs=$(_compose_resolve_path "$workdir" "$spec_dir")
    printf '%s\n' "--workdir=${wd_abs}"
  fi
  [[ -n "$profile"   ]] && printf '%s\n' "--auth-profile=${profile}"
  [[ -n "$isolation" ]] && printf '%s\n' "--isolation=${isolation}"
  [[ -n "$provider"  ]] && printf '%s\n' "--provider=${provider}"
  [[ -n "$api_key"   ]] && printf '%s\n' "--api-key=${api_key}"

  # Skills: comma-join the array. --no-skills wins (cmd_create's parser
  # treats them as mutually exclusive at the call site).
  local skills_csv
  skills_csv=$(jq -r 'if (.skills // []) | length == 0 then "" else (.skills | join(",")) end' <<<"$spec")
  if [[ "$no_skills" == "true" ]]; then
    printf '%s\n' "--no-skills"
  elif [[ -n "$skills_csv" ]]; then
    printf '%s\n' "--with-skills=${skills_csv}"
  fi
  [[ "$defer_auth" == "true" ]] && printf '%s\n' "--defer-auth"
}

# DIVE-536: build argv for `5dive agent import <pack> --as=<name> ...` when an
# agent spec carries `pack:`. The pack manifest supplies type/persona/skills/
# model/effort; here we only thread the runtime wiring (channels/auth/workdir).
# Echoed one arg per line for mapfile-slurp, same contract as _compose_create_args.
_compose_import_args() {
  local spec="$1" name="$2" pack="$3" spec_dir="$4"
  printf '%s\n' "$pack"
  printf '%s\n' "--as=${name}"
  local channels tg_token dc_token profile workdir
  channels=$(jq -r '.channels       // empty' <<<"$spec")
  tg_token=$(jq -r '.telegram_token // empty' <<<"$spec")
  dc_token=$(jq -r '.discord_token  // empty' <<<"$spec")
  profile=$(jq  -r '.auth_profile   // empty' <<<"$spec")
  workdir=$(jq  -r '.workdir        // empty' <<<"$spec")
  [[ -n "$channels" ]] && printf '%s\n' "--channels=${channels}"
  [[ -n "$tg_token" ]] && printf '%s\n' "--telegram-token=${tg_token}"
  [[ -n "$dc_token" ]] && printf '%s\n' "--discord-token=${dc_token}"
  [[ -n "$profile"  ]] && printf '%s\n' "--auth-profile=${profile}"
  if [[ -n "$workdir" ]]; then
    local wd_abs; wd_abs=$(_compose_resolve_path "$workdir" "$spec_dir")
    printf '%s\n' "--workdir=${wd_abs}"
  fi
}

# Build the "## Role" + "## Reporting" markdown for one agent and append it to
# the agent's $HOME/.claude/CLAUDE.md — BELOW the shared telegram fragment that
# cmd_create already dropped (telegram agents) or as a fresh file (others). This
# is the v1 gap: every telegram agent used to get only the shared mandate; now a
# CEO vs DevOps carry distinct role instructions + a real delegation map.
#
# Reporting lines are generated from reports_to so delegation is executable, not
# decorative: each manager / direct report comes with the exact `5dive agent
# send` invocation. Runs on CREATE only (see cmd_compose_up), so re-running `up`
# never double-appends.
_compose_write_role_md() {
  local spec="$1" name="$2" spec_dir="$3"
  local agent role instructions ifile
  agent=$(jq -c --arg n "$name" '.agents[$n]' <<<"$spec")
  role=$(jq         -r '.role              // empty' <<<"$agent")
  instructions=$(jq -r '.instructions      // empty' <<<"$agent")
  ifile=$(jq        -r '.instructions_file // empty' <<<"$agent")

  # Resolve instructions_file against the spec dir (parser already enforced XOR).
  if [[ -z "$instructions" && -n "$ifile" ]]; then
    local ipath
    ipath=$(_compose_resolve_path "$ifile" "$spec_dir")
    if [[ -f "$ipath" ]]; then
      instructions=$(cat "$ipath")
    else
      warn "[$name] instructions_file not found: $ipath"
    fi
  fi

  # Managers (reports_to) and direct reports (who lists $name as a manager).
  local -a mgrs reports
  mapfile -t mgrs    < <(jq -r --arg n "$name" '.agents[$n].reports_to // empty | if type=="array" then .[] else . end' <<<"$spec")
  mapfile -t reports < <(jq -r --arg n "$name" '.agents | to_entries[] | select((.value.reports_to // empty) | if type=="array" then any(. == $n) else . == $n end) | .key' <<<"$spec")

  # Nothing role-specific → leave the agent's CLAUDE.md exactly as cmd_create
  # left it (keeps plain v1 specs byte-identical to before).
  [[ -n "$role" || -n "$instructions" || ${#mgrs[@]} -gt 0 || ${#reports[@]} -gt 0 ]] || return 0

  local block=$'\n\n'
  if [[ -n "$role" ]]; then block+="## Role: ${role}"$'\n\n'; else block+="## Role"$'\n\n'; fi
  [[ -n "$instructions" ]] && block+="${instructions}"$'\n\n'
  block+="## Reporting"$'\n'
  if [[ ${#mgrs[@]} -gt 0 ]]; then
    local m
    for m in "${mgrs[@]}"; do
      block+="- You report to **${m}**. Escalate or sync: \`5dive agent send ${m} '<message>'\`."$'\n'
    done
  else
    block+="- You sit at the top of this org; you answer to the human owner."$'\n'
  fi
  if [[ ${#reports[@]} -gt 0 ]]; then
    local r
    for r in "${reports[@]}"; do
      block+="- Direct report **${r}**. Delegate: \`5dive agent send ${r} '<task>'\`."$'\n'
    done
  fi

  local user="agent-${name}" home="/home/agent-${name}" md
  md="$home/.claude/CLAUDE.md"
  sudo -u "$user" mkdir -p "$home/.claude" 2>/dev/null || true
  if printf '%s' "$block" | sudo -u "$user" tee -a "$md" >/dev/null 2>&1; then
    sudo chmod 644 "$md" 2>/dev/null || true
  else
    warn "[$name] could not write role instructions to $md"
  fi
}

# Apply the v2 role wiring for one freshly-created agent: model, effort, org
# edge (reports_to), role instructions + reporting block, and seed goals into
# the task queue. Every step is best-effort and process-isolated (shelled out
# or subshell-guarded) so one failure can't abort the whole bring-up.
_compose_wire_role() {
  local spec="$1" name="$2" spec_dir="$3" self="$4"
  local agent type model effort role primary_mgr
  agent=$(jq -c --arg n "$name" '.agents[$n]' <<<"$spec")
  type=$(jq   -r '.type   // "claude"' <<<"$agent")
  model=$(jq  -r '.model  // empty'    <<<"$agent")
  effort=$(jq -r '.effort // empty'    <<<"$agent")
  role=$(jq   -r '.role   // empty'    <<<"$agent")
  primary_mgr=$(jq -r '.reports_to // empty | if type=="array" then (.[0] // "") else . end' <<<"$agent")

  # DIVE-536/506: CC 2.1.181+ STRIPS a bare model alias ("opus") from a fresh
  # config dir, so a template that says `model: opus` silently loses it. Normalise
  # the alias to the full resolved id the runtime keeps; full ids pass untouched.
  case "$model" in
    opus)   model="claude-opus-4-8" ;;
    sonnet) model="claude-sonnet-4-6" ;;
    haiku)  model="claude-haiku-4-5-20251001" ;;
  esac

  # model / effort via the public config path (process-isolated; warns if the
  # runtime config isn't written yet — model just stays at its default).
  if [[ -n "$model" ]]; then
    bash "$self" agent config "$name" set "model=$model" >/dev/null 2>&1 \
      || warn "[$name] set model=$model failed (apply later: 5dive agent config $name set model=$model)"
  fi
  if [[ -n "$effort" ]]; then
    bash "$self" agent config "$name" set "effort=$effort" >/dev/null 2>&1 \
      || warn "[$name] set effort=$effort failed (apply later: 5dive agent config $name set effort=$effort)"
  fi

  # Org edge + title. org set carries one manager; the Reporting block lists all.
  if [[ -n "$role" || -n "$primary_mgr" ]]; then
    local -a oargs=(org set "$name")
    [[ -n "$role"        ]] && oargs+=("--role=$role")
    [[ -n "$primary_mgr" ]] && oargs+=("--manager=$primary_mgr")
    bash "$self" "${oargs[@]}" >/dev/null 2>&1 || warn "[$name] org set failed"
  fi

  # Role instructions + reporting block → agent CLAUDE.md.
  _compose_write_role_md "$spec" "$name" "$spec_dir"

  # Seed goals into the shared task queue, assigned to the role, from its manager.
  local -a goals
  mapfile -t goals < <(jq -r '(.goals // [])[]' <<<"$agent")
  local g
  for g in "${goals[@]}"; do
    [[ -n "$g" ]] || continue
    local -a targs=(task add "$g" "--assignee=$name")
    [[ -n "$primary_mgr" ]] && targs+=("--from=$primary_mgr")
    bash "$self" "${targs[@]}" >/dev/null 2>&1 || warn "[$name] seed goal failed: $g"
  done
}

# Re-exec self via bash so we work whether the script was installed (+x) or
# invoked from a source checkout (no +x).
_compose_self() { realpath "${BASH_SOURCE[0]}"; }

cmd_compose_up() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    file="$2"; shift ;;
      --file=*)     file="${1#--file=}" ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive up [-f file]
  Bring up agents declared in 5dive.yaml. Idempotent — existing agents are
  left alone, missing ones are created and started.
  Default file: 5dive.yaml or 5dive.yml in the current directory.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  if [[ -z "$file" ]]; then
    file=$(_compose_default_file) \
      || fail "$E_NOT_FOUND" "no 5dive.yaml or 5dive.yml in $(pwd) — pass -f <file>"
  fi
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "spec file not found: $file"
  ensure_state

  local spec spec_dir self
  spec=$(_compose_parse "$file") || fail "$E_VALIDATION" "spec parse failed"
  spec_dir=$(realpath "$(dirname "$file")")
  self=$(_compose_self)

  local reg
  reg=$(registry_read)

  local names created=0 started=0 skipped=0 errors=0
  mapfile -t names < <(jq -r '.agents | keys[]' <<<"$spec")
  if (( ${#names[@]} == 0 )); then
    warn "spec has no agents declared"
    ok "no agents to apply" '{file:$f, created:0, started:0, skipped:0, errors:0}' --arg f "$file"
    return 0
  fi

  local name
  for name in "${names[@]}"; do
    if ! valid_name "$name"; then
      warn "[$name] invalid agent name — skipping"
      ((errors++)) || true
      continue
    fi
    local exists
    exists=$(jq --arg n "$name" '.agents[$n] != null' <<<"$reg")
    if [[ "$exists" == "true" ]]; then
      step "[$name] already exists — ensuring started"
      if bash "$self" agent start "$name" >/dev/null 2>&1; then
        ((started++)) || true
      else
        ((skipped++)) || true
      fi
      continue
    fi
    local agent_spec pack_slug
    agent_spec=$(jq -c --arg n "$name" '.agents[$n]' <<<"$spec")
    pack_slug=$(jq -r '.pack // empty' <<<"$agent_spec")
    local -a args=(); local brought_up=1 verb=create
    if [[ -n "$pack_slug" ]]; then
      # DIVE-536: spec references a character pack → import it (pack supplies
      # persona+skills+model/effort); wiring below still applies org/goals/overrides.
      verb=import
      step "[$name] importing character pack '$pack_slug'"
      mapfile -t args < <(_compose_import_args "$agent_spec" "$name" "$pack_slug" "$spec_dir")
      bash "$self" agent import "${args[@]}" || brought_up=0
    else
      step "[$name] creating"
      mapfile -t args < <(_compose_create_args "$agent_spec" "$name" "$spec_dir")
      bash "$self" agent create "${args[@]}" || brought_up=0
    fi
    if (( brought_up )); then
      ((created++)) || true
      # v2 role wiring (model/effort/org/instructions/goals). Best-effort: a
      # wiring hiccup must not fail the create/import that already succeeded.
      _compose_wire_role "$spec" "$name" "$spec_dir" "$self" || true
    else
      warn "[$name] $verb failed"
      ((errors++)) || true
    fi
  done

  if (( JSON_MODE )); then
    ok "" '{file:$f, created:($c|tonumber), started:($s|tonumber), skipped:($k|tonumber), errors:($e|tonumber)}' \
      --arg f "$file" --arg c "$created" --arg s "$started" --arg k "$skipped" --arg e "$errors"
  else
    echo "OK — applied $file: created=$created started=$started skipped=$skipped errors=$errors"
  fi
  (( errors == 0 )) || return "$E_GENERIC"
}

cmd_compose_down() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    file="$2"; shift ;;
      --file=*)     file="${1#--file=}" ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive down [-f file]
  Tear down agents declared in 5dive.yaml — stops and removes each one.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  if [[ -z "$file" ]]; then
    file=$(_compose_default_file) \
      || fail "$E_NOT_FOUND" "no 5dive.yaml or 5dive.yml in $(pwd) — pass -f <file>"
  fi
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "spec file not found: $file"
  ensure_state

  local spec self
  spec=$(_compose_parse "$file") || fail "$E_VALIDATION" "spec parse failed"
  self=$(_compose_self)

  local reg
  reg=$(registry_read)

  local names removed=0 missing=0 errors=0
  mapfile -t names < <(jq -r '.agents | keys[]' <<<"$spec")
  local name
  for name in "${names[@]}"; do
    local exists
    exists=$(jq --arg n "$name" '.agents[$n] != null' <<<"$reg")
    if [[ "$exists" != "true" ]]; then
      step "[$name] not present — skipping"
      ((missing++)) || true
      continue
    fi
    step "[$name] removing"
    if bash "$self" agent rm "$name" >/dev/null 2>&1; then
      ((removed++)) || true
    else
      warn "[$name] remove failed"
      ((errors++)) || true
    fi
  done

  if (( JSON_MODE )); then
    ok "" '{file:$f, removed:($r|tonumber), missing:($m|tonumber), errors:($e|tonumber)}' \
      --arg f "$file" --arg r "$removed" --arg m "$missing" --arg e "$errors"
  else
    echo "OK — torn down $file: removed=$removed missing=$missing errors=$errors"
  fi
  (( errors == 0 )) || return "$E_GENERIC"
}

# 5dive export — round-trip the live fleet back to a v2 5dive.yaml, so a running
# org can be saved, versioned, and forked into a template. Dumps the structural
# spec (type/channels/workdir/auth_profile + model/effort + role/reports_to from
# the org graph). Role INSTRUCTIONS are not round-tripped: an agent's CLAUDE.md
# interleaves the shared telegram fragment with the role block, so re-deriving
# clean source is unsafe — a `# instructions: ...` reminder is emitted instead.
cmd_compose_export() {
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output) out="$2"; shift ;;
      --output=*)  out="${1#--output=}" ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive export [-o team.yaml]
  Dump the running fleet to a v2 5dive.yaml (stdout if no -o). Captures
  type/channels/workdir/auth_profile, model/effort, and role/reports_to.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  ensure_state
  local reg
  reg=$(registry_read)

  local names agents="{}"
  mapfile -t names < <(jq -r '.agents | keys[]' <<<"$reg")
  local name
  for name in "${names[@]}"; do
    local type channels workdir profile model effort role mgr
    type=$(jq    -r --arg n "$name" '.agents[$n].type        // "claude"' <<<"$reg")
    channels=$(jq -r --arg n "$name" '.agents[$n].channels    // empty'    <<<"$reg")
    workdir=$(jq -r --arg n "$name" '.agents[$n].workdir      // empty'    <<<"$reg")
    profile=$(jq -r --arg n "$name" '.agents[$n].authProfile  // empty'    <<<"$reg")
    model=$(resolve_agent_model  "$type" "$name")
    effort=$(resolve_agent_effort "$type" "$name")
    role=$(db "SELECT COALESCE(role,'')       FROM agents_org WHERE name=$(sqlq "$name");" 2>/dev/null | head -1)
    mgr=$(db  "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$name");" 2>/dev/null | head -1)
    # Assemble one agent object, dropping empty fields.
    local obj
    obj=$(jq -n \
      --arg type "$type" --arg channels "$channels" --arg workdir "$workdir" \
      --arg profile "$profile" --arg model "$model" --arg effort "$effort" \
      --arg role "$role" --arg mgr "$mgr" '
      {type:$type}
      | (if $channels != "" then .channels = $channels else . end)
      | (if $workdir  != "" then .workdir  = $workdir  else . end)
      | (if $profile  != "" then .auth_profile = $profile else . end)
      | (if $model    != "" then .model    = $model    else . end)
      | (if $effort   != "" then .effort   = $effort   else . end)
      | (if $role     != "" then .role     = $role     else . end)
      | (if $mgr      != "" then .reports_to = $mgr    else . end)')
    agents=$(jq -c --arg n "$name" --argjson o "$obj" '. + {($n): $o}' <<<"$agents")
  done

  local doc
  doc=$(jq -n --argjson agents "$agents" '{version:"2", agents:$agents}')
  local yaml
  yaml=$(printf '%s' "$doc" | python3 -c 'import sys,yaml,json; print("# 5dive.yaml v2 — exported fleet\n# note: role instructions are not round-tripped; re-add per role as needed.\n" + yaml.safe_dump(json.load(sys.stdin), sort_keys=False, default_flow_style=False))') \
    || fail "$E_GENERIC" "yaml serialisation failed"
  if [[ -n "$out" ]]; then
    printf '%s' "$yaml" > "$out" || fail "$E_GENERIC" "cannot write $out"
    ok "exported ${#names[@]} agents to $out" '{file:$f, agents:($n|tonumber)}' --arg f "$out" --arg n "${#names[@]}"
  else
    printf '%s' "$yaml"
  fi
}

# Where curated team templates live. Installed alongside the other shared
# plugin assets; falls back to a repo-local team-templates/ for source checkouts.
_team_templates_dir() {
  if   [[ -d /usr/local/lib/5dive/team-templates ]]; then printf '%s' /usr/local/lib/5dive/team-templates
  elif [[ -d "$(dirname "$(_compose_self)")/../team-templates" ]]; then
    realpath "$(dirname "$(_compose_self)")/../team-templates"
  else return 1
  fi
}

# 5dive team import <slug|path> — resolve a curated/bundled template (or a path)
# and bring the whole org up via the existing compose engine. A thin, honest
# wrapper over `up`: the heavy lifting (idempotent create + v2 wiring) is shared.
cmd_team() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    import) : ;;
    ls|list)
      local dir; dir=$(_team_templates_dir) || fail "$E_NOT_FOUND" "no team-templates dir found"
      echo "Available templates ($dir):"
      local f
      for f in "$dir"/*.5dive.yaml "$dir"/*.5dive.yml; do
        [[ -f "$f" ]] || continue
        local slug; slug=$(basename "$f"); slug="${slug%%.5dive.*}"
        printf '  %-16s %s\n' "$slug" "$f"
      done
      return 0 ;;
    -h|--help|"" )
      cat >&2 <<HELP
usage: 5dive team import <slug|path> [--auth-profile=<name>]
       5dive team ls
  Provision a whole company-structure template in one call (wraps 5dive up).
  <slug> resolves to a bundled template; a path is used as-is.
HELP
      return 0 ;;
    *) fail "$E_USAGE" "unknown team subcommand: $sub (try: import, ls)" ;;
  esac

  local ref="" profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth-profile=*) profile="${1#--auth-profile=}" ;;
      --auth-profile)   profile="$2"; shift ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive team import <slug|path>"

  local file=""
  if [[ -f "$ref" ]]; then
    file="$ref"
  else
    local dir; dir=$(_team_templates_dir) || fail "$E_NOT_FOUND" "no team-templates dir — pass a path"
    if   [[ -f "$dir/${ref}.5dive.yaml" ]]; then file="$dir/${ref}.5dive.yaml"
    elif [[ -f "$dir/${ref}.5dive.yml"  ]]; then file="$dir/${ref}.5dive.yml"
    else fail "$E_NOT_FOUND" "no template '$ref' in $dir (try: 5dive team ls)"
    fi
  fi

  # --auth-profile overrides the template's ${TEAM_AUTH_PROFILE} default.
  [[ -n "$profile" ]] && export TEAM_AUTH_PROFILE="$profile"
  step "importing team from $file"
  cmd_compose_up -f "$file"
}

cmd_compose_ps() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    file="$2"; shift ;;
      --file=*)     file="${1#--file=}" ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive ps [-f file]
  Show status of agents declared in 5dive.yaml.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  if [[ -z "$file" ]]; then
    file=$(_compose_default_file) \
      || fail "$E_NOT_FOUND" "no 5dive.yaml or 5dive.yml in $(pwd) — pass -f <file>"
  fi
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "spec file not found: $file"
  ensure_state

  local spec
  spec=$(_compose_parse "$file") || fail "$E_VALIDATION" "spec parse failed"
  local reg
  reg=$(registry_read)

  local names rows="[]"
  mapfile -t names < <(jq -r '.agents | keys[]' <<<"$spec")
  local name
  for name in "${names[@]}"; do
    local declared_type exists active
    declared_type=$(jq -r --arg n "$name" '.agents[$n].type // "?"' <<<"$spec")
    exists=$(jq           --arg n "$name" '.agents[$n] != null'     <<<"$reg")
    if [[ "$exists" == "true" ]]; then
      active=$(systemctl is-active "5dive-agent@${name}.service" 2>/dev/null || echo unknown)
    else
      active="missing"
    fi
    rows=$(jq -c --arg n "$name" --arg t "$declared_type" --arg a "$active" \
      '. + [{name:$n, type:$t, state:$a}]' <<<"$rows")
  done

  if (( JSON_MODE )); then
    ok "" '{file:$f, agents: $rows}' --arg f "$file" --argjson rows "$rows"
  else
    echo "$rows" | jq -r '
      (["NAME","TYPE","STATE"] | @tsv),
      (.[] | [.name, .type, .state] | @tsv)
    ' | column -t -s $'\t'
  fi
}

