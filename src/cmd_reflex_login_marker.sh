# cmd_reflex_login_marker — reflex proposes a site's login check, in SHADOW (DIVE-4928).
#
#   5dive reflex login-marker <site> --logged-out=<html> [--logged-out=<html 2>] [--logged-in=<html>]
#                             [--url=<probe url>] [--spa] [--compare=<adapter.json>]
#                             [--backend=fake:first|<command>] [--timeout=<s>]
#                             [--out=<file>] [--json]
#
# WHY. Every page verb of the browser plugin (read, snapshot, links, shot, run)
# refuses unless the site probes `authenticated`, and that needs an adapter with
# probe.logged_out_when_dom_matches. Four sites ship one. Every other site is
# unreadable until somebody writes one by hand, off a RENDERED logged-out page.
# This verb drafts that marker.
#
# HYBRID: THE CODE PROPOSES AND VERIFIES, THE MODEL ONLY PICKS. Nothing here lets
# a model write a regex, and nothing lets it click.
#   1. The code lists candidate markers from the renders: attribute tokens
#      (form action, input name/type/autocomplete, id, data-testid, class, role,
#      relative href), each written in the shipped adapters' own form,
#      `attr=["']?value` and `class="[^"]*token`.
#   2. The code verifies every candidate against BOTH renders with `grep -iE`,
#      the engine the probe itself uses (browser bin/browser: "two regex engines
#      must never both be allowed to decide a login"). A signed-out candidate must
#      match the signed-out render and must match the signed-in render ZERO times.
#      Given a second signed-out render (--logged-out twice; `5dive browser
#      capture` makes two), it must match EVERY one: a sign-in page carries
#      per-render tokens, and a token only one render has is not a marker.
#   3. The survivors, ranked by a fixed heuristic and capped, are the OPTIONS of
#      one Decisions-API choice. The model returns one key, or `none`. A choice
#      that is not an option falls back to `none`, which proposes nothing.
#
# SHADOW. The proposal is printed (or written to --out) and receipted as
# decision.browser-login-marker with mode=shadow. It is never written to an
# adapter directory, and --out refuses one. It earns trust by --compare: run it
# on a site that already has a hand-written adapter, and the report says whether
# the model's pick, and the heuristic's top pick, agree with the person's marker
# on the same two renders. Jev lost to today's code on routing
# (community/wiki/reflex-first-real-model-replay-...), so the numbers come first.
#
# WITHOUT --logged-in the signed-in half is UNMEASURED: the candidates are not
# filtered on it, and the report and the proposed adapter's _comment say so. That
# is the x.com shipped adapter's position, and it fails safe only for a logged-out
# marker (a false match reads "session expired" and asks a person). The adapter
# must still be measured on both halves before anyone trusts it.
#
# WHAT LEAVES THE BOX. The request carries the site, the probe URL, the
# signed-out page's <title> (a public page) and the candidate markers with their
# match counts. Never the page itself. Signed-in candidates (--spa) come from a
# page that holds the account's own content, so they are restricted to
# class/id/data-testid/role values made of letters, `-` and `_` only: no digits,
# no free text, nothing an account name or id is likely to be.
#
# THE KEY. The built-in backend reads the root-only reflex key
# (/etc/5dive/reflex-openrouter.key), so a real run is `sudo 5dive reflex
# login-marker ...`. --backend=fake:first picks the heuristic's top candidate and
# needs no key: it is the "today's code" baseline the model is compared against.

# The browser's own default challenge marker (bin/browser _site_challenge_marker),
# plus a TITLE test: reddit's interstitial ("Prove your humanity") carries none of
# those tokens, and a bare `captcha` anywhere in the page is too wide (GitHub's
# real sign-in page mentions it in a script).
_REFLEX_LM_CHALLENGE='(g-recaptcha|hcaptcha|cf-challenge|/checkpoint/challenge|two-factor|verify-your-identity)'
_REFLEX_LM_CHALLENGE_TITLE='(captcha|prove your humanity|are you a robot|just a moment|verify you are human|access denied|attention required)'
_REFLEX_LM_MAX_OPTIONS=20
_REFLEX_LM_SHORTLIST=150
_REFLEX_LM_MAX_BYTES=8000000
_REFLEX_LM_OUT_MORE=()

# _reflex_lm_extract <out|in> <file> -> "<score>\t<marker>" lines, best first,
# unverified. Pure text processing; the verification is _reflex_lm_count.
_reflex_lm_extract() {
  local half="$1" f="$2" attrs
  if [[ "$half" == out ]]; then attrs='name|action|id|data-testid|autocomplete|type|href|class|role'
  else attrs='id|data-testid|class|role'; fi
  grep -oiE "(^|[[:space:]<])(${attrs})=(\"[^\"]{1,300}\"|'[^']{1,300}')" "$f" 2>/dev/null \
  | LC_ALL=C awk -v half="$half" '
    function esc(s) { gsub(/\./, "\\.", s); return s }
    function loginish(v) { return tolower(v) ~ /(login|log-in|log_in|signin|sign-in|sign_in|session|passw|username|auth|otp|qr|signup|sign-up|register)/ }
    function emit(score, m) { if (!(m in seen)) { seen[m] = 1; printf "%d\t%s\n", score, m } }
    # A PER-RENDER TOKEN IS NOT A MARKER (DIVE-4929, measured on github.com): the
    # sign-in page carries honeypot fields named required_field_<4 hex> and ids
    # with a UUID, new on every render. One passes the both-halves bar by
    # construction (it is on this signed-out render and on no other page), and as
    # a marker it would never match again, so every expired login would read as
    # signed in. Any segment of 4+ hex characters holding a digit, or any run of 3+
    # digits, is treated as random. The second signed-out render (--logged-out
    # given twice) is the structural check; this is the cheap one.
    function randomish(v,   n, i, seg) {
      if (v ~ /[0-9][0-9][0-9]/) return 1
      n = split(v, seg, /[-_:.\/]/)
      for (i = 1; i <= n; i++) if (seg[i] ~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]+$/ && seg[i] ~ /[0-9]/) return 1
      return 0
    }
    {
      s = $0; sub(/^[[:space:]<]/, "", s)
      eq = index(s, "="); a = tolower(substr(s, 1, eq - 1)); v = substr(s, eq + 2); v = substr(v, 1, length(v) - 1)
      if (a == "class") {
        n = split(v, tok, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          t = tok[i]
          if (half == "out" && t !~ /^[A-Za-z][A-Za-z0-9_-]{2,40}$/) continue
          if (half == "in"  && t !~ /^[A-Za-z][A-Za-z_-]{2,40}$/) continue
          if (randomish(t)) continue
          emit(1 + 10 * loginish(t), "class=\"[^\"]*" esc(t))
        }
        next
      }
      if (a == "action" || a == "href") { sub(/[?#].*/, "", v); if (v !~ /^\//) next; if (a == "href" && length(v) > 40) next }
      if (a == "type") { lv = tolower(v); if (lv != "password" && lv != "email") next; v = lv }
      # <meta name=...> page metadata is on every page of a site, signed in or not.
      if (a == "name" && tolower(v) ~ /^(viewport|robots|referrer|description|keywords|theme-color|format-detection|color-scheme|generator|author|csrf.*|twitter:.*|og:.*|al:.*|fb:.*|apple-.*|msapplication.*|google.*|mobile-web-app-capable)$/) next
      if (half == "out" && v !~ /^[A-Za-z0-9_.\/:-]{1,60}$/) next
      if (half == "in"  && v !~ /^[A-Za-z][A-Za-z_-]{2,40}$/) next
      if (randomish(v)) next
      w = (a == "action") ? 5 : (a == "type") ? 5 : (a == "name") ? 4 : (a == "autocomplete") ? 4 : (a == "data-testid") ? 3 : (a == "id") ? 2 : 1
      emit(w + 10 * loginish(v), a "=[\"'"'"']?" esc(v))
    }' \
  | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | head -n "$_REFLEX_LM_SHORTLIST"
}

# _reflex_lm_count <marker> <file> -> how many times grep -iE matches it
# (grep exits 1 on zero matches, and under the CLI's pipefail that 1 would kill
# the assignment it feeds; zero is an answer here, not a failure.)
_reflex_lm_count() { { grep -oiE -- "$1" "$2" 2>/dev/null || true; } | wc -l | tr -d ' '; }

# _reflex_lm_half <out|in> <out file> <in file|""> -> JSON array of verified
# candidates, [{key, marker, out, in, score}], capped, best first.
_reflex_lm_half() {
  local half="$1" fo="$2" fi_="$3" score m co ci
  {
    while IFS=$'\t' read -r score m; do
      [[ -n "$m" ]] || continue
      co=$(_reflex_lm_count "$m" "$fo")
      if [[ -n "$fi_" ]]; then ci=$(_reflex_lm_count "$m" "$fi_"); else ci=null; fi
      if [[ "$half" == out ]]; then
        (( co >= 1 )) || continue
        [[ "$ci" == null || "$ci" == 0 ]] || continue
      else
        (( ci >= 1 && co == 0 )) || continue
      fi
      # Every EXTRA signed-out render must agree: a signed-out marker must match
      # each of them (stable across renders), and a signed-in one must match none.
      local x ok=1
      for x in "${_REFLEX_LM_OUT_MORE[@]}"; do
        if [[ "$half" == out ]]; then (( $(_reflex_lm_count "$m" "$x") >= 1 )) || { ok=0; break; }
        else (( $(_reflex_lm_count "$m" "$x") == 0 )) || { ok=0; break; }
        fi
      done
      (( ok )) || continue
      jq -cn --arg m "$m" --argjson s "$score" --argjson o "$co" --argjson i "$ci" '{marker:$m, score:$s, out:$o, in:$i}'
    done < <(if [[ "$half" == out ]]; then _reflex_lm_extract out "$fo"; else _reflex_lm_extract in "$fi_"; fi)
  } | jq -sc --argjson max "$_REFLEX_LM_MAX_OPTIONS" --arg half "$half" '
      sort_by(-.score, -(if $half == "out" then .out else .in end), .marker) | .[0:$max]
      | to_entries | map(.value + {key: "m\(.key + 1)"})'
}

# _reflex_lm_request <site> <url> <half> <title> <candidates json> <in-measured bool>
_reflex_lm_request() {
  jq -c --arg site "$1" --arg url "$2" --arg half "$3" --arg title "$4" --argjson inm "$6" '
    . as $c
    | {policy: "browser-login-marker", version: 1, type: "choice",
       state: ({site: $site, probe_url: $url, half: $half, signed_in_render: $inm}
               + (if $half == "logged_out" and $title != "" then {page_title: $title} else {} end)),
       instructions: (if $half == "logged_out" then
         "These are candidate markers for a browser login check on \($site). Each is a regex over the HTML of \($url) as rendered by a signed-out browser. The check reads a match as \"this profile is signed out\". Pick the candidate that most reliably marks the SIGN-IN page itself (a sign-in form, its fields or its action) and will survive a restyle. Avoid styling classes and anything a signed-in page could also contain. Answer none if no candidate is a sign-in marker."
       else
         "These are candidate markers for a browser login check on \($site), a single-page app. Each is a regex over the HTML of \($url) as rendered by a SIGNED-IN browser, and none matches the signed-out render. The check reads a match as \"this profile is signed in\". Pick the candidate that most reliably marks the signed-in app shell (an account menu, the main app container) and will survive a restyle. Answer none if no candidate is a signed-in marker."
       end),
       criteria: (($c | map({key: .key, value: "\(.marker)  (matches \(.out)x signed out, \(if .in == null then "unmeasured" else "\(.in)x" end) signed in)"}) | from_entries)
                  + {none: "None of these is a reliable marker."}),
       options: (($c | map(.key)) + ["none"])}' <<<"$5"
}

# _reflex_lm_decide <backend> <timeout> <model> <request> -> {choice, confidence, error}
_reflex_lm_decide() {
  local backend="$1" to="$2" model="$3" req="$4" resp="" rc=0
  case "$backend" in
    fake:first) resp=$(jq -c '{choice: .options[0], confidence: null}' <<<"$req") ;;
    builtin)
      resp=$(_reflex_openrouter_decide "$model" "$to" <<<"$req" 2>/dev/null); rc=$? ;;
    *)
      resp=$(timeout "$to" bash -c "$backend" <<<"$req" 2>/dev/null); rc=$? ;;
  esac
  resp=$(head -n1 <<<"$resp")
  jq -nc --argjson req "$req" --arg resp "$resp" --argjson rc "$rc" '
    ($resp | fromjson? // null) as $r
    | if $rc == 124 then {choice: "none", confidence: null, error: "timeout"}
      elif ($r | type) != "object" then {choice: "none", confidence: null, error: "no_response"}
      elif ($r.choice | type) != "string" then {choice: "none", confidence: null, error: (($r.error // "no_choice") | tostring | .[0:120])}
      elif ($req.options | index([$r.choice])) == null then {choice: "none", confidence: null, error: "invalid_choice"}
      else {choice: $r.choice, confidence: (($r.confidence | numbers | select(. >= 0 and . <= 1)) // null), error: null}
      end'
}

_reflex_login_marker() {
  local site="" fo="" fi_="" url="" spa=0 compare="" backend="builtin" to=30 out="" a
  local -a fo_more=()
  for a in "$@"; do
    case "$a" in
      --logged-out=*) if [[ -z "$fo" ]]; then fo="${a#*=}"; else fo_more+=("${a#*=}"); fi ;;
      --logged-in=*)  fi_="${a#*=}" ;;
      --url=*)        url="${a#*=}" ;;
      --spa)          spa=1 ;;
      --compare=*)    compare="${a#*=}" ;;
      --backend=*)    backend="${a#*=}" ;;
      --timeout=*)    to="${a#*=}" ;;
      --out=*)        out="${a#*=}" ;;
      --json)         JSON_MODE=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$site" ]] || fail "$E_USAGE" "one site only (got: $site and $a)"; site="$a" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "jq is required"
  [[ -n "$site" ]] || fail "$E_USAGE" "usage: 5dive reflex login-marker <site> --logged-out=<html> [--logged-in=<html>] [--url=<probe url>] [--spa] [--compare=<adapter.json>] [--backend=fake:first|<command>] [--out=<file>] [--json]"
  [[ "$site" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || fail "$E_VALIDATION" "site must be a host name like linkedin.com (got: $site)"
  [[ -n "$fo" ]] || fail "$E_USAGE" "--logged-out=<html> is required: the probe URL rendered by a signed-out browser (a throwaway profile)"
  local f
  (( ${#fo_more[@]} <= 3 )) || fail "$E_USAGE" "at most four --logged-out renders"
  for f in "$fo" "${fo_more[@]}" ${fi_:+"$fi_"}; do
    [[ -f "$f" && -r "$f" && -s "$f" ]] || fail "$E_NOT_FOUND" "render not readable or empty: $f"
    (( $(wc -c <"$f") <= _REFLEX_LM_MAX_BYTES )) || fail "$E_VALIDATION" "render over ${_REFLEX_LM_MAX_BYTES} bytes: $f"
  done
  (( spa )) && [[ -z "$fi_" ]] && fail "$E_USAGE" "--spa proposes a SIGNED-IN marker, so it needs --logged-in=<html>"
  [[ "$to" =~ ^[1-9][0-9]{0,2}$ ]] || fail "$E_VALIDATION" "--timeout must be 1-999 seconds"
  case "$backend" in
    builtin|fake:first) ;;
    fake:*) fail "$E_VALIDATION" "unknown fake backend: $backend (fake:first)" ;;
    "") fail "$E_VALIDATION" "--backend is empty" ;;
  esac
  local hand_out="" hand_in=""
  if [[ -n "$compare" ]]; then
    [[ -r "$compare" ]] || fail "$E_NOT_FOUND" "--compare adapter not readable: $compare"
    jq -e '.probe.logged_out_when_dom_matches | strings' "$compare" >/dev/null 2>&1 \
      || fail "$E_VALIDATION" "--compare needs an adapter with probe.logged_out_when_dom_matches: $compare"
    hand_out=$(jq -r '.probe.logged_out_when_dom_matches' "$compare")
    hand_in=$(jq -r '.probe.logged_in_when_dom_matches // empty | strings' "$compare")
    [[ -n "$url" ]] || url=$(jq -r '.probe.url // empty | strings' "$compare")
  fi
  [[ -n "$url" ]] || fail "$E_USAGE" "--url=<probe url> is required (the page both renders are of), unless --compare names an adapter that has one"
  [[ "$url" =~ ^https?://[^[:space:]]{1,500}$ ]] || fail "$E_VALIDATION" "--url must be an http(s) URL"
  # Shadow is structural: the proposal may never land where the browser loads adapters from.
  if [[ -n "$out" ]]; then
    # Resolve symlinks first: a link that points into .adapters/ is still .adapters/.
    case "/$(dirname -- "$(realpath -m -- "$out")")/" in
      */.adapters/*|*/adapters/*) fail "$E_VALIDATION" "--out may not be an adapter directory: this is a shadow proposal, and an adapter is trusted only once a person has measured it on both halves" ;;
    esac
  fi
  # A challenge page is not a sign-in page. A marker drafted off one would read
  # every future challenge as "signed out" and send a person to log in again.
  local title; title=$({ grep -oiE '<title[^>]*>[^<]{1,200}' "$fo" 2>/dev/null || true; } | head -n1 | sed -E 's/<title[^>]*>//; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  for f in "${fo_more[@]}"; do
    if grep -qiE "$_REFLEX_LM_CHALLENGE" "$f"; then
      fail "$E_VALIDATION" "the signed-out render $f is a challenge page (captcha or verification), not a sign-in page. Nothing was proposed."
    fi
  done
  _REFLEX_LM_OUT_MORE=("${fo_more[@]}")
  local challenge=false
  if grep -qiE "$_REFLEX_LM_CHALLENGE" "$fo"; then challenge=true; fi
  if grep -qiE "$_REFLEX_LM_CHALLENGE_TITLE" <<<"$title"; then challenge=true; fi
  if [[ "$challenge" == true ]]; then
    fail "$E_VALIDATION" "the signed-out render is a challenge page (captcha or verification), not a sign-in page. Nothing was proposed. Render it again from a browser the site does not challenge."
  fi
  local model=""
  if [[ "$backend" == builtin ]]; then
    reflex_model_resolve; model="$_REFLEX_MODEL"
    [[ -r "$(_reflex_key_file)" ]] \
      || fail "$E_PERMISSION" "the reflex key ($(_reflex_key_file)) is not readable by $(id -un). Run it as root (sudo 5dive reflex login-marker ...), or pass --backend=fake:first for the heuristic alone."
  fi
  local inm=false; if [[ -n "$fi_" ]]; then inm=true; fi

  local c_out c_in="[]" req_out req_in d_out d_in='null'
  c_out=$(_reflex_lm_half out "$fo" "$fi_")
  req_out=$(_reflex_lm_request "$site" "$url" logged_out "$title" "$c_out" "$inm")
  if [[ "$(jq 'length' <<<"$c_out")" == 0 ]]; then
    d_out='{"choice":"none","confidence":null,"error":"no_candidates"}'
  else
    d_out=$(_reflex_lm_decide "$backend" "$to" "$model" "$req_out")
  fi
  if (( spa )); then
    c_in=$(_reflex_lm_half in "$fo" "$fi_")
    req_in=$(_reflex_lm_request "$site" "$url" logged_in "" "$c_in" true)
    if [[ "$(jq 'length' <<<"$c_in")" == 0 ]]; then
      d_in='{"choice":"none","confidence":null,"error":"no_candidates"}'
    else
      d_in=$(_reflex_lm_decide "$backend" "$to" "$model" "$req_in")
    fi
  fi

  # The hand marker, counted by the same engine on the same renders.
  local ho=null hi=null hio=null hii=null
  if [[ -n "$hand_out" ]]; then
    ho=$(_reflex_lm_count "$hand_out" "$fo")
    if [[ -n "$fi_" ]]; then hi=$(_reflex_lm_count "$hand_out" "$fi_"); fi
  fi
  if [[ -n "$hand_in" && -n "$fi_" ]]; then
    hio=$(_reflex_lm_count "$hand_in" "$fo"); hii=$(_reflex_lm_count "$hand_in" "$fi_")
  fi

  local report
  report=$(jq -nc --arg site "$site" --arg url "$url" --arg backend "$backend" --arg model "$model" \
      --argjson c_out "$c_out" --argjson d_out "$d_out" --argjson c_in "$c_in" --argjson d_in "$d_in" \
      --argjson spa "$spa" --argjson inm "$inm" --arg compare "$compare" --argjson nout "$(( 1 + ${#fo_more[@]} ))" \
      --arg hand_out "$hand_out" --arg hand_in "$hand_in" \
      --argjson ho "$ho" --argjson hi "$hi" --argjson hio "$hio" --argjson hii "$hii" '
    def pick($c; $d): ($c | map(select(.key == $d.choice)) | .[0]) // null;
    def verdict($o; $i): if $o == null then null elif $i == null then ($o > 0) else ($o > 0 and $i == 0) end;
    pick($c_out; $d_out) as $po | (if $spa == 1 then pick($c_in; $d_in) else null end) as $pi
    | ($c_out[0] // null) as $top
    | {site: $site, probe_url: $url, mode: "shadow", written: false,
       backend: (if $backend == "builtin" then "openrouter" else $backend end),
       model: (if $model == "" then null else $model end),
       signed_in_render: $inm, signed_out_renders: $nout,
       logged_out: {candidates: $c_out, choice: $d_out.choice, confidence: $d_out.confidence, error: $d_out.error,
                    marker: ($po.marker // null), heuristic_top: ($top.marker // null)},
       logged_in: (if $spa == 1 then {candidates: $c_in, choice: $d_in.choice, confidence: $d_in.confidence,
                    error: $d_in.error, marker: ($pi.marker // null), heuristic_top: ($c_in[0].marker // null)} else null end),
       compare: (if $compare == "" then null else
         {adapter: $compare,
          logged_out: {hand: $hand_out, hand_out: $ho, hand_in: $hi,
                       hand_classifies: verdict($ho; $hi),
                       pick_is_hand: (($po.marker // null) == $hand_out),
                       heuristic_top_is_hand: (($top.marker // null) == $hand_out),
                       hand_among_candidates: ([$c_out[].marker] | index([$hand_out]) != null)},
          logged_in: (if $hand_in == "" then null else
                      {hand: $hand_in, hand_out: $hio, hand_in: $hii,
                       pick_is_hand: (if $spa == 1 then (($pi.marker // null) == $hand_in) else null end)} end)} end)}
    | . + {adapter: (if .logged_out.marker == null then null else
        {_comment: ("PROPOSED BY REFLEX, IN SHADOW (\(.backend)\(if .model then " " + .model else "" end), \(now | todate)). NOT MEASURED BY A PERSON. "
                    + "Signed-out marker: \(.logged_out.candidates | map(select(.marker == $po.marker))[0] | "\(.out) match(es) on the signed-out render, \(if .in == null then "the signed-in render was not supplied, so that half is UNMEASURED" else "\(.in) on the signed-in render" end)"). "
                    + "Measure it on both halves before copying it into .adapters/."),
         site: $site,
         probe: ({url: $url, logged_out_when_dom_matches: .logged_out.marker}
                 + (if (.logged_in.marker // null) != null then {logged_in_when_dom_matches: .logged_in.marker} else {} end)),
         actions: {}} end)}')

  # The receipt: labels, counts and hashes. No marker text, no page text.
  local mh; mh=$(jq -r '.logged_out.marker // empty' <<<"$report")
  if [[ -n "$mh" ]]; then mh="sha256:$(printf '%s' "$mh" | sha256sum | cut -c1-16)"; fi
  reflex_receipt policy=browser-login-marker mode=shadow result="$(jq -r '.logged_out.choice' <<<"$report")" \
    candidates="$(jq -r '[.logged_out.candidates[].key] + ["none"] | join(",")' <<<"$report")" \
    confidence="$(jq -c '.logged_out.confidence' <<<"$report")" \
    fallback="$(jq -r '.logged_out.error != null' <<<"$report")" \
    signals="$(jq -c '{site, signed_in_render, signed_out_renders, spa: (.logged_in != null), n_candidates: (.logged_out.candidates | length)}' <<<"$report")" \
    backend="$(jq -c '{adapter: (if .backend == "openrouter" then "openrouter" elif (.backend | startswith("fake:")) then .backend else "command" end), model}' <<<"$report")" \
    effect="$(jq -c --arg mh "$mh" '{acted: false, written: false, marker_hash: (if $mh == "" then null else $mh end),
        error: .logged_out.error, logged_in_choice: (.logged_in.choice // null),
        compare: (if .compare == null then null else
          {pick_is_hand: .compare.logged_out.pick_is_hand, heuristic_top_is_hand: .compare.logged_out.heuristic_top_is_hand,
           hand_among_candidates: .compare.logged_out.hand_among_candidates, hand_classifies: .compare.logged_out.hand_classifies} end)}' <<<"$report")" \
    actor="$(id -un 2>/dev/null || echo unknown)" authority="cli"

  if [[ -n "$out" ]]; then
    if jq -e '.adapter != null' <<<"$report" >/dev/null; then
      jq '.adapter' <<<"$report" >"$out" || fail "$E_GENERIC" "could not write $out"
    fi
  fi
  if [[ "${JSON_MODE:-0}" == 1 ]]; then printf '%s\n' "$report"; return 0; fi
  jq -r '
    def side($h; $name):
      if $h == null then empty else
        "\($name): " + (if $h.marker then "\($h.marker)   (\($h.choice) of \($h.candidates|length)\(if $h.confidence != null then ", confidence \($h.confidence)" else "" end))"
                        else "none proposed\(if $h.error then " (\($h.error))" else "" end) — \($h.candidates|length) candidate(s)" end),
        "  heuristic top pick: \($h.heuristic_top // "-")" end;
    "reflex login-marker — \(.site)  (shadow: nothing was written)",
    "probe url: \(.probe_url)",
    "backend:   \(.backend)\(if .model then " " + .model else "" end)",
    (if .signed_in_render then empty else "signed-in render: NOT SUPPLIED — the signed-in half is unmeasured" end),
    (if .signed_out_renders > 1 then "signed-out renders: \(.signed_out_renders) (a candidate must match every one)" else "signed-out renders: 1 — stability across renders is unmeasured (pass --logged-out twice)" end),
    side(.logged_out; "signed-out marker"),
    side(.logged_in; "signed-in marker"),
    (if .compare then
       "hand-written marker: \(.compare.logged_out.hand)  (\(.compare.logged_out.hand_out) signed out / \(.compare.logged_out.hand_in // "-") signed in)",
       "  model pick is the hand marker: \(.compare.logged_out.pick_is_hand); heuristic top is: \(.compare.logged_out.heuristic_top_is_hand); hand marker among the candidates: \(.compare.logged_out.hand_among_candidates)"
     else empty end),
    "",
    (if .adapter then "proposed adapter (NOT written; measure both halves before copying it into .adapters/):", (.adapter | tostring) else "no adapter proposed" end)' <<<"$report"
}
