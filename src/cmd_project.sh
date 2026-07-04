
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

# DIVE-981: compute a project's task_deps dependency graph as a JSON node array.
# Each node carries its topo LAYER (longest distance from a root prerequisite, so
# tasks sort into dependency tiers L0,L1,…) and a CRITICAL flag (it lies on a
# longest end-to-end chain). Direction: task_deps(task_id, blocked_by) means
# task_id depends on blocked_by, so an edge points blocker -> dependent. Only
# standard tasks IN THIS PROJECT are scoped; cross-project/kind edges are ignored.
# Critical marking = down(node)+up(node) == longest-path length, where down is the
# longest prerequisite chain behind a node and up the longest dependent chain
# ahead — the standard "on some critical path" test. Both walks are depth-capped
# at 64 so a malformed cyclic graph can't spin. Emits [] when the project is empty.
_project_dep_graph_json() {
  local key="$1"
  dbfmt -json "WITH RECURSIVE
    scope(id) AS (SELECT id FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard'),
    edges(task_id, blocked_by) AS (
      SELECT d.task_id, d.blocked_by FROM task_deps d
        WHERE d.task_id IN (SELECT id FROM scope)
          AND d.blocked_by IN (SELECT id FROM scope)),
    down(node, depth) AS (
      SELECT s.id, 0 FROM scope s
        WHERE NOT EXISTS (SELECT 1 FROM edges e WHERE e.task_id=s.id)
      UNION ALL
      SELECT e.task_id, dn.depth+1 FROM down dn JOIN edges e ON e.blocked_by=dn.node
        WHERE dn.depth < 64),
    dmax(node, d) AS (SELECT node, MAX(depth) FROM down GROUP BY node),
    up(node, h) AS (
      SELECT s.id, 0 FROM scope s
        WHERE NOT EXISTS (SELECT 1 FROM edges e WHERE e.blocked_by=s.id)
      UNION ALL
      SELECT e.blocked_by, u.h+1 FROM up u JOIN edges e ON e.task_id=u.node
        WHERE u.h < 64),
    umax(node, h) AS (SELECT node, MAX(h) FROM up GROUP BY node),
    tot(node, t) AS (SELECT dmax.node, dmax.d + umax.h FROM dmax JOIN umax ON umax.node=dmax.node),
    maxt(m) AS (SELECT COALESCE(MAX(t), 0) FROM tot)
    SELECT
      t.ident   AS ident,
      t.status  AS status,
      t.title   AS title,
      dmax.d    AS layer,
      CASE WHEN (SELECT m FROM maxt) > 0 AND tot.t = (SELECT m FROM maxt)
           THEN 1 ELSE 0 END AS critical,
      COALESCE((SELECT group_concat(b.ident, ',') FROM edges e JOIN tasks b ON b.id=e.blocked_by
                  WHERE e.task_id=t.id ORDER BY b.id), '') AS blockers
    FROM scope s
      JOIN tasks t   ON t.id = s.id
      JOIN dmax      ON dmax.node = s.id
      JOIN tot       ON tot.node = s.id
    ORDER BY layer, critical DESC, t.id;"
}

# Reconstruct one representative critical path (blocker -> … -> dependent) from
# the graph JSON, walking backward from a critical sink through critical blockers
# one layer down at a time. Prints the chain as "A -> B -> C" (empty if none).
_project_critical_chain() {
  local graph="$1"
  # ident|layer|critical|blockers-csv, one row per node
  local -A LAYER CRIT BLK
  local line ident layer crit blk
  while IFS=$'\t' read -r ident layer crit blk; do
    LAYER["$ident"]="$layer"; CRIT["$ident"]="$crit"; BLK["$ident"]="$blk"
  done < <(printf '%s' "$graph" | jq -r '.[] | [.ident, (.layer|tostring), (.critical|tostring), .blockers] | @tsv')
  # sink = critical node with the greatest layer
  local sink="" best=-1
  for ident in "${!CRIT[@]}"; do
    [[ "${CRIT[$ident]}" == "1" ]] || continue
    (( LAYER[$ident] > best )) && { best="${LAYER[$ident]}"; sink="$ident"; }
  done
  [[ -n "$sink" ]] || return 0
  local -a chain=("$sink") cur="$sink"
  while (( LAYER[$cur] > 0 )); do
    local want=$(( LAYER[$cur] - 1 )) picked="" b
    IFS=',' read -ra _blks <<< "${BLK[$cur]}"
    for b in "${_blks[@]}"; do
      [[ -n "$b" && "${CRIT[$b]:-0}" == "1" && "${LAYER[$b]:-}" == "$want" ]] && { picked="$b"; break; }
    done
    [[ -n "$picked" ]] || break
    chain=("$picked" "${chain[@]}"); cur="$picked"
  done
  local out="" c
  for c in "${chain[@]}"; do out+="${out:+ -> }$c"; done
  printf '%s' "$out"
}

cmd_project_show() {
  tasks_db_init
  local key="${1:-}"
  [[ -n "$key" ]] || fail "$E_USAGE" "usage: 5dive project show <key>"
  key="${key,,}"
  [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$key");")" == "1" ]] \
    || fail "$E_NOT_FOUND" "no such project: $key"

  local graph; graph=$(_project_dep_graph_json "$key"); [[ -n "$graph" ]] || graph="[]"
  local edges; edges=$(printf '%s' "$graph" | jq '[.[].blockers | select(length>0) | split(",") | length] | add // 0')
  local layers; layers=$(printf '%s' "$graph" | jq '([.[].layer] | max // -1) + 1')
  local chain; chain=$(_project_critical_chain "$graph")

  if (( JSON_MODE )); then
    dbfmt -json "SELECT * FROM projects WHERE key=$(sqlq "$key");" \
      | jq -c --argjson g "$graph" --argjson edges "$edges" --argjson layers "$layers" \
             --arg chain "$chain" \
             '{ok:true, data:{project:.[0], graph:{
                nodes:$g, edges:$edges, layers:$layers,
                critical_path:(if $chain=="" then [] else ($chain|split(" -> ")) end)}}}'
    return
  fi

  dbfmt -line "SELECT key, prefix, counter, name, description, goal, folder, lead_agent, status, archived_at, created_at
               FROM projects WHERE key=$(sqlq "$key");"
  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard';")
  printf '\n%s task(s) in this project. List: 5dive task ls --project=%s\n' "$n" "$key"

  # --- DIVE-981 dependency graph + critical path ---
  if (( edges == 0 )); then
    (( n > 0 )) && printf '\nDependency graph: no task_deps recorded (%s independent task(s)).\n' "$n"
    return
  fi
  printf '\nDependency graph  (%s task(s), %s layer(s), %s edge(s); \xe2\x97\x86 = critical path)\n\n' \
         "$n" "$layers" "$edges"
  # Render layer by layer; ident/status/title, blockers inline, critical marked.
  local prev_layer="-1" ident status title layer crit blk mark blkdisp
  while IFS=$'\t' read -r ident status title layer crit blk; do
    if [[ "$layer" != "$prev_layer" ]]; then
      printf '  L%s\n' "$layer"; prev_layer="$layer"
    fi
    mark=" "; [[ "$crit" == "1" ]] && mark=$'\xe2\x97\x86'
    blkdisp=""; [[ -n "$blk" ]] && blkdisp="  <- ${blk//,/, }"
    printf '    %s %-10s [%-9s] %s%s\n' "$mark" "$ident" "$status" "$title" "$blkdisp"
  done < <(printf '%s' "$graph" | jq -r '.[] | [.ident, .status, .title, (.layer|tostring), (.critical|tostring), .blockers] | @tsv')
  [[ -n "$chain" ]] && printf '\nCritical path:  %s  (%s step(s))\n' \
    "$chain" "$(( $(printf '%s' "$chain" | grep -o ' -> ' | wc -l) + 1 ))"
}
