#!/usr/bin/env bash
# DIVE-3509 — buzz onboarding, the CLI half.
#
# WHY THIS EXISTS. `--channels=buzz` used to be a no-op that reported success:
# valid_channel accepted it, the registry recorded it, 5dive-agent-start emitted
# `--channels plugin:buzz@5dive-plugins`, and the create's own self-check printed
# "poller up" — while the box had no buzz plugin, no config.json, and no `buzz`
# binary. Measured on a fresh customer-shaped box (sure-redwood, 2026-08-17).
#
# Enabling buzz for an agent is SIX things, and only the first was ever wired:
#   1. record the channel on the agent            (registry / agent config)
#   2. install the buzz plugin into the agent home (agent_setup.sh)
#   3. resolve the `buzz` binary                   (a customer box has none)
#   4. mint a nostr identity for THIS agent        (32-byte hex, 600, agent-owned)
#   5. choose a relay + join channels              (DIVE-3140 A+C)
#   6. publish profile + presence for the new key  (DIVE-3507)
#
# This command owns 2, 3 and 4 directly, and DRIVES 5 and 6 by calling
# `_buzz_join` (DIVE-3513, src/cmd_agent_buzz_join.sh) once the config is
# written. It is deliberately the thing the dashboard's "Connect Buzz" panel
# calls, so the OSS path and the managed path cannot drift (the body of DIVE-3509
# asks for exactly that ordering: CLI first, panel on top).
#
# `enable` used to STOP after step 4 and print 5 and 6 as prose. That is five of
# six wiring sites, which from the customer's side is indistinguishable from a
# broken relay. It now returns 5-and-6's rc: 0 when the whole chain is wired, 3
# when it is declared but not usable — the same predicate `status` returns, so a
# caller (an operator, or the panel) branches on the exit code without parsing
# prose. `--no-join` keeps the old stop-at-4 behaviour for a box whose relay is
# not up yet, and says so out loud.

# cmd_agent_buzz <enable|join|owner|status> <name> [flags]
# `join` and `owner` are DIVE-3513 (src/cmd_agent_buzz_join.sh) — steps 5 and 6.
cmd_agent_buzz() {
  local verb="${1:-}"
  case "$verb" in
    enable) shift; _buzz_enable "$@" ;;
    join)   shift; _buzz_join "$@" ;;
    owner)  shift; _buzz_owner "$@" ;;
    pair)   shift; _buzz_pair "$@" ;;
    status) shift; _buzz_status "$@" ;;
    ""|-h|--help)
      fail "$E_USAGE" "usage: 5dive agent buzz enable <name> [--relay=<https://…>] [--channels=<csv>] [--poll-ms=<n>] [--buzz-path=<path>] [--rotate-key] [--no-join]
       5dive agent buzz join <name> [--channels=<csv>] [--rotate-owner-key]
       5dive agent buzz owner <name> [--envelope]
       5dive agent buzz pair <name> [--timeout=<secs>]
       5dive agent buzz status <name>" ;;
    *) fail "$E_USAGE" "unknown buzz verb '$verb' (enable|join|owner|pair|status)" ;;
  esac
}

# Resolve the agent's buzz state dir. Kept in one place: publish-profile.sh in
# the plugin hardcodes the same two shapes, and a third spelling here would be a
# silent split-brain.
_buzz_state_dir() { printf '/home/agent-%s/.claude/channels/buzz\n' "$1"; }

# Where the `buzz` binary is, or empty. Checks the agent's own PATH view first
# (the plugin spawns it as the agent user), then the two locations our control
# plane uses. Never invents a path that does not exist — the config's buzz_path
# pointing at an absent binary is precisely the DIVE-3509 failure.
_buzz_resolve_binary() {
  local user="$1" p
  p=$(sudo -u "$user" -H bash -lc 'command -v buzz' 2>/dev/null) || p=""
  [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  for p in /usr/local/bin/buzz /opt/buzz/bin/buzz; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# The config writer, factored out of the enable path so it is gradeable without
# an agent user, root, or a relay. `runas` is the agent user in production; a
# harness passes its own name and the sudo hop is skipped. The shape here IS the
# contract plugins/buzz/server.ts validates — five fields, private_key 64 hex —
# so a drift on either side is a config the plugin silently refuses to load.
#
# THE KEY TRAVELS ON STDIN, NEVER ON ARGV (ops, on the DIVE-3509 push gate). The
# first shape of this function passed it as `env KEY=<hex> …`, which makes the
# secret an ARGV ELEMENT of the sudo command — and `/proc/<pid>/cmdline` is
# world-readable, with no hidepid on our boxes (positive-controlled). Every other
# agent user on the box could read a freshly minted private key for the width of
# the write. `/proc/<pid>/environ` is 0400 and would have been fine; argv is not.
# So: the program goes to `python3 -c` (not secret), the non-secret fields stay in
# the environment, and the key is piped. Nothing that holds the key is ever a
# command-line argument, on either side of the sudo hop.
_buzz_write_config() { # <runas> <state_dir> <relay> <key> <channels-csv> <poll_ms> <buzz_path>
  local runas="$1" state="$2" relay="$3" key="$4" chans="$5" poll="$6" bin="$7"
  local -a pre=()
  [[ "$runas" != "$(id -un)" ]] && pre=(sudo -u "$runas")
  local prog='
import json, os, sys
key = sys.stdin.read().strip()
if not key:
    sys.exit("no private key on stdin")
state = os.environ["STATE"]
os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, "config.json")
cfg = {
    "relay_url": os.environ["RELAY"],
    "private_key": key,
    "channels": [c.strip() for c in os.environ["CHANS"].split(",") if c.strip()],
    "poll_ms": int(os.environ["POLL"]),
    "buzz_path": os.environ["BIN"],
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
print("    wrote " + path)
'
  # `sudo -u` without a tty and with stdin piped is exactly the shape the rest of
  # agent_setup.sh uses (bash -s <<EOF), so no new privilege assumption here.
  printf '%s' "$key" | "${pre[@]}" env STATE="$state" RELAY="$relay" \
      CHANS="$chans" POLL="$poll" BIN="$bin" python3 -c "$prog" >&2
}

# The last mile, as its own step so the BRANCH is gradeable without a relay.
# `enable` used to stop after step 4 and print steps 5 and 6 as prose — five
# wiring sites out of six, which is exactly what broken looks like from the
# customer's side (community/wiki/a-channel-is-six-wiring-sites-and-five-green-
# ones-is-what-broken-looks-like.md). `_buzz_join` is idempotent by construction,
# so calling it from here is safe on every re-run.
#
# It runs in a SUBSHELL on purpose: `join` refuses with `fail`, which exits, and
# enable has already done four steps whose result the operator needs to hear.
_buzz_enable_last_mile() { # <name> <resolved_bin> <do_join>
  local name="$1" resolved_bin="$2" do_join="$3" rc=0
  if [[ "$do_join" != "true" ]]; then
    warn "--no-join: channels NOT joined and no profile published. '$name' has an identity and a config and is not yet reachable from a handset. Finish with: sudo 5dive agent buzz join $name"
    return 0
  fi
  if [[ -z "$resolved_bin" ]]; then
    warn "Last mile SKIPPED — joining a channel IS a relay call and there is no \`buzz\` binary to make it with (DIVE-3512). Install one, then: sudo 5dive agent buzz join $name"
    return 0
  fi
  step "Last mile: joining channel(s), adding the customer's key as a member, publishing profile + presence"
  ( _buzz_join "$name" ) || rc=$?
  if ((rc == 0)); then
    ok "buzz is wired end to end for '$name' — pair a handset with: sudo 5dive agent buzz owner $name --envelope"
  else
    warn "buzz enabled for '$name' but the last mile did not fully wire (rc=$rc). A handset will land in a room the agent may not be in. Re-run: sudo 5dive agent buzz join $name"
  fi
  return "$rc"
}

_buzz_enable() {
  local name="" relay="" chans="" poll_ms="" buzz_path="" rotate="false" do_join="true"
  while (($#)); do
    case "$1" in
      --relay=*)      relay="${1#*=}" ;;
      --channels=*)   chans="${1#*=}" ;;
      --poll-ms=*)    poll_ms="${1#*=}" ;;
      --buzz-path=*)  buzz_path="${1#*=}" ;;
      --rotate-key)   rotate="true" ;;
      --no-join)      do_join="false" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent buzz enable <name> [--relay=<https://…>]"

  ensure_state
  local reg type
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  # Same claude-only rule install_channel_for_agent enforces. Checked here too so
  # the refusal lands at the keystroke rather than after we have minted a key.
  [[ "$type" == "claude" ]] \
    || fail "$E_VALIDATION" "channels=buzz is claude-only (agent '$name' is type $type)"

  local user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"

  # A relay URL is not derivable by the box. Managed boxes can pass their own
  # default in through the environment; an OSS self-hoster brings a domain
  # (community/wiki/buzz-byo-domain-the-oss-path-to-a-pairable-relay.md). Refuse
  # rather than guess — a wrong relay is a channel that reports success and
  # connects to nothing, which is the bug this command exists to end.
  [[ -z "$relay" ]] && relay="${FIVE_BUZZ_RELAY_URL:-}"
  [[ -n "$relay" ]] || fail "$E_USAGE" \
    "no relay chosen — pass --relay=<https://relay.example.com> (a release build of Buzz mobile refuses anything that is not https and refuses private/LAN hosts; see community/wiki/buzz-byo-domain-the-oss-path-to-a-pairable-relay.md)"

  # 1. the plugin. Idempotent — a re-run reinstalls in place, and a create that
  # already installed it costs one no-op. This is the step the create path was
  # missing entirely.
  step "Installing buzz plugin for $user (if absent)"
  install_channel_for_agent "$type" buzz "$name" ""

  # 2. the binary. Reported, never invented: if it is absent, the config still
  # gets written (so the identity survives) but enable exits telling the truth.
  local resolved_bin=""
  if [[ -n "$buzz_path" ]]; then
    resolved_bin="$buzz_path"
  else
    resolved_bin=$(_buzz_resolve_binary "$user" || true)
  fi

  # 3. the identity. 32 bytes of hex is what the plugin's server.ts validates
  # (/^[0-9a-fA-F]{64}$/) before it derives the x-only schnorr pubkey. Minted
  # ONCE per agent: a re-run must not silently rotate a key that a relay and a
  # paired handset already know — that would look like the agent left the room.
  local state_dir key
  state_dir=$(_buzz_state_dir "$name")
  local cfg="${state_dir}/config.json"
  key=""
  if [[ "$rotate" != "true" && -f "$cfg" ]]; then
    key=$(sudo -u "$user" jq -r '.private_key // ""' "$cfg" 2>/dev/null || echo "")
  fi
  if [[ ! "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    key=$(openssl rand -hex 32 2>/dev/null) \
      || fail "$E_NOT_INSTALLED" "openssl is required to mint a buzz identity"
    [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]] \
      || fail "$E_GENERIC" "minted key is not 32-byte hex — refusing to write a config the plugin will reject"
    step "Minted a new buzz identity for $user"
  else
    step "Reusing the existing buzz identity for $user"
  fi

  # 4. the config. Written AS the agent user, 0600, in its own home — the key is
  # the agent's, and nothing else on the box should be able to speak as it.
  [[ -n "$chans" ]]   || chans="general"
  [[ -n "$poll_ms" ]] || poll_ms=15000
  step "Writing $cfg (0600, owned by $user)"
  _buzz_write_config "$user" "$state_dir" "$relay" "$key" "$chans" "$poll_ms" "${resolved_bin:-buzz}" \
    || fail "$E_GENERIC" "could not write the buzz config for $user"

  # 5. record the channel on the agent so a restart actually launches it. Only
  # when it is not already there — cmd_config re-runs the plugin install, which
  # we have just done.
  local cur
  cur=$(jq -r --arg n "$name" '.agents[$n].channels // ""' <<<"$(registry_read)")
  if ! channel_in_list buzz "$cur"; then
    step "Adding buzz to agent '$name' channels (was: ${cur:-none})"
    local next="buzz"
    [[ -n "$cur" && "$cur" != "none" ]] && next="${cur},buzz"
    cmd_config "$name" set "channels=$next"
  fi

  ok "buzz enabled for '$name' — identity minted, config written, plugin installed."
  if [[ -z "$resolved_bin" ]]; then
    warn "NOT READY: no \`buzz\` binary on this box (looked at the agent's PATH, /usr/local/bin/buzz, /opt/buzz/bin/buzz). The plugin will start and every relay call will fail until one is installed; re-run with --buzz-path=<path> once it is."
  fi

  # Steps 5 and 6 (DIVE-3513). Whatever it does or refuses to do, it SAYS —
  # the defect class this arc exists to end is a surface reporting success while
  # connected to nothing.
  local last_mile_rc=0
  _buzz_enable_last_mile "$name" "$resolved_bin" "$do_join" || last_mile_rc=$?

  warn "Restart to pick it up: sudo 5dive agent restart $name"
  # DIVE-3558: `enable` returns the last mile's rc on the SAME predicate `status`
  # returns 3 on, and `_buzz_enable_last_mile` has already warned with that rc and
  # the re-run command. Claim the report so the backstop does not staple its
  # "this is a bug in the CLI ... effect is UNKNOWN" block under a run that
  # completed and said what it did.
  if ((last_mile_rc != 0)); then mark_reported; fi
  return "$last_mile_rc"
}

# Read-only. Exists so an operator (and the dashboard panel) can ask "is buzz
# actually wired for this agent" and get the real predicate rather than the
# agent unit's liveness, which is what said "poller up" over a box with no buzz
# plugin at all.
_buzz_status() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent buzz status <name>"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local user="agent-${name}" state_dir cfg chan_decl="no" plugin="no" conf="no" bin="no" bin_path=""
  state_dir=$(_buzz_state_dir "$name")
  cfg="${state_dir}/config.json"
  channel_in_list buzz "$(jq -r --arg n "$name" '.agents[$n].channels // ""' <<<"$reg")" && chan_decl="yes"
  find "/home/${user}/.claude/plugins/cache" -maxdepth 3 -type d -name buzz -print -quit 2>/dev/null \
    | grep -q . && plugin="yes"
  jq -e '.relay_url and .private_key' "$cfg" >/dev/null 2>&1 && conf="yes"
  if bin_path=$(_buzz_resolve_binary "$user"); then bin="yes"; fi
  printf 'agent:            %s\n' "$name"
  printf 'channel declared: %s\n' "$chan_decl"
  printf 'plugin installed: %s\n' "$plugin"
  printf 'config readable:  %s (%s)\n' "$conf" "$cfg"
  printf 'buzz binary:      %s%s\n' "$bin" "${bin_path:+ ($bin_path)}"
  [[ "$conf" == "yes" ]] && printf 'relay_url:        %s\n' "$(jq -r '.relay_url' "$cfg" 2>/dev/null)"
  # Exit non-zero when it is declared but not usable, so a caller can branch on
  # it without parsing prose.
  #
  # DIVE-3558. rc=3 is the DESIGNED "declared but not usable" value and the table
  # above is its whole answer — but the EXIT backstop in lib/output.sh appends
  # "exited 3 without reporting a reason. This is a bug in the CLI ... the command
  # did NOT run to completion and its effect is UNKNOWN ... Please file it" to any
  # non-zero exit that has not claimed its report. On the FIRST verb of the Connect
  # Buzz path that turns the ordinary, expected "not wired yet" answer into a crash
  # notice, and every correctly-wired-but-not-yet-ready seat reads as broken. It DID
  # run to completion and its effect is exactly nothing.
  #
  # `mark_reported` is what claims the report (same fix pattern as DIVE-2890 /
  # DIVE-2711 in cmd_council.sh and DIVE-3135 in cmd_gh.sh). Claiming it OBLIGES us
  # to make one: three `no`s in a table are a reading exercise, so the missing
  # pieces are named in prose and the fix command is printed.
  if [[ "$chan_decl" == "yes" && ( "$plugin" == "no" || "$conf" == "no" || "$bin" == "no" ) ]]; then
    local missing=""
    [[ "$plugin" == "no" ]] && missing="the buzz plugin"
    [[ "$conf" == "no" ]]   && missing="${missing:+${missing}, }a readable config (the agent's identity)"
    [[ "$bin" == "no" ]]    && missing="${missing:+${missing}, }the \`buzz\` binary"
    warn "NOT WIRED YET (rc=3, by design — this is the answer, not a crash): '$name' declares the buzz channel but is missing ${missing}. Wire it with: sudo 5dive agent buzz enable $name --relay=<https://relay.example.com>"
    mark_reported
    return 3
  fi
  return 0
}
