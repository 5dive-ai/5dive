#!/usr/bin/env bash
# DIVE-7950 — crew (the CrewAI runtime, DIVE-787) left the core CLI for
# crew@5dive-plugins (5dive-ai/5dive-plugins plugins/crew). lodar 11-09: "do we
# still need this crew? just move to plugin". The plugin's own harness grades the
# verb (install, no receipt by default, --receipt posts one): 5dive-plugins
# test/crew-plugin.test.ts. This one grades core's half, against a BUILT bundle
# and a throwaway STATE_DIR:
#   A  src/cmd_crew.sh is gone and unbundled
#   B  `crew` is released: not in FIVEDIVE_BUILTIN_VERBS, no case label in main()
#   C  a box without the plugin answers every crew spelling with ONE line, rc 2
#   D  with a plugin claiming `crew`, core hands it the argv unchanged (+ --json)
#   E  SECURITY.md no longer lists a crew receipt among what leaves the server
#
# Run: bash tests/crew_moved_to_plugin_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
WORK=$(mktemp -d)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

LINE="crew is a plugin now: sudo 5dive plugin add crew@5dive-plugins"

# --- A. the module is gone and unbundled ------------------------------------
[[ ! -e "$SRC/cmd_crew.sh" ]] && ! grep -q 'src/cmd_crew\.sh' build.sh \
  && ok_t "A src/cmd_crew.sh is gone from src/ and build.sh" \
  || bad_t "A src/cmd_crew.sh is gone from src/ and build.sh" "it moved to plugins/crew/bin/crew"

# --- B. `crew` is released, not a builtin -----------------------------------
BV=$(sed -n 's/^readonly FIVEDIVE_BUILTIN_VERBS="\(.*\)"$/\1/p' "$SRC/cmd_plugin.sh")
[[ -n "$BV" ]] || bad_t "B FIVEDIVE_BUILTIN_VERBS was read" "the extractor found nothing — B measured nothing"
[[ -n "$BV" && " $BV " != *" crew "* ]] \
  && ok_t "B crew is not in FIVEDIVE_BUILTIN_VERBS" || bad_t "B crew is not in FIVEDIVE_BUILTIN_VERBS" "$BV"
grep -qE '^    crew\)' "$SRC/main.sh" \
  && bad_t "B main() has no top-level crew label" "a label would shadow the plugin's verb" \
  || ok_t "B main() has no top-level crew label"

# --- build the artifact the arms below run ----------------------------------
BIN="$WORK/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$WORK/build.log" 2>&1; then
  bad_t "the bundle builds" "$(tail -5 "$WORK/build.log")"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
run() { STATE_DIR="$SD" "$BIN" "$@" 2>&1; }

# --- C. no plugin: one line, rc 2 -------------------------------------------
SD="$WORK/state-none"; mkdir -p "$SD"
for argv in "crew" "crew run demo" "crew list"; do
  # shellcheck disable=SC2086
  out=$(run $argv); rc=$?
  [[ "$rc" == 2 && "$out" == "error: $LINE" ]] \
    && ok_t "C \`5dive $argv\` without the plugin: the one line, rc 2" \
    || bad_t "C \`5dive $argv\` without the plugin: the one line, rc 2" "rc=$rc out=[$out]"
done

# --- D. with the plugin, core hands it the verb -----------------------------
SD="$WORK/state-plugin"; key="crew@5dive-plugins"
dir="$SD/plugins/cache/5dive-plugins/crew/0.1.0"
mkdir -p "$dir/bin" "$SD/plugins/enabled"
cat >"$dir/bin/crew" <<SH
#!/usr/bin/env bash
printf '%s json=%s\n' "\$*" "\${FIVEDIVE_JSON_MODE:-}" >>"$SD/argv"
SH
chmod +x "$dir/bin/crew"
ln -sfn "$dir" "$SD/plugins/enabled/$key"
jq -n --arg k "$key" '{($k): {plugin:"crew", enabled:true, capabilities:["verb"], verbs:[{name:"crew"}]}}' \
  >"$SD/plugins/installed.json"
: >"$SD/argv"
out=$(run crew run demo --receipt); rc=$?
[[ "$rc" == 0 && "$(tail -1 "$SD/argv")" == "run demo --receipt json=0" ]] \
  && ok_t "D \`crew run demo --receipt\` reaches the plugin's bin/crew unchanged" \
  || bad_t "D \`crew run demo --receipt\` reaches the plugin's bin/crew unchanged" "rc=$rc out=[$out] argv=[$(cat "$SD/argv")]"
out=$(run --json crew list); rc=$?
[[ "$rc" == 0 && "$(tail -1 "$SD/argv")" == "list json=1" ]] \
  && ok_t "D a global --json reaches the plugin as FIVEDIVE_JSON_MODE=1" \
  || bad_t "D a global --json reaches the plugin as FIVEDIVE_JSON_MODE=1" "rc=$rc out=[$out] argv=[$(cat "$SD/argv")]"

# --- E. SECURITY.md ---------------------------------------------------------
grep -qiE 'crew run|cmd_crew' SECURITY.md \
  && bad_t "E SECURITY.md no longer lists a crew receipt" "$(grep -niE 'crew run|cmd_crew' SECURITY.md)" \
  || ok_t "E SECURITY.md no longer lists a crew receipt"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
