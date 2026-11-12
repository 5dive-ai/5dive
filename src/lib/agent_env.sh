#!/usr/bin/env bash
# Agent ENV-FILE readers. DIVE-2218.
#
# `${ENV_DIR}/<name>.env` is a SECOND source of truth for an agent's isolation
# tier, independent of the registry, and nothing reconciles the two. Three call
# sites read it with the same idiom -- `sed -n 's/^AGENT_ISOLATION=//p' "$ef"
# 2>/dev/null | head -1` -- and then default the empty result, so a missing file,
# an unreadable one and a genuinely-tiered agent all arrive spelled the same way.
#
# WHY THIS IS NOT agent_tier() (src/lib/registry.sh, DIVE-2213). Same shape,
# DIFFERENT SOURCE. Reusing that resolver here would answer a question about the
# registry and let the caller believe it had read the env file -- the exact
# mistake DIVE-2213 avoided by NOT reusing envelope_tier(). Two sources also means
# they can DISAGREE, which is a fact worth surfacing rather than hiding behind
# whichever one a given call site happens to read (agent_isolation_2src below).
#
# WHY THE DEFAULT WAS THE BUG, not the read. Per DIVE-2213: a default is not safe
# or unsafe in itself, its polarity is a property of the SITE. `iso="${iso:-admin}"`
# in cmd_agent_teambot.sh MANUFACTURED the top tier at a privilege site and then
# PERSISTED it through write_agent_env -- a transient read failure becoming a
# durable admin label on disk, which `5dive agent info` then compares against the
# enforced sudoers grant. So these resolvers cannot return empty and cannot invent
# a tier; they hand back a REASON and let each site pick its own polarity, the way
# cmd_agent_pairing.sh already does (fail-safe to `standard`, DIVE-1571).

# agent_env_isolation <name> -- the tier recorded in the agent's env file.
#
# Prints a bare tier token, or `unknown:<reason>`. Never empty, and a failure is
# NEVER spelled like a tier.
#   unknown:no-name         no agent name supplied
#   unknown:no-env-file     ${ENV_DIR}/<name>.env does not exist
#   unknown:env-unreadable  it exists and could not be read (mode, ACL, dangling)
#   unknown:no-field        read fine, no AGENT_ISOLATION line
#   unknown:malformed-tier  line present, value is not a bare token
#
# `no-field` is kept distinct from `no-env-file` on purpose: it is the shape a
# legacy env file written before the field existed takes, and a caller may want to
# fall back to the registry for it while treating an unreadable file as a hard
# stop (the file's OTHER fields are unreadable too, so nothing sourced from it can
# be trusted). None of the five is a measurement OF THE TIER -- unlike the
# registry's `unknown:unregistered`, which measures that a name is not an agent,
# an env file that will not answer says nothing at all.
agent_env_isolation() {
  local name="${1:-}"
  [[ -n "$name" ]] || { printf 'unknown:no-name\n'; return 0; }
  local ef="${ENV_DIR}/${name}.env"
  # -e, not -r: an existing-but-unreadable file must reach the `cat` below so it
  # reports env-unreadable rather than collapsing into no-env-file. A dangling
  # symlink fails -e and reads as no-env-file, which is the honest answer for it.
  [[ -e "$ef" ]] || { printf 'unknown:no-env-file\n'; return 0; }
  local body
  body="$(cat -- "$ef" 2>/dev/null)" || { printf 'unknown:env-unreadable\n'; return 0; }
  local v
  v="$(printf '%s\n' "$body" | sed -n 's/^AGENT_ISOLATION=//p' | head -1)"
  v="${v%$'\r'}"                       # CRLF-written env file
  v="${v%\"}"; v="${v#\"}"             # quoted value
  v="${v%\'}"; v="${v#\'}"
  [[ -n "$v" ]] || { printf 'unknown:no-field\n'; return 0; }
  # Same injection rule as agent_tier(): a tier is a bare token or it is unusable.
  # A site must never rank, compare or PERSIST a value it could not validate.
  [[ "$v" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { printf 'unknown:malformed-tier\n'; return 0; }
  printf '%s\n' "$v"
}

# agent_env_isolation_unmeasured <value> -- true when the env file did not answer.
#
# EVERY unknown:* qualifies, which is where this deliberately differs from
# tier_unmeasured(): that predicate has to exclude `unknown:unregistered` because
# the registry can measure a genuine absence. An env file has no such case, so the
# rule here is total. Keep the polarity in this one predicate and no caller can
# re-collapse the reasons by hand-writing `unknown:*`.
agent_env_isolation_unmeasured() {
  case "$1" in
    unknown:*) return 0 ;;
    *)         return 1 ;;
  esac
}

# agent_isolation_2src <name> -- isolation across BOTH sources of truth.
#
# Prints `<value>\t<provenance>`. The value is a bare tier token, or the literal
# `unknown:unmeasured` when neither source answered -- never a fabricated tier, so
# a caller that forgets to check still cannot mistake a hole for a real value.
#
#   env                          env file answered (registry agrees, or did not answer)
#   env:disagrees-registry:<r>   BOTH answered and they DIFFER; value is the env file's
#   registry:<env-reason>        env file did not answer, registry did
#   unmeasured:<env-r>:<reg-r>   neither answered
#
# The env file WINS a disagreement because it is what these call sites act on and
# what they rewrite; the point of the provenance string is that the disagreement
# stops being invisible. Callers own their own fallback: there is no safe global
# polarity for a tier (DIVE-2213), only a safe one per site.
agent_isolation_2src() {
  local name="${1:-}"
  local e r
  e="$(agent_env_isolation "$name")"
  r="$(agent_tier "$name")"
  if ! agent_env_isolation_unmeasured "$e"; then
    if [[ "$r" != unknown:* && "$r" != "$e" ]]; then
      printf '%s\tenv:disagrees-registry:%s\n' "$e" "$r"
    else
      printf '%s\tenv\n' "$e"
    fi
    return 0
  fi
  if [[ "$r" != unknown:* ]]; then
    printf '%s\tregistry:%s\n' "$r" "${e#unknown:}"
    return 0
  fi
  printf 'unknown:unmeasured\tunmeasured:%s:%s\n' "${e#unknown:}" "${r#unknown:}"
}

# ---------------------------------------------------------------------------
# DIVE-8294: one OpenClaw gateway port per seat.
#
# Every OpenClaw seat with a channel runs `openclaw gateway run`, and every one
# bound openclaw's default 127.0.0.1:18789. Each seat is its own Linux user, but
# loopback ports belong to the whole host, so a second OpenClaw seat's gateway
# could not bind and that agent never answered. OpenClaw resolves the port the
# same way for the gateway and for its clients (`openclaw agent`, which the web
# chat bridge runs): $OPENCLAW_GATEWAY_PORT, then gateway.port in the seat's
# openclaw.json, then 18789. So the seat's own port is recorded here, in
# AGENT_OPENCLAW_PORT of ${ENV_DIR}/<name>.env (the record 5dive-agent-start
# already reads), and 5dive-agent-start writes it into the config and the env.
#
# Ports are 18789 + 200*n. 200 because OpenClaw derives more ports from the
# gateway's: browser control at +2 and a browser CDP range at +11..+110.
# The first seat keeps 18789. An existing seat with no port gets one on its
# next start (`agent _seed_perms`, the unit's root pre-start step).
OPENCLAW_PORT_BASE=18789
OPENCLAW_PORT_STEP=200
OPENCLAW_PORT_SLOTS=230

openclaw_port_valid() {
  [[ "${1:-}" =~ ^[1-9][0-9]{3,4}$ ]] && (( 10#$1 <= 65535 ))
}

# openclaw_port_listening <port> -- 0 when anything on this host LISTENs on it.
# Reads /proc/net/tcp{,6} (no ss/netstat dependency). Tests point
# OPENCLAW_PORT_NET_FILES at fixtures.
openclaw_port_listening() {
  local hex f files=()
  hex=$(printf '%04X' "$1")
  for f in ${OPENCLAW_PORT_NET_FILES:-/proc/net/tcp /proc/net/tcp6}; do
    [[ -r "$f" ]] && files+=("$f")
  done
  (( ${#files[@]} )) || return 1
  awk -v h="$hex" 'FNR > 1 { n = split($2, a, ":"); if (a[n] == h && $4 == "0A") f = 1 }
                   END { exit !f }' "${files[@]}" 2>/dev/null
}

# openclaw_ports_taken [<self>] -- every port recorded for another seat.
openclaw_ports_taken() {
  local self="${1:-}" f n
  for f in "$ENV_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    n="${f##*/}"; n="${n%.env}"
    [[ "$n" == "$self" ]] && continue
    sed -n 's/^AGENT_OPENCLAW_PORT=//p' "$f" 2>/dev/null | head -1
  done
}

# openclaw_port_pick [<self>] -- the lowest slot no other seat holds and nothing
# listens on. Call it under openclaw_port_ensure's lock.
openclaw_port_pick() {
  local self="${1:-}" taken i p
  taken=" $(openclaw_ports_taken "$self" | tr '\n' ' ') "
  for (( i = 0; i < OPENCLAW_PORT_SLOTS; i++ )); do
    p=$(( OPENCLAW_PORT_BASE + i * OPENCLAW_PORT_STEP ))
    [[ "$taken" == *" $p "* ]] && continue
    openclaw_port_listening "$p" && continue
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

# openclaw_port_ensure <name> -- print the seat's port, picking and recording one
# when its env file has none. Its own lock, NOT the registry lock: `agent
# restart` holds that across `systemctl restart`, which runs the pre-start step
# that calls this (DIVE-8195). Writes in place, so the file keeps owner and mode.
openclaw_port_ensure() {
  local name="${1:-}" ef cur
  [[ -n "$name" ]] || return 1
  ef="${ENV_DIR}/${name}.env"
  [[ -f "$ef" ]] || return 1
  cur=$(sed -n 's/^AGENT_OPENCLAW_PORT=//p' "$ef" 2>/dev/null | head -1)
  if openclaw_port_valid "$cur"; then printf '%s\n' "$cur"; return 0; fi
  (
    flock -x -w 30 201 || exit 1
    cur=$(sed -n 's/^AGENT_OPENCLAW_PORT=//p' "$ef" 2>/dev/null | head -1)
    if openclaw_port_valid "$cur"; then printf '%s\n' "$cur"; exit 0; fi
    p=$(openclaw_port_pick "$name") || exit 1
    body=$(grep -v '^AGENT_OPENCLAW_PORT=' "$ef" 2>/dev/null || true)
    { [[ -n "$body" ]] && printf '%s\n' "$body"; printf 'AGENT_OPENCLAW_PORT=%s\n' "$p"; } > "$ef" || exit 1
    printf '%s\n' "$p"
  ) 201>"${STATE_DIR}/openclaw-port.lock"
}
