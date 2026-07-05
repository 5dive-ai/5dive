
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
