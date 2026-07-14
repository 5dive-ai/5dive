#!/usr/bin/env bash
# DIVE-1222 — Grok provisioning freeze guard unit test.
# The guard is inlined in cmd_create right after is_known_type, so every
# provisioning path (agent create, hire, pack import, clone) that funnels
# through cmd_create is blocked. We test (1) static wiring in the source and
# (2) functional behaviour of the refuse/override condition against the built
# `5dive` binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="src/cmd_agent_create.sh"
BIN="./5dive"
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
has()  { grep -qF -- "$2" "$SRC" && ok "$1" || bad "$1 (missing: $2)"; }

echo "== static wiring (DIVE-1222 grok freeze) =="
has "guard present"            "grok provisioning is frozen (DIVE-1221)"
has "refuse condition"         'if [[ "$type" == "grok" && "${FIVE_GROK_UNFREEZE_VERIFIED:-}" != "1" ]]; then'
has "points to DIVE-1221"      "See DIVE-1221."
has "override warns"           "bypassing the DIVE-1221 Grok exfiltration freeze"
has "guard sits after is_known_type" "DIVE-1221/1222: Grok provisioning is FROZEN"

echo "== functional (built binary) =="
# cmd_create is root-gated; the freeze fires right after is_known_type, before
# any user/FS side effect (verified: no agent-grokbot user is created), so a
# sudo dry-hit is safe and hermetic.
SUDO=""
[[ $EUID -eq 0 ]] || { sudo -n true 2>/dev/null && SUDO="sudo -n"; }
if [[ -x "$BIN" && ( $EUID -eq 0 || -n "$SUDO" ) ]]; then
  out="$($SUDO "$BIN" agent create grokbot --type=grok 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qF "grok provisioning is frozen (DIVE-1221)" <<<"$out"; then
    ok "grok create refused with DIVE-1221 error"
  else
    bad "grok create should refuse (rc=$rc, out: $out)"
  fi
  id agent-grokbot &>/dev/null && bad "freeze leaked a user (agent-grokbot created)" \
    || ok "no user created by refused grok create"
else
  echo "  skip functional (need built ./5dive + root/sudo -n)"
fi

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
