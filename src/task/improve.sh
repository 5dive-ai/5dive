# -------- 5dive task — self-improving loops (DIVE-8692) --------
#
# Split out of src/task/loops.sh (DIVE-8692, ops merge-stage finding): the engine
# behind `task loop improve <loop> on|off|log|undo|tick` and the run-close kick.
# It is its own LAZY module so the verbs that load loops.sh — `heartbeat ls`,
# `task ls` — never parse it (tests/lazy_dispatch_unit.sh T12 caps heartbeat ls
# at 110% of the eager control). Only `task loop improve` and the run-close hook
# (_loop_score_request, after it has read the switch itself) call into it.
# `task ls --recurring --json` reads the switch and score straight from
# task_prefs in SQL (src/task/crud.sh) and never loads this file.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.

# ───────────── DIVE-8692 self-improving loops: try one change per run, keep it only if it scores better ─────────────
# lodar 2026-11-18: "self-improving for loops". A switch per scheduled loop, off
# by default. With it on, after each run of the loop:
#   1. the run is GRADED 0-100 against what the loop is for: its acceptance
#      criteria, or (none set) 3-5 criteria the grader derives from the loop's
#      own text ONCE and that are then kept fixed, so every run is scored on the
#      same scale. A run that did not end done is not sent to the model: it
#      scores what the runtime gives it (DIVE-5815), and costs nothing;
#   2. a change is on TRIAL (applied before this run was created): this run's
#      score decides it. Higher than the last kept score → KEPT. Otherwise the
#      loop's text goes back to what it was before the change → DROPPED (logged
#      as tried and dropped, never shown as a kept change). Only a run created
#      AFTER the change was applied judges it: a run that was already open ran
#      on the old text;
#   3. no trial open, the score has room (under 90), and this tick did not just
#      drop one: write ONE small change (one find/replace, or one appended
#      sentence, each at most ${_LOOP_IMPROVE_MAX_CHARS} characters) that targets
#      the lowest criterion, and apply it to the loop's text. The next run
#      tries it.
# THE FLOOR. A change may never widen what the loop may do. Any term in the new
# text that the old text did not carry, from the Tier-2 floor `goal add` uses
# (_GATE_T2_FLOOR_RX: spend, publish, email customers, secrets, delete…) or the
# reach list below (post, send, message, a recipient, a link, a tool, a plugin,
# install, buy…), refuses the change. A refused change is logged as refused and
# never applied.
# UNDO. Every kept change can be undone: the loop's text goes back EXACTLY to
# what it was before that change. Kept changes made after it were built on top
# of it, so they are undone with it (the log says which).
# COST. One model call per run (grade + the change together), on the seat that
# closed the run: the loop owner's own AI, headless, no tools, no MCP. Each run's
# grade records what the call cost (total_cost_usd), and `log` shows it.
# State (task_prefs):
#   loop.improve.<tpl ident>        "on" | absent
#   loop.improve.state.<tpl ident>  {"criteria":[…], "kept_score", "first_score",
#                                    "next_id", "graded":{<run>:1}, "runs":[last 20 grades]}
#   loop.improve.log.<tpl ident>    [ {id, at, change, reason, target, status:
#                                    trying|kept|dropped|refused|undone, kept,
#                                    score_before, score_after, run, cost_usd,
#                                    body_before, body_after, applied_at,
#                                    decided_at, undone_at, note} … ]
_LOOP_IMPROVE_ROOM=90         # a run scoring at or above this needs no change
_LOOP_IMPROVE_MAX_CHARS=300   # "small": the find and the replace, each
_LOOP_IMPROVE_RUNS_KEPT=20
_LOOP_IMPROVE_REACH_RX='post|posts|posted|posting|tweet|tweets|reply|replies|comment|comments|send|sends|sent|sending|email|emails|e-mail|mail|message|messages|dm|dms|notify|notifies|telegram|slack|discord|whatsapp|sms|text them|call|phone|recipient|recipients|cc|bcc|forward|share|shares|tool|tools|plugin|plugins|mcp|install|installs|api|apis|webhook|sudo|ssh|buy|buys|purchase|purchases|pay|pays|paid|order|orders|book|subscribe|sign up|signup|register|account|accounts|login|log in'
_LOOP_IMPROVE_PROMPT_HEAD='You improve a recurring agent job one small step at a time. Grade its last run, then propose at most ONE small change to its instructions.'

# DIVE-9171: _LOOP_IMPROVE_MODE=weekly is the once-a-week turn src/task/heal.sh
# starts for an owner-facing loop. Same engine, three differences: it reads the
# week's runs, not one; its one change may only merge or drop text (never append,
# never longer); and its switch is loop.improve.weekly (heal.sh).
_loop_improve_on() {
  [[ "$(_loop_pref_get "loop.improve.${1}")" == "on" ]] && return 0
  [[ "${_LOOP_IMPROVE_MODE:-}" == "weekly" ]] && _loop_improve_call _loop_heal_weekly_on "$1"
}
_loop_improve_state() { local s; s=$(_loop_pref_get "loop.improve.state.${1}"); jq -e 'type=="object"' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '{}'; }
_loop_improve_log() { local s; s=$(_loop_pref_get "loop.improve.log.${1}"); jq -e 'type=="array"' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '[]'; }

# Words that LIMIT what a loop may do, matched as STEMS ("approv" catches
# approve, approved, approval; "until approved" -> "until 9am" moves no exact
# word). A sentence that carries one is READ-ONLY to the improver: the meaning of
# a limit lives in the words around it ("Do not send it." -> "Do not hesitate to
# send it." keeps every word and flips it), so no word count can guard an edit
# of it (quinn, DIVE-8692 it3).
_LOOP_IMPROVE_LIMIT_RX="never|not|no|none|nothing|nobody|nowhere|nor|don't|dont|doesn't|do not|does not|cannot|can't|won't|mustn't|must not|shouldn't|should not|only|just|at most|up to|max|maximum|limit[a-z]*|within|without|unless|except[a-z]*|avoid[a-z]*|forbid[a-z]*|refus[a-z]*|stop[a-z]*|ask first|approv[a-z]*|confirm[a-z]*|review[a-z]*|until|till|before|after|wait[a-z]*|once|draft[a-z]*|permission[a-z]*|allow[a-z]*|may|must"
# Words that set a limit ASIDE. An appended "Ignore the rule above." carries no
# floor or reach word and undoes every limit in the loop, so these are refused
# on the add side like reach is.
_LOOP_IMPROVE_OVERRIDE_RX="ignor[a-z]*|disregard[a-z]*|overrid[a-z]*|bypass[a-z]*|regardless|no longer|anyway|exempt[a-z]*|waive[a-z]*|skip the rule|skip the check"

# _loop_improve_terms <rx> <text> -> "count term" lines, lower-cased.
_loop_improve_terms() {
  grep -oiwE -- "$1" <<<"$2" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -c
}

# _loop_improve_sentence <body> <find> -> the whole sentence(s) of <body> that
# <find> touches, or <find> itself when it does not occur. "it." in "Do not send
# it." touches the limit sentence even though "it." carries no limit word.
# Where a sentence ENDS is read on the whole body, never on the find alone
# (quinn, DIVE-8692 it4): only at . ! ? followed by whitespace or the end of the
# text, so "$5.00", "v2.1" or a URL never cuts one; never after an abbreviation
# or a lone letter ("e.g. Bob and Ann" stays with the limit it names); and at a
# newline only when it opens a blank line, so a limit written as a list ("Never
# email these customers:" then "- Acme" / "- Globex") or hard-wrapped over lines
# is one unit. Every rule errs toward a LONGER unit: merging two sentences only
# makes more text read-only, splitting one makes limit text editable.
_LOOP_IMPROVE_ABBR_RX='^([a-z]|e\.g|i\.e|etc|vs|approx|incl|excl|esp|cf|ca|no|nr|nos|mr|mrs|ms|dr|st|inc|ltd|co|corp|jr|sr|min|max|fig|ref|dept|est|appt|tel)$'
_loop_improve_sentence_end() {   # <body> <i> -> rc 0 when a sentence ends at char i
  local b="$1" i="$2" c nx w j
  c="${b:i:1}"
  if [[ "$c" == $'\n' ]]; then
    # The newline that opens a blank line (only spaces/tabs until the next newline or the end).
    nx="${b:i+1}"; nx="${nx%%$'\n'*}"
    [[ -z "${nx//[[:blank:]]/}" ]]; return
  fi
  [[ "$c" == [.!?] ]] || return 1
  nx="${b:i+1:1}"
  [[ -z "$nx" || "$nx" == [[:space:]] ]] || return 1
  [[ "$c" == "." ]] || return 0
  # The word the dot closes, dots inside it kept ("e.g", "i.e").
  j=$i; w=""
  while (( j > 0 )) && [[ "${b:j-1:1}" == [[:alpha:].] ]]; do w="${b:j-1:1}$w"; ((j--)); done
  w="${w,,}"; w="${w%.}"
  [[ -n "$w" && "$w" =~ $_LOOP_IMPROVE_ABBR_RX ]] && return 1
  return 0
}
# A unit that introduces what follows it (quinn, DIVE-8692 it5): text ending in
# ':' ("Never email these customers:") or a markdown heading line. It does NOT
# end at the blank line after it: markdown normally puts one before a list, and
# the list IS the limit. It carries the whole next block (the lines up to the
# following blank line), and list blocks that follow one another are one unit
# too, so a loose list ("- Acme", blank, "- Globex") is never split item by item.
_LOOP_IMPROVE_LIST_RX='^([[:blank:]]+[^[:space:]]|[[:blank:]]*([-*+•>|]|[0-9]+[.)])([[:blank:]]|$))'
_loop_improve_intro() {   # <text> -> rc 0 when it introduces the block after it
  local t="$1" last
  t="${t%"${t##*[![:space:]]}"}"
  [[ "$t" == *: ]] && return 0
  last="${t##*$'\n'}"
  [[ "$last" =~ ^[[:blank:]]*# ]]
}
_loop_improve_listline() { [[ "$1" =~ $_LOOP_IMPROVE_LIST_RX ]]; }
_loop_improve_block_break() {   # <body> <i> -> rc 0 when char i is a newline that opens a blank line
  local b="$1" i="$2" nx
  [[ "${b:i:1}" == $'\n' ]] || return 1
  nx="${b:i+1}"; nx="${nx%%$'\n'*}"
  [[ -z "${nx//[[:blank:]]/}" ]]
}
_loop_improve_sentence() {
  local body="$1" find="$2" pre s e i n k p q gap unit line nfirst carried=0
  [[ -n "$find" && "$body" == *"$find"* ]] || { printf '%s' "$find"; return 0; }
  pre="${body%%"$find"*}"; s=${#pre}; e=$(( s + ${#find} )); n=${#body}
  # Left: just after the last sentence end before the find.
  for (( i = s - 1; i >= 0; i-- )); do _loop_improve_sentence_end "$body" "$i" && break; done
  s=$(( i + 1 ))
  # Right: through the first sentence end at or after the find's last char.
  for (( i = e - 1; i < n; i++ )); do _loop_improve_sentence_end "$body" "$i" && break; done
  (( i >= n )) && i=$(( n - 1 ))
  e=$i
  # Carry LEFT across blank lines: the block before joins when it introduces
  # this one, or when both are list blocks.
  while :; do
    # p: the start of the block s sits in (a sentence end mid-block is no stop:
    # an intro carries its WHOLE next block, "Acme. Initech too." included).
    for (( p = s - 1; p >= 0; p-- )); do _loop_improve_block_break "$body" "$p" && break; done
    p=$(( p + 1 )); while (( p < n )) && [[ "${body:p:1}" == [[:space:]] ]]; do p=$(( p + 1 )); done
    k=$(( p - 1 )); while (( k >= 0 )) && [[ "${body:k:1}" == [[:space:]] ]]; do k=$(( k - 1 )); done
    (( k >= 0 )) || break
    gap="${body:k+1:p-k-1}"; gap="${gap//[^$'\n']/}"
    (( ${#gap} >= 2 )) || break                       # not at a block start
    for (( q = k; q >= 0; q-- )); do _loop_improve_block_break "$body" "$q" && break; done
    q=$(( q + 1 ))                                    # start of the block before
    unit="${body:q:k-q+1}"; line="${unit##*$'\n'}"
    nfirst="${body:p}"; nfirst="${nfirst%%$'\n'*}"
    if _loop_improve_intro "$unit" || { _loop_improve_listline "$line" && _loop_improve_listline "$nfirst"; }; then
      s=$q; carried=1; continue
    fi
    break
  done
  # Once a carry joined blocks, the unit is whole blocks: the rest of the block
  # the find sits in comes with it ("The list:", blank, "Acme. Initech. Never Globex.").
  if (( carried )); then
    for (( q = e; q < n; q++ )); do _loop_improve_block_break "$body" "$q" && break; done
    (( q >= n )) && q=$n
    e=$(( q - 1 ))
  fi
  # Carry RIGHT the same way: an intro takes the whole next block; a list block
  # takes the list block after it.
  while :; do
    k=$e; while (( k >= s )) && [[ "${body:k:1}" == [[:space:]] ]]; do k=$(( k - 1 )); done
    p=$(( k + 1 )); while (( p < n )) && [[ "${body:p:1}" == [[:space:]] ]]; do p=$(( p + 1 )); done
    (( p < n )) || break
    gap="${body:k+1:p-k-1}"; gap="${gap//[^$'\n']/}"
    (( ${#gap} >= 2 )) || break                       # the unit ended at a sentence end, mid-block
    unit="${body:s:k-s+1}"; line="${unit##*$'\n'}"
    nfirst="${body:p}"; nfirst="${nfirst%%$'\n'*}"
    if _loop_improve_intro "$unit" || { _loop_improve_listline "$line" && _loop_improve_listline "$nfirst"; }; then
      for (( q = p; q < n; q++ )); do _loop_improve_block_break "$body" "$q" && break; done
      (( q >= n )) && q=$n
      e=$(( q - 1 )); continue
    fi
    break
  done
  local out="${body:s:e-s+1}"
  out="${out#"${out%%[![:space:]]*}"}"
  printf '%s' "${out%"${out##*[![:space:]]}"}"
}

# _loop_improve_widens <loop's current text> <new text> [<the text it replaces>]
# -> prints what widens (rc 0), or nothing (rc 1).
#  - READ-ONLY: the sentence the change rewrites (the find text widened to its
#    sentence) may carry NO floor, reach or limit term. Limit text is never the
#    improver's to edit, only to leave alone; it may append, and edit OTHER
#    sentences. The nouns price/prices/pricing are exempt: a watch loop reads them.
#  - ADDS: a floor, reach or override term (or a recipient/link) the new text
#    carries. An append replaces nothing and a rewrite replaces only term-free
#    text, so any such term in the new text is new reach. Presence elsewhere in
#    the loop is NOT scope: in "Draft a reply. Do not send it." the word "send" is
#    there BECAUSE it is forbidden (quinn, DIVE-8692 it2).
_loop_improve_widens() {
  local cur="$1" new="${2,,}" gone="${3:-}" rx term terms n o
  new="${new//’/\'}"
  if [[ -n "${gone//[[:space:]]/}" ]]; then
    gone=$(_loop_improve_sentence "$cur" "$gone"); gone="${gone,,}"; gone="${gone//’/\'}"
    for rx in "$_LOOP_IMPROVE_LIMIT_RX" "$_GATE_T2_FLOOR_RX" "$_LOOP_IMPROVE_REACH_RX" "$_LOOP_IMPROVE_OVERRIDE_RX"; do
      [[ -n "$rx" ]] || continue
      terms=$(_loop_improve_terms "$rx" "$gone") || terms=""
      while read -r n term; do
        [[ -n "$term" ]] || continue
        [[ "$term" =~ ^(price|prices|pricing)$ ]] && continue
        printf '"%s" is in the sentence it would rewrite (limit text is read-only)' "$term"; return 0
      done <<<"$terms"
    done
    # A recipient or a link in the rewritten sentence is reach too.
    local r0
    for r0 in '[[:alnum:]._%+-]+@[[:alnum:].-]+' '@[[:alnum:]_]{3,}' 'https?://[^[:space:]]+'; do
      term=$(grep -oE -- "$r0" <<<"$gone" 2>/dev/null | head -n1) || term=""
      [[ -n "$term" ]] && { printf '"%s" is in the sentence it would rewrite (limit text is read-only)' "$term"; return 0; }
    done
  fi
  for rx in "$_GATE_T2_FLOOR_RX" "$_LOOP_IMPROVE_REACH_RX" "$_LOOP_IMPROVE_OVERRIDE_RX"; do
    [[ -n "$rx" ]] || continue
    terms=$(_loop_improve_terms "$rx" "$new") || terms=""
    while read -r n term; do
      [[ -n "$term" ]] || continue
      # "price" names a thing a watch loop READS; it grants no spend. Every spend
      # ACT (buy, pay, purchase, order, charge, subscribe, a $ amount) is still
      # counted, so "End with the lowest price in bold." is not refused while
      # "Then buy the cheapest one." is.
      [[ "$term" =~ ^(price|prices|pricing)$ ]] && continue
      printf '"%s" added' "$term"; return 0
    done <<<"$terms"
  done
  # A recipient or a link is reach whatever word introduces it.
  local r
  for r in '[[:alnum:]._%+-]+@[[:alnum:].-]+' '@[[:alnum:]_]{3,}' 'https?://[^[:space:]]+' '\+?[0-9][0-9 ()-]{7,}[0-9]'; do
    term=$(grep -oE -- "$r" <<<"$new" 2>/dev/null | head -n1) || term=""
    [[ -n "$term" ]] && { printf '"%s" added' "$term"; return 0; }
  done
  return 1
}

# _loop_improve_apply_change <body> <find> <replace> -> prints the new body, or
# rc 1 when the change does not land exactly once.
_loop_improve_apply_change() {
  local body="$1" find="$2" repl="$3"
  if [[ -z "$find" ]]; then
    printf '%s\n\n%s' "$body" "$repl"; return 0
  fi
  local rest="${body#*"$find"}"
  [[ "$rest" != "$body" ]] || return 1
  [[ "${rest#*"$find"}" == "$rest" ]] || return 1   # more than once: ambiguous
  printf '%s%s%s' "${body%%"$find"*}" "$repl" "$rest"
}

# The model call. A seam: FIVEDIVE_LOOP_IMPROVE_AI is a command that reads the
# prompt on stdin and prints either the `claude --print --output-format json`
# envelope or the bare JSON answer (the harness injects a stub). Default: a
# headless claude on THIS seat, no tools, no MCP, no session left on disk.
_loop_improve_ai() {
  local cmd="${FIVEDIVE_LOOP_IMPROVE_AI:-}"
  if [[ -z "$cmd" ]]; then
    local _cl; _cl=$(command -v claude 2>/dev/null) || return 3
    cmd="$_cl --print --output-format json --strict-mcp-config --max-turns 1 --model ${FIVEDIVE_LOOP_IMPROVE_MODEL:-haiku}"
    local _help; _help="$("$_cl" --help </dev/null 2>/dev/null)" || true
    grep -qF -- '--no-session-persistence' <<<"$_help" && cmd+=" --no-session-persistence"
  fi
  # A seat's tool shell does not carry the sign-in its unit started with (systemd
  # gives it to the seat's Claude Code, which keeps it out of the commands it
  # runs), so a bare `claude --print` there answers "Not logged in". Read the
  # auth lines from the SAME files the seat's unit loads, in its order (later
  # wins), into the child's ENV, never its argv (wiki:
  # a-headless-seat-turn-passes-env-as-environ-and-reads-is-error).
  (
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
      local seat="${AGENT_NAME:-$(id -un 2>/dev/null)}" f line
      seat="${seat#agent-}"
      for f in "${CONNECTORS_DIR:-/etc/5dive/connectors}/anthropic.env" \
               "/var/lib/5dive/agents.d/${seat}.env" "/var/lib/5dive/agents.d/${seat}-auth.env"; do
        [[ -r "$f" ]] || continue
        while IFS= read -r line; do
          [[ "$line" =~ ^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL)=(.*)$ ]] || continue
          local v="${BASH_REMATCH[2]}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
          export "${BASH_REMATCH[1]}=$v"
        done <"$f"
      done
    fi
    timeout "${FIVEDIVE_LOOP_IMPROVE_TIMEOUT:-180}" bash -c "$cmd" 2>/dev/null
  )
}

# _loop_improve_parse <raw> -> {"answer":{…},"cost_usd":N} or rc 1.
_loop_improve_parse() {
  local raw="$1" inner cost=0
  # `claude --print` exits 0 logged out: the envelope's is_error is the signal.
  jq -e 'type=="object" and .is_error == true' <<<"$raw" >/dev/null 2>&1 && return 1
  if jq -e 'type=="object" and (.result|type)=="string"' <<<"$raw" >/dev/null 2>&1; then
    cost=$(jq -r '.total_cost_usd // .cost_usd // 0 | numbers | . * 1000000 | round / 1000000' <<<"$raw" 2>/dev/null); [[ -n "$cost" ]] || cost=0
    inner=$(jq -r .result <<<"$raw")
  else
    inner="$raw"
  fi
  # Tolerate a fence or a sentence around the object: take the outermost {…}.
  inner=$(python3 -c 'import sys,re;t=sys.stdin.read();a=t.find("{");b=t.rfind("}");print(t[a:b+1] if a>=0 and b>a else "")' <<<"$inner" 2>/dev/null)
  jq -e 'type=="object" and (.overall|type)=="number"' <<<"$inner" >/dev/null 2>&1 || return 1
  jq -cn --argjson a "$inner" --argjson c "$cost" '{answer:$a, cost_usd:$c}'
}

# _loop_improve_prompt <instructions> <criteria json|[]> <run result> <want change 0|1>
_loop_improve_prompt() {
  local body="$1" crit="$2" work="$3" want="$4"
  printf '%s\n\n' "$_LOOP_IMPROVE_PROMPT_HEAD"
  printf 'THE JOB'"'"'S INSTRUCTIONS (what every run is told to do):\n<<<\n%s\n>>>\n\n' "$body"
  if [[ "$(jq 'length' <<<"$crit")" -gt 0 ]]; then
    printf 'CRITERIA (grade each, use these exact names):\n%s\n\n' "$(jq -r '.[] | "- \(.)"' <<<"$crit")"
  else
    printf 'CRITERIA: none are set. Derive 3 to 5 short criteria from the instructions (what a good run of this job delivers). They will be reused for every later run.\n\n'
  fi
  printf 'WHAT THE LAST RUN REPORTED:\n<<<\n%s\n>>>\n\n' "${work:-(nothing reported)}"
  if (( want )) && [[ "${_LOOP_IMPROVE_MODE:-}" == "weekly" ]]; then
    cat <<EOF
This is the weekly review: grade the last run, reading the whole week above. Then propose ONE change that makes the instructions SHORTER or keeps them the same length: merge two lines that say the same thing into one, or drop the weakest line (the one the week shows does not help). Never add a line.
- find: an exact phrase copied from the instructions, at most ${_LOOP_IMPROVE_MAX_CHARS} characters, that appears once; replace: its new, shorter wording ("" to drop it).
- It must NOT widen what the job may do: no new spending or buying, no posting or publishing, no new people or places to send anything to, no new tools, accounts or installs.
- "change" is a label the owner reads on a phone: at most 8 plain words, e.g. "Drops the repeated weather line".
- No line is weak: set "proposal" to null.
EOF
  elif (( want )); then
    cat <<EOF
Then propose ONE small change to the instructions that would raise the LOWEST criterion next run.
- It is either a replacement (find: an exact phrase copied from the instructions, at most ${_LOOP_IMPROVE_MAX_CHARS} characters, that appears once; replace: its new wording, at most ${_LOOP_IMPROVE_MAX_CHARS} characters) or one added sentence (find: "", replace: the sentence).
- It must NOT widen what the job may do: no new spending or buying, no posting or publishing, no new people or places to send anything to, no new tools, accounts or installs. Make the job do its existing work better.
- "change" is a label the owner reads on a phone: at most 8 plain words, e.g. "Checks 12 shops, not 5".
- No good small change: set "proposal" to null.
EOF
  else
    printf 'Do not propose a change: set "proposal" to null.\n'
  fi
  cat <<'EOF'

Reply with ONLY this JSON, no prose:
{"criteria":[{"name":"…","score":0-100,"reason":"one line"}],"overall":0-100,
 "proposal":{"change":"…","reason":"one line","target":"<criterion name>","find":"…","replace":"…"} or null}
Be strict: a criterion with no evidence in the report scores low.
EOF
}

_loop_improve_log_put() { _loop_pref_set "loop.improve.log.${1}" "$2"; }
_loop_improve_state_put() { _loop_pref_set "loop.improve.state.${1}" "$2"; }

# Two per-loop locks. "tick" makes ticks single-flight and is held across the
# model call. "state" guards the loop's text, log and state: the tick takes it
# only to write, and off and undo take it too, so neither ever waits on a model
# call and neither loses its write to a tick that read before it.
_loop_improve_lock() {   # <tident> state|tick -> rc 1 when not had in time
  local f="${TASKS_DIR:-/tmp}/.loop-improve.${1}.lock"
  case "$2" in
    tick) { exec 208>"${f%.lock}.tick.lock"; } 2>/dev/null || return 0
          command -v flock >/dev/null 2>&1 || return 0
          flock -w "${FIVEDIVE_LOOP_IMPROVE_LOCK_WAIT:-30}" 208 ;;
    *)    { exec 207>"$f"; } 2>/dev/null || return 0
          command -v flock >/dev/null 2>&1 || return 0
          flock -w "${FIVEDIVE_LOOP_IMPROVE_LOCK_WAIT:-30}" 207 ;;
  esac
}
_loop_improve_unlock() {
  case "$1" in tick) { exec 208>&-; } 2>/dev/null ;; *) { exec 207>&-; } 2>/dev/null ;; esac
  return 0
}

# _loop_improve_tick <tpl ident> [<run ident>] — grade the newest closed,
# ungraded run of the loop (or the one named), then keep/drop the trial, then
# maybe start the next one. Single-flight per loop. Idempotent per run.
_loop_improve_tick() {
  local tident="$1" tid
  tid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$tident") AND ${_LOOP_TPL_PRED};")
  [[ -n "$tid" ]] || { printf 'not a loop: %s\n' "$tident"; return 1; }
  _loop_improve_on "$tident" || { printf 'self-improvement is off for %s\n' "$tident"; return 0; }
  _loop_improve_lock "$tident" tick || { printf 'another tick holds %s\n' "$tident"; return 0; }
  local rc=0
  _loop_improve_tick_locked "$tid" "$@" || rc=$?
  _loop_improve_unlock tick
  return "$rc"
}

# DIVE-8718: what the RUNTIME knows about a run that its own report cannot be
# trusted to say. Today one case: an agent's "Check in with you" loop, whose
# grade must carry how the owner took the last message it sent before this run
# (acted on it / said not now / no answer), read from `agent proactive`'s log,
# not from the run's text. Prints '' for every other loop.
_loop_improve_runtime_note() {
  local tident="$1" rcreated="$2" name entry
  name=$(_loop_pref_get "proactive.tpl.${tident}")
  [[ -n "$name" ]] || return 0
  entry=$(_loop_pref_get "proactive.log.${name}")
  jq -e 'type=="array"' <<<"$entry" >/dev/null 2>&1 || entry='[]'
  entry=$(jq -c --arg c "$rcreated" '[.[] | select(.at < $c)] | last // empty' <<<"$entry")
  printf '\n\nFROM THE RUNTIME (not the run): '
  if [[ -z "$entry" ]]; then
    printf 'no check-in message was sent before this run.'
    return 0
  fi
  local r at; r=$(jq -r '.reaction // ""' <<<"$entry"); at=$(jq -r .at <<<"$entry")
  case "$r" in
    acted)   printf 'the owner ACTED ON the last check-in message (sent %s UTC).' "$at" ;;
    not-now) printf 'the owner said NOT NOW to the last check-in message (sent %s UTC).' "$at" ;;
    *)       printf 'the owner has NOT ANSWERED the last check-in message (sent %s UTC).' "$at" ;;
  esac
}

# Phase 1: read a snapshot and grade the run (the model call), holding only the
# tick lock. Phase 2 (_loop_improve_commit) writes under the state lock.
_loop_improve_tick_locked() {
  local tid="$1" tident="$2" want_run="${3:-}"
  local state log body0; state=$(_loop_improve_state "$tident"); log=$(_loop_improve_log "$tident")
  body0=$(db "SELECT body FROM tasks WHERE id=${tid};")
  local run_sql="r.from_template_id=${tid} AND r.status IN ('done','cancelled')"
  [[ -n "$want_run" ]] && run_sql+=" AND r.ident=$(sqlq "$want_run")"
  local row rid rident rst rcreated rbody rwork
  row=$(db "SELECT r.id||x'1f'||r.ident||x'1f'||r.status||x'1f'||r.created_at FROM tasks r WHERE ${run_sql} ORDER BY r.id DESC LIMIT 1;")
  [[ -n "$row" ]] || { printf 'no closed run of %s to grade\n' "$tident"; return 0; }
  IFS=$'\x1f' read -r rid rident rst rcreated <<<"$row"
  if jq -e --arg r "$rident" '(.graded // {})[$r] != null' <<<"$state" >/dev/null 2>&1; then
    printf '%s already graded\n' "$rident"; return 0
  fi
  rbody=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${rid};")
  rwork=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${rid};")
  rwork+=$(_loop_improve_runtime_note "$tident" "$rcreated")
  if [[ "${_LOOP_IMPROVE_MODE:-}" == "weekly" ]]; then
    rwork+=$'\n\nTHE WEEK (newest first; each run, how it ended, what it reported):\n'
    rwork+=$(_loop_improve_call _loop_heal_week_digest "$tid")
  fi

  # Which criteria. The loop's own, else the ones derived on the first tick.
  local crit accept derived=""
  accept=$(db "SELECT COALESCE(acceptance_criteria,'') FROM tasks WHERE id=${tid};")
  if [[ -n "${accept//[[:space:]]/}" ]]; then
    crit=$(jq -Rn --arg a "$accept" '[$a | split("\n")[] | sub("^[-*0-9.) ]+";"") | select(length>0)]')
  else
    crit=$(jq -c '.criteria // []' <<<"$state")
  fi

  # Is a trial open, and does THIS run judge it (created after it applied)?
  local trial tri_id="" judges=0
  trial=$(jq -c '[.[] | select(.status=="trying")] | last // empty' <<<"$log")
  if [[ -n "$trial" ]]; then
    tri_id=$(jq -r .id <<<"$trial")
    [[ "$(db "SELECT julianday($(sqlq "$rcreated")) >= julianday($(sqlq "$(jq -r .applied_at <<<"$trial")"));")" == "1" ]] && judges=1
  fi

  # Grade. A run that did not end done is scored by the runtime, at no cost.
  # Ask for a change too when one may follow this run: no trial open, or this
  # run decides it (a kept change is built on; a dropped one's proposal is
  # discarded, since it was written against the text being taken back).
  local score cost=0 answer='{}' want=0
  if [[ -z "$trial" ]] || (( judges )); then want=1; fi
  if [[ "$rst" != "done" ]]; then
    [[ -n "$(_loop_pref_get "loop.score.${rident}")" ]] || _loop_first_score "$rid"
    score=$(_loop_pref_get "loop.score.${rident}" | jq -r '.score // 0')
    want=0
  else
    local raw parsed
    raw=$(_loop_improve_prompt "$rbody" "$(jq -c '[.[] | if type=="object" then .name else . end]' <<<"$crit")" "$rwork" "$want" | _loop_improve_ai) || raw=""
    if ! parsed=$(_loop_improve_parse "$raw"); then
      printf 'could not grade %s: the AI gave no usable answer (%s)\n' "$rident" "$(_loop_clip "${raw:-no output}")"
      return 1
    fi
    answer=$(jq -c .answer <<<"$parsed"); cost=$(jq -r .cost_usd <<<"$parsed")
    score=$(jq -r '.overall | if . < 0 then 0 elif . > 100 then 100 else (.|round) end' <<<"$answer")
    if [[ "$(jq 'length' <<<"$crit")" == "0" ]]; then
      derived=$(jq -c '[.criteria[]? | .name | strings | select(length>0)] | .[0:5]' <<<"$answer")
    fi
  fi

  if ! _loop_improve_lock "$tident" state; then
    printf 'could not record %s: the loop stayed busy (off or undo holding it)\n' "$rident"; return 1
  fi
  local rc=0
  _loop_improve_commit "$tid" "$tident" "$rident" "$rst" "$tri_id" "$judges" "$want" "$body0" \
                       "$score" "$cost" "$answer" "$derived" || rc=$?
  _loop_improve_unlock state
  return "$rc"
}

# Phase 2, under the state lock: everything is re-read here. The model call
# took seconds to minutes and off, undo or a hand edit may have landed in it.
_loop_improve_commit() {
  local tid="$1" tident="$2" rident="$3" rst="$4" tri_id="$5" judges="$6" want="$7" body0="$8"
  local score="$9" cost="${10}" answer="${11}" derived="${12}"
  # Turned off during the grade: off already took back any trial. Apply nothing.
  if ! _loop_improve_on "$tident"; then
    printf '%s: self-improving was turned off while %s was graded; nothing applied\n' "$tident" "$rident"
    return 0
  fi
  # Test seam: hold the commit window open, so a harness can land off/undo in
  # it and see them wait for the lock instead of losing their write.
  [[ -n "${FIVEDIVE_LOOP_IMPROVE_COMMIT_HOLD:-}" ]] && sleep "$FIVEDIVE_LOOP_IMPROVE_COMMIT_HOLD"
  local state log; state=$(_loop_improve_state "$tident"); log=$(_loop_improve_log "$tident")
  if jq -e --arg r "$rident" '(.graded // {})[$r] != null' <<<"$state" >/dev/null 2>&1; then
    printf '%s already graded\n' "$rident"; return 0
  fi
  if [[ -n "$derived" && "$(jq '.criteria // [] | length' <<<"$state")" == "0" ]]; then
    state=$(jq -c --argjson c "$derived" '.criteria = $c' <<<"$state")
  fi
  local now; now=$(db "SELECT datetime('now');")
  local verdict="graded" trial cur
  trial=$(jq -c '[.[] | select(.status=="trying")] | last // empty' <<<"$log")
  cur=$(db "SELECT body FROM tasks WHERE id=${tid};")
  # The loop moved under the grade (an undo, an off-and-on, a hand edit): the
  # score belongs to text that is no longer there. Record the run; decide nothing.
  local cur_tri=""; [[ -n "$trial" ]] && cur_tri=$(jq -r .id <<<"$trial")
  if [[ "$cur_tri" != "$tri_id" || "$cur" != "$body0" ]]; then
    trial=""; want=0; judges=0
    verdict="the loop changed while this run was graded; recorded only, nothing decided"
  else
    local kept_score; kept_score=$(jq -r '.kept_score // empty' <<<"$state")
    # Decide the trial.
    if [[ -n "$trial" ]] && (( judges )); then
      local base; base=$(jq -r '.score_before // empty' <<<"$trial")
      if [[ -n "$base" ]] && (( score > base )); then
        log=$(jq -c --argjson i "$tri_id" --argjson s "$score" --arg r "$rident" --arg at "$now" \
          'map(if .id == $i then .status="kept" | .kept=true | .score_after=$s | .run=$r | .decided_at=$at else . end)' <<<"$log")
        state=$(jq -c --argjson s "$score" '.kept_score = $s' <<<"$state")
        verdict="kept #${tri_id} (${base} → ${score})"
      else
        local after note="reverted"
        after=$(jq -r .body_after <<<"$trial")
        if [[ "$cur" == "$after" ]]; then
          db "UPDATE tasks SET body=$(sqlq "$(jq -r .body_before <<<"$trial")") WHERE id=${tid};"
        else
          note="instructions were changed by hand meanwhile; left as they are"
        fi
        log=$(jq -c --argjson i "$tri_id" --argjson s "$score" --arg r "$rident" --arg at "$now" --arg n "$note" \
          'map(if .id == $i then .status="dropped" | .kept=false | .score_after=$s | .run=$r | .decided_at=$at | .note=$n else . end)' <<<"$log")
        verdict="dropped #${tri_id} (${base:-?} → ${score}, ${note})"
        want=0   # the next run re-measures the restored text first
      fi
      trial=""
    elif [[ -z "$trial" ]]; then
      # No trial: this run measured the kept text. It is the new bar.
      state=$(jq -c --argjson s "$score" '.kept_score = $s' <<<"$state")
    fi
    state=$(jq -c --argjson s "$score" '.first_score = (.first_score // $s)' <<<"$state")
    [[ -n "$(jq -r '.kept_score // empty' <<<"$state")" ]] && kept_score=$(jq -r .kept_score <<<"$state")

    # Maybe start the next trial.
    local proposal; proposal=$(jq -c '.proposal // empty | objects' <<<"$answer")
    if (( want )) && [[ -z "$trial" && -n "$proposal" ]] && (( score < _LOOP_IMPROVE_ROOM )); then
      local find repl change reason target new widened id
      find=$(jq -r '.find // ""' <<<"$proposal"); repl=$(jq -r '.replace // ""' <<<"$proposal")
      change=$(jq -r '.change // ""' <<<"$proposal"); reason=$(jq -r '.reason // ""' <<<"$proposal")
      target=$(jq -r '.target // ""' <<<"$proposal")
      id=$(jq -r '.next_id // 1' <<<"$state"); state=$(jq -c '.next_id = ((.next_id // 1) + 1)' <<<"$state")
      cur=$(db "SELECT body FROM tasks WHERE id=${tid};")
      local status="trying" why=""
      local weekly=0; [[ "${_LOOP_IMPROVE_MODE:-}" == "weekly" ]] && weekly=1
      if (( weekly )) && [[ -z "$find" ]]; then status="refused"; why="the weekly change may only merge or drop text, never add a line"
      elif (( weekly )) && [[ -z "${change//[[:space:]]/}" ]]; then status="refused"; why="empty change"
      elif (( ! weekly )) && [[ -z "${repl//[[:space:]]/}" || -z "${change//[[:space:]]/}" ]]; then status="refused"; why="empty change"
      elif (( ${#find} > _LOOP_IMPROVE_MAX_CHARS || ${#repl} > _LOOP_IMPROVE_MAX_CHARS )); then status="refused"; why="not a small change (over ${_LOOP_IMPROVE_MAX_CHARS} characters)"
      elif widened=$(_loop_improve_widens "$cur" "$repl" "$find"); then status="refused"; why="would widen what the loop may do: ${widened}"
      elif ! new=$(_loop_improve_apply_change "$cur" "$find" "$repl"); then status="refused"; why="the text to change is not in the instructions exactly once"
      elif [[ "$new" == "$cur" ]]; then status="refused"; why="no change"
      elif (( weekly )) && (( ${#new} > ${#cur} )); then status="refused"; why="the weekly change would make the instructions longer"
      fi
      if [[ "$status" == "trying" ]]; then
        db "UPDATE tasks SET body=$(sqlq "$new") WHERE id=${tid};"
        verdict+="; trying #${id}: ${change}"
      else
        new=""; verdict+="; refused a change (${why})"
      fi
      log=$(jq -c --argjson i "$id" --arg at "$now" --arg c "${change:0:80}" --arg rs "$reason" --arg tg "$target" \
            --arg st "$status" --argjson sb "${kept_score:-$score}" --arg r "$rident" --argjson cost "$cost" \
            --arg bb "$cur" --arg ba "$new" --arg n "$why" \
        '. + [{id:$i, at:$at, change:$c, reason:$rs, target:$tg, status:$st, kept:(if $st=="trying" then null else false end),
               score_before:$sb, score_after:null, from_run:$r, cost_usd:$cost,
               body_before:$bb, body_after:(if $st=="trying" then $ba else null end),
               applied_at:(if $st=="trying" then $at else null end)} + (if $n != "" then {note:$n} else {} end)]' <<<"$log")
    fi
  fi

  local crit_scores; crit_scores=$(jq -c '[.criteria[]? | {name, score}]' <<<"$answer" 2>/dev/null) || crit_scores='[]'
  state=$(jq -c --arg r "$rident" --arg at "$now" --argjson s "$score" --argjson c "$cost" --argjson cs "${crit_scores:-[]}" \
          --arg st "$rst" --argjson keep "$_LOOP_IMPROVE_RUNS_KEPT" \
    '.graded = ((.graded // {}) + {($r):1})
     | .runs = (((.runs // []) + [{run:$r, at:$at, status:$st, score:$s, criteria:$cs, cost_usd:$c}]) | .[-$keep:])' <<<"$state")
  _loop_improve_state_put "$tident" "$state"
  _loop_improve_log_put "$tident" "$log"
  printf '%s: %s scored %s/100 (AI cost $%s); %s\n' "$tident" "$rident" "$score" "$cost" "$verdict"
}

# Called from _loop_score_request when a run of a loop closes. The tick makes a
# model call, so it runs detached: closing the run never waits on it.
_loop_improve_kick() {
  local tident="$1" rident="$2"
  _loop_improve_on "$tident" || return 0
  if [[ "${FIVEDIVE_LOOP_IMPROVE_SYNC:-0}" == "1" ]]; then
    ( _loop_improve_tick "$tident" "$rident" ) >/dev/null 2>&1 || true
    return 0
  fi
  local self="${FIVEDIVE_SELF:-$(command -v 5dive || echo /usr/local/bin/5dive)}"
  ( setsid nohup "$self" task loop improve "$tident" tick --run="$rident" \
      >>"${TASKS_DIR:-/tmp}/loop-improve.log" 2>&1 </dev/null & ) 2>/dev/null || true
  return 0
}

# _loop_improve_undo <tpl id> <tpl ident> <entry id>
_loop_improve_undo() {
  local tid="$1" tident="$2" eid="$3" log state entry now
  log=$(_loop_improve_log "$tident"); state=$(_loop_improve_state "$tident")
  entry=$(jq -c --argjson i "$eid" '.[] | select(.id == $i)' <<<"$log")
  [[ -n "$entry" ]] || fail "$E_NOT_FOUND" "${tident} has no change #${eid}"
  [[ "$(jq -r .status <<<"$entry")" == "kept" ]] \
    || fail "$E_VALIDATION" "change #${eid} on ${tident} is $(jq -r .status <<<"$entry"), not kept: nothing to undo"
  now=$(db "SELECT datetime('now');")
  db "UPDATE tasks SET body=$(sqlq "$(jq -r .body_before <<<"$entry")") WHERE id=${tid};"
  # Everything kept or on trial after it was built on the text it changed.
  local also
  also=$(jq -c --argjson i "$eid" '[.[] | select(.id > $i and (.status=="kept" or .status=="trying")) | .id]' <<<"$log")
  log=$(jq -c --argjson i "$eid" --arg at "$now" '
    map(if .id == $i then .status="undone" | .kept=false | .undone_at=$at
        elif .id > $i and .status=="kept" then .status="undone" | .kept=false | .undone_at=$at | .note="undone with #\($i), which it was built on"
        elif .id > $i and .status=="trying" then .status="dropped" | .kept=false | .decided_at=$at | .note="stopped: #\($i) was undone"
        else . end)' <<<"$log")
  state=$(jq -c --argjson s "$(jq '.score_before' <<<"$entry")" '.kept_score = $s' <<<"$state")
  _loop_improve_log_put "$tident" "$log"
  _loop_improve_state_put "$tident" "$state"
  UNDO_ALSO="$also"
}

# `task loop improve <loop> on|off|log [--json]|undo <id>|tick [--run=<run>]`
cmd_task_loop_improve() {
  tasks_db_init
  local ref="${1:-}" verb="${2:-}"
  [[ -n "$ref" && -n "$verb" ]] || fail "$E_USAGE" "usage: 5dive task loop improve <loop> on|off|log|undo <id>|tick [--run=<run>]"
  shift 2
  local tid tident
  _loop_tpl_resolve "$ref"; tid="$_LOOP_TID"; tident="$_LOOP_TIDENT"
  case "$verb" in
    on)
      [[ -z "$(_loop_pref_get "loop.outcome.${tident}")" ]] \
        || fail "$E_VALIDATION" "${tident} is scored by its outcome, and its next lane is the owner's call: self-improvement stays off (DIVE-5777)"
      _loop_pref_set "loop.improve.${tident}" on
      ok "self-improving on for ${tident}: after each run it grades the run, tries one small change, and keeps it only if the next run scores higher" \
         '{loop:$t, self_improving:true}' --arg t "$tident" ;;
    weekly)
      # DIVE-9171: once a week, never growing the text. Every-run improving, if
      # it was on, stops first (its open trial is taken back, as `off` does).
      [[ -z "$(_loop_pref_get "loop.outcome.${tident}")" ]] \
        || fail "$E_VALIDATION" "${tident} is scored by its outcome, and its next lane is the owner's call: self-improvement stays off (DIVE-5777)"
      if [[ "$(_loop_pref_get "loop.improve.${tident}")" == "on" ]]; then
        ( cmd_task_loop_improve "$tident" off ) >/dev/null 2>&1 || fail "$E_GENERIC" "${tident} is busy recording a run; try again in a minute"
      fi
      _loop_pref_set "loop.improve.weekly.${tident}" on
      ok "weekly self-improving on for ${tident}: once a week it reads the week's runs and makes at most one change, which only merges or drops a line" \
         '{loop:$t, self_improving:false, weekly_improve:true}' --arg t "$tident" ;;
    off)
      # DIVE-9171: off is off for the weekly turn too (an owner-facing loop
      # has it by default, so off is stored, not deleted).
      _loop_pref_set "loop.improve.weekly.${tident}" off
      # The state lock: a tick mid-grade writes under it too, and re-checks the
      # switch there, so once off holds it no tick can apply anything after.
      _loop_improve_lock "$tident" state || fail "$E_GENERIC" "${tident} is busy recording a run; try again in a minute"
      _loop_pref_del "loop.improve.${tident}"
      # A change still on trial has no run left to judge it: put the text back.
      local log trial; log=$(_loop_improve_log "$tident")
      trial=$(jq -c '[.[] | select(.status=="trying")] | last // empty' <<<"$log")
      if [[ -n "$trial" ]]; then
        [[ "$(db "SELECT body FROM tasks WHERE id=${tid};")" == "$(jq -r .body_after <<<"$trial")" ]] \
          && db "UPDATE tasks SET body=$(sqlq "$(jq -r .body_before <<<"$trial")") WHERE id=${tid};"
        _loop_improve_log_put "$tident" "$(jq -c --argjson i "$(jq .id <<<"$trial")" --arg at "$(db "SELECT datetime('now');")" \
          'map(if .id == $i then .status="dropped" | .kept=false | .decided_at=$at | .note="stopped: self-improving turned off" else . end)' <<<"$log")"
      fi
      _loop_improve_unlock state
      ok "self-improving off for ${tident}; kept changes stay (undo any with: 5dive task loop improve ${tident} undo <id>)" \
         '{loop:$t, self_improving:false}' --arg t "$tident" ;;
    log)
      local json=$JSON_MODE
      [[ "${1:-}" == "--json" ]] && json=1
      local log state view; log=$(_loop_improve_log "$tident"); state=$(_loop_improve_state "$tident")
      view=$(jq -cn --arg t "$tident" --argjson on "$(_loop_improve_on "$tident" && echo true || echo false)" \
             --argjson l "$log" --argjson s "$state" '
        {loop:$t, self_improving:$on,
         improved:([$l[] | select(.status=="kept")] | length),
         score_start:($s.first_score // null), score_now:($s.kept_score // null),
         criteria:($s.criteria // []),
         entries:[$l[] | {id, at, change, reason, target, status, kept, score_before, score_after, cost_usd}
                         + (if .note then {note} else {} end)],
         runs:[($s.runs // [])[] | {run, at, status, score, cost_usd}]}')
      if (( json )); then
        jq -c '{ok:true, data:.}' <<<"$view"
      else
        jq -r '"\(.loop)  self-improving: \(if .self_improving then "on" else "off" end)  ·  improved itself \(.improved) times  ·  score \(.score_start // "-") → \(.score_now // "-")",
               (.entries | reverse[] | "  #\(.id)  \(.at[0:16])  \(.status)\(if .kept then "" else "" end)  \(.change)  (score \(.score_before // "-") → \(.score_after // "…"))\(if .note then "  — \(.note)" else "" end)"),
               (if (.runs|length) > 0 then "  runs:" else empty end),
               (.runs | reverse[] | "    \(.run)  \(.score)/100  AI cost $\(.cost_usd)")' <<<"$view"
      fi ;;
    undo)
      local eid="${1:-}"
      [[ "$eid" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "usage: 5dive task loop improve <loop> undo <id>  (the id from: task loop improve ${tident} log)"
      UNDO_ALSO="[]"
      _loop_improve_lock "$tident" state || fail "$E_GENERIC" "${tident} is busy recording a run; try again in a minute"
      _loop_improve_undo "$tid" "$tident" "$((10#$eid))"
      _loop_improve_unlock state
      local n_also; n_also=$(jq 'length' <<<"$UNDO_ALSO")
      ok "undid change #${eid} on ${tident}: its instructions are back to what they were before it$( (( n_also > 0 )) && printf ' (also undid %s, made on top of it)' "$(jq -r 'map("#\(.)")|join(", ")' <<<"$UNDO_ALSO")")" \
         '{loop:$t, undone:($i|tonumber), also_undone:$a}' --arg t "$tident" --arg i "$eid" --argjson a "$UNDO_ALSO" ;;
    tick)
      local run=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --run=*)  run="${1#--run=}" ;;
          --weekly) _LOOP_IMPROVE_MODE=weekly ;;   # DIVE-9171, started by heal.sh
        esac
        shift
      done
      local out rc=0
      out=$(_loop_improve_tick "$tident" "$run") || rc=$?
      (( rc == 0 )) || fail "$E_GENERIC" "$out"
      ok "$out" '{loop:$t, message:$m}' --arg t "$tident" --arg m "$out" ;;
    *) fail "$E_USAGE" "usage: 5dive task loop improve <loop> on|weekly|off|log [--json]|undo <id>|tick [--run=<run>]" ;;
  esac
}
