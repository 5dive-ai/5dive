#!/usr/bin/env bash
# DIVE-5406: dashboard chat is OPT-IN on new agents.
#
# Before: cmd_agent_create.sh (DIVE-856) folded `dashboard` into every claude
# create on a box with /etc/5dive/connectord.env — an unset --channels became
# "dashboard", an explicit list got ",dashboard" appended — so every new agent
# booted dashboard@5dive-plugins whether its owner used the web dashboard or not.
#
# After: a new agent runs exactly the channels --channels names.
#
# HOW THIS GRADES: the harness holds no copy of either code path. It EXTRACTS
#   C  the create-time channel resolution — everything between the
#      valid_channel refusal and the DIVE-1002 isolation block in
#      src/cmd_agent_create.sh (where the fold lived), and
#   P  the enabledPlugins builder in src/lib/agent_setup.sh,
# and executes that shipped text against real inputs, with the connectord env
# path pointed at a readable temp file so the old fold's gate would be OPEN on
# any host. Put the fold back and the C arms go red, because the restored text
# is what runs. DIVE5406_CREATE_SRC overrides the create source (mutation runs).
#
# No root, network, credentials, users, or runtime state are touched.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh

CREATE_SRC="${DIVE5406_CREATE_SRC:-src/cmd_agent_create.sh}"
SETUP_SRC=src/lib/agent_setup.sh

: >"$TMP/connectord.env"
chmod 644 "$TMP/connectord.env"

# --- C: create-time channel resolution --------------------------------------
c_start=$(grep -nF 'valid_channel "$channels" || fail "$E_VALIDATION" "invalid channels' "$CREATE_SRC" | head -1 | cut -d: -f1) || c_start=""
c_end=$(grep -nF '# DIVE-1002: least-privilege by default.' "$CREATE_SRC" | head -1 | cut -d: -f1) || c_end=""
[[ -n "$c_start" && -n "$c_end" ]] && (( c_end > c_start )) || {
  echo "FAIL: create-path anchors not found in $CREATE_SRC (start=$c_start end=$c_end) — re-anchor, do not delete" >&2
  exit 1
}
BLOCK_C=$(sed -n "$((c_start + 1)),$((c_end - 1))p" "$CREATE_SRC" \
  | sed "s#/etc/5dive/connectord.env#$TMP/connectord.env#g")

resolve() { # resolve <type> <channels> -> the channels create carries forward
  # shellcheck disable=SC2034  # type/channels_explicit are read by the eval'd block
  local type="$1" channels="$2" channels_explicit=1
  eval "$BLOCK_C"
  printf '%s' "$channels"
}
resolve_unset() { # --channels not passed at all (parser default "none")
  # shellcheck disable=SC2034
  local type="$1" channels="none" channels_explicit=0
  eval "$BLOCK_C"
  printf '%s' "$channels"
}

# --- P: settings.json enabledPlugins builder ---------------------------------
p_start=$(grep -nF '# channels is a comma-separable list (DIVE-856): build enabledPlugins from' "$SETUP_SRC" | head -1 | cut -d: -f1) || p_start=""
[[ -n "$p_start" ]] || { echo "FAIL: enabledPlugins anchor not found in $SETUP_SRC" >&2; exit 1; }
BLOCK_P=$(sed -n "${p_start},\$p" "$SETUP_SRC" | sed -n '1,/^    settings=\$(jq --argjson ep "\$enabled_plugins"/p')
BLOCK_P+=$'\n  fi'
grep -q 'dashboard@5dive-plugins' <<<"$BLOCK_P" \
  || { echo 'FAIL: extracted enabledPlugins block has no dashboard arm — bad anchor' >&2; exit 1; }

dashboard_enabled() { # dashboard_enabled <channels> -> true|false
  local channels="$1" settings='{}'
  eval "$BLOCK_P"
  jq -r '.enabledPlugins["dashboard@5dive-plugins"] // false' <<<"$settings"
}

pass=0 fail=0
check() { # check <want> <got> <label>
  if [[ "$1" == "$2" ]]; then pass=$((pass + 1)); printf 'ok   %s\n' "$3"
  else fail=$((fail + 1)); printf 'FAIL %s (want %s, got %s)\n' "$3" "$1" "$2" >&2; fi
}

check none               "$(resolve_unset claude)"                 'C1 claude, no --channels           -> none (no dashboard)'
check telegram           "$(resolve claude telegram)"              'C2 claude --channels=telegram      -> telegram only'
check none               "$(resolve claude none)"                  'C3 claude --channels=none          -> none'
check telegram,dashboard "$(resolve claude telegram,dashboard)"    'C4 claude --channels=telegram,dashboard -> unchanged'
check dashboard          "$(resolve claude dashboard)"             'C5 claude --channels=dashboard     -> unchanged'
check discord,buzz       "$(resolve claude discord,buzz)"          'C6 claude --channels=discord,buzz  -> no dashboard appended'

check false "$(dashboard_enabled none)"                 'P1 channels=none               -> no dashboard@5dive-plugins'
check false "$(dashboard_enabled telegram)"             'P2 channels=telegram           -> no dashboard@5dive-plugins'
check true  "$(dashboard_enabled telegram,dashboard)"   'P3 channels=telegram,dashboard -> dashboard@5dive-plugins enabled'
check true  "$(dashboard_enabled dashboard)"            'P4 channels=dashboard          -> dashboard@5dive-plugins enabled'

echo "dive5406_dashboard_opt_in: $pass passed, $fail failed"
(( fail == 0 ))
