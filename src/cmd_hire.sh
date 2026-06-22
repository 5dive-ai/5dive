# -------- hire (DIVE-603) — ergonomic alias for `agent create` (+ `org set`) --------
#
# `hire` is sugar over the canonical `agent create` so demos/docs/copy can say
# "hire a CTO" and have the real command match the story. It is intentionally
# thin:
#   * defaults --type=claude (create requires an explicit --type);
#   * forwards every other flag verbatim to cmd_create, so hire inherits the
#     full create surface (--channels, --telegram-token, --isolation, …) for
#     free — no flag list to keep in sync;
#   * peels off --role / --title (org-chart concerns) and applies them via
#     cmd_org_set AFTER the agent exists.
#
# `agent create` stays canonical; hire never reimplements create logic. The
# `hire)` route in main.sh takes the registry lock exactly like `agent create`;
# with_registry_lock is re-entrant, so the inner create call is a no-op re-lock.
# If create fails it calls `fail` (exits the lock subshell) and the org step is
# correctly skipped.
cmd_hire() {
  local name="" role="" title="" role_set=0 title_set=0 have_type=0
  local create_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role=*)   role="${1#--role=}";   role_set=1 ;;
      --title=*)  title="${1#--title=}"; title_set=1 ;;
      --type=*)   have_type=1; create_args+=("$1") ;;
      -h|--help)
        cat <<'EOF'
usage: 5dive hire <name> [--type=claude] [--role=<text>] [--title=<text>] [+ any 'agent create' flag]

Sugar for `agent create` (+ `org set` when --role/--title given).
  5dive hire cto --role="CTO" --title="Chief Technology Officer"
  5dive hire scout --type=codex --channels=telegram --role="Researcher"

Defaults --type=claude. All other flags pass through to `agent create`.
EOF
        return 0 ;;
      -*)         create_args+=("$1") ;;
      *)          [[ -z "$name" ]] && name="$1" || create_args+=("$1") ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive hire <name> [--type=claude] [--role=<text>] [--title=<text>] [--channels=...] [+ any 'agent create' flag]"
  # Default the type so `hire bob --role=CTO` just works (create requires --type).
  (( have_type )) || create_args+=("--type=claude")

  # Create the agent via the canonical path (re-entrant lock = no double-lock).
  with_registry_lock cmd_create "$name" "${create_args[@]}"

  # Place the new hire on the org chart if a role/title was given. org store is
  # sqlite (separate from the registry), lockless by design — safe to call here.
  if (( role_set || title_set )); then
    local org_args=("$name")
    (( role_set ))  && org_args+=("--role=$role")
    (( title_set )) && org_args+=("--title=$title")
    cmd_org_set "${org_args[@]}"
  fi
}
