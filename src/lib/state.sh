
ensure_state() {
  require_root
  mkdir -p "$STATE_DIR" "$ENV_DIR"
  chown root:claude "$STATE_DIR" "$ENV_DIR"
  chmod 2750 "$STATE_DIR" "$ENV_DIR"
  if [[ ! -f "$REGISTRY" ]]; then
    jq -cn --argjson v "$REGISTRY_SCHEMA_VERSION" \
      '{schemaVersion:$v, agents:{}}' > "$REGISTRY"
  else
    # v0 -> current migration. Pre-version registries had no top-level
    # schemaVersion; stamp it in place. Pure jq so no extra deps needed.
    local current
    current=$(jq -r '.schemaVersion // 0' "$REGISTRY" 2>/dev/null || echo 0)
    if (( current < REGISTRY_SCHEMA_VERSION )); then
      local tmp
      tmp=$(mktemp "${REGISTRY}.XXXXXX")
      # v1 -> v2 (DIVE-1002): least-privilege isolation default. Pre-v2 agents
      # had no explicit `isolation` field and were provisioned as full-sudo
      # admins (create_agent_user's old default). Stamp them explicit-admin so
      # the new standard-by-default logic never silently downgrades a live
      # admin: their tier is now recorded, not inferred. Existing sudoers files
      # are untouched — this only makes the registry honest about what they are.
      jq --argjson v "$REGISTRY_SCHEMA_VERSION" \
        '.schemaVersion = $v
         | (.agents // {}) |= with_entries(.value.isolation //= "admin")' \
        "$REGISTRY" > "$tmp"
      chown root:claude "$tmp"
      chmod 640 "$tmp"
      mv "$tmp" "$REGISTRY"
    fi
  fi
  chown root:claude "$REGISTRY"
  chmod 640 "$REGISTRY"
  # Touch the lock file so flock -x has a target even on first run.
  [[ -f "$REGISTRY_LOCK" ]] || : > "$REGISTRY_LOCK"
  chown root:claude "$REGISTRY_LOCK"
  chmod 640 "$REGISTRY_LOCK"
  # Group-writable tasks/org store (unlike the rest of STATE_DIR, which is
  # root-only): the shared task queue is meant to be used by every agent
  # without sudo. 2770 + setgid keeps the db and its -wal/-shm sidecars
  # owned by group claude and writable across agent users. tasks_db_init
  # (re)applies the schema lazily on first use.
  mkdir -p "$TASKS_DIR"
  chown root:claude "$TASKS_DIR"
  chmod 2770 "$TASKS_DIR"
  audit_init
}

# Read-only counterpart to ensure_state for pure-read commands (e.g.
# `account list`). ensure_state requires root because it mkdir/chown/chmods
# the state tree — overkill for a command that only reads the registry and
# auth-profile metadata, all of which is already group-`claude` readable
# (agents.json 640, auth-profiles 2750, combined.env 640). So a non-root
# agent that hit `account list` failed at ensure_state's require_root even
# though it could read everything (DIVE-1035: ceo /account "Failed to list
# accounts"). When the registry already exists we simply return — no root,
# no mutation. Only when state was never initialized do we fall back to the
# root-requiring path, since creating it is genuinely an admin action.
ensure_state_ro() {
  [[ -r "$REGISTRY" ]] && return 0
  ensure_state
}

# Initialise the append-only audit log. Readable by group `claude` so the
# dashboard process (which runs as `claude`) can `tail` it without sudo.

# --- DIVE-4642: the composer-wedge ledger -------------------------------------
#
# A seat whose composer holds an unsubmitted payload is simultaneously ALIVE,
# IDLE and PERMANENTLY STUCK, and nothing anywhere pages: the row it was handed
# stays `in_progress`, so every later tick reads `busy — 1 in_progress, skip`,
# which is the very thing that stops it ever being re-woken. Measured on quinn
# 2026-09-19: DIVE-4628 (urgent, a green approved PR) sat ungraded for 9.5h.
#
# The injector ALREADY knows when this happens — it prints `submit unverified`.
# That line went to a log nobody reads. This ledger is how that knowledge leaves
# the injector: one file per wedged seat, written by whoever measured the wedge,
# read by `5dive supervisor` (class `composer-wedged`) so the seat is reported
# UNHEALTHY BY NAME within one tick instead of being reported busy forever.
#
# Deliberately a FILE and not a db row: the writer is the heartbeat injector,
# which runs inside `_hb_send_line` under a registry lock on some paths, and a
# sqlite write there would be a new lock-ordering edge on the one path that must
# never hang. Group-readable (2770 root:claude) so a non-root seat can read its
# own verdict — the plugin-floor log being root-only is why that is spelled out.
_wedge_dir() { printf '%s\n' "${STATE_DIR}/composer-wedge"; }

# Record that <seat>'s composer is holding text nobody submitted.
# args: <seat> <chars> <excerpt> [<cleared|residual>]
# Best-effort by construction: a ledger write must never fail a wake.
_wedge_mark() {
  local seat="$1" chars="${2:-0}" excerpt="${3:-}" disp="${4:-residual}" d
  d="$(_wedge_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  chown root:claude "$d" 2>/dev/null || true
  chmod 2770 "$d" 2>/dev/null || true
  excerpt="${excerpt//$'\n'/ }"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$(date -u +%s)" "$chars" "$disp" "${excerpt:0:120}" \
    > "${d}/${seat}" 2>/dev/null || return 0
  chmod 660 "${d}/${seat}" 2>/dev/null || true
  return 0
}

# Forget the wedge. Called on every VERIFIED submit, so the ledger ages out by
# the seat working again rather than by a timer — a timer would clear a wedge
# that is still live, which is the failure this whole row exists to remove.
_wedge_clear() { rm -f "$(_wedge_dir)/${1}" 2>/dev/null || true; return 0; }

# Human-readable detail for <seat>, or rc 1 when the seat is not wedged.
_wedge_read() {
  local seat="$1" line ts chars disp excerpt
  line=$(cat "$(_wedge_dir)/${seat}" 2>/dev/null) || return 1
  [[ -n "$line" ]] || return 1
  IFS=$'\x1f' read -r ts chars disp excerpt <<<"$line"
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  local age=$(( $(date -u +%s) - ts ))
  (( age < 0 )) && age=0
  if [[ "$disp" == "cleared" ]]; then
    printf 'a dispatched payload could not be submitted %dm ago (%s chars, since cleared from the composer): %s\n' \
      $(( age / 60 )) "$chars" "${excerpt:0:80}"
  else
    printf 'the composer has held %s chars of UNSENT text for %dm — the seat is idle, its row reads in_progress, and nothing is running: %s\n' \
      "$chars" $(( age / 60 )) "${excerpt:0:80}"
  fi
}

# The text a seat's composer was still holding the last time a submit was
# verified — set by the heartbeat's `_hb_verify_submit`, read by the heartbeat's
# failure/alarm lines AND by `inject_and_submit` in cmd_agent_runtime, which
# needs to know what it failed to send before it clears the draft.
#
# WHY THE DECLARATION LIVES HERE AND NOT BESIDE ITS WRITER. It is unsent-draft
# state, so it belongs with `_wedge_mark`/`_wedge_clear` above on subject matter
# alone — but the reason it MOVED is mechanical. Its column-0 assignment used to
# sit in `src/cmd_heartbeat.sh`, which made cmd_heartbeat the lazy-dispatch
# PROVIDER of the name; cmd_agent_runtime reading it therefore recorded a
# `cmd_agent_runtime -> cmd_heartbeat` edge, and since cmd_agent_runtime is in
# the universal provider set that edge closed over every verb in the CLI —
# `whoami` 8 -> 12 modules, `task ls` 16 -> 20, dragging in cmd_goal,
# cmd_objective and task__loops (DIVE-4642; same shape as DIVE-4585, DIVE-4087).
# state.sh is CORE, parsed on every invocation, so a name declared here is free
# to read from any module and creates no edge at all. A cross-module global
# belongs in core; only its writer belongs in the module.
_HB_COMPOSER_UNSENT=""
