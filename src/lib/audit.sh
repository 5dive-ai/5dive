audit_init() {
  local dir
  dir=$(dirname "$AUDIT_LOG")
  [[ -d "$dir" ]] || mkdir -p "$dir"
  chown root:claude "$dir"
  chmod 2750 "$dir"
  [[ -f "$AUDIT_LOG" ]] || : > "$AUDIT_LOG"
  chown root:claude "$AUDIT_LOG"
  chmod 640 "$AUDIT_LOG"
}

# _emit_audit_line <ndjson-line> — append one line to the tamper-evident log
# WITHOUT ever failing the caller or leaking to stderr.
#
# The log is 640 root:claude: root writes it directly, but a non-root agent-*
# caller cannot (group `claude` is read-only — deliberately, so no group member
# can rewrite/truncate past entries). DIVE-1268: rather than loosen perms to a
# group-writable 660 (which would make the log tamperable by ANY group-claude
# agent), non-root callers route the append through the privileged, append-only
# `_audit_append` primitive over NOPASSWD sudo. That primitive re-stamps the
# real caller server-side, so agent-initiated mutating actions (task done,
# agent send, ...) still land in the log and can't be dropped or spoofed.
#
# NOTE: a bare `... >> "$AUDIT_LOG" 2>/dev/null` does NOT suppress a failed-open
# diagnostic — bash applies redirections left-to-right, so if opening the log
# for append fails (EACCES) the "Permission denied" message hits the still-live
# stderr BEFORE `2>/dev/null` takes effect. We gate on writability first so the
# failing redirect is never attempted by a caller who can't write.
_emit_audit_line() {
  local line="$1"
  [[ -n "$line" ]] || return 0
  if [[ $EUID -eq 0 || -w "$AUDIT_LOG" ]]; then
    printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || true
  else
    printf '%s\n' "$line" | sudo -n /usr/local/bin/5dive _audit_append >/dev/null 2>&1 || true
  fi
}

# audit_log <cmd> <result:ok|error> <code> -- <args...>
# Emits one NDJSON line. Sensitive =<value> args are redacted ("--api-key=..."
# becomes "--api-key=<redacted>"). Never fails the caller — writes are
# best-effort so a full disk can't block a rescue rm.
audit_log() {
  # Best-effort: skip silently if the audit dir isn't initialized yet.
  # Some code paths (cmd_auth_start, the read-only commands) don't go
  # through ensure_state and thus don't trigger audit_init, leaving
  # /var/log/5dive/ missing. Without this guard the `>> "$AUDIT_LOG"`
  # redirect bash-errors with "No such file or directory" BEFORE jq's
  # `2>/dev/null` can suppress anything, leaking a noisy line to stderr
  # on every invocation.
  [[ -d "${AUDIT_LOG%/*}" ]] || return 0
  local cmd="$1" result="$2" code="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local -a sanitized=()
  local a
  for a in "$@"; do
    case "$a" in
      --api-key=*|--telegram-token=*|--discord-token=*|--code=*|--token=*)
        sanitized+=("${a%%=*}=<redacted>") ;;
      *)
        sanitized+=("$a") ;;
    esac
  done
  local user="${FIVEDIVE_AUDIT_USER:-${SUDO_USER:-${USER:-unknown}}}"
  local ts
  ts=$(date -Iseconds)
  local line
  line=$(jq -cn \
    --arg ts "$ts" --arg u "$user" --arg c "$cmd" \
    --arg r "$result" --argjson code "$code" \
    --args '{ts:$ts, user:$u, cmd:$c, result:$r, code:($code|tonumber? // 0), args:$ARGS.positional}' \
    "${sanitized[@]+"${sanitized[@]}"}" 2>/dev/null) || return 0
  _emit_audit_line "$line"
}

# Dispatcher-level audit state. main() populates these before calling the
# mutating handler; the EXIT trap below fires audit_log with the real exit
# code on the way out. Unset for read-only commands (list/logs/stats) so
# they don't clutter the log.
AUDIT_CMD=""
declare -a AUDIT_ARGS=()

on_exit_audit() {
  local code=$?
  [[ -n "$AUDIT_CMD" ]] || return 0
  local result="ok"
  (( code != 0 )) && result="error"
  audit_log "$AUDIT_CMD" "$result" "$code" -- "${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"}"
}

# Serialize mutating calls against a single flock. Lock is released when the
# subshell exits, so even a crash inside the handler frees it. Re-entrancy:
# IN_REGISTRY_LOCK=1 lets cmd_clone -> cmd_create run the inner command
# without trying to re-acquire the same lock (which flock would block on).
