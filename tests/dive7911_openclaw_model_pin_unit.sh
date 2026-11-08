#!/usr/bin/env bash
# DIVE-7911: an OpenClaw seat pinned to Haiku still called Sonnet.
#
# init-smoke pinned the seat with `openclaw models set anthropic/claude-haiku-5-5`
# (as the seat user, as a person would) and restarted it. On that restart
# 5dive-agent-start copied the ACCOUNT's model (anthropic/claude-sonnet-5-5,
# OPENCLAW_PROVIDER_MODEL) over the seat's, because the two differed. The first
# reply then went out as claude-sonnet-5-5 (init-smoke run 42426025339).
#
# The boot now copies the account's model only over a model the account put
# there (a stamp file records the last one it left), so a seat's own pin
# survives a restart, while an account default that changes (`agent auth login`)
# still reaches a seat that never chose its own.
#
# The block under test is the REAL text of bin/5dive-agent-start, run with a
# fake `openclaw` that applies `config patch --stdin` and `models set` to the
# seat's openclaw.json the way openclaw does (agents.defaults.model.primary is
# the key a turn's model comes from: `openclaw models status` "Default model").
# Pure: no root, no systemd, no network. Run: bash tests/dive7911_openclaw_model_pin_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d); trap 'rc=$?; rm -rf "${TMP:-/nonexistent-7911}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }

block=$(awk '/Inherit the profile.s model defaults/{on=1} /DIVE-7721: a seat with a channel runs/{exit} on{print}' bin/5dive-agent-start)
if [[ "$block" != *'SHARED_OPENCLAW_CFG='* || "$block" != *'AGENT_MODEL'* ]]; then
  bad "the model block is in bin/5dive-agent-start" "the block" "not found"
  echo "--- $PASS pass, $FAIL fail"; exit 1
fi
ok "the model block is in bin/5dive-agent-start"
block="${block//\/home\/claude\/.local\/bin\/openclaw/$TMP/openclaw}"
block="${block//\/home\/claude\/.openclaw\/openclaw.json/$TMP/account.json}"

cat >"$TMP/openclaw" <<'SH'
#!/bin/bash
cfg="$HOME/.openclaw/openclaw.json"
[[ "${OC_FAIL:-0}" == 1 ]] && { cat >/dev/null; exit 1; }
case "$1 $2" in
  "config patch") p=$(cat); jq --argjson p "$p" '. * $p' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg" ;;
  "models set")   jq --arg m "$3" '.agents.defaults.model.primary = $m' "$cfg" >"$cfg.new" && mv "$cfg.new" "$cfg" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP/openclaw"

SEAT="$TMP/seat"
SONNET=anthropic/claude-sonnet-5-5 HAIKU=anthropic/claude-haiku-5-5 LUNA=openai/gpt-6-luna
account() { printf '{"agents":{"defaults":{"model":{"primary":"%s"}}}}\n' "$1" >"$TMP/account.json"; }
fresh_seat() { # $1 = the seat's primary at create ("" = none)
  rm -rf "$SEAT"; mkdir -p "$SEAT/.openclaw"
  if [[ -n "$1" ]]; then
    printf '{"channels":{"telegram":{"allowFrom":["1"]}},"agents":{"defaults":{"model":{"primary":"%s"}}}}\n' "$1"
  else
    printf '{"channels":{"telegram":{"allowFrom":["1"]}}}\n'
  fi >"$SEAT/.openclaw/openclaw.json"
}
boot() { HOME="$SEAT" AGENT_MODEL="${AGENT_MODEL:-}" OC_FAIL="${OC_FAIL:-0}" bash -c "$block" 2>"$TMP/err"; }
seat_model() { jq -r '.agents.defaults.model.primary // ""' "$SEAT/.openclaw/openclaw.json"; }
pin_in_seat() { HOME="$SEAT" "$TMP/openclaw" models set "$1"; }

echo "== A: the init-smoke shape — pinned in the seat, then restarted =="
account "$SONNET"; fresh_seat "$SONNET"
boot
is 'first boot: the seat runs its account model' "$(seat_model)" "$SONNET"
pin_in_seat "$HAIKU"
boot
is 'the restart after `openclaw models set` keeps Haiku' "$(seat_model)" "$HAIKU"
boot
is 'and the restart after that one too' "$(seat_model)" "$HAIKU"
is 'the boot says it kept the seat model' "$(grep -c "keeping this seat's own model $HAIKU" "$TMP/err")" 1

echo "== B: a seat that never chose its own model follows its account =="
account "$SONNET"; fresh_seat "$SONNET"; boot
account "$LUNA"; boot
is 'an account default that changes reaches the seat (auth login)' "$(seat_model)" "$LUNA"
account "$SONNET"; boot
is 'and changes back' "$(seat_model)" "$SONNET"

echo "== C: DIVE-1900 — no model, or the built-in default, is still filled in =="
account "$SONNET"; fresh_seat ""; boot
is 'a seat with no model gets its account model' "$(seat_model)" "$SONNET"
account "$SONNET"; fresh_seat "openai/gpt-5.5"; boot
is 'a seat from before the stamp, on the built-in default, gets its account model' "$(seat_model)" "$SONNET"

echo "== D: the 5dive pin (config set model= -> AGENT_MODEL) =="
account "$SONNET"; fresh_seat "$SONNET"; boot
AGENT_MODEL="$HAIKU" boot
is 'AGENT_MODEL puts the seat on Haiku' "$(seat_model)" "$HAIKU"
AGENT_MODEL="$HAIKU" boot
is 'and keeps it there on the next restart' "$(seat_model)" "$HAIKU"
account "$SONNET"; fresh_seat "$SONNET"; boot; pin_in_seat "$LUNA"
AGENT_MODEL="$HAIKU" boot
is 'AGENT_MODEL wins over a model set in the seat' "$(seat_model)" "$HAIKU"

echo "== E: a failed copy leaves no false stamp =="
account "$SONNET"; fresh_seat ""
OC_FAIL=1 boot
is 'the failed copy warns' "$(grep -c 'warn: openclaw config patch (model defaults) failed' "$TMP/err")" 1
is 'and writes no stamp' "$([[ -e "$SEAT/.openclaw/.5dive-account-model" ]] && echo stamped || echo none)" none
boot
is 'the next boot fills the model in' "$(seat_model)" "$SONNET"

echo "--- $PASS pass, $FAIL fail"
(( FAIL == 0 ))
