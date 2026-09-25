#!/usr/bin/env bash
# DIVE-4973 — hermes' install recipe keeps the browser tools out of the blocking
# exec. Upstream's 2026-09-24 installer rework took a cold install from ~110-140s
# to 272-297s, 3s under the wizard's 300s kill. The recipe now:
#   - passes --skip-browser ONLY when the installer's --help lists it (upstream
#     briefly made the flag exit 1; a blind flag would fail every install),
#   - then fetches the browser tools DETACHED, so the exec returns without them.
# The recipe runs verbatim, re-rooted at a sandbox home, with curl stubbed to
# serve a fixture installer. Observed: the installer's argv, whether the
# background `hermes pm install agent-browser` ran, the recipe's exit code, how
# long the recipe held its stdout pipe, and the temp file it must not leave.
set -uo pipefail

# NOTE: sourcing src/header.sh below turns on `set -e`; every probe that may
# legitimately fail carries `|| true`.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/header.sh
source "$ROOT/src/header.sh"

fails=0
arms=0
check() { # check <label> <condition-rc>
  arms=$((arms+1))
  if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else echo "FAIL $1" >&2; fails=$((fails+1)); fi
}

# run_recipe <mode>: current | retired | broken
#   current — --help lists --skip-browser (upstream after 09-24 21:27Z)
#   retired — --help omits it and the flag exits 1 (09-24 13:20Z-21:27Z)
#   broken  — the install itself fails
# Sets: RC, MS, ARGV (installer argv), PM (background pm argv), TMPLEFT.
run_recipe() {
  local mode="$1"
  local fake; fake=$(mktemp -d)
  local home="$fake/home/claude"
  mkdir -p "$home" "$fake/stubs" "$fake/tmp"
  cat >"$fake/installer.sh" <<INST
#!/usr/bin/env bash
if [[ "\${1:-}" == --help ]]; then
  echo "Usage: install.sh [--non-interactive]"
  [[ "$mode" == current ]] && echo "                  [--skip-browser]"
  exit 0
fi
echo "\$*" >"$fake/argv"
for a in "\$@"; do
  [[ "\$a" == --skip-browser && "$mode" != current ]] && { echo "--skip-browser no longer skips" >&2; exit 1; }
done
[[ "$mode" == broken ]] && exit 1
mkdir -p "$home/.local/bin" "$home/.hermes/logs"
cat >"$home/.local/bin/hermes" <<'HB'
#!/usr/bin/env bash
echo "\$*" >"\$(dirname "\$0")/../../pm-argv"
sleep 2
echo done >"\$(dirname "\$0")/../../pm-done"
HB
chmod +x "$home/.local/bin/hermes"
INST
  cat >"$fake/stubs/curl" <<CURL
#!/usr/bin/env bash
# Serve the fixture to -o <file>, or to stdout for a \`curl | bash\` recipe.
while [[ \$# -gt 0 ]]; do [[ "\$1" == -o ]] && { cp "$fake/installer.sh" "\$2"; exit 0; }; shift; done
cat "$fake/installer.sh"
CURL
  chmod +x "$fake/stubs/curl"
  local recipe="${TYPE_INSTALL[hermes]//\/home\/claude/$home}"
  local t0; t0=$(date +%s%3N)
  # $(...) waits for EOF on the pipe, so the elapsed time measures how long the recipe
  # (and anything still holding its stdout/stderr) kept the exec open.
  local out
  out=$(cd "$fake" && HOME="$home" TMPDIR="$fake/tmp" PATH="$fake/stubs:/usr/bin:/bin" \
        /usr/bin/env bash -c "$recipe" 2>&1) && RC=0 || RC=$?
  MS=$(( $(date +%s%3N) - t0 ))
  ARGV=$(cat "$fake/argv" 2>/dev/null || true)
  # Wait (bounded) for the detached job so its argv is observable. Only the
  # current installer can launch one; the others would just burn the timeout.
  local w=0
  if [[ "$mode" == current ]]; then
    while [[ ! -f "$home/pm-done" && $w -lt 40 ]]; do sleep 0.1; w=$((w+1)); done
  fi
  PM=$(cat "$home/pm-argv" 2>/dev/null || true)
  TMPLEFT=$(ls -A "$fake/tmp")
  rm -rf "$fake"
}

run_recipe current
check "current installer: exits 0"                                  $(( RC != 0 ))
check "current installer: invoked with --skip-setup --skip-browser" $([[ "$ARGV" == "--skip-setup --skip-browser" ]]; echo $?)
check "current installer: browser tools fetched in the background"  $([[ "$PM" == "pm install agent-browser" ]]; echo $?)
check "current installer: exec released before the 2s browser job"  $(( MS >= 1500 ))
check "current installer: no temp file left"                        $([[ -z "$TMPLEFT" ]]; echo $?)

run_recipe retired
check "retired flag: exits 0 (flag not passed blind)"               $(( RC != 0 ))
check "retired flag: invoked with --skip-setup only"                $([[ "$ARGV" == "--skip-setup" ]]; echo $?)
check "retired flag: no background browser job"                     $([[ -z "$PM" ]]; echo $?)

run_recipe broken
check "failed install: recipe exits non-zero"                       $(( RC == 0 ))
check "failed install: no background browser job"                   $([[ -z "$PM" ]]; echo $?)
check "failed install: no temp file left"                           $([[ -z "$TMPLEFT" ]]; echo $?)

if (( fails > 0 )); then
  echo "FAIL: $fails of $arms hermes install-recipe arms failed" >&2
else
  echo "PASS: $arms of $arms hermes install-recipe arms"
fi
(( fails == 0 ))
