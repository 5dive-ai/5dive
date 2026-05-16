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
#       type:           claude|codex|gemini|hermes|openclaw|opencode  (required)
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
    step "[$name] creating"
    local agent_spec
    agent_spec=$(jq -c --arg n "$name" '.agents[$n]' <<<"$spec")
    local -a args=()
    mapfile -t args < <(_compose_create_args "$agent_spec" "$name" "$spec_dir")
    if bash "$self" agent create "${args[@]}"; then
      ((created++)) || true
    else
      warn "[$name] create failed"
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

