#!/usr/bin/env bash
# DIVE-1380 / DIVE-1689: post-install output promotes the supported self-update
# command, offers the opt-in auto-update verb (`update --auto`) for self-hosters
# instead of a hand-pasted crontab line, distinguishes managed nightly updates,
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

if grep -Fq 'sudo 5dive self-update' <<<"$output"; then
  ok_t "self-update is the primary upgrade path"
else
  bad_t "primary self-update hint" "$output"
fi
if grep -Fq 'Managed hosts already update nightly.' <<<"$output"; then
  ok_t "managed hosts are told not to duplicate the schedule"
else
  bad_t "managed nightly notice" "$output"
fi
if grep -Fq 'sudo 5dive update --auto' <<<"$output"; then
  ok_t "self-hosted opt-in auto-update verb is offered"
else
  bad_t "auto-update opt-in hint" "$output"
fi
if grep -Fq 'Fallback: curl -fsSL https://example.invalid/5dive/install.sh | sudo bash -s -- --upgrade' <<<"$output"; then
  ok_t "curl installer upgrade remains as fallback"
else
  bad_t "curl fallback" "$output"
fi

primary_line="$(grep -nF 'sudo 5dive self-update' <<<"$output" | head -n1 | cut -d: -f1)"
fallback_line="$(grep -nF 'Fallback: curl -fsSL' <<<"$output" | cut -d: -f1)"
if [[ -n "$primary_line" && -n "$fallback_line" && "$primary_line" -lt "$fallback_line" ]]; then
  ok_t "supported command appears before fallback"
else
  bad_t "upgrade hint ordering" "$output"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
