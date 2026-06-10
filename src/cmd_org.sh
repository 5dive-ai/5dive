
# -------- 5dive org — agent org chart --------
#
# Subordination is a single self-referential column (agents_org.reports_to),
# the same shape Paperclip uses. The org chart only earns its keep once a
# fleet grows past a handful of agents, so this stays deliberately small:
# who reports to whom, plus an optional role/title label.

_org_usage() {
  cat <<USAGE
5dive org — agent org chart (who reports to whom)

  5dive org set <agent> [--manager=<agent>|default] [--role=<text>] [--title=<text>]
                                                     # upsert; --manager=default clears
  5dive org tree                                     # the whole hierarchy, indented
  5dive org show <agent>                             # manager + direct reports
  5dive org ls                                       # flat list of everyone placed
  5dive org rm <agent>                               # remove (reports re-parent to null)

  Any agent (group claude) can run these without sudo. Add --json for machine output.
USAGE
}

cmd_org() {
  [[ $# -gt 0 ]] || { _org_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    set)             cmd_org_set "$@" ;;
    tree)            cmd_org_tree "$@" ;;
    show)            cmd_org_show "$@" ;;
    ls|list)         cmd_org_ls "$@" ;;
    rm|delete)       cmd_org_rm "$@" ;;
    -h|--help|help)  _org_usage ;;
    *) fail "$E_USAGE" "unknown org command: $sub (try: 5dive org --help)" ;;
  esac
}

cmd_org_set() {
  tasks_db_init
  local name="" manager="" role="" title=""
  local mgr_set=0 role_set=0 title_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manager=*) manager="${1#*=}"; mgr_set=1 ;;
      --role=*)    role="${1#*=}";    role_set=1 ;;
      --title=*)   title="${1#*=}";   title_set=1 ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive org set <agent> [--manager=] [--role=] [--title=]"
  valid_sender_label "$name" || fail "$E_VALIDATION" "bad agent name '$name'"
  (( mgr_set || role_set || title_set )) || fail "$E_USAGE" "nothing to set — pass --manager, --role and/or --title"

  # Resolve the manager value: default/none/empty clears the edge.
  local mgr_clear=0 mgr_name=""
  if (( mgr_set )); then
    case "$manager" in
      ""|default|none) mgr_clear=1 ;;
      *)
        valid_sender_label "$manager" || fail "$E_VALIDATION" "bad manager name '$manager'"
        [[ "$manager" != "$name" ]] || fail "$E_VALIDATION" "an agent can't report to itself"
        mgr_name="$manager"
        # Reject cycles: $name must not already sit above $manager in the chain.
        local cyc
        cyc=$(db "WITH RECURSIVE up(n) AS (
                    SELECT $(sqlq "$manager")
                    UNION ALL
                    SELECT a.reports_to FROM agents_org a JOIN up ON a.name=up.n
                    WHERE a.reports_to IS NOT NULL)
                  SELECT 1 FROM up WHERE n=$(sqlq "$name") LIMIT 1;")
        [[ -z "$cyc" ]] || fail "$E_CONFLICT" "that would create a reporting cycle ($manager already reports up to $name)"
        ;;
    esac
  fi

  db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$name"));"
  if (( mgr_set )); then
    if (( mgr_clear )); then
      db "UPDATE agents_org SET reports_to=NULL, updated_at=datetime('now') WHERE name=$(sqlq "$name");"
    else
      db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$mgr_name"));
          UPDATE agents_org SET reports_to=$(sqlq "$mgr_name"), updated_at=datetime('now') WHERE name=$(sqlq "$name");"
    fi
  fi
  (( role_set ))  && db "UPDATE agents_org SET role=$(sqlq_or_null "$role"),   updated_at=datetime('now') WHERE name=$(sqlq "$name");"
  (( title_set )) && db "UPDATE agents_org SET title=$(sqlq_or_null "$title"), updated_at=datetime('now') WHERE name=$(sqlq "$name");"

  if (( JSON_MODE )); then
    local row; row=$(dbfmt -json "SELECT name, reports_to, role, title FROM agents_org WHERE name=$(sqlq "$name");")
    jq -cn --argjson r "$row" '{ok:true, data:($r[0])}'
  else
    local mgr; mgr=$(db "SELECT COALESCE(reports_to,'(top)') FROM agents_org WHERE name=$(sqlq "$name");")
    ok "$name -> reports to $mgr"
  fi
}

cmd_org_tree() {
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive org tree"
  local count; count=$(db "SELECT COUNT(*) FROM agents_org;")
  if [[ "$count" == "0" ]]; then
    if (( JSON_MODE )); then jq -cn '{ok:true, data:{tree:[]}}'; else echo "(org chart empty — place agents with: 5dive org set <agent> --manager=<agent>)"; fi
    return 0
  fi
  # Roots: no manager, or a manager that isn't itself placed (orphans surface
  # rather than vanish). Walk down from there; path drives display order.
  local cte="WITH RECURSIVE tree(name, reports_to, role, title, depth, path) AS (
      SELECT name, reports_to, role, title, 0, name
      FROM agents_org
      WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org)
      UNION ALL
      SELECT a.name, a.reports_to, a.role, a.title, t.depth+1, t.path||'/'||a.name
      FROM agents_org a JOIN tree t ON a.reports_to = t.name)"
  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "${cte} SELECT name, reports_to, role, title, depth FROM tree ORDER BY path;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{tree:.}}'  # stdin, not --argjson (DIVE-222)
  else
    # Default list mode: no header, one column -> one indented line per row.
    db "${cte}
      SELECT substr('                                        ', 1, depth*2)
             || name
             || CASE WHEN title IS NOT NULL THEN '  — '||title
                     WHEN role  IS NOT NULL THEN '  — '||role ELSE '' END
      FROM tree ORDER BY path;"
  fi
}

cmd_org_show() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive org show <agent>"
  local name="$1"
  valid_sender_label "$name" || fail "$E_VALIDATION" "bad agent name '$name'"
  local exists; exists=$(db "SELECT 1 FROM agents_org WHERE name=$(sqlq "$name");")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "agent '$name' is not placed in the org chart"
  if (( JSON_MODE )); then
    local self reports
    self=$(dbfmt -json "SELECT name, reports_to, role, title FROM agents_org WHERE name=$(sqlq "$name");")
    reports=$(dbfmt -json "SELECT name, role, title FROM agents_org WHERE reports_to=$(sqlq "$name") ORDER BY name;")
    [[ -n "$reports" ]] || reports="[]"
    jq -cn --argjson s "$self" --argjson r "$reports" '{ok:true, data:($s[0] + {direct_reports:$r})}'
  else
    dbfmt -line "SELECT name, COALESCE(reports_to,'(top)') AS reports_to, role, title FROM agents_org WHERE name=$(sqlq "$name");"
    local reps; reps=$(db "SELECT name FROM agents_org WHERE reports_to=$(sqlq "$name") ORDER BY name;")
    if [[ -n "$reps" ]]; then echo; echo "direct reports:"; printf '%s\n' "$reps" | indent2; else echo; echo "direct reports: (none)"; fi
  fi
}

cmd_org_ls() {
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive org ls"
  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "SELECT name, reports_to, role, title FROM agents_org ORDER BY name;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{agents:.}}'  # stdin, not --argjson (DIVE-222)
  else
    dbfmt -box "SELECT name, COALESCE(reports_to,'-') AS reports_to, COALESCE(role,'-') AS role, COALESCE(title,'-') AS title FROM agents_org ORDER BY name;"
  fi
}

cmd_org_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive org rm <agent>"
  local name="$1"
  valid_sender_label "$name" || fail "$E_VALIDATION" "bad agent name '$name'"
  local exists; exists=$(db "SELECT 1 FROM agents_org WHERE name=$(sqlq "$name");")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "agent '$name' is not placed in the org chart"
  db "DELETE FROM agents_org WHERE name=$(sqlq "$name");"
  ok "$name removed from org chart" '{name:$n, removed:true}' --arg n "$name"
}
