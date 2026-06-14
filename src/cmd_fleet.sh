
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

  add/rm need root (writes ${STATE_DIR}/fleet.json, 0640 root:claude); ls/show are read-only.
  --key takes a PATH to an existing private key (never key material); omit it to use the
  default fleet key at connect time. Add --json for machine output. Fan-out (fleet
  agents/status/send) lands in later phases.
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
