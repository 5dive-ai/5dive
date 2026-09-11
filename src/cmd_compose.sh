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
#       provider:       <byo-id>           # hermes/openclaw (any), claude (anthropic-skin: deepseek moonshot openrouter qwen zai)
#       api_key:        "<key>"            # paired with provider; claude also needs auth_profile
#       pack:           <slug>             # import a character pack instead of a
#                                          # bare create — supplies persona+skills
#                                          # +model/effort (5dive agent import)
#       loops:                             # DIVE-4022 — recurring work this role owns
#         - id: weekly-brief               #   stable key (a-z0-9-), the reconcile key
#           title: "Ship the weekly brief" #   the recurring task's title
#           cron: "0 9 * * 1"              #   5-field cron cadence
#           prompt: |                      #   optional brief, folded into the body
#             ...
#           ceiling: 200000                #   optional advisory tokens/run
#         - pack: ci-analyst               #   OR a marketplace loop pack, installed
#           cron: "0 */4 * * *"            #   via `5dive loop install` (cron optional)
#
# Env vars: any "${VAR}" in a string value is expanded from the process env.
# Missing/empty vars fail loudly so a misconfigured shell can't silently
# create agents with literal "${...}" strings as bot tokens — EXCEPT in the
# optional credential fields telegram_token/discord_token, where an unset var
# drops the field and lands the agent channel-less (DIVE-3994). See the
# expansion block in _compose_parse for why.

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

# Marketplace teams may declare the one capability whose absence changes their
# operating mode. This is data, not an arbitrary preflight command supplied by
# the template: the CLI owns the exact probe (`5dive browser --help`).
team = data.get("team") or {}
if not isinstance(team, dict):
    print("error: 'team:' must be a map", file=sys.stderr); sys.exit(3)
caps = team.get("capabilities") or {}
if not isinstance(caps, dict):
    print("error: 'team.capabilities:' must be a map", file=sys.stderr); sys.exit(3)
browser_cap = caps.get("browser")
if browser_cap not in (None, "optional"):
    print("error: 'team.capabilities.browser' must be 'optional'", file=sys.stderr); sys.exit(3)

# Known per-agent keys (v1 + v2). Unknown → warn, not fail (forward-compat).
KNOWN = {
    "type","channels","telegram_token","discord_token","workdir","skills",
    "no_skills","defer_auth","isolation","auth_profile","provider","api_key","base_url",
    "role","instructions","instructions_file","model","effort","reports_to","goals",
    "loops", # DIVE-4022: recurring work this role owns. Same object `5dive loop
             # install` creates (a kind='recurring' task template), declared from
             # the spec instead of fetched from the marketplace registry.
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

# ---- loops: validation (DIVE-4022) ---------------------------------------
# A `loops:` entry declares recurring work the role OWNS. Ownership is per-agent
# because that is how `5dive loop install --onto=<agent>` already models it — no
# second ownership model is introduced here.
#
# Two forms, and exactly one of them per entry:
#   pack:  <slug>        -> installed via `5dive loop install <slug> --onto=<name>`,
#                           which owns the registry fetch, the skill attach and the
#                           recurring job. cron/ceiling optional overrides.
#   id+title+cron        -> a recurring task template created directly, i.e. the
#                           SAME object the pack path ends up creating.
# Validated here (fail loudly at parse) rather than at provision time, because a
# typo'd cadence discovered halfway through a roster leaves a half-provisioned
# company — the same reason --type is validated before ensure_state.
loop_id_re = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
def cron_ok(expr):
    f = str(expr).split()
    return len(f) == 5 and all(re.fullmatch(r"[0-9*,/-]+", x) for x in f)

for name, m in merged.items():
    loops = m.get("loops")
    if loops is None or loops == "":
        m.pop("loops", None)
        continue
    if not isinstance(loops, list):
        print(f"error: agent '{name}': 'loops:' must be a list", file=sys.stderr); sys.exit(3)
    seen = set()
    for i, L in enumerate(loops):
        where = f"agent '{name}' loop #{i+1}"
        if not isinstance(L, dict):
            print(f"error: {where}: each loop must be a map", file=sys.stderr); sys.exit(3)
        for k in L:
            if k not in ("id", "title", "cron", "prompt", "ceiling", "pack"):
                print(f"warning: {where}: unknown loop key '{k}' (ignored)", file=sys.stderr)
        pack, lid = L.get("pack"), L.get("id")
        if pack and (L.get("title") or L.get("prompt")):
            print(f"error: {where}: 'pack:' supplies its own job title and prompt — remove title/prompt", file=sys.stderr); sys.exit(3)
        key = pack or lid
        if not key:
            print(f"error: {where}: needs either 'pack: <slug>' or 'id: <key>' + 'title:' + 'cron:'", file=sys.stderr); sys.exit(3)
        if not loop_id_re.match(str(key)):
            print(f"error: {where}: bad {'pack' if pack else 'id'} '{key}' (a-z 0-9 - only)", file=sys.stderr); sys.exit(3)
        if key in seen:
            print(f"error: {where}: duplicate loop key '{key}' on this agent", file=sys.stderr); sys.exit(3)
        seen.add(key)
        if not pack:
            if not L.get("title"):
                print(f"error: {where}: an inline loop needs 'title:'", file=sys.stderr); sys.exit(3)
            if not L.get("cron"):
                print(f"error: {where}: an inline loop needs 'cron:' (5-field, e.g. \"0 9 * * 1\")", file=sys.stderr); sys.exit(3)
        # A pack carries its own cadence, so cron is optional there; when either
        # form DOES name one it must be a real 5-field expression.
        if L.get("cron") is not None and not cron_ok(L["cron"]):
            print(f"error: {where}: bad cron '{L['cron']}' (need 5 fields of [0-9*,/-], e.g. \"0 9 * * 1\")", file=sys.stderr); sys.exit(3)
        if L.get("ceiling") is not None and not re.fullmatch(r"[1-9][0-9]*", str(L["ceiling"])):
            print(f"error: {where}: ceiling must be a positive integer (tokens)", file=sys.stderr); sys.exit(3)

# ---- env expansion (DIVE-3994) -------------------------------------------
# Any "${VAR}" in a string value is expanded from the process env, and an unset
# one is a HARD error — a misconfigured shell must not create an agent whose bot
# token is the literal string "${...}".
#
# ONE class of field is exempt: the OPTIONAL credential fields below. A bot
# token is the one value a browser-driven `team import` cannot supply (there is
# no shell to export it in), and dying on the first unset one is what made the
# whole roster unreachable from the dashboard. There, an unset var drops the
# FIELD, and drops that agent's `channels` to `none` when the dropped token was
# the one wiring that channel — so the agent is created CHANNEL-LESS rather than
# half-wired with a channel it has no credential for. The rule is keyed on the
# FIELD, never on a var name, so it holds for any spec, not just our templates.
env_re = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
OPTIONAL_CRED_FIELDS = {"telegram_token": "telegram", "discord_token": "discord"}

class _UnsetVar(Exception):
    def __init__(self, var): self.var = var

def expand(v, optional=False):
    if isinstance(v, str):
        def sub(m):
            k = m.group(1)
            if k not in os.environ or os.environ[k] == "":
                if optional:
                    raise _UnsetVar(k)
                print(f"error: env var '{k}' referenced in spec is unset", file=sys.stderr)
                sys.exit(3)
            return os.environ[k]
        return env_re.sub(sub, v)
    if isinstance(v, dict): return {k: expand(x, optional) for k, x in v.items()}
    if isinstance(v, list): return [expand(x, optional) for x in v]
    return v

def drop_channel(spec, chan):
    """Remove ONE channel from `channels`, which is a comma LIST.

    `channels` is passed straight through to `agent create --channels=`, which
    accepts `<none|telegram|discord|dashboard|buzz[,ch...]>`. Matching it as a
    single value left `telegram,dashboard` untouched when the telegram token was
    dropped — the agent was created with a channel it has no credential for,
    which is the exact half-wired state this change exists to prevent, and it
    was silent because nothing was appended to the report either. Returns True
    when this agent actually had that channel, so only a real drop is reported.
    """
    parts = [c.strip() for c in str(spec.get("channels") or "").split(",")]
    parts = [c for c in parts if c]
    kept = [c for c in parts if c.lower() != chan]
    if len(kept) == len(parts): return False
    spec["channels"] = ",".join(kept) if kept else "none"
    return True

def drop_unset_creds(spec, name, dropped):
    """Expand only the optional credential fields; drop what is unset."""
    if not isinstance(spec, dict): return
    for field, chan in OPTIONAL_CRED_FIELDS.items():
        if field not in spec: continue
        try:
            spec[field] = expand(spec[field], optional=True)
        except _UnsetVar as u:
            del spec[field]
            if drop_channel(spec, chan) and name is not None:
                dropped.append({"agent": name, "channel": chan, "var": u.var})

dropped = []
for _name, _m in data["agents"].items():
    drop_unset_creds(_m, _name, dropped)
# `defaults:` was merged into every agent above, but it is ALSO carried through
# verbatim for `5dive export`, so its own raw "${...}" would still hard-fail the
# whole-document walk below. Same rule; there is no agent to name.
drop_unset_creds(data.get("defaults"), None, dropped)

out = expand(data)
# Consumed by cmd_compose_up to print ONE summary line. Emitted as data rather
# than printed here because _compose_parse is also called by `ps` and `export`,
# where a warning about a channel nobody is creating is noise.
out["channels_dropped"] = dropped
print(json.dumps(out))
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
  local type channels tg_token dc_token workdir profile isolation provider api_key base_url
  type=$(jq      -r '.type             // empty' <<<"$spec")
  channels=$(jq  -r '.channels         // empty' <<<"$spec")
  tg_token=$(jq  -r '.telegram_token   // empty' <<<"$spec")
  dc_token=$(jq  -r '.discord_token    // empty' <<<"$spec")
  workdir=$(jq   -r '.workdir          // empty' <<<"$spec")
  profile=$(jq   -r '.auth_profile     // empty' <<<"$spec")
  isolation=$(jq -r '.isolation        // empty' <<<"$spec")
  provider=$(jq  -r '.provider         // empty' <<<"$spec")
  api_key=$(jq   -r '.api_key          // empty' <<<"$spec")
  base_url=$(jq  -r '.base_url         // empty' <<<"$spec")
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
  # DIVE-2757: a self-hosted endpoint has no catalog row, so `agent create`
  # requires --model in the SAME call — it cannot be left to the post-create
  # `agent config set model=` that _compose_wire_role does for every other
  # agent, because create refuses before that ever runs. Emitted only on the
  # base_url path so no existing spec changes behaviour.
  if [[ -n "$base_url" ]]; then
    printf '%s\n' "--base-url=${base_url}"
    local _cmodel
    _cmodel=$(jq -r '.model // empty' <<<"$spec")
    [[ -n "$_cmodel" ]] && printf '%s\n' "--model=${_cmodel}"
  fi

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
  local spec="$1" name="$2" pack="$3" spec_dir="$4" type_override="${5:-}"
  printf '%s\n' "$pack"
  printf '%s\n' "--as=${name}"
  # DIVE-3998: a pack normally supplies its own harness, so `type:` is NOT
  # forwarded here — that is today's behaviour and it stays. `--type=` on
  # `up`/`team import` is the one exception: an explicit roster-wide override
  # must reach the pack path too, or `--type=codex` would create the plain
  # agents as codex and the pack agents as whatever the pack was packed as.
  if [[ -n "$type_override" ]]; then
    printf '%s\n' "--type=${type_override}"
  fi
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
# the persona file the agent's harness actually reads (TYPE_PERSONA_FILE,
# DIVE-2223 — ~/.claude/CLAUDE.md for claude/grok, elsewhere for the rest) — BELOW the shared telegram fragment that
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
  local -a mgrs=() reports=()
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

  # DIVE-2223: land the block in the file THIS harness reads. It used to go to
  # ~/.claude/CLAUDE.md for every type, which on a codex/opencode/pi/antigravity
  # seat is a write that succeeds into a path with no consumer. An unmapped type
  # warns loudly and installs nothing rather than defaulting to the claude path.
  local type
  type=$(jq -r '.type // "claude"' <<<"$agent")
  persona_append_block "$name" "$type" "$block" || true
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
  # DIVE-1883: the id itself lives in src/lib/models.sh — do NOT re-inline it here.
  model=$(resolve_model_alias "$model")

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
  local -a goals=()
  mapfile -t goals < <(jq -r '(.goals // [])[]' <<<"$agent")
  local g
  for g in "${goals[@]}"; do
    [[ -n "$g" ]] || continue
    local -a targs=(task add "$g" "--assignee=$name")
    [[ -n "$primary_mgr" ]] && targs+=("--from=$primary_mgr")
    bash "$self" "${targs[@]}" >/dev/null 2>&1 || warn "[$name] seed goal failed: $g"
  done
}

# -------- DIVE-4103: `team.requires:` — capability preflight --------------
#
# A team can declare the capabilities it needs to do its job at all. The Deploy
# Team needs a GitHub credential that can push and merge; without one it is
# still a useful team — it reads, grades and files — but nothing it approves
# ever lands, and NOTHING IN THE OUTPUT SAID SO. That is the defect this
# closes: an import that silently ships a Publisher that never publishes.
#
# POSTURE, and it is the same one `loops:` takes: a missing capability does NOT
# fail the import and does NOT count toward `errors`. The roster is up and
# useful in a reduced mode, which is named. A hard failure here would make a
# box with no credential unable to stand up a review team, which is worse than
# what it prevents.
#
# The probes live HERE, in code, and the template only names a key. A template
# that could name its own shell probe would be arbitrary code executed by an
# import, and the whole point of the marketplace is that a template is data.
_team_capability_label() {
  case "$1" in
    github_push) printf 'a GitHub credential that can push and merge' ;;
    browser)     printf 'the 5dive browser executor (authenticated-session channels)' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# What the team still IS without it, and how to get it. Read by a person who
# just ran one command, so it names the reduced mode first and the fix second.
_team_capability_degraded() {
  case "$1" in
    github_push) printf 'the team comes up REVIEW-ONLY — it can read, grade, file and reject, but nothing it approves can be pushed or merged. Give the box a credential (`gh auth login`, or export GH_TOKEN) and re-run the import: it is idempotent and will not double anything.' ;;
    browser)     printf 'the team comes up API-ONLY — any step that needs an authenticated browser session will not run. Install the executor and re-run the import.' ;;
    *)           printf 'the work that needs it will not run.' ;;
  esac
}

# rc 0 = present · 1 = absent · 2 = no probe for this key.
# `gh auth token` resolves GH_TOKEN/GITHUB_TOKEN and the hosts config and makes
# NO network call (same probe as _gh_caller_credential), so the preflight cannot
# hang an import on a box with no route out. It answers "does this box hold a
# credential", not "does that credential carry push on your repo" — a scope read
# needs a repo we have not been given and a network call we just refused to make.
# Does this spec actually PIN an account, i.e. would --auth-profile= change what
# gets provisioned? Comment lines are stripped first: this template EXPLAINS in
# its header why it pins no account, and a naked grep read that explanation as
# the pin.
#
# Named rather than inlined at the call site so the suite can drive THIS
# predicate. Its arms previously re-declared the same sed|grep and stayed green
# while the production line was mutated to a naked grep (quinn, DIVE-4103
# iteration 1) — a copy of a line is not a test of it.
_compose_spec_pins_auth_profile() {
  sed 's/[[:space:]]*#.*$//' "$1" 2>/dev/null | grep -q 'TEAM_AUTH_PROFILE'
}

# rc contract: 0 = present · 1 = absent · 2 = THIS CLI HAS NO PROBE for the key.
#
# 2 is a SENTINEL, so every known arm must collapse its probe's own exit status
# to 0/1 before returning it. Returning a probe's status verbatim is how the
# sentinel got claimed by accident: `5dive browser --help` on a box without the
# plugin prints "unknown command: browser" and exits 2, which reported "not
# checked" on exactly the box where the answer is a measured ABSENT — the one
# lie the unknown-key arm exists to prevent. (quinn, DIVE-4103 iteration 1.)
_team_capability_present() {
  case "$1" in
    github_push) command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1 || return 1 ;;
    browser)     "$(_compose_self)" browser --help >/dev/null 2>&1 || return 1 ;;
    *)           return 2 ;;
  esac
}

# Report every capability the spec declares, before anything is provisioned —
# the user reads it at the top of the import, not buried after 4 agent creates.
_compose_requires_preflight() {
  local spec="$1" k
  local -a keys=()
  mapfile -t keys < <(jq -r '
      if   (.team.requires? | type) == "array"  then .team.requires[]
      elif (.team.requires? | type) == "string" then .team.requires
      else empty end' <<<"$spec" 2>/dev/null || true)
  (( ${#keys[@]} )) || return 0
  for k in "${keys[@]}"; do
    [[ -n "$k" ]] || continue
    if _team_capability_present "$k"; then
      step "precondition ok — this box has $(_team_capability_label "$k")"
    else
      case $? in
        2) warn "this team declares a precondition this CLI has no probe for ('$k'). It is NOT checked — verify it by hand before you rely on the team." ;;
        *) warn "PRECONDITION ABSENT — $(_team_capability_label "$k") is not on this box, so $(_team_capability_degraded "$k")" ;;
      esac
    fi
  done
}

# -------- DIVE-4022: declared loops --------
#
# `team import` provisioned a ROSTER, not a working company: agents, roles and
# reporting lines came up with nothing recurring on the board, so an imported
# team sat idle until someone hand-created the work. `loops:` closes that.
#
# It is NOT a second loop format. A loop here ends as the same object
# `5dive loop install` produces — a kind='recurring' task template owned by one
# agent, which the step-2 materializer clones on schedule. The `pack:` form does
# not even reimplement that: it shells out to `loop install`, which owns the
# registry fetch and the skill attach.
#
# The marker below is the RECONCILE KEY. `up` is declarative and re-runnable, so
# a second import must find its own loops rather than add a second copy of each.

# Body marker for one declared loop. Mirrors cmd_loop_pack's
# "installed loop: <slug> (5dive marketplace)" so both are greppable the same way.
_compose_loop_marker() { printf 'declared loop: %s (5dive.yaml)' "$1"; }

# Does <agent> already own this loop? Matched on the marker OR the exact title.
#
# Title is the second key on purpose. The marker alone would be enough for loops
# THIS code created, but `5dive export` also dumps recurring work that was created
# by hand or by `loop install` — those carry no declared-loop marker, and matching
# the marker alone would re-create every one of them on the next `up`. That is the
# accumulation this reconcile exists to prevent, arriving through the export path
# instead of the re-import one. Scoped to kind='recurring' + this assignee, so it
# can only ever see the template rows this agent owns.
_compose_loop_present() {
  local agent="$1" key="$2" title="$3"
  local marker pack_marker title_clause="" n
  marker=$(_compose_loop_marker "$key")
  pack_marker="installed loop: ${key} (5dive marketplace)"
  # Built as its own variable rather than an inline $( … ) inside the SQL string:
  # an empty title makes that substitution exit non-zero, and a conditional whose
  # failure is invisible inside a query argument is exactly the shape that hides
  # a broken guard.
  [[ -n "$title" ]] && title_clause=" OR title=$(sqlq "$title")"
  n=$(db "SELECT COUNT(*) FROM tasks
          WHERE kind='recurring' AND assignee=$(sqlq "$agent")
            AND ( body LIKE '%'||$(sqlq "$marker")||'%'
               OR body LIKE '%'||$(sqlq "$pack_marker")||'%'${title_clause} );" 2>/dev/null | head -1)
  # A STORE ERROR ANSWERS 'ABSENT', DELIBERATELY. Both directions are wrong when
  # the db is unreadable; this one is wrong LOUDLY. Answering 'present' would skip
  # the create and print "already present" — a company that comes up idle while the
  # summary says every loop is there, which is the exact silent failure this row
  # exists to end. Answering 'absent' sends the caller to `task add`, which reaches
  # the SAME broken store, fails, and is counted as an error with a runnable retry
  # line. The cost of being wrong this way is a duplicate row on a store that is
  # readable-but-lying; the cost of the other is an idle roster reported as healthy.
  # Written out rather than inherited from ${n:-0} defaulting to 0: a guard whose
  # direction is a side effect of a default expansion is not a decision.
  if [[ -z "$n" || ! "$n" =~ ^[0-9]+$ ]]; then
    warn "[$agent] could not read the task store while checking loop '$key' — assuming ABSENT"
    return 1
  fi
  (( n > 0 ))
}

# Create the loops declared on ONE agent that are not already there.
#
# Emits, on stdout: zero or more "RETRY <command>" lines, then one
# "COUNTS <created> <existing> <errors>" line. Retries travel through stdout
# rather than a shared array because the caller consumes this function through a
# process substitution, i.e. a SUBSHELL — an array appended to in here would be
# discarded on return, and the end-of-run block would print an empty list beside a
# non-zero error count. That is the DIVE-2341 defect exactly (a real failure with
# nothing said about it last), reintroduced by a scoping mistake.
#
# Every write is shelled out through the public verb so a failure is contained the
# same way _compose_wire_role's are: a loop that will not install must not undo a
# roster that came up.
_compose_apply_loops() {
  local spec="$1" name="$2" self="$3"
  local created=0 existing=0 errors=0 loops
  loops=$(jq -c --arg n "$name" '(.agents[$n].loops // [])[]' <<<"$spec" 2>/dev/null || true)
  [[ -n "$loops" ]] || { printf 'COUNTS 0 0 0\n'; return 0; }

  local L pack lid title cron prompt ceiling key
  while IFS= read -r L; do
    [[ -n "$L" ]] || continue
    pack=$(jq    -r '.pack    // empty' <<<"$L")
    lid=$(jq     -r '.id      // empty' <<<"$L")
    title=$(jq   -r '.title   // empty' <<<"$L")
    cron=$(jq    -r '.cron    // empty' <<<"$L")
    prompt=$(jq  -r '.prompt  // empty' <<<"$L")
    ceiling=$(jq -r '.ceiling // empty' <<<"$L")
    key="${pack:-$lid}"

    if _compose_loop_present "$name" "$key" "$title"; then
      step "[$name] loop '$key' already present — leaving it alone"
      ((existing++)) || true
      continue
    fi

    if [[ -n "$pack" ]]; then
      # Marketplace pack: `loop install` owns the registry fetch, the skill
      # attach and the recurring job. Nothing about a pack is re-derived here.
      local -a largs=(loop install "$pack" "--onto=$name")
      [[ -n "$cron"    ]] && largs+=("--cron=$cron")
      [[ -n "$ceiling" ]] && largs+=("--ceiling=$ceiling")
      step "[$name] installing loop pack '$pack'"
      # </dev/null: the loop list is fed to this while via a here-string, and a
      # child that reads stdin would swallow the remaining loops — they would
      # vanish with no error, which is the silent half-provisioning this pass
      # exists to prevent.
      if bash "$self" "${largs[@]}" </dev/null >/dev/null 2>&1; then
        ((created++)) || true
      else
        warn "[$name] loop pack '$pack' failed to install"
        printf 'RETRY sudo 5dive loop install %s --onto=%s\n' "$pack" "$name"
        ((errors++)) || true
      fi
      continue
    fi

    # Inline loop -> the same recurring template `loop install` ends up writing.
    local body="${prompt}"
    [[ -n "$body" ]] && body+=$'\n\n'
    body+="— $(_compose_loop_marker "$lid") runs on '${cron}'."
    [[ -n "$ceiling" ]] && body+=" advisory budget: ${ceiling} tokens/run (bound hard with: 5dive usage budget $name)."
    step "[$name] creating loop '$lid' on '$cron'"
    if bash "$self" task add --materialized "--body=$body" "--recurring=$cron" \
         "--assignee=$name" --project=dive -- "$title" </dev/null >/dev/null 2>&1; then
      ((created++)) || true
    else
      warn "[$name] loop '$lid' failed to register — no recurring row was created for '$title' on '$cron'"
      printf "RETRY sudo 5dive up -f %s   # re-run; only the missing loop '%s' for %s is created\n" "${_COMPOSE_SPEC_FILE:-<spec>}" "$lid" "$name"
      ((errors++)) || true
    fi
  done <<<"$loops"
  printf 'COUNTS %s %s %s\n' "$created" "$existing" "$errors"
}

# DIVE-3998: apply a roster-wide harness override to an already-parsed spec.
#
# Every bundled team template hard-sets `defaults.type: claude`, which made a
# company import Claude-Code-only even though `agent create` has long accepted
# every harness in TYPE_BIN (codex, opencode, openclaw, hermes, grok, pi, devin,
# antigravity — read the map, do not re-inline the list). This rewrites the PARSED
# spec rather than each call site, so every downstream reader (create argv,
# _compose_wire_role's persona target, the ps view) sees one consistent type.
#
# It also drops Claude-only pins when the target is not claude. The templates
# carry `model: opus|sonnet` + `effort:`, which are Claude aliases: `agent
# config set effort=` REFUSES on a non-claude type (loud, harmless), but
# `model=` is accepted for codex/grok/antigravity and only charset-validated —
# so a resolved `claude-opus-5` would be written into a codex seat's runtime
# config and the agent would be quietly broken. Dropping the pin lets the
# target harness use its own default. A non-Claude model string (a full id, a
# `vendor/model` BYO string) is NOT a Claude alias and passes through.
_compose_apply_type_override() {
  local spec="$1" t="$2"
  jq --arg t "$t" '
    .defaults = ((.defaults // {}) + {type: $t})
    | .agents |= with_entries(
        .value.type = $t
        | if $t == "claude" then .
          else
            (if ((.value.model // "") | test("^(opus|sonnet|fable|haiku)$|^claude-"))
             then .value |= del(.model) else . end)
            | .value |= del(.effort)
          end
      )
  ' <<<"$spec"
}

# Names of the agents _compose_apply_type_override would strip a Claude-only
# model/effort pin from, comma-joined. Reported to the user: a silently dropped
# pin is the same class of defect as a silently kept one.
_compose_type_override_pins() {
  local spec="$1" t="$2"
  [[ "$t" == "claude" ]] && { printf ''; return 0; }
  jq -r '[ .agents | to_entries[]
           | select(((.value.model // "") | test("^(opus|sonnet|fable|haiku)$|^claude-"))
                    or ((.value.effort // "") | tostring | length > 0))
           | .key ] | join(", ")' <<<"$spec"
}

# Re-exec self via bash so we work whether the script was installed (+x) or
# invoked from a source checkout (no +x).
_compose_self() { realpath "${BASH_SOURCE[0]}"; }

# DIVE-4093 — a Distribution import must say whether authenticated-browser
# adapters are usable. The manifest declares only `browser: optional`; the CLI
# owns the fixed probe, so a marketplace YAML can never make us execute an
# arbitrary command. Empty means the team did not declare this capability.
_compose_browser_mode() {
  local spec="$1" self="$2" declared
  declared=$(jq -r '.team.capabilities.browser // empty' <<<"$spec" 2>/dev/null)
  [[ -n "$declared" ]] || { printf ''; return 0; }
  if bash "$self" browser --help </dev/null >/dev/null 2>&1; then
    printf 'browser+api'
  else
    printf 'api-only'
  fi
}

cmd_compose_up() {
  local file="" type_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    file="$2"; shift ;;
      --file=*)     file="${1#--file=}" ;;
      --type=*)     type_override="${1#--type=}" ;;
      --type)       type_override="$2"; shift ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive up [-f file] [--type=<harness>]
  Bring up agents declared in 5dive.yaml. Idempotent — existing agents are
  left alone, missing ones are created and started.
  Default file: 5dive.yaml or 5dive.yml in the current directory.

  --type=<harness>  Create the WHOLE roster on this harness, overriding the
                    spec's type:/defaults.type:. Known: ${!TYPE_BIN[*]}.
                    Claude-only model/effort pins are dropped when the target
                    is not claude. Omit the flag and nothing changes.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  # DIVE-3998: reject an unknown harness HERE — before the spec is read and
  # before ensure_state touches anything. Left to `agent create`, a typo'd
  # --type fails once per agent, midway through a partly-provisioned roster.
  if [[ -n "$type_override" ]]; then
    is_known_type "$type_override" \
      || fail "$E_NOT_FOUND" "unknown --type: $type_override (known: ${!TYPE_BIN[*]})"
  fi
  if [[ -z "$file" ]]; then
    file=$(_compose_default_file) \
      || fail "$E_NOT_FOUND" "no 5dive.yaml or 5dive.yml in $(pwd) — pass -f <file>"
  fi
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "spec file not found: $file"
  ensure_state

  local spec spec_dir self
  spec=$(_compose_parse "$file") || fail "$E_VALIDATION" "spec parse failed"
  if [[ -n "$type_override" ]]; then
    local _pins
    _pins=$(_compose_type_override_pins "$spec" "$type_override")
    spec=$(_compose_apply_type_override "$spec" "$type_override") \
      || fail "$E_VALIDATION" "could not apply --type=$type_override to the spec"
    step "harness override: creating the whole roster as '$type_override'"
    if [[ -n "$_pins" ]]; then
      warn "dropped Claude-only model/effort pins (not valid on '$type_override'): $_pins — the harness default applies; set one later with: 5dive agent config <name> set model=<id>"
    fi
  fi
  # DIVE-4103: what this team needs from the BOX, answered before anything is
  # provisioned. Never fatal — a missing capability names the reduced mode.
  _compose_requires_preflight "$spec"
  spec_dir=$(realpath "$(dirname "$file")")
  self=$(_compose_self)
  local _compose_browser_mode_value
  _compose_browser_mode_value=$(_compose_browser_mode "$spec" "$self")
  if [[ -n "$_compose_browser_mode_value" ]]; then
    step "capability preflight: publishing=$_compose_browser_mode_value (browser is optional; API adapters remain available)"
  fi
  # DIVE-4022: named here so a loop that fails to register can print the exact
  # re-run, not a `<spec>` placeholder the user has to translate.
  local _COMPOSE_SPEC_FILE="$file"

  local reg
  reg=$(registry_read)

  local names created=0 started=0 skipped=0 errors=0
  # DIVE-2341: names of agents this run brought up, so the end-of-run block can
  # re-derive their self-check state. Collected here rather than parsed out of the
  # child `agent create` output — that output is a clack render and parsing it would
  # break the moment the renderer changes.
  local -a _brought_up_names=()
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
      mapfile -t args < <(_compose_import_args "$agent_spec" "$name" "$pack_slug" "$spec_dir" "$type_override")
      bash "$self" agent import "${args[@]}" || brought_up=0
    else
      step "[$name] creating"
      mapfile -t args < <(_compose_create_args "$agent_spec" "$name" "$spec_dir")
      bash "$self" agent create "${args[@]}" || brought_up=0
    fi
    if (( brought_up )); then
      ((created++)) || true
      _brought_up_names+=("$name")
      # v2 role wiring (model/effort/org/instructions/goals). Best-effort: a
      # wiring hiccup must not fail the create/import that already succeeded.
      _compose_wire_role "$spec" "$name" "$spec_dir" "$self" || true
    else
      warn "[$name] $verb failed"
      ((errors++)) || true
    fi
  done

  # DIVE-4022 — declared loops, in a SECOND pass over the whole roster.
  #
  # Deliberately NOT folded into the create branch above, where _compose_wire_role
  # sits. Wiring runs on create only, which is right for a persona file that must
  # not double-append; it is wrong for loops. A user who adds a `loops:` block to a
  # company they already imported and re-runs `up` would get nothing — the roster
  # exists, so every agent takes the "already exists" branch and the new loops are
  # never seen. Reconciling over EVERY declared agent instead is what makes the key
  # declarative, and it is safe because _compose_loop_present makes the create
  # idempotent rather than the code path doing it.
  #
  # Ordering matters twice: after the create loop, because a loop needs its owner
  # to exist; before the summary, because the counts belong on the summary line.
  local loops_created=0 loops_existing=0 loops_errors=0
  local _lc _le _lerr _line _
  local -a _COMPOSE_LOOP_RETRY=()
  if [[ "$(jq -r '[.agents[] | (.loops // []) | length] | add // 0' <<<"$spec" 2>/dev/null || echo 0)" != "0" ]]; then
    tasks_db_init 2>/dev/null || true
    # Re-read: `reg` above is the PRE-run registry, so every agent this run just
    # created would read as absent and its loops would be skipped.
    local _reg_after; _reg_after=$(registry_read 2>/dev/null || echo '{}')
    for name in "${names[@]}"; do
      valid_name "$name" || continue
      # An agent that is not on the box owns nothing — a loop assigned to a name
      # that failed to create is a recurring row nobody will ever run.
      [[ "$(jq --arg n "$name" '.agents[$n] != null' <<<"$_reg_after")" == "true" ]] || continue
      while IFS= read -r _line; do
        case "$_line" in
          "COUNTS "*)
            read -r _ _lc _le _lerr <<<"$_line"
            loops_created=$((loops_created + _lc))
            loops_existing=$((loops_existing + _le))
            loops_errors=$((loops_errors + _lerr)) ;;
          "RETRY "*) _COMPOSE_LOOP_RETRY+=("${_line#RETRY }") ;;
        esac
      done < <(_compose_apply_loops "$spec" "$name" "$self")
    done
  fi
  # A loop that would not install must NOT fail the import — same rule, and the
  # same reason, as DIVE-3994's unset bot token and DIVE-2347's failed skill: the
  # roster is up and useful, and a marketplace fetch needs the network, which the
  # one-tap dashboard import cannot assume. It is reported last instead, with the
  # exact command, and it stays out of `errors`.

  # DIVE-2341 — SAY IT LAST, OR IT WAS NOT SAID.
  #
  # `agent create` already emits a correct self-check warning per agent ("no heartbeat
  # (agent is ASLEEP — won't self-act on board work)"). This row is not about its wording.
  # It is about WHERE it lands: each create prints a full skill-install render, so the
  # warning is buried mid-scroll and then followed by a cheerful summary. On a five-role
  # `team import` the user gets five buried warnings and one green `errors=0`, and the
  # last thing they read says nothing is wrong. Measured on the content-studio template:
  # five agents created, five asleep, summary `created=5 started=0 skipped=0 errors=0`.
  #
  # So re-derive the state from the REGISTRY (the thing that defines it) and restate it
  # after the summary. Nothing new is computed and nothing can fail a create — this is
  # display only, deliberately, so it cannot regress the path it describes.
  local -a _asleep=()
  local _n _hb _reg_now=""
  if (( ${#_brought_up_names[@]} > 0 )); then
    _reg_now="$(registry_read 2>/dev/null || echo '{}')"
    for _n in "${_brought_up_names[@]}"; do
      _hb=$(jq -r --arg n "$_n" '.agents[$n].heartbeat.enabled // false' <<<"$_reg_now" 2>/dev/null || echo false)
      [[ "$_hb" == "true" ]] || _asleep+=("$_n")
    done
  fi

  # DIVE-2347 — A FAILED SKILL INSTALL IS INVISIBLE TO THE `errors` COUNTER.
  #
  # `agent create` deliberately does NOT fail when a preseeded skill won't install
  # (the agent itself is up), so the failure never reaches `errors` and the summary
  # says `errors=0` over a red line the user just watched scroll past. Measured on
  # the content-studio template, whose writer and seo roles both request a skill
  # that is not in the repo the template names: two `error:` lines, then `errors=0`.
  #
  # Same shape and same remedy as the asleep row above: re-derive from the INSTALLED
  # SET (`_skill_list_json`, the same reader `skill list` uses) rather than trusting
  # the create's exit code, and restate it after the summary. A spec entry may be
  # `owner/repo:id`, but only the bare id is ever the installed directory name.
  # Display only — it cannot regress the create path it describes.
  # >>> DIVE-2347 degraded-skill derivation (extracted verbatim by tests/compose_skill_degraded_unit.sh)
  local -a _degraded=()
  local _want _have _miss
  for _n in "${_brought_up_names[@]+"${_brought_up_names[@]}"}"; do
    _want=$(jq -r --arg n "$_n" '(.agents[$n].skills // [])[] | sub("^.*:";"")' <<<"$spec" 2>/dev/null || true)
    [[ -n "$_want" ]] || continue
    _have=$(_skill_list_json "$_n" 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
    while IFS= read -r _miss; do
      [[ -n "$_miss" ]] || continue
      grep -qxF -- "$_miss" <<<"$_have" || _degraded+=("$_n $_miss")
    done <<<"$_want"
  done
  # <<< DIVE-2347 degraded-skill derivation

  # DIVE-3994: the roles whose optional bot token was unset, as reported by the
  # parser. Restricted to agents this run actually brought up — a re-run over an
  # already-imported company must not re-announce a channel it did not touch.
  local _no_channel_names="" _cand
  for _cand in $(jq -r '(.channels_dropped // [])[].agent' <<<"$spec" 2>/dev/null); do
    for _n in "${_brought_up_names[@]+"${_brought_up_names[@]}"}"; do
      [[ "$_n" == "$_cand" ]] && { _no_channel_names+="${_no_channel_names:+ }$_cand"; break; }
    done
  done

  if (( JSON_MODE )); then
    ok "" '{file:$f, created:($c|tonumber), started:($s|tonumber), skipped:($k|tonumber), errors:($e|tonumber), asleep:$a, skills_failed:($sf|tonumber), degraded:$d, no_channel:$nc, loops:{created:($lc|tonumber), existing:($le|tonumber), errors:($lerr|tonumber), retry:$lr}}' \
      --arg f "$file" --arg c "$created" --arg s "$started" --arg k "$skipped" --arg e "$errors" \
      --argjson a "$(printf '%s\n' "${_asleep[@]+"${_asleep[@]}"}" | jq -R . | jq -sc 'map(select(length>0))')" \
      --arg sf "${#_degraded[@]}" \
      --argjson d "$(printf '%s\n' "${_degraded[@]+"${_degraded[@]}"}" | jq -R 'select(length>0) | split(" ") | {agent:.[0], skill:.[1]}' | jq -sc .)" \
      --argjson nc "$(printf '%s\n' $_no_channel_names | jq -R . | jq -sc 'map(select(length>0))')" \
      --arg lc "$loops_created" --arg le "$loops_existing" --arg lerr "$loops_errors" \
      --argjson lr "$(printf '%s\n' "${_COMPOSE_LOOP_RETRY[@]+"${_COMPOSE_LOOP_RETRY[@]}"}" | jq -R . | jq -sc 'map(select(length>0))')"
  else
    echo "OK — applied $file: created=$created started=$started skipped=$skipped errors=$errors asleep=${#_asleep[@]} skills_failed=${#_degraded[@]} loops=${loops_created}(+${loops_existing} already there)"
    if (( ${#_asleep[@]} > 0 )); then
      echo ""
      echo "── ${#_asleep[@]} agent(s) are ASLEEP — created, but they will not self-act on board work:"
      for _n in "${_asleep[@]}"; do
        echo "     sudo 5dive heartbeat on $_n"
      done
      echo "   (each line above is the exact command; nothing else is needed)"
    fi
    if (( ${#_degraded[@]} > 0 )); then
      echo ""
      echo "── ${#_degraded[@]} skill(s) FAILED to install — those agents are up but DEGRADED:"
      for _n in "${_degraded[@]}"; do
        echo "     sudo 5dive agent skill ${_n%% *} add --skill=${_n##* }"
      done
      echo "   (if a skill is missing from its source repo, the spec is wrong — not your box)"
    fi
    # DIVE-3994: ONE line for the agents that came up without a channel because
    # their optional bot token was not set, and the exact command to add one.
    # Same "say it last" reason as the two blocks above.
    if [[ -n "$_no_channel_names" ]]; then
      echo ""
      echo "── agent(s) created WITHOUT a channel (no bot token was set): $_no_channel_names"
      for _n in $_no_channel_names; do
        echo "     sudo 5dive agent config $_n set telegram.token=<bot-token> && sudo 5dive agent config $_n set channels=telegram"
      done
    fi
    # DIVE-4022 — same "say it last" rule for a loop that did not install. It is
    # kept OUT of `errors` (the roster is up and working), so this block is the
    # only place a user learns the company came up with less recurring work than
    # the spec declared.
    if (( ${#_COMPOSE_LOOP_RETRY[@]} > 0 )); then
      echo ""
      echo "── ${#_COMPOSE_LOOP_RETRY[@]} declared loop(s) did NOT install — those roles have less recurring work than the spec says:"
      local _r
      for _r in "${_COMPOSE_LOOP_RETRY[@]}"; do
        echo "     $_r"
      done
    fi
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
  tasks_db_init 2>/dev/null || true   # DIVE-4022: declared loops live in the task store

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
    # DIVE-4022: drop this agent's DECLARED loops before the seat goes. `agent rm`
    # deletes the registry entry and the org row but NOT recurring templates, so a
    # torn-down company would leave its templates behind, still materializing a new
    # instance every slot for an assignee that no longer exists. Scoped hard: only
    # kind='recurring' rows for THIS assignee that carry a declared-loop marker for
    # an id this spec names — a hand-created recurring row, or one this spec never
    # declared, is not ours to delete.
    _compose_down_loops "$spec" "$name"
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
  ensure_state_ro   # read-only: fleet export must work for non-root agents
  tasks_db_init 2>/dev/null || true   # DIVE-4022: loops are read from the task store
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
    local loops; loops=$(_compose_export_loops "$name")
    # Assemble one agent object, dropping empty fields.
    local obj
    obj=$(jq -n \
      --arg type "$type" --arg channels "$channels" --arg workdir "$workdir" \
      --arg profile "$profile" --arg model "$model" --arg effort "$effort" \
      --arg role "$role" --arg mgr "$mgr" --argjson loops "${loops:-[]}" '
      {type:$type}
      | (if $channels != "" then .channels = $channels else . end)
      | (if $workdir  != "" then .workdir  = $workdir  else . end)
      | (if $profile  != "" then .auth_profile = $profile else . end)
      | (if $model    != "" then .model    = $model    else . end)
      | (if $effort   != "" then .effort   = $effort   else . end)
      | (if $role     != "" then .role     = $role     else . end)
      | (if $mgr      != "" then .reports_to = $mgr    else . end)
      | (if ($loops | length) > 0 then .loops = $loops else . end)')
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

# DIVE-4022 — remove the recurring templates `up` created for ONE agent.
#
# Deletes the TEMPLATE rows only, exactly as `loop uninstall` does; already
# materialized instances are separate rows and are left for their owner. A pack
# loop is removed through `loop uninstall`, so the pack path has one implementation
# on the way out as well as on the way in.
_compose_down_loops() {
  local spec="$1" name="$2" self
  self=$(_compose_self)
  local L pack lid marker ids
  while IFS= read -r L; do
    [[ -n "$L" ]] || continue
    pack=$(jq -r '.pack // empty' <<<"$L")
    lid=$(jq  -r '.id   // empty' <<<"$L")
    if [[ -n "$pack" ]]; then
      bash "$self" loop uninstall "$pack" "--from=$name" </dev/null >/dev/null 2>&1 \
        || warn "[$name] could not uninstall loop pack '$pack' (remove by hand: sudo 5dive loop uninstall $pack --from=$name)"
      continue
    fi
    [[ -n "$lid" ]] || continue
    marker=$(_compose_loop_marker "$lid")
    ids=$(db "SELECT id FROM tasks
              WHERE kind='recurring' AND assignee=$(sqlq "$name")
                AND body LIKE '%'||$(sqlq "$marker")||'%';" 2>/dev/null || true)
    [[ -n "$ids" ]] || continue
    local idlist; idlist=$(printf '%s,' $ids); idlist="${idlist%,}"
    db "DELETE FROM tasks WHERE id IN (${idlist}) AND kind='recurring';" >/dev/null 2>&1 \
      || warn "[$name] could not delete recurring template(s) for loop '$lid'"
    step "[$name] removed declared loop '$lid'"
  done < <(jq -c --arg n "$name" '(.agents[$n].loops // [])[]' <<<"$spec" 2>/dev/null || true)
}

# DIVE-4022 — the export half of the round-trip.
#
# `5dive export` dumps the fleet so a running org can be forked into a template.
# With loops declared but not exported, the dump would claim a company that has
# recurring work as one that has none — export would silently lie about the fleet
# it dumped, and a re-import would rebuild the idle roster this row exists to end.
#
# Read from the tasks table (the thing that DEFINES a loop) rather than from any
# spec file, so hand-made and `loop install`-made recurring work round-trips too.
# Shaped in SQL as JSON: the default sqlite3 list output is pipe-separated, and a
# task title or body may legitimately contain a pipe or a newline.
#
#   body carries "installed loop: <slug> (5dive marketplace)"  -> pack: <slug>
#   body carries "declared loop: <id> (5dive.yaml)"            -> id: <id>
#   neither                                                    -> id derived from
#     the title, so a hand-created recurring row still exports as a real loop.
#     The derivation is stable, and _compose_loop_present also matches on TITLE,
#     so re-importing this dump onto the same fleet finds the row and does not
#     duplicate it.
_compose_export_loops() {
  local agent="$1" rows
  rows=$(db "SELECT COALESCE(json_group_array(json_object(
                'title', title, 'body', COALESCE(body,''), 'cron', COALESCE(schedule,''))), '[]')
             FROM tasks
             WHERE kind='recurring' AND assignee=$(sqlq "$agent");" 2>/dev/null | head -1)
  [[ -n "$rows" ]] || { printf '[]'; return 0; }
  # DIVE-4022 iteration 2 — the shaper and the PARSER are two halves of one
  # contract, and every measurement in iteration 1 read only this half's output.
  # Fed back through `5dive ps`, the live board refused the whole document three
  # ways. Each is fixed HERE, in the shaper, because a re-import must not be the
  # place a user discovers that their export was unusable:
  #
  #  (1) A `kind='recurring'` row with an EMPTY schedule is not a loop. The
  #      materializer's `_cron_matches` needs 5 fields and returns 1 on zero, so
  #      such a row can never fire — it is a template that does nothing. Exporting
  #      it as an inline loop emitted a cron-less loop the parser rejects, and the
  #      parse is WHOLE-DOCUMENT, so one dead row refused the entire company. It
  #      is SKIPPED and REPORTED rather than exported. The alternative — teaching
  #      the parser to accept a cadence-less inline loop — was rejected: it would
  #      let `5dive up` create dead templates BY DESIGN, which is the opposite of
  #      the "roster that sits idle" this row exists to end. (The pack form keeps
  #      cron optional: a pack carries its own cadence and `loop install` sets it.)
  #  (2) A title carrying no [a-z0-9] at all — any non-Latin script, or symbols
  #      only — slugifies to the empty string, and `id: ""` fails the parser's
  #      "needs either pack: or id:". Such a title falls back to a stable digest.
  #  (3) Two titles agreeing on their first 64 slug characters derive the SAME id
  #      and the parser answers "duplicate loop key". The live fleet already has
  #      many ids sitting exactly at that cap. A collision takes a digest suffix,
  #      applied in list order so the output is deterministic.
  #
  # The digest is a djb2 over the FULL title, so it distinguishes titles that the
  # cap made identical and is stable across exports of an unchanged board.
  local env
  env=$(jq -c '
    def h: explode | reduce .[] as $c (5381; (. * 33 + $c) % 4294967296) | tostring;
    def slugify: ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "") | .[0:64] | sub("-+$"; "");
    # Shape each row, tagging the ones that cannot be represented at all.
    [ .[] |
      ([.body | scan("installed loop: ([a-z0-9-]+) \\(5dive marketplace\\)")] | first | first) as $pack
      | ([.body | scan("declared loop: ([a-z0-9-]+) \\(5dive\\.yaml\\)")] | first | first) as $decl
      | if $pack != null
        then {kind:"pack", out: ({pack: $pack} + (if .cron != "" then {cron: .cron} else {} end))}
        elif .cron == ""
        then {kind:"skip", title: .title}
        else ((.title | slugify) as $slug
              | (if $decl != null then $decl
                 elif $slug == "" then "loop-" + (.title | h)
                 else $slug end) as $id
              | {kind:"inline", declared: ($decl != null), id: $id, title: .title,
                 out: {id: $id, title: .title, cron: .cron}})
        end ]
    # Second pass: de-duplicate derived ids in list order. A key already claimed
    # by an earlier entry takes a digest suffix, trimmed so the id stays inside
    # the parsers 64-character limit.
    | reduce .[] as $e ({seen: {}, loops: [], skipped: [], dupes: []};
        if $e.kind == "skip" then .skipped += [$e.title]
        elif $e.kind == "pack" then
          (if .seen[$e.out.pack] then .dupes += [$e.out.pack]
           else .seen[$e.out.pack] = true | .loops += [$e.out] end)
        else
          (if .seen[$e.id] | not then .seen[$e.id] = true | .loops += [$e.out]
           else (($e.title | h) as $d
                 | (($e.id[0:(63 - ($d | length))]) + "-" + $d) as $alt
                 | if .seen[$alt] then .dupes += [$e.title]
                   else .seen[$alt] = true | .loops += [$e.out + {id: $alt}] end)
           end)
        end)
    | {loops: .loops, skipped: .skipped, dupes: .dupes}' <<<"$rows" 2>/dev/null) || env=""
  [[ -n "$env" ]] || { printf '[]'; return 0; }
  local skipped
  skipped=$(jq -r '.skipped[]' <<<"$env" 2>/dev/null || true)
  if [[ -n "$skipped" ]]; then
    local t
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      warn "[$agent] recurring row '$t' has no cadence — it can never fire, so it is not exported as a loop"
    done <<<"$skipped"
  fi
  local dupes
  dupes=$(jq -r '.dupes[]' <<<"$env" 2>/dev/null || true)
  if [[ -n "$dupes" ]]; then
    local d
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      warn "[$agent] a second recurring row indistinguishable from '$d' is not exported (same key and same title)"
    done <<<"$dupes"
  fi
  jq -c '.loops' <<<"$env"
}

# -------- team templates come from the MARKETPLACE REGISTRY (DIVE-4196) -----
#
# Curated team templates live in the same curated GitHub repo the character packs
# come from — <org>/5dive-marketplace, under teams/ — and the CLI reads them there,
# live. They are no longer bundled with this binary.
#
# WHY. They used to ship inside this repo and be staged by install.sh AT INSTALL
# TIME ONLY. So publishing a template needed a PR here, an edit to the
# installer's hand-maintained staging list, a release cut and a self-update on
# every box — and even then an ALREADY-installed box never received it. Measured
# 2026-09-10: this host ran 0.29.0 with 4 staged templates while the tag shipped
# 6 (DIVE-4141). Two of the three template defects in the record are that shape:
# a slug in index.json that install.sh never staged, advertised by `team ls` and
# refused on import (#807 deploy-team, #808 distribution). Reading the registry
# deletes the whole class: one declaration, no staging list to drift from it, and
# a published template reaches every box on the next `team ls` with no cut.
#
# WHAT IT COSTS, stated rather than hidden: there is no bundled copy to fall back
# to, so a slug import needs the network. A PATH still resolves as a path
# (`5dive team import ./my-team.5dive.yaml`) — that is the offline and BYO route,
# and it is the only fallback.
TEAM_SCHEMA_MAX=2

# Registry ROOT (not the teams/ dir): index entries carry a repo-relative
# `path`, so root + path is the one place the layout is written down.
# Same one definition the packs path reads (header.sh: FIVE_MARKETPLACE_REPO).
_teams_registry_base() { _marketplace_raw_base; }

# Fetch one registry object, preserving the failure class so a transient fetch
# failure is never reported as the much stronger claim that the slug does not
# exist. Returns 0=2xx, 1=404, 2=other HTTP, 3=timeout, 4=transport.
# Deliberately self-contained rather than reusing cmd_pack.sh's twin: harnesses
# source this file alone, and a cross-file dependency would make them red on a
# seam that has nothing to do with what they grade.
_teams_get() {
  local url="$1" out="$2" http rc
  if http=$(curl -sSL --max-time 20 -o "$out" -w '%{http_code}' "$url" 2>/dev/null); then
    case "$http" in 2??) return 0 ;; 404) return 1 ;; *) return 2 ;; esac
  else
    rc=$?; (( rc == 28 )) && return 3; return 4
  fi
}

# Fetch the index. It is NOT memoised in a variable, and the reason is the same
# subshell rule that _team_resolve_template documents below: every caller reads
# this through `idx=$(_teams_registry_index)`, a command substitution, so an
# assignment made in here happens in the subshell and is discarded. A cache
# written that way is inert — worse than none, because a green "fetched once"
# arm can only be written by calling this function in a shape no caller uses.
#
# So the index is CARRIED instead of cached: a caller fetches it once and passes
# it to _team_resolve_template, which is what keeps `team ps` at one index round
# trip instead of one per slug. Nothing is written to disk either: a cache on
# disk is a second thing that can be stale, which is the defect this row exists
# to remove.
_teams_registry_index() {
  local tmp rc; tmp=$(mktemp)
  # CAPTURE BEFORE BRANCHING. `$?` read inside `if ! cmd; then` is the status
  # the `!` produced, not the one the command exited with — it is 0 exactly when
  # the command failed. Written that way this returned 0-with-empty-output on
  # every network failure, and the caller then reported a transport error as
  # "no such template", which is the one conflation this path exists to avoid.
  _teams_get "$(_teams_registry_base)/teams/index.json" "$tmp"; rc=$?
  if (( rc != 0 )); then rm -f "$tmp"; return "$rc"; fi
  if ! jq -e '.companies | type == "array"' >/dev/null 2>&1 <"$tmp"; then
    rm -f "$tmp"; return 5
  fi
  cat "$tmp"; rm -f "$tmp"
}

# One sentence per failure class, so "cannot reach the registry" never reads as
# "that template does not exist".
_teams_index_diag() {
  case "$1" in
    1) echo "the registry index is missing (404 at $(_teams_registry_base)/teams/index.json)" ;;
    2) echo "the registry returned an HTTP error" ;;
    3) echo "the registry fetch timed out" ;;
    5) echo "the registry index is malformed (no companies[])" ;;
    *) echo "the registry could not be reached (network/transport)" ;;
  esac
}

# THE SCHEMA GATE. This is the one thing bundling gave away for free: a template
# and the CLI that read it shipped in the same artifact, so a template could not
# declare a schema this binary does not understand. Publishing to a registry
# decouples them, so the CLI has to say it itself — and it has to NAME the
# version, because "unsupported template" with no number tells the customer
# nothing they can act on and half-parsing it is worse than refusing.
#
# Applied to a --path import too, not just a slug: the hazard is the FILE, and a
# newer template handed over on disk is the same file.
_team_schema_version() {
  sed -n 's/^version:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" | head -1
}
_team_assert_schema() {
  local file="$1" label="$2" v
  v=$(_team_schema_version "$file")
  # No `version:` at all is a v1 template; the parser has always owned that case
  # and this gate must not change its answer.
  [[ -n "$v" ]] || return 0
  if (( v > TEAM_SCHEMA_MAX )); then
    fail "$E_USAGE" "template '$label' declares team schema v$v; 5dive $FIVE_VERSION reads up to v$TEAM_SCHEMA_MAX. Upgrade first: sudo 5dive self-update"
  fi
}

# 5dive team import <slug|path> — resolve a curated/bundled template (or a path)
# and bring the whole org up via the existing compose engine. A thin, honest
# wrapper over `up`: the heavy lifting (idempotent create + v2 wiring) is shared.
#
# DIVE-3994 — this verb is now reachable from the DASHBOARD (the API exec
# allowlist gates `team` to exactly `import`), so it must work with no shell
# behind it:
#   * no env var is required — an unset optional bot token lands the role
#     channel-less instead of killing the import (see _compose_parse),
#   * --telegram-token= supplies the ONE optional company channel (the lead's)
#     without the caller exporting anything. `-` reads it from stdin, which is
#     the form the browser path is forced to use so a bot token never enters
#     argv (and thus never reaches shelld's audit log or /proc/<pid>/cmdline) —
#     same rule as `agent cos set --token=-` and `--api-key=-`.
#
# DIVE-3998: the usage text was inline in the subcommand switch, so it was
# reachable as `5dive team --help` but NOT as `5dive team import --help` —
# there the flag loop hit `-*)` and answered "unknown flag: --help". Naming the
# text lets the import loop print the same thing, which matters now that the
# flags it documents (--type, --telegram-token) live on `team import`.
_team_usage() {
  cat >&2 <<HELP
usage: 5dive team import <slug|path> [--auth-profile=<name>] [--type=<harness>]
                                   [--telegram-token=<bot-token>|-]
       5dive team ps [<slug|path>] [--type=<harness>]
       5dive team ls
  Provision a whole company-structure template in one call (wraps 5dive up).
  <slug> resolves in the marketplace registry (<org>/5dive-marketplace, teams/),
  read live — a template published there works on this box with no update.
  A path is used as-is, and is the offline / bring-your-own route.

  --type=<harness>  Create the whole roster on this harness instead of the
                    template's own (every bundled template says claude).
                    Known: ${!TYPE_BIN[*]}.
  --telegram-token=<tok>    optional bot token for the company LEAD, the single
                            point of contact with you. '-' reads it from stdin.
                            Omit it and the whole company comes up channel-less
                            — that is a supported path, not an error.
HELP
}

# <slug|path> [<index-json>] -> a readable local file. A path is used as-is; a
# slug is resolved through the registry index and fetched. Return codes are
# distinct on purpose, so the caller can tell "no such slug" from "could not
# ask".
#
# The optional second argument is an ALREADY-FETCHED index, and it is how a
# caller that resolves more than one slug (`team ps` with no slug) stays at one
# index round trip: the index cannot be memoised here, because every caller
# reads this function through a command substitution and an assignment made in
# a subshell is discarded. Omit it and this fetches the index itself, which is
# right for the one-slug callers (`team import <slug>`, `team ps <slug>`) and
# keeps a PATH resolving with no network at all.
#    1     = the fetched, valid index has no such slug — the ONLY code that
#            licenses telling a customer their template does not exist
#    3     = the index entry carries no path (a broken registry, not a bad call)
#    4     = the template body itself could not be fetched
#   21..25 = the INDEX could not be read; the low digit is _teams_get's class
#
# The class rides in the RETURN CODE and not in a variable on purpose: every
# caller reads this function through a command substitution, which is a
# subshell, so a variable set in here is gone by the time the caller looks at
# it. A diagnostic that silently empties is worse than none — it prints
# "unknown" and reads like a bug in the customer's command.
_team_resolve_template() {
  local ref="$1" idx="${2-}"
  if [[ -f "$ref" ]]; then
    printf '%s' "$ref"
    return 0
  fi
  local rc entry path dest
  if [[ -z "$idx" ]]; then
    idx=$(_teams_registry_index); rc=$?   # never inside `if !` — see _teams_registry_index
    if (( rc != 0 )); then return $(( 20 + rc )); fi
  fi
  entry=$(jq -e --arg s "$ref" '.companies[] | select(.slug==$s)' <<<"$idx" 2>/dev/null) || return 1
  path=$(jq -r '.path // empty' <<<"$entry"); [[ -n "$path" ]] || return 3
  dest="$(mktemp -d)/${ref}.5dive.yaml"
  _teams_get "$(_teams_registry_base)/$path" "$dest"; rc=$?
  if (( rc != 0 )); then rm -rf "$(dirname "$dest")"; return 4; fi
  printf '%s' "$dest"
}

# The message a caller shows when _team_resolve_template did not produce a file.
_team_resolve_fail() {
  local ref="$1" rc="$2" why
  case "$rc" in
    1) fail "$E_NOT_FOUND" "no template '$ref' in $(_marketplace_slug) (try: 5dive team ls)" ;;
    3) fail "$E_NOT_FOUND" "the registry lists '$ref' but the entry carries no path — the registry index is broken, not your command" ;;
    4) why="the template body could not be fetched from the registry" ;;
    2?) why=$(_teams_index_diag "$(( rc - 20 ))") ;;
    *) why="unknown" ;;
  esac
  fail "$E_NOT_FOUND" "could not resolve template '$ref' — ${why}. This is NOT a claim that '$ref' does not exist; retry, or import a local file: 5dive team import ./<file>.5dive.yaml"
}

cmd_team() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    import) : ;;
    ps)
      if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat >&2 <<'HELP'
usage: 5dive team ps [<slug|path>] [--type=<harness>]
  Show a marketplace team's roster, state, scheduled loops and capability mode.
  With no slug, show every registry team whose complete roster is installed.
HELP
        return 0
      fi
      local ps_ref="${1:-}"
      if [[ -n "$ps_ref" && "$ps_ref" != --* ]]; then
        shift || true
        local ps_file ps_rc
        ps_file=$(_team_resolve_template "$ps_ref") || { ps_rc=$?; _team_resolve_fail "$ps_ref" "$ps_rc"; }
        _team_assert_schema "$ps_file" "$ps_ref"
        cmd_compose_ps -f "$ps_file" "$@"
        return 0
      fi

      # A slug-free status command is the receipt shown after a one-command
      # marketplace import. Detect complete installed rosters from registry
      # state; do not persist a mutable "last import" pointer that can lie after
      # a second team is installed or removed.
      local ps_idx ps_rc ps_reg ps_slug ps_candidate ps_spec ps_res_rc ps_why
      local -a ps_matches=() ps_names=()
      local ps_unreadable=0
      ps_idx=$(_teams_registry_index); ps_rc=$?
      if (( ps_rc != 0 )); then
        fail "$E_NOT_FOUND" "cannot list installed teams — $(_teams_index_diag "$ps_rc"). Name a template instead: 5dive team ps <slug|path>"
      fi
      ps_reg=$(registry_read)
      while IFS= read -r ps_slug; do
        [[ -n "$ps_slug" ]] || continue
        # THE INDEX IS CARRIED IN, not refetched per slug: this loop is the one
        # caller that resolves N slugs, so `$ps_idx` here is what keeps the
        # whole command at a single index round trip.
        #
        # And the RETURN CODE is read rather than `|| continue`d. `|| continue`
        # swallowed rc 4 (the template BODY could not be fetched) and rc 21..25
        # (the index could not be read) identically to rc 1 (no such slug) — so
        # a dropped connection came out the bottom of this loop as the much
        # stronger claim that no roster is installed, which is the exact
        # conflation the rest of this path exists to remove, one level up.
        ps_candidate=$(_team_resolve_template "$ps_slug" "$ps_idx"); ps_res_rc=$?
        if (( ps_res_rc != 0 )); then
          case "$ps_res_rc" in
            1) : ;;   # the index named it and it is gone: genuinely absent, skip
            3) warn "registry entry '$ps_slug' carries no path — skipping it (the registry index is broken, not your command)" ;;
            4) ps_unreadable=$((ps_unreadable+1))
               ps_why="the template body could not be fetched from the registry"
               warn "could not read template '$ps_slug' — ${ps_why}; its roster is not counted here" ;;
            2?) ps_unreadable=$((ps_unreadable+1))
                ps_why=$(_teams_index_diag "$(( ps_res_rc - 20 ))")
                warn "could not read template '$ps_slug' — ${ps_why}; its roster is not counted here" ;;
            *) ps_unreadable=$((ps_unreadable+1))
               ps_why="the template could not be read (rc=$ps_res_rc)"
               warn "could not read template '$ps_slug' — ${ps_why}; its roster is not counted here" ;;
          esac
          continue
        fi
        # A registry template this binary cannot read is skipped, not fatal: the
        # question here is "which rosters are installed", and one unreadable
        # template must not hide the ones that are.
        [[ "$(_team_schema_version "$ps_candidate")" -le "$TEAM_SCHEMA_MAX" ]] 2>/dev/null || continue
        ps_spec=$(TEAM_AUTH_PROFILE="${TEAM_AUTH_PROFILE:-__team_ps__}" _compose_parse "$ps_candidate" 2>/dev/null) || continue
        if jq -e --argjson reg "$ps_reg" \
          '(.agents | length) > 0 and ([.agents | keys[] as $n | $reg.agents[$n] != null] | all)' \
          <<<"$ps_spec" >/dev/null; then
          ps_matches+=("$ps_candidate"); ps_names+=("$ps_slug")
        fi
      done < <(jq -r '.companies[].slug' <<<"$ps_idx")
      # NOTHING MATCHED — and the two reasons are not the same answer. If any
      # template could not be READ, "no roster is installed" is a claim this
      # command did not earn: it never got to look. Say which it was.
      if (( ${#ps_matches[@]} == 0 )); then
        if (( ps_unreadable > 0 )); then
          fail "$E_NOT_FOUND" "could not determine which teams are installed — ${ps_why} ($ps_unreadable of the registry's templates could not be read). This is NOT a claim that no roster is installed; retry, or name one: 5dive team ps <slug|path>"
        fi
        fail "$E_NOT_FOUND" "no complete team roster from $(_marketplace_slug) is installed (try: 5dive team import <slug>)"
      fi
      local ps_i=0
      for ps_file in "${ps_matches[@]}"; do
        if (( ${#ps_matches[@]} > 1 )); then
          echo "TEAM  ${ps_names[$ps_i]}"
        fi
        cmd_compose_ps -f "$ps_file" "$@"
        ps_i=$((ps_i+1))
      done
      return 0 ;;
    ls|list)
      # Read live from the registry. A template published there is listed here
      # on the next call, on a box that has not been updated — which is the whole
      # point of the move (DIVE-4196).
      local ls_idx ls_rc
      ls_idx=$(_teams_registry_index); ls_rc=$?
      if (( ls_rc != 0 )); then
        fail "$E_NOT_FOUND" "cannot read the team registry — $(_teams_index_diag "$ls_rc"). A local file still imports: 5dive team import ./<file>.5dive.yaml"
      fi
      echo "Available templates ($(_marketplace_slug) → teams/):"
      # A template the registry advertises but this binary cannot read is LISTED
      # and marked, not hidden: a customer who sees nothing concludes the
      # registry is empty, and the actionable fact is that their CLI is old.
      jq -r --argjson max "$TEAM_SCHEMA_MAX" '
        .companies[]
        | "  \(.slug)\t\(.size // "?") roles\t\(.description // .name // "")\(if (.schemaVersion // 1) > $max then "   [needs a newer 5dive: schema v\(.schemaVersion)]" else "" end)"
      ' <<<"$ls_idx" | column -t -s$'\t' 2>/dev/null || jq -r '.companies[].slug' <<<"$ls_idx"
      return 0 ;;
    -h|--help|"" )
      _team_usage
      return 0 ;;
    *) fail "$E_USAGE" "unknown team subcommand: $sub (try: import, ps, ls)" ;;
  esac

  local ref="" profile="" type_override="" tg_token="" tg_token_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth-profile=*) profile="${1#--auth-profile=}" ;;
      --auth-profile)   profile="$2"; shift ;;
      --telegram-token=*) tg_token="${1#--telegram-token=}"; tg_token_set=1 ;;
      --telegram-token)   tg_token="$2"; tg_token_set=1; shift ;;
      # DIVE-3998: forwarded verbatim to `up`, which owns the validation and
      # the override itself. This wrapper stays thin on purpose.
      --type=*)         type_override="${1#--type=}" ;;
      --type)           type_override="$2"; shift ;;
      -h|--help)        _team_usage; return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$ref" ]] && ref="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive team import <slug|path>"

  local file="" resolve_rc=0
  file=$(_team_resolve_template "$ref") || { resolve_rc=$?; _team_resolve_fail "$ref" "$resolve_rc"; }
  # Refuse a template this binary cannot read BEFORE the parser sees it. A
  # half-parsed newer schema comes up as a roster missing whatever the new keys
  # wired, which is worse than not importing at all.
  _team_assert_schema "$file" "$ref"

  # --auth-profile overrides the template's ${TEAM_AUTH_PROFILE} default.
  #
  # DIVE-4103: a template that never references the var takes nothing from the
  # flag, and passing it read as "the roster is on that account" when the seats
  # were in fact created unpinned. A silently inert flag on a verb you run once
  # per company is an account you think you chose — same rule as `--pr-title`
  # without `--open-pr` in `5dive push`. Warn rather than refuse: the import is
  # correct, only the caller's belief about it was not.
  if [[ -n "$profile" ]]; then
    export TEAM_AUTH_PROFILE="$profile"
    _compose_spec_pins_auth_profile "$file" || warn \
      "--auth-profile=$profile has no effect on this template — it does not pin an account (its seats come up with deferred auth, which is what lets a flagless one-tap import work). The roster still comes up; sign each seat in afterwards with: 5dive agent auth <name>"
  fi

  # The lead's optional channel. Curated templates read it as ${TEAM_TG_TOKEN}
  # — ONE token for the whole company (a customer talks to the lead; the rest of
  # the roster is reachable in the dashboard and via `5dive agent send`).
  # `-` = read from stdin so the secret never enters argv.
  if (( tg_token_set )); then
    if [[ "$tg_token" == "-" ]]; then
      IFS= read -r tg_token || true
    fi
    [[ -n "$tg_token" ]] && export TEAM_TG_TOKEN="$tg_token"
  fi

  step "importing team from $file"
  local -a _up_args=(-f "$file")
  [[ -n "$type_override" ]] && _up_args+=("--type=$type_override")
  cmd_compose_up "${_up_args[@]}"
}

cmd_compose_ps() {
  local file="" type_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)    file="$2"; shift ;;
      --file=*)     file="${1#--file=}" ;;
      --type=*)     type_override="${1#--type=}" ;;
      --type)       type_override="$2"; shift ;;
      -h|--help)
        # NO BACKTICKS AND NO $(...) IN THIS HEREDOC. The delimiter is unquoted
        # on purpose (the sibling helps interpolate ${!TYPE_BIN[*]}), so a
        # backtick is a command substitution: `up --type=<harness>` got RUN, and
        # `<harness>` inside it is a redirection — bash printed a syntax error
        # above the usage text and swallowed the phrase. shellcheck SC1073
        # caught it; it is a runtime defect, not a lint.
        cat >&2 <<HELP
usage: 5dive ps [-f file] [--type=<harness>]
  Show status of agents declared in 5dive.yaml.

  --type=<harness>  Read the spec the way 'up --type=<harness>' would. Pass the
                    same flag you brought the roster up with, or the 'type'
                    column reports the spec's own harness for agents created on
                    another one.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  # DIVE-3998: `ps` reports the DECLARED type straight out of the spec. Without
  # this the column contradicts a roster brought up with `up --type=` — it would
  # say claude for agents that are codex, which is drift reported where there is
  # none. Same guard as `up`: an unknown harness is a usage error, not a column.
  if [[ -n "$type_override" ]]; then
    is_known_type "$type_override" \
      || fail "$E_NOT_FOUND" "unknown --type: $type_override (known: ${!TYPE_BIN[*]})"
  fi
  if [[ -z "$file" ]]; then
    file=$(_compose_default_file) \
      || fail "$E_NOT_FOUND" "no 5dive.yaml or 5dive.yml in $(pwd) — pass -f <file>"
  fi
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "spec file not found: $file"
  ensure_state_ro   # read-only: compose ps must work for non-root agents

  local spec self browser_mode
  spec=$(_compose_parse "$file") || fail "$E_VALIDATION" "spec parse failed"
  if [[ -n "$type_override" ]]; then
    spec=$(_compose_apply_type_override "$spec" "$type_override") \
      || fail "$E_VALIDATION" "could not apply --type=$type_override to the spec"
  fi
  self=$(_compose_self)
  browser_mode=$(_compose_browser_mode "$spec" "$self")
  tasks_db_init 2>/dev/null || true
  local reg
  reg=$(registry_read)

  local names rows="[]"
  mapfile -t names < <(jq -r '.agents | keys[]' <<<"$spec")
  local name
  for name in "${names[@]}"; do
    local declared_type exists active loops
    declared_type=$(jq -r --arg n "$name" '.agents[$n].type // "?"' <<<"$spec")
    exists=$(jq           --arg n "$name" '.agents[$n] != null'     <<<"$reg")
    if [[ "$exists" == "true" ]]; then
      active=$(systemctl is-active "5dive-agent@${name}.service" 2>/dev/null || echo unknown)
    else
      active="missing"
    fi
    loops=$(db "SELECT COALESCE(json_group_array(json_object(
                  'title', title, 'schedule', COALESCE(schedule,''))), '[]')
                FROM tasks WHERE kind='recurring' AND assignee=$(sqlq "$name");" 2>/dev/null | head -1)
    [[ -n "$loops" ]] || loops='[]'
    rows=$(jq -c --arg n "$name" --arg t "$declared_type" --arg a "$active" --argjson l "$loops" \
      '. + [{name:$n, type:$t, state:$a, loops:$l}]' <<<"$rows")
  done

  if (( JSON_MODE )); then
    ok "" '{file:$f, agents:$rows} + (if $bm == "" then {} else {capabilities:{browser:$bm}} end)' \
      --arg f "$file" --argjson rows "$rows" --arg bm "$browser_mode"
  else
    [[ -n "$browser_mode" ]] && echo "PUBLISHING  $browser_mode"
    echo "$rows" | jq -r '
      (["NAME","TYPE","STATE","LOOP SCHEDULES"] | @tsv),
      (.[] | [.name, .type, .state,
              ([.loops[] | "\(.schedule) \(.title)"] | join("; ") | if . == "" then "-" else . end)] | @tsv)
    ' | column -t -s $'\t'
  fi
}
