# cmd_reflex_pick_ref — reflex drafts ONE recipe step by picking a snapshot ref, in SHADOW (DIVE-4929).
#
#   5dive reflex pick-ref <site> --tree=<tree.json> --op=<op> --intent="<what the step is for>"
#                         [--value=<v>] [--key=<k>] [--path=<p>]
#                         [--backend=fake:first|<command>] [--timeout=<s>] [--json]
#
# WHY. An adapter action is a closed list of steps (goto fill click wait_for
# select upload press) that replays exactly, and today a person writes every
# one. `5dive browser snapshot <site> <url>` already lists the page's
# addressable nodes as SEMANTIC refs (`ref=button/Send`, `ref=textbox/To`),
# and `run` resolves a ref as a step's selector. So a step is one choice: WHICH
# ref. That is the whole job here.
#
# THE SAME HYBRID AS `login-marker`. The CODE decides what is legal: only nodes
# whose role can take this op (a `fill` never lands on a button), with a
# non-empty accessible name of at most 80 characters. The MODEL picks one key,
# or `none`. The code writes the step. There is no free-form click and no
# selector the model wrote: the step's selector is `ref=<the picked ref>`,
# copied from the tree.
#
# SHADOW. The step is printed, never written into an adapter, and receipted as
# decision.browser-recipe-step (mode=shadow, a hash of the ref, no names and no
# intent text). A step whose op is click or press and whose intent or target
# reads as publishing, sending, paying, buying, deleting or submitting is
# flagged `review_required`. Such a recipe is shown to a person before its
# first run ("show before anything leaves").
#
# WHAT LEAVES THE BOX. The intent the caller wrote, the op, and each candidate's
# role, accessible name and ref. Never the page. Accessible names on a
# signed-in page can be the account's own content (a contact's name on a link),
# which is why names are capped and the tree is the interactive nodes only.

_REFLEX_PR_MAX_OPTIONS=40
_REFLEX_PR_NAME_MAX=80
_REFLEX_PR_REVIEW_RE='(send|post|publish|tweet|reply|comment|submit|pay|buy|purchase|order|checkout|delete|remove|transfer|confirm)'

# _reflex_pr_roles <op> -> the roles that op may act on, space-separated
_reflex_pr_roles() {
  case "$1" in
    click)    echo "button link checkbox radio menuitem menuitemcheckbox menuitemradio switch tab treeitem option" ;;
    fill)     echo "textbox searchbox combobox spinbutton" ;;
    select)   echo "combobox listbox" ;;
    press)    echo "textbox searchbox combobox button link" ;;
    upload)   echo "button" ;;
    wait_for) echo "button link textbox searchbox checkbox radio combobox listbox option menuitem menuitemcheckbox menuitemradio switch slider spinbutton tab treeitem" ;;
    *) return 1 ;;
  esac
}

_reflex_pick_ref() {
  local site="" tree="" op="" intent="" value="" key="" path="" backend="builtin" to=30 a
  for a in "$@"; do
    case "$a" in
      --tree=*)    tree="${a#*=}" ;;
      --op=*)      op="${a#*=}" ;;
      --intent=*)  intent="${a#*=}" ;;
      --value=*)   value="${a#*=}" ;;
      --key=*)     key="${a#*=}" ;;
      --path=*)    path="${a#*=}" ;;
      --backend=*) backend="${a#*=}" ;;
      --timeout=*) to="${a#*=}" ;;
      --json)      JSON_MODE=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$site" ]] || fail "$E_USAGE" "one site only (got: $site and $a)"; site="$a" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "jq is required"
  [[ -n "$site" && -n "$tree" && -n "$op" && -n "$intent" ]] \
    || fail "$E_USAGE" "usage: 5dive reflex pick-ref <site> --tree=<tree.json from 'browser snapshot'> --op=click|fill|select|press|upload|wait_for --intent=\"<what the step is for>\" [--value=|--key=|--path=] [--backend=fake:first|<command>] [--json]"
  [[ "$site" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || fail "$E_VALIDATION" "site must be a host name like linkedin.com (got: $site)"
  local roles; roles=$(_reflex_pr_roles "$op") || fail "$E_VALIDATION" "--op must be one of click fill select press upload wait_for (got: $op). goto takes a URL, not a ref."
  (( ${#intent} <= 200 )) || fail "$E_VALIDATION" "--intent is at most 200 characters: say what the step is for, not the whole task"
  case "$op" in
    fill|select) [[ -n "$value" ]] || fail "$E_USAGE" "--op=$op needs --value=<text or {placeholder}>" ;;
    press)       [[ -n "$key" ]]   || fail "$E_USAGE" "--op=press needs --key=<key, e.g. Enter>" ;;
    upload)      [[ -n "$path" ]]  || fail "$E_USAGE" "--op=upload needs --path=<file or {placeholder}>" ;;
  esac
  [[ -r "$tree" && -s "$tree" ]] || fail "$E_NOT_FOUND" "tree not readable or empty: $tree"
  jq -e '(.nodes | type) == "array"' "$tree" >/dev/null 2>&1 || fail "$E_VALIDATION" "not a snapshot tree (no .nodes array): $tree"
  [[ "$to" =~ ^[1-9][0-9]{0,2}$ ]] || fail "$E_VALIDATION" "--timeout must be 1-999 seconds"
  case "$backend" in
    builtin|fake:first) ;;
    fake:*) fail "$E_VALIDATION" "unknown fake backend: $backend (fake:first)" ;;
    "") fail "$E_VALIDATION" "--backend is empty" ;;
  esac
  local model=""
  if [[ "$backend" == builtin ]]; then
    reflex_model_resolve; model="$_REFLEX_MODEL"
    [[ -r "$(_reflex_key_file)" ]] \
      || fail "$E_PERMISSION" "the reflex key ($(_reflex_key_file)) is not readable by $(id -un). Run it as root (sudo 5dive reflex pick-ref ...), or pass --backend=fake:first."
  fi

  # The legal set: document order, the op's roles, a usable name, deduped by ref.
  local cands
  cands=$(jq -c --arg roles "$roles" --argjson nmax "$_REFLEX_PR_NAME_MAX" --argjson max "$_REFLEX_PR_MAX_OPTIONS" '
    ($roles | split(" ")) as $r
    | [ .nodes[] | objects
        | select((.ref | type) == "string" and (.ref | length) > 0 and (.ref | length) <= 200)
        | select((.role // "") as $x | $r | index([$x]) != null)
        | select((.name // "") | type == "string" and length > 0 and length <= $nmax)
        | {ref, role, name} ]
    | reduce .[] as $n ([]; if any(.[]; .ref == $n.ref) then . else . + [$n] end)
    | .[0:$max] | to_entries | map(.value + {key: "r\(.key + 1)"})' "$tree")

  local req
  req=$(jq -c --arg site "$site" --arg op "$op" --arg intent "$intent" '
    . as $c
    | {policy: "browser-recipe-step", version: 1, type: "choice",
       state: {site: $site, op: $op, intent: $intent},
       instructions: "One step of a browser recipe on \($site) will \($op) an element. The step is for: \($intent). Each option is an element on the page, by its role and accessible name. Pick the element this step should \($op). Answer none if no option is clearly it.",
       criteria: (($c | map({key: .key, value: "\(.role) \"\(.name)\"  (ref=\(.ref))"}) | from_entries)
                  + {none: "None of these elements is the one this step needs."}),
       options: (($c | map(.key)) + ["none"])}' <<<"$cands")
  local d
  if [[ "$(jq 'length' <<<"$cands")" == 0 ]]; then
    d='{"choice":"none","confidence":null,"error":"no_candidates"}'
  else
    d=$(_reflex_lm_decide "$backend" "$to" "$model" "$req")
  fi

  local report
  report=$(jq -nc --arg site "$site" --arg op "$op" --arg intent "$intent" --arg value "$value" --arg key "$key" --arg path "$path" \
      --arg backend "$backend" --arg model "$model" --arg rre "$_REFLEX_PR_REVIEW_RE" \
      --argjson c "$cands" --argjson d "$d" '
    ($c | map(select(.key == $d.choice)) | .[0]) as $p
    | {site: $site, op: $op, mode: "shadow", written: false,
       backend: (if $backend == "builtin" then "openrouter" else $backend end),
       model: (if $model == "" then null else $model end),
       candidates: $c, choice: $d.choice, confidence: $d.confidence, error: $d.error,
       ref: ($p.ref // null),
       step: (if $p == null then null else
         ({op: $op, selector: "ref=\($p.ref)"}
          + (if $op == "fill" or $op == "select" then {value: $value} else {} end)
          + (if $op == "press" then {key: $key} else {} end)
          + (if $op == "upload" then {path: $path} else {} end)) end),
       review_required: (($op == "click" or $op == "press")
          and (($intent | test($rre; "i")) or (($p.name // "") | test($rre; "i"))))}')

  local rh; rh=$(jq -r '.ref // empty' <<<"$report")
  if [[ -n "$rh" ]]; then rh="sha256:$(printf '%s' "$rh" | sha256sum | cut -c1-16)"; fi
  reflex_receipt policy=browser-recipe-step mode=shadow result="$(jq -r '.choice' <<<"$report")" \
    candidates="$(jq -r '[.candidates[].key] + ["none"] | join(",")' <<<"$report")" \
    confidence="$(jq -c '.confidence' <<<"$report")" \
    fallback="$(jq -r '.error != null' <<<"$report")" \
    signals="$(jq -c '{site, op, n_candidates: (.candidates | length)}' <<<"$report")" \
    backend="$(jq -c '{adapter: (if .backend == "openrouter" then "openrouter" elif (.backend | startswith("fake:")) then .backend else "command" end), model}' <<<"$report")" \
    effect="$(jq -c --arg rh "$rh" '{acted: false, written: false, ref_hash: (if $rh == "" then null else $rh end),
        error, review_required}' <<<"$report")" \
    actor="$(id -un 2>/dev/null || echo unknown)" authority="cli"

  if [[ "${JSON_MODE:-0}" == 1 ]]; then printf '%s\n' "$report"; return 0; fi
  jq -r '
    "reflex pick-ref — \(.site), \(.op)  (shadow: nothing was written)",
    "backend: \(.backend)\(if .model then " " + .model else "" end)",
    (if .step then
       "picked: \(.ref)   (\(.choice) of \(.candidates|length)\(if .confidence != null then ", confidence \(.confidence)" else "" end))",
       "proposed step (NOT written): \(.step | tostring)",
       (if .review_required then "REVIEW REQUIRED: this step publishes, sends, pays or deletes. Show the recipe to a person before its first run." else empty end)
     else "no step proposed\(if .error then " (\(.error))" else "" end) — \(.candidates|length) candidate(s)" end)' <<<"$report"
}
