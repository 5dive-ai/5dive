#!/usr/bin/env bash
# DIVE-1816: managed-settings channel-allowlist reconcile.
#
# install.sh must (1) ship a template that allowlists BOTH 5dive fork channels
# (telegram + dashboard), and (2) reconcile an EXISTING file in place so boxes
# provisioned before dashboard shipped stop dropping dashboard-chat pings. This
# harness locks both: the template shape (grep) and the reconcile jq semantics
# (behavioural), without needing root or a real /etc/claude-code.
# Run: bash tests/managed_settings_reconcile_unit.sh
set -uo pipefail

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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d /tmp/msj-reconcile.XXXXXX)"

# DIVE-3537: the set of 5dive fork channels comes from the ONE constant in
# src/header.sh, not from a list re-typed here. install.sh is curl-piped and
# cannot source that file, so its two copies (template + reconcile filter) are
# graded AGAINST the constant — the drift between two hand-kept copies of this
# list is the defect this harness now has to be able to see.
CONST="$(grep -m1 '^readonly FIVEDIVE_CHANNEL_PLUGINS_JSON=' src/header.sh)"
[[ -n "$CONST" ]] \
  && ok_t "FIVEDIVE_CHANNEL_PLUGINS_JSON present in src/header.sh" \
  || bad_t "channel-plugin constant missing" "no readonly FIVEDIVE_CHANNEL_PLUGINS_JSON= in src/header.sh"
eval "$CONST"

# ---- 1. template ships EVERY 5dive fork channel -----------------------------
TPL=$(sed -n '/cat > "\$msj" <<.\?MANAGED/,/^MANAGED/p' install.sh)
while read -r p m; do
  grep -q "\"plugin\": \"$p\", \"marketplace\": \"$m\"" <<<"$TPL" \
    && ok_t "template allowlists $p@$m" \
    || bad_t "template $p@$m" "a box installed FRESH would have that channel deaf. Template: $TPL"
done < <(jq -r '.[] | "\(.plugin) \(.marketplace)"' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON")
grep -q '"channelsEnabled": true' <<<"$TPL" \
  && ok_t "template sets channelsEnabled:true" \
  || bad_t "template channelsEnabled" ""

# install.sh must RECONCILE existing files, not just skip them.
grep -q 'reconcile' install.sh \
  && ok_t "install.sh reconciles an existing managed-settings.json" \
  || bad_t "install.sh reconcile branch" "existing-file branch must merge, not blind-skip"

# ---- 2. reconcile jq semantics — EXTRACTED from install.sh, not mirrored ----
# DIVE-3537: this used to be a copy "kept byte-identical to the filter in
# install.sh's else-branch", and by the time buzz shipped it was neither
# byte-identical nor testing install.sh at all — it graded its own stale copy and
# stayed green. Read the real filter out of install.sh instead, and fail loudly
# if the extraction comes back empty (an empty filter would make every arm below
# pass against nothing).
reconcile_filter=$(awk '/^ *if jq .$/{grab=1; next} grab && /^ *. "\$msj" > "\$msj_tmp"/{exit} grab' install.sh)
if [[ -n "$reconcile_filter" ]] && jq -n "$reconcile_filter" >/dev/null 2>&1 <<<'{}'; then
  ok_t "reconcile filter extracted from install.sh and parses as jq"
else
  bad_t "reconcile filter extracted from install.sh" \
        "extraction empty or unparseable — every semantic arm below would grade nothing. Got: $reconcile_filter"
fi
rec() { jq "$reconcile_filter" "$1"; }

# stale: telegram-only + an operator entry + channelsEnabled:false (claude-leaf shape)
cat > "$TMP/stale.json" <<'J'
{"channelsEnabled":false,"allowedChannelPlugins":[{"plugin":"telegram","marketplace":"5dive-plugins"},{"plugin":"telegram","marketplace":"claude-plugins-official"},{"plugin":"myown","marketplace":"acme"}]}
J
OUT=$(rec "$TMP/stale.json")
jq -e '.channelsEnabled == true' <<<"$OUT" >/dev/null \
  && ok_t "reconcile flips channelsEnabled -> true" || bad_t "reconcile channelsEnabled" "$OUT"
while read -r p m; do
  jq -e --arg p "$p" --arg m "$m" '.allowedChannelPlugins | any(.plugin==$p and .marketplace==$m)' <<<"$OUT" >/dev/null \
    && ok_t "reconcile adds $p@$m to a stale list" \
    || bad_t "reconcile adds $p@$m" "an existing box rerunning install.sh keeps that channel deaf. Got: $OUT"
done < <(jq -r '.[] | "\(.plugin) \(.marketplace)"' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON")
jq -e '.allowedChannelPlugins | any(.plugin=="myown" and .marketplace=="acme")' <<<"$OUT" >/dev/null \
  && ok_t "reconcile PRESERVES an operator's own channel entry" || bad_t "reconcile preserves operator" "$OUT"
jq -e '.allowedChannelPlugins | any(.plugin=="telegram" and .marketplace=="claude-plugins-official")' <<<"$OUT" >/dev/null \
  && ok_t "reconcile PRESERVES the upstream/official entries" || bad_t "reconcile preserves upstream" "$OUT"

# idempotent: a second pass adds nothing
N1=$(jq '.allowedChannelPlugins | length' <<<"$OUT")
N2=$(rec <(echo "$OUT") 2>/dev/null | jq '.allowedChannelPlugins | length')
[[ "$N1" == "$N2" ]] \
  && ok_t "reconcile is idempotent (no duplicate entries on re-run)" \
  || bad_t "reconcile idempotent" "len $N1 -> $N2"

# already-current file: filter produces an equal object (change-detector skips write).
# Built FROM the constant — hand-writing this fixture is how it silently stopped
# being "already current" the moment a channel was added (DIVE-3537).
jq -c --argjson need "$FIVEDIVE_CHANNEL_PLUGINS_JSON" \
   -n '{channelsEnabled:true, allowedChannelPlugins:$need}' > "$TMP/cur.json"
jq -e --slurpfile a <(rec "$TMP/cur.json") '. == $a[0]' "$TMP/cur.json" >/dev/null \
  && ok_t "already-current file is unchanged by the filter (no needless rewrite)" \
  || bad_t "current-file no-op" ""

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
