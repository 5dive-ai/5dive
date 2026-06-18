
# -------- projects (DIVE-484) --------
#
# A project groups tasks under its own ident namespace (prefix + per-project
# counter -> FROG-1, FROG-2 …) and carries lightweight workspace metadata
# (name/description/goal/folder/lead_agent). The default project is 'dive'
# (prefix DIVE), seeded by the schema so the original DIVE-N queue is unchanged.
# Storage lives in the same group-writable tasks.db; see lib/tasks_db.sh.

cmd_project() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    add|new)     cmd_project_add "$@" ;;
    ls|list)     cmd_project_ls "$@" ;;
    show|view)   cmd_project_show "$@" ;;
    *)           fail "$E_USAGE" "unknown project command: $sub (add|ls|show)" ;;
  esac
}

# slug rule for a project key: lowercase letters, digits, dashes.
valid_project_key()    { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]; }
# prefix rule: uppercase letters only (the part before '-' in an ident).
valid_project_prefix() { [[ "$1" =~ ^[A-Z]+$ ]]; }

cmd_project_add() {
  tasks_db_init
  local key="" prefix="" name="" description="" goal="" folder="" lead=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix=*)      prefix="${1#*=}" ;;
      --name=*)        name="${1#*=}" ;;
      --description=*) description="${1#*=}" ;;
      --goal=*)        goal="${1#*=}" ;;
      --folder=*)      folder="${1#*=}" ;;
      --lead-agent=*)  lead="${1#*=}" ;;
      -*)              fail "$E_USAGE" "unknown flag: $1" ;;
      *)               words+=("$1") ;;
    esac
    shift
  done
  key="${words[0]:-}"
  [[ -n "$key" ]] || fail "$E_USAGE" "usage: 5dive project add <key> --prefix=FROG [--name=] [--description=] [--goal=] [--folder=] [--lead-agent=]"
  key="${key,,}"
  valid_project_key "$key" || fail "$E_VALIDATION" "bad key '$key' (lowercase slug: [a-z][a-z0-9-]*)"
  # Default the prefix to the upper-cased key when not given (frog -> FROG).
  [[ -z "$prefix" ]] && prefix="${key^^}"
  prefix="${prefix^^}"
  valid_project_prefix "$prefix" || fail "$E_VALIDATION" "bad --prefix '$prefix' (UPPERCASE letters only, e.g. FROG)"

  # Uniqueness: both key and prefix must be free (prefix collisions would make
  # idents ambiguous across projects).
  [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$key");")" == "1" ]] \
    && fail "$E_VALIDATION" "project key '$key' already exists"
  [[ "$(db "SELECT 1 FROM projects WHERE prefix=$(sqlq "$prefix");")" == "1" ]] \
    && fail "$E_VALIDATION" "prefix '$prefix' already in use by another project"

  db "INSERT INTO projects (key, prefix, name, description, goal, folder, lead_agent)
      VALUES ($(sqlq "$key"), $(sqlq "$prefix"), $(sqlq_or_null "$name"),
              $(sqlq_or_null "$description"), $(sqlq_or_null "$goal"),
              $(sqlq_or_null "$folder"), $(sqlq_or_null "$lead"));"
  ok "created project '$key' (prefix ${prefix}-) — new tasks: 5dive task add --project=$key …" \
     '{key:$k, prefix:$pr, name:$n, lead_agent:$l}' \
     --arg k "$key" --arg pr "$prefix" --arg n "${name:-}" --arg l "${lead:-}"
}

cmd_project_ls() {
  tasks_db_init
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT key, prefix, counter, name, description, goal, folder, lead_agent, status, created_at FROM projects ORDER BY created_at;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{projects:.}}'
    return
  fi
  dbfmt -box "SELECT key, prefix||'-' AS prefix, counter AS tasks,
                     COALESCE(name,'') AS name, COALESCE(lead_agent,'-') AS lead,
                     status
              FROM projects ORDER BY created_at;"
}

cmd_project_show() {
  tasks_db_init
  local key="${1:-}"
  [[ -n "$key" ]] || fail "$E_USAGE" "usage: 5dive project show <key>"
  key="${key,,}"
  [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$key");")" == "1" ]] \
    || fail "$E_NOT_FOUND" "no such project: $key"
  if (( JSON_MODE )); then
    dbfmt -json "SELECT * FROM projects WHERE key=$(sqlq "$key");" | jq -c '{ok:true, data:{project:.[0]}}'
    return
  fi
  dbfmt -line "SELECT key, prefix, counter, name, description, goal, folder, lead_agent, status, archived_at, created_at
               FROM projects WHERE key=$(sqlq "$key");"
  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard';")
  printf '\n%s task(s) in this project. List: 5dive task ls --project=%s\n' "$n" "$key"
}
