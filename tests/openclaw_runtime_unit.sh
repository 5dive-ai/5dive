#!/usr/bin/env bash
# shellcheck disable=SC2016
# DIVE-1328: OpenClaw gets Node on PATH and never gates chat on a wizard.
# Static/source-level test: no root, network, users, or runtime state touched.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${tmp:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
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
# DIVE-8705: a pinned release, never @latest; a known-bad installed copy is replaced.
[[ "$recipe" == *"npm --loglevel=error --no-fund --no-audit install -g openclaw@${OPENCLAW_PIN_VERSION}"* ]]
[[ "$OPENCLAW_PIN_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]
[[ "$recipe" != *'openclaw@latest'* ]]
# The bad-version check, run for real against package.json files.
bad_re=$(sed -n "s/.*grep -qE '\([^']*\)' .*/\1/p" <<<"$recipe")
[[ -n "$bad_re" ]]
printf -v pkg '{\n  "name": "openclaw",\n  "version": "2026.11.5",\n'
grep -qE "$bad_re" <<<"$pkg"
printf -v pkg '{\n  "name": "openclaw",\n  "version": "%s",\n' "$OPENCLAW_PIN_VERSION"
if grep -qE "$bad_re" <<<"$pkg"; then echo "FAIL: bad-version check matched: pin" >&2; exit 1; fi
printf -v pkg '{\n  "version": "2026.11.50",\n'
if grep -qE "$bad_re" <<<"$pkg"; then echo "FAIL: bad-version check matched: 2026.11.50" >&2; exit 1; fi
printf -v pkg '{\n  "version": "2026x11y5",\n'
if grep -qE "$bad_re" <<<"$pkg"; then echo "FAIL: bad-version check matched: 2026x11y5" >&2; exit 1; fi
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
mkdir -p "$tmp/empty-path"
printf '%s\n' '#!/usr/bin/env node' 'process.stdout.write("openclaw-ok")' > "$tmp/openclaw"
chmod +x "$tmp/openclaw"
if env -i PATH="$tmp/empty-path" "$tmp/openclaw" >/dev/null 2>&1; then
  echo 'FAIL: env-node launcher unexpectedly ran without node on PATH' >&2
  exit 1
fi
node_bin=$(command -v node)
[[ "$(env -i PATH="$tmp/empty-path" "$node_bin" "$tmp/openclaw")" == "openclaw-ok" ]]

start_src=$(<bin/5dive-agent-start)
[[ "$start_src" == *'resolve_openclaw_node()'* ]]
[[ "$start_src" == *'OPENCLAW_NODE_BIN="$(resolve_openclaw_node)"'* ]]
[[ "$start_src" == *'OPENCLAW_PATH_OVERRIDE="export PATH='* ]]
[[ "$start_src" == *'${STAGE_GUARD}${OPENCLAW_PATH_OVERRIDE}${CODEX_OVERRIDE}'* ]]
[[ "$start_src" == *'${BIN_Q} config set gateway.mode local && touch ${SENTINEL_Q}'* ]]

# The runtime prelude must not invoke the interactive configure command. Match
# executable interpolation + command so the explanatory comment is harmless.
if grep -q '${BIN_Q} configure' bin/5dive-agent-start; then
  echo 'FAIL: OpenClaw first boot still invokes the interactive configure wizard' >&2
  exit 1
fi

echo 'PASS: OpenClaw runtime has Node PATH + headless first-boot config'
