
# -------- 5dive company: onboarding wizard for a self-steering company --------
# OSS-34 ("build LAST"): pure sugar, a `5dive init` for a company. It stands up
# the smallest self-steering unit — a project namespace + ONE objective (the
# number the company steers, bound to a read-only metric) + a planner + a
# re-plan cadence — and optionally seeds a first goal. It is NOT a second
# orchestration engine: every prompt maps 1:1 to an existing primitive and the
# wizard shells back into `project add` / `objective add` / `goal add`, so
# anything it does is reachable via those commands directly (see
# cli-v0.10-self-steering-company-loops).
#
# Two ways in, same code path: run it bare for the prompt-driven wizard, or pass
# flags + --yes for a scripted, non-interactive stand-up (flags pre-seed the
# prompts; --yes skips them and requires the essentials). Reuses the _init_*
# helpers from cmd_init.sh for the shared, dependency-free terminal UI.

_company_welcome() {
  local cyan="" bold="" dim="" reset=""
  if _init_color_enabled; then
    cyan=$'\033[38;5;81m'; bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
  fi
  printf '\n  %s%s5dive company%s\n' "$cyan" "$bold" "$reset" >&2
  printf '  %sStand up a self-steering company: one number, on autopilot.%s\n' "$bold" "$reset" >&2
  printf '  %sA project + an objective + a planner, wired in a few guided steps.%s\n\n' "$dim" "$reset" >&2
}

# Best-effort slug: lowercase, non-alnum -> single hyphen, trim, cap length.
_company_slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  s="${s#-}"; s="${s%-}"
  printf '%s' "${s:0:32}"
}

cmd_company() {
  tasks_db_init

  # --- Flags: every prompt has a matching flag so the wizard is scriptable ---
  local cname="" key="" prefix="" outcome="" metric="" target="" direction="up"
  local unit="" planner="" review="" maxnew="3" first_goal="" assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*)      cname="${1#*=}" ;;
      --key=*)       key="${1#*=}" ;;
      --prefix=*)    prefix="${1#*=}" ;;
      --objective=*) outcome="${1#*=}" ;;
      --metric-cmd=*) metric="${1#*=}" ;;
      --target=*)    target="${1#*=}" ;;
      --direction=*) direction="${1#*=}" ;;
      --unit=*)      unit="${1#*=}" ;;
      --planner=*)   planner="${1#*=}" ;;
      --review=*)    review="${1#*=}" ;;
      --max-new-per-cycle=*) maxnew="${1#*=}" ;;
      --goal=*)      first_goal="${1#*=}" ;;
      -y|--yes)      assume_yes=1 ;;
      -h|--help)
        cat >&2 <<'USAGE'
5dive company [--yes] [flags]
  Onboarding wizard: stand up a self-steering company — a project namespace, one
  objective (a number bound to a read-only metric), a planner, and a re-plan
  cadence. Thin sugar over `project add` + `objective add` + `goal add`.

  Run bare for the interactive wizard, or drive it with flags:
    --name=<company>          Company name
    --key=<slug>              Project key (task namespace; default: slug of name)
    --prefix=<UPPER>          Task id prefix, e.g. ACME (default: from key)
    --objective="<outcome>"   What the company steers toward
    --metric-cmd="<cmd>"      Read-only command that prints ONE number to stdout
    --target=<n>              Target value for the metric
    --direction=up|down       Which way is better (default up)
    --unit=<u>                Optional unit label (%, $, …)
    --planner=<agent>         Agent that re-plans each cycle (default: set later)
    --review="<cron>"         Re-plan cadence, e.g. "0 9 * * 1" (default: manual)
    --max-new-per-cycle=<n>   Cap on tasks a re-plan may create (default 3)
    --goal="<outcome>"        Also decompose a first goal into a task graph
    -y, --yes                 Non-interactive: use flags/defaults, no prompts
USAGE
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag '$1' (see: 5dive company --help)" ;;
      *)  [[ -z "$cname" ]] && cname="$1" || fail "$E_USAGE" "unexpected argument '$1'" ;;
    esac
    shift
  done

  local interactive=1
  { [[ $assume_yes -eq 1 || ! -t 0 ]]; } && interactive=0
  if (( interactive == 0 && assume_yes == 0 )); then
    fail "$E_USAGE" "5dive company is interactive — run it in a real terminal, or pass --yes with flags"
  fi

  (( interactive )) && _company_welcome

  # --- Step 1/4: name -> project key + prefix ---
  (( interactive )) && _init_section 1 4 "Name your company" \
    "This becomes a project namespace for the company's tasks."
  if (( interactive )); then
    _init_text cname "Company name" "${cname:-Acme}"
  fi
  [[ -n "$cname" ]] || fail "$E_VALIDATION" "--name is required"
  [[ -n "$key" ]] || key=$(_company_slug "$cname")
  [[ -n "$key" ]] || key="company"
  (( interactive )) && _init_text key "Project key (task namespace)" "$key"
  key="${key,,}"
  valid_project_key "$key" || fail "$E_VALIDATION" "bad project key '$key' (lowercase slug: [a-z][a-z0-9-]*)"
  if [[ -z "$prefix" ]]; then
    prefix=$(printf '%s' "$key" | tr -cd 'a-z' | tr '[:lower:]' '[:upper:]')
    prefix="${prefix:0:4}"; [[ -n "$prefix" ]] || prefix="CO"
  fi
  (( interactive )) && _init_text prefix "Task prefix (uppercase, e.g. ACME)" "$prefix"
  prefix="${prefix^^}"
  valid_project_prefix "$prefix" || fail "$E_VALIDATION" "bad prefix '$prefix' (UPPERCASE letters only)"

  # --- Step 2/4: the number the company steers ---
  (( interactive )) && _init_section 2 4 "The number you steer" \
    "One objective, bound to a read-only metric command that prints a number."
  if (( interactive )); then
    _init_text outcome "Objective (what outcome are you steering?)" "${outcome:-grow $cname}"
    _init_note "The metric is a READ-ONLY command whose stdout is ONE number."
    _init_text metric "Metric command" "${metric:-5dive digest --json | jq .tasks.done}"
  fi
  [[ -n "$outcome" ]] || fail "$E_VALIDATION" "--objective is required"
  [[ -n "$metric" ]] || fail "$E_VALIDATION" "--metric-cmd is required (a read-only command printing one number)"
  # Offer to prove the metric reads a number before we commit to it.
  if (( interactive )); then
    local test_choice
    _init_pick test_choice "Test-run the metric now?" 1 \
      "yes|Run it|read the number this command prints" \
      "no|Skip|trust it, wire it up as-is"
    if [[ "$test_choice" == "yes" ]]; then
      local reading; reading=$(_objective_metric_run "$metric")
      if [[ "${reading#*|}" == "0" ]]; then
        _init_ok "Metric reads: ${reading%|*}"
      else
        _init_warn "Metric did not print a number (exit ${reading#*|}) — you can still wire it and fix later."
      fi
    fi
    _init_text target "Target value" "${target:-100}"
    _init_pick direction "Which way is better?" 1 \
      "up|Up|higher is better" \
      "down|Down|lower is better"
    _init_text unit "Unit (optional, e.g. % or \$)" "$unit"
  fi
  case "$direction" in up|down) ;; *) fail "$E_VALIDATION" "bad --direction '$direction' (up|down)" ;; esac

  # --- Step 3/4: how it self-steers ---
  (( interactive )) && _init_section 3 4 "How it self-steers" \
    "A planner agent re-reads the number each cycle and re-plans the work."
  if (( interactive )); then
    _init_text planner "Planner agent (blank = set later)" "$planner"
    local cad
    _init_pick cad "Re-plan cadence" 3 \
      "0 9 * * *|Daily|every morning at 09:00" \
      "0 9 * * 1|Weekly|Mondays at 09:00" \
      "none|Manual|only when you run objective replan"
    [[ "$cad" == "none" ]] && review="" || review="$cad"
    _init_text maxnew "Max new tasks per re-plan cycle" "$maxnew"
  fi
  [[ "$maxnew" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--max-new-per-cycle must be a non-negative integer"

  # --- Step 4/4: review + create ---
  if (( interactive )); then
    _init_section 4 4 "Review and create" \
      "Nothing below is secret. Confirm before 5dive creates the project + objective."
    _init_review_row "Company"   "$cname"
    _init_review_row "Project"   "$key ($prefix-N)"
    _init_review_row "Objective" "$outcome"
    _init_review_row "Metric"    "$metric"
    _init_review_row "Target"    "${direction} to ${target:-?}${unit}"
    _init_review_row "Planner"   "${planner:-— set later}"
    _init_review_row "Re-plan"   "${review:-manual}"
    echo >&2
    local go
    _init_pick go "Create the company?" 1 \
      "create|Create|set up the project and objective" \
      "cancel|Cancel|exit without changes"
    if [[ "$go" == "cancel" ]]; then
      _init_note "Cancelled. Nothing was created."
      return 0
    fi
  fi

  # --- Provision: project (skip if it already exists), then the objective ---
  if [[ "$(db "SELECT 1 FROM projects WHERE key=$(sqlq "$key");" 2>/dev/null)" == "1" ]]; then
    (( interactive )) && _init_note "Project '$key' already exists — reusing it."
  else
    cmd_project add "$key" --prefix="$prefix" --name="$cname" >&2 \
      || fail "$E_GENERIC" "failed to create project '$key'"
    (( interactive )) && _init_ok "Project $key created"
  fi

  local -a oa=("$outcome" "--metric-cmd=$metric" "--direction=$direction"
               "--project=$key" "--max-new-per-cycle=$maxnew")
  [[ -n "$target" ]]  && oa+=("--target=$target")
  [[ -n "$unit" ]]    && oa+=("--unit=$unit")
  [[ -n "$review" ]]  && oa+=("--review=$review")
  [[ -n "$planner" ]] && oa+=("--planner=$planner")
  cmd_objective add "${oa[@]}" >&2 \
    || fail "$E_GENERIC" "failed to create objective '$outcome'"
  (( interactive )) && _init_ok "Objective '$outcome' created"

  # --- Optional: seed a first goal (decompose an outcome into a task graph) ---
  if (( interactive )) && [[ -z "$first_goal" ]]; then
    local seed
    _init_pick seed "Decompose a first goal now?" 2 \
      "yes|Yes|break an outcome into a guardrailed task graph" \
      "no|Not now|do it later with goal add"
    if [[ "$seed" == "yes" ]]; then
      _init_text first_goal "First goal (outcome to decompose)" ""
    fi
  fi
  if [[ -n "$first_goal" ]]; then
    cmd_goal add "$first_goal" --project="$key" >&2 \
      || _init_warn "goal add failed — you can retry: 5dive goal add \"$first_goal\" --project=$key"
  fi

  # --- Next steps ---
  if (( interactive )); then
    echo >&2
    _init_ok "$cname is steering."
    cat >&2 <<NEXT

  Next:
    5dive objective tick   "$outcome"       # take the first reading
    5dive objective status "$outcome"       # the number, the plan, the cycle
    5dive goal add "<outcome>" --project=$key
    5dive team import <template>            # provision the teammates who do the work

NEXT
  else
    ok "company '$cname' created (project $key, objective '$outcome')" \
       '{company:$c, project:$k, prefix:$p, objective:$o}' \
       --arg c "$cname" --arg k "$key" --arg p "$prefix" --arg o "$outcome"
  fi
}
