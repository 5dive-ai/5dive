#!/usr/bin/env bash
# publish-zero-human.sh — thin back-compat shim for `5dive proof publish`.
#
# The publisher logic now lives in the CLI verb (src/cmd_proof.sh, OSS-17) so it
# is bundle-built and unit-tested. This script stays so existing daily crons keep
# working unchanged. The ZH_REPO / ZH_BRANCH / ZH_GIT_NAME / ZH_GIT_EMAIL env
# vars are still honored by the verb (repo/branch fall back to them when neither
# a flag nor the proof.json config is set).
#
# Usage: publish-zero-human.sh [--dry-run]
set -euo pipefail
exec "$(command -v 5dive || echo 5dive)" proof publish "$@"
