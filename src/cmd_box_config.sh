# ── DIVE-4251: `5dive config` — the per-box settings surface ────────────────
#
# Box settings, shared by every seat:
# the company wizard needs somewhere to write a per-box choice that every seat
# reads and no seat can change for itself. `5dive agent config <name> set …` is
# the PER-AGENT surface and could not host this — a box default that each seat
# stores separately is not a box default.
#
# ROOT WRITES, EVERYONE READS. The file lives in STATE_DIR (2750 root:claude),
# so any agent reads it without sudo and only root sets it. A customer who does
# not want graders sets it once, on the box, and every seat honours it.
_box_config_read() {
  local f; f=$(_box_config_path)
  [[ -r "$f" ]] && cat "$f" 2>/dev/null || printf '{}'
}

cmd_box_config() {
  local -a sets=()
  while (( $# )); do
    case "$1" in
      --json) JSON_MODE=1 ;;
      -h|--help) printf '%s\n' \
        "usage: 5dive config                 # show this box's settings" \
        "       5dive config verify=<always|delivered-only|never>" \
        "       5dive config verify-small=<lines>|off" \
        "       5dive config coauthor=<on|off>" \
        "       5dive config pace-week=<soft>/<hard>|off|default" \
        "       5dive config pace-5h=<pct>|off|default" \
        "       5dive config reflex-receipts=on|off|default" \
        "       5dive config reflex-model=<model id>|default" \
        "       5dive config reflex-key=- < keyfile     # the key is read from stdin, never argv" \
        "       5dive config reflex-key=clear" \
        "       5dive config reflex-endpoint=<url>|default" \
        "       5dive config reflex-api=decisions|systemone|chat|default" \
        "       5dive config reflex-endpoint-key=- < keyfile | clear" \
        "" \
        "  verify   whether a task on this box gets a grader session." \
        "             always          every standard row is graded" \
        "             delivered-only  only rows bound to a delivery (default when unset)" \
        "             never           no row is graded by default" \
        "           A row always wins over the box: 'task add --verify' demands a" \
        "           grade on a 'never' box, 'task add --no-verify' skips one on 'always'." \
        "" \
        "  verify-small  how SMALL a delivery has to be to close without a grader." \
        "             <lines>  a delivery under this many changed lines (additions +" \
        "                      deletions, across the whole PR) closes outright" \
        "             off      every delivery is graded on its own merits (default)" \
        "           Paths override the number: anything touching the scheduler, the task" \
        "           store, credentials, deploy, a shared lib, sudo policy, systemd, the" \
        "           schema or the provisioning scripts is never small, at any size." \
        "           'task add --verify' still demands a grade whatever the size." \
        "" \
        "  pace-week  how much of an account's WEEK the heartbeat spends before it" \
        "             paces the account's seats (DIVE-4430)." \
        "             <soft>/<hard>  past <soft>% of the week only high/urgent rows run;" \
        "                            past <hard>% only urgent ones (default 60/90)." \
        "                            Integers, soft <= hard <= 100." \
        "             off            no weekly floor at all" \
        "             default        clear back to 60/90" \
        "  pace-5h    the same for the 5-hour session window: past <pct>% only urgent" \
        "             rows run (default 85); off, or default." \
        "           An explicit FIVE_PACE_7D_SOFT / FIVE_PACE_7D_HARD / FIVE_PACE_5H in the" \
        "           heartbeat's environment still wins over this setting. The source shown" \
        "           names the environment of THIS shell, not of the heartbeat's cron line." \
        "" \
        "  reflex-receipts  whether scheduler decisions are recorded for 'reflex replay'" \
        "             (default on). FIVEDIVE_REFLEX_RECEIPTS=0 in the environment still wins." \
        "  reflex-model     the model the reference replay backend asks (default" \
        "             ${REFLEX_MODEL_DEFAULT:-typesafe/jev-1.13}); a replay's own --model wins." \
        "             On OpenRouter it is provider/model; on a custom endpoint, any id" \
        "             that server knows (a local Laya: typed-decisions)." \
        "  reflex-key       the OpenRouter key for replays, written root-only 600 to" \
        "             $(declare -F _reflex_key_file >/dev/null && _reflex_key_file || printf /etc/5dive/reflex-openrouter.key)." \
        "             Write-only: nothing ever prints it; 'config' shows set or unset." \
        "  reflex-endpoint  where decisions are sent: a full http(s) URL, e.g." \
        "             http://127.0.0.1:8000/v1/systemone for a local Laya. default is" \
        "             OpenRouter. No credentials or query string in the URL. The" \
        "             OpenRouter key is never sent to a custom endpoint." \
        "  reflex-api       the wire format: decisions (OpenRouter's Decisions API)," \
        "             systemone (Jev/Laya, the same body), chat (chat completions)." \
        "             default reads it off the endpoint's path, else decisions." \
        "  reflex-endpoint-key  an optional bearer for the custom endpoint, from stdin," \
        "             root-only 600 at $(declare -F _reflex_endpoint_key_file >/dev/null && _reflex_endpoint_key_file || printf /etc/5dive/reflex-endpoint.key)."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *=*) sets+=("$1") ;;
      *)  fail "$E_USAGE" "usage: 5dive config [<key>=<value>]  (keys: verify, verify-small, coauthor, pace-week, pace-5h, reflex-receipts, reflex-model, reflex-key, reflex-endpoint, reflex-api, reflex-endpoint-key)" ;;
    esac
    shift
  done

  if (( ${#sets[@]} == 0 )); then
    local policy; policy=$(box_verify_policy)
    local src="box default" configured="" cfg
    cfg=$(_box_config_path)
    [[ -r "$cfg" ]] && configured=$(jq -r '.verify // empty' "$cfg" 2>/dev/null || printf '')
    [[ -n "$configured" ]] || src="unset — defaulting to 'delivered-only'"
    [[ "${FIVE_VERIFY_DEFAULT:-1}" == "0" ]] && src="FIVE_VERIFY_DEFAULT=0 in this environment"
    local small; small=$(box_verify_small)
    local ssrc="off — every delivery is graded on its own merits"
    [[ "$small" != "off" ]] && ssrc="a delivery under ${small} changed lines closes without a grader (DIVE-4559)"
    local coauthor; coauthor=$(jq -r '.coauthor // "on"' <<<"$(_box_config_read)" 2>/dev/null || printf on)
    [[ "$coauthor" == on || "$coauthor" == off ]] || coauthor=on
    # DIVE-4890: the effective floors and where each came from, off the SAME
    # loader the heartbeat and the digest use.
    local pw="unknown" p5="unknown" pws="the pacing floor is not in this process" p5s
    p5s="$pws"
    if declare -F _pace_floors_load >/dev/null 2>&1; then
      pw=$(_pace_week_effective); p5=$(_pace_5h_effective)
      _pace_floors_load; pws="$_PACE_WEEK_SRC"; p5s="$_PACE_5H_SRC"
    fi
    # DIVE-4915: reflex's settings, each with its source. The key is reported as
    # set/unset only — this path never opens the key file.
    local rr="on" rrs="reflex is not in this build" rm="" rms="" rk="unknown"
    local re="default" res="" ra="decisions" ras="" rek="unknown" rc="unknown"
    if declare -F reflex_receipts_resolve >/dev/null 2>&1; then
      reflex_receipts_resolve; reflex_model_resolve
      rr="$_REFLEX_RECEIPTS"; rrs="$_REFLEX_RECEIPTS_SRC"; rm="$_REFLEX_MODEL"; rms="$_REFLEX_MODEL_SRC"
      rk=$(reflex_key_status)
      # DIVE-4932: the endpoint, its wire format, its own key, and whether the
      # box can make a call at all.
      rc=$(reflex_configured); reflex_endpoint_resolve
      re="$_REFLEX_ENDPOINT"; res="$_REFLEX_ENDPOINT_SRC"; ra="$_REFLEX_API"; ras="$_REFLEX_API_SRC"
      rek=$(reflex_endpoint_key_status)
    fi
    ok "verify = ${policy} (${src})
verify-small = ${small} (${ssrc})
coauthor = ${coauthor} (box-wide, default on)
pace-week = ${pw} (${pws})
pace-5h = ${p5} (${p5s})
reflex-receipts = ${rr} (${rrs})
reflex-model = ${rm} (${rms})
reflex-key = ${rk}
reflex-endpoint = ${re} (${res})
reflex-api = ${ra} (${ras})
reflex-endpoint-key = ${rek}
reflex-configured = ${rc}" \
       '{verify:$v, source:$s, verify_small:$sm, coauthor:$c, pace_week:$pw, pace_week_source:$pws, pace_5h:$p5, pace_5h_source:$p5s,
         reflex_receipts:$rr, reflex_receipts_source:$rrs, reflex_model:$rm, reflex_model_source:$rms, reflex_key:$rk,
         reflex_endpoint:$re, reflex_endpoint_source:$res, reflex_api:$ra, reflex_api_source:$ras, reflex_endpoint_key:$rek,
         reflex_configured:(if $rc == "true" then true elif $rc == "false" then false else null end), path:$p}' \
       --arg v "$policy" --arg s "$src" --arg sm "$small" --arg c "$coauthor" \
       --arg pw "$pw" --arg pws "$pws" --arg p5 "$p5" --arg p5s "$p5s" \
       --arg rr "$rr" --arg rrs "$rrs" --arg rm "$rm" --arg rms "$rms" --arg re "$re" --arg res "$res" \
       --arg ra "$ra" --arg ras "$ras" --arg rek "$rek" --arg rc "$rc" --arg rk "$rk" --arg p "$(_box_config_path)"
    return 0
  fi

  # VALIDATE BEFORE require_root. A typo'd value is a typo whether or not the
  # caller is root, and refusing it with "must run as root" sends the reader
  # after the wrong problem — they sudo, and only then learn the value was wrong.
  local kv k v json key_op="" key_val="" ekey_op="" ekey_val=""
  # DIVE-4932: reflex-model and reflex-api are judged against the endpoint this
  # command LEAVES the box with, so `reflex-endpoint=<laya> reflex-model=english`
  # works in either order and in one call.
  local next_ep; next_ep=$(jq -r '.reflex_endpoint // empty | strings' <<<"$(_box_config_read)" 2>/dev/null || true)
  for kv in "${sets[@]}"; do
    case "${kv%%=*}" in reflex-endpoint|reflex_endpoint) next_ep="${kv#*=}"; [[ "$next_ep" == default ]] && next_ep="" ;; esac
  done
  for kv in "${sets[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      # DIVE-4915. Error messages here NEVER quote the value: a key pasted inline
      # by mistake must not be echoed back into a terminal, a log or an API body.
      reflex-key|reflex_key)
        case "$v" in
          -)     [[ "$ekey_op" == set ]] && fail "$E_VALIDATION" "reflex-key=- and reflex-endpoint-key=- both read stdin: set them in two calls. Nothing was written"
                 key_op="set"
                 IFS= read -r key_val || true
                 key_val="${key_val%$'\r'}"
                 [[ "$key_val" =~ ^[A-Za-z0-9_.:-]{16,256}$ ]] \
                   || fail "$E_VALIDATION" "reflex-key: stdin did not hold one key (16-256 characters of A-Z a-z 0-9 _ . : -); nothing was written" ;;
          clear) key_op=clear ;;
          *)     fail "$E_VALIDATION" "reflex-key is read from stdin only: use reflex-key=- (or reflex-key=clear). The value you passed was not used or stored" ;;
        esac ;;
      # DIVE-4932. Same rules as reflex-key; one stdin, so one key per call.
      reflex-endpoint-key|reflex_endpoint_key)
        case "$v" in
          -)     [[ "$key_op" == set ]] && fail "$E_VALIDATION" "reflex-key=- and reflex-endpoint-key=- both read stdin: set them in two calls. Nothing was written"
                 ekey_op="set"
                 IFS= read -r ekey_val || true
                 ekey_val="${ekey_val%$'\r'}"
                 [[ "$ekey_val" =~ ^[A-Za-z0-9_.:~+/=-]{8,512}$ ]] \
                   || fail "$E_VALIDATION" "reflex-endpoint-key: stdin did not hold one token (8-512 characters of A-Z a-z 0-9 _ . : ~ + / = -); nothing was written" ;;
          clear) ekey_op=clear ;;
          *)     fail "$E_VALIDATION" "reflex-endpoint-key is read from stdin only: use reflex-endpoint-key=- (or reflex-endpoint-key=clear). The value you passed was not used or stored" ;;
        esac ;;
      reflex-endpoint|reflex_endpoint) [[ "$v" == default ]] || reflex_endpoint_valid "$v" \
                || fail "$E_VALIDATION" "reflex-endpoint takes a full http(s) URL with no credentials, query string or fragment (at most 200 characters, e.g. http://127.0.0.1:8000/v1/systemone), or default — got '${v:0:200}'" ;;
      reflex-api|reflex_api)
        case "$v" in
          decisions|chat|default) ;;
          systemone) [[ -n "$next_ep" ]] \
                || fail "$E_VALIDATION" "reflex-api=systemone needs a custom reflex-endpoint: OpenRouter does not serve it. Set reflex-endpoint=<url> in the same call" ;;
          *) fail "$E_VALIDATION" "reflex-api takes one of: decisions, systemone, chat, default — got '$v'" ;;
        esac ;;
      reflex-receipts|reflex_receipts) [[ "$v" == on || "$v" == off || "$v" == default ]] \
                || fail "$E_VALIDATION" "reflex-receipts takes one of: on, off, default — got '$v'" ;;
      reflex-model|reflex_model)
        if [[ -n "$next_ep" ]]; then
          [[ "$v" == default || ( ${#v} -le 100 && "$v" =~ $REFLEX_MODEL_ANY_RE ) ]] \
            || fail "$E_VALIDATION" "reflex-model takes the custom endpoint's model id (at most 100 characters of A-Z a-z 0-9 . _ ~ : / -), or default — got '${v:0:100}'"
        else
          [[ "$v" == default || ( ${#v} -le 100 && "$v" =~ $REFLEX_MODEL_RE ) ]] \
            || fail "$E_VALIDATION" "reflex-model takes an OpenRouter model id like ${REFLEX_MODEL_DEFAULT} (provider/model, at most 100 characters), or default — got '${v:0:100}'. On a custom reflex-endpoint any id is accepted"
        fi ;;
      verify) _verify_policy_valid "$v" \
                || fail "$E_VALIDATION" "verify takes one of: ${_VERIFY_POLICIES// /, } — got '$v'" ;;
      # DIVE-4559. `verify-small` on the command line, `.verify_small` in the
      # file: the hyphen is the CLI convention every other 5dive flag uses and
      # the underscore is jq-addressable without quoting. Both spellings are
      # accepted here so a caller who read the JSON cannot be told their own
      # key is unknown.
      verify-small|verify_small) _verify_small_valid "$v" \
                || fail "$E_VALIDATION" "verify-small takes a positive number of changed lines, or 'off' — got '$v'" ;;
      coauthor) [[ "$v" == on || "$v" == off ]] \
                || fail "$E_VALIDATION" "coauthor takes one of: on, off — got '$v'" ;;
      # DIVE-4890. Validated in full before anything is written, like every key
      # above: one bad value in a multi-key call writes none of them.
      pace-week|pace_week) _pace_week_valid "$v" \
                || fail "$E_VALIDATION" "pace-week takes <soft>/<hard> (integers, soft <= hard <= 100, e.g. 85/95), off, or default — got '$v'" ;;
      pace-5h|pace_5h) _pace_5h_valid "$v" \
                || fail "$E_VALIDATION" "pace-5h takes a percentage (an integer 0-100, e.g. 85), off, or default — got '$v'" ;;
      *) fail "$E_VALIDATION" "unknown box setting: $k (keys: verify, verify-small, coauthor, pace-week, pace-5h, reflex-receipts, reflex-model, reflex-key, reflex-endpoint, reflex-api, reflex-endpoint-key)" ;;
    esac
  done
  require_root
  json=$(_box_config_read)
  local -a applied=()
  # DIVE-4559: WRITE THE KEY THAT WAS SET. This loop hardcoded `.verify = $v`
  # while iterating over every key — harmless with one key, and a silent
  # mis-write the moment there were two (`verify-small=30` would have stored
  # "30" as the verification POLICY, which `box_verify_policy` then discards as
  # invalid: the setting vanishes and the command reports success).
  for kv in "${sets[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # DIVE-4890: `default` on a pace key CLEARS it rather than storing the word,
    # so the loader falls through to the built-in floor and the file stops
    # carrying a setting nobody chose.
    case "$k" in
      reflex-key|reflex_key) applied+=("reflex-key"); continue ;;
      reflex-endpoint-key|reflex_endpoint_key) applied+=("reflex-endpoint-key"); continue ;;
    esac
    if [[ "$v" == default && ( "$k" == pace-week || "$k" == pace_week || "$k" == pace-5h || "$k" == pace_5h \
          || "$k" == reflex-receipts || "$k" == reflex_receipts || "$k" == reflex-model || "$k" == reflex_model \
          || "$k" == reflex-endpoint || "$k" == reflex_endpoint || "$k" == reflex-api || "$k" == reflex_api ) ]]; then
      json=$(jq --arg k "${k//-/_}" 'del(.[$k])' <<<"$json")
    else
      json=$(jq --arg k "${k//-/_}" --arg v "$v" '.[$k] = $v' <<<"$json")
    fi
    applied+=("$k")
  done
  local cfg; cfg=$(_box_config_path)
  mkdir -p "$(dirname "$cfg")"
  local tmp; tmp=$(mktemp "${cfg}.XXXXXX")
  printf '%s\n' "$json" > "$tmp"
  # 640 root:claude, the same posture as agents.json: every seat reads it,
  # only root writes it.
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv "$tmp" "$cfg"
  if [[ -n "$key_op" ]]; then _reflex_key_write "$key_op" "$key_val"; key_val=""; fi
  if [[ -n "$ekey_op" ]]; then _reflex_key_write "$ekey_op" "$ekey_val" "$(_reflex_endpoint_key_file)"; ekey_val=""; fi
  local policy; policy=$(box_verify_policy)
  local small; small=$(box_verify_small)
  local pw="" p5=""
  if declare -F _pace_floors_load >/dev/null 2>&1; then pw=$(_pace_week_effective); p5=$(_pace_5h_effective); fi
  local rr="" rm="" rk="" re="" ra="" rc=""
  if declare -F reflex_receipts_resolve >/dev/null 2>&1; then
    reflex_receipts_resolve; reflex_model_resolve; rr="$_REFLEX_RECEIPTS"; rm="$_REFLEX_MODEL"; rk=$(reflex_key_status)
    rc=$(reflex_configured); reflex_endpoint_resolve; re="$_REFLEX_ENDPOINT"; ra="$_REFLEX_API"
  fi
  ok "box config updated (${applied[*]}) — verify = ${policy}, verify-small = ${small}${pw:+, pace-week = ${pw}, pace-5h = ${p5}}${rr:+, reflex-receipts = ${rr}, reflex-model = ${rm}, reflex-key = ${rk}, reflex-endpoint = ${re}, reflex-api = ${ra}, reflex-configured = ${rc}}" \
     '{verify:$v, verify_small:$sm, pace_week:$pw, pace_5h:$p5, reflex_receipts:$rr, reflex_model:$rm, reflex_key:$rk,
       reflex_endpoint:$re, reflex_api:$ra, reflex_configured:(if $rc == "true" then true elif $rc == "false" then false else null end),
       applied:($a|split(",")), path:$p}' \
     --arg v "$policy" --arg sm "$small" --arg pw "$pw" --arg p5 "$p5" --arg rr "$rr" --arg rm "$rm" --arg rk "$rk" \
     --arg re "$re" --arg ra "$ra" --arg rc "$rc" \
     --arg a "$(IFS=,; printf '%s' "${applied[*]}")" --arg p "$cfg"
}

# DIVE-4915: write or remove the reflex OpenRouter key. Root-only 600 in a file
# of its own (not box.json, which every seat reads). The value arrives from
# stdin via the validator above and leaves only into the file. DIVE-4932: a
# third argument names another file (the custom endpoint's bearer).
_reflex_key_write() {
  local op="$1" val="${2:-}" f="${3:-}" d tmp
  [[ -n "$f" ]] || f=$(_reflex_key_file)
  d=$(dirname "$f")
  if [[ "$op" == clear ]]; then
    rm -f "$f" || fail "$E_GENERIC" "could not remove the reflex key file"
    return 0
  fi
  install -d -m 750 "$d" 2>/dev/null || mkdir -p "$d"
  tmp=$(umask 077; mktemp "${f}.XXXXXX") || fail "$E_GENERIC" "could not stage the reflex key file"
  printf '%s\n' "$val" > "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv "$tmp" "$f" || { rm -f "$tmp"; fail "$E_GENERIC" "could not write the reflex key file"; }
}
