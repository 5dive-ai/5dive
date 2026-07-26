
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

# How long the dashboard waits after a release before treating a still-behind
# box as "stale". One nightly soft-update (every 24h) should close the gap, so
# anything past ~1.5 days means the auto-update isn't keeping up.
readonly UPDATE_STALE_AFTER_SECS=$((36 * 3600))

# >>> DIVE-2042 published-version probe
#     (tests/update_check_propagation_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# _published_cli_probe — read the version main currently publishes, and say how
# much we trust the read.
#
# "What does main publish?" is a THREE-state question, not a value.
# raw.githubusercontent serves the bundle and its `.sha256` as two independent
# cache objects, so for minutes after every push to main it can hand back a
# STALE bundle beside a FRESH checksum — DIVE-1977 is the same window on the
# install path, and it has since been observed on the contents API too. A probe
# that can only return a version returns the stale one; the caller compares it
# to the local version, finds them equal, and reports a confident "up to date"
# to an operator asking precisely the question we could not answer. That window
# opens on EVERY push to main, and main HEAD is what customer boxes self-update
# from, so every ship has a period where a box asking "am I current?" is told
# yes and is wrong.
#
# Two defences, in order:
#   1. PIN. `git ls-remote` rides the git transport, not the raw CDN, so it has
#      no split-generation window. Resolve main -> ONE immutable sha and fetch
#      BOTH objects from raw/<sha>/, where they cannot disagree. Unresolvable
#      (no git, no network) -> fall back to /main rather than fail shut; a
#      probe that bricks is worse than the race it avoids.
#   2. VERIFY. Hash the bundle we were ACTUALLY served and compare it to the
#      `.sha256` we were ACTUALLY served. Their disagreement IS the
#      propagation signal, and on the unpinned path it is the only one there is.
#
# Prints exactly three lines (never fails the caller):
#   1  state    consistent | indeterminate | unavailable
#   2  version  the published FIVE_VERSION — empty unless state is consistent
#   3  detail   the ref the answer came from (consistent), else the reason.
#               Never empty, so line 3 always exists.
_published_cli_probe() {
  local state version detail
  _pcp_out() { printf '%s\n%s\n%s\n' "$1" "$2" "$3"; }

  command -v curl >/dev/null 2>&1 \
    || { _pcp_out unavailable "" "curl is not installed"; return 0; }
  command -v sha256sum >/dev/null 2>&1 \
    || { _pcp_out unavailable "" "sha256sum is not installed"; return 0; }

  local org pinned=""
  org=$(gh_org)
  if command -v git >/dev/null 2>&1; then
    pinned=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote \
      "https://github.com/$org/5dive" main 2>/dev/null | awk 'NR==1{print $1}') || pinned=""
    [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] || pinned=""
  fi
  local ref="${pinned:-main}"

  local tmp
  tmp=$(mktemp -d) || { _pcp_out unavailable "" "no writable temp dir"; return 0; }
  local base="https://raw.githubusercontent.com/$org/5dive/$ref" fetched=1
  curl -fsSL --max-time 10 -o "$tmp/5dive" "$base/5dive" 2>/dev/null || fetched=0
  curl -fsSL --max-time 10 -o "$tmp/5dive.sha256" "$base/5dive.sha256" 2>/dev/null || fetched=0
  if (( ! fetched )) || [[ ! -s "$tmp/5dive" || ! -s "$tmp/5dive.sha256" ]]; then
    rm -rf "$tmp"
    _pcp_out unavailable "" "could not fetch the published bundle and its checksum"
    return 0
  fi

  local served published
  served=$(sha256sum "$tmp/5dive" | awk '{print $1}')
  published=$(awk 'NR==1{print $1}' "$tmp/5dive.sha256")
  version=$(grep -m1 -oP '(?<=^readonly FIVE_VERSION=")[^"]+' "$tmp/5dive") || version=""
  rm -rf "$tmp"

  if [[ "$served" != "$published" ]]; then
    # Branch the explanation on whether we can justify the accusation
    # (DIVE-1977's rule). PINNED: both objects came from one immutable tree, so
    # cache skew cannot explain it and something is genuinely wrong. UNPINNED:
    # two cache generations is by far the likeliest cause, and rendering that
    # as tampering is an alarm scarier than the fault.
    if [[ -n "$pinned" ]]; then
      detail="the bundle published at ${pinned:0:12} does not match its own checksum"
    else
      detail="the published bundle and its checksum are from different CDN cache generations (release propagation in progress)"
    fi
    _pcp_out indeterminate "" "$detail"
    return 0
  fi
  if [[ -z "$version" ]]; then
    _pcp_out indeterminate "" "the published bundle carries no FIVE_VERSION"
    return 0
  fi
  _pcp_out consistent "$version" "$ref"
}
# <<< DIVE-2042 published-version probe

# cmd_update_check — read-only (no root, no mutation) version probe for the
# dashboard maintenance tile. Compares the installed CLI to the published
# release and reads the last nightly soft-update result, then reports whether
# the box is GENUINELY stale (behind AND the auto-update isn't catching up) vs
# merely a release or two behind with a healthy nightly that'll close the gap.
#
# DIVE-2042: this answers in THREE states, not two. up-to-date / behind /
# INDETERMINATE. A checker that can only say yes or no says yes when it does
# not know, and the propagation window (see _published_cli_probe) is exactly
# when it does not know. Indeterminate exits NON-ZERO so an unattended caller
# branches on status alone and never reads a green it wasn't given.
cmd_update_check() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "update --check takes no arguments"
  command -v curl >/dev/null 2>&1 || fail "$E_NOT_FOUND" "curl is required for update --check"

  local current="$FIVE_VERSION" probe
  probe=$(_published_cli_probe)
  local -a p=()
  mapfile -t p <<<"$probe"
  local state="${p[0]:-unavailable}" latest="${p[1]:-}" detail="${p[2]:-no detail}"

  case "$state" in
    consistent) ;;
    indeterminate)
      # Worded to avoid the substring "up to date" entirely: this line lands in
      # nightly logs beside the green one, and half a grep must not read as a
      # pass.
      fail "$E_GENERIC" \
        "cannot determine whether CLI $current is current — $detail; retry in a few minutes" ;;
    *)
      fail "$E_GENERIC" "could not determine the latest published version — $detail" ;;
  esac
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

  # `behind`/`stale` keep their existing meaning and are only ever emitted on
  # the consistent path — the indeterminate branch above exits before here, so
  # a false `stale:false` can no longer be minted from a stale read.
  # `source` names the ref the answer came from (a 40-char sha when pinned,
  # "main" on the unpinned fallback) so a surprising number can be re-fetched
  # at the exact identity that produced it.
  ok "$prose" \
     '{current:$cur, latest:$lat, behind:$beh, stale:$stl, lastUpdateOk:$luo, lastUpdateAt:$lua, source:$src}' \
     --arg cur "$current" --arg lat "$latest" --arg src "$detail" \
     --argjson beh "$behind" --argjson stl "$stale" \
     --argjson luo "$last_ok_json" --argjson lua "$last_at_json"
}
