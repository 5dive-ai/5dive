
# -------- self-update (fetch installer + --upgrade, then restart agents) --------
#
# `5dive self-update` is the on-demand counterpart to the managed nightly
# soft-update, for OSS self-hosted boxes that have no scheduler of their own.
# It does two things:
#
#   1. Fetches install.sh and runs `--upgrade` — refreshes the 5dive CLI,
#      5dive-agent-start, hooks, skills, the systemd template, and the plugins
#      (via 5dive-refresh-plugins.sh). This reuses the same installer that
#      `uninstall` shells out to, so there's a single source of truth for
#      "what gets updated" rather than a second copy that drifts.
#
#   2. Restarts every running agent so the refreshed plugins/CLIs actually
#      load. A live agent keeps its old plugin (and shared CLI binary) in
#      memory until it restarts — that's the usual reason a plugin "still
#      shows the old version" after an upgrade.
#
# The agent AI CLIs themselves (claude/codex/grok/antigravity) self-update via
# their own vendor autoupdaters; the restart in step 2 is what loads the latest
# shared binary into each agent. Managed boxes have their own scheduler so they
# don't need this, but running it there is harmless — `--upgrade` and the
# restart loop are both idempotent.

# json_array <items...> — emit a compact JSON string array, "[]" when empty.
# Guards the empty-array case (printf with no args would otherwise emit a stray
# empty element).
json_array() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -cs .
  fi
}

cmd_self_update() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "self-update takes no arguments"
  command -v curl >/dev/null 2>&1 || fail "$E_NOT_FOUND" "curl is required for 5dive self-update"

  local installer
  installer=$(mktemp) || fail "$E_GENERIC" "failed to create temp file"
  # shellcheck disable=SC2064
  trap "rm -f '$installer'" RETURN

  step "Fetching installer"
  curl -fsSL "https://raw.githubusercontent.com/$(gh_org)/5dive/main/install.sh" -o "$installer" \
    || fail "$E_GENERIC" "failed to fetch installer"

  step "Upgrading 5dive CLI + plugins"
  # Send installer chatter to stderr so JSON stdout stays parseable.
  bash "$installer" --upgrade >&2 || fail "$E_GENERIC" "upgrade failed"

  # Restart running agents so the refreshed plugins/CLIs load. Best-effort per
  # unit — one failed restart shouldn't abort the rest.
  local -a restarted=() failed=()
  local unit name
  if command -v systemctl >/dev/null 2>&1; then
    while read -r unit; do
      [[ -z "$unit" ]] && continue
      name="${unit#5dive-agent@}"; name="${name%.service}"
      if systemctl restart "$unit" 2>/dev/null; then
        step "restarted $name"
        restarted+=("$name")
      else
        warn "failed to restart agent '$name'"
        failed+=("$name")
      fi
    done < <(systemctl list-units '5dive-agent@*' --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')
  fi

  # DIVE-1095: refresh the materialized shared team-bot listener. It lives at
  # /opt/5dive/team-bot-listener.ts and is (re)written ONLY by `team-bot shared`,
  # so listener-only fixes (e.g. DIVE-1093's tap handling) otherwise ship in the
  # bundle but stay DORMANT on auto-updating boxes until an operator re-runs that
  # command. Re-materialize the listener from the freshly-installed bundle and
  # restart its service. Guarded on the unit file so it's a no-op on boxes with
  # no shared team-bot; best-effort so a listener hiccup never fails self-update.
  local listener_refreshed=false
  if [[ -f /etc/systemd/system/5dive-team-bot-listener.service ]]; then
    if _team_bot_install_listener >&2; then
      step "refreshed shared team-bot listener"
      listener_refreshed=true
    else
      warn "team-bot listener refresh failed (prior listener left running)"
    fi
  fi

  local r f prose
  r=$(json_array "${restarted[@]}")
  f=$(json_array "${failed[@]}")
  prose="self-update complete — ${#restarted[@]} agent(s) restarted"
  (( ${#failed[@]} )) && prose+=", ${#failed[@]} failed to restart"
  [[ "$listener_refreshed" == "true" ]] && prose+=", team-bot listener refreshed"
  ok "$prose" \
     '{restarted:$r, restarted_count:($r|length), failed:$f, listener_refreshed:$lr}' \
     --argjson r "$r" --argjson f "$f" --argjson lr "$listener_refreshed"
}

# version_lt A B — true when semver A is strictly older than B (sort -V).
version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# _update_latest_version [max-secs] — echo the published FIVE_VERSION from the
# canonical 5dive script on main, or nothing on any failure. Bounded by an
# optional curl --max-time (default 5s) so no caller ever blocks for long. The
# single source of truth for "what's the latest" — shared by `update --check`
# and the passive new-version notice so the two can never drift.
_update_latest_version() {
  curl -fsSL --max-time "${1:-5}" \
    "https://raw.githubusercontent.com/$(gh_org)/5dive/main/5dive" 2>/dev/null \
    | grep -m1 -oP '(?<=^readonly FIVE_VERSION=")[^"]+' || true
}

# How long the dashboard waits after a release before treating a still-behind
# box as "stale". One nightly soft-update (every 24h) should close the gap, so
# anything past ~1.5 days means the auto-update isn't keeping up.
readonly UPDATE_STALE_AFTER_SECS=$((36 * 3600))

# cmd_update_check — read-only (no root, no mutation) version probe for the
# dashboard maintenance tile. Compares the installed CLI to the published
# release and reads the last nightly soft-update result, then reports whether
# the box is GENUINELY stale (behind AND the auto-update isn't catching up) vs
# merely a release or two behind with a healthy nightly that'll close the gap.
cmd_update_check() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "update --check takes no arguments"
  command -v curl >/dev/null 2>&1 || fail "$E_NOT_FOUND" "curl is required for update --check"

  local current="$FIVE_VERSION" latest
  latest=$(_update_latest_version)
  [[ -n "$latest" ]] || fail "$E_GENERIC" "could not determine the latest published version"

  local behind=false
  version_lt "$current" "$latest" && behind=true

  # Inspect the last managed nightly soft-update run (managed boxes log to
  # /tmp/claude-soft-updates.log). Best-effort: absent log → unknown.
  local log="/tmp/claude-soft-updates.log"
  local last_ok_json="null" last_at_json="null" last_epoch=""
  if [[ -r "$log" ]]; then
    local start_line
    start_line=$(grep -n "soft updates start" "$log" | tail -1 | cut -d: -f1)
    if [[ -n "$start_line" ]]; then
      if tail -n "+${start_line}" "$log" | grep -q "CLI upgrade via install.5dive.com failed"; then
        last_ok_json="false"
      else
        last_ok_json="true"
      fi
    fi
    local last_at
    last_at=$(grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ soft updates done" "$log" \
      | tail -1 | grep -oE "^[^ ]+")
    if [[ -n "$last_at" ]]; then
      last_at_json="\"$last_at\""
      last_epoch=$(date -d "$last_at" +%s 2>/dev/null || echo "")
    fi
  fi

  # "stale" = behind AND the nightly auto-update isn't closing the gap: it
  # failed, never ran on record, or hasn't run inside the staleness window.
  local stale=false now
  now=$(date +%s)
  if [[ "$behind" == true ]]; then
    if [[ "$last_ok_json" == "false" || -z "$last_epoch" ]]; then
      stale=true
    elif (( now - last_epoch > UPDATE_STALE_AFTER_SECS )); then
      stale=true
    fi
  fi

  local prose
  if [[ "$behind" == true ]]; then
    prose="CLI $current is behind (latest $latest)"
    [[ "$stale" == true ]] && prose+=" — stale, update recommended"
  else
    prose="CLI $current is up to date"
  fi

  ok "$prose" \
     '{current:$cur, latest:$lat, behind:$beh, stale:$stl, lastUpdateOk:$luo, lastUpdateAt:$lua}' \
     --arg cur "$current" --arg lat "$latest" \
     --argjson beh "$behind" --argjson stl "$stale" \
     --argjson luo "$last_ok_json" --argjson lua "$last_at_json"
}

# The opt-in auto-APPLY cron and the passive new-version notice both key off this
# one file: its presence == "this box auto-updates", which is exactly why the
# notice stays silent once a box is enrolled (no point nagging a box that already
# updates itself).
readonly UPDATE_AUTOCRON="/etc/cron.d/5dive-self-update"

# cmd_update_auto <on|off> — DIVE-1689. Enroll (opt-in) or remove the daily
# self-update cron for OSS self-hosters who have no scheduler of their own. This
# is the auto-APPLY switch; it's OFF by default (fresh installs ship no cron —
# only a notice), so a box never starts auto-mutating itself without an explicit
# `5dive update --auto`. Root-gated (writes /etc/cron.d). Idempotent.
cmd_update_auto() {
  local mode="${1:-on}"
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "update --auto must run as root (sudo 5dive update --auto)"
  case "$mode" in
    on)
      [[ -d /etc/cron.d ]] || fail "$E_NOT_FOUND" "/etc/cron.d not present — cannot enroll auto-update on this host (run 'sudo 5dive self-update' by hand, or add your own scheduler)"
      cat > "$UPDATE_AUTOCRON" <<'AUTOCRON'
# 5dive OSS auto-update (DIVE-1689) — opt-in daily self-update for self-hosted
# boxes with no scheduler. Enrolled via `sudo 5dive update --auto`; remove with
# `sudo 5dive update --no-auto`. Managed hosts update via their own scheduler.
0 4 * * * root /usr/local/bin/5dive self-update >> /var/log/5dive-self-update.log 2>&1
AUTOCRON
      chmod 644 "$UPDATE_AUTOCRON"
      ok "auto-update ENABLED — daily 'self-update' at 04:00 ($UPDATE_AUTOCRON). New-version notices are now silent (this box updates itself). Disable with 'sudo 5dive update --no-auto'." \
         '{auto:true, cron:$c}' --arg c "$UPDATE_AUTOCRON"
      ;;
    off)
      if [[ -f "$UPDATE_AUTOCRON" ]]; then
        rm -f "$UPDATE_AUTOCRON"
        ok "auto-update DISABLED (removed $UPDATE_AUTOCRON). You'll still get a notice when a new version is out; update with 'sudo 5dive self-update'." \
           '{auto:false, cron:$c}' --arg c "$UPDATE_AUTOCRON"
      else
        ok "auto-update already off (no $UPDATE_AUTOCRON)." '{auto:false}'
      fi
      ;;
    *) fail "$E_USAGE" "usage: 5dive update --auto[=on|off] | --no-auto" ;;
  esac
}

# cmd_update_notice_pref <on|off> — DIVE-1689. Persist the operator's choice to
# silence (or re-enable) the passive new-version notice. Root-gated (writes the
# root-owned state dir the notice reads). `--no-notice` => off, `--notice` => on.
cmd_update_notice_pref() {
  local mode="$1"
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "update --no-notice/--notice must run as root (it writes $STATE_DIR)"
  local off="${STATE_DIR}/update-notice.off"
  case "$mode" in
    off)
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      : > "$off"
      ok "new-version notices SILENCED. Re-enable with 'sudo 5dive update --notice'." '{notice:false}'
      ;;
    on)
      rm -f "$off"
      ok "new-version notices ENABLED." '{notice:true}'
      ;;
    *) fail "$E_USAGE" "usage: 5dive update --no-notice | --notice" ;;
  esac
}

# _update_notice — DIVE-1689. Passive "a new version is available" nudge for the
# interactive OSS operator, run from the EXIT trap on ANY command so it catches
# them during normal use (they rarely run update verbs). The whole design is
# built around ONE invariant: it must NEVER touch the fleet hot path. Every guard
# below fails CLOSED, and the network probe sits BEHIND a 1/24h throttle whose
# stamp is written to the root-owned state dir — so a non-root/agent invocation
# can't even reach the network (it can't claim the throttle), and a root box
# probes at most once per day. Belt-and-braces: TTY-only, never under --json,
# never in a systemd/service (agent) context, silent when auto-update is enrolled
# or the operator opted out, and an env kill-switch for scripts.
_update_notice() {
  [[ -t 2 ]] || return 0                                # interactive stderr only (not pipes/cron/redirect)
  (( JSON_MODE )) && return 0                           # never pollute machine output
  [[ -z "${FIVE_NO_UPDATE_NOTICE:-}" ]] || return 0     # ad-hoc env kill-switch
  [[ -z "${INVOCATION_ID:-}" ]] || return 0             # systemd/service (fleet-agent) context
  [[ -f "$UPDATE_AUTOCRON" ]] && return 0               # auto-update on => no nag
  [[ -f "${STATE_DIR}/update-notice.off" ]] && return 0 # operator opted out

  # Throttle 1/24h. The stamp lives in the root-owned state dir; claiming the
  # window (the write) is what gates the network probe to root callers only —
  # if we can't persist the stamp we do NOT probe (fail-closed), which keeps
  # every non-root/agent invocation off the network entirely.
  local stamp="${STATE_DIR}/update-notice.ts" now last
  now=$(date +%s 2>/dev/null) || return 0
  if [[ -r "$stamp" ]]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < 86400 )) && return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$now" > "$stamp" 2>/dev/null || return 0  # claim window BEFORE probing

  local latest
  latest=$(_update_latest_version 3)                    # ≤3s, ≤1/day/box
  [[ -n "$latest" ]] || return 0
  version_lt "$FIVE_VERSION" "$latest" || return 0       # already current => silent

  local cyan="" bold="" dim="" reset=""
  if _init_color_enabled; then
    cyan=$'\033[38;5;81m'; bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
  fi
  printf '\n  %s%s↑ 5dive %s is available%s %s(you have %s)%s\n' \
    "$bold" "$cyan" "$latest" "$reset" "$dim" "$FIVE_VERSION" "$reset" >&2
  printf '  %supdate:%s sudo 5dive self-update   %sauto-update:%s sudo 5dive update --auto   %ssilence:%s sudo 5dive update --no-notice\n\n' \
    "$bold" "$reset" "$bold" "$reset" "$dim" "$reset" >&2
  return 0
}
