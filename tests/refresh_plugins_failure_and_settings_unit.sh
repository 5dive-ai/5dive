#!/usr/bin/env bash
# DIVE-4867: telegram@5dive-plugins 0.5.50 -> 0.5.59 never reached five
# control-plane seats. They sat on 0.5.49 from 2026-08-26 to 2026-09-23, every
# nightly `5dive-refresh-plugins.sh` failed for them, and the log showed nothing.
# Two defects, one arm group each:
#
#   F — FAILURES WERE FILTERED OUT. Each `claude plugin …` step was piped
#       through `grep -E 'updated|error|warn|fail'`, case-sensitive, and Claude
#       Code prints `✘ Failed to update marketplace(s): …`. The one line a
#       failure prints was the one line dropped, so a failing seat logged what a
#       seat with nothing to do logs.
#   S — settings.json WAS NEVER MIGRATED. The 5dive-com -> 5dive-ai migration
#       rewrote known_marketplaces.json and the clone remote but not
#       `settings.json .extraKnownMarketplaces.<name>.source`; when the two
#       disagree Claude Code answers `Marketplace '5dive-plugins' not found`.
#       The source must match EXACTLY, form included (github `repo` vs git
#       `url`) — on two seats an org-only rewrite still failed.
#
# END TO END, NOT A FENCE EXTRACT. Every arm runs the WHOLE shipped script for
# one seat whose home is a temp dir. `sudo`, `id` and `getent` are PATH stubs
# (sudo drops `-u X -H` and runs the rest as the caller), CLAUDE_BIN is a stub
# whose output and exit code each arm scripts, GH_ORG is pinned so no network
# probe runs, and FORK_STAGE_SH is a no-op so the box's real fork staging is
# never reached. Nothing outside $WORK is read or written.
#
# Run: bash tests/refresh_plugins_failure_and_settings_unit.sh   (no root, no network)
# REFRESH_PLUGINS_SH=<path> grades another copy of the script (a pre-fix tree).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is $? captured at trap time
trap 'rc=$?; rm -rf "${WORK:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - refresh_plugins_failure_and_settings_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
SCRIPT="${REFRESH_PLUGINS_SH:-$ROOT/5dive-refresh-plugins.sh}"
command -v jq >/dev/null 2>&1 || { echo "jq required"; SUMMARY_PRINTED=1; exit 1; }

WORK="$(mktemp -d)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/bash
while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
exec "$@"
STUB
cat > "$WORK/bin/id" <<'STUB'
#!/bin/bash
echo 4242
STUB
cat > "$WORK/bin/getent" <<'STUB'
#!/bin/bash
u="${2:?}"; echo "$u:x:4242:4242::${SEAT_HOME:?}:/bin/bash"
STUB
# The claude stub: `plugin marketplace update` answers with MP_OUT / MP_RC,
# every other step with PL_OUT / PL_RC. Every argv is recorded.
cat > "$WORK/bin/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${CLAUDE_LOG:?}"
if [[ "$1 $2" == "plugin marketplace" ]]; then printf '%b' "${MP_OUT:-}"; exit "${MP_RC:-0}"; fi
printf '%b' "${PL_OUT:-}"; exit "${PL_RC:-0}"
STUB
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/fork-stage"
chmod +x "$WORK/bin/"*

OK_MP='✔ Successfully updated marketplace: 5dive-plugins\n'
OK_PL='✔ telegram is already at the latest version (0.5.59).\n'
NOTFOUND="✘ Failed to update marketplace(s): Marketplace '5dive-plugins' not found\n"

KM_GIT_AI='{"5dive-plugins":{"source":{"source":"git","url":"https://github.com/5dive-ai/5dive-plugins.git"},"installLocation":"/x","lastUpdated":"2026-09-23T00:00:00Z"}}'
KM_GH_COM='{"5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"},"installLocation":"/x","lastUpdated":"2026-09-23T00:00:00Z"}}'
ST_GH_COM='{"model":"opus","extraKnownMarketplaces":{"5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"}}},"enabledPlugins":{"telegram@5dive-plugins":true}}'
ST_GIT_COM='{"extraKnownMarketplaces":{"5dive-plugins":{"source":{"source":"git","url":"https://github.com/5dive-com/5dive-plugins.git"}}},"enabledPlugins":{"telegram@5dive-plugins":true}}'
ST_THIRD='{"extraKnownMarketplaces":{"5dive-plugins":{"source":{"source":"github","repo":"5dive-com/5dive-plugins"}},"acme":{"source":{"source":"github","repo":"acme/market"}}},"enabledPlugins":{"telegram@5dive-plugins":true}}'
INSTALLED='{"version":2,"plugins":{"telegram@5dive-plugins":[{"version":"0.5.49","gitCommitSha":"bc5a520aaaa"}]}}'

# seat <settings|NONE> <known_marketplaces|NONE> — fresh seat home for one arm.
seat() {
  rm -rf "${WORK:?}/home"; mkdir -p "$WORK/home/.claude/plugins"
  [[ "$1" == NONE ]] || printf '%s\n' "$1" > "$WORK/home/.claude/settings.json"
  [[ "$2" == NONE ]] || printf '%s\n' "$2" > "$WORK/home/.claude/plugins/known_marketplaces.json"
  printf '%s\n' "$INSTALLED" > "$WORK/home/.claude/plugins/installed_plugins.json"
}
# run [GH_ORG] — the whole shipped script for seat `s1`; stdout+stderr.
run() {
  : > "$WORK/claude.log"
  env PATH="$WORK/bin:$PATH" SEAT_HOME="$WORK/home" CLAUDE_BIN="$WORK/bin/claude" \
      CLAUDE_LOG="$WORK/claude.log" GH_ORG="${1:-5dive-ai}" FORK_STAGE_SH="$WORK/bin/fork-stage" \
      AGENTS_REGISTRY="$WORK/no-registry.json" \
      MP_OUT="${MP_OUT:-}" MP_RC="${MP_RC:-0}" PL_OUT="${PL_OUT:-}" PL_RC="${PL_RC:-0}" \
      REFRESH_FAIL_LINES="${REFRESH_FAIL_LINES:-20}" \
      bash "$SCRIPT" s1 2>&1
}
st_src() { jq -c '.extraKnownMarketplaces["'"${1:-5dive-plugins}"'"].source' "$WORK/home/.claude/settings.json"; }
km_src() { jq -c '.["5dive-plugins"].source' "$WORK/home/.claude/plugins/known_marketplaces.json"; }
flat() { tr '\n' '|' <<<"$1"; }

# ================================================================================
# F — a failed step is LOGGED and COUNTED
# ================================================================================
seat "$ST_GIT_COM" "$KM_GIT_AI"
out="$(MP_OUT="$NOTFOUND" MP_RC=1 PL_OUT="$OK_PL" run)"
if grep -qF "[marketplace 5dive-plugins] ✘ Failed to update marketplace(s): Marketplace '5dive-plugins' not found" <<<"$out"; then
  ok_t "F1 Claude Code's own '✘ Failed …' line reaches the log (the case-sensitive filter dropped it)"
else
  bad_t "F1 the failure line is filtered out of the log" "out: $(flat "$out")"
fi
if grep -q '^  refresh_failed_count: 1$' <<<"$out" && grep -q '^  refresh_failed: s1$' <<<"$out"; then
  ok_t "F2 the failing seat is counted and named in the run summary"
else
  bad_t "F2 no per-seat failure in the summary" "out: $(flat "$out")"
fi
seat NONE NONE; printf '%s\n' '{"enabledPlugins":{"telegram@5dive-plugins":true}}' > "$WORK/home/.claude/settings.json"
out="$(MP_OUT="$NOTFOUND" MP_RC=0 PL_OUT="$OK_PL" run)"
if grep -q '^  refresh_failed_count: 1$' <<<"$out"; then
  ok_t "F3 a '✘' line with exit 0 still counts — the exit code is not trusted to track Claude Code's own verdict"
else
  bad_t "F3 exit-0 failure not counted" "out: $(flat "$out")"
fi
out="$(MP_OUT="$OK_MP" PL_OUT='' PL_RC=3 run)"
if grep -qF '[plugin update telegram@5dive-plugins] FAILED (exit 3)' <<<"$out" && grep -q '^  refresh_failed_count: 1$' <<<"$out"; then
  ok_t "F4 a SILENT non-zero exit is a failure and says so (no output line to filter is not 'nothing happened')"
else
  bad_t "F4 silent non-zero exit not reported" "out: $(flat "$out")"
fi
out="$(MP_OUT="$OK_MP" PL_OUT='Error: EACCES: permission denied, rmdir …/5dive-plugins.bak\n' PL_RC=0 run)"
if grep -qF 'Error: EACCES' <<<"$out" && grep -q '^  refresh_failed_count: 1$' <<<"$out"; then
  ok_t "F5 a capitalised 'Error:' line is logged and counted (the filter is case-insensitive now)"
else
  bad_t "F5 capitalised Error dropped" "out: $(flat "$out")"
fi
noisy=''; for i in $(seq 1 30); do noisy+="✘ Failed line $i\n"; done
out="$(REFRESH_FAIL_LINES=5 MP_OUT="$noisy" MP_RC=1 PL_OUT="$OK_PL" run)"
if grep -qF 'Failed line 5' <<<"$out" && ! grep -qF 'Failed line 6' <<<"$out" && grep -qF '25 more line(s) not shown' <<<"$out"; then
  ok_t "F6 a noisy failure is capped and says how much it cut"
else
  bad_t "F6 failure output not capped" "out: $(flat "$out")"
fi
out="$(MP_OUT="$OK_MP" PL_OUT="$OK_PL" run)"
if grep -q '^  refresh_failed_count: 0$' <<<"$out" && ! grep -q 'FAILED' <<<"$out" \
   && grep -qF '✔ Successfully updated marketplace' <<<"$out" && grep -qF 'already at the latest' <<<"$out"; then
  ok_t "F7 NEGATIVE CONTROL — a clean run counts 0, prints no FAILED, and keeps its success lines"
else
  bad_t "F7 a clean run reads as failed (or lost its success lines)" "out: $(flat "$out")"
fi
if grep -q '^plugin marketplace update 5dive-plugins$' "$WORK/claude.log" && grep -q '^plugin update telegram@5dive-plugins$' "$WORK/claude.log"; then
  ok_t "F8 the steps still run with the same argv (the capture changed, the calls did not)"
else
  bad_t "F8 claude argv changed" "log: $(flat "$(cat "$WORK/claude.log")")"
fi

# ================================================================================
# S — settings.json takes known_marketplaces' source, form included
# ================================================================================
seat "$ST_GH_COM" "$KM_GIT_AI"
ino_before=$(stat -c %i "$WORK/home/.claude/settings.json")
out="$(MP_OUT="$OK_MP" PL_OUT="$OK_PL" run)"
if [[ "$(st_src)" == "$(km_src)" && "$(st_src)" == '{"source":"git","url":"https://github.com/5dive-ai/5dive-plugins.git"}' ]]; then
  ok_t "S1 a github-form 5dive-com settings source takes known_marketplaces' GIT-form object verbatim (org-only rewrite still failed on two seats)"
else
  bad_t "S1 settings source does not match known_marketplaces exactly" "settings=$(st_src) km=$(km_src)"
fi
if grep -qF 'migrated settings.json marketplace 5dive-plugins -> {"source":"git"' <<<"$out"; then
  ok_t "S2 the rewrite is logged with the source it wrote"
else
  bad_t "S2 no migration line" "out: $(flat "$out")"
fi
if [[ "$(stat -c %i "$WORK/home/.claude/settings.json")" == "$ino_before" ]] \
   && [[ "$(jq -c 'keys_unsorted' "$WORK/home/.claude/settings.json")" == '["model","extraKnownMarketplaces","enabledPlugins"]' ]] \
   && [[ "$(jq -r .model "$WORK/home/.claude/settings.json")" == opus ]]; then
  ok_t "S3 written in place (same inode, so the seat keeps ownership), key order and other keys untouched"
else
  bad_t "S3 settings.json replaced or reordered" "inode $ino_before -> $(stat -c %i "$WORK/home/.claude/settings.json"); keys $(jq -c keys_unsorted "$WORK/home/.claude/settings.json")"
fi
out="$(MP_OUT="$OK_MP" PL_OUT="$OK_PL" run)"
if ! grep -q 'migrated settings.json' <<<"$out"; then
  ok_t "S4 idempotent — a second run rewrites nothing"
else
  bad_t "S4 settings migrated twice" "out: $(flat "$out")"
fi

seat "$ST_GH_COM" "$KM_GH_COM"
run >/dev/null
if [[ "$(km_src)" == '{"source":"github","repo":"5dive-ai/5dive-plugins"}' && "$(st_src)" == "$(km_src)" ]]; then
  ok_t "S5 both on 5dive-com: known_marketplaces is migrated first and settings follows it"
else
  bad_t "S5 km/settings out of step" "settings=$(st_src) km=$(km_src)"
fi

seat "$ST_GIT_COM" NONE
run >/dev/null
if [[ "$(st_src)" == '{"source":"git","url":"https://github.com/5dive-ai/5dive-plugins.git"}' ]]; then
  ok_t "S6 no known_marketplaces entry: the org is rewritten in place and the git form is kept"
else
  bad_t "S6 fallback rewrite wrong" "settings=$(st_src)"
fi

# known_marketplaces DISAGREES with settings on acme (git form vs github form) —
# without that, the scope guard is never consulted and this arm passes vacuously.
seat "$ST_THIRD" "$(jq -c '. + {"acme":{"source":{"source":"git","url":"https://github.com/acme/market.git"}}}' <<<"$KM_GIT_AI")"
run >/dev/null
if [[ "$(st_src acme)" == '{"source":"github","repo":"acme/market"}' && "$(st_src)" == "$(km_src)" ]]; then
  ok_t "S7 NEGATIVE CONTROL — a third-party marketplace entry is left exactly as the operator declared it"
else
  bad_t "S7 third-party entry touched" "acme=$(st_src acme) 5dive=$(st_src)"
fi

seat "$ST_GH_COM" "$KM_GIT_AI"
run 5dive-com >/dev/null
if [[ "$(st_src)" == '{"source":"github","repo":"5dive-com/5dive-plugins"}' ]]; then
  ok_t "S8 NEGATIVE CONTROL — while the new org is not live (GH_ORG=5dive-com) settings is not touched"
else
  bad_t "S8 migrated before the org is live" "settings=$(st_src)"
fi

seat NONE "$KM_GIT_AI"; printf '%s' '{"extraKnownMarketplaces":{"5dive-plugins":{"source":{"repo":"5dive-com/5dive-pl' > "$WORK/home/.claude/settings.json"
cp "$WORK/home/.claude/settings.json" "$WORK/corrupt.orig"
out="$(run)"
if cmp -s "$WORK/home/.claude/settings.json" "$WORK/corrupt.orig" && grep -q 'not valid JSON' <<<"$out"; then
  ok_t "S9 a corrupt settings.json is left byte-identical and named in the log"
else
  bad_t "S9 corrupt settings.json rewritten or silent" "out: $(flat "$out")"
fi

echo
echo "$PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == 0 ]]
