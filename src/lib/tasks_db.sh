
# -------- tasks + org store (sqlite) --------
#
# A light, host-shared task queue + agent org-chart, kept SEPARATE from the
# root-only agent registry. It lives in a GROUP-WRITABLE subdir so any agent
# (every agent-<x> user is in group `claude`) can add/list/update tasks
# WITHOUT sudo — these are high-frequency, low-risk operations, unlike
# `agent create` which provisions Linux users and stays root-only.
#
# Storage: /var/lib/5dive/tasks/tasks.db (sqlite, WAL). The dir is 2770
# root:claude (setgid) and we run under umask 0002 so the .db plus its
# -wal/-shm sidecars stay group-writable for the next agent's connection.

TASKS_DIR="${STATE_DIR}/tasks"
TASKS_DB="${TASKS_DIR}/tasks.db"

# Quote an arbitrary string as a SQL literal: double embedded single quotes
# and wrap. The sqlite3 CLI has no ergonomic bind-parameter path from bash,
# so this is the safe way to inline a shell value — use it for EVERY
# user-supplied TEXT value to keep injection impossible.
sqlq() {
  local s=${1//\'/\'\'}
  printf "'%s'" "$s"
}

# SQL NULL for empty input, otherwise a quoted literal.
sqlq_or_null() {
  [[ -z "${1:-}" ]] && { printf 'NULL'; return; }
  sqlq "$1"
}

# Agents can't apt-install, so route a missing binary to the repair path
# rather than a raw "sqlite3: command not found".
require_sqlite() {
  command -v sqlite3 >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" \
    "sqlite3 not installed — run: sudo 5dive doctor --repair  (or: sudo apt-get install -y sqlite3)"
}

# Idempotent schema. CREATE IF NOT EXISTS throughout, so re-applying it on
# every command is cheap and self-heals a fresh box. DIVE-N idents come from
# a trigger off the autoincrement rowid.
# NOTE: projects/loop_runs/supervisor_events are ALSO defined inside gated
# one-shot migration blocks in _tasks_db_migrate() below — edit both copies
# together; tests/schema_sync_unit.sh fails CI if they diverge.
_tasks_schema() {
  cat <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- Projects (DIVE-484). A project is BOTH an ident namespace (prefix + its own
-- counter -> FROG-1, FROG-2 …, numbering scheme B) AND a lightweight workspace
-- (name/description/goal/folder/coordinator). Modeled on paperclipai/paperclip:
-- they keep the ident counter on the namespace row (companies.issue_prefix +
-- issue_counter); we merge that with their projects fields onto one row.
--   key       slug, the stable handle used on the CLI (e.g. 'dive', 'frog')
--   prefix    ident prefix, UNIQUE (e.g. 'DIVE', 'FROG')
--   counter   per-project monotone task counter; the ident trigger bumps it
--   lead_agent the project's coordinator (auto-assignee for its tasks; cf DIVE-333)
--   folder     working dir the project's tasks/agents default into (advisory)
-- The default project key='dive' prefix='DIVE' is seeded below so every existing
-- DIVE-<n> ident is preserved (back-compat — see _tasks_db_migrate's dive backfill).
CREATE TABLE IF NOT EXISTS projects (
  key         TEXT PRIMARY KEY,
  prefix      TEXT NOT NULL UNIQUE,
  counter     INTEGER NOT NULL DEFAULT 0,
  name        TEXT,
  description TEXT,
  goal        TEXT,
  folder      TEXT,
  lead_agent  TEXT,
  status      TEXT NOT NULL DEFAULT 'active',
  archived_at TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT OR IGNORE INTO projects (key, prefix, name, description)
  VALUES ('dive', 'DIVE', 'Dive', 'Default project (the original DIVE-N queue)');

CREATE TABLE IF NOT EXISTS tasks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ident       TEXT UNIQUE,
  -- DIVE-484: which project this task belongs to + its per-project number.
  -- project_key defaults to 'dive' so legacy inserts and old call sites keep
  -- working; issue_number is the prefix-local sequence (DIVE keeps issue_number
  -- = the global id for back-compat, new projects count 1,2,3…).
  project_key  TEXT NOT NULL DEFAULT 'dive' REFERENCES projects(key),
  issue_number INTEGER,
  title       TEXT NOT NULL,
  body        TEXT,
  status      TEXT NOT NULL DEFAULT 'todo',
  priority    TEXT NOT NULL DEFAULT 'medium',
  assignee    TEXT,
  created_by  TEXT,
  parent_id   INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
  started_at  TEXT,
  done_at     TEXT,
  updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
  -- Result text captured at close time via `5dive task done <id> --result=…`.
  -- Lets dashboard + creators read what the assignee produced without
  -- scraping the tmux pane. NULL for open tasks + legacy rows closed before
  -- the column existed.
  result      TEXT,
  -- Human-gate fields (Human Task Inbox, DIVE-103; parent feature DIVE-102).
  -- A task an agent can't finish without a human (a decision, a secret, an
  -- approval, a manual step) is parked with `5dive task need`: status=blocked
  -- + need_type set. The inbox is the still-pending gates — see the canonical
  -- definition just below (need_type IS NOT NULL AND need_answered_at IS NULL).
  -- All NULL for ordinary tasks. need_options is pipe-delimited (decision
  -- choices). need_answered_at is the single "answered" signal — set by
  -- `task answer` for EVERY gate type, so the inbox (need_type IS NOT NULL AND
  -- need_answered_at IS NULL) is decoupled from the overloaded `status` column
  -- (a task can be both human-gated AND blocked-by another task). need_answer
  -- holds the value for decision/approval/manual; for `secret` it stays NULL —
  -- a raw key must NEVER land in this group-readable db (answer records only
  -- that it was provided, and the agent loads the key out-of-band).
  need_type        TEXT,
  ask              TEXT,
  need_options     TEXT,
  -- DIVE-148. recommend is the option text the filing agent advises (strongly
  -- encouraged for decision/approval). When set it leads the human alert as
  -- '✅ Recommended: <X>' and that option's tap button sorts first (⭐). For a
  -- decision it must match one of need_options; for approval it's free text
  -- (typically 'approved'/'denied'). NULL when the agent gave no recommendation.
  recommend        TEXT,
  need_answer      TEXT,
  need_answered_at TEXT,
  -- DIVE-394: provenance of the answer. Records WHO cleared the gate (actor
  -- label, prefixed `human:` when answered through a verified human path that
  -- passed --human). Hard-line gates (approval/secret) are root-gated in
  -- cmd_task_answer so a plain agent can't clear them; this column is the audit
  -- trail for every answer regardless of type.
  need_answered_by TEXT,
  -- DIVE-756: tamper-evidence for gate closures. need_answered_uid is the REAL
  -- pre-sudo invoker ($SUDO_UID, falling back to the caller uid) — unlike
  -- need_answered_by it can't be masked by `sudo -u agent-X`. need_answer_sig is
  -- an HMAC (root-only gate-proof key) over the canonical closure facts
  -- (id|type|answer|by|answered_at|uid); a raw-sqlite write that bypasses
  -- cmd_task_answer can't forge it, so `gate-proof verify <id>` flags the closure
  -- as unsigned/invalid. Best-effort in drop 1 (signing needs a root context);
  -- enforcement of "no valid sig ⇒ reject" is a later flip, not here.
  need_answered_uid INTEGER,
  need_answer_sig  TEXT,
  -- DIVE-916: per-gate HUMAN nonce that closes the sudo->--human forge. On a
  -- hard human gate (approval/secret/manual) `task need` mints a 16-byte nonce,
  -- stores ONLY its SHA-256 here, and embeds the RAW nonce solely in the trusted
  -- tap artifacts (Telegram callback_data / dashboard approve payload) — the
  -- agent's LLM never sees it. `task answer` clears as human iff it presents ONE
  -- of: a matching --human-proof=<nonce>, a valid DIVE-519 --proof, or a
  -- non-agent SUDO_UID. A bare `sudo task answer --human` from an agent session
  -- (SUDO_UID=agent-*, no nonce) is rejected under enforcement. Hash-only at
  -- rest, so a group-readable db leak can't reconstruct the nonce.
  human_nonce_hash TEXT,
  -- Recurring task templates (DIVE step 1). kind='recurring' marks a row as a
  -- TEMPLATE, not work: it's excluded from the work board, the heartbeat TODO
  -- count + wake, and the human inbox, so it's never picked up directly.
  -- `schedule` is a 5-field cron expression; the step-2 materializer clones the
  -- template into a fresh kind='standard' todo when due and stamps
  -- last_fired_at. Ordinary tasks are kind='standard' (the default) with both
  -- schedule + last_fired_at NULL.
  kind             TEXT NOT NULL DEFAULT 'standard',
  schedule         TEXT,
  last_fired_at    TEXT,
  -- DIVE-138 step 2. A materialized instance links back to the recurring
  -- template it was cloned from via from_template_id (NULL for templates and
  -- ordinary tasks); the materializer's skip-if-open dedup keys on it. NOT a FK
  -- with cascade — deleting a template must not nuke its already-materialized
  -- instances' history. `fresh` (1/0/NULL) is the per-template clean-session
  -- pref copied onto each instance: when 1 the heartbeat sends /clear before
  -- working it regardless of the agent-level fresh setting.
  from_template_id INTEGER,
  fresh            INTEGER,
  -- DIVE-476: loop-spec columns — make a task's verify loop declarative + durable
  -- so the (c) deterministic verify-runner (DIVE-475) reads its inputs off the row
  -- instead of every caller re-passing them. acceptance_criteria = the human-
  -- readable done definition the verifier grades against; verify_command = the
  -- shell command `task verify` runs when --cmd is omitted (its exit code is the
  -- stop condition); max_iterations = the maker→verifier loop cap before
  -- stuck→escalate (DIVE-478); verifier = the agent that grades, separate from the
  -- maker (writer != grader, DIVE-477). All NULL for ordinary tasks.
  acceptance_criteria TEXT,
  verify_command      TEXT,
  max_iterations      INTEGER,
  verifier            TEXT,
  -- DIVE-824: per-run spend cap carried on the task so the on-host loop handoff
  -- has a real budget (sibling to the verify loop's --timeout). Stored verbatim
  -- as either a bare token count ("50000") or a dollar cost ("$1.50"); the loop
  -- runner maps the $-form to `claude --max-budget-usd` (hard) and the token-form
  -- to the raw Messages-API task_budget (was advisory-only on-host pre-DIVE-824).
  task_budget         TEXT,
  -- DIVE-477: maker→verifier loop state. iteration = how many times the maker has
  -- handed off to the verifier (bumped on each `task done` that routes, not on
  -- bounce-back). maker_agent = the original maker, stashed at first handoff so a
  -- verify FAIL (`task reject`) can bounce the task straight back to them; it
  -- survives re-routes (COALESCE keeps the first writer). Both NULL until a task
  -- enters a loop (verifier set + maker hands off).
  iteration           INTEGER,
  maker_agent         TEXT,
  -- DIVE-891: risk-tiered gates (adopted design DIVE-861). tier is set when the
  -- gate is filed: 0 = auto-clear (rec applies immediately, digest line only),
  -- 1 = agent-clearable + 48h TTL auto-applies the recommendation, 2 = hard
  -- human gate (never auto-applies; TTL only batches reminder pings). The T2
  -- category floor (spend/publish/secret/destructive/brand) is enforced in
  -- cmd_task_need, not trusted from the filer. NULL = legacy gate, treated as
  -- tier 2 (never auto-cleared). need_asked_at stamps gate filing time — the
  -- TTL clock (updated_at is useless for this: any row touch bumps it).
  -- gate_pinged_at = last time a TTL reminder batch included this gate, so the
  -- sweep re-pings weekly instead of every tick. wake_at: a parked task
  -- (task park --wake=...) auto-unparks when the heartbeat passes this time.
  tier                INTEGER,
  need_asked_at       TEXT,
  gate_pinged_at      TEXT,
  wake_at             TEXT,
  -- DIVE-931 secure credential drop: a --type=secret gate can name WHERE the
  -- value should land — secret_key is the env-var name, connector the
  -- /etc/5dive/connectors/<connector>.env stem. When both are set, the gate
  -- notify mints a burnable drop link (api /drop/mint) instead of the legacy
  -- "put it where I expect it" text. NULL on non-secret gates and on secret
  -- gates filed without a target (legacy behavior preserved). The VALUE is never
  -- stored here — only the destination coordinates.
  secret_key          TEXT,
  connector           TEXT,
  -- OSS-11 (DIVE-976) decision-memory precedent prefill. ask_shape is the
  -- normalized "shape key" of the ask (idents/nums/amounts/dates/hosts/names
  -- collapsed to typed placeholders) computed at gate-file time; precedent_ref
  -- is the prior answered gate whose answer prefilled this one's recommend (audit
  -- + digest provenance). Both advisory-only: they NEVER mutate tier or the clear
  -- path — precedent sources the VALUE of a rec the tier would surface anyway,
  -- it never widens what a gate can self-clear (the DIVE-916 invariant).
  -- OSS-20 precedent_kind: 'exact' when precedent_ref came from an EXACT ask_shape
  -- match, 'fuzzy' when it came from the token-set Jaccard>=0.8 fallback. NULL when
  -- no precedent sourced this gate. The digest splits acceptance by kind so the two
  -- match qualities are comparable; only 'exact' is promotion-eligible (OSS-21
  -- auto-clear reads exact match, never fuzzy). Advisory-only like precedent_ref.
  ask_shape           TEXT,
  precedent_ref       INTEGER,
  precedent_kind      TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_precedent ON tasks(need_type, ask_shape);

CREATE TABLE IF NOT EXISTS task_deps (
  task_id     INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  blocked_by  INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (task_id, blocked_by)
);

CREATE TABLE IF NOT EXISTS agents_org (
  name        TEXT PRIMARY KEY,
  reports_to  TEXT REFERENCES agents_org(name) ON DELETE SET NULL,
  role        TEXT,
  title       TEXT,
  updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS tasks_status_idx   ON tasks(status);
CREATE INDEX IF NOT EXISTS tasks_assignee_idx ON tasks(assignee, status);
CREATE INDEX IF NOT EXISTS tasks_parent_idx   ON tasks(parent_id);
CREATE INDEX IF NOT EXISTS tasks_project_idx  ON tasks(project_key);

-- DIVE-484: derive ident from the task's PROJECT (numbering scheme B). On insert
-- we bump that project's counter and stamp issue_number + ident=<prefix>-<n>. All
-- three statements run in the insert's implicit transaction, and tasks.db is a
-- single-writer store (busy_timeout serializes agents), so the counter can't race.
-- The tasks.ident UNIQUE index is the backstop. For the seeded 'dive' project the
-- counter starts at MAX(existing id) (see migration) so new DIVE-N continue the
-- historical sequence with no renumbering of existing rows.
CREATE TRIGGER IF NOT EXISTS tasks_ident_ai AFTER INSERT ON tasks
WHEN NEW.ident IS NULL
BEGIN
  UPDATE projects SET counter = counter + 1 WHERE key = NEW.project_key;
  UPDATE tasks
     SET issue_number = (SELECT counter FROM projects WHERE key = NEW.project_key),
         ident = (SELECT prefix FROM projects WHERE key = NEW.project_key)
                 || '-' || (SELECT counter FROM projects WHERE key = NEW.project_key)
   WHERE id = NEW.id;
END;

-- Touch updated_at on change. The WHEN guard stops the trigger recursing on
-- its own write (it only fires when updated_at wasn't itself just changed).
CREATE TRIGGER IF NOT EXISTS tasks_touch_au AFTER UPDATE ON tasks
WHEN OLD.updated_at = NEW.updated_at
BEGIN
  UPDATE tasks SET updated_at=datetime('now') WHERE id=NEW.id;
END;

-- The "organized view" behind `task ls`: open work, priority then age.
CREATE VIEW IF NOT EXISTS task_board AS
  SELECT ident, status, priority, COALESCE(assignee,'-') AS assignee,
         title, COALESCE(created_by,'-') AS created_by, created_at, id
  FROM tasks
  WHERE status NOT IN ('done','cancelled') AND kind = 'standard'
  ORDER BY CASE priority
             WHEN 'urgent' THEN 0 WHEN 'high' THEN 1
             WHEN 'medium' THEN 2 ELSE 3 END,
           created_at;

-- LOOP-7: one row per loop run. The control/kill window (`task loops`) reads
-- this live; `5dive usage` aggregates tokens_spent. loop_id is a handle, NOT a
-- task ident (loops orchestrate over backing tasks, whose ids live in
-- child_task_ids). Fully additive — never referenced by tasks/projects, so it
-- can't affect the existing queue. See loop-cli-impl-design.md §2.
CREATE TABLE IF NOT EXISTS loop_runs (
  loop_id          TEXT PRIMARY KEY,
  topology         TEXT NOT NULL,
  spawned_by_agent TEXT,
  spawned_by_task  INTEGER,
  stage            TEXT,
  iteration        INTEGER NOT NULL DEFAULT 0,
  tokens_spent     INTEGER NOT NULL DEFAULT 0,
  ceiling          INTEGER,
  status           TEXT NOT NULL DEFAULT 'running',
  stuck            INTEGER NOT NULL DEFAULT 0,
  kill_requested   INTEGER NOT NULL DEFAULT 0,
  child_task_ids   TEXT,
  result_json      TEXT,
  scorecard_json   TEXT,
  started_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS loop_runs_status_idx ON loop_runs(status);

-- DIVE-724 P1: append-only supervisor audit trail. Written ONLY by
-- `5dive supervisor --tick`: one event='observe' row per agent per tick when
-- its classification != healthy, plus an event='transition' row whenever the
-- classification changed since the agent's last recorded row (including
-- recovery back to healthy). signals is the full per-agent JSON snapshot at
-- that tick. Never updated or deleted — this trail is the P2 escalation
-- evidence (design doc §7). Additive, never referenced by tasks/projects.
CREATE TABLE IF NOT EXISTS supervisor_events (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  ts                  TEXT NOT NULL DEFAULT (datetime('now')),
  agent               TEXT NOT NULL,
  event               TEXT NOT NULL DEFAULT 'observe',
  classification      TEXT NOT NULL,
  cause               TEXT,
  prev_classification TEXT,
  signals             TEXT
);
CREATE INDEX IF NOT EXISTS supervisor_events_agent_idx ON supervisor_events(agent, id);

-- OSS-21: fleet-wide policy prefs as a tiny key/value store. Currently holds
-- precedent_autoclear (on|off, default off when the row is absent) — the switch
-- that lets a resolved tier-1 gate clear itself from proven human precedent.
-- Additive, never referenced by tasks/projects, so it can't touch the queue.
-- Defined identically inside _tasks_db_migrate for pre-existing stores; keep the
-- two copies byte-identical (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS task_prefs (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
SQL
}

# Create the group-writable tasks dir + db and apply the schema. Safe to call
# repeatedly; command functions call it first. If the dir is missing and we
# aren't root we can't create it (parent /var/lib/5dive is 2750), so emit a
# one-time bootstrap hint instead of a cryptic failure.
tasks_db_init() {
  require_sqlite
  umask 0002
  if [[ ! -d "$TASKS_DIR" ]]; then
    if [[ $EUID -eq 0 ]]; then
      mkdir -p "$TASKS_DIR"
      chown root:claude "$TASKS_DIR"
      chmod 2770 "$TASKS_DIR"
    else
      fail "$E_PERMISSION" "tasks store not initialised — run once: sudo 5dive task init"
    fi
  fi
  # Apply the schema only when the db is uninitialised. Re-running it on every
  # command would take a write lock each time and, under concurrent agents,
  # collide ("database is locked"); a cheap read of sqlite_master takes only a
  # WAL read-lock, which never blocks writers. .timeout lets a genuine
  # first-run race serialise instead of erroring. stdout is discarded because
  # `PRAGMA journal_mode=WAL` echoes "wal".
  local has
  has=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks' LIMIT 1;" 2>/dev/null)
  if [[ "$has" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" < <(_tasks_schema) >/dev/null \
      || fail "$E_GENERIC" "failed to initialise tasks db at $TASKS_DB"
    chmod 0660 "$TASKS_DB" 2>/dev/null || true
  else
    _tasks_db_migrate
  fi
}

# Idempotent additive migrations for already-initialised stores. sqlite has
# no `ADD COLUMN IF NOT EXISTS`, so we check pragma_table_info first. Each
# migration is a one-shot check + ALTER; running it on every init is cheap
# (single PRAGMA read). Add new column migrations to the array below.
_tasks_db_migrate() {
  local cols
  cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
         "SELECT name FROM pragma_table_info('tasks');" 2>/dev/null)
  local c
  # Each entry: "<column> <type>". Add new additive columns here; existing
  # rows backfill to NULL. Pure expand (no contract), so old queries/rows are
  # untouched and a downgrade still reads/writes the table fine.
  # NB project_key uses a constant DEFAULT (no REFERENCES) — sqlite forbids
  # ADD COLUMN with a foreign key unless the default is NULL. The FK is declared
  # in _tasks_schema for fresh boxes; on migrated stores the project_key→projects
  # link is enforced at the app layer (project add/resolve), same as parent_id's
  # behavior pre-FK. issue_number is the per-project sequence (DIVE-484).
  for c in 'result TEXT' 'need_type TEXT' 'ask TEXT' 'need_options TEXT' 'recommend TEXT' 'need_answer TEXT' 'need_answered_at TEXT' \
           "kind TEXT NOT NULL DEFAULT 'standard'" 'schedule TEXT' 'last_fired_at TEXT' \
           'from_template_id INTEGER' 'fresh INTEGER' \
           'parked_at TEXT' 'park_reason TEXT' 'need_answered_by TEXT' \
           'need_answered_uid INTEGER' 'need_answer_sig TEXT' \
           'escalated_at TEXT' 'escalated_by TEXT' \
           "project_key TEXT NOT NULL DEFAULT 'dive'" 'issue_number INTEGER' \
           'acceptance_criteria TEXT' 'verify_command TEXT' 'max_iterations INTEGER' 'verifier TEXT' \
           'iteration INTEGER' 'maker_agent TEXT' 'task_budget TEXT' \
           'tier INTEGER' 'need_asked_at TEXT' 'gate_pinged_at TEXT' 'wake_at TEXT' \
           'secret_key TEXT' 'connector TEXT' 'human_nonce_hash TEXT' \
           'ask_shape TEXT' 'precedent_ref INTEGER' 'precedent_kind TEXT'; do
    if ! printf '%s\n' "$cols" | grep -qx "${c%% *}"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE tasks ADD COLUMN ${c};" >/dev/null 2>&1 || true
    fi
  done
  # OSS-11 precedent-lookup index (idempotent; harmless if the columns just
  # backfilled to NULL above — an all-NULL ask_shape simply never matches).
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "CREATE INDEX IF NOT EXISTS idx_tasks_precedent ON tasks(need_type, ask_shape);" >/dev/null 2>&1 || true

  # DIVE-484 projects migration — ONE-SHOT, gated on the projects table's absence
  # so it doesn't take a write lock on every command. Runs after the column loop
  # above guarantees project_key + issue_number exist. Single transaction:
  #   * create + seed the default 'dive' project (prefix DIVE, preserving history)
  #   * backfill legacy rows: issue_number = the existing global id (NO renumber,
  #     so every current DIVE-<n> ident stays byte-identical)
  #   * sync dive.counter to MAX so new DIVE-N continue the historical sequence
  #   * swap the old DIVE-hardcoded ident trigger for the project-aware one
  local has_projects
  has_projects=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='projects' LIMIT 1;" 2>/dev/null)
  if [[ "$has_projects" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS projects (
  key         TEXT PRIMARY KEY,
  prefix      TEXT NOT NULL UNIQUE,
  counter     INTEGER NOT NULL DEFAULT 0,
  name        TEXT,
  description TEXT,
  goal        TEXT,
  folder      TEXT,
  lead_agent  TEXT,
  status      TEXT NOT NULL DEFAULT 'active',
  archived_at TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT OR IGNORE INTO projects (key, prefix, name, description)
  VALUES ('dive', 'DIVE', 'Dive', 'Default project (the original DIVE-N queue)');
UPDATE tasks SET project_key='dive' WHERE project_key IS NULL OR project_key='';
UPDATE tasks SET issue_number = id WHERE issue_number IS NULL;
UPDATE projects
   SET counter = (SELECT COALESCE(MAX(issue_number),0) FROM tasks WHERE project_key='dive')
 WHERE key='dive';
DROP TRIGGER IF EXISTS tasks_ident_ai;
CREATE TRIGGER tasks_ident_ai AFTER INSERT ON tasks
WHEN NEW.ident IS NULL
BEGIN
  UPDATE projects SET counter = counter + 1 WHERE key = NEW.project_key;
  UPDATE tasks
     SET issue_number = (SELECT counter FROM projects WHERE key = NEW.project_key),
         ident = (SELECT prefix FROM projects WHERE key = NEW.project_key)
                 || '-' || (SELECT counter FROM projects WHERE key = NEW.project_key)
   WHERE id = NEW.id;
END;
CREATE INDEX IF NOT EXISTS tasks_project_idx ON tasks(project_key);
COMMIT;
MIG
  fi

  # LOOP-7 loop_runs table — additive, gated on absence so it takes no write lock
  # on every command. Brand-new table, never referenced by tasks/projects, so
  # creating it cannot touch the existing queue (proven non-destructive on a copy
  # of the live db before ship). See loop-cli-impl-design.md §2.
  local has_loop_runs
  has_loop_runs=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='loop_runs' LIMIT 1;" 2>/dev/null)
  if [[ "$has_loop_runs" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS loop_runs (
  loop_id          TEXT PRIMARY KEY,
  topology         TEXT NOT NULL,
  spawned_by_agent TEXT,
  spawned_by_task  INTEGER,
  stage            TEXT,
  iteration        INTEGER NOT NULL DEFAULT 0,
  tokens_spent     INTEGER NOT NULL DEFAULT 0,
  ceiling          INTEGER,
  status           TEXT NOT NULL DEFAULT 'running',
  stuck            INTEGER NOT NULL DEFAULT 0,
  kill_requested   INTEGER NOT NULL DEFAULT 0,
  child_task_ids   TEXT,
  result_json      TEXT,
  scorecard_json   TEXT,
  started_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS loop_runs_status_idx ON loop_runs(status);
MIG
  fi

  # DIVE-724 supervisor_events table — additive, gated on absence like loop_runs
  # above so it takes no write lock on every command. Brand-new append-only
  # table, never referenced by tasks/projects, so creating it cannot touch the
  # existing queue.
  local has_sup_events
  has_sup_events=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='supervisor_events' LIMIT 1;" 2>/dev/null)
  if [[ "$has_sup_events" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS supervisor_events (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  ts                  TEXT NOT NULL DEFAULT (datetime('now')),
  agent               TEXT NOT NULL,
  event               TEXT NOT NULL DEFAULT 'observe',
  classification      TEXT NOT NULL,
  cause               TEXT,
  prev_classification TEXT,
  signals             TEXT
);
CREATE INDEX IF NOT EXISTS supervisor_events_agent_idx ON supervisor_events(agent, id);
MIG
  fi

  # DIVE-748 — additive scorecard column on already-created loop_runs tables.
  # The create-if-absent block above only covers fresh stores; existing loop_runs
  # (e.g. prod) need the column added. Pure expand: NULL backfill, old rows/queries
  # untouched. Gated on pragma so it's a no-op once present.
  if [[ "$has_loop_runs" == "1" ]]; then
    local lr_cols
    lr_cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
              "SELECT name FROM pragma_table_info('loop_runs');" 2>/dev/null)
    if ! printf '%s\n' "$lr_cols" | grep -qx "scorecard_json"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE loop_runs ADD COLUMN scorecard_json TEXT;" >/dev/null 2>&1 || true
    fi
  fi

  # OSS-21 task_prefs table — additive, gated on absence like loop_runs above so
  # it takes no write lock on every command. Brand-new key/value table, never
  # referenced by tasks/projects, so creating it cannot touch the existing queue.
  # Keep this definition byte-identical to the one in _tasks_schema above
  # (tests/schema_sync_unit.sh).
  local has_task_prefs
  has_task_prefs=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_prefs' LIMIT 1;" 2>/dev/null)
  if [[ "$has_task_prefs" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS task_prefs (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
MIG
  fi
}

# Per-connection setup, passed via -cmd / .timeout so it produces NO output
# rows (an inline `PRAGMA busy_timeout=N;` echoes the value, which would
# corrupt anything that captures a query result). .timeout makes concurrent
# agent writers retry instead of erroring with "database is locked";
# foreign_keys=ON enables the ON DELETE cascades.
db() {
  umask 0002
  sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON" "$TASKS_DB" "$1"
}

# OSS-21 fleet policy prefs (task_prefs KV). _task_pref_get echoes the stored
# value or nothing when unset; callers apply their own default. _task_pref_set
# upserts. Both assume tasks_db_init already ran (table present).
_task_pref_get() {
  db "SELECT value FROM task_prefs WHERE key=$(sqlq "$1");"
}
_task_pref_set() {
  db "INSERT INTO task_prefs(key,value,updated_at)
        VALUES($(sqlq "$1"),$(sqlq "$2"),datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
}

# Formatted read: dbfmt <sqlite-flag> "<sql>"  (e.g. -box, -json, -line).
dbfmt() {
  umask 0002
  sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON" "$1" "$TASKS_DB" "$2"
}

# Resolve a task ref (numeric id or DIVE-N) into the global RESOLVED_TASK_ID,
# or fail. Sets a global rather than echoing so the `fail` error path runs in
# the caller's shell (not a $() subshell) — otherwise a --json error envelope
# would be captured into the caller's var instead of reaching stdout. Shape is
# validated before anything touches SQL.
RESOLVED_TASK_ID=""
# Also exposes the row's true display ident (DIVE-561) so callers never render
# "DIVE-${id}" from the raw row id — those diverge once a non-default project
# consumes global ids (DIVE-484), e.g. row 571 carries ident DIVE-561 (DIVE-561).
RESOLVED_TASK_IDENT=""
resolve_task_id() {
  local ref="$1" found
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    # Bare number = the global row id (unchanged from before).
    found=$(db "SELECT id FROM tasks WHERE id=${ref};")
  elif [[ "$ref" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
    # DIVE-484: any <PREFIX>-<n> ident. Resolve by the ident string (case-
    # normalized to the stored UPPER prefix) — for non-dive projects the number
    # is the per-project issue_number, NOT the global id, so a numeric shortcut
    # would resolve the wrong row.
    local up="${ref^^}"
    found=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$up");")
  else
    fail "$E_VALIDATION" "bad task ref '$ref' (expected <number> or <PREFIX>-<number>, e.g. DIVE-42)"
  fi
  [[ -n "$found" ]] || fail "$E_NOT_FOUND" "no such task: $ref"
  RESOLVED_TASK_ID="$found"
  RESOLVED_TASK_IDENT=$(db "SELECT ident FROM tasks WHERE id=${found};")
}

# Resolve a known numeric row id to its display ident (DIVE-484). Used by call
# sites that already hold the numeric id (params, subqueries) and must render a
# user-facing label without assuming the DIVE-<id> shortcut.
ident_of() {
  db "SELECT ident FROM tasks WHERE id=${1};"
}

# Who is acting: --from wins, else infer from SUDO_USER (sudo path) or $USER
# (agent running directly as agent-<x>), else the literal "cli".
task_actor() {
  local from="${1:-}"
  [[ -n "$from" ]] && { printf '%s' "$from"; return; }
  local s; s=$(auto_sender_from_sudo)
  [[ -n "$s" ]] && { printf '%s' "$s"; return; }
  local u="${USER:-$(id -un 2>/dev/null)}"
  [[ "$u" == agent-* ]] && { printf '%s' "${u#agent-}"; return; }
  printf 'cli'
}

valid_task_status()   { [[ "$1" =~ ^(todo|in_progress|blocked|done|cancelled)$ ]]; }
valid_task_priority() { [[ "$1" =~ ^(low|medium|high|urgent)$ ]]; }
valid_need_type()     { [[ "$1" =~ ^(decision|secret|approval|manual)$ ]]; }

# Shape-check a 5-field cron expression (minute hour dom month dow). This is a
# lightweight gate at create time — exactly five whitespace-separated fields,
# each built only from cron field chars ([0-9*,/-]). It does NOT validate ranges
# (e.g. minute 0-59); the step-2 materializer / system cron is the authority on
# semantics. Rejects obvious garbage so a typo can't silently store a never-
# firing template.
valid_cron_expr() {
  local expr="$1"
  read -r -a _cf <<<"$expr"
  [[ ${#_cf[@]} -eq 5 ]] || return 1
  local f
  for f in "${_cf[@]}"; do
    [[ "$f" =~ ^[0-9*,/-]+$ ]] || return 1
  done
  return 0
}

# Does a single cron field match an integer value? Supports the cron grammar the
# DIVE-138 materializer needs: '*', int, list a,b,c, range a-b, step */n and
# a-b/n. <value> is a date component (already an int). Returns 0 on match. Uses
# `read -ra` (not `for x in $field`) to split on commas WITHOUT triggering
# pathname expansion on the '*' wildcard. All numbers forced base-10 (10#) so a
# zero-padded date component like "08"/"09" isn't read as bad octal.
_cron_field_match() {
  local field="$1" val="$2" part lo hi step
  val=$((10#$val))
  local -a parts; IFS=',' read -ra parts <<<"$field"
  for part in "${parts[@]}"; do
    step=1
    if [[ "$part" == */* ]]; then
      step="${part##*/}"; part="${part%%/*}"
      [[ "$step" =~ ^[0-9]+$ ]] && (( step > 0 )) || continue
    fi
    if [[ "$part" == "*" ]]; then
      (( step == 1 )) && return 0          # bare '*' — everything matches
      (( val % step == 0 )) && return 0    # '*/n' — every nth from 0
      continue
    fi
    if [[ "$part" == *-* ]]; then
      [[ "${part%%-*}" =~ ^[0-9]+$ && "${part##*-}" =~ ^[0-9]+$ ]] || continue
      lo=$((10#${part%%-*})); hi=$((10#${part##*-}))
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      lo=$((10#$part)); hi=$lo
    else
      continue
    fi
    (( val < lo || val > hi )) && continue
    (( (val - lo) % step == 0 )) && return 0
  done
  return 1
}

# Day-of-week match with Sunday=0=7 (cron allows both). %w gives 0-6 (0=Sun).
_cron_dow_match() {
  local field="$1" v="$2"
  _cron_field_match "$field" "$v" && return 0
  (( v == 0 )) && _cron_field_match "$field" 7 && return 0
  return 1
}

# Does 5-field cron <expr> fire at <epoch> (unix seconds)? Implements standard
# cron semantics incl. the dom/dow OR-rule: when BOTH day-of-month and
# day-of-week are restricted (neither is '*'), the row fires if EITHER matches;
# otherwise every field ANDs. Backs the DIVE-138 heartbeat materializer.
# Returns 0 if due at that minute, 1 otherwise.
_cron_matches() {
  local expr="$1" epoch="$2"
  local -a cm; read -r -a cm <<<"$expr"
  [[ ${#cm[@]} -eq 5 ]] || return 1
  local emin ehour edom emon edow
  read -r emin ehour edom emon edow < <(date -u -d "@${epoch}" +'%M %H %d %m %w' 2>/dev/null)
  [[ -n "$edow" ]] || return 1
  _cron_field_match "${cm[0]}" "$emin"  || return 1
  _cron_field_match "${cm[1]}" "$ehour" || return 1
  _cron_field_match "${cm[3]}" "$emon"  || return 1
  if [[ "${cm[2]}" != "*" && "${cm[4]}" != "*" ]]; then
    _cron_field_match "${cm[2]}" "$edom" || _cron_dow_match "${cm[4]}" "$edow" || return 1
  else
    _cron_field_match "${cm[2]}" "$edom" || return 1
    _cron_dow_match  "${cm[4]}" "$edow" || return 1
  fi
  return 0
}

# Indent every line of stdin by two spaces. Used for the nested lists in
# `task show` / `org show`; a plain `printf '  %s\n' "$var"` only indents the
# first line, and unquoting splits values that contain spaces (task titles).
indent2() { while IFS= read -r _l; do printf '  %s\n' "$_l"; done; }

# -------- gate-proof: human-origin proof for approval/secret gates (DIVE-519) --------
#
# BAR-RAISE + AUDIT, NOT airtight. An agent with sudo is root-equivalent — it can
# read the key or write the db directly — so this CANNOT stop a determined
# malicious root agent. What it DOES stop is the real reported failure mode: an
# over-eager / prompt-injected agent self-clearing an approval/secret gate with a
# silent one-liner `sudo 5dive task answer` (the DIVE-515/516 incident). To clear
# such a gate the caller must now present a --proof token minted from a root-only
# 0400 key, so a bypass requires an explicit, AUDITED `sudo 5dive gate-proof`
# (loud) instead of a silent answer. Mint + verify share _gate_proof_hmac so they
# can never drift. The agent-* uid check in cmd_task_answer stays the first line;
# this is the second, catching the agent->sudo->root bypass.
#
# Token: v1:<nonce>:<exp_unix>:<base64url HMAC-SHA256(key, "taskid:needtype:nonce:exp")>
# Bound to the canonical task id + gate type; TTL <=120s; replay is bounded by the
# gate's own one-shot need_answered_at (an answered gate can't be re-answered).
GATE_PROOF_KEY="${STATE_DIR}/gate-proof.key"
GATE_PROOF_ENFORCE="${STATE_DIR}/gate-proof.enforce"
GATE_PROOF_TTL=120

# Provision the 0400 root:root key on first use (root only). Group-claude must NOT
# read it (unlike the group-readable task db) or the bar-raise is moot.
_gate_proof_ensure_key() {
  [[ -s "$GATE_PROOF_KEY" ]] && return 0
  [[ $EUID -eq 0 ]] || return 1
  ( umask 077; openssl rand -hex 32 > "$GATE_PROOF_KEY" ) 2>/dev/null || return 1
  chown root:root "$GATE_PROOF_KEY" 2>/dev/null || true
  chmod 0400 "$GATE_PROOF_KEY" 2>/dev/null || true
  [[ -s "$GATE_PROOF_KEY" ]]
}

# HMAC-SHA256(key, payload) -> base64url (unpadded). hexkey avoids binary-in-argv.
_gate_proof_hmac() {
  local payload="$1" key
  key=$(cat "$GATE_PROOF_KEY" 2>/dev/null) || return 1
  [[ -n "$key" ]] || return 1
  printf '%s' "$payload" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" -binary 2>/dev/null \
    | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='
}

# Constant-time compare: full-length scan, no early exit. Length isn't secret (the
# mac is fixed-width base64url).
_gate_proof_ct_equal() {
  local a="$1" b="$2" i res=0
  [[ ${#a} -eq ${#b} ]] || return 1
  for ((i=0; i<${#a}; i++)); do
    [[ "${a:i:1}" == "${b:i:1}" ]] || res=1
  done
  return $res
}

# DIVE-950: `_gate_proof_mint` / `_gate_proof_verify` (the DIVE-519 --proof token,
# evidence-form b) are REMOVED — the token was agent-forgeable via the require_root
# `gate-proof` mint (no higher a bar than the sudo it already needed). `_gate_proof_hmac`
# above is retained: DIVE-756 closure-signature tamper-evidence (`_gate_closure_sign`
# / `_gate_closure_verify`) still uses it.

# Enforcement is OFF until the sentinel exists. DIVE-519 ships DORMANT (audit-only):
# flip on only after the plugin mint is confirmed live on the box, else live taps
# that can't mint yet would fail closed. Root toggles it.
_gate_proof_enforced() { [[ -f "$GATE_PROOF_ENFORCE" ]]; }

# ── DIVE-916: per-gate HUMAN nonce (close the sudo->--human forge) ────────────
# Distinct from the DIVE-519 --proof token: that is a box-wide, TTL'd, HMAC proof
# any trusted path can mint; this is a per-GATE secret bound to one task row. Its
# job is the ONE human path the SUDO_UID key can't cover — the plugin tap, which
# runs as SUDO_UID=agent-* (the plugin is spawned by the agent) yet is a real
# human action. The raw nonce reaches the plugin ONLY via the Telegram
# callback_data the CLI composes as root; the agent LLM never sees it.

# SHA-256 of a value -> lowercase hex. Used for both mint (store) and verify.
_human_nonce_sha() {
  printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

# Mint a fresh nonce. 16 bytes = 32 hex chars: unguessable, and short enough that
# `tna:<numid>:<action>:<nonce>` stays under Telegram's 64-byte callback cap.
# Echoes the RAW nonce on stdout (caller stores only its hash).
_human_nonce_mint() { openssl rand -hex 16 2>/dev/null; }

# Verify a presented nonce against the stored hash for task <id>. 0 = match.
# Fails closed on a gate with no stored hash (legacy row / non-human gate) or an
# empty presented nonce. Constant-time compare (reuses the gate-proof helper).
_human_nonce_verify() {
  local id="$1" nonce="$2" stored calc
  [[ -n "$nonce" ]] || return 1
  stored=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${id};")
  [[ -n "$stored" ]] || return 1
  calc=$(_human_nonce_sha "$nonce")
  [[ -n "$calc" ]] || return 1
  _gate_proof_ct_equal "$calc" "$stored"
}

# Resolve the REAL pre-sudo caller and report whether it is a NON-agent uid — the
# third human-evidence form (a claude/root interactive login or the shelld/drop
# path, all of which carry SUDO_UID != agent-*). $SUDO_UID survives `sudo -u
# agent-X` and a nested non-sudo exec (verified for the DIVE-931 drop chain),
# unlike `id -un`. 0 = non-agent (human-trusted), 1 = agent (or unknown).
_gate_sudo_uid_nonagent() {
  local uid="${SUDO_UID:-$(id -u 2>/dev/null || echo "")}"
  [[ -n "$uid" ]] || return 1
  local uname; uname=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
  [[ -n "$uname" ]] || return 1        # unknown uid -> not trusted
  [[ "$uname" != agent-* ]]
}

# ── DIVE-756: persisted closure signature (tamper-evidence) ──────────────────
# Unlike the short-lived answer-time --proof (bound to id:type, TTL 120s, then
# discarded), this HMAC is STORED on the row and binds the durable closure facts,
# so an auditor/consumer can verify long after the answer — and a raw-sqlite write
# that never ran cmd_task_answer leaves an unsigned/invalid row that `gate-proof
# verify` flags. Newlines/pipes in the human answer are escaped so the canonical
# payload is unambiguous (and recomputes identically at verify time).
_gate_closure_payload() {
  # args: id type answer by answered_at uid
  local id="$1" type="$2" answer="$3" by="$4" at="$5" uid="$6"
  _gc_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\p/g' -e ':a;N;$!ba;s/\n/\\n/g'; }
  printf 'c1|%s|%s|%s|%s|%s|%s' \
    "$id" "$type" "$(_gc_esc "$answer")" "$(_gc_esc "$by")" "$at" "$uid"
}

# Sign the canonical payload. Needs the root-only key, so this only produces a
# value in a root context; callers treat empty as "couldn't sign" (best-effort).
_gate_closure_sign() {
  [[ -s "$GATE_PROOF_KEY" ]] || return 1
  _gate_proof_hmac "$(_gate_closure_payload "$@")"
}

# Verify a stored signature against the row facts. 0 = valid, 1 = invalid/absent.
_gate_closure_verify() {
  # args: id type answer by answered_at uid sig
  local sig="${7:-}"
  [[ -n "$sig" ]] || return 1
  local expect; expect=$(_gate_closure_sign "$1" "$2" "$3" "$4" "$5" "$6") || return 1
  [[ -n "$expect" ]] || return 1
  _gate_proof_ct_equal "$sig" "$expect"
}
