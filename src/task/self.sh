# -------- DIVE-9004: a sandboxed seat's own team rail (_team_self) ----------
#
# A sandboxed seat sits outside group `claude` (DIVE-1033) and holds no general
# sudo, so the board (`/var/lib/5dive/tasks`, 2770 root:claude) and the a2a
# delivery grant were both out of its reach: the heartbeat dispatched its rows
# with a prompt that says `5dive task show`, and every board verb the seat ran
# died on EACCES. The sandbox fences off the box's secrets and other seats'
# files; it was never meant to fence off the teamwork (lodar, 2026-11-21).
#
# This rail is the _task_answer / _task_channel shape, one exact sudoers line:
#   * root only, reached through `sudo -n /usr/local/bin/5dive _team_self`;
#   * the operation travels NUL-separated on STDIN, never argv, so the grant has
#     no wildcard and a message body never lands in the process table;
#   * the caller is derived from SUDO_UID, and must be a REGISTERED SANDBOXED
#     agent: every other tier already has its own path, and this rail must not
#     become a second, differently-shaped one for them;
#   * a per-verb FLAG ALLOWLIST. Anything not listed is refused by name. That
#     shuts the provenance flags (`--from=` is stamped as the actor), every
#     `--force-*`, and every `*-file=` flag (root would read the path; the
#     client side inlines those files as the seat before crossing);
#   * WRITES ARE SELF-SCOPED: start/done/deliver/need/cancel only on a row whose
#     assignee is the caller. `add` files a new row as the caller (created_by is
#     derived from SUDO_UID), so DIVE-1065's hold on a confined creator driving
#     an unconfined seat keeps working unchanged.
#   * `send` hands one message to cmd_deliver, the same root primitive a
#     standard seat's `agent _deliver` grant reaches; the envelope stamps
#     tier=sandboxed from the caller, so the receiver sees who is talking.
#
# The task functions then run their OWN authorisation unchanged, as root, with
# the actor derived from SUDO_UID. Every check here refuses EARLIER; nothing
# here can widen who may change what.

TEAM_SELF_BIN="/usr/local/bin/5dive"

# _team_self_flag_ok <verb> <arg> — 0 when <arg> (a `--flag` or `--flag=value`)
# is on <verb>'s allowlist. A predicate over ONE argument so a harness grades
# the exact list the executor loops over.
_team_self_flag_ok() {
  local verb="$1" a="$2"
  case "$verb:${a%%=*}" in
    show:--no-body) return 0 ;;
    ls:--all|ls:--assignee|ls:--brief|ls:--gated|ls:--mine|ls:--no-body|ls:--project|ls:--recurring|ls:--status) return 0 ;;
    start:*) return 1 ;;
    done:--result|done:--append-result|done:--no-pr) return 0 ;;
    cancel:--result|cancel:--append-result) return 0 ;;
    deliver:--result|deliver:--append-result|deliver:--pr|deliver:--no-pr) return 0 ;;
    need:--type|need:--ask|need:--options|need:--recommend|need:--secret-key|need:--connector|need:--needs|need:--urgent|need:--withdraw|need:--expires-in|need:--quote) return 0 ;;
    add:--assignee|add:--body|add:--priority|add:--parent|add:--project|add:--already-blocked|add:--tell-me|add:--fresh|add:--no-fresh|add:--branch|add:--accept) return 0 ;;
    send:--urgent) return 0 ;;
  esac
  return 1
}

# Verbs whose single positional is a task ident the caller must be ASSIGNED.
_team_self_own_row_verb() { case "${1:-}" in start|done|cancel|deliver|need) return 0 ;; esac; return 1; }

cmd_team_self_delegated() {
  _gate_is_root || fail "$E_PERMISSION" "_team_self is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant a sandboxed seat holds)."

  local -a wire=() args=(); local a
  while IFS= read -r -d '' a; do wire+=("$a"); done
  (( ${#wire[@]} >= 1 )) || fail "$E_VALIDATION" "_team_self got no operation on stdin."
  local verb="${wire[0]}"; args=("${wire[@]:1}")
  case "$verb" in show|ls|start|done|cancel|deliver|need|add|send) ;;
    *) fail "$E_VALIDATION" "_team_self allows only: task show|ls|start|done|cancel|deliver|need|add, and agent send (got '${verb}')." ;;
  esac

  local ruid="${SUDO_UID:-}" actor="" tier=""
  [[ "$ruid" =~ ^[0-9]+$ && "$ruid" != 0 ]] \
    || fail "$E_AUTH_REQUIRED" "_team_self requires sudo from an agent seat (no SUDO_UID, or root)."
  actor=$(_gate_uid_to_agent "$ruid")
  [[ -n "$actor" ]] || fail "$E_AUTH_REQUIRED" "_team_self: uid ${ruid} is not an agent seat."
  tier=$(agent_tier "$actor")
  [[ "$tier" == sandboxed ]] \
    || fail "$E_PERMISSION" "_team_self serves sandboxed seats only; '${actor}' is '${tier}' and reaches the board directly."

  local -a pos=()
  for a in "${args[@]}"; do
    if [[ "$a" == --* ]]; then
      _team_self_flag_ok "$verb" "$a" \
        || fail "$E_VALIDATION" "_team_self ${verb} refuses ${a%%=*} (a sandboxed seat's rail takes a fixed flag list; *-file flags are inlined by the client, provenance and --force flags are never accepted)."
    else
      pos+=("$a")
    fi
  done

  if [[ "$verb" == send ]]; then
    (( ${#pos[@]} == 2 )) || fail "$E_USAGE" "_team_self send takes <agent> <message>."
    cmd_deliver "${args[@]}"
    return $?
  fi

  if _team_self_own_row_verb "$verb"; then
    (( ${#pos[@]} == 1 )) || fail "$E_USAGE" "_team_self ${verb} takes exactly one task ident."
    tasks_db_init
    local assignee
    assignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident=$(sqlq "${pos[0]}") LIMIT 1;" 2>/dev/null || printf '')
    [[ -n "$assignee" ]] || fail "$E_NOT_FOUND" "no task ${pos[0]} assigned to anyone."
    [[ "$assignee" == "$actor" ]] \
      || fail "$E_PERMISSION" "${pos[0]} is assigned to '${assignee}', not you ('${actor}'): a sandboxed seat changes only its own rows."
  fi
  if [[ "$verb" == show ]]; then
    (( ${#pos[@]} == 1 )) || fail "$E_USAGE" "_team_self show takes exactly one task ident."
  fi

  TEAM_SELF_DELEGATED=1
  cmd_task "$verb" "${args[@]}"
}

# ---- caller half -------------------------------------------------------------

# _team_self_available — 0 when THIS process should cross through the rail: not
# root, the board is not writable from here, and sudo says the exact line is
# granted. A seat that reaches the board directly keeps today's path byte for byte.
_team_self_available() {
  _gate_is_root && return 1
  [[ -z "${TEAM_SELF_DELEGATED:-}" ]] || return 1
  [[ -w "${TASKS_DIR:-/var/lib/5dive/tasks}" ]] && return 1
  sudo -n -l "$TEAM_SELF_BIN" _team_self >/dev/null 2>&1
}

# _team_self_try <verb> <arg>... — run the verb through the rail when this seat
# needs it. Returns 125 when the rail does not apply (the caller falls through to
# today's path). Every `--X-file=<path>` is read HERE, as the seat, and crosses as
# `--X=<content>`: root must never open a path the seat named.
_team_self_try() {
  local verb="${1:-}"
  case "$verb" in
    show|view) verb=show ;; list|ls) verb=ls ;; close|done) verb=done ;; new|add) verb=add ;;
    start|cancel|deliver|need) ;;
    *) _team_self_available && fail "$E_PERMISSION" "'${verb}' is not on a sandboxed seat's team rail (task show|ls|start|done|cancel|deliver|need|add). Ask a teammate, or file a row."
       return 125 ;;
  esac
  _team_self_available || return 125
  shift
  local -a out=("$verb"); local a k p
  for a in "$@"; do
    case "$a" in
      --result-file=*|--body-file=*|--ask-file=*|--recommend-file=*|--quote-file=*|--accept-file=*)
        k="${a%%-file=*}"; p="${a#*=}"
        [[ "$p" == - ]] && p=/dev/stdin
        [[ -r "$p" ]] || fail "$E_NOT_FOUND" "cannot read ${p} for ${k}-file"
        out+=("${k}=$(cat -- "$p")") ;;
      *) out+=("$a") ;;
    esac
  done
  _team_self_cross "${out[@]}"
}

# _team_self_cross <op> <arg>... — the one crossing. On a non-zero exit the root
# side has ALREADY printed its reason, so mark it reported: otherwise this
# process's own backstop overprints "exited N without reporting a reason … a bug
# in the CLI" under a plain refusal (measured on the test box, DIVE-9004).
_team_self_cross() {
  local rc=0
  printf '%s\0' "$@" | sudo -n "$TEAM_SELF_BIN" _team_self || rc=$?
  (( rc == 0 )) || mark_reported
  return "$rc"
}

# _team_self_send [--urgent] <agent> <message> — cmd_send's crossing for a seat
# that holds this rail and not the standard `agent _deliver` grant. 125 = n/a.
_team_self_send() {
  _team_self_available || return 125
  sudo -n -l "$TEAM_SELF_BIN" agent _deliver x y >/dev/null 2>&1 && return 125
  _team_self_cross send "$@"
}
