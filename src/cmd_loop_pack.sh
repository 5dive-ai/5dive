# -------- loop packs (DIVE-761) — install recurring agentic workflows --------
# A "loop pack" is a marketplace entry (5dive-ai/loops registry) that turns a
# job title into a recurring agent: persona + skills + a cadence + a starter
# prompt. `5dive loop install <slug> --onto=<agent>` wires the pack's skills and
# a recurring task onto an existing agent, so the agent wakes itself on the
# pack's schedule and does the job. The marketplace tab's Install button calls
# this. Browse lives in the dashboard; this is the install/show half on the CLI.
#
# Cost/safety posture (v1): the loop runs at the TARGET agent's existing
# autonomy (we do not silently elevate it) and is bounded by (a) the pack's
# cadence — every-4h/daily, not a tight spin — plus (b) the agent's account
# usage budget (`5dive usage budget`). The advisory --ceiling is recorded on the
# job for visibility; hard per-run token-halt (reusing the loop-engine ceiling)
# is the documented next increment, not faked here.

_loops_base() { echo "https://raw.githubusercontent.com/$(gh_org)/loops/main"; }
_loops_index() { curl -fsSL --max-time 20 "$(_loops_base)/index.json" 2>/dev/null; }

# Resolve <slug> → the loop entry JSON from the registry. Echoes JSON; 1 if absent.
_loops_fetch_entry() {
  local slug="$1" idx
  idx=$(_loops_index) || return 1
  jq -e --arg s "$slug" '.loops[] | select((.slug // .id)==$s)' <<<"$idx" 2>/dev/null
}

cmd_loop_pack() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    install)            cmd_loop_pack_install "$@" ;;
    uninstall|remove)   cmd_loop_pack_uninstall "$@" ;;
    show)               cmd_loop_pack_show "$@" ;;
    help|-h|--help)     _loop_pack_help ;;
    *)                  fail "$E_USAGE" "unknown loop command: $sub (install|uninstall|show)" ;;
  esac
}

_loop_pack_help() {
  cat <<'EOF'
5dive loop install — install a marketplace loop pack (recurring agentic workflow)

  loop install   <slug> --onto=<agent> [--cron="<5-field>"] [--ceiling=<tokens>] [--dry-run]
  loop uninstall <slug> --from=<agent> [--purge-skills]
  loop show      <slug>

  <slug>          a loop from the 5dive-ai/loops registry (e.g. ci-analyst).
  --onto          existing agent that takes the job (gains the skills + recurring task).
  --from          agent to remove the loop from (deletes its recurring job).
  --cron          override the pack's cadence (5-field cron).
  --ceiling       advisory per-run token budget, recorded on the job (visibility).
  --purge-skills  on uninstall, also remove the pack's skills from the agent.
  --dry-run       print the plan, change nothing.

  The agent runs the loop at its own autonomy level (not elevated) on the pack's
  cadence. Bound spend with `5dive usage budget <agent> ...`.
EOF
}

# loop show <slug> — print the pack (read-only registry lookup).
cmd_loop_pack_show() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive loop show <slug>"
  local entry; entry=$(_loops_fetch_entry "$slug") \
    || fail "$E_NOT_FOUND" "no loop '$slug' in the $(gh_org)/loops registry"
  if (( JSON_MODE )); then
    ok "" '$e' --argjson e "$entry"
  else
    jq -r '
      "loop: \(.slug // .id)",
      "  job:      \(.jobTitle)",
      "  does:     \(.tagline // .does // "-")",
      "  cadence:  \(.trigger.label // .trigger.cron // .cadence // "-")",
      "  skills:   \((.skills // []) | join(", "))",
      "  agent:    \((.agent // []) | if type=="array" then join("+") else . end)"
    ' <<<"$entry"
  fi
}

# loop install <slug> --onto=<agent> [...] — wire the pack onto an agent.
cmd_loop_pack_install() {
  local slug="" onto="" cron_override="" ceiling="" dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --onto=*)    onto="${1#*=}" ;;
      --cron=*)    cron_override="${1#*=}" ;;
      --ceiling=*) ceiling="${1#*=}" ;;
      --dry-run)   dry=1 ;;
      --)          shift; [[ -z "$slug" && $# -gt 0 ]] && { slug="$1"; shift; }; break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$slug" ]] && slug="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive loop install <slug> --onto=<agent> [--cron=\"<5-field>\"] [--ceiling=<tokens>] [--dry-run]"
  [[ -n "$onto" ]] || fail "$E_USAGE" "--onto=<agent> is required (the agent that takes the job)"
  [[ -z "$ceiling" || "$ceiling" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"

  # Pack from registry.
  local entry; entry=$(_loops_fetch_entry "$slug") \
    || fail "$E_NOT_FOUND" "no loop '$slug' in the $(gh_org)/loops registry"
  local job prompt cron
  job=$(jq -r '.jobTitle // .slug // .id' <<<"$entry")
  prompt=$(jq -r '.starterPrompt // empty' <<<"$entry")
  cron="${cron_override:-$(jq -r '.trigger.cron // .schedule // empty' <<<"$entry")}"
  [[ -n "$prompt" ]] || fail "$E_VALIDATION" "loop '$slug' has no starterPrompt — can't install"
  [[ -n "$cron" ]] || fail "$E_VALIDATION" "loop '$slug' has no cron cadence (and no --cron given)"
  valid_cron_expr "$cron" || fail "$E_VALIDATION" "bad cadence cron '$cron' (need a 5-field expr, e.g. \"0 */4 * * *\")"

  # Target agent must exist.
  local user="agent-${onto}" home="/home/agent-${onto}"
  [[ -d "$home" ]] || fail "$E_NOT_FOUND" "agent home missing: $home (is '$onto' a real agent? see: 5dive agent list)"
  id -u "$user" &>/dev/null || fail "$E_NOT_FOUND" "agent user missing: $user"
  agent_type "$onto" >/dev/null 2>&1 || true

  local -a skills=()
  while IFS= read -r s; do [[ -n "$s" ]] && skills+=("$s"); done \
    < <(jq -r '.skills[]? // empty' <<<"$entry")

  if (( dry )); then
    step "DRY-RUN — would install loop '$slug' onto '$onto':"
    step "  recurring job: \"$job\" on cron '$cron', assignee=$onto"
    step "  skills to attach: ${skills[*]:-(none)}"
    step "  starter prompt: ${prompt:0:80}..."
    [[ -n "$ceiling" ]] && step "  advisory ceiling: ${ceiling} tokens/run"
    ok "dry-run: loop '$slug' would install onto '$onto'" \
       '{slug:$s, onto:$o, cron:$c, skills:$sk, dryRun:true}' \
       --arg s "$slug" --arg o "$onto" --arg c "$cron" --argjson sk "$(jq -c '.skills // []' <<<"$entry")"
    return 0
  fi

  # Attach skills, best-effort. A pack lists bare ids that resolve to the
  # 5dive-ai/skills repo (copywriting, ad-creative, compile-knowledge, …) AND
  # Claude-Code built-in skills (deep-research, verify, …) that aren't in any
  # repo. The first install; the second 404s — those are already present on the
  # agent, so we skip+note rather than abort the whole install.
  local -a attached=() skipped=()
  local sk src id
  for sk in "${skills[@]}"; do
    read -r src id < <(parse_skill_spec "$sk")
    if ! valid_skill_id "$id"; then skipped+=("$sk"); warn "skipping invalid skill id '$sk'"; continue; fi
    step "attaching skill '$id' (from $src) to '$onto'..."
    if ( cmd_skill_add "$onto" --source="$src" --skill="$id" ) >/dev/null 2>&1; then
      attached+=("$id")
    else
      skipped+=("$id")
      warn "skill '$id' not installed from '$src' (likely a built-in already on the agent) — continuing"
    fi
  done

  # Register the recurring job. Fold the starter prompt + provenance + advisory
  # ceiling into the body so each materialized run carries its own brief.
  local body="$prompt

— installed loop: $slug (5dive marketplace). runs on '$cron'."
  [[ -n "$ceiling" ]] && body="$body advisory budget: ${ceiling} tokens/run (bound hard with: 5dive usage budget $onto)."
  local out ident
  out=$(cmd_task_add "$job" --body="$body" --recurring="$cron" --assignee="$onto" --project=dive 2>/dev/null) || true
  if (( JSON_MODE )); then
    ident=$(jq -r '.data.ident // empty' <<<"$out" 2>/dev/null)
  else
    ident=$(grep -oE 'DIVE-[0-9]+' <<<"$out" | head -1)
  fi
  [[ -n "$ident" ]] || fail "$E_GENERIC" "failed to register the recurring job for loop '$slug'"

  step "installed loop '$slug' onto '$onto' — recurring job $ident on '$cron'"
  (( ${#skipped[@]} )) && step "skills already-present/skipped: ${skipped[*]}"
  ok "installed loop '$slug' onto '$onto' (recurring $ident, cron '$cron')" \
     '{slug:$s, job:$j, onto:$o, task:$t, cron:$c, skillsAttached:$a, skillsSkipped:$k, ceiling:($ce|if .=="" then null else (.|tonumber) end)}' \
     --arg s "$slug" --arg j "$job" --arg o "$onto" --arg t "$ident" --arg c "$cron" \
     --argjson a "$(printf '%s\n' "${attached[@]:-}" | jq -R . | jq -sc 'map(select(.!=""))')" \
     --argjson k "$(printf '%s\n' "${skipped[@]:-}" | jq -R . | jq -sc 'map(select(.!=""))')" \
     --arg ce "$ceiling"
}

# loop uninstall <slug> --from=<agent> [--purge-skills] — remove an installed
# loop's recurring job. Necessary because `task cancel` does NOT stop a recurring
# template (the materializer keys on kind+schedule, not status), so without this
# a bad loop can't be cleanly stopped. We delete the TEMPLATE row only; any
# already-materialized instances are separate rows (from_template_id, no cascade)
# and are left alone. Skills are kept by default (the agent may use them
# elsewhere); --purge-skills removes the pack's skills too.
cmd_loop_pack_uninstall() {
  local slug="" from="" purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from=*)       from="${1#*=}" ;;
      --purge-skills) purge=1 ;;
      --)             shift; [[ -z "$slug" && $# -gt 0 ]] && { slug="$1"; shift; }; break ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              [[ -z "$slug" ]] && slug="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive loop uninstall <slug> --from=<agent> [--purge-skills]"
  [[ -n "$from" ]] || fail "$E_USAGE" "--from=<agent> is required"
  valid_skill_id "$slug" || fail "$E_VALIDATION" "invalid loop slug '$slug'"

  tasks_db_init
  # Match the install marker we write into the body. kind='recurring' + assignee
  # scopes it to this agent's installed loop; LIKE on the marker scopes to this slug.
  local marker="installed loop: ${slug} (5dive marketplace)"
  local ids; ids=$(db "SELECT id FROM tasks WHERE kind='recurring' AND assignee=$(sqlq "$from") AND body LIKE '%'||$(sqlq "$marker")||'%';")
  [[ -n "$ids" ]] || fail "$E_NOT_FOUND" "no installed loop '$slug' found on agent '$from'"
  local -a idents=()
  local id
  while IFS= read -r id; do [[ -n "$id" ]] || continue; idents+=("$(ident_of "$id")"); done <<<"$ids"
  # Delete the template rows (comma-joined id list).
  local idlist; idlist=$(printf '%s,' $ids); idlist="${idlist%,}"
  db "DELETE FROM tasks WHERE id IN (${idlist}) AND kind='recurring';"

  local -a removed_skills=()
  if (( purge )); then
    local entry; entry=$(_loops_fetch_entry "$slug" 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
      local sk src sid
      while IFS= read -r sk; do
        [[ -n "$sk" ]] || continue
        read -r src sid < <(parse_skill_spec "$sk")
        valid_skill_id "$sid" || continue
        if ( cmd_skill_rm "$from" --skill="$sid" ) >/dev/null 2>&1; then removed_skills+=("$sid"); fi
      done < <(jq -r '.skills[]? // empty' <<<"$entry")
    fi
  fi

  step "uninstalled loop '$slug' from '$from' — removed recurring job(s): ${idents[*]}"
  (( ${#removed_skills[@]} )) && step "purged skills: ${removed_skills[*]}"
  ok "uninstalled loop '$slug' from '$from' (removed ${#idents[@]} recurring job(s))" \
     '{slug:$s, from:$f, removed:$r, purgedSkills:$p}' \
     --arg s "$slug" --arg f "$from" \
     --argjson r "$(printf '%s\n' "${idents[@]:-}" | jq -R . | jq -sc 'map(select(.!=""))')" \
     --argjson p "$(printf '%s\n' "${removed_skills[@]:-}" | jq -R . | jq -sc 'map(select(.!=""))')"
}
