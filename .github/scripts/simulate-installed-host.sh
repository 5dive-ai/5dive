#!/usr/bin/env bash
# Seed a GitHub runner so it looks like a box with 5dive INSTALLED (DIVE-1919).
#
# EXTRACTED FROM unit-tests.yml BY DIVE-2829, and the reason is the reason this file
# has a header at all: the installed-host core tier now needs a SECOND job on a SECOND
# runner to confirm an over-budget red, and two jobs that seed their environment from
# two copies of the same YAML are two environments the moment either copy is edited.
# The confirmation is only worth anything if the second box measures the SAME corpus in
# the SAME environment, so the environment has to have one definition. Every comment
# below is the one that stood beside the line in the workflow; none of it is new.
set -euo pipefail

# live state dir + gate-proof enforcement flipped ON (as on the control plane) —
# catches harnesses whose gate paths escape STATE_DIR
sudo mkdir -p /var/lib/5dive
sudo touch /var/lib/5dive/gate-proof.enforce
sudo chmod 0644 /var/lib/5dive/gate-proof.enforce

# a real telegram-pi/-opencode checkout on the canonical fallback paths — catches
# assertions that only hold when the product is NOT installed
for p in telegram-pi telegram-opencode; do
  sudo mkdir -p "/usr/local/lib/5dive/$p"
  echo '// stub for the installed-host CI matrix' \
    | sudo tee "/usr/local/lib/5dive/$p/server.ts" >/dev/null
done

# DIVE-2018: a `claude` user and at least one `agent-*` user. The control plane has
# both; a CI runner has neither, so gate_nonce_unit.sh and gate_sudo_uid_forge_unit.sh
# `exit 0` at their own SKIP guard before ever reaching a verdict. After the canary fix
# they were the LAST two harnesses the probe could not reach in ANY environment — and
# they are the gate identity and SUDO_UID forge tests, i.e. exactly the coverage whose
# absence matters most. Two throwaway system users, no shell, no home.
# DIVE-2525: the GROUP, not just the users. `task init` chowns the store to
# root:claude, and `useradd -N` deliberately does NOT create a like-named group — so on
# a runner seeded with users alone the chown dies with "chown: invalid group:
# 'root:claude'", `task init` fails, and council_record_e2e.sh takes its own `|| exit 0`
# and skips. That skip is what the nightly union reported as NEVER PROBED in EITHER
# environment. It had been getting the group by accident from a corpus run earlier in
# the same job; splitting the probe into its own job removed the accident and the union
# said so immediately, which is the rail working.
sudo groupadd -f claude
sudo useradd -M -N -s /usr/sbin/nologin claude 2>/dev/null || true
sudo useradd -M -N -s /usr/sbin/nologin agent-dev 2>/dev/null || true
getent passwd claude agent-dev
