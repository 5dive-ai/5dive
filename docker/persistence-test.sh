#!/bin/bash
# DIVE-6802: prove docker/compose.yaml keeps an agent through everything a
# hosted box goes through. Run on a machine with Docker, from the repo root,
# after the image is built and tagged ghcr.io/5dive-ai/5dive:<tag>:
#
#   docker/persistence-test.sh <tag>
#
# Arms, each read back from INSIDE the container after the event:
#   A  fresh up: agent created, its unit active, an API key and a Telegram token saved
#   B  container recreate (compose down + up, volumes kept)
#   C  Docker daemon restart (restart: unless-stopped brings it back by itself)
#   D  update: a different CLI boots over the saved volumes; the entrypoint
#      re-runs install.sh, and the agent, key and token are all still there
#
# Needs network (installs the claude harness) and sudo for the daemon restart.
# Creates and then deletes the compose project `fivedive-ptest` and its volumes.
set -euo pipefail

tag="${1:?usage: docker/persistence-test.sh <image tag>}"
cd "$(dirname "$0")"
export FIVEDIVE_TAG="$tag" COMPOSE_PROJECT_NAME=fivedive-ptest
agent=ptest
key=sk-ant-persistence-test-0000000000
tg=123456789:persistence-test-token
pass=0

dc() { docker compose -f compose.yaml "$@"; }
dx() { docker exec 5dive "$@"; }
die() { echo "FAIL: $*" >&2; dc logs --tail=50 >&2 || true; exit 1; }
cleanup() { dc down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

booted() {
  local _
  for _ in $(seq 1 90); do
    state=$(dx systemctl is-system-running 2>/dev/null || true)
    case "$state" in running|degraded) return 0 ;; esac
    sleep 2
  done
  die "systemd did not finish booting (last: ${state:-no answer})"
}

agent_up() {
  local _
  for _ in $(seq 1 60); do
    dx systemctl is-active --quiet "5dive-agent@${agent}.service" && return 0
    sleep 2
  done
  dx systemctl status "5dive-agent@${agent}.service" --no-pager >&2 || true
  die "5dive-agent@${agent} is not active"
}

# The fingerprint of everything that must survive: the user, the unit, the
# registry entry, the saved key and the saved Telegram token.
fingerprint() {
  dx bash -c "
    set -e
    id -u agent-${agent}
    systemctl is-enabled 5dive-agent@${agent}.service
    jq -r '.agents | has(\"${agent}\")' /var/lib/5dive/agents.json
    grep -rl '${key}' /etc/5dive/connectors
    grep -c '${tg}' /home/agent-${agent}/.claude/channels/telegram/.env
  "
}

check() {
  local arm="$1" now
  booted
  agent_up
  now=$(fingerprint) || die "$arm: state unreadable after the event"
  [[ "$now" == "$before" ]] || die "$arm: state changed
--- before
$before
--- after
$now"
  echo "PASS $arm"
  pass=$((pass + 1))
}

cleanup
dc up -d
booted
dx 5dive agent install claude
dx 5dive agent create "$agent" --type=claude --channels=none --defer-auth
dx 5dive agent auth set claude --api-key="$key"
dx bash -c "install -d -o agent-${agent} -m 700 /home/agent-${agent}/.claude/channels/telegram \
  && printf 'TELEGRAM_BOT_TOKEN=%s\n' '${tg}' > /home/agent-${agent}/.claude/channels/telegram/.env"
agent_up
before=$(fingerprint) || die "A: fingerprint unreadable on the fresh box"
echo "$before"
echo "PASS A fresh up"; pass=$((pass + 1))

dc down
dc up -d
check "B container recreate"

sudo systemctl restart docker
check "C docker daemon restart"

# D: pretend the saved state was laid down by an older CLI. On the next start the
# entrypoint must see the mismatch, re-run install.sh, and record the new version.
dx bash -c 'echo 0.0.0-older > /var/lib/5dive/image-cli-version'
dc down
dc up -d
check "D update over saved volumes"
want=$(dx /usr/local/bin/5dive --version | tr -d '\n')
got=$(dx cat /var/lib/5dive/image-cli-version)
[[ "$got" == "$want" ]] || die "D: the entrypoint did not re-apply (marker '$got', CLI '$want')"
dx test -s /var/log/5dive-image-sync.log || die "D: no install.sh re-run log"

echo "$pass/4 arms pass on $(uname -m)"
