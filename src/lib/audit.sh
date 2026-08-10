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
# DIVE-2073 seam: $EUID is READONLY in bash, so a unit harness cannot exercise
# the root branch of the actor fallback by assigning it. Same reason cmd_task.sh
# grew _gate_is_root (DIVE-1968) — the hardcoded audit code behind an
# unreachable root check survived a year precisely because no test could reach
# it. A check nobody can exercise is a check nobody can trust.
_audit_is_root() { [[ $EUID -eq 0 ]]; }

# _actor_identity — the ONE resolver for "who is acting", shared by the audit log
# and the INST-4 lifecycle ledger.
#
# It is deliberately a single function rather than the same four-fallback
# expression copy-pasted per trail. Two evidence trails that disagree about the
# actor are worse than one trail: a reader cannot tell a real identity conflict
# from two resolvers drifting apart, and there is nothing in either row that says
# which resolver produced it. Same reason the ledger below reuses this instead of
# re-deriving the caller.
#
# DIVE-2073 semantics are preserved verbatim: root with no invoking user is an
# identity BY DESIGN (`root`), and `unknown` means only the genuine failure — a
# NON-root process whose USER we could not read.
_actor_identity() {
  local user="${FIVEDIVE_AUDIT_USER:-${SUDO_USER:-${USER:-}}}"
  [[ -n "$user" ]] || { if _audit_is_root; then user="root"; else user="unknown"; fi; }
  printf '%s' "$user"
}

# _actor_identity_derived — the same question, answered from the UID (DIVE-2518).
#
# `_actor_identity` above is DELIBERATELY NOT REPLACED, and that is a decision, not
# an omission. It is the audit log's PROVENANCE field: "who does this invocation say
# it is". `FIVEDIVE_AUDIT_USER` is the dashboard's Clerk relay (see header.sh) — a
# real human acting through the API has no uid on this box, and collapsing that onto
# the process's uid would replace the only record of which human it was with the
# service account that carried the request. The wiki inventory names the split
# exactly: provenance is the right answer for an audit record and the wrong one for
# an authorization check.
#
# What was missing is the OTHER half. A row carrying only the asserted identity
# cannot be falsified afterwards — nothing in it says whether the value was measured
# or announced. This returns the derived unix name so `audit_log` can carry both and
# a reader can see when they disagree.
#
# Pure bash by construction: it goes through `actor_derive`, which reads `$EUID` and
# walks /etc/passwd without `id`, `getent` or jq. audit_log is a best-effort writer on
# every command path, so it must not gain a jq dependency or a registry read here.
# DIVE-2130: every `return` below is `return 0`, spelled out. A BARE `return`
# yields `$?`, and both of these run inside `audit_log`, which the EXIT trap calls
# with the process's own exit status still pending. Measured on bash 5.2.21: in a
# command substitution taken from an EXIT trap, a function that ends in a bare
# `return` hands back the TRAP'S inherited status, not the 0 that `printf ''` just
# set — so `claimed=$(_actor_identity_claim)` returned 3 for a refused `5dive push`,
# tripped `set -e` INSIDE the trap, and killed the process before the row was ever
# rendered. Every dispatcher-audited verb that exited non-zero silently wrote
# nothing from 2026-08-02 (when DIVE-2518 added the claim) onward. A helper that
# answers a question must never leak the caller's status.
_actor_identity_derived() {
  actor_derive >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$ACTOR_UNIX"
}

# _actor_identity_claim — the provenance string, but ONLY when it disagrees with the
# derivation. Empty when they agree, when nothing was derived, or when the provenance
# is just the derived name with the `agent-` prefix intact — that last case is the
# same principal spelled two ways, not a conflict, and stamping it would bury the
# real disagreements in noise.
_actor_identity_claim() {
  local claimed derived
  claimed=$(_actor_identity); derived=$(_actor_identity_derived)
  [[ -n "$derived" ]] || { printf ''; return 0; }
  [[ "$claimed" == "$derived" ]] && { printf ''; return 0; }
  [[ "$claimed" == "${derived#agent-}" ]] && { printf ''; return 0; }
  printf '%s' "$claimed"
}

# _actor_authority — under WHOSE authority the current process is acting.
#
# Distinct from _actor_identity on purpose. Identity answers "who"; authority
# answers "with what powers, granted by whom". `sudo:claude` and `self` can carry
# the same identity and are not the same act, and the audit log has never been
# able to say which — it records the invoking user and drops the elevation. For a
# ledger whose whole job is "who was AUTHORIZED to act", that distinction is the
# payload, not a detail.
#   root        EUID 0 with no invoking user (cron, systemd, the privileged rails)
#   sudo:<who>  EUID 0 reached by elevation from <who>
#   self        unelevated — the agent acting as itself
#
# Goes through _audit_is_root, NOT a bare `[[ $EUID -eq 0 ]]`.
#
# $EUID is READONLY in bash, so a direct read makes the root and sudo: branches
# unreachable from a unit harness — and the first cut of this function did read it
# directly, which meant the only branch any test could ever observe was `self`.
# Two of the three values this function exists to produce would have shipped
# unexercised, on the column that carries the whole authority claim. Same defect
# main hit in _gate_withdraw_actor on DIVE-2330 the same evening: a seam added so
# a harness can model the caller, then bypassed by the guard that actually
# decides. The comment eight lines above this one already says it — a check
# nobody can exercise is a check nobody can trust — and the fix is to route
# through the seam that exists rather than add a second one.
_actor_authority() {
  if _audit_is_root; then
    if [[ -n "${SUDO_USER:-}" ]]; then printf 'sudo:%s' "$SUDO_USER"; else printf 'root'; fi
  else
    printf 'self'
  fi
}

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
  # DIVE-2073: `unknown` used to mean TWO different things and the reader could
  # not tell them apart — "this process genuinely has no invoking user" (root
  # cron: every gate-delivery row at :NN:02 is the heartbeat re-nag, which has
  # neither SUDO_USER nor USER) and "actor resolution FAILED". Same absent-vs-
  # forbidden conflation this codebase keeps paying for (DIVE-1927's paired
  # probe, DIVE-1989's dropped rows): a row that says `unknown` cannot be used
  # to answer "who delivered this", which is the whole load-bearing question on
  # the privileged re-send path. Root with no invoking user is an identity BY
  # DESIGN, so record it as `root`; `unknown` now means only the genuine
  # failure — a NON-root process whose USER we could not read — and a reader
  # seeing it should treat it as a defect, not as routine.
  local user; user=$(_actor_identity)
  # DIVE-2518: `user` above is what this invocation SAYS it is. `derived` is what
  # the uid measures. Carrying both is the point — one field cannot record a
  # disagreement, and a row that cannot record one is a row where a forged
  # $SUDO_USER leaves no trace at all. `claimed` is populated ONLY when they
  # disagree, so the common case adds one key and no noise, and a reader grepping
  # for `.claimed` gets exactly the rows worth looking at.
  local derived; derived=$(_actor_identity_derived)
  local claimed; claimed=$(_actor_identity_claim)
  local ts
  ts=$(date -Iseconds)
  local line
  # DIVE-2130: `--` before the positionals. `--args` does NOT stop jq's option
  # parsing — jq 1.7 still reads a later `--branch=probe` as an option and dies
  # with "Unknown option", stderr swallowed by the 2>/dev/null below. AUDIT_ARGS
  # is `("$@")` for most verbs, so ANY invocation carrying a flag rendered no row
  # at all, pass or fail. That is the half of this defect that predates DIVE-2518
  # and it is why the DIVE-2129 probe (`push … --branch=probe-nonexistent`) saw
  # nothing on 2026-07-26 while plain `push DIVE-N` refusals were still logging.
  # And a render failure now leaves a drop marker instead of evaporating: a row
  # the log cannot record is exactly what DIVE-1989 bought _audit_note_drop for.
  line=$(jq -cn \
    --arg ts "$ts" --arg u "$user" --arg c "$cmd" \
    --arg dv "$derived" --arg cl "$claimed" \
    --arg r "$result" --argjson code "$code" \
    --args '{ts:$ts, user:$u, cmd:$c, result:$r, code:($code|tonumber? // 0), args:$ARGS.positional}
            + (if $dv == "" then {} else {derived:$dv} end)
            + (if $cl == "" then {} else {claimed:$cl} end)' \
    -- "${sanitized[@]+"${sanitized[@]}"}" 2>/dev/null) \
    || { _audit_note_drop "$(jq -Rn --arg s "cmd=${cmd} result=${result} code=${code} args=${sanitized[*]:-}" '$s' 2>/dev/null)" \
           "render-failed"; return 0; }
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
  # DIVE-2598 it2: verb-local cleanup first (LIFO), because a `watch` teardown has
  # to leave the alt-screen before anything below prints — a diagnostic written
  # into a screen that is about to be torn down is a diagnostic the caller never
  # sees. These used to be their own `trap ... EXIT`, which replaced this one.
  declare -F _five_run_exit_handlers >/dev/null && _five_run_exit_handlers
  # DIVE-2598: the silent-non-zero backstop runs FIRST and unconditionally —
  # deliberately ahead of the AUDIT_CMD early-return below. AUDIT_CMD is only set
  # for mutating verbs, so hanging the report off it would have left every
  # read-only command able to die with a bare exit code and nothing said. The
  # reporting property belongs to the process, not to the audit subsystem.
  _report_silent_exit "$code"
  [[ -n "$AUDIT_CMD" ]] || return 0
  local result="ok"
  (( code != 0 )) && result="error"
  # DIVE-2130: `|| true` is load-bearing, not decoration. `set -e` is suspended for
  # the whole of a `||` list — INCLUDING inside the called function — so this is what
  # makes "audit is best-effort" true of the writer rather than only of its comments.
  # Without it, one non-zero status anywhere in audit_log truncates the EXIT trap and
  # the process dies mid-teardown, which is how the entire error class of rows went
  # missing here. Belt and braces: the bare-`return` root cause is fixed above.
  audit_log "$AUDIT_CMD" "$result" "$code" -- "${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"}" || true
}

# Serialize mutating calls against a single flock. Lock is released when the
# subshell exits, so even a crash inside the handler frees it. Re-entrancy:
# IN_REGISTRY_LOCK=1 lets cmd_clone -> cmd_create run the inner command
# without trying to re-acquire the same lock (which flock would block on).
