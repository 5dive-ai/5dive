#!/usr/bin/env bash
# DIVE-5622 unit harness: `5dive machine add|rm|ls`.
#
# Any box can attach any machine the user can SSH into; agents reach it as
# `ssh <name>`. The caller inputs are a name and user@host[:port], and both land
# in an ssh config, so the load-bearing arms are the refusals: a name or target
# carrying a newline, a space or a shell metachar must stop BEFORE anything is
# written. Then the effects: a real ssh-keygen keypair (group claude, 0640),
# `ssh -G` resolving the name through the written config, re-adding a name
# replacing its block rather than duplicating it, exactly ONE CLAUDE.md line
# that keeps the rest of the file, and `rm` leaving `ssh -G` unable to resolve.
#
# chgrp is a seam; every path is redirected into a temp dir. No root, no network.
#
# Run: bash tests/machine_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/machine-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_machine.sh"
set +e

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

export FIVE_MACHINE_DIR="$TMP/etc/5dive/machines"
export FIVE_MACHINE_SSH_CONF="$TMP/etc/ssh/ssh_config.d/50-5dive-machines.conf"
export FIVE_MACHINE_MD="$TMP/etc/claude-code/CLAUDE.md"
CONF="$FIVE_MACHINE_SSH_CONF"; MD="$FIVE_MACHINE_MD"
_machine_chgrp() { printf 'chgrp %s\n' "$*" >> "$TMP/calls"; }
require_root() { :; }
run() { ( cmd_machine "$@" ) > "$TMP/out" 2>&1; echo $? > "$TMP/rc"; }
rc() { cat "$TMP/rc"; }
resolves() { ssh -F "$CONF" -G "$1" 2>/dev/null | awk '$1=="hostname"{print $2}'; }

# --- refusals: nothing written --------------------------------------------------
refuse() { run add "$@"; check "add refuses: $(printf '%q ' "$@")" '[[ $(rc) != 0 && ! -e "$CONF" && ! -e "$FIVE_MACHINE_DIR" ]]'; }
refuse Bad x@h
refuse 'a$b' x@h
refuse a x
refuse a 'root@h;id'
refuse a $'root@h\nHost *'
refuse a 'root@h:0'
refuse a 'root@h:99999'
refuse a 'ro ot@h'
refuse a 'root@-oProxyCommand=x'
refuse a root@h extra
refuse a
run rm nope;  check "rm of an unknown name refuses (E_NOT_FOUND)" '[[ $(rc) == "$E_NOT_FOUND" ]]'

# --- add ------------------------------------------------------------------------
mkdir -p "$(dirname "$MD")"; printf '# Owner note\nkeep me\n' > "$MD"
run add test deploy@192.0.2.10:2222
check "add succeeds" '[[ $(rc) == 0 ]]'
check "keypair made, private key 0640 and handed to group claude" \
  '[[ $(stat -c %a "$FIVE_MACHINE_DIR/id_ed25519") == 640 ]] && grep -q "chgrp $FIVE_MACHINE_DIR/id_ed25519" "$TMP/calls"'
check "add prints the box's PUBLIC key and never the private one" \
  'grep -qF "$(cat "$FIVE_MACHINE_DIR/id_ed25519.pub")" "$TMP/out" && ! grep -q PRIVATE "$TMP/out"'
check "ssh -G resolves test through the written config" '[[ $(resolves test) == 192.0.2.10 ]]'
check "user, port, key and BatchMode land in the block" \
  'ssh -F "$CONF" -G test 2>/dev/null | grep -qx "user deploy" && ssh -F "$CONF" -G test 2>/dev/null | grep -qx "port 2222" && ssh -F "$CONF" -G test 2>/dev/null | grep -qx "batchmode yes"'
check "CLAUDE.md keeps the owner text and gains one machines line" \
  'grep -qx "keep me" "$MD" && [[ $(grep -c "5dive-machines" "$MD") == 1 ]] && grep -qF "\`ssh test\`" "$MD"'

pub1=$(cat "$FIVE_MACHINE_DIR/id_ed25519.pub")
run add web root@example.com
run add test deploy@192.0.2.11
check "re-adding a name replaces its block (one Host test, new address)" \
  '[[ $(grep -c "^Host test$" "$CONF") == 1 && $(resolves test) == 192.0.2.11 ]]'
check "the keypair is reused, not regenerated" '[[ $(cat "$FIVE_MACHINE_DIR/id_ed25519.pub") == "$pub1" ]]'
check "still ONE CLAUDE.md line, naming both machines" \
  '[[ $(grep -c "5dive-machines" "$MD") == 1 ]] && grep "5dive-machines" "$MD" | grep -qF "\`ssh web\`"'
JSON_MODE=1 run ls
check "ls --json lists both, port defaults to 22" \
  '[[ $(jq -c "[.data.machines[] | [.name,.port]]" "$TMP/out") == "[[\"web\",22],[\"test\",22]]" ]]'

# --- rm -------------------------------------------------------------------------
run rm test
check "rm succeeds" '[[ $(rc) == 0 ]]'
check "after rm, ssh -G can no longer resolve test (falls back to the bare name)" '[[ $(resolves test) == test ]]'
check "rm keeps the other machine" '[[ $(resolves web) == example.com ]]'
check "CLAUDE.md line now names only web" '! grep -qF "\`ssh test\`" "$MD" && grep -qF "\`ssh web\`" "$MD"'
run rm web
check "removing the last machine drops the config and the line, keeps the owner text" \
  '[[ ! -e "$CONF" ]] && ! grep -q "5dive-machines" "$MD" && grep -qx "keep me" "$MD"'
check "the box keypair survives rm (other machines may still trust it)" '[[ -f "$FIVE_MACHINE_DIR/id_ed25519" ]]'

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
