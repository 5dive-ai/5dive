audit_init() {
  local dir
  dir=$(dirname "$AUDIT_LOG")
  [[ -d "$dir" ]] || mkdir -p "$dir"
  chown root:claude "$dir"
  chmod 2750 "$dir"
  [[ -f "$AUDIT_LOG" ]] || : > "$AUDIT_LOG"
  chown root:claude "$AUDIT_LOG"
  chmod 640 "$AUDIT_LOG"
  # DIVE-1345: a group-writable subdir for agent-filed diagnostic logs
  # (gate-notify.log). The parent stays 2750 so the tamper-evident audit log is
  # never exposed to group writes; only this purpose-built subdir is 2770 (setgid
  # + group-write, same shape as TASKS_DIR) so gate notifies running AS the agent
  # (group claude, NOT root) can create/append the log instead of silently
  # falling back to stderr — the DIVE-1344 observability gap.
  local notify_dir="$dir/notify"
  [[ -d "$notify_dir" ]] || mkdir -p "$notify_dir"
  chown root:claude "$notify_dir"
  chmod 2770 "$notify_dir"
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
    printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null \
      || _audit_note_drop "$line" "direct-append-failed"
  else
    printf '%s\n' "$line" | sudo -n /usr/local/bin/5dive _audit_append >/dev/null 2>&1 \
      || _audit_note_drop "$line" "privileged-fallback-failed"
  fi
  return 0
}

# _audit_note_drop <ndjson-line> <reason> — leave a trace when an audit row is LOST.
#
# DIVE-1989. Both append paths above used to end in a bare `|| true`, so a failed
# write left no evidence ANYWHERE: the row was simply absent, and "absent from the
# audit log" became indistinguishable from "the action never happened". That is the
# absent-vs-forbidden conflation aimed at our own evidence base — DIVE-1988 spent a
# day unable to decide whether three DIVE-1801 rows were dropped by the privileged
# fallback or were fixture reuse, and no amount of re-reading the audit log could
# settle it, because a drop is exactly what the log cannot record.
#
# The drop marker goes to the 2770 `notify/` sibling, NOT to $AUDIT_LOG: the whole
# reason we are here is that the caller could not write the audit log, so recording
# the failure there would fail the same way. notify/ is group-writable by
# construction (audit_init) precisely so agent-context diagnostics survive.
#
# Still never fails and never speaks to the caller — audit is best-effort by design
# (a full disk must not block a rescue `agent rm`). The marker is for the reader of
# the log, not for the actor.
_audit_note_drop() {
  local line="$1" reason="$2"
  local drops_dir="${AUDIT_LOG%/*}/notify"
  [[ -d "$drops_dir" ]] || return 0
  local drops="$drops_dir/audit-drops.log"
  local note
  # --argjson (not --arg): the row is already valid NDJSON, so it nests as an
  # object and a reader can re-derive the lost row verbatim. A caller that hands
  # us non-JSON gets no marker rather than a corrupt one.
  note=$(jq -cn --arg ts "$(date -Iseconds)" --arg reason "$reason" \
    --arg by "${SUDO_USER:-${USER:-unknown}}" --argjson row "$line" \
    '{ts:$ts, dropped_by:$by, reason:$reason, row:$row}' 2>/dev/null) || return 0
  # DIVE-1888: the setgid dir hands the FILE group `claude` but not group WRITE,
  # so whichever agent creates it would own the only writable handle and every
  # other agent's drop would itself be dropped. chmod the file, not the dir.
  if [[ ! -e "$drops" ]]; then
    : >> "$drops" 2>/dev/null || return 0
    chmod g+w "$drops" 2>/dev/null || true
  fi
  [[ -w "$drops" ]] || return 0
  printf '%s\n' "$note" >> "$drops" 2>/dev/null || true
  return 0
}

# audit_log <cmd> <result:ok|error> <code> -- <args...>
#
# CALL THIS UNCONDITIONALLY. Do NOT wrap it in `[[ $EUID -eq 0 ]] && ...` — that
# pattern predates _emit_audit_line's privileged fallback and was the DIVE-1989
# defect: nine `task`/`task need` sub-events were gated that way, so an agent
# running the verb as itself emitted NO row while the identical command as root
# emitted one. The gate looked honest (it skipped a write that would EACCES) but
# it turned the audit log into a record of privileged operations only, silently,
# and nothing said so. _emit_audit_line handles the non-root case; let it.
#
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
