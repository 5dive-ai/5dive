
# -------- agent CRUD --------

cmd_list() {
  # DIVE-1074: rootless read (mirrors account list / DIVE-1035). `agent list` is
  # pure-read, and a standard-isolation agent (group claude, so it can read the
  # registry) needs it to DISCOVER peers before it can send/ask them. ensure_state_ro
  # skips require_root when the registry already exists.
  ensure_state_ro
  local reg
  reg=$(registry_read)
  # Enrich with live systemd state.
  local out
  out=$(echo "$reg" | jq -c '.agents')
  local enriched="{}"
  # DIVE-352: collapse the per-agent systemd probe — was 2 systemctl spawns per
  # agent (is-active + is-enabled), i.e. 2N process spawns per `agent list`, which
  # the dashboard polls every 30s — into ONE `systemctl show` over every unit.
  # Keeps `agent list` a single cheap shell-out at any fleet size. Missing units
  # fall through to the "// unknown" default in the merge below.
  local -A _active_map=() _enabled_map=()
  local _svc_args=() _an
  for _an in $(echo "$out" | jq -r 'keys[]' 2>/dev/null); do
    _svc_args+=("5dive-agent@${_an}.service")
  done
  if (( ${#_svc_args[@]} )); then
    local _show _line _id="" _as="" _ufs="" _n
    _show=$(systemctl show --property=Id,ActiveState,UnitFileState --no-page "${_svc_args[@]}" 2>/dev/null || true)
    while IFS= read -r _line; do
      case "$_line" in
        Id=*)            _id="${_line#Id=}" ;;
        ActiveState=*)   _as="${_line#ActiveState=}" ;;
        UnitFileState=*) _ufs="${_line#UnitFileState=}" ;;
        "")              if [[ "$_id" == 5dive-agent@*.service ]]; then
                           _n="${_id#5dive-agent@}"; _n="${_n%.service}"
                           _active_map["$_n"]="$_as"; _enabled_map["$_n"]="$_ufs"
                         fi
                         _id=""; _as=""; _ufs="" ;;
      esac
    done <<< "$_show"
    # systemctl show emits no trailing blank line, so flush the final block.
    if [[ "$_id" == 5dive-agent@*.service ]]; then
      _n="${_id#5dive-agent@}"; _n="${_n%.service}"
      _active_map["$_n"]="$_as"; _enabled_map["$_n"]="$_ufs"
    fi
  fi
  # DIVE-2135: ONE privileged read of the sudoers dir for the whole survey,
  # before the per-agent loop. No-op (and no exec) for a root caller or a
  # readable dir, where the per-row read already answers; on failure every row
  # falls back to `unknown` rather than to the stored label. See
  # sudo_grant_batch_load for why `list` batches where `info` does not.
  sudo_grant_batch_load
  for name in $(echo "$out" | jq -r 'keys[]' 2>/dev/null); do
    local svc="5dive-agent@${name}"
    local active sub
    active="${_active_map[$name]:-unknown}"
    sub="${_enabled_map[$name]:-unknown}"
    # Surface bot-to-bot status (DIVE-161) so the dashboard can flag which agents
    # can message bots outside the team — without N per-agent access fetches.
    # It lives in the agent's access.json, not the registry; read it here (root).
    local b2b="false" ltype lchan lsd lprof
    ltype=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    lchan=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
    lprof=$(jq -r --arg n "$name" '.agents[$n].authProfile // ""' <<<"$reg")
    if [[ "$lchan" == "telegram" ]]; then
      lsd=$(_tg_access_state_dir "agent-${name}" "$ltype" 2>/dev/null || echo "")
      if [[ -n "$lsd" && -f "$lsd/access.json" ]]; then
        b2b=$(jq -r '.botToBot.enabled // false' "$lsd/access.json" 2>/dev/null || echo "false")
      fi
    fi
    # Surface the configured model + reasoning effort (DIVE-211) so the dashboard
    # can render a per-row model badge + picker without an N×`agent info` fan-out.
    # Same best-effort reads `info` uses; empty -> null (model unset / non-claude
    # effort). Two extra per-agent file reads, in line with the systemctl + b2b
    # reads this loop already does.
    local amodel aeffort
    # `|| true`: belt-and-suspenders with the resolvers' own exit-0 contract so a
    # best-effort per-agent config read can never abort the whole list under
    # `set -e` (DIVE-230).
    amodel=$(resolve_agent_model "$ltype" "$name" || true)
    aeffort=$(resolve_agent_effort "$ltype" "$name" || true)
    # DIVE-1219: surface reachability/autonomy health so the dashboard can badge
    # agents that look up-and-running but are silently broken. Mirrors the
    # DIVE-1197 create-time self-check, computed here for the live fleet:
    #   deaf   — a telegram/discord channel with an empty allowlist (nobody paired,
    #            so every inbound DM is refused). Absent when the agent has no
    #            personal-bot channel.
    #   asleep — heartbeat not enabled (won't self-act on board work).
    # PRIVILEGED READ (DIVE-1219 iter-2): access.json is 0600 owned by
    # agent-<name>, but the dashboard runs this CLI through the API exec tunnel
    # as `claude` (User=claude in 5dive-api.service). A plain read EACCESes, and
    # treating that as an empty allowlist would false-flag EVERY paired agent as
    # deaf (verifier olivia, iter-1). Read via `sudo -n cat` (no-op cost when
    # already root); fall back to a plain read for group-readable files. Only a
    # POSITIVE read of an empty allowFrom marks deaf — a missing/unreadable/
    # garbled file stays "unknown" (hdeaf untouched) and can never false-flag a
    # paired agent nor abort the list under `set -e`.
    local hdeaf="false" hasleep="false" _hc_ch _hc_access _hc_json _hc_nallow _hc_hb
    for _hc_ch in telegram discord; do
      case ",${lchan}," in *",${_hc_ch},"*) ;; *) continue ;; esac
      _hc_access="/home/agent-${name}/.${ltype}/channels/${_hc_ch}/access.json"
      _hc_json=$(sudo -n cat "$_hc_access" 2>/dev/null || cat "$_hc_access" 2>/dev/null || true)
      [[ -z "$_hc_json" ]] && continue          # unreadable/missing -> unknown, don't flag
      _hc_nallow=$(jq -r '(.allowFrom // []) | length' <<<"$_hc_json" 2>/dev/null || echo -1)
      (( _hc_nallow == 0 )) && hdeaf="true"      # -1 (parse fail) -> unknown, don't flag
    done
    _hc_hb=$(jq -r --arg n "$name" '.agents[$n].heartbeat.enabled // false' <<<"$reg" 2>/dev/null || echo false)
    [[ "$_hc_hb" == "true" ]] || hasleep="true"
    # DIVE-1953: the third badge in this set. deaf/asleep answer "can anything
    # reach it" and "will it act on its own"; neither asks whether the runtime
    # can still reach its PROVIDER. A lapsed credential leaves the unit active
    # and the seat useless, which is how a council convene dispatched a ballot
    # to a dead grok seat and recorded a normal-looking abstain (DIVE-1869 item
    # 3). File-state only — see agent_auth_health for why it never flags a
    # refreshable token, and why an unreadable credential is `unknown` rather
    # than an alarm. `|| true` keeps a best-effort read from aborting the list.
    local _ha _ha_state _ha_exp _ha_refresh
    _ha=$(agent_auth_health "$ltype" "$lprof" || true)
    [[ -n "$_ha" ]] || _ha="unknown|-|false"
    _ha_state="${_ha%%|*}"
    _ha_exp="${_ha#*|}"; _ha_exp="${_ha_exp%%|*}"
    _ha_refresh="${_ha##*|}"
    # DIVE-2088: measure the ENFORCED sudo grant here too. DIVE-2079 fixed the
    # per-agent DRILL-DOWN (`agent info`), but `list` is the SURVEY surface — the
    # command you run to notice something is off, not the one you run once you
    # already suspect it. It shipped `isolation` (the stored label) in --json with
    # no measurement beside it, so three genuinely different privilege levels
    # rendered identically to the reader most likely to be scanning for the
    # difference. Same instrument as `info` on purpose: a second, cheaper-but-
    # weaker measurement under a friendlier name would recreate the exact defect
    # DIVE-2079 was worth shipping to remove.
    #
    # Cost: a root caller pays one authoritative `sudo -l -U` per agent. A
    # non-root caller pays a file-read per agent plus, at most, the ONE batched
    # privileged read sudo_grant_batch_load did before this loop (DIVE-2135) —
    # never one sudo exec per row, because the survey is the command people
    # re-run and 16 auth-log rows per run is how an honest column gets silenced.
    # `|| true`: an unmeasurable grant is a reported `unknown`, never a failed list.
    local _sg _sg_class _sg_runas _sg_extra _sg_implied
    _sg=$(agent_sudo_grant "agent-${name}" || true)
    [[ -n "$_sg" ]] || _sg="unknown|-|0"
    _sg_class="${_sg%%|*}"
    _sg_runas="${_sg#*|}"; _sg_runas="${_sg_runas%%|*}"
    _sg_extra="${_sg##*|}"
    _sg_implied=$(isolation_implied_by_grant "$_sg_class")
    enriched=$(jq -c --arg n "$name" --arg a "$active" --arg e "$sub" --argjson b2b "$b2b" \
      --arg model "$amodel" --arg effort "$aeffort" \
      --argjson hdeaf "$hdeaf" --argjson hasleep "$hasleep" \
      --arg haState "$_ha_state" --arg haExp "$_ha_exp" --arg haRefresh "$_ha_refresh" \
      --arg sgClass "$_sg_class" --arg sgRunas "$_sg_runas" \
      --arg sgExtra "$_sg_extra" --arg sgImplied "$_sg_implied" \
      '.[$n] = {active: $a, enabled: $e, botToBotEnabled: $b2b,
                model: (if $model == "" then null else $model end),
                effort: (if $effort == "" then null else $effort end),
                sudo: {grant: $sgClass, runas: $sgRunas, impliedIsolation: $sgImplied,
                       measured: ($sgClass != "unknown"),
                       extraEntries: ($sgExtra == "1")},
                health: {deaf: $hdeaf, asleep: $hasleep,
                         auth: {state: $haState,
                                expiresAt: (if $haExp == "-" then null
                                            else ($haExp | tonumber | todate) end),
                                refreshable: ($haRefresh == "true")}}}' <<<"$enriched")
  done
  local merged
  merged=$(jq -c --arg default_wd "$DEFAULT_WORKDIR" --argjson live "$enriched" '.agents | to_entries | map({
    name: .key,
    type: .value.type,
    channels: .value.channels,
    workdir: (.value.workdir // $default_wd),
    authProfile: (.value.authProfile // null),
    botUsername: (.value.botUsername // null),
    isolation: (.value.isolation // "admin"),
    heartbeat: (.value.heartbeat // null),
    createdAt: .value.createdAt,
    active: ($live[.key].active // "unknown"),
    enabled: ($live[.key].enabled // "unknown"),
    botToBotEnabled: ($live[.key].botToBotEnabled // false),
    model: ($live[.key].model // null),
    effort: ($live[.key].effort // null),
    # DIVE-2088: same shape `agent info` reports, so one schema serves both
    # readers. `isolation` above is the stored LABEL; `sudo` here is the MEASURED
    # grant; `diverges` is true only when a REAL measurement contradicts the
    # label — `unknown` is never divergence, it is absence of evidence.
    sudo: (($live[.key].sudo // {grant: "unknown", runas: "-", impliedIsolation: "custom",
                                 measured: false, extraEntries: false}) as $s
           | $s + {diverges: ($s.measured and $s.impliedIsolation != (.value.isolation // "admin"))}),
    health: ($live[.key].health // null)
  })' <<<"$reg")
  if (( JSON_MODE )); then
    echo "$merged" | jq -c '{ok:true, data: .}'
  else
    echo "$merged" | jq -r '
      if length == 0 then "no agents" else
        (["NAME","TYPE","CHANNELS","PROFILE","AUTH","SUDO","ACTIVE","ENABLED"] | @tsv),
        (.[] | [(.name + (if (.heartbeat.enabled // false) then " ∿" + ((.heartbeat.everyMin // 30)|tostring) + "m" else "" end)), .type, .channels, (.authProfile // "-"),
                (.health.auth.state // "unknown"),
                (if (.sudo.measured | not) then "unknown"
                 else .sudo.grant + (if .sudo.diverges then "!" else "" end) + (if .sudo.extraEntries then "+" else "" end) end),
                .active, .enabled] | @tsv)
      end' | column -t -s $'\t'
    # DIVE-2088: the SUDO column is a MEASUREMENT, not the stored label, so the
    # legend only prints for the states that need reading — and `unknown` says
    # outright that nothing was measured rather than quietly falling back to the
    # label (falling back is what made the label authoritative-looking in the
    # first place). Detail deliberately stays in `agent info`; this is a survey.
    # DIVE-1953: the AUTH column is file state, so the legend says what was
    # observed and what the observation cannot cover. A `needs_login` row whose
    # unit is ACTIVE is the exact defect this shipped for — call it out by name
    # rather than leaving the reader to join two columns themselves.
    local _lg_login _lg_exp _lg_aunk
    _lg_login=$(jq -r '[.[] | select(.health.auth.state == "needs_login")] | length' <<<"$merged")
    _lg_exp=$(jq -r '[.[] | select(.health.auth.state == "expired")] | length' <<<"$merged")
    _lg_aunk=$(jq -r '[.[] | select((.health.auth.state // "unknown") == "unknown")] | length' <<<"$merged")
    if (( _lg_login || _lg_exp )); then
      echo
      local _lg_live
      _lg_live=$(jq -r '[.[] | select(.active == "active"
                        and ((.health.auth.state == "needs_login") or (.health.auth.state == "expired")))
                        | .name] | join(", ")' <<<"$merged")
      echo "AUTH: $(( _lg_login + _lg_exp )) agent(s) have no usable credential (5dive agent auth start <type> --auth-profile=<p>)"
      [[ -n "$_lg_live" ]] && echo "      RUNNING but unauthed — the unit is up and the runtime cannot reach its provider: ${_lg_live}"
    fi
    if (( _lg_aunk )); then
      (( _lg_login || _lg_exp )) || echo
      echo "AUTH unknown = credential not readable as $(id -un); re-run as root. ok = the credential FILE is present/unexpired, not probed (5dive auth status)"
    fi
    local _lg_unk _lg_div _lg_ext
    _lg_unk=$(jq -r '[.[] | select(.sudo.measured | not)] | length' <<<"$merged")
    _lg_div=$(jq -r '[.[] | select(.sudo.diverges)] | length' <<<"$merged")
    _lg_ext=$(jq -r '[.[] | select(.sudo.extraEntries)] | length' <<<"$merged")
    if (( _lg_div )); then
      echo
      echo "! enforced grant DISAGREES with the stored isolation label — trust the grant (5dive agent info <name>)"
    fi
    (( _lg_ext )) && echo "+ extra sudoers entries this CLI did not write"
    if (( _lg_unk )); then
      (( _lg_div )) || echo
      echo "unknown = grant not measurable as $(id -un); re-run as root for the measured column"
    fi
  fi
}

# --- Unprivileged-first reads, with a circuit breaker (DIVE-2791) -----------
#
# These resolvers are cosmetic survey columns, and they are called once PER AGENT
# on a fleet-wide sweep (`agent list`, `compose`). Reaching for `sudo` by reflex
# made a scoped agent emit one denial per agent per sweep: 224 `command not
# allowed` lines in 24h on the control plane (164 agent-codex + 26 agent-dev3),
# all of them `sudo jq`/`sudo sed` against other agents' settings.json. Each
# denial is a syslog line and, where sudoers sets `mail_no_perms`, a mail to root
# — a reporter's box ran that chain for 9 days and landed its IP on Spamhaus CSS
# and XBL. No compromise; volume to a nonexistent recipient just reads as abuse.
#
# Two rules keep that from recurring:
#   1. Ask root only when the direct read genuinely cannot answer. Readability is
#      the test, NOT emptiness — an empty `model` is a legitimate value (the
#      runtime falls back to its built-in pick), so escalating on "" would sudo
#      for every unset agent forever.
#   2. Latch off after PRIV_READ_MAX_DENIALS consecutive refusals. A grant is
#      written against the COMMAND, so a refusal for agent-A's file predicts a
#      refusal for agent-B's; we spend a few before latching only because a
#      per-target sudoers rule is expressible.

# Consecutive sudo refusals tolerated before we stop asking for the rest of the
# window. Cache TTL bounds how long a latched breaker outlives a sudoers change.
PRIV_READ_MAX_DENIALS="${PRIV_READ_MAX_DENIALS:-3}"
PRIV_READ_TTL="${PRIV_READ_TTL:-900}"

# Where the denial count lives. It MUST be a file rather than a shell variable:
# every caller invokes these resolvers as `model=$(resolve_agent_model …)`, and a
# subshell cannot write a variable back to its parent — a variable-held counter
# would reset on every agent and the breaker would never latch at all. Keyed by
# the caller's OWN cache dir, so the count also carries across the ~8 sweeps a
# day that produced the flood, and never lets one uid touch another's state.
_priv_state_file() {
  local base="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
  [[ "$base" == /* ]] || return 1
  [[ -d "$base/5dive" ]] || mkdir -p "$base/5dive" 2>/dev/null || return 1
  printf '%s/5dive/privread-denials' "$base"
}

# Current consecutive-denial count, or 0 when unknown/expired.
_priv_denials() {
  local f n mt now
  f=$(_priv_state_file) || { printf 0; return; }
  [[ -r "$f" ]] || { printf 0; return; }
  mt=$(stat -c %Y "$f" 2>/dev/null) || mt=0
  now=$(date +%s 2>/dev/null) || now=0
  # A stale latch must expire: a sudoers grant can be widened between sweeps and
  # nothing here would otherwise notice. TTL resolved locally for the same reason
  # the denial bound is (an unset global would make this `> 0` — expire always).
  local ttl="${PRIV_READ_TTL:-900}"
  [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || ttl=900
  if (( now > 0 && mt > 0 && now - mt > ttl )); then
    rm -f "$f" 2>/dev/null || true
    printf 0; return
  fi
  read -r n <"$f" 2>/dev/null || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# Record an escalation outcome. `ok` clears the latch (root works here), `denied`
# advances it and emits exactly ONE warn line for the window — a silently
# degraded read that mails root once a minute is the worst of both, so the
# operator gets told once and never spammed. A command that ran and merely failed
# (absent file, bad JSON) is NOT a denial and must not latch the breaker.
_priv_note() {
  local outcome="$1" f n
  f=$(_priv_state_file) || return 0
  case "$outcome" in
    ok)     rm -f "$f" 2>/dev/null || true ;;
    denied)
      n=$(_priv_denials); n=$(( n + 1 ))
      printf '%s\n' "$n" >"$f" 2>/dev/null || true
      if (( n == 1 )); then
        local max="${PRIV_READ_MAX_DENIALS:-3}"
        [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=3
        printf '5dive: warn: reading another agent'"'"'s config needs root and this grant was refused as %s; model/effort will show "—" for agents whose files are not readable. Suppressing further attempts after %s (DIVE-2791).\n' \
          "$(id -un 2>/dev/null || printf '?')" "$max" >&2
      fi
      ;;
  esac
  return 0
}

# Run a read-only command, unprivileged FIRST, escalating to `sudo -n` only when
# the direct read cannot answer AND the breaker is closed.
#   $1   the path whose readability decides whether root is needed at all
#   $2.. the command; its stdout is the value
# ALWAYS exits 0 with the value on stdout ("" when unavailable), because every
# caller assigns it under the bundle's `set -e` (see DIVE-230).
priv_read() {
  local guard="$1"; shift
  # Already root, or readable as us — our own home, a world-readable config, or a
  # root-invoked sweep. The direct read is authoritative: "" means unset.
  if (( EUID == 0 )) || [[ -r "$guard" ]]; then
    "$@" 2>/dev/null || true
    return 0
  fi
  # Resolve the bound LOCALLY. `(( n >= PRIV_READ_MAX_DENIALS ))` with the constant
  # unset is `0 >= 0` — TRUE — which reads as "breaker already latched" and disables
  # escalation entirely, silently returning "" for every agent. That is a quiet loss
  # of function with no warn line, and it depends only on bundle source order, so the
  # function must not rely on a global having been assigned first.
  local max="${PRIV_READ_MAX_DENIALS:-3}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=3
  local n; n=$(_priv_denials)
  (( n >= max )) && { printf ''; return 0; }
  local out err rc=0
  err=$(mktemp 2>/dev/null) || { printf ''; return 0; }
  # `-n` matters independently of the routing: without it a box that would prompt
  # hangs a survey column behind a password read it can never satisfy.
  out=$(sudo -n "$@" 2>"$err") || rc=$?
  if (( rc == 0 )); then
    _priv_note ok
  elif grep -qiE 'not allowed|password is required|not in the sudoers|may not run|no tty' "$err" 2>/dev/null; then
    _priv_note denied
  fi
  rm -f "$err" 2>/dev/null || true
  printf '%s' "$out"
  return 0
}

# Resolve the coding-CLI version string for an agent type from its TYPE_BIN
# binary. Best-effort: returns "" if the binary is missing or doesn't answer
# --version in time. Runs as `claude` (owns the binaries + their caches) through
# a login shell so node/nvm-based CLIs (codex) inherit their PATH, capped at 5s
# so a wedged CLI can't hang `info`. DIVE-2791: when the binary is already
# executable as us there is nothing to escalate for — that path was emitting
# `sudo bash` denials for a string we could read directly.
resolve_cli_version() {
  local type="$1"
  local bin="${TYPE_BIN[$type]:-}"
  [[ -n "$bin" ]] || { printf ''; return; }
  local q; q=$(printf '%q' "$bin")
  if (( EUID == 0 )) || [[ -x "$bin" ]]; then
    timeout 5 bash -lc "$q --version 2>/dev/null | head -1" 2>/dev/null || printf ''
    return 0
  fi
  local max="${PRIV_READ_MAX_DENIALS:-3}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=3
  local n; n=$(_priv_denials)
  (( n >= max )) && { printf ''; return 0; }
  local err out rc=0
  err=$(mktemp 2>/dev/null) || { printf ''; return 0; }
  out=$(timeout 5 sudo -n -u claude bash -lc "$q --version 2>/dev/null | head -1" 2>"$err") || rc=$?
  if (( rc == 0 )); then
    _priv_note ok
  elif grep -qiE 'not allowed|password is required|not in the sudoers|may not run|no tty' "$err" 2>/dev/null; then
    _priv_note denied
  fi
  rm -f "$err" 2>/dev/null || true
  printf '%s' "$out"
  return 0
}

# Resolve the model an agent is configured to use, read from the per-type
# runtime config the CLI actually loads (codex/grok TOML, claude/antigravity
# JSON). Best-effort: returns "" when the runtime doesn't persist a model
# (grok/antigravity fall back to the CLI's built-in pick), so callers should
# render "—"/null rather than treat empty as an error.
resolve_agent_model() {
  local type="$1" name="$2"
  local home="/home/agent-${name}"
  # MUST stay exit-0 on a missing/unreadable config: the caller assigns this in
  # `amodel=$(resolve_agent_model …)`, and under the bundle's `set -e` a non-zero
  # here aborts the whole command. A `--defer-auth` antigravity agent has no
  # settings.json until its first boot writes it, so the jq below exits non-zero
  # and (DIVE-230) crashed `agent list`/`info` mid-build → empty output → callers
  # read it as "agent missing". The `|| true` on every file read keeps the
  # contract: absent value → "" → exit 0. (sed|head needs it too: under
  # `pipefail` a missing config.toml propagates sed's non-zero status.)
  # DIVE-2791: every arm goes through priv_read, which reads directly when it can
  # and asks root only when the file is genuinely unreadable as us. The guard path
  # and the command's own path argument are the same file by construction.
  local f
  case "$type" in
    claude)
      f="$home/.claude/settings.json"
      priv_read "$f" jq -r '.model // empty' "$f" ;;
    codex|grok)
      f="$home/.${type}/config.toml"
      { priv_read "$f" sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*[^"# ])"?.*/\1/p' \
        "$f" | head -1; } || true ;;
    antigravity)
      f="$home/.gemini/antigravity-cli/settings.json"
      priv_read "$f" jq -r '.model // .selectedModel // empty' "$f" ;;
    *) printf '' ;;
  esac
}

# Resolve the reasoning effort an agent is configured with — claude-only
# (`effortLevel` in settings.json). Best-effort: returns "" for non-claude types
# or when unset (Claude Code then uses its built-in default), so callers render
# "—"/null rather than treat empty as an error.
resolve_agent_effort() {
  local type="$1" name="$2"
  local f
  case "$type" in
    claude)
      f="/home/agent-${name}/.claude/settings.json"
      priv_read "$f" jq -r '.effortLevel // empty' "$f" ;;
    *) printf '' ;;
  esac
}

# Write the selected model into the per-type runtime config the CLI loads, so
# `config set model=` is the single uniform path the forks' /model shells out to
# (replacing each plugin's own per-runtime config write). TOML (codex/grok) and
# JSON (claude/antigravity) are handled distinctly:
#   - TOML: split at the first table header; replace an existing top-level
#     `model = ...` in the preamble, else prepend one above the first [table] —
#     so the key stays document-root-level, never binds to a [section] and never
#     duplicates (matches telegram-{codex,grok} writeConfigModel()).
#   - JSON: merge-write the top-level `.model` key, preserving every other key.
# The runtime config must already exist (every provisioned+started agent has
# one) — we refuse to create it, both because a bare new file would drop the
# other required settings and because pre-seeding codex's config.toml would make
# 5dive-agent-start skip its approval_policy/sandbox baseline. Atomic (tmp +
# rename) with the existing owner:group + 600 mode preserved.
write_runtime_model() {
  local type="$1" name="$2" model="$3"
  local home="/home/agent-${name}" file fmt
  case "$type" in
    claude)      file="$home/.claude/settings.json"; fmt=json ;;
    codex)       file="$home/.codex/config.toml";     fmt=toml ;;
    grok)        file="$home/.grok/config.toml";       fmt=toml ;;
    antigravity) file="$home/.gemini/antigravity-cli/settings.json"; fmt=json ;;
    *) fail "$E_VALIDATION" "type '$type' has no model config (can't set model=)" ;;
  esac
  [[ -f "$file" ]] \
    || fail "$E_NOT_FOUND" "no $type runtime config at $file yet — start agent '$name' once before setting model"
  local dir own
  dir=$(dirname "$file")
  own=$(stat -c '%U:%G' "$file")
  local tmp
  tmp=$(mktemp -p "$dir" .model.XXXXXX) || fail "$E_GENERIC" "mktemp failed in $dir"
  if ! MODEL_FMT="$fmt" MODEL_VAL="$model" MODEL_SRC="$file" python3 - "$tmp" <<'PY'
import os, sys, json, re
fmt, val, src, tmp = os.environ["MODEL_FMT"], os.environ["MODEL_VAL"], os.environ["MODEL_SRC"], sys.argv[1]
with open(src) as f: orig = f.read()
if fmt == "json":
    try:
        data = json.loads(orig) if orig.strip() else {}
    except ValueError:
        sys.stderr.write("existing %s is not valid JSON\n" % src); sys.exit(3)
    if not isinstance(data, dict):
        sys.stderr.write("existing %s is not a JSON object\n" % src); sys.exit(3)
    data["model"] = val
    out = json.dumps(data, indent=2) + "\n"
else:  # toml — only ever touch the preamble before the first [table] header
    m = re.search(r'^\s*\[', orig, re.M)
    head = orig if m is None else orig[:m.start()]
    tail = "" if m is None else orig[m.start():]
    line = 'model = "%s"' % val
    if re.search(r'^[ \t]*model[ \t]*=.*$', head, re.M):
        head = re.sub(r'^[ \t]*model[ \t]*=.*$', line, head, count=1, flags=re.M)
    else:
        head = line + "\n" + head
    out = head + tail
with open(tmp, "w") as f: f.write(out)
PY
  then
    rm -f "$tmp"; fail "$E_GENERIC" "failed to write model into $file"
  fi
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Write the reasoning effort into claude's settings.json (`effortLevel`) — the
# same key Claude Code reads and the telegram plugin's /effort writes. Claude-only
# (other types have no effort knob). Same atomic merge-write contract as
# write_runtime_model: refuse to create a missing file, preserve owner:group + 600.
write_runtime_effort() {
  local name="$1" effort="$2"
  local file="/home/agent-${name}/.claude/settings.json"
  [[ -f "$file" ]] \
    || fail "$E_NOT_FOUND" "no claude runtime config at $file yet — start agent '$name' once before setting effort"
  local dir own tmp
  dir=$(dirname "$file")
  own=$(stat -c '%U:%G' "$file")
  tmp=$(mktemp -p "$dir" .effort.XXXXXX) || fail "$E_GENERIC" "mktemp failed in $dir"
  if ! EFFORT_VAL="$effort" EFFORT_SRC="$file" python3 - "$tmp" <<'PY'
import os, sys, json
val, src, tmp = os.environ["EFFORT_VAL"], os.environ["EFFORT_SRC"], sys.argv[1]
with open(src) as f: orig = f.read()
try:
    data = json.loads(orig) if orig.strip() else {}
except ValueError:
    sys.stderr.write("existing %s is not valid JSON\n" % src); sys.exit(3)
if not isinstance(data, dict):
    sys.stderr.write("existing %s is not a JSON object\n" % src); sys.exit(3)
data["effortLevel"] = val
with open(tmp, "w") as f: f.write(json.dumps(data, indent=2) + "\n")
PY
  then
    rm -f "$tmp"; fail "$E_GENERIC" "failed to write effortLevel into $file"
  fi
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# DIVE-2766: DECLARED channels are not BOUND channels.
#
# `channels:` on `info` is read straight out of the registry, so a box where
# every channel was REFUSED at runtime still prints
# `channels: telegram,dashboard (@bot)` beside `state: active`. That is accurate
# about what was declared and it is rendered in the grammar of an observation,
# which is how four consecutive red `telegram-roundtrip-openrouter` runs were
# triaged as credential routing while the agent had simply never bound a channel
# (DIVE-2765 / DIVE-2754). Same class as the DIVE-2362 send receipt: the field
# describes the CALL, not the delivery.
#
# What is measurable from here is the refusal, not the success. The gate is
# inside the Claude Code binary and it announces itself in the session's own
# output — `--channels ignored (…)` followed by one of the `Channels are not …`
# branches (`community/wiki/the-channels-gate-is-inside-claude-code-not-our-plugin-staging.md`).
# There is NO corresponding success banner in the binary (checked against
# 2.1.233), so this probe can prove REFUSED and can never prove BOUND.
#
# Hence three states and deliberately not two:
#   n/a       — nothing declared, so there is nothing to bind.
#   refused   — POSITIVE evidence: the refusal banner is in the pane.
#   unknown   — everything else, INCLUDING a clean capture. The banner prints at
#               session start and rolls off the scrollback, so "not found" is
#               not "bound". Reporting a clean capture as bound would rebuild
#               this ticket's defect one layer down.
# Never `bound`. An unprobeable state renders UNKNOWN, never silently as the
# declared value — the v0.16 "fails loud" direction, where NOT-REACHED is not a
# synonym for green.
#
# Emits `<state>|<detail>|<evidence>` on stdout and always exits 0: like every
# other probe on this command it degrades to a reported unknown, never a failed
# `info`.
agent_channels_binding() { # agent_channels_binding <name> <declared-channels>
  local name="$1" declared="$2" pane="" line=""
  case "$declared" in
    ""|none|null) printf 'n/a||\n'; return 0 ;;
  esac
  # Same instrument the runtime commands use (cmd_agent_runtime.sh). A missing
  # session, a denied sudo and an absent tmux are one answer here — unknown —
  # and the detail says which, because "cannot probe" and "probed clean" have
  # completely different remedies and render identically otherwise.
  if ! sudo -n -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null; then
    printf 'unknown|no readable tmux session for agent-%s (not running, or this caller cannot read it) — run this as root on the box|\n' "$name"
    return 0
  fi
  pane=$(sudo -n -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -J -S -2000 2>/dev/null) || pane=""
  if [[ -z "$pane" ]]; then
    printf 'unknown|tmux capture-pane returned nothing for agent-%s|\n' "$name"
    return 0
  fi
  # Match the FAMILY, not one branch: the binary picks between several
  # `Channels are not …` endings (capability / third-party / org policy) and it
  # gained a new one between 2.1.222 and 2.1.233, so pinning the exact sentence
  # would have gone quietly blind on an upgrade.
  # `Channels are not …` is preferred over `--channels ignored` when both are in
  # the pane (they print as a pair): the second line names WHICH branch of the
  # gate fired, and the branch is the whole diagnosis. Taking whichever came
  # first would have surfaced the line that says only "something was ignored".
  line=$(grep -m1 -E 'Channels are not ' <<<"$pane" 2>/dev/null) || line=""
  [[ -n "$line" ]] || line=$(grep -m1 -E 'channels ignored' <<<"$pane" 2>/dev/null) || line=""
  if [[ -n "$line" ]]; then
    # Trim to keep one banner line on one output line.
    line="${line//|/ }"
    printf 'refused|the session announced the channel gate|%s\n' "$(printf '%s' "$line" | tr -d '\r' | cut -c1-160)"
    return 0
  fi
  printf 'unknown|no refusal banner in the last 2000 lines of the pane — the banner prints at session start and rolls off, so this is NOT evidence the channels bound|\n'
  return 0
}

# Single-agent detail: registry identity/config + live systemd state, plus the
# resolved coding-CLI version and selected model. Added so each fork's /status
# reads one uniform source (cliName/cliVersion/model) instead of shelling each
# runtime's config itself — the version/model live in different files per type
# and the binaries aren't on the agent user's PATH.
cmd_info() {
  ensure_state_ro   # read-only: agent info must work for non-root / standard-isolation agents
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent info <name> [--json]"
  require_agent "$name"

  local reg
  reg=$(registry_read)

  local svc="5dive-agent@${name}"
  local active enabled
  active=$(systemctl is-active "$svc" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)

  local type
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")

  local cli_version model effort
  cli_version=$(resolve_cli_version "$type")
  # `|| true`: a best-effort per-agent config read must never abort `info` under
  # `set -e` when the file is absent (e.g. --defer-auth agy pre-boot — DIVE-230).
  model=$(resolve_agent_model "$type" "$name" || true)
  effort=$(resolve_agent_effort "$type" "$name" || true)

  # DIVE-3113: for openclaw, an absent model is not a neutral "unset" — it is a
  # SILENT SWITCH TO A DIFFERENT PROVIDER. openclaw model ids are
  # `<provider>/<model>`, so with no pin it uses its built-in default, whose
  # prefix names a vendor we hold no credential for, and the BYO key sitting
  # right there on disk is never offered. The whole of DIVE-3112 was two hours
  # spent on a valid key because every check that asked "is the key there?"
  # passed. `model: —` was printed and read as cosmetic. Name it instead.
  local oc_unpinned=0
  if [[ "$type" == "openclaw" && -z "$model" ]]; then
    local _oc_prof _oc_auth=""
    _oc_prof=$(jq -r --arg n "$name" '.agents[$n].authProfile // ""' <<<"$reg")
    if [[ -n "$_oc_prof" ]]; then
      _oc_auth=$(profile_type_auth_path "$_oc_prof" openclaw 2>/dev/null) || _oc_auth=""
    fi
    # DIVE-3834: the default-home seat needs the same layout ladder the
    # profile-scoped one gets. TYPE_AUTH names the pre-2026.8.1 sqlite, which
    # 2026.8.1 creates and leaves empty, so `-s` read false and this warning —
    # the whole of DIVE-3112 — was silently suppressed on exactly the seats that
    # need it. profile_type_auth_path '' openclaw returns the proven rung, or
    # the constant unchanged when no rung proves a credential.
    if [[ -z "$_oc_auth" ]]; then
      _oc_auth=$(profile_type_auth_path "" openclaw 2>/dev/null) || _oc_auth=""
    fi
    [[ -n "$_oc_auth" ]] || _oc_auth="${TYPE_AUTH[openclaw]}"
    [[ -s "$_oc_auth" ]] && oc_unpinned=1
  fi

  # DIVE-2079: measure the ENFORCED sudo grant so `info` reports what this agent
  # can actually do, not only the label the registry stores. See
  # agent_sudo_grant/classify_sudo_grant in cmd_agent_create.sh for the classes
  # and for why the two can disagree. `|| true`: an unmeasurable grant is a
  # reported `unknown`, never a failed `info`.
  local grant grant_class grant_runas grant_extra grant_implied grant_english
  grant=$(agent_sudo_grant "agent-${name}" || true)
  [[ -n "$grant" ]] || grant="unknown|-|0"
  grant_class="${grant%%|*}"
  grant_runas="${grant#*|}"; grant_runas="${grant_runas%%|*}"
  grant_extra="${grant##*|}"
  grant_implied=$(isolation_implied_by_grant "$grant_class")
  grant_english=$(sudo_grant_english "$grant_class")

  # DIVE-3274: the OUTPUT overlay. `state:` below reports systemd + the registry
  # — both LIVENESS labels — and a seat that is up, reachable and closing
  # nothing prints identically to a working one. That is exactly what happened
  # to dev3 for four days (DIVE-3272), and this is the surface people type. See
  # sup_info_for_agent in cmd_supervisor.sh for why one half of the overlay is
  # measured here and the other is inherited with its age attached. `|| true`:
  # the overlay is best-effort like every other probe on this command — an
  # unreadable store degrades to `unobserved`, never to a failed `info`.
  # DIVE-2766: measure the channel BINDING beside the declared value. See
  # agent_channels_binding for why this can report REFUSED and can never report
  # BOUND, and why a clean capture is `unknown` rather than a green.
  local _chan_declared _cb _cb_state _cb_detail _cb_evidence
  _chan_declared=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
  _cb=$(agent_channels_binding "$name" "$_chan_declared" || true)
  [[ -n "$_cb" ]] || _cb='unknown|channel binding probe did not run|'
  _cb_state="${_cb%%|*}"
  _cb_detail="${_cb#*|}"; _cb_detail="${_cb_detail%%|*}"
  _cb_evidence="${_cb##*|}"

  local sup
  sup=$(sup_info_for_agent "$name" 2>/dev/null || true)
  [[ -n "$sup" ]] || sup='{"output":"unknown","transacting":null,"classification":"unobserved","verdict":null,"stateNote":"output unknown — the task store was not readable from here","line":"unobserved — the task store was not readable from here","note":"store unreadable"}'

  local obj
  obj=$(jq -c \
    --argjson sup "$sup" \
    --arg n "$name" \
    --arg grantClass "$grant_class" \
    --arg grantRunas "$grant_runas" \
    --arg grantExtra "$grant_extra" \
    --arg grantImplied "$grant_implied" \
    --arg grantEnglish "$grant_english" \
    --arg default_wd "$DEFAULT_WORKDIR" \
    --arg active "${active:-unknown}" \
    --arg enabled "${enabled:-unknown}" \
    --arg cliName "$type" \
    --arg cliVersion "$cli_version" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg ocUnpinned "$oc_unpinned" \
    --arg cbState "$_cb_state" \
    --arg cbDetail "$_cb_detail" \
    --arg cbEvidence "$_cb_evidence" \
    '.agents[$n] as $a | {
      name: $n,
      type: $a.type,
      # DIVE-2766: `channels` is the DECLARED value and always was. It keeps its
      # name and its shape so no consumer breaks, but it is no longer the only
      # channel field on this record, and `channelsBinding` below is the one that
      # answers the question a reader of `channels` thought they were asking.
      channels: ($a.channels // "none"),
      channelsDeclared: ($a.channels // "none"),
      channelsBinding: {
        state: $cbState,
        # `measured` is true ONLY for a positive refusal. `n/a` measured nothing
        # (there was nothing to measure) and `unknown` measured nothing either;
        # collapsing those into a true would hand a consumer the same false
        # confidence in JSON that the printed line used to hand a human.
        measured: ($cbState == "refused"),
        detail: (if $cbDetail == "" then null else $cbDetail end),
        evidence: (if $cbEvidence == "" then null else $cbEvidence end)
      },
      workdir: ($a.workdir // $default_wd),
      authProfile: ($a.authProfile // null),
      botUsername: ($a.botUsername // null),
      isolation: ($a.isolation // "admin"),
      # DIVE-2079: `isolation` above is the stored LABEL (and `// "admin"` means
      # a legacy agent with no field at all still reads `admin`); `sudo` below is
      # the MEASURED grant. `diverges` is true when they disagree, which is the
      # whole point of reporting both.
      isolationLabelled: ($a.isolation != null),
      sudo: {
        grant: $grantClass,
        runas: $grantRunas,
        scope: $grantEnglish,
        # DIVE-2098: null, never a class, when the grant was not measured.
        # `grant`/`scope` above already say "unknown"/"not measurable from
        # here"; the whole vocabulary of THIS field is definite privilege classes,
        # so there is no honest string for it and null is the only value a
        # consumer cannot mistake for a measurement. Guarded HERE as well as in
        # isolation_implied_by_grant so a future caller that re-derives the
        # value cannot reintroduce the confident wrong answer.
        impliedIsolation: (if $grantClass == "unknown" then null else $grantImplied end),
        measured: ($grantClass != "unknown"),
        extraEntries: ($grantExtra == "1"),
        diverges: (
          $grantClass != "unknown"
          and $grantImplied != ($a.isolation // "admin")
        )
      },
      heartbeat: ($a.heartbeat // null),
      createdAt: $a.createdAt,
      active: $active,
      enabled: $enabled,
      cliName: $cliName,
      cliVersion: (if $cliVersion == "" then null else $cliVersion end),
      model: (if $model == "" then null else $model end),
      effort: (if $effort == "" then null else $effort end),
      # DIVE-3113: true == an openclaw agent holding a BYO credential with no
      # model pin, i.e. running on the built-in openclaw default and therefore
      # on a provider whose key it does not have. (No apostrophes in this jq
      # program: it is a single-quoted bash string, so one would end it.)
      modelUnpinnedWithCreds: ($ocUnpinned == "1"),
      # DIVE-3274: whether this seat is PRODUCING, alongside the liveness fields
      # above. `active`/`enabled` answer "is it up", `supervisor.output` answers
      # "does anything come out" — the question no signal on this command asked
      # before, and the one a dark seat passes every other check on.
      supervisor: $sup
    }' <<<"$reg")

  if (( JSON_MODE )); then
    jq -cn --argjson d "$obj" '{ok:true, data:$d}'
  else
    jq -r '
      "name:        \(.name)",
      "type:        \(.type)",
      "cli:         \(.cliName) \(.cliVersion // "unknown")",
      "model:       \(.model // (if .modelUnpinnedWithCreds then "— UNPINNED (see warning below)" else "—" end))\(if .effort then " · effort \(.effort)" else "" end)",
      # DIVE-2766: the word DECLARED is the fix. It is what this line always
      # reported and never said, and the `bound:` line under it is what the
      # reader was actually after.
      "channels:    \(.channels)\(if .botUsername then " (@\(.botUsername))" else "" end)\(if .channelsBinding.state == "n/a" then "" else " — DECLARED (registry)" end)",
      (if .channelsBinding.state == "n/a" then empty else
        "bound:       \(if .channelsBinding.state == "refused" then "NO — REFUSED at runtime" else "unknown — \(.channelsBinding.detail // "not probeable from here")" end)\(if .channelsBinding.evidence then "\n             ↳ \(.channelsBinding.evidence)" else "" end)"
       end),
      "profile:     \(.authProfile // "-")",
      "workdir:     \(.workdir)",
      "isolation:   \(.isolation) (label\(if .isolationLabelled then "" else ", defaulted — unset in registry" end))",
      "sudo:        \(if .sudo.measured then "\(.sudo.grant) — \(.sudo.scope); runas \(.sudo.runas)" else "unknown — not measurable from here; run `sudo -n -l` as agent-\(.name), or re-run this as root" end)\(if .sudo.extraEntries then " (+ entries this CLI did not write)" else "" end)",
      "state:       \(.active) / \(.enabled) · \(.supervisor.stateNote)",
      "output:      \(.supervisor.note)",
      "supervisor:  \(.supervisor.line)",
      "created:     \(.createdAt // "unknown")",
      # DIVE-3274: leads with the QUEUE, not the seat symptom — the entire cost
      # of the DIVE-3272 incident was the 20 rows stacked behind a seat nobody
      # knew was dark, and the seat itself, by construction, cannot read this.
      (if .supervisor.verdict then
         "\nWARNING: this seat is UP and REACHABLE but NOT TRANSACTING (\(.supervisor.verdict)): \(.supervisor.note). Whatever is queued behind it is not moving. The `state:` line above and every other liveness signal (unit / tmux / poller / registry label) read healthy — that agreement is the DIVE-3272 defect, not evidence against this line. Check model capacity (auth-profile, quota reset) and reassign or park the queue: 5dive task ls --assignee=\(.name)"
       else empty end),
      (if .channelsBinding.state == "refused" then
         "\nWARNING: this agent DECLARES channels (\(.channelsDeclared)) and its session REFUSED them. It cannot receive or reply on any of them, however healthy every other line above looks — the registry, the unit and the bot username are all still correct, which is exactly why this reads as paired. The gate is inside the coding-CLI binary, not our plugin staging, so re-running `agent create` or re-installing the plugins will not move it (DIVE-2765). Do not attribute an unanswered message or a red round-trip on this agent to credential routing until this line is clear."
       else empty end),
      (if .modelUnpinnedWithCreds then
         "\nWARNING: this openclaw agent has a credential on disk and NO model pin. That is not a neutral default — openclaw model ids are `<provider>/<model>`, so with nothing pinned it uses its built-in default, whose provider prefix is not the one you configured. It will consult a credential that does not exist and return HTTP 401 while your key sits unused (DIVE-3112). Repair: sudo 5dive agent auth set openclaw --provider=<provider> --api-key=<key> --auth-profile=\(.authProfile // "<profile>") --model=<provider>/<model>"
       else empty end),
      (if .sudo.diverges then
         "\nWARNING: the label and the enforced grant DISAGREE. Label \"\(.isolation)\" describes \(if .isolation == "admin" then "the 5dive CLI as root" elif .isolation == "standard" then "5dive agent _deliver/_capture only" else "no sudo" end); the enforced grant is \(.sudo.grant) (\(.sudo.scope), runas \(.sudo.runas)). Trust the grant, not the label. Nothing re-writes a drop-in after create (create_agent_user is the only writer), so a drifted grant stays drifted until someone edits /etc/sudoers.d/agent-\(.name) by hand or recreates the agent."
       else empty end)
    ' <<<"$obj"
  fi
}

