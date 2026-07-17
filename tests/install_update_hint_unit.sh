#!/usr/bin/env bash
# DIVE-1380: post-install output promotes the supported self-update command,
# distinguishes managed nightly updates from self-hosted opt-in scheduling,
# and preserves the raw installer upgrade as a fallback.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

if bash -n install.sh; then
  ok_t "install.sh parses"
else
  bad_t "install.sh syntax"
fi

# Execute only the side-effect-free final echo block so assertions cover the
# rendered user-facing text (including variable expansion), not just source.
output="$(sed -n '/^echo "Next steps:"/,$p' install.sh \
  | REPO=https://example.invalid/5dive GH_ORG=5dive-ai bash)"

if grep -Fq 'To upgrade later: sudo 5dive self-update' <<<"$output"; then
  ok_t "self-update is the primary upgrade path"
else
  bad_t "primary self-update hint" "$output"
fi
if grep -Fq 'Managed hosts already update nightly.' <<<"$output"; then
  ok_t "managed hosts are told not to duplicate the schedule"
else
  bad_t "managed nightly notice" "$output"
fi
if grep -Fq '0 4 * * * /usr/local/bin/5dive self-update' <<<"$output"; then
  ok_t "self-hosted root-crontab example is offered"
else
  bad_t "self-hosted cron hint" "$output"
fi
if grep -Fq 'Fallback: curl -fsSL https://example.invalid/5dive/install.sh | sudo bash -s -- --upgrade' <<<"$output"; then
  ok_t "curl installer upgrade remains as fallback"
else
  bad_t "curl fallback" "$output"
fi

primary_line="$(grep -nF 'To upgrade later: sudo 5dive self-update' <<<"$output" | cut -d: -f1)"
fallback_line="$(grep -nF 'Fallback: curl -fsSL' <<<"$output" | cut -d: -f1)"
if [[ -n "$primary_line" && -n "$fallback_line" && "$primary_line" -lt "$fallback_line" ]]; then
  ok_t "supported command appears before fallback"
else
  bad_t "upgrade hint ordering" "$output"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
