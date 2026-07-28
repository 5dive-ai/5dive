#!/usr/bin/env bash
# DIVE-2076: the TYPE_* maps are read under `set -uo pipefail`, so an omitted key
# does not degrade — it hard-crashes with an unbound-variable error that names the
# ARRAY and not the type. Reported from outside by A-MO7SEN (github #196) while
# adding a new agent type: `agent types` died on a missing TYPE_CHANNELS entry.
#
# Two dimensions, because either alone is defeatable:
#   (1) STATIC  — every reader of an optional map keyed by a variable carries a
#                 `:-` default. Catches a new bare read added tomorrow.
#   (2) BEHAVIOURAL — register a synthetic type in TYPE_BIN ONLY and run the real
#                 reader expressions under `set -u`. This observes the READER'S
#                 OWN outcome (did it degrade, and to what value) rather than
#                 whether some binary appeared, which our stubs would have
#                 defeated. See community/wiki/mutation-coverage-is-per-dimension.md
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$ROOT/src/header.sh"

fails=0
# No spaces inside the arithmetic: tests/meta/harness-verdict-probe.sh extracts
# the assignment with [^[:space:];]*, so `fails=$((fails + 1))` truncates to
# `fails=$((fails` and the harness is reported UNPROBEABLE (which reds the
# harness-verdict CI job). Same trap caught DIVE-2075's harness.
bad() { echo "FAIL: $*" >&2; fails=$((fails+1)); }
note() { echo "  .. $*"; }

# TYPE_BIN is REQUIRED (it IS the registry — is_known_type tests it), so bare
# reads of it are correct by construction and deliberately not listed here.
OPTIONAL_MAPS=(TYPE_CHANNELS TYPE_AUTH TYPE_INSTALL TYPE_API_FILE TYPE_API_VAR TYPE_PROBE TYPE_SKILLS_DIR)

# --- (1) static: no bare variable-keyed read of an optional map --------------
#
# Only variable-keyed reads matter. `${TYPE_API_FILE[pi]}` is a literal key the
# author can see is present in the declaration; `${TYPE_API_FILE[$type]}` is the
# one that depends on a caller-supplied type nobody validated against this map.
for map in "${OPTIONAL_MAPS[@]}"; do
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    bad "bare variable-keyed read of optional map $map (needs \${$map[\$x]:-<default>}): $hit"
  done < <(
    grep -rnoE "\\\$\{${map}\[\\\$[A-Za-z_][A-Za-z0-9_]*\][^:}]*\}" "$ROOT/src/" 2>/dev/null \
      | grep -vE '\[\$[A-Za-z_][A-Za-z0-9_]*\]\+x' || true
  )
done

# --- (2) behavioural: a type present in TYPE_BIN only must not crash a reader --
#
# Load just the map declarations, then add a synthetic type to TYPE_BIN and to
# nothing else — precisely the state a contributor lands in mid-registration.
eval "$(sed -n '/^declare -A TYPE_BIN=(/,/^)/p;/^declare -A TYPE_CHANNELS=(/,/^)/p;/^declare -A TYPE_API_FILE=(/,/^)/p;/^declare -A TYPE_API_VAR=(/,/^)/p' "$HEADER")"
[[ -n "${TYPE_BIN[claude]:-}" ]]      || bad "could not load TYPE_BIN from header.sh (test would be vacuous)"
[[ -n "${TYPE_CHANNELS[claude]:-}" ]] || bad "could not load TYPE_CHANNELS from header.sh (test would be vacuous)"

TYPE_BIN[newtype]="/home/claude/.local/bin/newtype"

# Each probe is the reader's real expression, lifted verbatim from the source
# line it guards, run under `set -u` with `newtype` absent from the optional map.
# A crash here is the reported bug; the expected outcome is the documented default.
probe() { # probe <label> <expected> <expr>
  local label="$1" expect="$2" expr="$3" got rc
  got="$(set -u; type="newtype"; eval "printf '%s' \"$expr\"" 2>&1)" && rc=0 || rc=$?
  if (( rc != 0 )); then
    bad "$label CRASHED under set -u with the key absent (rc=$rc): ${got//$'\n'/ }"
  elif [[ "$got" != "$expect" ]]; then
    bad "$label degraded to '$got', expected the documented default '$expect'"
  else
    note "$label -> '$got' (degraded as documented)"
  fi
}

# The expressions are LIFTED FROM THE SOURCE, not written here: a probe that
# hardcodes `${TYPE_CHANNELS[$type]:-0}` proves only that the default works, and
# passes just as happily against a tree whose readers are still bare. Extracting
# the real substitution binds this dimension to the shipped code, so it crashes
# on the pre-fix tree instead of reading vacuously green.
from_source() { # from_source <file> <map> -> the map's first variable-keyed read
  grep -hoE "\\\$\{$2\[\\\$[A-Za-z_][A-Za-z0-9_]*\](:-[^}]*)?\}" "$ROOT/src/$1" | head -1
}

CH_EXPR="$(from_source cmd_agent_config.sh TYPE_CHANNELS)"
AV_EXPR="$(from_source cmd_auth.sh TYPE_API_VAR)"
AF_EXPR="$(from_source cmd_auth.sh TYPE_API_FILE)"
[[ -n "$CH_EXPR" && -n "$AV_EXPR" && -n "$AF_EXPR" ]] \
  || bad "could not lift reader expressions from src/ (test would be vacuous)"
note "lifted from source: $CH_EXPR | $AV_EXPR | $AF_EXPR"

probe "TYPE_CHANNELS[\$type] (agent types / config / create)" "0" "$CH_EXPR"
probe "TYPE_API_VAR[\$type]  (auth set-key)"                  ""  "$AV_EXPR"
probe "TYPE_API_FILE[\$type] (auth set-key)"                  ""  "$AF_EXPR"

# Non-vacuity: the same probe against a BARE read must still crash. If this
# passes, `set -u` is not actually in force and dimension 2 proves nothing.
bare_got="$(set -u; type="newtype"; eval 'printf "%s" "${TYPE_CHANNELS[$type]}"' 2>&1)" && bare_rc=0 || bare_rc=$?
if (( bare_rc == 0 )); then
  bad "control probe: a BARE read of a missing key did NOT crash — set -u is not in force, so the checks above are vacuous"
else
  note "control: bare read of a missing key still crashes (rc=$bare_rc) — set -u confirmed in force"
fi

# --- (3) the contract is documented where a contributor will read it ---------
#
# The ticket's second half: a contributor adding a type had no way to learn this
# except by crashing. The comments are the deliverable, so they are asserted.
grep -q 'absent-vs-zero contract' "$HEADER" \
  || bad "header.sh does not document the absent-vs-zero contract for the TYPE_* maps"
grep -q 'OPTIONAL map, default 0' "$HEADER" \
  || bad "TYPE_CHANNELS does not state its own default for an omitted key"

# --- verdict ----------------------------------------------------------------
# Last line must be a plain status test so tests/meta/harness-verdict-probe.sh
# can see the verdict shape (an `if (( fails ))` block reads as UNPROBEABLE).
if (( fails )); then
  echo "FAILED: $fails TYPE_* registration-contract violation(s)" >&2
else
  echo "PASS: optional TYPE_* maps all read with defaults, degrade as documented under set -u, and the contract is written down"
fi
[[ "$fails" -eq 0 ]]
