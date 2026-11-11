#!/usr/bin/env bash
# DIVE-8174 — the one-time secret page names no platform. A partner's client opens
# it (a saved login, a key an agent asked for) and must never read the platform's
# name; the expired-link line used to say "Open the task again in the 5dive app",
# which is also wrong for a saved login (there is no task).
#
# U1 every text the page shows (GONE's titles and lines) is free of the name
# U2 mutant: the old expired line put back turns U1 red (the check bites)
#
# Run: bash tests/secret_drop_page_unbranded_unit.sh   (no root, no network)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
pass=0 failn=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$1"; }

# The GONE table's quoted strings: what a person reads on a dead or used link.
gone_texts() { awk '/^GONE = \{/,/^\}/' "$1" | grep -oE '"[^"]+"'; }

texts=$(gone_texts src/cmd_secret_drop.sh)
[[ $(printf '%s\n' "$texts" | wc -l) -ge 6 ]] || bad "U0 GONE table not found (got: $texts)"
if printf '%s\n' "$texts" | grep -qi '5dive'; then bad "U1 a page text names the platform: $(printf '%s\n' "$texts" | grep -i 5dive)"; else ok "U1 page texts are unbranded"; fi

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
sed 's|"Ask for a new link where you opened this one."|"Open the task again in the 5dive app for a new link."|' src/cmd_secret_drop.sh > "$tmp"
if cmp -s "$tmp" src/cmd_secret_drop.sh; then bad "U2 mutation did not apply"
elif gone_texts "$tmp" | grep -qi '5dive'; then ok "U2 the old line is caught"
else bad "U2 the old line was not caught"; fi

printf '%d pass, %d fail\n' "$pass" "$failn"
(( failn == 0 ))
