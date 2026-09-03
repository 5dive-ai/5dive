# -------- DIVE-3932: runs — first-class execution attempts (Proposal 2, v1) ----
#
# A RUN is one concrete attempt by ONE agent to advance ONE task. It is the
# operational unit BENEATH the task and it does NOT replace `5dive trace`:
#
#   trace  — the causal story of an ident: goal -> delegation -> attempt ->
#            rejection -> retry -> gate -> ship. Company narrative, human-shaped.
#   run    — "what exactly happened during this ONE activation of this agent?"
#            Started, ended, outcome, attempt number, journal window, usage.
#
# Neither answers the other's question, which is why both exist. `trace` renders
# run ids as anchors (see cmd_trace.sh) and `run show` names the task back.
#
# EVERY WRITER HERE IS BEST-EFFORT AND NEVER FAILS ITS CALLER. Runs are evidence
# ABOUT the work, never part of it — the same posture as ledger_emit and
# audit_log, and for the same measured reason: a `task done` that errored because
# a bookkeeping insert failed would be a worse outcome than a missing receipt.
# Every function returns 0.
#
# The store is the shared task board (group-writable sqlite), so no root and no
# lock: sqlite serializes its own writes under busy_timeout, exactly as the task
# queue does.

# _run_id — a fresh run id. Sortable by construction: 11 hex of epoch-ms then 3
# hex of entropy, so `ORDER BY id` and `ORDER BY started_at` agree even inside
# one second, and a listing never needs a secondary sort to look sane.
# Falls back to whole seconds where %N is unsupported (busybox date); the id
# stays unique on the random tail, it just sorts coarser.
_run_id() {
  local ms
  ms=$(date +%s%3N 2>/dev/null) || ms=""
  [[ "$ms" =~ ^[0-9]+$ ]] || ms=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
  printf 'R-%011x%03x' "$ms" $((RANDOM % 4096))
}

# _run_seat — the agent this run belongs to, derived from the CALLER'S UID
# through the sealed seam, never from $SUDO_USER. Same reasoning as
# _task_session_open: SUDO_USER is an ordinary variable nothing verifies, and
# DIVE-2518 already closed that hole for actor attribution. A caller that is not
# an `agent-*` seat (cron, root, a human shell) falls back to the BOARD identity
# so a run opened from a shell is still attributable; empty only if neither
# resolver knows, and an empty agent reads "unattributed", never a guess.
_run_seat() {
  local who=""
  who=$(_gate_uid_to_agent "$(_gate_caller_uid 2>/dev/null)" 2>/dev/null) || who=""
  [[ -n "$who" ]] || who=$(task_actor 2>/dev/null) || who=""
  printf '%s' "$who"
}

# _run_role <task_id> <agent> — maker | verifier | ''(unknown).
# Read from the row's own loop spec rather than guessed from the verb, because
# the SAME seat can be maker on one row and verifier on the next, and the role is
# what makes "verifier rejection rate" separable from "maker failure rate".
_run_role() {
  local id="$1" who="${2:-}"
  [[ "$id" =~ ^[0-9]+$ && -n "$who" ]] || return 0
  local v m
  v=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};" 2>/dev/null) || v=""
  m=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id};" 2>/dev/null) || m=""
  if [[ -n "$v" && "$who" == "$v" ]]; then printf 'verifier'
  elif [[ -n "$m" && "$who" == "$m" ]]; then printf 'maker'
  elif [[ -n "$v" ]]; then printf 'maker'
  fi
  return 0
}

# _run_journal_unit <agent> — the systemd unit whose journal covers this seat.
#
# The seat arrives as a BOARD name (`dev`, `quinn`) because that is what
# _gate_uid_to_agent resolves a uid to, while the unit is templated on the same
# short name (`5dive-agent@dev.service`) — so an `agent-` prefix is stripped if a
# caller passes the unix account name instead. The unit is RECORDED, never
# probed: whether the journal is readable is a question for `run logs` at read
# time, and refusing to record a name because this process cannot read it would
# lose the one string that lets a privileged reader find the window later.
# Empty only for a caller with no seat at all (cron, a bare root shell); `run
# logs` then says there is no interval rather than opening the wrong one.
_run_journal_unit() {
  local who="${1:-}"
  [[ -n "$who" ]] || return 0
  [[ "$who" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  printf '5dive-agent@%s.service' "${who#agent-}"
}

# _run_journal_cursor <unit> — journald's cursor at this instant, or empty.
# `-n 0 --show-cursor` prints only the `-- cursor: s=…` trailer. A seat that
# cannot read that unit's journal yields empty, stored NULL: `run logs` then uses
# --since/--until off the run's own timestamps.
_run_journal_cursor() {
  local unit="${1:-}"
  [[ -n "$unit" ]] || return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  journalctl -u "$unit" -n 0 --show-cursor -q 2>/dev/null \
    | sed -n 's/^-- cursor: //p' | head -1
  return 0
}

# run_current <task_id> [agent] — the OPEN run this seat holds on this task, or ''.
run_current() {
  local id="$1" who="${2:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$who" ]] || who=$(_run_seat)
  db "SELECT id FROM runs
       WHERE task_id=${id} AND status='running'
         AND agent IS $(sqlq_or_null "$who")
       ORDER BY started_at DESC, id DESC LIMIT 1;" 2>/dev/null || true
  return 0
}

# run_open <task_id> <ident> [wake_reason] [retry_of] — open (or reuse) a run and
# print its id.
#
# IDEMPOTENT PER (task, agent, open run), for the same reason _task_session_open
# is: a second `task start` inside one activation must not manufacture a second
# attempt, or `attempt` stops counting attempts and starts counting keystrokes.
# A genuine retry comes in through `run retry`, which passes retry_of and always
# opens a new row — that is the distinction the spec asks for ("a resumed attempt
# creates a NEW run linked with retry_of, not a silent rewrite").
run_open() {
  local id="$1" ident="${2:-}" wake="${3:-}" retry_of="${4:-}" for_agent="${5:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  local who role rid prev attempt unit cursor sid
  # for_agent is the DISPATCHER override: the heartbeat claims a row on a seat's
  # behalf, so the run belongs to that seat and not to the root process that moved
  # it. Everywhere else it is empty and the seat is derived, never supplied — a
  # caller-supplied identity is exactly what DIVE-2518 removed from attribution.
  who="$for_agent"
  [[ -n "$who" ]] || who=$(_run_seat)
  if [[ -z "$retry_of" ]]; then
    rid=$(run_current "$id" "$who")
    if [[ -n "$rid" ]]; then printf '%s' "$rid"; return 0; fi
  fi
  role=$(_run_role "$id" "$who")
  # attempt = 1 + this seat's completed attempts on this row. Scoped to the SEAT,
  # not the row: "coder attempt 2" is the number a reader wants, and a row worked
  # by a maker and a verifier would otherwise show the verifier as attempt 2 of
  # something it never attempted.
  attempt=$(db "SELECT COUNT(*)+1 FROM runs
                 WHERE task_id=${id} AND agent IS $(sqlq_or_null "$who");" 2>/dev/null) || attempt=1
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
  prev="$retry_of"
  [[ -n "$prev" ]] || prev=$(db "SELECT id FROM runs
                                  WHERE task_id=${id} AND agent IS $(sqlq_or_null "$who")
                                  ORDER BY started_at DESC, id DESC LIMIT 1;" 2>/dev/null) || prev=""
  unit=$(_run_journal_unit "$who")
  cursor=$(_run_journal_cursor "$unit")
  sid=$(_task_session_env_id 2>/dev/null) || sid=""
  # A dispatcher-opened run has no session of its own — the seat's session id is
  # not knowable from here and inventing one would name a transcript that does not
  # exist. Left NULL; the seat's own `task start` reuses this row and does not
  # backfill it either, because the field means "the session that OPENED this
  # attempt" and that was the dispatcher.
  [[ -z "$for_agent" ]] || sid=""
  rid=$(_run_id)
  db "INSERT INTO runs
        (id, task_id, ident, agent, role, attempt, parent_run_id, retry_of,
         wake_reason, runtime_type, model, session_id, journal_unit,
         journal_cursor_start, status)
      VALUES ($(sqlq "$rid"), ${id}, $(sqlq_or_null "$ident"), $(sqlq_or_null "$who"),
              $(sqlq_or_null "$role"), ${attempt}, $(sqlq_or_null "$prev"),
              $(sqlq_or_null "$retry_of"), $(sqlq_or_null "$wake"),
              $(sqlq_or_null "${FIVEDIVE_RUNTIME:-${CLAUDE_CODE_SESSION_ID:+claude}}"),
              $(sqlq_or_null "${ANTHROPIC_MODEL:-}"), $(sqlq_or_null "$sid"),
              $(sqlq_or_null "$unit"), $(sqlq_or_null "$cursor"), 'running');" \
    >/dev/null 2>&1 || { printf ''; return 0; }
  run_event "$rid" run.started "{\"wake_reason\":$(_run_json_str "$wake"),\"attempt\":${attempt}}"
  printf '%s' "$rid"
  return 0
}

# _run_json_str <s> — a JSON string literal for the small data_json payloads
# written here. jq is present on every box the CLI supports, but these writers
# run on the hot status path and must never fork; the payloads are short and
# control-character-free by construction (verbs, idents, agent names), so
# escaping the two characters JSON forbids raw is sufficient and honest.
_run_json_str() {
  local s="${1:-}"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\t'/ }
  printf '"%s"' "$s"
}

# run_event <run_id> <kind> [data_json] [actor] — append one milestone.
run_event() {
  local rid="${1:-}" kind="${2:-}" data="${3:-}" actor="${4:-}"
  [[ -n "$rid" && -n "$kind" ]] || return 0
  [[ -n "$actor" ]] || actor=$(_run_seat)
  db "INSERT INTO run_events (run_id, kind, actor, data_json)
      VALUES ($(sqlq "$rid"), $(sqlq "$kind"), $(sqlq_or_null "$actor"),
              $(sqlq_or_null "$data"));" >/dev/null 2>&1 || true
  return 0
}

# run_close <run_id> <status> <outcome> [exit_code] [error_class] [error_summary]
#
# status is the RUN's fate (completed | failed | abandoned | parked); outcome is
# the human-readable end boundary (handed_to_verifier, task_done, gate_filed,
# process_exit, reassigned…). Two fields on purpose: "the attempt finished
# cleanly" and "what it finished INTO" are different questions, and the metrics
# below need to count them separately — a run that ends `completed /
# handed_to_verifier` and one that ends `completed / task_done` are both
# successes, while `parked / gate_filed` is neither a success nor a failure and
# must not be scored as either.
#
# Closing an already-closed run is a no-op: the WHERE clause keys on
# status='running', so a double close (a verb that funnels twice, a retry racing
# a crash sweep) cannot rewrite a terminal record.
run_close() {
  local rid="${1:-}" status="${2:-completed}" outcome="${3:-}" code="${4:-}"
  local eclass="${5:-}" esum="${6:-}"
  [[ -n "$rid" ]] || return 0
  local unit cursor
  unit=$(db "SELECT COALESCE(journal_unit,'') FROM runs WHERE id=$(sqlq "$rid");" 2>/dev/null) || unit=""
  cursor=$(_run_journal_cursor "$unit")
  [[ "$code" =~ ^[0-9]+$ ]] || code=""
  db "UPDATE runs
         SET status=$(sqlq "$status"), outcome=$(sqlq_or_null "$outcome"),
             ended_at=datetime('now'), exit_code=${code:-NULL},
             error_class=$(sqlq_or_null "$eclass"),
             error_summary=$(sqlq_or_null "$esum"),
             journal_cursor_end=$(sqlq_or_null "$cursor")
       WHERE id=$(sqlq "$rid") AND status='running';" >/dev/null 2>&1 || true
  run_event "$rid" run.completed "{\"status\":$(_run_json_str "$status"),\"outcome\":$(_run_json_str "$outcome")}"
  return 0
}

# run_touch_human <run_id> — mark that this attempt required a person.
# "human touches per shipped task" is the metric the zero-human thesis is graded
# on, so it is recorded as a FLAG on the attempt rather than inferred later from
# whether a gate row happens to exist: a gate that was filed and withdrawn still
# cost a human, and an inference off the surviving rows would lose it.
run_touch_human() {
  local rid="${1:-}"
  [[ -n "$rid" ]] || return 0
  db "UPDATE runs SET human_touch=1 WHERE id=$(sqlq "$rid");" >/dev/null 2>&1 || true
  return 0
}

# run_usage_add <run_id> <metric> <value> <unit> <source> <quality> <scope> [metadata_json]
#
# PROVENANCE IS MANDATORY, and that is the point of the table. source/quality/
# scope are positional and unguessable on purpose: a caller that cannot say where
# a number came from is a caller that should be writing quality='unavailable'.
# A datum with quality='unavailable' stores a NULL value and still occupies a
# row — "we looked and this runtime does not expose it" is a different fact from
# "nobody looked", and only a stored row can tell them apart.
run_usage_add() {
  local rid="${1:-}" metric="${2:-}" value="${3:-}" unit="${4:-}"
  local source="${5:-}" quality="${6:-}" scope="${7:-run}" meta="${8:-}"
  [[ -n "$rid" && -n "$metric" ]] || return 0
  case "$source"  in runtime|provider|account|inferred) ;; *) source="inferred" ;; esac
  case "$quality" in exact|estimated|unavailable) ;;     *) quality="unavailable" ;; esac
  case "$scope"   in run|session|account) ;;             *) scope="run" ;; esac
  [[ "$quality" == "unavailable" ]] && value=""
  [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || value=""
  db "INSERT INTO run_usage (run_id, metric, value, unit, source, quality, scope, metadata_json)
      VALUES ($(sqlq "$rid"), $(sqlq "$metric"), ${value:-NULL}, $(sqlq_or_null "$unit"),
              $(sqlq "$source"), $(sqlq "$quality"), $(sqlq "$scope"),
              $(sqlq_or_null "$meta"));" >/dev/null 2>&1 || true
  return 0
}

# _run_close_for_task <task_id> <status> <outcome> — close whatever open run this
# seat holds on the row. The status funnel calls this; it must stay a no-op when
# no run was ever opened (a board that predates DIVE-3932, a verb reached without
# a claim), which is why run_close on an empty id returns 0.
_run_close_for_task() {
  local id="$1" status="${2:-completed}" outcome="${3:-}" for_agent="${4:-}" eclass="${5:-}"
  local rid; rid=$(run_current "$id" "$for_agent")
  [[ -n "$rid" ]] || return 0
  run_close "$rid" "$status" "$outcome" "" "$eclass"
  return 0
}

# _run_event_for_task <task_id> <kind> [data_json] — milestone onto this seat's
# open run, if there is one.
_run_event_for_task() {
  local id="$1" kind="$2" data="${3:-}"
  local rid; rid=$(run_current "$id")
  [[ -n "$rid" ]] || return 0
  run_event "$rid" "$kind" "$data"
  return 0
}
