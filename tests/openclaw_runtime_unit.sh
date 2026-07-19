#!/usr/bin/env bash
# shellcheck disable=SC2016
# DIVE-1328: OpenClaw gets Node on PATH and never gates chat on a wizard.
# Static/source-level test: no root, network, users, or runtime state touched.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh

# Literal command-substitution/interpolation syntax is what these assertions
# intentionally validate in the generated shell source.
recipe="${TYPE_INSTALL[openclaw]}"
[[ "$recipe" == *'nvm install 24'* ]]
[[ "$recipe" == *'nvm use 24 --silent'* ]]
[[ "$recipe" == *'ln -sfn "$(nvm which 24)" /home/claude/.local/bin/node'* ]]
[[ "$recipe" == *'[[ "${FORCE_INSTALL:-0}" != 1 && -x "$(npm prefix -g)/bin/openclaw" ]]'* ]]
[[ "$recipe" == *'npm --loglevel=error --no-fund --no-audit install -g openclaw@latest'* ]]
[[ "$recipe" != *'https://openclaw.ai/install.sh'* ]]
[[ "$recipe" == *'ln -sfn "$(npm prefix -g)/bin/openclaw" /home/claude/.local/bin/openclaw'* ]]
[[ "$recipe" == *'&& [[ -x /home/claude/.local/bin/openclaw ]]'* ]]

create_src=$(<src/cmd_agent_create.sh)
[[ "$create_src" == *'PATH="/home/claude/.local/bin:/usr/bin:/bin"'* ]]
[[ "$create_src" == *'local openclaw_node="/home/claude/.local/bin/node"'* ]]
[[ "$create_src" == *'"$openclaw_node" "$openclaw_bin"'* ]]

# Reproduce the create-time failure mode with a real env-node launcher and an
# empty PATH. The launcher cannot resolve its shebang on its own, while the
# product's explicit-node invocation shape succeeds under the same environment.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/empty-path"
printf '%s\n' '#!/usr/bin/env node' 'process.stdout.write("openclaw-ok")' > "$tmp/openclaw"
chmod +x "$tmp/openclaw"
if env -i PATH="$tmp/empty-path" "$tmp/openclaw" >/dev/null 2>&1; then
  echo 'FAIL: env-node launcher unexpectedly ran without node on PATH' >&2
  exit 1
fi
node_bin=$(command -v node)
[[ "$(env -i PATH="$tmp/empty-path" "$node_bin" "$tmp/openclaw")" == "openclaw-ok" ]]

start_src=$(<5dive-agent-start)
[[ "$start_src" == *'resolve_openclaw_node()'* ]]
[[ "$start_src" == *'OPENCLAW_NODE_BIN="$(resolve_openclaw_node)"'* ]]
[[ "$start_src" == *'OPENCLAW_PATH_OVERRIDE="export PATH='* ]]
[[ "$start_src" == *'${STAGE_GUARD}${OPENCLAW_PATH_OVERRIDE}${CODEX_OVERRIDE}'* ]]
[[ "$start_src" == *'${BIN_Q} config set gateway.mode local && touch ${SENTINEL_Q}'* ]]

# The runtime prelude must not invoke the interactive configure command. Match
# executable interpolation + command so the explanatory comment is harmless.
if grep -q '${BIN_Q} configure' 5dive-agent-start; then
  echo 'FAIL: OpenClaw first boot still invokes the interactive configure wizard' >&2
  exit 1
fi

echo 'PASS: OpenClaw runtime has Node PATH + headless first-boot config'
