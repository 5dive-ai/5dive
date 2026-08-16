
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

# DIVE-1475: honor direct env overrides too (a test may set TASKS_DB straight),
# same isolation rationale as STATE_DIR in header.sh. Unset -> the live defaults.
TASKS_DIR="${TASKS_DIR:-${STATE_DIR}/tasks}"
TASKS_DB="${TASKS_DB:-${TASKS_DIR}/tasks.db}"

# -------- DIVE-2249: the STORE FENCE on the prod task board --------
#
# The production board may only be WRITTEN by a process that entered through the
# real CLI entrypoint. A sourced-library caller aiming a write at the prod path is
# refused, loudly, before sqlite sees it.
#
# WHY. On 2026-07-27 18:10:58 a run of tests/gate_verifier_route_unit.sh appended
# six fixture rows (DIVE-501..506, created_by=dev) to the LIVE board. They were not
# inert: `5dive trace DIVE-503` shows two real gate deliveries and a human-facing
# gate that agent-main then had to withdraw by hand. Reproduced under DIVE-2249 in
# a private mount namespace with /var/lib/5dive bound onto a decoy copy — with the
# harness's single STATE_DIR line removed, the same six idents land with the same
# created_by/verifier/maker_agent values, and NOTHING refuses them.
#
# This is the FOURTH instance of one class. The gate-notify send (DIVE-1500), the
# human DM relay (DIVE-1506) and audit_log (DIVE-2010) were each fenced in turn,
# and all three are OUTBOUND rails. The tasks table is the store those rails read
# FROM, so it is the one that most needed a fence and the only one that had none.
#
# WHY ENTRYPOINT, and not an env var. Every legitimate prod write comes from the
# built bundle, whose last line is `main "$@"`; build.sh is the only non-test file
# in the repo that sources this library. A caller that sourced src/lib/*.sh and
# then aimed a write at the prod path is therefore a mistake BY CONSTRUCTION —
# there is no correct caller with that shape — which is what makes this structural
# rather than a rule every harness has to remember. Deliberately NOT an opt-out
# marker a harness sets: a forgotten opt-out fails silently INTO prod, which is the
# exact defect being removed here, and DIVE-1968/DIVE-2010 already record that
# reasoning ("do not fix an opt-out failure with a different opt-in"). A harness
# that sets nothing is fenced, including harnesses nobody has written yet.
#
# SCOPE, stated plainly: this fences the shell library's writers (db, dbfmt,
# tasks_db_init). It does NOT fence a process that opens the .db file with its own
# sqlite3/node client — the dashboard API reads the board that way. Closing that
# needs file-level perms, not a function guard, and is out of scope here.
_TASKS_STORE_ENTRY="${_TASKS_STORE_ENTRY:-}"

# Is the ACTIVE store the production board?
#
# DELIBERATELY NOT keyed on FIVEDIVE_PROD_TASKS_DB, even though that is the
# existing "which store is prod" knob (DIVE-1506). 23 harnesses already export it
# pointing at their OWN throwaway store — that is how they get the human-send
# allowlist to let their gate-delivery assertions run — so a fence that read it
# would fence 23 correctly-isolated suites and fence NOTHING on the real board.
# Measured, not predicted: a full-suite run under a bind-mounted decoy fired this
# fence in 5 suites before the sweep was stopped, all of them properly isolated.
# One name cannot carry two opposite consequences.
#
# So the prod path is HARDCODED and unconditional: no environment can remove it.
# FIVEDIVE_FENCE_EXTRA_STORE only ADDS a path to the fenced set (the fence's own
# unit test designates its decoy that way), so the escape hatch cannot become an
# escape — the worst a caller can do with it is fence themselves.
#
# readlink -f prints nothing when a path's PARENT does not exist, so an empty
# result falls back to the literal path rather than comparing "" == "" and
# fencing every caller (readlink's three unresolvable states — only one is empty).
_tasks_store_is_prod() {
  local active ra p rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  ra="$(readlink -f "$active" 2>/dev/null)"; [[ -n "$ra" ]] || ra="$active"
  for p in /var/lib/5dive/tasks/tasks.db "${FIVEDIVE_FENCE_EXTRA_STORE:-}"; do
    [[ -n "$p" ]] || continue
    rp="$(readlink -f "$p" 2>/dev/null)"; [[ -n "$rp" ]] || rp="$p"
    [[ "$ra" == "$rp" ]] && return 0
  done
  return 1
}

# Is this SQL a pure READ? A POSITIVE ALLOWLIST — everything it does not
# recognise counts as a write.
#
# The obvious shape is the other one: list the mutating verbs and refuse those.
# This repo has already paid for that shape — DIVE-1506 records that a blocklist
# "is exactly how DIVE-1500's guard missed the gate-notify + /inbox legs". A verb
# list rots the same way, and it did here under test: the blocklist draft of this
# function caught a CTE-prefixed `WITH … INSERT` but let `ATTACH DATABASE`
# through unfenced. Inverting it makes the failure mode a refused READ (loud,
# immediate, harmless) rather than an admitted WRITE (silent, and the thing being
# fixed).
#
# Word-anchored on both sides so `created_by` / `deleted_at` in a SELECT are not
# read as CREATE / DELETE. The second test is what catches the CTE case: a
# statement may OPEN like a read and still mutate further in.
#
# This runs ONLY in the already-broken case (prod path + no entrypoint) —
# production short-circuits on the marker before reaching here — so a false
# positive costs a legitimate sourced reader one clear error message, and a false
# negative costs us the incident again.
_tasks_sql_is_read() {
  local sql="${1:-}" rc=1
  shopt -s nocasematch
  if [[ "$sql" =~ ^[[:space:]]*(--[^$'\n']*$'\n'[[:space:]]*)*(SELECT|WITH|EXPLAIN|PRAGMA[[:space:]]+(table_info|table_xinfo|foreign_key_list|index_list|database_list)|ANALYZE)([[:space:]]|\(|$) ]]; then
    [[ "$sql" =~ (^|[[:space:];\(,])(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|VACUUM|ATTACH|DETACH|REINDEX)([[:space:]]|\() ]] || rc=0
  fi
  shopt -u nocasematch
  return $rc
}

# The fence itself. Ordered cheapest-first: the entrypoint marker short-circuits
# every production call before any path resolution or regex runs.
_tasks_store_fence() { # <sql>
  [[ -n "${_TASKS_STORE_ENTRY:-}" ]] && return 0
  _tasks_store_is_prod || return 0
  _tasks_sql_is_read "${1:-}" && return 0
  local msg="refusing a non-READ statement against the production task board from a sourced-library caller (DIVE-2249).
  store: ${TASKS_DB:-<unset>}
  This process sourced src/lib/*.sh directly instead of entering through the 5dive
  CLI, so a write here would append real-looking rows to the live board — the
  DIVE-501..506 fixture leak. If this is a test: set STATE_DIR (and TASKS_DIR/
  TASKS_DB) to a throwaway dir BEFORE the first store call. If you are genuinely
  driving prod, invoke the 5dive binary rather than sourcing its libraries."
  # `fail` comes from lib/output.sh, which build.sh and every harness source
  # before this file — but never assume it, or the fence dies silently in the one
  # context that skipped it.
  if declare -F fail >/dev/null 2>&1; then
    fail "${E_PERMISSION:-13}" "$msg"
  else
    printf 'error: %s\n' "$msg" >&2
    exit "${E_PERMISSION:-13}"
  fi
}

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
_TASKS_SCHEMA_EPOCH='3251-1'   # DIVE-3251: +first_started_at
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
  -- DIVE-2518: the uid-derived actor, recorded ONLY when it differs from
  -- created_by. `created_by` can legitimately name a principal with no uid at all
  -- (`council`, `telegram`), so this is what makes a `--from` claim falsifiable
  -- after the fact rather than the only identity on file.
  --
  -- MUST BE ADDED HERE **AND** in _TASKS_ADDITIVE_COLUMNS. A fresh store is built
  -- from this schema and DIVE-2808's gate skips the migration only when every
  -- array column is already present. Keeping the two definitions complete makes
  -- that fast path both safe and cheap; the convergence assertion is the backstop.
  derived_actor TEXT,
  -- DIVE-3098: a verifier grade recorded by `task verify --no-done` (graded_at) and
  -- the actor who recorded it (graded_by). Structural on purpose — the
  -- terminal-for-verifier predicate must not key on result TEXT, which the MAKER's
  -- `task deliver --result=` also writes, or a maker could buy the exemption by
  -- typing the right words. Declared HERE as well as in _TASKS_ADDITIVE_COLUMNS,
  -- per the rule directly above: a fresh store takes this CREATE and never runs the
  -- ALTER loop, so array-only lands a store that fails the DIVE-2197 assertion.
  graded_at TEXT,
  graded_by TEXT,
  -- DIVE-3430: WHAT the grade was. graded_at above records only THAT someone
  -- graded, and it is stamped by `verify`'s else-branch, which is entered on a FAIL
  -- exactly as readily as on a `--no-done` pass — so a FAIL rendered `graded->merge`
  -- with no reject token anywhere for DIVE-3428's conjunct to catch.
  --   graded_verdict     'pass'|'fail', the LATEST verdict, written with a bare SET.
  --   graded_verdict_at  when THAT verdict was recorded.
  -- The two write rules differ ON PURPOSE and the pair is why that is safe:
  -- graded_at/graded_by are COALESCE'd (first grade wins, DIVE-2477's rule) because
  -- they answer WHO FIRST GRADED THIS AND WHEN — provenance, which a re-grade must
  -- not rewrite. graded_verdict answers IS THE LATEST VERDICT STILL A PASS, which a
  -- re-grade must rewrite or a verifier could never clear their own earlier FAIL.
  -- Those are different questions, so a shared write rule is wrong for one of them
  -- either way; graded_verdict_at makes the resulting skew READABLE instead of a
  -- trap, so no reader has to assume the verdict and graded_at describe one event.
  -- NULL verdict = graded before this column existed. The predicate reads NULL as
  -- 'pass' deliberately: that is the pre-DIVE-3430 behaviour, so the migration is a
  -- pure ALTER with NO backfill and no already-graded row silently leaves the board.
  -- A backfill could not do better — it cannot know a legacy row's verdict, and one
  -- keyed on graded_at would have to re-run on every migrate pass and would then
  -- resurrect exactly the FAILs this column exists to record.
  graded_verdict TEXT,
  graded_verdict_at TEXT,
  -- DIVE-2615: why this gate has this tier — axis=pinned|type-default|secret-type
  -- |ask|title|title-fallback|none, plus ;term=<t> where a term is what fired.
  -- Declared HERE as well as in _TASKS_ADDITIVE_COLUMNS: a fresh store takes this
  -- CREATE, and the migration gate must find this column before it may skip.
  floor_provenance TEXT,
  -- DIVE-3171: why this gate has this ROUTED_REVIEWER — the sibling axis to
  -- floor_provenance above, which DIVE-3117 named as missing while fixing a routing
  -- defect it could not measure ("the TIER axis had a floor, its sibling ROUTING axis
  -- had none"). Values:
  --   chart              _gate_route_reviewer resolved them from agents_org
  --   verifier-loop      DIVE-1495 routed to the row's verifier
  --   seal:standing-lead DIVE-3171 — the chart resolved NOBODY and the SEALED
  --                      constitution's eng_approval_lead took the gate
  -- NULL is a real third state, exactly as for floor_provenance (DIVE-2615): it means
  -- this build never recorded it, NOT that the route had no source. Conflating the two
  -- is what made the existing floor column unusable for a whole release.
  -- WHY IT IS A COLUMN AND NOT A DERIVATION: `cmd_task_answer` reads it to decide
  -- whether a lead-clear is stamped `lead:` or `lead:standing:`, and re-deriving it
  -- would mean re-reading agents_org — an agent-writable table (DIVE-2233) — at answer
  -- time, so a chart edit between filing and answering would silently change what the
  -- record says HAPPENED. A recorded fact beats a re-derived one; that is the whole
  -- lesson of the three 2026-08-10 provenance incidents.
  route_provenance TEXT,
  -- DIVE-2354: WHICH of the two orders this gate is in, as data.
  --   approve-to-send   the action has NOT happened; the tap authorises it (default).
  --   confirm-after-send the action ALREADY happened; the tap RATIFIES it after the fact.
  -- NULL is a real third state and not a synonym for either: it means the gate was
  -- filed before this column existed, so the record does not say which order it was
  -- (the same distinction as unreadable-vs-absent, DIVE-2327). Readers must render
  -- the three apart -- a ratification that renders as a prior approval is the exact
  -- false record this ticket exists to end. Declared HERE as well as in
  -- _TASKS_ADDITIVE_COLUMNS: a fresh store takes this CREATE and never runs the
  -- ALTER loop, per the rule above.
  gate_mode TEXT,
  -- DIVE-3342: the PERSON this gate belongs to — humans.id, stamped when the gate
  -- is filed (or declared with `task need --owner=`). routed_reviewer above names
  -- the AGENT who may clear it; this names the human who may, which until now was
  -- never recorded anywhere and was re-derived at send time from whoever last
  -- DM'd the bot. Recorded, not re-derived, for the same reason
  -- route_provenance is (DIVE-3171): the org chart is agent-writable and a chart
  -- edit between filing and paging would otherwise move a live gate to a
  -- different person. NULL is a real third state — a gate filed before this
  -- column, or one whose clearers no human owns — and it means "no person is
  -- named", never "send it to everybody". Declared HERE as well as in
  -- _TASKS_ADDITIVE_COLUMNS, per the rule above.
  human_owner TEXT,
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
  escalated_at     TEXT,
  escalated_by     TEXT,
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
  -- DIVE-1518: independently records which authenticated evidence form cleared
  -- the current gate (tap nonce, sudo uid, channel session, or proof).
  human_evidence   TEXT,
  -- DIVE-3128: the RELAY, kept OUT of need_answered_by rather than folded into
  -- it. A Telegram button tap reaches this CLI through some agent's bot, and
  -- until now the relaying agent's own identity was what got the `human:`
  -- prefix — so `human:olivia` meant either "a person tapped, olivia's bot
  -- carried it" or "the olivia agent cleared its own human gate", with nothing
  -- in the row to tell them apart (DIVE-3045). Two columns, two facts:
  --   need_answered_by     WHO decided
  --   need_answered_relay  WHOSE BOT carried the decision
  -- need_answered_tap_uid is the Telegram user id of the person who tapped, kept
  -- as TEXT because Telegram ids are opaque identifiers, not arithmetic.
  need_answered_relay   TEXT,
  need_answered_tap_uid TEXT,
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
  -- DIVE-2237. last_fired_at moves ONLY on a successful INSERT, so a template
  -- the materializer looked at and declined to fire (skip-if-open dedup) is
  -- indistinguishable on the board from a template the scheduler never reached
  -- -- box down, cron wrong, heartbeat dead. last_skipped_at is the other half
  -- of that reading: stamped every tick the template was DUE and deliberately
  -- suppressed. Recent last_skipped_at + stale last_fired_at = suppressed (a
  -- human must close the stuck instance); both stale = the scheduler is not
  -- reaching it at all. Deliberately a separate column, not a status: the
  -- dedup decision itself is unchanged by this.
  last_skipped_at  TEXT,
  -- DIVE-2272 (decision DIVE-2270). The PER-TEMPLATE overlap policy. NULL means
  -- 'skip' -- every template that predates this column keeps today's behaviour
  -- byte for byte, which is why this is a nullable add and not a NOT NULL
  -- DEFAULT 'skip': a backfilled default and an unset value would then be
  -- indistinguishable, and 'nobody has classified this template yet' is a state
  -- the classification pass needs to be able to SEE.
  --   skip  = an open instance suppresses the next slot (today's dedup).
  --   spawn = fire anyway, UP TO overlap_bound open instances; past the bound,
  --           skip AND stamp last_skipped_at, i.e. degrade to exactly the
  --           now-legible skip behaviour rather than invent new alarm machinery.
  -- WHY PER-TEMPLATE: skip-if-open is a claim about the VALUE of a pile-up, and
  -- that value is class-dependent. For a fungible chore (disk reclaim, hygiene
  -- sweep) three open instances are three copies of one job and dedup is right.
  -- For a reading-of-the-present job (recap, version loop) Tuesday's instance
  -- cannot be discharged by Wednesday's run, so three open instances mean nobody
  -- has read the inbox in three days -- the pile-up IS the alarm the dedup
  -- deletes. Only the template's author knows the class; the scheduler cannot
  -- infer it.
  on_overlap       TEXT,
  -- The bound for on_overlap='spawn'. NULL means the built-in default (3).
  -- A JUDGMENT CALL, NOT A MEASUREMENT: 3 open recaps is unmistakable to a human
  -- and 300 is a different outage. Tunable per template precisely so the number
  -- is never mistaken for something derived.
  overlap_bound    INTEGER,
  -- DIVE-138 step 2. A materialized instance links back to the recurring
  -- template it was cloned from via from_template_id (NULL for templates and
  -- ordinary tasks); the materializer's skip-if-open dedup keys on it. NOT a FK
  -- with cascade — deleting a template must not nuke its already-materialized
  -- instances' history. `fresh` (1/0/NULL) is the per-template clean-session
  -- pref copied onto each instance: when 1 the heartbeat sends /clear before
  -- working it regardless of the agent-level fresh setting.
  from_template_id INTEGER,
  fresh            INTEGER,
  -- Parking is task state, not a separate table: these were historically
  -- migration-only and therefore made a fresh canonical store incomplete.
  parked_at        TEXT,
  park_reason      TEXT,
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
  -- DIVE-1378: one real receiver ACK for maker→verifier handoffs. NULL means
  -- the work was delivered to the verifier but they have not acknowledged
  -- beginning review; set only when that assigned verifier runs `task start`.
  -- The public handoff state is derived as delivered|reviewing so we do not grow
  -- a second task-status FSM or let a sender claim that review has begun.
  handoff_ack_at      TEXT,
  -- DIVE-1416 (gap#2): handoff_delivered_at stamps the moment a maker's `task
  -- done` routes the task to its verifier (_task_route_to_verifier) — a
  -- dedicated clock, unlike updated_at, which any row touch bumps and so can't
  -- measure "how long has this sat unacknowledged". Reset on every fresh
  -- handoff (including a re-delivery after a reject/bounce-back cycle).
  -- handoff_stale_pinged_at throttles the stall sweep's surface-ping to once
  -- per delivery (shipped_flag_at pattern): stamped when the sweep flags a
  -- delivery that's sat past its staleness window, cleared on the next fresh
  -- handoff so a redelivered task gets a clean chance to alert again.
  -- DIVE-2624: handoff_rejected_at stamps the verifier's FAIL bounce
  -- (cmd_task_reject). It exists so `iteration` can mean what every reader already
  -- assumes it means — verifier rejections — instead of "number of task done calls".
  -- It is a ONE-SHOT TOKEN, not a clock to compare: the next delivery bumps the
  -- counter iff this is set (or it is the first delivery ever) and CLEARS it in the
  -- same UPDATE. A re-delivery with no reject outstanding — restoring a handoff, say
  -- — therefore does not bump. Deliberately not compared against
  -- handoff_delivered_at: both are datetime('now') at one-second resolution, so a
  -- reject and the delivery answering it land in the same second often enough that
  -- either side of that tie is wrong somewhere. The timestamp is kept (rather than a
  -- boolean) because WHEN the bounce happened is worth having; only the ordering
  -- decision is made by presence.
  handoff_delivered_at    TEXT,
  handoff_stale_pinged_at TEXT,
  handoff_rejected_at     TEXT,
  -- DIVE-2693: recurring_stall_pinged_at throttles the recurring-instance stall
  -- sweep to one surface-ping per instance (same shipped_flag_at pattern as
  -- handoff_stale_pinged_at above). A materialized instance that is never STARTED
  -- has no handoff_delivered_at, so gap#2's sweep cannot see it — and skip-if-open
  -- dedup means the template's next slot is suppressed for as long as it sits, so
  -- one unworked instance silently eats every subsequent occurrence of the beat.
  -- Measured twice on DIVE-1237 (the OpenAgent drip): DIVE-2026 ate 07-27..07-28,
  -- DIVE-2403 ate 07-31..08-04. Both recovered cleanly downstream, which is exactly
  -- what kept the fault quiet.
  recurring_stall_pinged_at TEXT,
  -- DIVE-2853: recurring_stall_escalated_at throttles the SECOND rung — the one
  -- that changes hands — to once per instance. The first rung's notice goes to the
  -- row's assignee, i.e. to the party whose non-pickup IS the fault, so repeating it
  -- cannot clear the state: measured on DIVE-2694, which was flagged exactly on time
  -- and then sat unstarted another 28h because dev was mid-delivery under a
  -- single-task goal and structurally could not take a second row. A fence outlives
  -- every re-ping. So the second rung reassigns to a free agent, or cancels with a
  -- written reason so the template re-fires, and this column is what stops a
  -- reassignment from thrashing the row around the fleet tick after tick.
  recurring_stall_escalated_at TEXT,
  -- DIVE-3218: nudge_escalated_at / nudge_parked_at throttle the two rungs of the
  -- nudge-threshold ladder (heartbeat). They are stamped ONCE PER ROW, not per
  -- wake: the ladder's job is to force a state change after N fruitless nudges,
  -- and a rung that could re-fire every tick would escalate a row to urgent N
  -- times over. Deliberately NOT cleared when the row is re-queued — the count
  -- of sessions already burned on this row is a property of the row, not of its
  -- current status, and re-arming the ladder on every requeue is how a reassign
  -- turns into a thrash around the fleet (the DIVE-2853 lesson).
  nudge_escalated_at TEXT,
  -- DIVE-3218: the nudge COUNT at which rung 1 fired. Rung 2 keys on
  -- nudge_escalated_n + N, never on 2*N recomputed from the current priority,
  -- because rung 1's own escalation RAISES the band and a higher band has a
  -- SMALLER N — so a row escalated at the high threshold of 16 is instantly past
  -- an urgent 2N of 16 and both rungs fire on the same wake. Storing the count
  -- makes rung 2 "one more full threshold of fruitless wakes AFTER we escalated",
  -- which is what the ladder means and is immune to the band moving underneath it.
  nudge_escalated_n INTEGER,
  nudge_parked_at TEXT,
  -- DIVE-2207: gate_answered_nudged_at throttles the POST-GATE-ANSWER nudge
  -- (gap#2's second predicate) to once per row. It is a SEPARATE column from
  -- handoff_stale_pinged_at on purpose, and reusing that one would have shipped
  -- this fix dead: 30 rows fleet-wide had already burned handoff_stale_pinged_at
  -- when this was written, INCLUDING DIVE-2146 (burned 2026-07-27 21:40), which is
  -- the specimen the rail was written for. A throttle already spent by a different
  -- rail is not a throttle, it is an exclusion.
  -- WHY THE RAIL EXISTS: a delivered row blocked on a human gate is excluded from
  -- the gap#2 sweep (DIVE-2196 — nagging there prescribes resolving the human's
  -- gate by side effect). The instant that gate is ANSWERED the wait is back on the
  -- verifier, but nothing re-arms: handoff_ack_at may already be stamped (any
  -- verifier who ran `task start` before getting blocked stamped it), so the
  -- original predicate can never fire again. Measured on the live board 2026-07-28:
  -- 20 rows have entered that blind window, 17 graded within the hour, 1 took over
  -- 24h. Low frequency, silent failure — which is the case for a rail, not against.
  gate_answered_nudged_at TEXT,
  -- DIVE-891: risk-tiered gates (adopted design DIVE-861). tier is set when the
  -- gate is filed: 0 = auto-clear (rec applies immediately, digest line only),
  -- 1 = agent-clearable + 48h TTL auto-applies the recommendation, 2 = hard
  -- human gate (never auto-applies; TTL only batches reminder pings). The T2
  -- category floor (spend/publish/secret/destructive/brand) is enforced in
  -- cmd_task_need, not trusted from the filer. NULL = legacy gate, treated as
  -- tier 2 (never auto-cleared). need_asked_at stamps gate filing time — the
  -- TTL clock (updated_at is useless for this: any row touch bumps it).
  -- gate_pinged_at = last CONFIRMED Bot API delivery for this gate (initial,
  -- 1h/24h re-nag, or legacy TTL batch). It is both the queryable receipt and
  -- migration-free throttle stamp; failed/unconfirmed sends leave it unchanged.
  -- wake_at: a parked task
  -- (task park --wake=...) auto-unparks when the heartbeat passes this time.
  -- DIVE-1945: gate_filed_by = the ACTOR who filed THIS gate, stamped by
  -- cmd_task_need. Not derivable from the row: created_by is the task's author
  -- and assignee is rewritten to the filer only on the human lane, so a gate one
  -- agent files on another's task had no record of whose ask it is. The
  -- escalation chain is walked from the FILER (gate-escalate, T1 re-nag routing);
  -- created_by stays the right key for the T2 re-nag, which batches by the
  -- channel OWNER. NULL on legacy gates -> callers COALESCE back to created_by.
  tier                INTEGER,
  need_asked_at       TEXT,
  gate_pinged_at      TEXT,
  gate_filed_by       TEXT,
  wake_at             TEXT,
  -- DIVE-931 secure credential drop: a --type=secret gate can name WHERE the
  -- value should land — secret_key is the env-var name, connector the
  -- /etc/5dive/connectors/<connector>.env stem. When both are set, the gate
  -- notify mints a burnable drop link (api /drop/mint) instead of the legacy
  -- "put it where I expect it" text. NULL on non-secret gates. The VALUE is
  -- never stored here — only the destination coordinates.
  secret_key          TEXT,
  connector           TEXT,
  -- DIVE-2411: the EXPLICIT out-of-band delivery declaration. A secret gate must
  -- name a delivery path or it cannot be filed: either the drop target above, or
  -- this — free text naming WHERE the human should put the value (".env on the
  -- box", "our shared channel"). Before DIVE-2411 both-NULL was the DEFAULTED
  -- legacy shape, which is how DIVE-2232 shipped a gate whose only answer path
  -- was pasting a live token into chat. Now both-NULL is unfilable and
  -- unanswerable; the legacy shape survives only when CHOSEN via --out-of-band.
  secret_oob          TEXT,
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
  precedent_kind      TEXT,
  -- DIVE-2241 needs_capability: the capability the FILER DECLARED this ask consumes
  -- (`task need --needs=<cap>`), verbatim, including an unrecognised one. Three names
  -- are human-class constants (human_tap / spend_authority / secret_provision) and
  -- resolve the gate to the paired human instead of the task's verifier or the filer's
  -- lead; anything else is undeclared-equivalent and changes no routing. DECLARED, never
  -- inferred from --type or the ask text. The sealed list lives in the shipped source
  -- (_GATE_HUMAN_CAPABILITIES), NOT here and not in any writable table — see DIVE-2099.
  needs_capability    TEXT,
  -- DIVE-2848 gate_rubber_stamp: the filer's DECLARED reason for routing a
  -- decision/approval gate to the paired human at tier 2 *despite* having written
  -- their own --recommend. That shape is refused by default at the keystroke (see
  -- the cap in cmd_task_need): measured 2026-07-16..08-07, 96 of 107 judgment gates
  -- carrying a recommendation came back as the human tapping that same value. The
  -- escape exists so a real exception can still be filed, and this column is what
  -- makes it AUDITABLE instead of invisible — the failure mode the cap replaces is
  -- an agent typing --tier=2 with no record of why. NULL on every gate that did not
  -- use the escape. Recorded verbatim, never inferred from the ask.
  gate_rubber_stamp   TEXT,
  -- DIVE-1140 gate-shipped sweep. Stamped (once) when the heartbeat finds a
  -- commit referencing this OPEN gate's ident on a configured repo's origin/main
  -- — the gate is FLAGGED "likely shipped, verify+close" to its owner. Flag-only
  -- for ALL tiers (lodar 2026-07-12): a merge is not a human sign-off (DIVE-555)
  -- and a commit may only partially fix a gate, so this NEVER auto-answers/closes
  -- — it only stops the ghost-gate from re-surfacing in the overnight recap and
  -- throttles the flag to once (re-flag only if cleared back to NULL).
  shipped_flag_at     TEXT,
  -- DIVE-1182: when builder-gate routing (DIVE-1145) sends a NON-true-human gate
  -- to the org lead, the designated reviewer's name is recorded here. It is the
  -- ONLY basis on which cmd_task_answer's approval/manual human-only floor grants
  -- a lead agent an exception (agent-<routed_reviewer> may clear THIS routed
  -- gate). NULL on every human-directed gate, so the DIVE-391/515/516 self-clear
  -- boundary is unchanged for anything not explicitly routed. `secret` is never
  -- routed (stays hard-human), and a tier-2 gate is never routed.
  routed_reviewer     TEXT,
  -- DIVE-1376/DIVE-2728: merge-gate binding and the loop iteration it belongs to.
  delivery_ref           TEXT,
  delivered_at           TEXT,
  delivery_ref_iteration INTEGER,
  -- OSS-27 (OSS-19 re-plan cycle): provenance for a task ORIGINATED by an
  -- objective's planner cycle. originated_by_objective = objectives.id that
  -- filed it; originated_cycle = the objective_cycles.cycle_no it was filed in.
  -- Both NULL for every human/goal/recurring/relay task. The re-plan cycle keys
  -- its "own originated tasks" scope on originated_by_objective: a planner may
  -- propose-cancel or reprioritize ONLY rows it originated — touching any
  -- human-created (or other-objective) task is impossible in code, never merely
  -- discouraged. Additive expand, NULL backfill.
  originated_by_objective INTEGER,
  originated_cycle        INTEGER,
  -- INST-2: integrity label for the verifier-by-default posture (DIVE-969/989).
  -- Set to 1 at add time ONLY when a non-trivial standard task WOULD have been
  -- graded by default but no distinct grader existed (solo org / the only
  -- candidate IS the maker) — the silent no-op the posture otherwise hides.
  -- Surfaced as "Unverified: no independent verifier available" on `task show`
  -- and the dashboard while verifier stays NULL, so the "verifier-graded by
  -- default" claim is never quietly false. NULL/0 for every task that got a real
  -- grader, opted out via --no-verify, or is trivial. Same integrity-invariant
  -- spirit as the council founder-excluded badge.
  verify_unavailable      INTEGER,
  -- DIVE-2730: the filer's EXPLICIT `--no-verify` at add time, set to 1 there and
  -- NULL everywhere else. It exists because a decision and a default that produce
  -- the same stored state ARE the same state: before this column, `--no-verify`
  -- was a local shell var in `task add` that died with the process, so at
  -- `task done` an explicit opt-out was byte-identical to a DIVE-969 auto-skipped
  -- row (both verifier NULL, verify_unavailable NULL), so `task done` could not
  -- NAME what it was overriding when DIVE-2719's UPGRADE arm re-attached a grader.
  -- Distinct from verify_unavailable, which records that no distinct grader
  -- EXISTED — this records that one was not WANTED.
  -- IT IS A RECORD, NOT A CONTROL, and deliberately so: the upgrade still fires
  -- on an opted-out row, because the flag is declared at FILE time and the blast
  -- radius is measured at DELIVERY time, and a file-time sentence must not
  -- pre-authorise closing a credentials diff nobody had written yet. What it buys
  -- is that the override is stated instead of silent, and that the two NULLs stop
  -- being one. Set only by `task add --no-verify`; cleared by
  -- `task verifier <id> <agent>`, since an explicit attach supersedes the refusal.
  verify_optout           INTEGER,
  -- DIVE-3251: THE FIRST TIME REAL WORK STARTED ON THIS ROW, and the one clock in
  -- this table that no nudge/reclaim path may touch. `started_at` is the CURRENT
  -- claim's clock and the heartbeat ladder deliberately clears it on reclaim, "so
  -- its age and the per-task nudge counter both restart cleanly"
  -- (_hb_reclaim_to_todo, src/cmd_heartbeat.sh) — a real requirement, not a typo.
  -- The defect was that one field was carrying BOTH meanings: resetting the age
  -- also destroyed the only board-visible evidence that the work had ever
  -- happened, so 58 rows fleet-wide read as never-started while carrying a
  -- `task.started` ledger event (16 of them still open at filing time).
  --
  -- SO: TWO FIELDS. `started_at` = the resettable claim clock the ladder owns.
  -- `first_started_at` = the durable record of first start, written once by
  -- COALESCE at every start path (`task start` and the dispatcher claim) and
  -- NEVER cleared by reclaim, handoff, or reassign. Read `started_at` to ask "is
  -- a seat on this now"; read `first_started_at` to ask "did real work happen".
  --
  -- IT IS A LOWER BOUND ON AGE, NOT THE LAST START, for rows backfilled from the
  -- ledger: the ledger's idem_key is constant per task (cmd_heartbeat.sh, the
  -- task.started emit), so a reclaimed-and-reclaimed row recorded its FIRST claim
  -- only. Going forward the reclaim emits its own `task.reclaimed` event, so
  -- cycles become countable from the ledger for rows reclaimed after this ships.
  -- Declared HERE as well as in _TASKS_ADDITIVE_COLUMNS, per the rule above: a
  -- fresh store takes this CREATE and never runs the ALTER loop.
  first_started_at        TEXT
);
CREATE INDEX IF NOT EXISTS idx_tasks_precedent ON tasks(need_type, ask_shape);
CREATE INDEX IF NOT EXISTS idx_tasks_originated ON tasks(originated_by_objective);

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

-- DIVE-3342: HUMANS as first-class records. agents_org above says who reports to
-- whom; nothing said who the PEOPLE are. A person existed only as a numeric chat
-- id inside one bot's access.json allowFrom, so gate routing could name an agent
-- clearer but never a person, and which human a gate actually paged was decided
-- by last-human-chat.json — whoever DM'd that bot most recently — fanning out to
-- the whole allowlist when no pointer resolved. Rationale, the measured harm, and
-- why ZERO rows must preserve the old delivery path exactly: src/cmd_human.sh.
-- A row here is an IDENTITY, never a grant: a telegram_id is still only
-- deliverable if the receiving bot's allowFrom contains it (enforced at the send
-- site, where the bot is known). Keep these two definitions byte-identical to the
-- copies in _tasks_db_migrate below (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS humans (
  id           TEXT PRIMARY KEY,
  display_name TEXT,
  telegram_id  TEXT,
  buzz_npub    TEXT,
  discord_id   TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS human_agents (
  human_id TEXT NOT NULL REFERENCES humans(id) ON DELETE CASCADE,
  agent    TEXT NOT NULL,
  PRIMARY KEY (human_id, agent)
);
CREATE INDEX IF NOT EXISTS human_agents_agent_idx ON human_agents(agent);

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

-- DIVE-1349: async goal-planner jobs. `goal add` (default, no --wait) spawns the
-- planner loop WITHOUT blocking and records the job here, returning a job id
-- immediately so the dashboard goals page never holds an HTTP request past the
-- gateway timeout (the old sync wait 502'd whenever the planner was busy/slow).
-- `goal status <job>` reads the backing planner task (task_id) and, once it lands
-- a plan, runs the same validate -> dry-run/gate/materialize tail. result_json
-- caches the terminal envelope so repeat polls are idempotent (a materialize
-- happens exactly once). Additive, never referenced by tasks/projects.
CREATE TABLE IF NOT EXISTS goal_jobs (
  job_id      TEXT PRIMARY KEY,
  loop_id     TEXT NOT NULL,
  task_id     INTEGER NOT NULL,
  outcome     TEXT NOT NULL,
  project     TEXT,
  planner     TEXT NOT NULL,
  max_tasks   INTEGER NOT NULL,
  depth_cap   INTEGER NOT NULL,
  checkpoint  INTEGER NOT NULL,
  ceiling     INTEGER NOT NULL,
  dry_run     INTEGER NOT NULL DEFAULT 0,
  yes         INTEGER NOT NULL DEFAULT 0,
  from_actor  TEXT,
  status      TEXT NOT NULL DEFAULT 'running',
  result_json TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS goal_jobs_status_idx ON goal_jobs(status);

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

-- DIVE-1922: policy refusals — the capture path behind `proof scorecard`'s
-- "policy-blocked action attempts". Until this existed the metric had NO
-- source: we recorded gates that were ASKED and ANSWERED, never attempts a
-- policy REFUSED before they got that far, so a rendered 0.0% would have read
-- as "we never get blocked". Written ONLY by policy_refuse(); append-only,
-- never updated or deleted, and never referenced by tasks/projects so it
-- cannot touch the queue. `policy` is a stable slug (not the message text, so
-- rewording a refusal never breaks the series); `ticket` is the rule's origin.
CREATE TABLE IF NOT EXISTS policy_refusals (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  ts       TEXT NOT NULL DEFAULT (datetime('now')),
  policy   TEXT NOT NULL,
  ticket   TEXT,
  actor    TEXT,
  ident    TEXT,
  detail   TEXT
);
CREATE INDEX IF NOT EXISTS policy_refusals_ts_idx ON policy_refusals(ts, policy);

-- DIVE-1923: the ship ledger — the capture path behind `proof scorecard`'s
-- "autonomous rollback rate". Nothing recorded an agent UNDOING work it had
-- already shipped: `task reject` is a VERIFIER bounce on the maker->verifier
-- rail, which happens BEFORE a ship and is a different event, so the metric had
-- no source at all and a rendered 0.0% would have read as "we never roll back".
--   Numerator and denominator come from the SAME instrument. A rate whose two
-- halves are sourced differently cannot report its own coverage; both kinds of
-- row here are written by the one site that observes a ship, `5dive push`. The
-- rollback half needs no new discipline from anyone because git itself writes
-- "This reverts commit <sha>" into a revert's message.
--   kind    ship|rollback (a revert is BOTH: it is a commit that was shipped)
--   reverts for kind='rollback', the sha the commit undoes
--   self    1 ONLY when that sha is itself a recorded ship — i.e. we can PROVE
--           the fleet undid its own shipped work. Every commit here is authored
--           `lodar` by policy, so authorship can never establish that. An
--           unprovable revert is stored with self=0 and surfaced as coverage,
--           never silently promoted into the numerator.
-- Append-only, never updated or deleted, never referenced by tasks/projects so
-- it cannot touch the queue. The UNIQUE index is what makes re-pushing the same
-- branch idempotent rather than a way to inflate the denominator.
CREATE TABLE IF NOT EXISTS ship_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      TEXT NOT NULL DEFAULT (datetime('now')),
  kind    TEXT NOT NULL,
  actor   TEXT,
  ident   TEXT,
  repo    TEXT,
  branch  TEXT,
  sha     TEXT NOT NULL,
  reverts TEXT,
  self    INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS ship_events_kind_sha_idx ON ship_events(kind, sha);
CREATE INDEX IF NOT EXISTS ship_events_ts_idx ON ship_events(ts, kind);

-- DIVE-2119: append-only gate history. `tasks` carries exactly ONE set of need_*
-- columns, so a task can only ever prove its MOST RECENT gate — and every verb
-- that retires a gate (a re-file, `need --withdraw`, `task park`, the
-- loop-ceiling auto-park) overwrote the previous one with nothing kept. One row
-- is appended here, in the SAME transaction, immediately BEFORE the provenance
-- columns are reset, so a displaced gate survives its own retirement. Written
-- only by _gate_archive_and_clear_sql; append-only (never updated or deleted)
-- and never referenced by tasks/projects, so it cannot touch the queue.
-- retired_by is the verb that displaced it: file|withdraw|park|loop-ceiling.
-- Additive, never referenced by tasks/projects, so it can't touch the queue.
-- Defined identically inside _tasks_db_migrate for pre-existing stores; keep the
-- two copies byte-identical (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS gate_history (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id           INTEGER NOT NULL,
  ident             TEXT,
  need_type         TEXT,
  ask               TEXT,
  need_options      TEXT,
  recommend         TEXT,
  tier              INTEGER,
  need_asked_at     TEXT,
  need_answer       TEXT,
  need_answered_at  TEXT,
  need_answered_by  TEXT,
  need_answered_uid INTEGER,
  need_answer_sig   TEXT,
  human_nonce_hash  TEXT,
  retired_by        TEXT NOT NULL,
  retired_at        TEXT NOT NULL DEFAULT (datetime('now')),
  floor_provenance  TEXT,
  -- DIVE-3171: carried for the same reason floor_provenance is. A retired gate that
  -- keeps its TIER's provenance and drops its ROUTE's is the half-record that makes a
  -- later count wrong in one direction only, and the count at stake here is "how often
  -- did the standing authority actually carry a gate".
  route_provenance  TEXT,
  gate_mode         TEXT
);
CREATE INDEX IF NOT EXISTS gate_history_task_idx ON gate_history(task_id, id);

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

-- DIVE-2133: evidence boundary for the gate_history reader. A fresh store
-- stamps this before its first task, so zero archived rows can truthfully mean
-- zero displaced gates. Existing stores stamp conservatively in migration: the
-- earliest row already present, or migration time when the archive is empty.
INSERT OR IGNORE INTO task_prefs(key,value)
  SELECT 'gate_history_coverage', 'fresh:'||datetime('now');

-- OSS-19 (OSS-26, phase A1): outcome-loop objectives. An objective is a standing
-- goal bound to a READ-ONLY metric command (metric_cmd: stdout -> one number).
-- The metric is run ONLY by `objective tick` and the digest — NEVER by a planner
-- (the anti-Goodhart separation: the planner receives readings, it can't own the
-- number). This phase A1 build is MEASUREMENT ONLY: no origination, no planner
-- cycle. The re-plan cycle (planner, review cron, max_new_per_cycle, budget,
-- project_key link) is the successor build; those columns are stored now so the
-- data model is stable, but nothing reads them for origination yet.
--   direction  up|down — which way is "better" (target gap + trend sign)
--   public     1 => eligible for the public proof feed (rides proof publish in a
--              later phase; this build does not touch cmd_proof.sh)
--   status     active|paused — paused objectives are not ticked
-- Additive, never referenced by tasks/projects, so it can't touch the queue.
-- Defined identically inside _tasks_db_migrate for pre-existing stores; keep the
-- two copies byte-identical (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS objectives (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT NOT NULL UNIQUE,
  metric_cmd        TEXT NOT NULL,
  target            REAL,
  direction         TEXT NOT NULL DEFAULT 'up',
  unit              TEXT,
  review            TEXT,
  planner           TEXT,
  project_key       TEXT,
  max_new_per_cycle INTEGER NOT NULL DEFAULT 3,
  budget            INTEGER,
  public            INTEGER NOT NULL DEFAULT 0,
  status            TEXT NOT NULL DEFAULT 'active',
  -- OSS-27 shadow-first run mode (OSS-35): 'live' (default) applies a re-plan
  -- cycle's non-origination changes within the objective's own-task autonomy,
  -- 'shadow' forces PROPOSE-ONLY -- the entire diff rides ONE gate a human
  -- confirms, nothing auto-applies, and --yes cannot waive it. Fail-safe lever
  -- so a dogfood run (OSS-35) never touches the live company until approved.
  run_mode          TEXT NOT NULL DEFAULT 'live',
  created_by        TEXT,
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
-- Append-only reading history — one row per tick (value=NULL + rc!=0 on a metric
-- failure, so a broken metric-cmd shows as a visible gap, not a silent skip). This
-- is the audit trail, same honesty pattern as the proof branch's history.jsonl.
-- Keep byte-identical to the copy in _tasks_db_migrate (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS objective_readings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  objective_id INTEGER NOT NULL REFERENCES objectives(id) ON DELETE CASCADE,
  ts           TEXT NOT NULL DEFAULT (datetime('now')),
  value        REAL,
  rc           INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS objective_readings_idx ON objective_readings(objective_id, id);
-- OSS-27 (OSS-19 re-plan cycle): one append-only row per objective PLANNER CYCLE
-- (`objective replan`). The honesty/audit trail for origination — same pattern as
-- objective_readings. cycle_no is the monotone per-objective cycle index. outcome
-- records what the cycle did: applied | gated | target_reached | budget_exhausted
-- | noop. reading_value is the metric reading the planner saw. tokens_spent is the
-- planner's spend that cycle (fed into the per-objective budget stop-condition).
-- gate_anchor is the ident of the ONE count-checkpoint decision gate a gated cycle
-- filed (NULL otherwise). Keep byte-identical to the copy in _tasks_db_migrate.
CREATE TABLE IF NOT EXISTS objective_cycles (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  objective_id  INTEGER NOT NULL REFERENCES objectives(id) ON DELETE CASCADE,
  cycle_no      INTEGER NOT NULL,
  ts            TEXT NOT NULL DEFAULT (datetime('now')),
  reading_value REAL,
  proposed      INTEGER NOT NULL DEFAULT 0,
  applied       INTEGER NOT NULL DEFAULT 0,
  reprioritized INTEGER NOT NULL DEFAULT 0,
  cancelled     INTEGER NOT NULL DEFAULT 0,
  gated         INTEGER NOT NULL DEFAULT 0,
  gate_anchor   TEXT,
  tokens_spent  INTEGER NOT NULL DEFAULT 0,
  planner_loop_id TEXT,
  planner_task_id INTEGER,
  outcome       TEXT NOT NULL DEFAULT 'noop'
);
CREATE INDEX IF NOT EXISTS objective_cycles_idx ON objective_cycles(objective_id, cycle_no);

-- INST-4: the unified lifecycle ledger — ONE append-only log for the whole
-- task/gate/verify/ship lifecycle, carrying the full authority envelope on every
-- row (actor, authority, parent, idempotency key, input/output hashes, policy
-- decision, usage, host).
--
-- We were ALREADY event-sourcing, in four separate append-only silos:
-- supervisor_events (DIVE-724), objective_readings (OSS-19), the council
-- governance lineage, and the _audit_append log (DIVE-1268). Each is correct and
-- each answers a different question, which is precisely the problem: no single
-- one of them can answer "who was authorized to do this, why, and what happened
-- next", because the answer is split across four schemas with four different
-- notions of actor, four timestamp conventions, and no shared key. `5dive trace`
-- had to hand-join transition COLUMNS on the tasks row to fake one.
--
-- ADDITIVE BY CONSTRUCTION. This does NOT replace the state machine, the four
-- silos, or any existing write. Every current writer keeps writing where it
-- writes today; the emitters below run ALONGSIDE them. The tasks row stays the
-- authority on current state — read it as the materialized view this log would
-- rebuild, not as a thing to be migrated. Nothing here is referenced by
-- tasks/projects, so it cannot touch the queue, and a ledger write that fails
-- can never fail the action it describes (see ledger_emit).
--
-- READ THE START MARKER BEFORE READING THE ROWS. A ledger installed today has
-- nothing to say about work that finished yesterday, and the failure mode this
-- codebase keeps paying for is exactly that: absence read as evidence. The
-- ledger_started pref (task_prefs) stamps the first init, and `trace` refuses to
-- render an empty ledger section for a task that predates it.
--   kind       dotted lifecycle verb: task.created|task.started|task.delivered|
--              task.done|task.cancelled|gate.filed|gate.answered|policy.refused|
--              ship|rollback
--   actor      the identity the RECORDING SITE is authoritative for, which is not
--              the same namespace for every kind and should not be forced to be.
--              Task lifecycle rows carry the BOARD actor (task_actor: `dev`),
--              because the org is what those events are about. ship/rollback rows
--              carry the ship actor ship_events already recorded, so the two rows
--              about one ship can never disagree. gate.answered carries the
--              persisted gate provenance (`human:...`, `lead:standing:...`), which
--              is the only identity that decides whether a human touched the work.
--   authority  root | sudo:<who> | self — the elevation, which the audit log has
--              never recorded (see _actor_authority)
--   idem_key   natural key for the event. The UNIQUE index makes a retried emit
--              collapse instead of double-counting; a caller needing genuine
--              repeats supplies its own distinguishing key.
--   input_hash/output_hash  sha256 (first 16 hex) of the raw payloads, hashed by
--              ledger_emit. The ledger stores digests, never the content, so it
--              stays safe to read at a lower privilege than the thing it records.
-- Append-only: never updated, never deleted.
-- Defined identically inside _tasks_db_migrate for pre-existing stores; keep the
-- two copies byte-identical (tests/schema_sync_unit.sh).
CREATE TABLE IF NOT EXISTS lifecycle_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  ts              TEXT NOT NULL DEFAULT (datetime('now')),
  kind            TEXT NOT NULL,
  ident           TEXT,
  task_id         INTEGER,
  actor           TEXT NOT NULL,
  authority       TEXT NOT NULL DEFAULT 'self',
  parent_ident    TEXT,
  idem_key        TEXT NOT NULL,
  input_hash      TEXT,
  output_hash     TEXT,
  policy_decision TEXT,
  tokens          INTEGER,
  host            TEXT,
  detail          TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_events_idem_idx ON lifecycle_events(idem_key);
CREATE INDEX IF NOT EXISTS lifecycle_events_ident_idx ON lifecycle_events(ident, id);
CREATE INDEX IF NOT EXISTS lifecycle_events_ts_idx ON lifecycle_events(ts, kind);
SQL
}

# -------- DIVE-1479: silent-recreate trap guard --------
#
# The 2026-07-19 04:20 wipe = something unlinked tasks.db, then a routine cron
# reader ran tasks_db_init which SILENTLY recreated it empty — the board looked
# legitimately empty and everyone proceeded. The guard below makes that class of
# data-loss LOUD + self-healing: a durable sentinel records that the board was
# initialized at least once; if the tasks table is ever absent while that
# sentinel (or a backup snapshot) exists, we DON'T silently create an empty
# board — we alarm on stderr + an incident log and auto-restore from the newest
# /var/lib/5dive/tasks-backups snapshot (written every 5min by
# 5dive-tasks-backup.sh, which only snapshots a NON-empty board).
#
# Paths are resolved at CALL time (not sourced into constants) so the DIVE-1475
# STATE_DIR/TASKS_DIR test-isolation overrides still redirect them to a temp tree.
# The sentinel lives beside the active store — for prod that is TASKS_DIR
# (2770 group-writable, so any agent can write
# it and it survives a bare `rm tasks.db`); the backups + incident log live in
# the sibling tasks-backups dir. If the whole TASKS_DIR is wiped the sentinel
# goes with it, but the backup snapshots in the sibling dir still trip the alarm.
_tasks_backup_dir() { printf '%s' "${TASKS_BACKUP_DIR:-${STATE_DIR}/tasks-backups}"; }
# DIVE-1986: the sentinel is a fact about the store BESIDE it, so derive it from
# the active store's own directory rather than from TASKS_DIR. Identical whenever
# TASKS_DB is that dir's tasks.db (every isolated harness, and prod); different
# only in the case this fixes — TASKS_DB aimed elsewhere with TASKS_DIR left at
# its default, where reading the prod sentinel makes prod's history testify about
# a store it has never met.
_tasks_store_dir() { local d; d="$(dirname -- "$TASKS_DB" 2>/dev/null)"; printf '%s' "${d:-$TASKS_DIR}"; }
_tasks_sentinel()  { printf '%s' "${TASKS_SENTINEL:-$(_tasks_store_dir)/.board-initialized}"; }

# DIVE-1986: do the snapshots in the backup dir belong to the ACTIVE store?
#
# 5dive-tasks-backup.sh snapshots ONE board: ${TASKS_DIR}/tasks.db. Those .db.gz
# files are that board's history and no other's. The restore path did not check,
# so `TASKS_DB=/tmp/x/tasks.db 5dive task init` — TASKS_DB overridden alone,
# STATE_DIR left at its default, which is what a harness that only wants a
# throwaway store naturally writes — found the prod sentinel, then the prod
# snapshots, and auto-restored 579 rows of production task bodies, results and
# gate ASK text into /tmp. Two costs, both real: task content that names people,
# decisions and spend lands wherever the caller pointed, and a fixture store the
# author believes is empty silently is not.
#
# An explicit TASKS_BACKUP_DIR is the caller pairing a backup set with their own
# store on purpose, so it is honoured as-is — the override cannot be the source of
# the mismatch it would have to describe.
#
# readlink -f prints nothing when a path's PARENT does not exist, so fall back to
# the literal path rather than comparing "" == "" and matching everything — the
# same three-state care _tasks_store_is_prod takes, and the opposite failure
# direction matters just as much here: an empty result must not read as a match.
_tasks_backups_match_store() {
  [[ -n "${TASKS_BACKUP_DIR:-}" ]] && return 0
  local active canon ra rc
  active="$TASKS_DB"; canon="${TASKS_DIR}/tasks.db"
  ra="$(readlink -f "$active" 2>/dev/null)"; [[ -n "$ra" ]] || ra="$active"
  rc="$(readlink -f "$canon"  2>/dev/null)"; [[ -n "$rc" ]] || rc="$canon"
  [[ "$ra" == "$rc" ]]
}

# Newest backup snapshot path (most recent first), or empty when none exist —
# or when the snapshots are a DIFFERENT board's history (DIVE-1986).
_tasks_newest_backup() {
  _tasks_backups_match_store || return 0
  ls -1t "$(_tasks_backup_dir)"/tasks-*.db.gz 2>/dev/null | head -n1
}

# Has the board been initialized before? A sentinel OR any backup snapshot both
# prove prior existence; either one turns a missing table into an incident
# rather than a fresh-box first-run.
_tasks_board_existed() {
  [[ -f "$(_tasks_sentinel)" ]] && return 0
  [[ -n "$(_tasks_newest_backup)" ]] && return 0
  return 1
}

# Idempotent: stamp the sentinel the first time we see a healthy board. Cheap
# once present (a single stat), best-effort on the write so a perms hiccup never
# breaks a task command.
_tasks_mark_initialized() {
  local s; s="$(_tasks_sentinel)"
  [[ -f "$s" ]] && return 0
  { : > "$s"; } 2>/dev/null || true
}

# LOUD alarm: stderr (the durable channel a human/cron log sees) + a best-effort
# append to a durable incident log next to the backups.
_tasks_alarm() {
  local ts; ts=$(date -u +%FT%TZ 2>/dev/null || echo now)
  printf '🚨 [5dive tasks-db] %s: %s\n' "$ts" "$1" >&2
  { printf '%s\t%s\t%s\n' "$ts" "${SUDO_USER:-$(id -un 2>/dev/null || echo ?)}" "$1" \
      >> "$(_tasks_backup_dir)/RESTORE-INCIDENTS.log"; } 2>/dev/null || true
}

# The table is absent but the board existed before: alarm + auto-restore from the
# newest snapshot, or fail LOUDLY (never silently recreate an empty board). Serial-
# ized under a lock so concurrent inits don't double-restore; the winner recreates
# the table and every follower re-checks and no-ops.
_tasks_board_recover() {
  _tasks_alarm "board table MISSING but previously initialized (sentinel/backup present) — refusing to silently recreate an EMPTY board."
  local newest; newest=$(_tasks_newest_backup)
  if [[ -z "$newest" ]]; then
    _tasks_alarm "no backup snapshot in $(_tasks_backup_dir) — cannot auto-restore; MANUAL recovery required."
    fail "$E_GENERIC" "tasks board vanished and no backup exists to restore — investigate before proceeding (DIVE-1479)."
  fi
  (
    flock 9 2>/dev/null || true
    local h2
    h2=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
         "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks' LIMIT 1;" 2>/dev/null)
    [[ "$h2" == "1" ]] && exit 0   # another init already restored under the lock
    local tmp="${TASKS_DB}.restore.$$"
    if ! gunzip -c "$newest" > "$tmp" 2>/dev/null; then
      _tasks_alarm "gunzip of $newest failed"; rm -f "$tmp"; exit 3
    fi
    local rows
    rows=$(sqlite3 "$tmp" "SELECT count(*) FROM tasks;" 2>/dev/null || echo 0)
    if [[ "${rows:-0}" -lt 1 ]]; then
      _tasks_alarm "restore source $newest had 0 rows / no tasks table"; rm -f "$tmp"; exit 3
    fi
    # Drop any stale WAL/SHM from the vanished db so the restored file is authoritative.
    rm -f "${TASKS_DB}-wal" "${TASKS_DB}-shm" 2>/dev/null || true
    mv -f "$tmp" "$TASKS_DB" && chmod 0660 "$TASKS_DB" 2>/dev/null
    _tasks_alarm "AUTO-RESTORED $rows rows from $(basename "$newest") — verify integrity."
  ) 9>"$(_tasks_store_dir)/.recover.lock"   # DIVE-1986: lock beside the store being recovered, not always prod's
  # Confirm we ended with a real table; if not, fail loudly rather than proceed empty.
  local h3
  h3=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
       "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks' LIMIT 1;" 2>/dev/null)
  [[ "$h3" == "1" ]] || fail "$E_GENERIC" \
    "tasks board auto-restore failed — MANUAL recovery required (DIVE-1479); newest snapshot: $newest"
}

# Create the group-writable tasks dir + db and apply the schema. Safe to call
# repeatedly; command functions call it first. If the dir is missing and we
# aren't root we can't create it (parent /var/lib/5dive is 2750), so emit a
# one-time bootstrap hint instead of a cryptic failure.
tasks_db_init() {
  require_sqlite
  # DIVE-2518: prime the registry memo ONCE, here, in the top-level shell.
  # `task_actor` runs inside `$( )` at nearly every one of its 43 call sites, so a
  # memo it populates itself dies with the subshell and `agent_tier` would shell out
  # to jq a dozen times per verb. A subshell INHERITS the parent's variables, so
  # priming here makes every later call a cache hit. Best-effort by construction:
  # the value is only a name, and if this fails the ladder in `actor_board_name`
  # re-derives it. `|| true` because init must not fail on an unreadable registry.
  actor_board_name >/dev/null 2>&1 || true
  # DIVE-2249: init is a write path in its own right (schema apply + additive
  # migrations go straight to sqlite3, not through db()), so fence it here rather
  # than at each of those call sites.
  _tasks_store_fence "CREATE TABLE"
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
  local has created_fresh=0
  has=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='tasks' LIMIT 1;" 2>/dev/null)
  if [[ "$has" != "1" ]]; then
    # DIVE-1479: a missing table on a board that existed before is the
    # silent-recreate trap — alarm + auto-restore, never a silent empty create.
    # Only a genuinely fresh box (no sentinel, no snapshot) gets a new schema.
    if _tasks_board_existed; then
      _tasks_board_recover
    else
      local fresh_payload row
      # DIVE-2808: a fresh store is born at the current whole-schema epoch in the
      # SAME sqlite invocation. Existing stores earn this receipt only after the
      # complete migration and canonical-surface assertion below.
      #
      # The stamp lives HERE and not in _tasks_schema() on purpose. Every statement
      # that block emits is `CREATE ... IF NOT EXISTS`, so replaying it over an
      # existing store is a no-op — a contract the migration driver and several
      # harnesses rely on, and a bare INSERT is the one statement that breaks it
      # (UNIQUE constraint failed: task_prefs.key). Making the INSERT itself
      # idempotent would be worse than leaving it out: an upsert would stamp the
      # CURRENT epoch onto a store that a replay does not actually complete, since
      # `CREATE TABLE IF NOT EXISTS tasks` adds no column to an existing tasks
      # table. That is the lying-gate class this row exists to close. Only this
      # arm has just proved it created the whole schema from nothing.
      fresh_payload=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" < <(
        _tasks_schema
        printf "INSERT INTO task_prefs(key,value) VALUES ('schema_epoch',%s);\n" \
          "$(sqlq "$_TASKS_SCHEMA_EPOCH")"
        # DIVE-2808: the ledger start marker was seeded inside _tasks_db_migrate,
        # which a fresh store no longer enters. Without this a brand-new board has
        # no marker at all, and `trace` reads a ledger with nothing to say about
        # anything as one that predates everything — absence read as evidence,
        # which is the exact failure the marker exists to prevent.
        printf "INSERT OR IGNORE INTO task_prefs(key,value) VALUES ('ledger_started',datetime('now'));\n"
        printf "SELECT 'column:'||name FROM pragma_table_info('tasks');\n"
      )) || fail "$E_GENERIC" "failed to initialise tasks db at $TASKS_DB"
      _TASKS_DB_GATE_COLUMNS=''
      while IFS= read -r row; do
        [[ "$row" == column:* ]] || continue  # ignores PRAGMA journal_mode's "wal"
        _TASKS_DB_GATE_COLUMNS+="${row#column:}"$'\n'
      done <<<"$fresh_payload"
      _TASKS_DB_GATE_COLUMNS="${_TASKS_DB_GATE_COLUMNS%$'\n'}"
      chmod 0660 "$TASKS_DB" 2>/dev/null || true
      created_fresh=1
    fi
  fi
  # DIVE-2808: the canonical schema is complete, so almost every invocation can
  # skip the expensive reconciliation. The gate requires the whole-schema epoch
  # plus the SAME tasks-column array the migration consumes; pure-Bash membership
  # avoids one grep process per column. Both arms retain DIVE-2197's assertion.
  if ((created_fresh)); then
    # The CREATE and epoch stamp succeeded in one sqlite invocation. Preserve DIVE-2197's
    # independent resulting-set assertion without paying a redundant epoch read.
    _tasks_db_assert_required_columns "$_TASKS_DB_GATE_COLUMNS"
  elif _tasks_db_migration_needed; then
    _tasks_db_migrate
  else
    _tasks_db_assert_required_columns "$_TASKS_DB_GATE_COLUMNS"
  fi
  # DIVE-1479: stamp the durable "this board exists" sentinel (idempotent). On a
  # pre-existing board this is the one-time backfill so a later wipe is caught.
  _tasks_mark_initialized
}

# One source of truth for both migration and its skip-gate. Each entry is
# "<column> <type>"; existing rows backfill to NULL. Pure expand (no contract),
# so old queries/rows remain readable after downgrade. project_key deliberately
# omits REFERENCES here because sqlite rejects a non-NULL FK default on ADD.
# DIVE-2272: the fleet-wide fallback bound for an on_overlap='spawn' template that
# sets no overlap_bound of its own. A JUDGMENT CALL, NOT A MEASUREMENT — 3 open
# recaps is unmistakable to a human and 300 is a different outage. Env-tunable and
# per-template overridable precisely so the number is never read as derived.
# Lives here, not in cmd_heartbeat.sh, so the materializer and `task ls --recurring`
# read the SAME default (the DIVE-2055 no-disagreement rule for that table).
TASKS_OVERLAP_BOUND_DEFAULT="${HEARTBEAT_OVERLAP_BOUND:-3}"
[[ "$TASKS_OVERLAP_BOUND_DEFAULT" =~ ^[1-9][0-9]*$ ]] || TASKS_OVERLAP_BOUND_DEFAULT=3

_TASKS_ADDITIVE_COLUMNS=(
  'result TEXT' 'need_type TEXT' 'ask TEXT' 'need_options TEXT' 'recommend TEXT'
  'need_answer TEXT' 'need_answered_at TEXT'
  "kind TEXT NOT NULL DEFAULT 'standard'" 'schedule TEXT' 'last_fired_at TEXT'
  'from_template_id INTEGER' 'fresh INTEGER'
  'parked_at TEXT' 'park_reason TEXT' 'need_answered_by TEXT'
  'need_answered_uid INTEGER' 'need_answer_sig TEXT'
  'escalated_at TEXT' 'escalated_by TEXT'
  "project_key TEXT NOT NULL DEFAULT 'dive'" 'issue_number INTEGER'
  'acceptance_criteria TEXT' 'verify_command TEXT' 'max_iterations INTEGER' 'verifier TEXT'
  'iteration INTEGER' 'maker_agent TEXT' 'handoff_ack_at TEXT' 'task_budget TEXT'
  'handoff_delivered_at TEXT' 'handoff_stale_pinged_at TEXT' 'handoff_rejected_at TEXT'
  'recurring_stall_pinged_at TEXT' 'recurring_stall_escalated_at TEXT'
  'gate_answered_nudged_at TEXT'
  'nudge_escalated_at TEXT' 'nudge_escalated_n INTEGER' 'nudge_parked_at TEXT'
  'tier INTEGER' 'need_asked_at TEXT' 'gate_pinged_at TEXT' 'wake_at TEXT'
  'gate_filed_by TEXT'
  'secret_key TEXT' 'connector TEXT' 'secret_oob TEXT' 'human_nonce_hash TEXT'
  'ask_shape TEXT' 'precedent_ref INTEGER' 'precedent_kind TEXT'
  'needs_capability TEXT'
  'gate_rubber_stamp TEXT'
  'shipped_flag_at TEXT' 'routed_reviewer TEXT'
  'delivery_ref TEXT' 'delivered_at TEXT' 'delivery_ref_iteration INTEGER'
  'originated_by_objective INTEGER' 'originated_cycle INTEGER'
  'verify_unavailable INTEGER' 'last_skipped_at TEXT'
  # DIVE-2730: the add-time `--no-verify`, persisted. Nullable — NULL is "the
  # filer did not opt out", which is the truth for every pre-existing row, so the
  # backfill is a no-op. See the CREATE TABLE comment for why an unpersisted
  # refusal reads downstream as a default absence.
  'verify_optout INTEGER'
  # DIVE-3251: the durable first-start clock, split out of `started_at` so the
  # reclaim ladder can keep restarting the age without destroying the evidence
  # that work happened. Nullable — NULL means "this build never recorded it",
  # which is a real third state and NOT a synonym for never-started; the
  # migration below backfills it from the ledger where a start was recorded,
  # and from started_at otherwise. See the CREATE TABLE comment.
  'first_started_at TEXT'
  # DIVE-2272: per-template overlap policy. Both NULLABLE on purpose -- NULL is
  # 'skip' / 'the default bound', so the migration is a no-op for every existing
  # template AND an unclassified template stays visibly unclassified. See the
  # CREATE TABLE comment for why the pile-up's value is per-template.
  'on_overlap TEXT' 'overlap_bound INTEGER'
  'human_evidence TEXT' 'derived_actor TEXT' 'floor_provenance TEXT'
  # DIVE-3171: the ROUTING axis's provenance, sibling to floor_provenance. See the
  # CREATE TABLE comment for the values and for why it is stored, not derived.
  'route_provenance TEXT'
  # DIVE-3128: the tapping human vs the relaying bot, separated. See the CREATE
  # TABLE comment above for why folding them into one string was the defect.
  'need_answered_relay TEXT' 'need_answered_tap_uid TEXT'
  # DIVE-3098: a verifier grade recorded by `task verify --no-done`. Structural on
  # purpose — the terminal-for-verifier predicate must not key on result TEXT,
  # which the MAKER's `task deliver --result=` also writes.
  'graded_at TEXT' 'graded_by TEXT'
  # DIVE-3430: the VERDICT of that grade, and when the current verdict was recorded.
  # See the CREATE TABLE comment for why these are bare-SET while graded_at is
  # COALESCE'd, and why NULL must keep reading as a pass.
  'graded_verdict TEXT' 'graded_verdict_at TEXT'
  # DIVE-2354: approve-to-send | confirm-after-send. See the CREATE TABLE comment.
  'gate_mode TEXT'
  # DIVE-3342: humans.id of the person who may CLEAR this gate. See the CREATE
  # TABLE comment — recorded at filing, never re-derived from bot traffic.
  'human_owner TEXT'
)

# DIVE-3098 - TERMINAL FOR THE VERIFIER, as ONE SQL boolean expression.
#
# Three readers evaluate this: `task ls`'s render, `_task_terminal_for_verifier`
# (the goal Stop hook's answer), and the heartbeat rot-nudger's exclusion. They MUST
# agree - a row the nudger exempts but the render still paints `todo` is the original
# bug wearing different clothes. So it is written once here and interpolated, never
# retyped. (Same rule that produced broker_strip_md_quotes: a two-reader binding
# diverges the moment someone fixes one side.)
#
# Every conjunct is load-bearing:
#   graded_at                - stamped ONLY by `task verify --no-done`, never by the
#                              maker's `task deliver --result=`, so it cannot be
#                              forged in prose.
#   graded_by <> maker_agent - a self-verified close does not buy the exemption.
#   delivery_ref             - a verdict with nothing to merge is not awaiting a merge.
#   handoff_rejected_at      - DIVE-3428, below. A grade is not a LATCH.
#   graded_verdict           - DIVE-3430, below. A grade is not a PASS.
# status stays OPEN: terminal for the VERIFIER, non-terminal for the ROW.
# NOT `readonly`: several harnesses and code paths source this lib twice, and a
# readonly re-assignment errors on the second source — measured, it broke 8 arms of
# tests/gate_route_delivery_unit.sh with a stderr line and nothing else. Every other
# constant in this file (incl. _TASKS_SCHEMA_EPOCH) is a plain assignment for the
# same reason; match the file.
# DIVE-3428 — A GRADE IS NOT A LATCH, and until this conjunct existed the predicate
# treated it as one: it asked "has a grade ever been recorded?" and never "is the
# latest verdict still a pass?". Measured on DIVE-3315 — graded_at 2026-08-12 (quinn,
# PASS), handoff_rejected_at 2026-08-16 (codex, FAIL) — the reject FOUR DAYS newer,
# and both board branches still rendered `graded->merge:olivia`.
#
# NOT COSMETIC: the label is consumed as an INSTRUCTION. `_hb_loop_terminal_clause`
# formats the same predicate into the /goal wrapper as "TERMINAL FOR THIS GOAL ...
# Treat the goal as MET and stop", so a row with a live verifier FAIL and real
# outstanding maker work told an agent to stop, and named the outstanding act as a
# MERGE of a PR that must not be merged in its graded state.
#
# `<` AND NOT `<=`, WHICH THE ROW ASKED FOR — the tie is reachable and it is not a
# rounding detail. graded_at is stamped by the `verify` else-branch, which is
# `rc != 0 || no_done`, so a FAIL verify stamps it; a verifier who runs `task verify`
# then `task reject` lands both stamps in the SAME second at datetime()'s one-second
# resolution (the tie DIVE-2624 measured on this very column pair and solved with a
# token instead of a clock). `<=` would hand that tie to the GRADE and reprint the
# exact label this row exists to remove. The tie goes to the REJECT because the two
# errors are not symmetric: a false `graded->merge` tells an agent to STOP on live
# work, while a false plain status merely makes someone open the row.
#
# The OLDER-reject arm is still a real state and still renders graded->merge:
# graded_at is COALESCE'd (first grade wins), so a reject that predates the
# first-ever grade is a verifier who bounced and then graded a pass without a
# re-delivery. handoff_rejected_at is a TOKEN spent (NULLed) by the next delivery,
# so a live one means the maker has not answered the bounce yet.
# DIVE-3430 — AND A GRADE IS NOT A PASS. DIVE-3428 closed the REJECT door; this is
# the other one, and it needs no second actor at all. `graded_at` is stamped in
# `cmd_task_verify`'s else-branch, and that else is the else of
# `rc == 0 && ! no_done` — so a verifier who records a FAIL through `task verify` and
# does NOT additionally `task reject` stamps graded_at, leaves handoff_rejected_at
# NULL, and reproduces the DIVE-3315 render exactly with no token for the conjunct
# above to see. Measured on a bound fixture before this line existed:
#   task verify --cmd=false                                 -> graded_at set, reject NULL
#   task verify --no-done --cmd=false --result="FAIL: ..."   -> graded_at set, reject NULL
# both rendering graded->merge. Two doors, two tokens: handoff_rejected_at is the
# `reject` verb's, graded_verdict is `verify`'s. `reject` deliberately does NOT write
# graded_verdict — it has its own token, and writing both would make a bounce
# unrecoverable by the pass-grade path DIVE-3428's older-reject arm depends on.
#
# NULL IS A PASS HERE, and that is the whole migration story. NULL means "graded
# before this column existed", not "failed"; reading it as a fail would drop every
# already-graded row off the board the moment this shipped — a silent regression on
# live data, in the direction this predicate is least able to afford. See the CREATE
# TABLE comment for why no backfill can do better than that.
_TASKS_TFV_SQL="graded_at IS NOT NULL
       AND delivery_ref IS NOT NULL AND TRIM(delivery_ref) <> ''
       AND (maker_agent IS NULL OR graded_by IS NULL OR graded_by <> maker_agent)
       AND (handoff_rejected_at IS NULL OR handoff_rejected_at < graded_at)
       AND (graded_verdict IS NULL OR graded_verdict = 'pass')
       AND status NOT IN ('done','cancelled')"

_TASKS_DB_GATE_COLUMNS=''
_TASKS_DB_GATE_EPOCH=''
_TASKS_DB_GATE_SEEDS=''

# Exact newline membership without a subprocess. The newline frame prevents a
# prefix (need_ty) from satisfying a full column name (need_type).
_tasks_columns_have_all_additive() { # <newline-delimited pragma names>
  local cols="${1:-}" c name framed
  framed=$'\n'"$cols"$'\n'
  for c in "${_TASKS_ADDITIVE_COLUMNS[@]}"; do
    name="${c%% *}"
    [[ "$framed" == *$'\n'"$name"$'\n'* ]] || return 1
  done
  return 0
}

# DIVE-2808: the migration also SEEDS, it does not only alter shape, and a gate that
# reasons only about SHAPE silently drops every seed. Each key below is written by
# `_tasks_db_migrate` with an INSERT OR IGNORE that re-runs on every pass, so before
# this gate existed a deleted row healed itself on the next invocation. Skipping the
# migration removes that, and the loss is invisible to any schema comparison: the
# store is shape-perfect and semantically wrong. A missing seed therefore sends the
# store back through the migration once, which re-seeds it.
#
# ONE SOURCE OF TRUTH. This array is the gate's model of what the migration seeds,
# and it is the same drift hazard as the column list: a copy that falls behind the
# migration reports *current* on a store that is not. tests/tasks_db_restore_guard_unit.sh
# Case 16 DERIVES the seeded keys from `_tasks_db_migrate`'s own source and reds if
# the two disagree in either direction, so adding a seed to the migration without
# adding it here cannot pass quietly.
#
# `ledger_started` (INST-4) was the first found: `trace` reads a missing marker as a
# ledger that predates everything. `gate_history_coverage` (DIVE-2133) was the second
# and was missed by the first cut — the coverage boundary the gate_history reader
# needs to tell "no gates were displaced" from "the archive was not yet writing", so
# losing it downgrades a truthful complete zero to `unknown`. Two of two seeds in the
# migration were self-healing, which is why the list is enumerated rather than the
# exception hand-carved.
_TASKS_SELFHEAL_PREFS=(ledger_started gate_history_coverage)

_tasks_db_migration_needed() {
  local payload row k in_list=''
  # The seed markers ride along in the SAME read as the epoch and the columns, so
  # keeping their self-heal costs no extra process. See the note above.
  for k in "${_TASKS_SELFHEAL_PREFS[@]}"; do in_list+="${in_list:+,}'${k//\'/\'\'}'"; done
  payload=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 'epoch:'||COALESCE((SELECT value FROM task_prefs WHERE key='schema_epoch'),'')
       UNION ALL
     SELECT 'seed:'||key FROM task_prefs WHERE key IN ($in_list)
       UNION ALL
     SELECT 'column:'||name FROM pragma_table_info('tasks');" 2>/dev/null) || return 0
  _TASKS_DB_GATE_COLUMNS=''
  _TASKS_DB_GATE_EPOCH=''
  _TASKS_DB_GATE_SEEDS=''
  while IFS= read -r row; do
    case "$row" in
      epoch:*)  _TASKS_DB_GATE_EPOCH="${row#epoch:}" ;;
      seed:*)   _TASKS_DB_GATE_SEEDS+="${row#seed:}"$'\n' ;;
      column:*) _TASKS_DB_GATE_COLUMNS+="${row#column:}"$'\n' ;;
    esac
  done <<<"$payload"
  _TASKS_DB_GATE_COLUMNS="${_TASKS_DB_GATE_COLUMNS%$'\n'}"
  _TASKS_DB_GATE_SEEDS="${_TASKS_DB_GATE_SEEDS%$'\n'}"
  [[ "$_TASKS_DB_GATE_EPOCH" == "$_TASKS_SCHEMA_EPOCH" ]] || return 0
  _tasks_prefs_have_all_seeds "$_TASKS_DB_GATE_SEEDS" || return 0
  ! _tasks_columns_have_all_additive "$_TASKS_DB_GATE_COLUMNS"
}

# Same newline-framed membership as the column check, and for the same reason: no
# subprocess per key, and no prefix satisfying a longer name.
_tasks_prefs_have_all_seeds() { # <newline-delimited present pref keys>
  local present="${1:-}" k framed
  framed=$'\n'"$present"$'\n'
  for k in "${_TASKS_SELFHEAL_PREFS[@]}"; do
    [[ "$framed" == *$'\n'"$k"$'\n'* ]] || return 1
  done
  return 0
}

# DIVE-2808: the epoch is a receipt that the curated migration GENERATION named by
# $_TASKS_SCHEMA_EPOCH has run to completion on this store. It is deliberately NOT
# a claim that the store matches the canonical schema item for item.
#
# The first cut asserted exactly that — every canonical table, index and non-tasks
# column after migrating — and `fail`ed tasks_db_init when it did not hold, which
# is every `5dive task` invocation rather than merely a slow one. It cannot hold:
# the migration is a curated set of one-shot blocks that was never a convergence
# engine, and `CREATE TABLE IF NOT EXISTS` cannot widen a table that already
# exists, so neither the migration nor a replay of the canonical DDL can add a
# missing column to an existing table or an index over a column that is absent.
# Asserting a property no code path can repair converts a slow migration into an
# outage; four unrelated harnesses (ledger, policy_refusals, rollback_rate,
# whoami_for_chain) went red on precisely that, on a store shaped like a legacy box.
#
# What still covers the axis the first cut was reaching for:
#   - The EPOCH itself, which is what Case 13 of tests/tasks_db_restore_guard_unit.sh
#     exercises: a stale/absent epoch sends a tasks-current store back through the
#     whole migration, so a hole OUTSIDE tasks (gate_history.floor_provenance) is
#     still repaired. That win belongs to the epoch, not to the manifest assertion.
#   - tests/schema_sync_unit.sh, which fails CI if the migration's copies of those
#     CREATE TABLE statements drift from the canonical ones — so a table built by
#     EITHER path carries the same columns.
#   - DIVE-2197's resulting-column assertion, retained on BOTH arms below.
# A store that is genuinely short of a canonical table or column is not made worse
# by the gate: the pre-DIVE-2808 code re-ran the migration on every invocation and
# never created those either. Converging one needs per-table ALTERs — its own row.
_tasks_db_stamp_schema_epoch() {
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "INSERT INTO task_prefs(key,value,updated_at)
       VALUES ('schema_epoch',$(sqlq "$_TASKS_SCHEMA_EPOCH"),datetime('now'))
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');" \
    >/dev/null 2>&1 || fail "$E_GENERIC" "failed to stamp tasks-db schema epoch (DIVE-2808)"
}

# DIVE-2197's resulting-set assertion. It is called after a real migration and
# on the skip path, so an ALTER failure and a lying gate are both loud.
_tasks_db_assert_required_columns() {
  local final_cols c name
  local -a missing_columns=()
  if (($#)); then
    final_cols="$1"
  else
    final_cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
                 "SELECT name FROM pragma_table_info('tasks');" 2>/dev/null)
  fi
  local framed=$'\n'"$final_cols"$'\n'
  for c in "${_TASKS_ADDITIVE_COLUMNS[@]}"; do
    name="${c%% *}"
    [[ "$framed" == *$'\n'"$name"$'\n'* ]] || missing_columns+=("$name")
  done
  ((${#missing_columns[@]} == 0)) || fail "$E_GENERIC" \
    "tasks db schema incomplete after migration — missing columns: ${missing_columns[*]} (DIVE-2197)"
}

# Idempotent additive migrations for stores that fail the gate above.
_tasks_db_migrate() {
  local cols c name framed
  cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
         "SELECT name FROM pragma_table_info('tasks');" 2>/dev/null)
  # DIVE-2808: the list moved to $_TASKS_ADDITIVE_COLUMNS so the skip-gate and this
  # loop cannot drift, and the DIVE-2418 `grep -qx` herestring became pure-Bash
  # membership — same prefix-rejecting semantics (need_ty vs need_type), and with no
  # subprocess at all the SIGPIPE class that comment describes cannot exist here.
  framed=$'\n'"$cols"$'\n'
  for c in "${_TASKS_ADDITIVE_COLUMNS[@]}"; do
    name="${c%% *}"
    if [[ "$framed" != *$'\n'"$name"$'\n'* ]]; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE tasks ADD COLUMN ${c};" >/dev/null 2>&1 || true
    fi
  done
  _tasks_db_assert_required_columns

  # DIVE-3251 — BACKFILL first_started_at. Runs AFTER the column loop above, on
  # purpose: the sweep and the fix read the same ledger by the same predicate, so
  # splitting them would run the sweep against a schema the fix is about to
  # change. The sweep runs LAST.
  #
  # THE VALUE COMES FROM THE LEDGER, NEVER FROM now(). A `task start` re-run (or
  # any datetime('now') here) would stamp today and mis-state the age a second
  # time, in the same direction, while LOOKING repaired. MIN(ts) over this task's
  # `task.started` events is the earliest recorded true start; started_at is used
  # only where no ledger row exists. A row with neither is LEFT UNREPAIRED — an
  # unrepaired NULL you can see beats a fabricated timestamp you cannot.
  #
  # STATUS IS NOT TOUCHED. `first_started_at` answers "did real work happen";
  # `status` answers "is a seat on it now". The reclaim collapsed those two into
  # one field and THAT IS THE DEFECT — repeating it here would assert a seat is
  # working a row it may have genuinely dropped. It is also load-bearing for
  # safety: the ladder's age query is filtered `status='in_progress'`, so an old
  # timestamp on a `todo` row feeds nothing. Note this is ALSO why the backfill
  # target is first_started_at and NOT started_at: `task start` COALESCEs
  # started_at, so a backfilled old started_at would survive the next claim and
  # the row would arrive at rule (c) instantly ancient — the repair would trigger
  # the bug it repairs, on the exact rows it just repaired.
  #
  # Gated on a cheap EXISTS so it takes no write lock on the common path, and
  # idempotent by construction (it only ever fills a NULL).
  local _fsa_todo
  _fsa_todo=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM tasks t
      WHERE t.first_started_at IS NULL
        AND (COALESCE(t.started_at,'') <> ''
             OR EXISTS (SELECT 1 FROM lifecycle_events e
                         WHERE e.task_id=t.id AND e.kind='task.started'))
      LIMIT 1;" 2>/dev/null) || _fsa_todo=""
  if [[ "$_fsa_todo" == "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
      "UPDATE tasks SET first_started_at = COALESCE(
           (SELECT MIN(e.ts) FROM lifecycle_events e
             WHERE e.task_id=tasks.id AND e.kind='task.started'),
           NULLIF(started_at,''))
        WHERE first_started_at IS NULL
          AND (COALESCE(started_at,'') <> ''
               OR EXISTS (SELECT 1 FROM lifecycle_events e
                           WHERE e.task_id=tasks.id AND e.kind='task.started'));" \
      >/dev/null 2>&1 || true
  fi

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

  # DIVE-1923: the ship ledger, for stores that predate it. Guarded on
  # ship_events ITSELF, never on a neighbouring table — DIVE-1922 shipped its
  # migration nested under a `policy_refusals`-absent check, so on every box that
  # already had that table the block never ran and the metric read NO DATA
  # forever, indistinguishable from "nothing has been reverted yet". Every box
  # alive today HAS policy_refusals, so nesting this one there would reproduce
  # that bug exactly. Guard on the table you are creating.
  local has_ship_events
  has_ship_events=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ship_events' LIMIT 1;" 2>/dev/null)
  if [[ "$has_ship_events" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'SHIPMIG' >/dev/null 2>&1 || true
-- DIVE-1923: the ship ledger — the capture path behind `proof scorecard`'s
-- "autonomous rollback rate". Nothing recorded an agent UNDOING work it had
-- already shipped: `task reject` is a VERIFIER bounce on the maker->verifier
-- rail, which happens BEFORE a ship and is a different event, so the metric had
-- no source at all and a rendered 0.0% would have read as "we never roll back".
--   Numerator and denominator come from the SAME instrument. A rate whose two
-- halves are sourced differently cannot report its own coverage; both kinds of
-- row here are written by the one site that observes a ship, `5dive push`. The
-- rollback half needs no new discipline from anyone because git itself writes
-- "This reverts commit <sha>" into a revert's message.
--   kind    ship|rollback (a revert is BOTH: it is a commit that was shipped)
--   reverts for kind='rollback', the sha the commit undoes
--   self    1 ONLY when that sha is itself a recorded ship — i.e. we can PROVE
--           the fleet undid its own shipped work. Every commit here is authored
--           `lodar` by policy, so authorship can never establish that. An
--           unprovable revert is stored with self=0 and surfaced as coverage,
--           never silently promoted into the numerator.
-- Append-only, never updated or deleted, never referenced by tasks/projects so
-- it cannot touch the queue. The UNIQUE index is what makes re-pushing the same
-- branch idempotent rather than a way to inflate the denominator.
CREATE TABLE IF NOT EXISTS ship_events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      TEXT NOT NULL DEFAULT (datetime('now')),
  kind    TEXT NOT NULL,
  actor   TEXT,
  ident   TEXT,
  repo    TEXT,
  branch  TEXT,
  sha     TEXT NOT NULL,
  reverts TEXT,
  self    INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS ship_events_kind_sha_idx ON ship_events(kind, sha);
CREATE INDEX IF NOT EXISTS ship_events_ts_idx ON ship_events(ts, kind);
SHIPMIG
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

  # DIVE-1349 goal_jobs table — additive, gated on absence like loop_runs above so
  # it takes no write lock on every command. Brand-new table, never referenced by
  # tasks/projects, so creating it cannot touch the existing queue.
  local has_goal_jobs
  has_goal_jobs=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='goal_jobs' LIMIT 1;" 2>/dev/null)
  if [[ "$has_goal_jobs" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS goal_jobs (
  job_id      TEXT PRIMARY KEY,
  loop_id     TEXT NOT NULL,
  task_id     INTEGER NOT NULL,
  outcome     TEXT NOT NULL,
  project     TEXT,
  planner     TEXT NOT NULL,
  max_tasks   INTEGER NOT NULL,
  depth_cap   INTEGER NOT NULL,
  checkpoint  INTEGER NOT NULL,
  ceiling     INTEGER NOT NULL,
  dry_run     INTEGER NOT NULL DEFAULT 0,
  yes         INTEGER NOT NULL DEFAULT 0,
  from_actor  TEXT,
  status      TEXT NOT NULL DEFAULT 'running',
  result_json TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS goal_jobs_status_idx ON goal_jobs(status);
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

  # DIVE-1922: policy_refusals needs its OWN guard. Nesting it under the
  # supervisor_events check meant it only ran on stores that LACKED
  # supervisor_events — so on every existing box the table was never created and
  # `proof scorecard` would have read NO DATA forever: a silent no-op that looks
  # exactly like "no refusals recorded yet". Guard on the table you are creating.
  local has_policy_refusals
  has_policy_refusals=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='policy_refusals' LIMIT 1;" 2>/dev/null)
  if [[ "$has_policy_refusals" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
-- DIVE-1922: policy refusals — the capture path behind `proof scorecard`'s
-- "policy-blocked action attempts". Until this existed the metric had NO
-- source: we recorded gates that were ASKED and ANSWERED, never attempts a
-- policy REFUSED before they got that far, so a rendered 0.0% would have read
-- as "we never get blocked". Written ONLY by policy_refuse(); append-only,
-- never updated or deleted, and never referenced by tasks/projects so it
-- cannot touch the queue. `policy` is a stable slug (not the message text, so
-- rewording a refusal never breaks the series); `ticket` is the rule's origin.
CREATE TABLE IF NOT EXISTS policy_refusals (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  ts       TEXT NOT NULL DEFAULT (datetime('now')),
  policy   TEXT NOT NULL,
  ticket   TEXT,
  actor    TEXT,
  ident    TEXT,
  detail   TEXT
);
CREATE INDEX IF NOT EXISTS policy_refusals_ts_idx ON policy_refusals(ts, policy);
MIG
  fi

  # DIVE-2119 gate_history — additive, gated on absence so it takes no write lock
  # on every command. Brand-new append-only table, never referenced by
  # tasks/projects, so creating it cannot touch the existing queue. NOTE this
  # starts EMPTY on an existing store and no backfill is possible: for every row
  # already carrying orphaned answer provenance the answer TEXT was overwritten
  # long ago, so the pre-fix era is known-blind by construction (same posture
  # DIVE-2090 took for its unaudited era). Keep this definition byte-identical to
  # the one in _tasks_schema above (tests/schema_sync_unit.sh).
  local has_gate_history
  has_gate_history=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='gate_history' LIMIT 1;" 2>/dev/null)
  if [[ "$has_gate_history" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS gate_history (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id           INTEGER NOT NULL,
  ident             TEXT,
  need_type         TEXT,
  ask               TEXT,
  need_options      TEXT,
  recommend         TEXT,
  tier              INTEGER,
  need_asked_at     TEXT,
  need_answer       TEXT,
  need_answered_at  TEXT,
  need_answered_by  TEXT,
  need_answered_uid INTEGER,
  need_answer_sig   TEXT,
  human_nonce_hash  TEXT,
  retired_by        TEXT NOT NULL,
  retired_at        TEXT NOT NULL DEFAULT (datetime('now')),
  floor_provenance  TEXT,
  -- DIVE-3171: carried for the same reason floor_provenance is. A retired gate that
  -- keeps its TIER's provenance and drops its ROUTE's is the half-record that makes a
  -- later count wrong in one direction only, and the count at stake here is "how often
  -- did the standing authority actually carry a gate".
  route_provenance  TEXT,
  gate_mode         TEXT
);
CREATE INDEX IF NOT EXISTS gate_history_task_idx ON gate_history(task_id, id);
MIG
  fi

  # DIVE-2615 — additive floor_provenance on an ALREADY-CREATED gate_history. The
  # block above only runs when the table is ABSENT, so on every store that already
  # has one (i.e. every box that has ever filed a gate) a new column in the CREATE
  # reaches nothing. Same one-shot pragma check the tasks columns use.
  #
  # This box is the reason the check is a pragma read and not a bare ALTER: it
  # already carries `floor_provenance TEXT`, added out-of-band by something that
  # left no trace in this repo — the column existed with no writer, no migration
  # and no reference in src/ or tests/, which is why it read NULL on all 79 rows.
  # DIVE-2354: additive gate_mode on an ALREADY-CREATED gate_history, for the same
  # reason floor_provenance needs one directly below -- the create-if-absent block
  # above reaches only stores that have never filed a gate.
  local has_gh_gatemode
  has_gh_gatemode=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM pragma_table_info('gate_history') WHERE name='gate_mode' LIMIT 1;" 2>/dev/null)
  if [[ "$has_gh_gatemode" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
      "ALTER TABLE gate_history ADD COLUMN gate_mode TEXT;" >/dev/null 2>&1 || true
  fi

  local has_gh_floorprov
  has_gh_floorprov=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM pragma_table_info('gate_history') WHERE name='floor_provenance' LIMIT 1;" 2>/dev/null)
  if [[ "$has_gh_floorprov" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
      "ALTER TABLE gate_history ADD COLUMN floor_provenance TEXT;" >/dev/null 2>&1 || true
  fi

  # DIVE-3171: additive route_provenance on an ALREADY-CREATED gate_history, for the
  # same reason its two siblings above need one — the create-if-absent block reaches
  # only stores that have never filed a gate, which is no box that has ever run.
  local has_gh_routeprov
  has_gh_routeprov=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM pragma_table_info('gate_history') WHERE name='route_provenance' LIMIT 1;" 2>/dev/null)
  if [[ "$has_gh_routeprov" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
      "ALTER TABLE gate_history ADD COLUMN route_provenance TEXT;" >/dev/null 2>&1 || true
  fi

  # DIVE-748 — additive scorecard column on already-created loop_runs tables.
  # The create-if-absent block above only covers fresh stores; existing loop_runs
  # (e.g. prod) need the column added. Pure expand: NULL backfill, old rows/queries
  # untouched. Gated on pragma so it's a no-op once present.
  if [[ "$has_loop_runs" == "1" ]]; then
    local lr_cols
    lr_cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
              "SELECT name FROM pragma_table_info('loop_runs');" 2>/dev/null)
    if ! grep -qx "scorecard_json" <<<"$lr_cols"; then
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

  # DIVE-2133: do not let an empty archive assert that the pre-DIVE-2119 era
  # was quiet. Stamp the earliest PROVEN coverage boundary once. If this store
  # already archived rows, the first retirement proves the writer was live by
  # then; otherwise only this migration time is knowable. The read guard avoids
  # taking a write lock on every command after the one-time stamp.
  local gate_history_coverage
  gate_history_coverage=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT value FROM task_prefs WHERE key='gate_history_coverage';" 2>/dev/null)
  if [[ -z "$gate_history_coverage" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
      "INSERT OR IGNORE INTO task_prefs(key,value)
         SELECT 'gate_history_coverage',
                'inferred:'||COALESCE((SELECT MIN(retired_at) FROM gate_history), datetime('now'));" \
      >/dev/null 2>&1 || true
  fi

  # OSS-19 (OSS-26) objectives + objective_readings — additive, gated on the
  # objectives table's absence so it takes no write lock on every command. Both
  # brand-new, never referenced by tasks/projects, so creating them cannot touch
  # the existing queue. Keep these two CREATE TABLE bodies byte-identical to the
  # copies in _tasks_schema above (tests/schema_sync_unit.sh).
  local has_objectives
  has_objectives=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='objectives' LIMIT 1;" 2>/dev/null)
  if [[ "$has_objectives" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS objectives (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT NOT NULL UNIQUE,
  metric_cmd        TEXT NOT NULL,
  target            REAL,
  direction         TEXT NOT NULL DEFAULT 'up',
  unit              TEXT,
  review            TEXT,
  planner           TEXT,
  project_key       TEXT,
  max_new_per_cycle INTEGER NOT NULL DEFAULT 3,
  budget            INTEGER,
  public            INTEGER NOT NULL DEFAULT 0,
  status            TEXT NOT NULL DEFAULT 'active',
  -- OSS-27 shadow-first run mode (OSS-35): 'live' (default) applies a re-plan
  -- cycle's non-origination changes within the objective's own-task autonomy,
  -- 'shadow' forces PROPOSE-ONLY -- the entire diff rides ONE gate a human
  -- confirms, nothing auto-applies, and --yes cannot waive it. Fail-safe lever
  -- so a dogfood run (OSS-35) never touches the live company until approved.
  run_mode          TEXT NOT NULL DEFAULT 'live',
  created_by        TEXT,
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS objective_readings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  objective_id INTEGER NOT NULL REFERENCES objectives(id) ON DELETE CASCADE,
  ts           TEXT NOT NULL DEFAULT (datetime('now')),
  value        REAL,
  rc           INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS objective_readings_idx ON objective_readings(objective_id, id);
MIG
  fi

  # OSS-27 objective_cycles — additive, gated on its OWN absence (not objectives',
  # so a store that already has objectives from OSS-26 still gets the cycles table).
  # Brand-new, never referenced by tasks/projects. Keep this CREATE body
  # byte-identical to the copy in _tasks_schema above (tests/schema_sync_unit.sh).
  local has_obj_cycles
  has_obj_cycles=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='objective_cycles' LIMIT 1;" 2>/dev/null)
  if [[ "$has_obj_cycles" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS objective_cycles (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  objective_id  INTEGER NOT NULL REFERENCES objectives(id) ON DELETE CASCADE,
  cycle_no      INTEGER NOT NULL,
  ts            TEXT NOT NULL DEFAULT (datetime('now')),
  reading_value REAL,
  proposed      INTEGER NOT NULL DEFAULT 0,
  applied       INTEGER NOT NULL DEFAULT 0,
  reprioritized INTEGER NOT NULL DEFAULT 0,
  cancelled     INTEGER NOT NULL DEFAULT 0,
  gated         INTEGER NOT NULL DEFAULT 0,
  gate_anchor   TEXT,
  tokens_spent  INTEGER NOT NULL DEFAULT 0,
  planner_loop_id TEXT,
  planner_task_id INTEGER,
  outcome       TEXT NOT NULL DEFAULT 'noop'
);
CREATE INDEX IF NOT EXISTS objective_cycles_idx ON objective_cycles(objective_id, cycle_no);
MIG
  fi

  # INST-4 lifecycle_events — additive, gated on its OWN absence. Brand-new,
  # never referenced by tasks/projects. Keep this CREATE body byte-identical to
  # the copy in _tasks_schema above (tests/schema_sync_unit.sh).
  local has_lifecycle
  has_lifecycle=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='lifecycle_events' LIMIT 1;" 2>/dev/null)
  if [[ "$has_lifecycle" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS lifecycle_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  ts              TEXT NOT NULL DEFAULT (datetime('now')),
  kind            TEXT NOT NULL,
  ident           TEXT,
  task_id         INTEGER,
  actor           TEXT NOT NULL,
  authority       TEXT NOT NULL DEFAULT 'self',
  parent_ident    TEXT,
  idem_key        TEXT NOT NULL,
  input_hash      TEXT,
  output_hash     TEXT,
  policy_decision TEXT,
  tokens          INTEGER,
  host            TEXT,
  detail          TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_events_idem_idx ON lifecycle_events(idem_key);
CREATE INDEX IF NOT EXISTS lifecycle_events_ident_idx ON lifecycle_events(ident, id);
CREATE INDEX IF NOT EXISTS lifecycle_events_ts_idx ON lifecycle_events(ts, kind);
MIG
  fi

  # INST-4: stamp the ledger's own start. `trace` needs to distinguish "this task
  # produced no lifecycle events" from "this task ran before the ledger existed",
  # and only a marker written at install time can tell them apart — by the time a
  # reader asks, an empty result looks identical either way. Written once; the
  # INSERT OR IGNORE keeps every later init a no-op so the marker records the
  # FIRST init on this box, not the most recent one.
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "INSERT OR IGNORE INTO task_prefs (key, value) VALUES ('ledger_started', datetime('now'));" \
    >/dev/null 2>&1 || true

  # DIVE-1737 — async self-heal materialize: additive planner-handle columns on
  # already-created objective_cycles tables. When a planner loop times out past
  # OBJ_PLANNER_WAIT_DEFAULT, replan records an 'awaiting_planner' cycle stamped
  # with the backing loop + task id so the heartbeat reconciler can pull the late
  # diff and materialize it (instead of the diff being orphaned). Pure expand:
  # NULL backfill, gated on pragma so it's a no-op once present.
  if [[ "$has_obj_cycles" == "1" ]]; then
    local oc_cols
    oc_cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
              "SELECT name FROM pragma_table_info('objective_cycles');" 2>/dev/null)
    if ! grep -qx "planner_loop_id" <<<"$oc_cols"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE objective_cycles ADD COLUMN planner_loop_id TEXT;" >/dev/null 2>&1 || true
    fi
    if ! grep -qx "planner_task_id" <<<"$oc_cols"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE objective_cycles ADD COLUMN planner_task_id INTEGER;" >/dev/null 2>&1 || true
    fi
  fi

  # OSS-27 tasks.originated index for migrated stores (the columns backfill via the
  # ALTER loop above; harmless if they're all-NULL — the index just never matches).
  sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "CREATE INDEX IF NOT EXISTS idx_tasks_originated ON tasks(originated_by_objective);" >/dev/null 2>&1 || true

  # OSS-27 shadow-first: objectives.run_mode for stores whose objectives table
  # predates it (created by OSS-26). Pure expand, NOT-NULL DEFAULT 'live' so old
  # objectives keep applying own-task changes directly; a dogfood objective is
  # flipped to 'shadow' explicitly (5dive objective shadow <name>).
  if [[ "$has_objectives" == "1" ]]; then
    local obj_cols
    obj_cols=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
              "SELECT name FROM pragma_table_info('objectives');" 2>/dev/null)
    if ! grep -qx "run_mode" <<<"$obj_cols"; then
      sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
        "ALTER TABLE objectives ADD COLUMN run_mode TEXT NOT NULL DEFAULT 'live';" >/dev/null 2>&1 || true
    fi
  fi
  # DIVE-3342 humans + human_agents for existing stores. Guarded on the table it
  # creates (the DIVE-1922 lesson: nesting it under another table's absence check
  # means it never runs on any live box and the feature is a silent no-op that
  # looks exactly like "nobody has been added yet"). Two brand-new tables, never
  # referenced by tasks/projects, so creating them cannot touch the queue — and
  # they start EMPTY, which is deliberately load-bearing here: an empty registry
  # is the signal that gate delivery keeps its pre-DIVE-3342 behaviour, so this
  # migration changes NOTHING about how any existing box pages its human until
  # someone runs `5dive human add`. Keep both definitions byte-identical to the
  # copies in _tasks_schema above (tests/schema_sync_unit.sh).
  local has_humans
  has_humans=$(sqlite3 -cmd ".timeout 5000" "$TASKS_DB" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='humans' LIMIT 1;" 2>/dev/null)
  if [[ "$has_humans" != "1" ]]; then
    sqlite3 -cmd ".timeout 5000" "$TASKS_DB" <<'MIG' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS humans (
  id           TEXT PRIMARY KEY,
  display_name TEXT,
  telegram_id  TEXT,
  buzz_npub    TEXT,
  discord_id   TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS human_agents (
  human_id TEXT NOT NULL REFERENCES humans(id) ON DELETE CASCADE,
  agent    TEXT NOT NULL,
  PRIMARY KEY (human_id, agent)
);
CREATE INDEX IF NOT EXISTS human_agents_agent_idx ON human_agents(agent);
MIG
  fi
  _tasks_db_stamp_schema_epoch
}

# Per-connection setup, passed via -cmd / .timeout so it produces NO output
# rows (an inline `PRAGMA busy_timeout=N;` echoes the value, which would
# corrupt anything that captures a query result). .timeout makes concurrent
# agent writers retry instead of erroring with "database is locked";
# foreign_keys=ON enables the ON DELETE cascades.
db() {
  umask 0002
  _tasks_store_fence "$1"   # DIVE-2249
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
  _tasks_store_fence "${2:-}"   # DIVE-2249 — named a read, but nothing stops a write being handed to it
  # DIVE-1610: on the -json path, drop null-valued keys before the JSON reaches
  # agent context. sqlite3 -json emits every selected column including the ~70%
  # that are null on a typical task row (41/58 on `task show --json`), and that
  # bloat multiplies across every heartbeat/objective/task tick fleet-wide.
  # Omitting a null key is a no-op for jq/JS consumers (a missing key reads back
  # as null), so keys stay stable — this is lean, not a rename. jq is already a
  # hard dependency of the CLI (see the --json error envelope in output.sh).
  # Only the -json mode is post-processed; -box/-line are untouched.
  if [[ "$1" == "-json" ]]; then
    local out
    out=$(sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON" -json "$TASKS_DB" "$2")
    # Empty result set: sqlite3 -json prints nothing. Preserve that (callers
    # guard on empty), don't emit "[]" where they expect "".
    [[ -z "$out" ]] && return 0
    printf '%s' "$out" | jq -c 'if type=="array" then map(with_entries(select(.value != null))) else . end'
    return 0
  fi
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

# Resolve a task ref for a PARENT EDGE, refusing a bare number whose row carries
# a different ident number. DIVE-3275. Lives beside resolve_task_id() because it
# is a statement about that function's two number spaces, not about any one verb.
#
# resolve_task_id() branches on argument SHAPE: `^[0-9]+$` is the global row id,
# `^[A-Za-z]+-[0-9]+$` is the ident. THE TWO SPACES HAVE DIVERGED — measured on
# the live store 2026-08-12: DIVE-2895 is row id 3082, and row id 2895 is
# DIVE-2708, a cancelled row from another month. So a bare number is a VALID id
# naming the WRONG row, with no error: that is how DIVE-3273 was filed under
# DIVE-2708, and `task add`'s own `--parent=<id>` help text is what made the bare
# form look intended.
#
# Why this guard is stricter than the rest of the CLI's ref handling, rather than
# resolve_task_id() itself being tightened: a wrong ref elsewhere shows you the
# wrong row and you notice. A wrong PARENT is invisible (the edge renders on a
# row nobody is looking at) and `parent_id INTEGER REFERENCES tasks(id) ON DELETE
# CASCADE` silently arms the child's deletion with it. Tightening every caller of
# resolve_task_id() would be a much larger behaviour change for cases that are
# self-revealing.
#
# <role> names the argument in the refusal ("the parent", "the task to re-parent")
# so a two-argument verb says WHICH one was wrong.
_task_resolve_ref_strict() {
  local ref="$1" role="$2"
  resolve_task_id "$ref"
  [[ "$ref" =~ ^[0-9]+$ ]] || return 0   # the ident form is the quiet path
  local title; title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${RESOLVED_TASK_ID};")
  local ident_number="${RESOLVED_TASK_IDENT##*-}"
  if [[ "$ident_number" != "$ref" ]]; then
    fail "$E_VALIDATION" "'$ref' as $role is the global row id, which resolves to ${RESOLVED_TASK_IDENT} (\"${title}\") — not to an ident numbered $ref. The two number spaces diverged; name the row you mean by IDENT: ${RESOLVED_TASK_IDENT} (or DIVE-${ref}, if that is what you meant)."
  fi
  # It agrees TODAY. That is a coincidence of this row's history, not a property
  # of the argument form, so it still warns — and the ident form warns about
  # nothing, which is what keeps this warning worth reading.
  warn "$role was given as the bare number $ref, which resolved to ${RESOLVED_TASK_IDENT} (\"${title}\"). Prefer the ident form — a bare number is a global row id, not an ident."
  return 0
}

# Resolve a known numeric row id to its display ident (DIVE-484). Used by call
# sites that already hold the numeric id (params, subqueries) and must render a
# user-facing label without assuming the DIVE-<id> shortcut.
ident_of() {
  db "SELECT ident FROM tasks WHERE id=${1};"
}

# Who is acting. DERIVED from the uid (src/lib/actor.sh); `--from` is a CLAIM.
#
# DIVE-2518 changed the PRECEDENCE, not the vocabulary. This function used to read
# `--from` first — a caller-supplied argv string, taken as gospel — then
# `$SUDO_USER`, an ordinary environment variable that nothing verifies sudo ever
# set. With 43 references it is what stamps `created_by` on every row, `assignee`
# under `--mine`, `actor=` on the ledger emits and the actor of all six loop rails,
# so one uid could act as any agent across the entire board with no privilege at
# all (proven at runtime, wiki: six-actor-derivations-strictest-has-smallest-blast-radius).
#
# The answer now comes from `$EUID` -> /etc/passwd -> the registry. The RETURN
# SHAPE is unchanged, including the `cli` sentinel for "could not attribute this
# invocation" that :2177, :2392 and :3030 already branch on — which is why all 43
# sites inherit the derivation without individually changing.
#
# The claim is NOT discarded. It is graded (`actor_claim`) and recorded where it
# disagrees, and no decision anywhere reads it (see the note at the end of
# lib/actor.sh for why that replaced an outright refusal).
# But this accessor runs inside `$( )` at nearly every call site, so the status it
# sets dies with the subshell — a caller that needs the grade must use
# `task_actor_claim` below, in its OWN shell.
task_actor() {
  actor_claim "${1:-}" || true
  # A SUPPLIED CLAIM IS STILL WHAT GETS STAMPED, and that is a correction to this
  # ticket's first cut, forced by measurement rather than preference.
  #
  # The first cut returned the derivation unconditionally, so `--from` stamped
  # nothing. That breaks relay for every principal WITHOUT A UID: `council` files
  # board rows as `--from=council` and `cmd_task_clear_recs` answers as
  # `--from=telegram`, and no /etc/passwd walk can ever produce either name. The
  # derived value is not a better answer there — it is the wrong entity, and it
  # silently reattributes the row to whoever happened to run the process.
  #
  # WHAT ACTUALLY CLOSED IS THE ENV PATH, which is the hole that was measured:
  # `SUDO_USER=agent-olivia 5dive task ls --mine` acted as another agent with no
  # privilege and left NO trace, because $SUDO_USER is an ordinary variable nothing
  # verifies. `--from` is argv: deliberate, visible in the audit log, and the only
  # way a uid-less principal can be named at all. Those are different threats and
  # they do not get the same answer.
  #
  # So: no claim -> the DERIVATION (never $USER, never $SUDO_USER). A claim -> the
  # claim, PROVENANCE, now always accompanied by the measured actor (`derived_actor`)
  # so the row records who really ran it and a forged claim is falsifiable after the
  # fact. Sites that DECIDE rather than record call `task_actor ""` explicitly.
  [[ -n "${1:-}" ]] && { printf '%s' "$1"; return; }
  printf '%s' "$ACTOR_BOARD"
}

# task_actor_claim [claim] — same derivation, run in the CALLER'S shell.
#
# CALL IT BARE. It deliberately prints NOTHING and returns its answer in
# ACTOR_BOARD, because a function that printed would invite `$(task_actor_claim …)`
# — and the command substitution is precisely what this exists to avoid. The
# subshell would set ACTOR_CLAIM_STATUS in a shell that then exits, so the caller's
# `actor_claim_note` would read a stale value and record nothing.
#
# That is not hypothetical: the first cut of the DIVE-2518 create path called this
# inside `$( )` and shipped a `claimed_by` column that was NULL for every divergent
# claim. Both assertions a reader would naturally make still passed — `created_by`
# was the derived actor and the row existed — because the half that was missing was
# the half nothing asserted. Graded now by T19b.
#
#   actor_claim "$from"                 -> sets ACTOR_BOARD/ACTOR_CLAIM_STATUS
#   creator="$ACTOR_BOARD"              -> the derived actor
#   claimed_by=$(actor_claim_note)      -> safe: a subshell may READ these
task_actor_claim() {
  actor_claim "${1:-}" || true
}

valid_task_status()   { [[ "$1" =~ ^(todo|in_progress|blocked|done|cancelled)$ ]]; }
valid_task_priority() { [[ "$1" =~ ^(low|medium|high|urgent)$ ]]; }
# DIVE-1243: `access` is the manager-clearable class — "I'm blocked on a grant a
# teammate/manager can give (access/resource/config), NOT a human-only call". It
# routes manager-FIRST regardless of tier and is lead-clearable (reusing the
# DIVE-1182 routed_reviewer path); it falls through to a human only when the T2
# category floor fires (genuine human-territory: money/destructive/secrets/brand).
valid_need_type()     { [[ "$1" =~ ^(decision|secret|approval|manual|access)$ ]]; }

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
  local -a parts=(); IFS=',' read -ra parts <<<"$field"
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
  local -a cm=(); read -r -a cm <<<"$expr"
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
# DIVE-1950: resolved LAZILY, not bound at source time. Every isolated unit
# harness sources this file (and STATE_DIR's process-default) FIRST and
# re-points STATE_DIR AFTER, so a plain assignment here would freeze at the
# load-time STATE_DIR forever — reading/writing the LIVE host's key and
# enforce sentinel from inside what the harness believes is an isolated test.
# These getters resolve at CALL time instead; an explicit GATE_PROOF_KEY /
# GATE_PROOF_ENFORCE env override (the harnesses that already set one
# directly) still wins, since `:-` only supplies the default when unset.
_gate_proof_key_file()     { printf '%s\n' "${GATE_PROOF_KEY:-${STATE_DIR}/gate-proof.key}"; }
_gate_proof_enforce_file() { printf '%s\n' "${GATE_PROOF_ENFORCE:-${STATE_DIR}/gate-proof.enforce}"; }
GATE_PROOF_TTL=120

# Provision the 0400 root:root key on first use (root only). Group-claude must NOT
# read it (unlike the group-readable task db) or the bar-raise is moot.
_gate_proof_ensure_key() {
  local keyfile; keyfile=$(_gate_proof_key_file)
  [[ -s "$keyfile" ]] && return 0
  [[ $EUID -eq 0 ]] || return 1
  ( umask 077; openssl rand -hex 32 > "$keyfile" ) 2>/dev/null || return 1
  chown root:root "$keyfile" 2>/dev/null || true
  chmod 0400 "$keyfile" 2>/dev/null || true
  [[ -s "$keyfile" ]]
}

# HMAC-SHA256(key, payload) -> base64url (unpadded). hexkey avoids binary-in-argv.
_gate_proof_hmac() {
  local payload="$1" key
  key=$(cat "$(_gate_proof_key_file)" 2>/dev/null) || return 1
  [[ -n "$key" ]] || return 1
  printf '%s' "$payload" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" -binary 2>/dev/null \
    | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='
}

# DIVE-2119 — the ONE way to retire a gate. Emits SQL that (1) appends the
# outgoing gate to gate_history and (2) nulls ALL SIX provenance columns.
#
# Why one helper and not six columns inlined at each site: before this, four
# separate UPDATEs retired a gate by nulling only the two columns that carry the
# MEANING (need_answer, need_answered_at) and left the three that carry the
# ATTRIBUTION (need_answered_by, need_answered_uid, need_answer_sig) plus the
# human tap nonce standing. That partial reset produces a row that reads as
# unanswered to every guard and as human-attested to every reader that skips the
# guard — 21 live rows did exactly that (DIVE-2094). Nulling the three without
# archiving first would have been worse still: with no gate history anywhere,
# the leaked attribution WAS the only surviving trace of the previous gate. So
# archive and clear are one indivisible operation, and they live here so a fifth
# retirement path cannot re-open the hole by forgetting half of it.
#
# human_nonce_hash is in the reset set for a second reason: _human_nonce_verify
# checks a presented nonce against whatever hash the row currently holds, so a
# nonce minted for a SUPERSEDED tier-2 gate would otherwise still verify against
# the gate that replaced it — an old Telegram tap button clearing a new gate.
# The mint at cmd_task_need runs AFTER the filing UPDATE, so clearing here never
# eats the incoming gate's own nonce.
#
# Usage: db "BEGIN IMMEDIATE; $(_gate_archive_and_clear_sql <verb> "<pred>") <your UPDATE>; COMMIT;"
# Emit this BEFORE the caller's own UPDATE — the archive reads need_type/ask/tier
# off the row, which a re-file is about to overwrite. <pred> is a WHERE fragment
# on tasks and may match many rows (the loop-ceiling park archives a whole set).
_gate_archive_and_clear_sql() {
  local verb="$1" pred="$2"
  # printf, not a heredoc: an UNQUOTED heredoc carrying $( is the shape
  # tests/heredoc_substitution_unit.sh forbids by pattern (DIVE-2005), and
  # allowlisting a site blunts that scanner. The interpolation here is
  # deliberate, so make it explicit instead of exempt.
  printf '%s\n' \
    "INSERT INTO gate_history (task_id, ident, need_type, ask, need_options, recommend," \
    "                          tier, need_asked_at, need_answer, need_answered_at," \
    "                          need_answered_by, need_answered_uid, need_answer_sig," \
    "                          human_nonce_hash, retired_by, floor_provenance," \
    "                          route_provenance, gate_mode)" \
    "  SELECT id, ident, need_type, ask, need_options, recommend," \
    "         tier, need_asked_at, need_answer, need_answered_at," \
    "         need_answered_by, need_answered_uid, need_answer_sig," \
    "         human_nonce_hash, $(sqlq "$verb"), floor_provenance," \
    "         route_provenance, gate_mode" \
    "    FROM tasks" \
    "   WHERE (${pred})" \
    "     AND (need_type IS NOT NULL OR need_answer IS NOT NULL" \
    "          OR need_answered_at IS NOT NULL OR need_answered_by IS NOT NULL" \
    "          OR need_answered_uid IS NOT NULL OR need_answer_sig IS NOT NULL" \
    "          OR (human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''));" \
    "UPDATE tasks" \
    "   SET need_answer=NULL, need_answered_at=NULL, need_answered_by=NULL," \
    "       need_answered_uid=NULL, need_answer_sig=NULL, human_nonce_hash=NULL" \
    " WHERE (${pred});"
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
#
# DIVE-2588 — THE OVERRIDE MAY ONLY MAKE THIS STRICTER, NEVER WEAKER. This used to
# read the ENV-OR-DEFAULT path, so an unprivileged agent turned the whole enforcement
# envelope off with one variable and no sudo:
#
#   GATE_PROOF_ENFORCE=/nonexistent/nope  5dive task answer <T2-decision> --value=A --human
#
# succeeded where the identical command without it was refused, and landed
# need_answered_by=human:<agent> — byte-identical to a real relayed human tap. A file-
# EXISTENCE test on a path the constrained party supplies is not a control: its OFF
# position was reachable by its own subject. Reversing the sense fixes that without
# taking the override away — an existing sentinel at EITHER path arms enforcement, so
# a harness can still turn it ON for an isolated store (which is all any of them do:
# every caller in tests/ sets it to "$STATE_DIR/gate-proof.enforce", the default it
# would have resolved anyway), and pointing it at an absent path now says nothing at
# all instead of saying "off".
#
# STATE_DIR is deliberately read directly here rather than through
# _gate_proof_enforce_file: that helper resolves the override, and the whole point of
# this branch is that the root-owned default is consulted whether or not one is set.
_gate_proof_enforced() {
  [[ -f "${STATE_DIR}/gate-proof.enforce" ]] && return 0
  [[ -n "${GATE_PROOF_ENFORCE:-}" && -f "$GATE_PROOF_ENFORCE" ]]
}

# ── DIVE-2235: the HUMAN CLASS, and class-over-tier ──────────────────────────
# The gate types that mint and verify a one-time human nonce. This list already
# existed three times over in cmd_task.sh (the mint site in cmd_task_need, and
# the two evidence blocks in cmd_task_answer); it is named here once so the
# THREE AUTO-ANSWER WRITERS can consult it too.
#
# THE RULE: TIER MUST NOT BE ABLE TO DOWNGRADE CLASS. Tier says how urgently a
# gate is pushed at a person. It must not decide WHETHER a person answers it.
# A gate of a human class is one a human has to answer, at any tier, so none of
#   1. `_hb_gate_ttl_sweep` — the 48h tier-1 TTL that applies `recommend`
#   2. `cmd_task_need`'s tier-0 apply-at-file-time
#   3. `cmd_task_need`'s OSS-21 precedent auto-clear
# may decide one. Before DIVE-2235 the TTL sweep excluded only 'secret', so a
# tier-1 APPROVAL auto-applied its own recommendation after 48 hours with no
# human anywhere near it — live on DIVE-2224, where lodar's own escalation-floor
# decision was scheduled to self-approve from the recommendation of the agent
# who filed it.
#
# 'decision' is deliberately NOT a human class here. It mints no nonce (same
# list), and the DIVE-861 TTL default exists for exactly that class — a decision
# with a recommendation, unanswered for two days, taking its recommendation is
# the designed behaviour, not a defect. Making human=1 unforgeable so that
# 'decision' can join this list is the v0.18 "proof of who" work; it is NOT this
# change, and adding decision here would silently kill the TTL sweep entirely.
_gate_human_class() { case "${1:-}" in approval|secret|manual|access) return 0 ;; *) return 1 ;; esac; }
# SQL form of the same list, for the sweep predicates. Keep in lockstep above.
_GATE_HUMAN_CLASS_SQL="('approval','secret','manual','access')"

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
# Echoes the RAW nonce on stdout (caller stores only its hash). rc 0 only when a
# well-formed nonce was actually produced.
#
# DIVE-2233 item 2 (found by Marcus on the pre-merge read): this used to be a bare
# `openssl rand -hex 16 2>/dev/null` — stderr suppressed, rc unchecked. A missing or
# broken openssl therefore returned EMPTY, the caller's `[[ -n $human_nonce ]] &&`
# skipped the UPDATE, and the gate filed with human_nonce_hash NULL and nothing
# anywhere saying so. That was harmless while nothing read the column; it stopped
# being harmless at the commit that made NULL mean "skip the tier-2 floor". An
# inherited silent-empty becomes a security property at the moment something starts
# reading it, and that is the commit that owes it a voice.
#
# Two changes: a FALLBACK so a single missing tool cannot disarm the floor, and an
# rc so the caller can refuse rather than guess. /dev/urandom is the kernel CSPRNG —
# the same source openssl seeds from — so the fallback is not a weaker nonce, and it
# is present on every box we run on. The result is validated either way: a truncated
# read that yields 12 hex chars must not pass as a nonce.
_human_nonce_mint() {
  local n=""
  n=$(openssl rand -hex 16 2>/dev/null) || n=""
  if [[ ! "$n" =~ ^[0-9a-f]{32}$ ]]; then
    n=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  [[ "$n" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s' "$n"
}

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

# Seam so unit tests can drive the EUID-branch below — $EUID is read-only in a
# running shell, so the forge/legit-path tests override this instead (mirrors the
# _gate_is_root seam introduced for the DIVE-1401 withdraw fix, 547a219).
_gate_is_root() { [[ $EUID -eq 0 ]]; }

# Resolve the REAL pre-sudo caller and report whether it is a NON-agent uid — the
# third human-evidence form (a claude/root interactive login, the dashboard/shelld
# exec that runs AS claude, or the DIVE-931 secret-drop). 0 = non-agent
# (human-trusted), 1 = agent (or unknown).
#
# DIVE-1413: $SUDO_UID is a PLAIN ENV VAR any non-root process sets freely — so a
# non-root agent could forge SUDO_UID=<claude uid> to mint 'human' evidence and
# clear an approval/secret/manual gate (same env-forge class the DIVE-1401
# withdraw path was hardened against). Fix: trust $SUDO_UID ONLY at EUID 0, where
# real `sudo` stamps it truthfully AND a non-root agent cannot reach root without
# genuinely sudo-ing. Off root, $SUDO_UID is ignored and we judge by the
# UNSPOOFABLE real uid — which is exactly what the two legit non-root paths carry
# (the shelld/dashboard exec runs AS claude, so `id -u` is already non-agent),
# while an agent's real `id -u` is agent-* and is rejected. The DIVE-931 drop is a
# root path (secret write is require_root, so its nested task-answer runs at
# EUID 0 carrying the human's SUDO_UID=claude) and still clears via the EUID-0
# branch. The residual root-sudo forge (an agent already elevated to root) is out
# of scope, shared with the rest of the gate system (see DIVE-1401).
_gate_sudo_uid_nonagent() {
  local uid
  if _gate_is_root; then
    uid="${SUDO_UID:-$(id -u 2>/dev/null || echo "")}"
  else
    uid="$(id -u 2>/dev/null || echo "")"
  fi
  [[ -n "$uid" ]] || return 1
  local uname; uname=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
  [[ -n "$uname" ]] || return 1        # unknown uid -> not trusted
  [[ "$uname" != agent-* ]]
}

# ── DIVE-2371: the STRUCTURAL half of the human-evidence test ────────────────
# The uid test above asks "is this name absent from a list I maintain", so every
# principal NOT enumerated is promoted to human: `claude` (an agent runtime, not
# a person — the pre-`agent-*` session present on every box), `hello`, `dmarc`,
# CI's `runner`, and any future service account. A human-evidence test whose
# DEFAULT is *human* has its fail direction backwards, and on the one account
# present everywhere it gave the wrong answer: a bare `--human` from any process
# running as claude cleared a tier-2 gate.
#
# WHY A CGROUP AND NOT A BETTER NAME LIST: /proc/self/cgroup is written by systemd
# at fork and an unprivileged process cannot rewrite its own. Crucially `sudo` does
# NOT move cgroups, so it survives the EUID-0 hop $SUDO_UID exists for — the same
# hop that makes that env var forgeable off-root (DIVE-1413).
#
# THE LIST IS ON THE ACCEPT SIDE, which is what makes it fail closed: a principal
# nobody enumerated is REFUSED, where the uid test admitted it. lodar answered
# "Ship it" 2026-08-05 07:40 knowing the consequence — a tier-2 gate can no longer
# be cleared from a shell on the box as user claude. Telegram taps are untouched:
# they clear through the nonce arm, not this one.
# Pick the SYSTEMD line out of a /proc/<pid>/cgroup stream and print its path.
# Split out from _gate_caller_cgroup so the line-SELECTION rule is gradable without
# an override for the path to read — the path stays hardcoded at the one call site
# below, because a readable-path knob on a fail-closed predicate is the same class
# of widening surface as an accept-list knob (D1).
#
# WHY NOT `head -1`. That read whichever line came first. On cgroup v2 the file IS
# the single unified `0::<path>` entry and it happens to be right; on a v1 or hybrid
# host the file is many `<hier>:<controllers>:<path>` lines in kernel order, so the
# first is an ARBITRARY controller whose path can differ from the systemd one. A real
# login session then read as an unrecognised cgroup and a HUMAN was locked out of
# their own tier-2 clear. That direction is fail-closed, which is the right default
# and is NOT a reason to keep a known-wrong reader on a human-auth path: the installed
# fleet is unobservable by design (no exec token, SSH stripped), so "our boxes are v2"
# is a statement about the boxes we can see, and a lockout there has no self-service
# path.
#
# NO PERMISSIVE FALLBACK. If neither line is present we return 1 and the caller
# refuses. "Take any line we did find" is exactly what would admit an unrecognised
# hierarchy's path into a fail-closed accept list.
_gate_cgroup_pick_line() {
  local line sysd="" uni=""
  while IFS= read -r line; do
    case "$line" in
      *:name=systemd:*) sysd="$line" ;;   # v1/hybrid: systemd's unit-tracking hierarchy
      0::*)             uni="$line"  ;;   # v2: the unified hierarchy
    esac
  done
  # v1/hybrid FIRST: where systemd tracks units in the name=systemd hierarchy the
  # unified line may be bare `/`. A pure-v2 host has no name=systemd line at all, so
  # this falls through to the unified one rather than needing to detect the version.
  line="${sysd:-$uni}"
  [[ -n "$line" ]] || return 1
  # Strip the two leading `<field>:` columns rather than taking everything after the
  # LAST colon — a unit path may legitimately contain one.
  printf '%s' "${line#*:*:}"
}

_gate_caller_cgroup() {
  # An unreadable /proc entry fails the redirect, so this returns nonzero and the
  # caller refuses — the "unresolved principal is not a verified one" rule.
  _gate_cgroup_pick_line </proc/self/cgroup 2>/dev/null
}

_gate_cgroup_human_capable() {
  local cg; cg=$(_gate_caller_cgroup) || return 1
  [[ -n "$cg" ]] || return 1

  # ACCEPT 1 — THE DASHBOARD. It is the only non-Telegram surface a customer
  # clears a gate from, and it has neither a nonce (the nonce is minted into
  # Telegram callback_data, never to a browser) nor a login session. shelld is a
  # plain system service, User=claude, no Slice=, so /system.slice/shelld.service.
  # MEASURED on a freshly provisioned box 2026-08-05, not derived from the unit
  # file: ControlGroup and the running process's own /proc/<pid>/cgroup agree, and
  # shelld spawns the CLI as a PLAIN sudo child, so the answerer inherits this.
  #
  # HARDCODED ON PURPOSE — no env override. My first draft read this list from
  # $FIVE_GATE_CGROUP_ACCEPT, a plain env var any non-root process sets freely: an
  # agent could name its OWN cgroup and pass. That is the exact env-forge class
  # DIVE-1413 hardened $SUDO_UID against, reintroduced into the predicate written
  # to close it. A widening knob on a fail-closed accept list IS the failure mode.
  [[ "$cg" == "/system.slice/shelld.service" ]] && return 0

  # ACCEPT 2 — A REAL LOGIN SESSION, structural rather than named: a person who
  # logs in and sudo's lands in /user.slice/user-<uid>.slice/session-<n>.scope.
  # No unit name to forget, and no system service can manufacture one.
  [[ "$cg" == /user.slice/*/session-*.scope ]] && return 0

  # Everything else refused: agent units, the primary claude runtime, an
  # unreadable cgroup, a non-systemd host. An unresolved principal is not a
  # verified one — the same rule the served/expected commit checks use.
  return 1
}

# The AUTHORIZATION predicate. Requires BOTH halves on purpose, so it can only
# tighten: nothing the uid test refused becomes permitted, and the structural test
# removes the principals it wrongly admitted. ATTRIBUTION does not use this —
# `_gate_withdraw_actor` keeps the uid test, because authorization must fail closed
# while attribution must stay TRUTHFUL, and degrading a real person's withdrawal to
# 'none' would make the record worse rather than safer.
_gate_human_principal() {
  _gate_sudo_uid_nonagent || return 1
  _gate_cgroup_human_capable
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
  [[ -s "$(_gate_proof_key_file)" ]] || return 1
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

# ── INST-4: the unified lifecycle ledger writer ──────────────────────────────
#
# ledger_emit <kind> [k=v ...] — append ONE row to lifecycle_events.
#
# Keys: ident, task_id, parent, actor, authority, idem, in, out, policy, tokens,
# detail. Everything is optional except <kind>.
#
#   in= / out=  take the RAW payload and are HASHED here, never stored. Call
#               sites therefore cannot leak a secret, a gate answer, or a task
#               body into a table that is read by lower-privileged consumers —
#               they physically have no way to write content into it. That is a
#               property of this function, not a rule call sites must remember.
#   idem=       the natural key. Omitted, it is derived deterministically from
#               kind+ident+task_id+payload digest, so a retried emit collapses
#               instead of double-counting. A caller whose event legitimately
#               repeats with an identical payload MUST pass its own key
#               (ship_ledger_record passes the sha; policy refusals pass a clock
#               nonce) — otherwise the second occurrence is silently dropped, and
#               a dropped row here is indistinguishable from an event that never
#               happened.
#
# NEVER fails the caller and never speaks to it. A lifecycle event that cannot be
# recorded must not turn a successful `task done` into a failed one; the ledger
# is evidence about the action, not part of it. This is the same posture as
# audit_log and ship_ledger_record.
ledger_hash() {
  # First 16 hex of sha256 — enough to compare payloads, short enough to render
  # in a terminal timeline. Empty input hashes to empty, so an absent payload
  # stays visibly absent rather than becoming the well-known sha256 of "".
  local raw="${1:-}"
  [[ -n "$raw" ]] || { printf ''; return 0; }
  printf '%s' "$raw" | sha256sum 2>/dev/null | cut -c1-16 || printf ''
}

ledger_emit() {
  local kind="${1:-}"; shift || true
  [[ -n "$kind" ]] || return 0
  local ident="" task_id="" parent="" actor="" authority="" idem=""
  local raw_in="" raw_out="" policy="" tokens="" detail="" claimed="" kv
  for kv in "$@"; do
    case "$kv" in
      ident=*)     ident="${kv#*=}" ;;
      task_id=*)   task_id="${kv#*=}" ;;
      parent=*)    parent="${kv#*=}" ;;
      actor=*)     actor="${kv#*=}" ;;
      authority=*) authority="${kv#*=}" ;;
      idem=*)      idem="${kv#*=}" ;;
      in=*)        raw_in="${kv#*=}" ;;
      out=*)       raw_out="${kv#*=}" ;;
      policy=*)    policy="${kv#*=}" ;;
      tokens=*)    tokens="${kv#*=}" ;;
      detail=*)    detail="${kv#*=}" ;;
      claimed_by=*) claimed="${kv#*=}" ;;
    esac
  done
  # DIVE-2518: the MEASURED actor rides in the DETAIL whenever it is known. `actor`
  # keeps its existing meaning (who the row is attributed to) and the reader gains
  # the one thing the ledger could never say before: who actually ran it. Emitted
  # for agreement as well as divergence — a ledger row that records only conflicts
  # cannot distinguish "they matched" from "nobody looked".
  # Folded into detail rather than a new column on purpose — lifecycle_events is
  # append-only history and an ALTER on it would leave every pre-existing row with a
  # NULL that reads as "no claim" when it actually means "not recorded yet".
  if [[ -n "$claimed" ]]; then detail="${detail:+$detail }derived_actor=${claimed}"; fi
  local in_hash out_hash
  in_hash=$(ledger_hash "$raw_in")
  out_hash=$(ledger_hash "$raw_out")
  # One resolver for identity, shared with the audit log (_actor_identity), so
  # the two trails can never disagree about who acted.
  [[ -n "$actor" ]]     || actor=$(_actor_identity)
  [[ -n "$authority" ]] || authority=$(_actor_authority)
  [[ -n "$idem" ]]      || idem="${kind}|${ident}|${task_id}|$(ledger_hash "${detail}${in_hash}${out_hash}")"
  local host="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
  [[ "$task_id" =~ ^[0-9]+$ ]] || task_id=""
  [[ "$tokens"  =~ ^[0-9]+$ ]] || tokens=""
  db "INSERT OR IGNORE INTO lifecycle_events
        (kind, ident, task_id, actor, authority, parent_ident, idem_key,
         input_hash, output_hash, policy_decision, tokens, host, detail)
      VALUES ($(sqlq "$kind"), $(sqlq_or_null "$ident"), ${task_id:-NULL},
              $(sqlq "$actor"), $(sqlq "$authority"), $(sqlq_or_null "$parent"),
              $(sqlq "$idem"), $(sqlq_or_null "$in_hash"), $(sqlq_or_null "$out_hash"),
              $(sqlq_or_null "$policy"), ${tokens:-NULL}, $(sqlq_or_null "$host"),
              $(sqlq_or_null "$detail"));" >/dev/null 2>&1 || true
  return 0
}

# ship_ledger_record <kind> <ident> <repo> <branch> <sha> [reverts] — DIVE-1923.
#
# Append one row to the ship ledger, the capture path behind `proof scorecard`'s
# "autonomous rollback rate". Before this, nothing in the fleet recorded an agent
# undoing its OWN shipped work: `task reject` is a verifier bounce that happens
# before a ship, so the metric had no source and had to render an explicit
# NO DATA marker rather than a 0.0% that would read as "we never roll back".
#
# `self` is computed HERE, from the ledger, and is deliberately conservative: it
# is 1 only when the reverted sha is already a recorded ship, which is the only
# evidence available that the fleet undid ITS OWN work. Commit authorship cannot
# supply it — every commit we push is authored `lodar` by policy, so author would
# mark a human's revert as ours. A revert we cannot attribute is stored with
# self=0 and reported as coverage beside the rate, never counted in it.
#
# Best-effort and never fatal: a ship that fails to record must still be a ship.
# The UNIQUE(kind, sha) index makes re-pushing a branch idempotent, so the
# denominator counts commits shipped rather than times `push` was run.
ship_ledger_record() {
  local kind="$1" ident="$2" repo="$3" branch="$4" sha="$5" reverts="${6:-}"
  local actor self=0
  actor="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
  if [[ "$kind" == "rollback" && -n "$reverts" ]]; then
    [[ "$(db "SELECT 1 FROM ship_events WHERE kind='ship' AND sha=$(sqlq "$reverts") LIMIT 1;" 2>/dev/null)" == "1" ]] && self=1
  fi
  db "INSERT OR IGNORE INTO ship_events (kind, actor, ident, repo, branch, sha, reverts, self)
      VALUES ($(sqlq "$kind"), $(sqlq "$actor"), $(sqlq "$ident"), $(sqlq "$repo"),
              $(sqlq "$branch"), $(sqlq "$sha"), $(sqlq "$reverts"), $self);" \
    >/dev/null 2>&1 || true
  # INST-4: mirror into the unified ledger. ship_events keeps its own shape (the
  # scorecard's rate is computed from it and stays sourced from ONE instrument);
  # this row is the same fact placed on the lifecycle timeline next to the gate
  # that authorized it and the verifier who graded it. idem is the sha, matching
  # the UNIQUE(kind,sha) contract above — re-pushing a branch stays one event.
  ledger_emit "$kind" ident="$ident" actor="$actor" idem="${kind}:${sha}" \
    out="$sha" detail="${repo:-?}@${branch:-?} ${sha}${reverts:+ reverts ${reverts}}"
}

# policy_refuse <exit-code> <policy-slug> <ticket> <ident> <message> — DIVE-1922.
#
# Record that a policy REFUSED an action, then refuse it. This is the capture
# path behind `proof scorecard`'s "policy-blocked action attempts", which had no
# source at all: we recorded gates that were ASKED and ANSWERED, never attempts
# stopped before they got that far. A metric with no source renders 0.0% and
# reads as "we never get blocked" — the succeeding-in-appearance class aimed at
# the honesty instrument, which is why the scorecard shipped a NO DATA marker
# rather than a zero.
#
# ONLY for genuine POLICY refusals — a rule stopping an actor from doing
# something it asked to do. NOT for usage/validation errors (bad flag, missing
# arg, malformed input): those are the caller getting the invocation wrong, not
# policy blocking an action, and counting them would inflate the number into
# meaninglessness. When in doubt, keep using `fail` directly; an UNDER-counted
# metric that reports its own coverage is honest, an inflated one is not.
#
# The EXIT CODE is a parameter, not a constant. Instrumenting a site must be
# behaviour-preserving: hardcoding one code silently changed three sites'
# contracts (E_USAGE->E_CONFLICT twice, E_AUTH_REQUIRED->E_CONFLICT once) when
# this was first written. Adding telemetry must never alter what a caller sees.
#
# <policy-slug> is a stable identifier, deliberately NOT the message text, so
# rewording a refusal never breaks the series. Recording is best-effort and can
# never prevent the refusal: if the write fails the action is still refused,
# because a policy that stops working when its telemetry breaks is a worse
# failure than a missing row.
# OSS-37: the ONE definition of a spent maker→verifier loop, as a SQL predicate over
# `tasks`. A loop is "stuck" once it has a cap, has reached it, and still isn't closed.
#
# It lives here, not in cmd_task.sh, because it has two callers in different command
# files — `loop board --stuck` / `--escalate-stuck` and the objective planner's injected
# context — and a predicate held as a local shell var in one of them can only be REUSED
# by re-typing it. Re-typing buys does-not-currently-drift; a shared definition is what
# buys cannot-drift, and the difference is invisible on the day you write it. This
# codebase already paid for that lesson once (DIVE-1963, `_gate_bind_slug` in
# cmd_push.sh: "they agreed, but that is parallel derivation").
#
# Callers must NOT re-type it or "simplify" it at the call site — the second copy that
# omits a clause because the local WHERE already covers it is exactly the copy that
# stops matching when this one changes. `tests/objective_replan_unit.sh` fails if either
# call site inlines the predicate instead of calling this.
_task_stuck_loop_pred() {
  printf '%s' "(verifier IS NOT NULL AND max_iterations IS NOT NULL
                AND COALESCE(iteration,0) >= max_iterations
                AND status NOT IN ('done','cancelled'))"
}

policy_refuse() {
  local code="$1" policy="$2" ticket="$3" ident="$4"; shift 4
  local msg="$*" actor
  actor="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
  db "INSERT INTO policy_refusals (policy, ticket, actor, ident, detail)
      VALUES ($(sqlq "$policy"), $(sqlq "$ticket"), $(sqlq "$actor"), $(sqlq "$ident"), $(sqlq "$msg"));" \
    >/dev/null 2>&1 || true
  # INST-4: a refusal is a lifecycle event — arguably the most load-bearing one,
  # since it is the only kind that proves the authority envelope was ENFORCED and
  # not merely recorded. policy_decision carries the stable slug (not the message
  # text, so rewording a refusal never breaks the series).
  #
  # An explicit clock-nonce idem key, NOT the derived default: the same actor
  # hitting the same wall twice is two genuine attempts, and the derived key
  # (which digests the payload) would collapse them into one — turning "they kept
  # trying" into "they tried once", on the exact metric that measures how often
  # policy bites.
  ledger_emit policy.refused ident="$ident" actor="$actor" policy="$policy" \
    idem="refuse:${policy}:${ident}:$(date +%s%N 2>/dev/null || echo $$)" \
    in="$msg" detail="${policy}${ticket:+ (${ticket})} — refused with code ${code}"
  fail "$code" "$msg"
}
