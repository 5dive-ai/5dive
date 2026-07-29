
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

# >>> DIVE-2287 version-freeze observer
#     (tests/version_freeze_observer_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# Every staleness signal we have is a COMPARISON against a published "latest".
# That family shares one blind spot: when the release process itself stops, the
# comparand stops moving too, every box compares equal, and the whole fleet
# reports green while nothing has updated for a week. DIVE-2243's monotonicity
# guard sharpened this — it converted a silent fleet-wide DOWNGRADE into a loud
# refusal plus a frozen fleet, and nothing alarms on a frozen fleet. A guard
# that turns a wrong answer into no answer has moved which silence you live
# with, not removed it.
#
# So this observation is ABSOLUTE and takes no comparand: has the version this
# box RUNS changed, ever, within N days. It stays true when the cutter is dead,
# when the tag is frozen, when the probe is offline, and when --check is wrong.
#
# WHY IT NEEDS A RECORD AND CANNOT READ ONE OFF THE BOX. The obvious baseline is
# the installed binary's mtime — "when was 5dive last written". It is WRONG, and
# silently so: `refresh_managed_files()` swaps the bundle in UNCONDITIONALLY
# (`mv -f "$_bundle_tmp" "$BIN_DIR/5dive"`), with no already-current branch. The
# nightly rewrites the file every night whether or not the version moved, so
# mtime measures the last UPDATE ATTEMPT and never the last version CHANGE — the
# exact two things this alarm exists to tell apart. A freeze read off mtime
# would report "moved yesterday" forever, i.e. a monitor that cannot fire.
#
# ABSENT RECORD IS UNKNOWN, NOT FRESH (DIVE-2230's rule). A missing record is
# emitted identically by "first pass on a new box" and "record wiped", so it
# resolves to neither: we seed it and answer `unknown`. Reporting a green from
# an absent record would rebuild the fail-open one layer down.
#
# Prints exactly three lines (never fails the caller):
#   1  state       moving | frozen | unknown
#   2  age_secs    seconds since the running version was first observed ('' if unknown)
#   3  detail      human phrase — always the OBSERVED claim ("not observed to
#                  change"), never the stronger unobserved one ("did not change")
_CLI_FREEZE_AFTER_SECS=$((7 * 86400))
_cli_freeze_observe() {
  local cur="${1:-}" record="${2:-}" now="${3:-}"
  _cfo_out() { printf '%s\n%s\n%s\n' "$1" "$2" "$3"; }
  [[ -n "$now" ]] || now=$(date +%s)
  [[ -n "$cur" ]] || { _cfo_out unknown "" "the running version is unreadable"; return 0; }
  [[ -n "$record" ]] || { _cfo_out unknown "" "no state dir to record version movement in"; return 0; }

  local seen_ver="" seen_at=""
  if [[ -r "$record" ]]; then
    seen_ver=$(jq -r '.version // empty' "$record" 2>/dev/null) || seen_ver=""
    seen_at=$(jq -r '.first_seen_epoch // empty' "$record" 2>/dev/null) || seen_at=""
    [[ "$seen_at" =~ ^[0-9]+$ ]] || seen_at=""
  fi

  # A version we have never recorded, or an unusable record, restarts the clock
  # — and the restart is itself the movement signal on every case but the first.
  if [[ -z "$seen_ver" || -z "$seen_at" || "$seen_ver" != "$cur" ]]; then
    # Best-effort write. A read-only STATE_DIR (`update --check` runs as a
    # non-root operator) must not fail the command — it degrades to `unknown`,
    # which is what an unrecordable observation honestly is.
    if [[ -w "$(dirname "$record")" || -w "$record" ]]; then
      printf '{"version":%s,"first_seen_epoch":%s,"first_seen_at":%s}\n' \
        "$(printf '%s' "$cur" | jq -R .)" "$now" \
        "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null | jq -R .)" \
        > "$record" 2>/dev/null || true
    fi
    if [[ -n "$seen_ver" && "$seen_ver" != "$cur" ]]; then
      _cfo_out moving "0" "version changed ${seen_ver} -> ${cur}"
    else
      _cfo_out unknown "" "no prior observation of this box's version — clock starts now"
    fi
    return 0
  fi

  local age=$(( now - seen_at ))
  (( age < 0 )) && { _cfo_out unknown "" "recorded observation is in the future — clock skew"; return 0; }
  local days=$(( age / 86400 ))
  if (( age >= _CLI_FREEZE_AFTER_SECS )); then
    _cfo_out frozen "$age" "CLI ${cur} has not been observed to change in ${days}d"
  else
    _cfo_out moving "$age" "CLI ${cur} first observed ${days}d ago"
  fi
}
# <<< DIVE-2287 version-freeze observer

# >>> DIVE-2042 published-version probe
#     (tests/update_check_propagation_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# _published_cli_probe — read the version the installer would actually give
# this box, and say how much we trust the read.
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
#   1. PIN to an IMMUTABLE ref. The split-generation window exists because
#      `main` MOVES. A release tag does not, so fetching both objects from
#      raw/<tag>/ closes the same window that pinning main->sha closed, for the
#      same reason and with one fewer round trip. (Fetch by tag NAME, never by
#      the sha `git ls-remote` prints for it: 97 of our tags are annotated, and
#      an annotated tag's own sha is the tag object, which raw.githubusercontent
#      does not serve. install.sh peels `^{}` for exactly this; the name needs
#      no peel because GitHub resolves the ref server-side.)
#   2. VERIFY. Hash the bundle we were ACTUALLY served and compare it to the
#      `.sha256` we were ACTUALLY served. Their disagreement IS the propagation
#      signal, and it is the only one there is if the CDN ever skews a tag.
#
# DIVE-2287 — WHICH REF DEFINES "LATEST". This probe used to read `main`, while
# `install.sh` installs the newest release TAG. When main runs ahead of the
# newest tag (the DIVE-2238 cutter outage; 0.17.2 assigned on main, v0.17.1 the
# newest tag) the two disagree, and the operator gets both halves at once:
#
#     5dive update --check   ->  CLI 0.16.32 is behind (latest 0.17.2)
#     sudo 5dive self-update ->  5dive upgraded: 0.16.32 -> 0.17.1
#
# ...then is told they are STILL behind, permanently, by a checker naming a
# version that does not exist as a tag and that no installer can deliver. Worse
# with DIVE-2243's monotonicity guard in place: a box that ever lands above the
# newest tag is REFUSED every subsequent upgrade while --check keeps insisting
# it is behind, and both messages are correct.
#
# So the probe resolves what the INSTALLER would resolve. The rungs below mirror
# install.sh's `resolve_gh_tag` deliberately — a second resolver that drifts from
# the first gives two answers to the one question this command exists to answer.
# NO fallback to main: falling back is precisely the defect, because main's
# version is not installable. Unresolvable tags => `unavailable`, which is honest
# and is also what the installer does (it fails CLOSED on the same condition).
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

  local org tags="" ref=""
  org=$(gh_org)
  # Rung 1: git ls-remote — exact, no API rate limit.
  if command -v git >/dev/null 2>&1; then
    tags=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --tags --refs \
      "https://github.com/$org/5dive" 'v*' 2>/dev/null | sed -n 's#.*refs/tags/##p') || tags=""
  fi
  # Rung 2: the tags atom feed — unauthenticated, not subject to the 60/hr
  # api.github.com limit a NAT'd fleet shares. Parse <id>, NOT <title>: the
  # title carries a human release headline after the tag and matches nothing.
  if [[ -z "$tags" ]]; then
    tags=$(curl -fsSL --max-time 10 "https://github.com/$org/5dive/tags.atom" 2>/dev/null \
      | sed -n 's#.*<id>tag:github.com,[0-9]*:Repository/[0-9]*/\([^<]*\)</id>.*#\1#p') || tags=""
  fi
  # Rung 3: the tags API, last before giving up.
  if [[ -z "$tags" ]]; then
    tags=$(curl -fsSL --max-time 10 "https://api.github.com/repos/$org/5dive/tags?per_page=100" 2>/dev/null \
      | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p') || tags=""
  fi
  # `sort -V`, never `sort`. The regex drops anything that is not a plain
  # vMAJOR.MINOR.PATCH release tag, so an rc or a `nightly` can never become the
  # thing we advertise — same filter install.sh applies before installing one.
  [[ -n "$tags" ]] && ref=$(printf '%s\n' "$tags" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  if [[ -z "$ref" ]]; then
    _pcp_out unavailable "" "no release tag resolves — the installer could not upgrade this box either"
    return 0
  fi

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
    # DIVE-1977's rule: name only the cause we can justify. Both objects came
    # from ONE immutable tag, so this is NOT the mutable-ref cache skew the old
    # unpinned path suffered — but a freshly cut tag is still being cached for
    # the first time when a box asks, so "propagation" and "bad bytes" are both
    # live and we are not entitled to pick. State the fact, name the ref, say
    # retry; do not accuse an operator's mirror of tampering on a coin flip.
    detail="the bundle published at $ref does not match its own checksum — either the tag is still propagating or the bytes are bad"
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

  local behind=false ahead=false
  version_lt "$current" "$latest" && behind=true
  # DIVE-2287: a box ABOVE the newest release is its own state, not "up to
  # date". It is the state DIVE-2243's guard REFUSES every upgrade from, so
  # folding it into the green is how an operator ends up staring at "up to
  # date" and "refusing to DOWNGRADE" at the same time with no thread to pull.
  version_lt "$latest" "$current" && ahead=true

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

  # DIVE-2287 freeze observation — absolute, independent of $latest, so it
  # survives the release process being down (which is exactly when every
  # comparison-based signal above goes quiet).
  local -a fz=()
  mapfile -t fz < <(_cli_freeze_observe "$current" "${STATE_DIR}/cli-version-seen.json")
  local frozen_state="${fz[0]:-unknown}" frozen_age="${fz[1]:-}" frozen_detail="${fz[2]:-}"

  local prose
  if [[ "$behind" == true ]]; then
    prose="CLI $current is behind (latest $latest)"
    [[ "$stale" == true ]] && prose+=" — stale, update recommended"
  elif [[ "$ahead" == true ]]; then
    prose="CLI $current is AHEAD of the newest release $latest — the installer will refuse to move it (a release cut is owed)"
  else
    prose="CLI $current is up to date"
  fi
  [[ "$frozen_state" == frozen ]] && prose+=" · ⚠ $frozen_detail"

  # `behind`/`stale` keep their existing meaning and are only ever emitted on
  # the consistent path — the indeterminate branch above exits before here, so
  # a false `stale:false` can no longer be minted from a stale read.
  # `source` names the ref the answer came from (a 40-char sha when pinned,
  # "main" on the unpinned fallback) so a surprising number can be re-fetched
  # at the exact identity that produced it.
  # `ahead` and `frozen` are ADDITIVE — `behind`/`stale` keep their exact prior
  # meaning so the dashboard tile and every existing caller read the same field
  # they always did. `frozen` is a THREE-state string, not a boolean: an absent
  # or unwritable record is "unknown", and a caller must not be able to read a
  # green out of an observation we never made.
  ok "$prose" \
     '{current:$cur, latest:$lat, behind:$beh, ahead:$ahd, stale:$stl, frozen:$fz, frozenAgeSec:$fza, frozenDetail:$fzd, lastUpdateOk:$luo, lastUpdateAt:$lua, source:$src}' \
     --arg cur "$current" --arg lat "$latest" --arg src "$detail" \
     --arg fz "$frozen_state" --arg fzd "$frozen_detail" \
     --argjson fza "${frozen_age:-null}" \
     --argjson beh "$behind" --argjson ahd "$ahead" --argjson stl "$stale" \
     --argjson luo "$last_ok_json" --argjson lua "$last_at_json"
}
