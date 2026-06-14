
# -------- 5dive fleet — multi-box control plane (DIVE-204) --------
#
# v0.2 graduates the CLI from a single-box agent manager into one control
# surface over MANY boxes. NOT master/slave: the CLI/dashboard is the control
# surface, boxes stay equal peers each running + exposing their own agents
# (reached over SSH + their own 5dive CLI). The only central state is this
# small fleet REGISTRY — where each box is and how to reach it — kept as local
# operator config on the OSS path. Hosted (api.5dive.com) already holds box
# records + keys server-side, so the hosted fleet view aggregates there and
# never touches this file.
#
# SECURITY: the registry stores REFERENCES, never secrets. A box entry holds
# host/user/port and an optional PATH to an existing private key — never key
# material. fleet.json is written atomically as root:claude 0640 (same posture
# as the agent registry); the actual key stays protected by its own 0600 perms
# at the referenced path. `fleet add` validates the key path and warns if it is
# looser than 0600 so we never point the fleet at a sloppy key.
#
# Phase 1 (this file): the registry — add/ls/show/rm. Fan-out READ (fleet
# agents/status) and COMMAND (fleet send/restart) build on it in later phases.

FLEET_REGISTRY="${STATE_DIR}/fleet.json"

_fleet_usage() {
  cat <<USAGE
5dive fleet — register and view the boxes in your fleet (DIVE-204 phase 1)

  5dive fleet add <name> --host=<addr> [--user=<u>] [--port=<n>] [--key=<path>]
                                          # register a peer box (default user=claude, port=22)
  5dive fleet ls                          # list registered boxes
  5dive fleet show <name>                 # one box's connection details
  5dive fleet rm <name>                   # remove a box from the registry
  5dive fleet status [--timeout=<s>]      # per-box reachability + agent counts (parallel SSH)
  5dive fleet agents [--timeout=<s>]      # every agent across the fleet, one view

  add/rm need root (writes ${STATE_DIR}/fleet.json, 0640 root:claude); ls/show/status/agents
  are read-only. --key takes a PATH to an existing private key (never key material); omit it
  to use the default fleet key at connect time. status/agents fan out over SSH in parallel and
  degrade gracefully — one unreachable box never fails the whole view. Add --json for machine
  output. Fan-out COMMAND (fleet send/restart) lands in the next phase.
USAGE
}

fleet_read() {
  [[ -f "$FLEET_REGISTRY" ]] && cat "$FLEET_REGISTRY" || echo '{"boxes":{}}'
}

fleet_write() {
  # stdin -> registry, atomic, same posture as registry_write (root:claude 0640).
  local tmp
  tmp=$(mktemp "${FLEET_REGISTRY}.XXXXXX")
  cat > "$tmp"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv "$tmp" "$FLEET_REGISTRY"
}

cmd_fleet() {
  [[ $# -gt 0 ]] || { _fleet_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    add)            cmd_fleet_add "$@" ;;
    ls|list)        cmd_fleet_ls "$@" ;;
    show)           cmd_fleet_show "$@" ;;
    rm|delete)      cmd_fleet_rm "$@" ;;
    status)         cmd_fleet_status "$@" ;;
    agents)         cmd_fleet_agents "$@" ;;
    -h|--help|help) _fleet_usage ;;
    *) fail "$E_USAGE" "unknown fleet command: $sub (try: 5dive fleet --help)" ;;
  esac
}

cmd_fleet_add() {
  require_root
  local name="" host="" user="claude" port="22" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host=*) host="${1#*=}" ;;
      --user=*) user="${1#*=}" ;;
      --port=*) port="${1#*=}" ;;
      --key=*)  key="${1#*=}" ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive fleet add <name> --host=<addr> [--user=] [--port=] [--key=]"
  valid_sender_label "$name" || fail "$E_VALIDATION" "bad box name '$name' (lowercase letter then letters/digits/hyphen, max 32)"
  [[ -n "$host" ]] || fail "$E_USAGE" "--host=<addr> is required"
  # Host is a hostname or IP — no shell metachars (it gets handed to ssh later).
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$E_VALIDATION" "bad host '$host' (hostname or IP only)"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || fail "$E_VALIDATION" "bad port '$port' (1-65535)"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "$E_VALIDATION" "bad ssh user '$user'"
  # --key is a PATH to an existing key, never key material. Validate it exists
  # and is not looser than 0600 so the fleet never points at a sloppy key.
  if [[ -n "$key" ]]; then
    [[ -f "$key" ]] || fail "$E_NOT_FOUND" "ssh key not found at '$key' (pass a path to an existing private key, not the key itself)"
    local mode
    mode=$(stat -c '%a' "$key" 2>/dev/null || echo "")
    if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
      warn "key '$key' is mode $mode — tighten to 600 (chmod 600 '$key'); registering the path anyway"
    fi
  fi

  local reg added_ts
  reg=$(fleet_read)
  added_ts=$(date -u +%FT%TZ)
  reg=$(jq --arg n "$name" --arg h "$host" --arg u "$user" --argjson p "$port" \
           --arg k "$key" --arg t "$added_ts" '
    .boxes[$n] = {
      host: $h, user: $u, port: $p,
      key: (if $k == "" then null else $k end),
      addedAt: $t
    }' <<<"$reg") || fail "$E_GENERIC" "failed to update fleet registry"
  printf '%s\n' "$reg" | fleet_write
  ok "registered box '$name' (${user}@${host}:${port})" \
     '{name:$n, host:$h, user:$u, port:$p, key:(if $k=="" then null else $k end)}' \
     --arg n "$name" --arg h "$host" --arg u "$user" --argjson p "$port" --arg k "$key"
}

cmd_fleet_ls() {
  local reg; reg=$(fleet_read)
  if (( JSON_MODE )); then
    jq -c '{ok:true, data:(.boxes | to_entries | map({name:.key} + .value))}' <<<"$reg"
    return 0
  fi
  local names; names=$(jq -r '.boxes | keys[]' <<<"$reg" 2>/dev/null || true)
  if [[ -z "$names" ]]; then
    echo "No boxes registered. Add one: 5dive fleet add <name> --host=<addr>"
    return 0
  fi
  printf '%-16s %-26s %-10s %-6s %s\n' NAME HOST USER PORT KEY
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    local h u p k
    h=$(jq -r --arg n "$n" '.boxes[$n].host' <<<"$reg")
    u=$(jq -r --arg n "$n" '.boxes[$n].user' <<<"$reg")
    p=$(jq -r --arg n "$n" '.boxes[$n].port' <<<"$reg")
    k=$(jq -r --arg n "$n" '.boxes[$n].key // "(default)"' <<<"$reg")
    printf '%-16s %-26s %-10s %-6s %s\n' "$n" "$h" "$u" "$p" "$k"
  done <<<"$names"
}

cmd_fleet_show() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive fleet show <name>"
  local reg; reg=$(fleet_read)
  jq -e --arg n "$name" '.boxes[$n]' <<<"$reg" >/dev/null 2>&1 \
    || fail "$E_NOT_FOUND" "no box '$name' in the fleet (see: 5dive fleet ls)"
  if (( JSON_MODE )); then
    jq -c --arg n "$name" '{ok:true, data:({name:$n} + .boxes[$n])}' <<<"$reg"
    return 0
  fi
  echo "name: $name"
  echo "host: $(jq -r --arg n "$name" '.boxes[$n].host' <<<"$reg")"
  echo "user: $(jq -r --arg n "$name" '.boxes[$n].user' <<<"$reg")"
  echo "port: $(jq -r --arg n "$name" '.boxes[$n].port' <<<"$reg")"
  echo "key:  $(jq -r --arg n "$name" '.boxes[$n].key // "(default fleet key)"' <<<"$reg")"
}

cmd_fleet_rm() {
  require_root
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive fleet rm <name>"
  local reg; reg=$(fleet_read)
  jq -e --arg n "$name" '.boxes[$n]' <<<"$reg" >/dev/null 2>&1 \
    || fail "$E_NOT_FOUND" "no box '$name' in the fleet (see: 5dive fleet ls)"
  reg=$(jq --arg n "$name" 'del(.boxes[$n])' <<<"$reg")
  printf '%s\n' "$reg" | fleet_write
  ok "removed box '$name' from the fleet" '{name:$n, removed:true}' --arg n "$name"
}

# ---- phase 2: fan-out READ (DIVE-204) ------------------------------------
#
# `fleet status` / `fleet agents` SSH every registered box in PARALLEL, run
# `agent list --json` there, and aggregate one view. Read-only (no root). A box
# that times out or refuses becomes {reachable:false} rather than failing the
# whole command, so one dead peer never blinds the fleet view.

# Resolve the SSH key for a box: the explicit registry path, else the default
# fleet key. Echoes a readable path, or empty (let ssh fall back to its own
# default identities). The key is a REFERENCE — material never lives here.
_fleet_key_for() {
  local key="$1" d
  if [[ -n "$key" && "$key" != "null" && -r "$key" ]]; then printf '%s' "$key"; return; fi
  for d in /home/claude/.ssh/id_ed25519 "${HOME:-/root}/.ssh/id_ed25519"; do
    [[ -r "$d" ]] && { printf '%s' "$d"; return; }
  done
  printf ''
}

# Query ONE box; write a single JSON object to $outfile. Never exits non-zero.
_fleet_query_box() {
  local name="$1" reg="$2" tmo="$3" outfile="$4"
  local host user port key keyarg=() out rc
  host=$(jq -r --arg n "$name" '.boxes[$n].host' <<<"$reg")
  user=$(jq -r --arg n "$name" '.boxes[$n].user' <<<"$reg")
  port=$(jq -r --arg n "$name" '.boxes[$n].port' <<<"$reg")
  key=$(jq -r --arg n "$name" '.boxes[$n].key // ""' <<<"$reg")
  local keypath; keypath=$(_fleet_key_for "$key")
  [[ -n "$keypath" ]] && keyarg=(-i "$keypath")
  # accept-new pins the host key on first contact (writes the operator's
  # known_hosts) without prompting — automatable but still MITM-resistant after
  # first use. BatchMode so a missing key fails fast instead of prompting.
  out=$(timeout "$tmo" ssh -p "$port" "${keyarg[@]}" \
        -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o LogLevel=ERROR \
        "${user}@${host}" 'sudo -n /usr/local/bin/5dive agent list --json' 2>/dev/null)
  rc=$?
  if (( rc != 0 )); then
    local reason="ssh failed (rc=$rc)"; (( rc == 124 )) && reason="timed out after ${tmo}s"
    jq -cn --arg n "$name" --arg h "$host" --arg e "$reason" \
      '{name:$n, host:$h, reachable:false, error:$e, agents:[]}' >"$outfile"
    return 0
  fi
  if jq -e '.ok == true and (.data|type=="array")' <<<"$out" >/dev/null 2>&1; then
    jq -c --arg n "$name" --arg h "$host" \
      '{name:$n, host:$h, reachable:true, agents:.data,
        agentCount:(.data|length),
        activeCount:(.data|map(select(.active=="active"))|length)}' <<<"$out" >"$outfile"
  else
    jq -cn --arg n "$name" --arg h "$host" --arg e "remote agent list returned no usable JSON" \
      '{name:$n, host:$h, reachable:true, error:$e, agents:[]}' >"$outfile"
  fi
  return 0
}

# Fan out across all boxes in parallel; echo {boxes:[...], totals:{...}}.
_fleet_fanout() {
  local tmo="${1:-20}"
  local reg names; reg=$(fleet_read)
  names=$(jq -r '.boxes | keys[]' <<<"$reg" 2>/dev/null || true)
  if [[ -z "$names" ]]; then
    echo '{"boxes":[],"totals":{"boxes":0,"reachable":0,"agents":0,"active":0}}'
    return 0
  fi
  local tmpd n; tmpd=$(mktemp -d)
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    _fleet_query_box "$n" "$reg" "$tmo" "$tmpd/$n.json" &
  done <<<"$names"
  wait
  jq -cs '{
    boxes: (. | sort_by(.name)),
    totals: {
      boxes: length,
      reachable: (map(select(.reachable))|length),
      agents: (map(.agents|length)|add // 0),
      active: (map(.agents|map(select(.active=="active"))|length)|add // 0)
    }
  }' "$tmpd"/*.json
  rm -rf "$tmpd"
}

_fleet_parse_timeout() {
  local tmo=20 a
  for a in "$@"; do
    case "$a" in
      --timeout=*) tmo="${a#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *)  fail "$E_USAGE" "unexpected arg: $a" ;;
    esac
  done
  [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo >= 1 && tmo <= 120 )) || fail "$E_VALIDATION" "bad --timeout '$tmo' (1-120s)"
  printf '%s' "$tmo"
}

cmd_fleet_status() {
  local tmo; tmo=$(_fleet_parse_timeout "$@")
  local agg; agg=$(_fleet_fanout "$tmo")
  if (( JSON_MODE )); then
    jq -cn --argjson a "$agg" '{ok:true, data:$a}'
    return 0
  fi
  if [[ "$(jq -r '.totals.boxes' <<<"$agg")" == "0" ]]; then
    echo "No boxes registered. Add one: 5dive fleet add <name> --host=<addr>"
    return 0
  fi
  printf '%-16s %-26s %-12s %-7s %s\n' NAME HOST STATUS AGENTS ACTIVE
  jq -r '.boxes[] | [.name, .host, (if .reachable then "ok" else "UNREACHABLE" end),
                     (.agentCount // 0), (.activeCount // 0), (.error // "")] | @tsv' <<<"$agg" \
  | while IFS=$'\t' read -r n h st ac act err; do
      if [[ "$st" == "ok" ]]; then
        printf '%-16s %-26s %-12s %-7s %s\n' "$n" "$h" "$st" "$ac" "$act"
      else
        printf '%-16s %-26s %-12s %s\n' "$n" "$h" "$st" "${err}"
      fi
    done
  echo "---"
  jq -r '"\(.totals.reachable)/\(.totals.boxes) boxes reachable · \(.totals.agents) agents (\(.totals.active) active)"' <<<"$agg"
}

cmd_fleet_agents() {
  local tmo; tmo=$(_fleet_parse_timeout "$@")
  local agg; agg=$(_fleet_fanout "$tmo")
  if (( JSON_MODE )); then
    jq -cn --argjson a "$agg" '{ok:true, data:$a}'
    return 0
  fi
  if [[ "$(jq -r '.totals.boxes' <<<"$agg")" == "0" ]]; then
    echo "No boxes registered. Add one: 5dive fleet add <name> --host=<addr>"
    return 0
  fi
  # Per-box section, then each agent indented (name / type / state).
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    local reachable; reachable=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .reachable' <<<"$agg")
    if [[ "$reachable" == "true" ]]; then
      local host ac act
      host=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .host' <<<"$agg")
      ac=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .agentCount' <<<"$agg")
      act=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .activeCount' <<<"$agg")
      echo "▸ $n ($host) — $ac agents, $act active"
      jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .agents[]
        | "    \(.name)  \(.type // "?")  \(.active // "?")"' <<<"$agg"
    else
      local host err
      host=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .host' <<<"$agg")
      err=$(jq -r --arg n "$n" '.boxes[] | select(.name==$n) | .error' <<<"$agg")
      echo "▸ $n ($host) — UNREACHABLE: $err"
    fi
  done < <(jq -r '.boxes[].name' <<<"$agg")
  echo "---"
  jq -r '"\(.totals.reachable)/\(.totals.boxes) boxes reachable · \(.totals.agents) agents (\(.totals.active) active)"' <<<"$agg"
}
