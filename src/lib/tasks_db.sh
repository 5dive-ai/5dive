
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
  -- DIVE-477: maker→verifier loop state. iteration = how many times the maker has
  -- handed off to the verifier (bumped on each `task done` that routes, not on
  -- bounce-back). maker_agent = the original maker, stashed at first handoff so a
  -- verify FAIL (`task reject`) can bounce the task straight back to them; it
  -- survives re-routes (COALESCE keeps the first writer). Both NULL until a task
  -- enters a loop (verifier set + maker hands off).
  iteration           INTEGER,
  maker_agent         TEXT
);

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
           'escalated_at TEXT' 'escalated_by TEXT' \
           "project_key TEXT NOT NULL DEFAULT 'dive'" 'issue_number INTEGER' \
           'acceptance_criteria TEXT' 'verify_command TEXT' 'max_iterations INTEGER' 'verifier TEXT' \
           'iteration INTEGER' 'maker_agent TEXT'; do
    if ! printf '%s\n' "$cols" | grep -qx "${c%% *}"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE tasks ADD COLUMN ${c};" >/dev/null 2>&1 || true
    fi
  done

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

# Mint a token for <canonical_id> <type>. Returns the RAW token on stdout.
_gate_proof_mint() {
  local id="$1" type="$2" nonce exp mac
  nonce=$(openssl rand -hex 8 2>/dev/null) || return 1
  exp=$(( $(date +%s) + GATE_PROOF_TTL ))
  mac=$(_gate_proof_hmac "${id}:${type}:${nonce}:${exp}") || return 1
  [[ -n "$mac" ]] || return 1
  printf 'v1:%s:%s:%s' "$nonce" "$exp" "$mac"
}

# Verify <canonical_id> <type> <token>. 0 = structurally valid, unexpired, matches.
_gate_proof_verify() {
  local id="$1" type="$2" token="$3"
  [[ "$token" == v1:*:*:* ]] || return 1
  local body="${token#v1:}"
  local nonce="${body%%:*}"; body="${body#*:}"
  local exp="${body%%:*}";   local mac="${body#*:}"
  [[ "$nonce" =~ ^[0-9a-f]+$ && "$exp" =~ ^[0-9]+$ && -n "$mac" ]] || return 1
  (( exp >= $(date +%s) )) || return 1
  local expect; expect=$(_gate_proof_hmac "${id}:${type}:${nonce}:${exp}") || return 1
  [[ -n "$expect" ]] || return 1
  _gate_proof_ct_equal "$mac" "$expect"
}

# Enforcement is OFF until the sentinel exists. DIVE-519 ships DORMANT (audit-only):
# flip on only after the plugin mint is confirmed live on the box, else live taps
# that can't mint yet would fail closed. Root toggles it.
_gate_proof_enforced() { [[ -f "$GATE_PROOF_ENFORCE" ]]; }
