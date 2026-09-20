# shellcheck shell=bash
# ---------------------------------------------------------------------------
# DIVE-4589 — historical auth-profile metering.
#
# 5dive already knows WHICH account a seat is on. What it did not store is WHEN
# it was on it. Every historical turn was attributed with the seat's CURRENT
# authProfile, so the instant a seat moved accounts (manual set, rotation,
# failover, a rename) the whole past was re-attributed to the new profile — and
# the only repair available was a hand-typed constant in a bespoke script
# (DIVE-4584's `T1=1789512540`), which no later reader can re-derive.
#
# Two append-only stores fix that, both in tasks.db (see src/lib/tasks_db.sh):
#
#   account_binding_events   — (ts, agent, account, reason). The binding that was
#                              LIVE at an instant. Written BEFORE the new
#                              credential is used, never rewritten.
#   account_usage_samples    — (account, as_of, five/seven pct + reset,
#                              source_agent). The provider's own numbers over
#                              time, instead of one overwritten latest reading.
#
# EVERY function here is best-effort and returns 0. A metering store that cannot
# be written must never fail the rebind, the rotation or the table that a human
# asked for — losing one event costs one turn's attribution confidence, and that
# loss is REPORTED (`current-binding-fallback`), not hidden.
# ---------------------------------------------------------------------------

# The store. Resolved at call time, so a harness that points TASKS_DB at a
# scratch file after sourcing still lands there.
account_history_db() { printf '%s' "${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"; }

# Writable store + sqlite3 present. No `tasks_db_init` from here: init is a
# root-shaped path (it can create /var/lib/5dive/tasks) and a metering write must
# not be the thing that demands root.
_account_history_writable() {
  local db; db=$(account_history_db)
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db" && -w "$db" ]] || return 1
  # DIVE-2249: route through the same fence every other writer uses, so a
  # sourced-library caller cannot append fixture rows to the production board.
  if declare -F _tasks_store_fence >/dev/null 2>&1; then _tasks_store_fence "INSERT"; fi
  return 0
}

_account_history_readable() {
  local db; db=$(account_history_db)
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db" && -r "$db" ]] || return 1
  return 0
}

# _account_history_ensure — create the two tables if this store predates them.
# Cheap: one read of sqlite_master, and the CREATEs only on a store that lacks
# them. The canonical definitions live in src/lib/tasks_db.sh; this is the
# self-heal for a board whose migration has not run yet (an unprivileged seat
# cannot run `task init`).
_account_history_ensure() {
  local db has; db=$(account_history_db)
  has=$(sqlite3 -cmd ".timeout 5000" "$db" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='account_binding_events' LIMIT 1;" 2>/dev/null)
  [[ "$has" == "1" ]] && return 0
  sqlite3 -cmd ".timeout 5000" "$db" <<'SQL' >/dev/null 2>&1 || return 1
CREATE TABLE IF NOT EXISTS account_binding_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      INTEGER NOT NULL,
  agent   TEXT NOT NULL,
  account TEXT,
  reason  TEXT
);
CREATE INDEX IF NOT EXISTS idx_account_binding_agent_ts
  ON account_binding_events(agent, ts);
CREATE TABLE IF NOT EXISTS account_usage_samples (
  account      TEXT NOT NULL,
  as_of        INTEGER NOT NULL,
  five_pct     REAL,
  five_reset   TEXT,
  seven_pct    REAL,
  seven_reset  TEXT,
  source_agent TEXT NOT NULL,
  UNIQUE(account, as_of)
);
CREATE INDEX IF NOT EXISTS idx_account_usage_samples_acct
  ON account_usage_samples(account, as_of);
SQL
  return 0
}

# account_binding_latest <agent> — the account bound by the newest event, or
# empty when the agent has no history at all. Prints `-` for an explicit UNBOUND
# event so "unbound" and "never recorded" stay distinguishable.
account_binding_latest() {
  local agent="${1:-}" db row
  [[ -n "$agent" ]] || return 0
  _account_history_readable || return 0
  db=$(account_history_db)
  row=$(sqlite3 -cmd ".timeout 5000" "$db" \
    "SELECT COALESCE(account,'-') FROM account_binding_events
      WHERE agent=$(sqlq "$agent") ORDER BY ts DESC, id DESC LIMIT 1;" 2>/dev/null) || return 0
  printf '%s' "$row"
  return 0
}

# account_binding_at <agent> <epoch> — the account that was live for <agent> at
# <epoch>: the newest event at or before it. EMPTY means "no event that old" —
# the caller must then say so (`current-binding-fallback` / `unknown`) rather
# than reaching for the current config and calling it history.
account_binding_at() {
  local agent="${1:-}" ts="${2:-}" db
  [[ -n "$agent" && "$ts" =~ ^[0-9]+$ ]] || return 0
  _account_history_readable || return 0
  db=$(account_history_db)
  sqlite3 -cmd ".timeout 5000" "$db" \
    "SELECT COALESCE(account,'') FROM account_binding_events
      WHERE agent=$(sqlq "$agent") AND ts <= $ts
      ORDER BY ts DESC, id DESC LIMIT 1;" 2>/dev/null || true
  return 0
}

# account_binding_record <agent> <account|""> [reason] [ts]
#
# Append one binding event. Call it BEFORE the new credential is reachable (the
# registry write / env rewrite / symlink re-point), which is what makes the
# event's ts a lower bound on the first turn that could have used it.
#
# Idempotent against a no-op rebind: if the newest event already names this
# account, nothing is written — otherwise every `config set` that merely touched
# a neighbouring key would forge a rebind that never happened. A GENUINE re-bind
# to the same account after a different one is still recorded, because the
# comparison is against the newest event, not against history.
account_binding_record() {
  local agent="${1:-}" account="${2:-}" reason="${3:-}" ts="${4:-}" db prev
  [[ -n "$agent" ]] || return 0
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=$(date +%s)
  [[ -n "$reason" ]] || reason="${_5D_BINDING_REASON:-config-set}"
  _account_history_writable || return 0
  _account_history_ensure  || return 0
  db=$(account_history_db)
  prev=$(account_binding_latest "$agent")
  if [[ -n "$prev" ]]; then
    [[ "$prev" == "-" ]] && prev=""
    [[ "$prev" == "$account" ]] && return 0
  fi
  sqlite3 -cmd ".timeout 5000" "$db" \
    "INSERT INTO account_binding_events(ts,agent,account,reason)
       VALUES ($ts, $(sqlq "$agent"), $(sqlq_or_null "$account"), $(sqlq_or_null "$reason"));" \
    >/dev/null 2>&1 || true
  return 0
}

# account_usage_sample_record <account> <as_of> <five_pct> <five_reset> <seven_pct> <seven_reset> <source_agent>
#
# Append ONE provider observation. source_agent is MANDATORY — a percentage with
# no seat behind it is a recall of somebody's last turn, not an observation, and
# the acceptance criterion "do not insert recalled/stale readings as fresh
# observations" is unenforceable without knowing whose cache answered. The
# UNIQUE(account, as_of) collision is the second half of the same rule: reading
# the same statusline cache ten times inserts one row, because a sample is keyed
# by when the PROVIDER measured, never by when we looked.
account_usage_sample_record() {
  local acct="${1:-}" as_of="${2:-}" fp="${3:-}" fr="${4:-}" sp="${5:-}" sr="${6:-}" src="${7:-}" db
  [[ -n "$acct" && -n "$src" && "$src" != "null" ]] || return 0
  [[ "$as_of" =~ ^[0-9]+$ ]] || return 0
  [[ "$fp" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fp=""
  [[ "$sp" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || sp=""
  # Nothing measured is nothing to store.
  [[ -n "$fp" || -n "$sp" ]] || return 0
  _account_history_writable || return 0
  _account_history_ensure  || return 0
  db=$(account_history_db)
  sqlite3 -cmd ".timeout 5000" "$db" \
    "INSERT OR IGNORE INTO account_usage_samples
       (account,as_of,five_pct,five_reset,seven_pct,seven_reset,source_agent)
       VALUES ($(sqlq "$acct"), $as_of, ${fp:-NULL}, $(sqlq_or_null "$fr"),
               ${sp:-NULL}, $(sqlq_or_null "$sr"), $(sqlq "$src"));" \
    >/dev/null 2>&1 || true
  return 0
}

# account_usage_samples_json [<since-epoch>] [<account>] — the raw history, JSON
# array, newest last. Empty array when the store has nothing (never an error:
# absence of history is a legitimate answer and the presenters say so).
account_usage_samples_json() {
  local since="${1:-0}" acct="${2:-}" db where out
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  _account_history_readable || { printf '[]'; return 0; }
  db=$(account_history_db)
  where="as_of >= $since"
  [[ -n "$acct" ]] && where="$where AND account = $(sqlq "$acct")"
  out=$(sqlite3 -cmd ".timeout 5000" -json "$db" \
    "SELECT account, as_of AS asOf, five_pct AS fivePct, five_reset AS fiveResetsAt,
            seven_pct AS sevenPct, seven_reset AS sevenResetsAt,
            source_agent AS sourceAgent
       FROM account_usage_samples WHERE $where ORDER BY account, as_of;" 2>/dev/null) || out=""
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
  return 0
}

# account_binding_events_json [<since-epoch>] [<agent>] — the binding trail.
# Deliberately NOT fenced at <since>: the event that explains a turn inside the
# window is usually OLDER than the window. `since` filters the rows shown, so it
# defaults to everything.
account_binding_events_json() {
  local since="${1:-0}" agent="${2:-}" db where out
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
  _account_history_readable || { printf '[]'; return 0; }
  db=$(account_history_db)
  where="ts >= $since"
  [[ -n "$agent" ]] && where="$where AND agent = $(sqlq "$agent")"
  out=$(sqlite3 -cmd ".timeout 5000" -json "$db" \
    "SELECT ts, agent, account, reason FROM account_binding_events
      WHERE $where ORDER BY ts, id;" 2>/dev/null) || out=""
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
  return 0
}

# account_usage_history_rows <since> [<account>] — the appended provider samples
# joined into per-account series with their bracketed deltas. Read-only over the
# group-readable task store, so it needs no root: the whole point of persisting
# the readings is that consulting them no longer means reading sibling homes.
account_usage_history_rows() {
  local since="${1:-0}" acct="${2:-}" samples
  samples=$(account_usage_samples_json "$since" "$acct")
  jq -c '
    # A window RESET makes two samples incomparable — either the vendor'"'"'s reset
    # stamp moved, or the percentage fell (a plan meter only rises inside one
    # window). Either tell is enough, and when one fires the delta is `null`
    # with `resetCrossed: true` rather than a number computed across the seam.
    def reset($a; $b; pk; rk):
      (($a[rk] != null and $b[rk] != null and $a[rk] != $b[rk])
       or ($a[pk] != null and $b[pk] != null and $b[pk] < $a[pk]));
    group_by(.account)
    | map( (sort_by(.asOf)) as $r
         | ($r|first) as $f | ($r|last) as $l
         | {account: $f.account,
            samples: ($r|length),
            firstAsOf: $f.asOf, lastAsOf: $l.asOf,
            sourceAgents: ($r|map(.sourceAgent)|unique),
            latest: $l,
            resetCrossed: (if ($r|length) < 2 then false else reset($f; $l; "sevenPct"; "sevenResetsAt") end),
            sevenDayPpDelta: (if ($r|length) < 2 or reset($f; $l; "sevenPct"; "sevenResetsAt")
                                 or $f.sevenPct == null or $l.sevenPct == null then null
                              else ($l.sevenPct - $f.sevenPct) end),
            fiveHourPpDelta: (if ($r|length) < 2 or reset($f; $l; "fivePct"; "fiveResetsAt")
                                 or $f.fivePct == null or $l.fivePct == null then null
                              else ($l.fivePct - $f.fivePct) end)} )
    | sort_by(.account)' <<<"$samples"
}
