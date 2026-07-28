#!/usr/bin/env bash
# DIVE-2075 — every TYPE_INSTALL recipe must gate on the EXACT artifact it is
# about to hand to the systemd unit, never on "is something by this name on PATH".
#
# Reported by A-MO7SEN (github #196): `[claude]="command -v claude >/dev/null || ..."`
# no-ops on a box carrying a stray npm-global claude, so ~/.local/bin/claude is
# never created and cmd_install fails "install reported success but $bin still
# missing" — permanently, since the gate can never flip. Same primitive as
# DIVE-2061 (`command -v 5dive` grading the installed CLI, not the bundle under test).
#
# WHAT THIS MEASURES, and why that dimension:
# The input under test is the ENVIRONMENT (a stray binary on PATH), not the recipe
# text and not the installer's behaviour. So we vary exactly that, and we observe
# the GATE'S OWN DECISION — did the install action run? — rather than whether a
# binary appeared. Observing the binary would be defeated by our own stubs
# (community/wiki/mutation-coverage-is-per-dimension.md, instance 3: a faithful
# mutation aimed at the wrong axis reads green and means nothing).
#
# Two cases per type, because "always installs" would pass case A alone:
#   A. stray-on-PATH, gate artifact ABSENT  -> the install action MUST run
#   B. gate artifact PRESENT, no stray      -> the install action MUST NOT run
# Textual assertion is deliberately not used: `command -v agy` legitimately
# survives inside antigravity's post-install symlink fallback.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

MARKER="INSTALL_ACTION_RAN"
fails=0
checked=0

# Extra paths (beyond TYPE_BIN) a recipe legitimately gates on, so case B can
# make the gate true. openclaw gates on its npm-prefix binary before symlinking
# into TYPE_BIN — an exact path, so not this ticket's defect, but it has to be
# present for case B or the recipe reinstalls by design.
gate_extra_for() {
  case "$1" in
    openclaw) printf 'NPMPREFIX/bin/openclaw\n' ;;
    *) : ;;
  esac
}

# Build a sandbox and run <type>'s recipe in it with the network/npm layer
# stubbed. Echoes the recipe's stdout+stderr; the caller greps for $MARKER.
# $2 = present|absent (whether the gate artifact exists), $3 = stray|nostray.
run_gate() {
  local type="$1" artifact="$2" stray="$3"
  local fake; fake=$(mktemp -d) || return 99
  local home="$fake/home/claude"
  local lbin="$home/.local/bin" prefix="$fake/npmprefix"
  mkdir -p "$lbin" "$prefix/bin" "$fake/stray/bin" "$fake/stubs" \
           "$home/.nvm" "$home/.nvm/versions/node/v24.0.0/bin"

  # --- action layer: curl and npm are the only things that can INSTALL an agent
  # CLI here, so they are the marker. `nvm install 24` is a runtime prerequisite
  # every node recipe does unconditionally by design, so it stays silent.
  # The marker goes to STDERR on purpose: every recipe pipes curl's stdout into
  # `bash`, so a marker on stdout would be swallowed by the pipe instead of
  # reaching the assertion. `npm prefix -g` keeps answering on stdout.
  cat >"$fake/stubs/curl" <<EOF
#!/usr/bin/env bash
echo "$MARKER curl \$*" >&2
EOF
  cat >"$fake/stubs/npm" <<EOF
#!/usr/bin/env bash
case "\$1" in
  prefix) echo "$prefix" ;;
  *) echo "$MARKER npm \$*" >&2 ;;
esac
EOF
  chmod +x "$fake/stubs/curl" "$fake/stubs/npm"
  cat >"$home/.nvm/nvm.sh" <<EOF
nvm() {
  case "\$1" in
    which) echo "$home/.nvm/versions/node/v24.0.0/bin/node" ;;
    *) return 0 ;;
  esac
}
EOF
  : >"$home/.nvm/versions/node/v24.0.0/bin/node"; chmod +x "$home/.nvm/versions/node/v24.0.0/bin/node"

  local base; base=$(basename "${TYPE_BIN[$type]}")
  local path="$fake/stubs:$lbin:/usr/bin:/bin"
  if [[ "$stray" == stray ]]; then
    # The mutation: a working binary of the right NAME, at the wrong PATH.
    printf '#!/usr/bin/env bash\necho stray\n' >"$fake/stray/bin/$base"
    chmod +x "$fake/stray/bin/$base"
    path="$fake/stray/bin:$path"
  fi
  if [[ "$artifact" == present ]]; then
    printf '#!/usr/bin/env bash\necho real\n' >"$lbin/$base"; chmod +x "$lbin/$base"
    local extra
    while IFS= read -r extra; do
      [[ -n "$extra" ]] || continue
      extra="${extra/NPMPREFIX/$prefix}"
      mkdir -p "$(dirname "$extra")"; : >"$extra"; chmod +x "$extra"
    done < <(gate_extra_for "$type")
  fi

  # Recipe verbatim, re-rooted at the sandbox home. Recipes run under
  # `sudo -u claude -i bash -lc` on a real box: bash, no `set -e`.
  local recipe="${TYPE_INSTALL[$type]//\/home\/claude/$home}"
  ( cd "$fake" && HOME="$home" PATH="$path" FORCE_INSTALL= \
      /usr/bin/env bash -c "$recipe" 2>&1 )
  rm -rf "$fake"
}

for type in $(printf '%s\n' "${!TYPE_INSTALL[@]}" | sort); do
  [[ -n "${TYPE_INSTALL[$type]}" ]] || continue
  [[ -n "${TYPE_BIN[$type]:-}" ]] || {
    echo "FAIL: $type has an install recipe but no TYPE_BIN to gate on" >&2
    fails=$((fails+1)); continue
  }
  checked=$((checked+1))
  base=$(basename "${TYPE_BIN[$type]}")

  out_a=$(run_gate "$type" absent stray)
  if [[ "$out_a" != *"$MARKER"* ]]; then
    echo "FAIL: $type — a stray '$base' on PATH suppressed the install while" >&2
    echo "      ${TYPE_BIN[$type]} was ABSENT. The gate asks 'is something named" >&2
    echo "      $base on PATH', not 'is my TYPE_BIN present' (DIVE-2075). Recipe:" >&2
    echo "      ${TYPE_INSTALL[$type]:0:160}" >&2
    fails=$((fails+1))
  fi

  out_b=$(run_gate "$type" present nostray)
  if [[ "$out_b" == *"$MARKER"* ]]; then
    echo "FAIL: $type — recipe reinstalled with its gate artifact already present;" >&2
    echo "      not idempotent (or this harness cannot see the gate's decision)." >&2
    fails=$((fails+1))
  fi
done

(( checked >= 6 )) || {
  echo "FAIL: only $checked recipes measured — expected every type with an installer" >&2
  fails=$((fails+1))
}

if (( fails > 0 )); then
  echo "FAIL: $fails TYPE_INSTALL gate assertion(s) failed across $checked recipes" >&2
else
  echo "PASS: all $checked TYPE_INSTALL recipes gate on their exact artifact — install runs when TYPE_BIN is missing despite a stray on PATH, and no-ops when present"
fi
# Verdict on its own last line, in a shape tests/meta/harness-verdict-probe.sh can
# identify and mutate: `if (( fails ))` reads fine to a person but is UNPROBEABLE
# to the probe, which reds the check (council_amend_e2e.sh is allowlisted for
# exactly this shape). Empirically confirmed with --only= on this file.
[[ "$fails" -eq 0 ]]
