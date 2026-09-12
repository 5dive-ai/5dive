#!/usr/bin/env bash
# DIVE-4350 — install.sh COMES FROM main, ITS DOWNLOADS COME FROM THE PIN.
#
# THE CLASS THIS GRADES (DIVE-4349, 2026-09-12). install.sh is fetched live from
# `main` — install.5dive.com serves it, and every box re-fetches it on each
# self-update — but every `$REPO/<path>` inside it resolves against the tree of
# the tag the fleet is PINNED to. Those two refs are not the same ref, and with
# the pin promoted deliberately and rarely (DIVE-4140) main is normally AHEAD.
#
# So a maker adding a fail-closed `curl -fsSL "$REPO/<new file>"` to install.sh
# ships a 404 to the fleet: #890 added hooks/stop-browser-teardown.sh (first in
# v0.34.0) while the pin was v0.32.3, and under `set -e` that 404 aborted the
# WHOLE install. Every fresh customer box and every pinned box's 04:00Z
# self-update failed at "Installing software" from 18:24Z until the hotfix.
# Nothing in CI could see it: the file exists on main, so every test passed.
#
# WHAT THIS ASSERTS: for each fail-closed `$REPO/<path>` in install.sh,
# `<pin>:<path>` is an object in this repo. That is the exact condition the
# fleet evaluates at 04:00Z, evaluated at PR time instead.
#
# WHAT IT DOES NOT ASSERT, named rather than left to be discovered:
#   * downloads whose path is a runtime variable this script cannot resolve —
#     they are LISTED in the report by line, not silently dropped;
#   * the six branch-tarball merge-deploy sites of OTHER repos (DIVE-2288) —
#     a different rail, and no check in this repo can see them;
#   * whether a file that EXISTS at the pin is the right version of itself.
#
# THE FIX when this fails is one of two, and never "retry":
#   1. the file is genuinely newer than the pin -> move the download into
#      `fetch_optional_at_pin` (install.sh), which skips on 404 only; or
#   2. the pin has caught up -> promote it, and update .github/fleet-pin.
#
# Hermetic apart from ONE optional network call (the live pin route). Grades a
# working tree; `--install-sh=` and `--pin=` make it drivable from a harness.
set -uo pipefail

INSTALL_SH="install.sh"
PIN=""
PIN_SOURCE=""
ROUTE="${FLEET_PIN_ROUTE:-https://api.5dive.com/cli-version}"
RECORDED=".github/fleet-pin"
NO_NETWORK="${INSTALL_PIN_COMPAT_NO_NETWORK:-0}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

for arg in "$@"; do
  case "$arg" in
    --install-sh=*) INSTALL_SH="${arg#*=}" ;;
    --pin=*)        PIN="${arg#*=}"; PIN_SOURCE="--pin= override" ;;
    --recorded=*)   RECORDED="${arg#*=}" ;;
    --no-network)   NO_NETWORK=1 ;;
    *) printf 'install-pin-compat: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

[[ -r "$INSTALL_SH" ]] || { printf 'install-pin-compat: cannot read %s\n' "$INSTALL_SH" >&2; exit 2; }

# ---------------------------------------------------------------- resolve the pin
# Ladder: explicit override > live route > recorded file. A recorded value that
# lags the real pin makes this guard stricter, never looser (see .github/fleet-pin).
if [[ -z "$PIN" && "$NO_NETWORK" != 1 ]]; then
  _route_answer="$(curl -fsSL --max-time 10 "$ROUTE" 2>/dev/null | tr -d '[:space:]')" || _route_answer=""
  if [[ "$_route_answer" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PIN="$_route_answer"; PIN_SOURCE="live fleet route $ROUTE"
  fi
fi
if [[ -z "$PIN" && -r "$RECORDED" ]]; then
  _rec="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$RECORDED" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)" || _rec=""
  if [[ -n "$_rec" ]]; then
    PIN="$_rec"; PIN_SOURCE="recorded pin $RECORDED (the live route did not answer)"
  fi
fi
if [[ -z "$PIN" ]]; then
  # NOT a silent pass. Both rungs failing means the guard graded nothing, and a
  # green tick for "I could not look" is the fails-open half of every guard this
  # repo has had to fix twice (DIVE-4237).
  printf '::error::install-pin-compat resolved NO fleet pin — the live route (%s) did not answer and %s carries no vN.N.N line. It therefore graded nothing, and is refusing rather than reporting a pass it did not earn. Set the pin in %s.\n' \
    "$ROUTE" "$RECORDED" "$RECORDED" >&2
  exit 1
fi

# The pin must be an OBJECT here, or the assertion below is vacuous.
PIN_COMMIT="$(git rev-parse -q --verify "refs/tags/${PIN}^{commit}" 2>/dev/null)" || PIN_COMMIT=""
if [[ -z "$PIN_COMMIT" ]]; then
  git fetch --tags --quiet origin "refs/tags/${PIN}:refs/tags/${PIN}" >/dev/null 2>&1 || true
  PIN_COMMIT="$(git rev-parse -q --verify "refs/tags/${PIN}^{commit}" 2>/dev/null)" || PIN_COMMIT=""
fi
if [[ -z "$PIN_COMMIT" ]]; then
  printf '::error::install-pin-compat resolved the fleet pin as %s (%s) but that tag is not an object in this clone and could not be fetched, so every path assertion below would be vacuously true. Refusing to report a pass it did not earn.\n' \
    "$PIN" "$PIN_SOURCE" >&2
  exit 1
fi

# ------------------------------------------------------- extract download sites
# Join backslash continuations first: the pii-guard block is one logical `if`
# spread over five physical lines, and classifying those lines separately reads
# four bare `curl`s that are not bare.
# The helper's OWN body is excluded: `curl "$REPO/$_path"` inside
# fetch_optional_at_pin is the tolerant mechanism, not a download site, and
# grading it would report the mechanism as an ungradeable blind spot forever.
LOGICAL="$(sed -e '/>>> DIVE-4350 optional-at-pin download contract/,/<<< DIVE-4350 optional-at-pin download contract/d' "$INSTALL_SH" \
           | sed -e :a -e '/\\$/N; s/\\\n//; ta')"

# CLASSIFIER. After DIVE-4350 the tolerant path is exactly ONE named function, so
# "is this fail-closed?" is a structural question and not a judgement call:
#   tolerant  - routed through fetch_optional_at_pin;
#             - the condition of an `if`/`elif` (the caller handles the failure);
#             - inside a command substitution (the caller inspects the result);
#             - has a `||` fallback that does NOT end in `die`.
#   fail-closed - everything else. Under `set -e` it takes the box down.
# Deliberately biased toward fail-closed: a false positive here is one PR comment,
# a false negative is the fleet.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$LOGICAL" | awk '
  function classify(l) {
    if (l ~ /fetch_optional_at_pin/) return "tolerant"
    if (l ~ /^[[:space:]]*(el)?if[[:space:]]/) return "tolerant"
    if (l ~ /\$\(/ && l ~ /curl/) return "tolerant"
    if (l ~ /\|\|/ && l !~ /die[[:space:]]/) return "tolerant"
    return "closed"
  }
  {
    line = $0
    # remember the most recent `for <var> in <words>; do` list
    if (match(line, /^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/)) {
      hdr = line
      sub(/^[[:space:]]*for[[:space:]]+/, "", hdr)
      var = hdr; sub(/[[:space:]].*$/, "", var)
      items = hdr; sub(/^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+/, "", items)
      sub(/;[[:space:]]*do.*$/, "", items)
      forvar[var] = items
    }
    if (line !~ /\$\{?REPO\}?\//) next
    if (line !~ /curl/) next
    # `echo "Fallback: curl -fsSL $REPO/install.sh | sudo bash"` at the foot of
    # install.sh prints an instruction; it downloads nothing.
    if (line ~ /^[[:space:]]*(echo|printf)[[:space:]]/) next
    cls = classify(line)
    rest = line
    while (match(rest, /\$\{?REPO\}?\/[^"'"'"' ]+/)) {
      site = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      path = site
      sub(/^\$\{?REPO\}?\//, "", path)
      if (path ~ /\$/) {
        # one resolvable shape: a for-loop variable whose list we just recorded
        resolved = 0
        for (v in forvar) {
          pat = "\\$\\{?" v "\\}?$"
          if (path ~ pat) {
            prefix = path; sub(pat, "", prefix)
            n = split(forvar[v], w, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (w[i] != "") print cls "\t" prefix w[i] "\tfor-list $" v
            resolved = 1
          }
        }
        if (!resolved) print "unresolved\t" path "\truntime variable"
      } else {
        print cls "\t" path "\tliteral"
      }
    }
  }
' > "$TMP/sites"

# URL-decode the one encoding install.sh uses (systemd/5dive-agent%40.service).
sed -i 's/%40/@/g' "$TMP/sites"

CLOSED="$(awk -F'\t' '$1=="closed"{print $2"\t"$3}' "$TMP/sites" | sort -u)"
TOLERANT="$(awk -F'\t' '$1=="tolerant"{print $2}' "$TMP/sites" | sort -u)"
UNRESOLVED="$(awk -F'\t' '$1=="unresolved"{print $2}' "$TMP/sites" | sort -u)"

if [[ -z "$CLOSED" ]]; then
  printf '::error::install-pin-compat found ZERO fail-closed $REPO downloads in %s. install.sh has always had several, so this is the extractor breaking, not the file getting safer — and a guard that greens when it stops being able to read its input is worse than no guard (DIVE-4237).\n' "$INSTALL_SH" >&2
  exit 1
fi

# ------------------------------------------------------------------- the assertion
MISSING=0; CHECKED=0
{
  printf '## install.sh vs the fleet pin\n\n'
  printf 'Fleet pin: **%s** (`%s`) — resolved from %s.\n\n' "$PIN" "${PIN_COMMIT:0:12}" "$PIN_SOURCE"
  printf '`install.sh` is served from **main**; every `$REPO/…` inside it is fetched from **%s**.\n\n' "$PIN"
} >> "$SUMMARY"

while IFS=$'\t' read -r path how; do
  [[ -n "$path" ]] || continue
  CHECKED=$((CHECKED+1))
  if git cat-file -e "${PIN_COMMIT}:${path}" 2>/dev/null; then
    printf 'ok   - %s exists at %s\n' "$path" "$PIN"
  else
    MISSING=$((MISSING+1))
    printf 'FAIL - %s is fetched FAIL-CLOSED but does not exist at %s (%s)\n' "$path" "$PIN" "$how"
    printf '::error file=%s::install.sh downloads `%s` fail-closed, but the fleet pin %s does not carry that path. Every fresh install and every box'"'"'s 04:00Z self-update would 404 there and abort the whole install under `set -e` (DIVE-4349). Fix: move it into `fetch_optional_at_pin` (skips on 404 only), or promote the fleet pin past the tag that ships it and update .github/fleet-pin.\n' \
      "$INSTALL_SH" "$path" "$PIN" >&2
    printf -- '- **MISSING at %s**: `%s` (%s)\n' "$PIN" "$path" "$how" >> "$SUMMARY"
  fi
done <<< "$CLOSED"

{
  printf '\n%d fail-closed path(s) checked, %d missing at the pin.\n\n' "$CHECKED" "$MISSING"
  if [[ -n "$TOLERANT" ]]; then
    printf '### Tolerated at this pin (404 -> named skip, anything else still fatal)\n\n'
    while IFS= read -r t; do [[ -n "$t" ]] && printf -- '- `%s`\n' "$t"; done <<< "$TOLERANT"
    printf '\n'
  fi
  printf '### What this check CANNOT see\n\n'
  if [[ -n "$UNRESOLVED" ]]; then
    printf 'Downloads whose path is a runtime variable — listed, not silently dropped:\n\n'
    while IFS= read -r u; do [[ -n "$u" ]] && printf -- '- `$REPO/%s`\n' "$u"; done <<< "$UNRESOLVED"
    printf '\n'
  fi
  printf 'Also invisible here: the six branch-tarball merge-deploy sites of **other** repos (DIVE-2288) — a different rail, and no path filter in this repo can reach them.\n'
} >> "$SUMMARY"

if [[ -n "$UNRESOLVED" ]]; then
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    printf 'note - $REPO/%s is a runtime variable; NOT graded against the pin\n' "$u"
  done <<< "$UNRESOLVED"
fi

printf 'install-pin-compat: pin=%s (%s) source=%s checked=%d missing=%d tolerated=%d unresolved=%d\n' \
  "$PIN" "${PIN_COMMIT:0:12}" "$PIN_SOURCE" "$CHECKED" "$MISSING" \
  "$(printf '%s' "$TOLERANT" | grep -c . || true)" "$(printf '%s' "$UNRESOLVED" | grep -c . || true)"

[[ $MISSING -eq 0 ]] || exit 1
