# --- machine (DIVE-5622) -------------------------------------------------------
# Attach any machine the user can SSH into to this box, so every agent seat
# reaches it as `ssh <name>`. We provision nothing: the user
# brings the machine, puts the box's PUBLIC key on it, and `machine rm` only
# forgets it here — it never touches the machine itself.
#
# State is the ssh config itself (no DB): one `Host <name>` block per machine in
# a file every seat's ssh reads, plus ONE line in Claude Code's managed CLAUDE.md
# naming them. The box keypair is root:claude 0640 so agent seats (group claude)
# can use it; no password is ever taken and no secret leaves the box.
# The FIVE_MACHINE_* overrides exist for the unit harness only.
MACHINE_MD_MARK="<!-- 5dive-machines (DIVE-5622; written by 5dive machine) -->"
MACHINE_NAME_RE='^[a-z0-9][a-z0-9-]{0,31}$'
MACHINE_USER_RE='^[a-z_][a-z0-9_.-]{0,31}$'
MACHINE_HOST_RE='^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$'
_machine_dir()  { printf '%s' "${FIVE_MACHINE_DIR:-/etc/5dive/machines}"; }
_machine_conf() { printf '%s' "${FIVE_MACHINE_SSH_CONF:-/etc/ssh/ssh_config.d/50-5dive-machines.conf}"; }
_machine_md()   { printf '%s' "${FIVE_MACHINE_MD:-/etc/claude-code/CLAUDE.md}"; }
_machine_chgrp() { chgrp claude "$@"; }   # seam for the harness

_machine_write() {   # <path> <content> — atomic, 0644
  local tmp; mkdir -p "$(dirname "$1")" && tmp=$(mktemp "$1.XXXXXX") || fail "$E_GENERIC" "cannot write $1"
  printf '%s' "$2" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; fail "$E_GENERIC" "cannot write $1"; }
}
_machine_names() { local f; f=$(_machine_conf); [[ -f "$f" ]] && awk '$1=="Host"{print $2}' "$f"; return 0; }
_machine_conf_without() {   # <name> — the config minus that machine's block
  local f; f=$(_machine_conf); [[ -f "$f" ]] || return 0
  awk -v n="$1" '$1=="Host"{skip=($2==n)} !skip' "$f"
}
# Rewrite the one CLAUDE.md line from the config, keeping the rest of the file.
_machine_sync_md() {
  local md rest names line=""; md=$(_machine_md)
  rest=$( [[ -f "$md" ]] && grep -vF -- "$MACHINE_MD_MARK" "$md" || true ); names=$(_machine_names)
  [[ -n "$names" ]] && line="Machines you can use from this box: $(printf '`ssh %s` ' $names)${MACHINE_MD_MARK}"
  if [[ -n "${rest//[$'\n ']/}" ]]; then _machine_write "$md" "${rest}${line:+$'\n'$line}"$'\n'
  elif [[ -n "$line" ]]; then _machine_write "$md" "${line}"$'\n'
  else rm -f "$md"; fi
}

cmd_machine() {
  local action="${1:-}"; shift || true
  local dir conf; dir=$(_machine_dir); conf=$(_machine_conf)
  [[ "${1:-}" == "--json" ]] && { JSON_MODE=1; shift; }
  case "$action" in
    add)
      local name="${1:-}" target="${2:-}" user host port=22
      (( $# == 2 )) || fail "$E_USAGE" "usage: 5dive machine add <name> <user@host[:port]>"
      require_root "machine add $*"
      [[ "$name" =~ $MACHINE_NAME_RE ]] || fail "$E_VALIDATION" "name must be lowercase letters, digits and dashes (max 32), got '${name:0:40}'"
      [[ "$target" == *@* ]] || fail "$E_VALIDATION" "target must be user@host[:port], got '${target:0:80}'"
      user="${target%%@*}"; host="${target#*@}"
      [[ "$host" == *:* ]] && { port="${host##*:}"; host="${host%:*}"; }
      [[ "$user" =~ $MACHINE_USER_RE ]] || fail "$E_VALIDATION" "bad user '${user:0:40}'"
      [[ "$host" =~ $MACHINE_HOST_RE ]] || fail "$E_VALIDATION" "bad host '${host:0:80}' (a hostname or IPv4)"
      [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || fail "$E_VALIDATION" "bad port '${port:0:8}'"
      if [[ ! -f "$dir/id_ed25519" ]]; then
        mkdir -p "$dir" && chmod 0755 "$dir" || fail "$E_GENERIC" "cannot create $dir"
        ssh-keygen -q -t ed25519 -N '' -C "5dive-box@$(hostname)" -f "$dir/id_ed25519" </dev/null >/dev/null \
          || fail "$E_GENERIC" "ssh-keygen failed"
      fi
      _machine_chgrp "$dir/id_ed25519" && chmod 0640 "$dir/id_ed25519" || fail "$E_GENERIC" "cannot give group claude the box key"
      local block; block=$(printf '%s\n' "Host $name" "  HostName $host" "  User $user" "  Port $port" \
        "  IdentityFile $dir/id_ed25519" "  IdentitiesOnly yes" "  BatchMode yes" "  StrictHostKeyChecking accept-new")
      local rest; rest=$(_machine_conf_without "$name" | grep -v '^# Written by' || true)
      _machine_write "$conf" "# Written by \`5dive machine\` (DIVE-5622). Edit with 5dive machine add|rm."$'\n'"${rest:+$rest$'\n'}${block}"$'\n'
      _machine_sync_md
      local pub; pub=$(cat "$dir/id_ed25519.pub")
      ok "machine '$name' added: agents reach it as \`ssh $name\` ($user@$host:$port).
Put this box's public key in ~$user/.ssh/authorized_keys on that machine:
$pub" '{name:$n, user:$u, host:$h, port:($p|tonumber), publicKey:$k}' \
        --arg n "$name" --arg u "$user" --arg h "$host" --arg p "$port" --arg k "$pub" ;;
    rm)
      local name="${1:-}"
      (( $# == 1 )) || fail "$E_USAGE" "usage: 5dive machine rm <name>"
      require_root "machine rm $*"
      _machine_names | grep -qxF -- "$name" || fail "$E_NOT_FOUND" "no machine named '${name:0:40}' (see: 5dive machine ls)"
      local rest; rest=$(_machine_conf_without "$name")
      if _machine_names | grep -vxF -- "$name" | grep -q .; then _machine_write "$conf" "${rest}"$'\n'; else rm -f "$conf"; fi
      _machine_sync_md
      ok "machine '$name' detached from this box (the machine itself is untouched)" '{name:$n, removed:true}' --arg n "$name" ;;
    ls|"")
      local rows="[]" human=""
      [[ -f "$conf" ]] && rows=$(awk '$1=="Host"{if(n)print n"\t"u"\t"h"\t"p; n=$2;u="";h="";p=22} $1=="HostName"{h=$2} $1=="User"{u=$2} $1=="Port"{p=$2} END{if(n)print n"\t"u"\t"h"\t"p}' "$conf" \
        | jq -Rn '[inputs | split("\t") | {name:.[0], user:.[1], host:.[2], port:(.[3]|tonumber)}]')
      human=$(jq -r '.[] | "\(.name)\t\(.user)@\(.host):\(.port)"' <<<"$rows")
      ok "${human:-no machines attached (add one: sudo 5dive machine add <name> <user@host[:port]>)}" '{machines:$m}' --argjson m "$rows" ;;
    -h|--help|help) printf '%s\n' \
      "usage: 5dive machine add <name> <user@host[:port]>   # agents reach it as \`ssh <name>\`; prints the key to install" \
      "       5dive machine rm <name>                       # forget it here; the machine itself is untouched" \
      "       5dive machine ls" ;;
    *) fail "$E_USAGE" "usage: 5dive machine <add|rm|ls> (see: 5dive machine --help)" ;;
  esac
}
