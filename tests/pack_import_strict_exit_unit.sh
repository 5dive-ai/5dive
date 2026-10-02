#!/usr/bin/env bash
# DIVE-5395 — a registry pack import must EXIT 0 under the CLI's own strict mode.
#
# THE BUG: every Mini App Olivia hire read "hire failed" (lodar's e2e, 2026-10-02,
# twice, CLI 0.67.1 and 0.68.0). The agent was fully created; `agent import`
# exited 1 right after "persona installed" with the backstop's "exited 1 without
# reporting a reason". The hire binds the box's demo-ai OpenRouter account, so
# olivia's `model: opus` resolves to the account's mapped vendor id (DIVE-5163),
# and model_effort_ids_json returned 1 for any model that is not `claude-*`:
# its brace group ended in `[[ … ]] && printf`, and pipefail carried that 1 out
# through `effort_ids=$(…)`, which set -e turns into a silent death.
#
# WHY NOTHING CAUGHT IT: model_alias_mapping_account_unit.sh runs the real
# cmd_import on exactly that account — but after `set +e`, it reads only the
# model handed to _pack_unapplied_on (which runs BEFORE the death), and it never
# looks at the exit code. This file runs the same real cmd_import with errexit,
# nounset and pipefail ON inside the import, olivia's manifest shape, through the
# registry-slug path, and grades the exit code and the final ok line.
#
# Arms: (1) OpenRouter-mapped account, (2) a plain Claude account, (3) a pack
# that pins a vendor id, (4) the CONTROL: the pre-fix model_effort_ids_json body
# swapped back in must make arm 1's import exit non-zero — so a green arm 1
# means the fix, not a harness that cannot see the death.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         cmd_agent.sh cmd_agent_runtime.sh cmd_agent_config.sh cmd_pack.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

command -v jq >/dev/null 2>&1 || { bad_t 'jq unavailable — arms 1-4 NOT REACHED'; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

TMP=$(mktemp -d)
# Never a real home: cmd_import writes under ${AGENT_HOME_ROOT:-/home}/agent-<as>.
AGENT_HOME_ROOT="$TMP/home"
FLASH="anthropic/claude-opus-4.5"
AUTH_PROFILES_DIR="$TMP/profiles"
mkprof() { # <name> <base-url or ""> <mapped id or "">
  mkdir -p "$AUTH_PROFILES_DIR/$1"
  {
    if [[ -n "$2" ]]; then printf 'ANTHROPIC_BASE_URL=%s\nANTHROPIC_AUTH_TOKEN=sk-test\n' "$2"
    else printf 'CLAUDE_CODE_OAUTH_TOKEN=oat-test\n'; fi
    if [[ -n "$3" ]]; then
      printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\nANTHROPIC_DEFAULT_SONNET_MODEL=%s\nANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "$3" "$3" "$3"
    fi
  } >"$AUTH_PROFILES_DIR/$1/combined.env"
}
# The box's demo key, as an alias-mapping OpenRouter account (DIVE-5255).
mkprof demo-ai https://openrouter.ai/api "$FLASH"
mkprof client-claude "" ""

# Olivia's registry pack, by shape (5dive-ai/5dive-marketplace packs/olivia,
# read 2026-10-02): claude, opus, effort high, standard isolation, distilled
# memory, two skills, a CLAUDE.md.
mkpack() { # <dir> <model>
  local d="$1"
  mkdir -p "$d/memory" "$d/skills/deep-research" "$d/skills/pitch-deck"
  jq -n --arg m "$2" '{packFormat:1, agentName:"olivia",
    config:{type:"claude", model:$m, effort:"high", isolation:"standard"},
    includes:{memory:"distilled"}, skills:["deep-research","pitch-deck"]}' >"$d/manifest.json"
  printf '# Olivia\n\nYou are Olivia.\n' >"$d/CLAUDE.md"
  printf -- '---\nname: f1\n---\nfact one\n' >"$d/memory/f1.md"
  printf -- '---\nname: deep-research\n---\nbody\n' >"$d/skills/deep-research/SKILL.md"
  printf -- '---\nname: pitch-deck\n---\nbody\n' >"$d/skills/pitch-deck/SKILL.md"
}

# --- the seams: root-only effects and the network. Everything between create and
# the ok line that is not one of these runs as shipped. ---------------------------
printf '%s' '{"agents":{}}' >"$TMP/reg"
require_root() { :; }
registry_read() { cat "$TMP/reg"; }
registry_write() { cat >"$TMP/reg"; }
_marketplace_fetch_pack() { : >"$TMP/fetched.tar.gz"; printf '%s' "$TMP/fetched.tar.gz"; }
_pack_safe_extract() { cp -a "$TMP/pack/." "$2/"; }
cmd_create() {
  jq --arg n "$1" '.agents[$n] = {type:"claude"}' <<<"$(cat "$TMP/reg")" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
  return 0
}
# The same line persona_install_doc prints on a box — the last line lodar's hires
# showed before the death — then success, as on a box.
persona_install_doc() { step "[$1] persona installed at /home/agent-$1/.claude/CLAUDE.md (type=$2)"; return 0; }
_install_bundled_skill() { return 0; }
_pack_record_write() { return 0; }
_pack_skill_shas() { printf '{}'; }
# install as a plain copy / mkdir: owner and mode need root, the bytes do not.
install() {
  local -a a=(); local d=0
  while (( $# )); do
    case "$1" in -o|-g|-m) shift 2 ;; -d) d=1; shift ;; *) a+=("$1"); shift ;; esac
  done
  if (( d )); then mkdir -p "${a[@]}"; else cp "${a[0]}" "${a[1]}"; fi
}
chown() { :; }

# Runs the REAL cmd_import with the CLI's strict mode on inside the import.
# Prints the exit code; stdout/stderr land in $TMP/out / $TMP/err.
import_rc() { # <as> <profile> <model>
  rm -rf "$TMP/pack"; mkpack "$TMP/pack" "$3"
  printf '%s' '{"agents":{}}' >"$TMP/reg"
  rm -rf "$AGENT_HOME_ROOT"; mkdir -p "$AGENT_HOME_ROOT/agent-$1/.claude"
  ( set -euo pipefail; JSON_MODE=1; cmd_import olivia --as="$1" --isolation=standard --auth-profile="$2" ) \
    >"$TMP/out" 2>"$TMP/err"
  echo $?
}
last_err() { tail -n 3 "$TMP/err" | tr '\n' ' '; }
ok_name() { jq -r 'select(.ok == true) | .data.name // empty' "$TMP/out" 2>/dev/null | tail -n1; }

echo '== 1. the Mini App hire: olivia on the demo-ai OpenRouter account =='
rc=$(import_rc olivia demo-ai opus)
eq_t 'import exits 0 (RED on main: 1, right after "persona installed")' 0 "$rc"
[[ "$rc" == 0 ]] || printf '       stderr tail: %s\n' "$(last_err)"
eq_t 'the ok envelope names the imported agent' olivia "$(ok_name)"
grep -q 'without reporting a reason' "$TMP/err" \
  && bad_t 'the silent-exit backstop fired' "$(last_err)" \
  || ok_t 'the silent-exit backstop did not fire'

eq_t 'the effort step ran: per-model effort on the mapped id is written' high \
  "$(jq -r '.modelSettings["claude-opus-5-5"].effortLevel // ""' "$AGENT_HOME_ROOT/agent-olivia/.claude/settings.json" 2>/dev/null)"
eq_t 'settings.json carries the account-mapped model' "$FLASH" \
  "$(jq -r '.model // ""' "$AGENT_HOME_ROOT/agent-olivia/.claude/settings.json" 2>/dev/null)"
[[ -n "$(ls "$AGENT_HOME_ROOT"/agent-olivia/.claude/projects/*/memory/ 2>/dev/null)" ]] \
  && ok_t 'the steps after it ran too: memory seeded' || bad_t 'memory was not seeded' "$(last_err)"

echo '== 2. the same pack on a plain Claude account =='
eq_t 'import exits 0' 0 "$(import_rc olivia2 client-claude opus)"
eq_t 'the ok envelope names the imported agent' olivia2 "$(ok_name)"

echo '== 3. a pack that pins a vendor id (no alias to resolve) =='
eq_t 'import exits 0 (RED on main: the vendor id is not claude-*)' 0 "$(import_rc olivia3 demo-ai z-ai/glm-4.6)"

echo '== 4. control: the pre-fix body makes arm 1 die =='
# Verbatim the body this row replaced. If arm 1 stays green with it, this file
# cannot see the defect and its arms 1-3 prove nothing.
model_effort_ids_json() {
  local fam id own
  own=$(model_canonical "${1:-}")
  {
    while read -r fam; do
      id=$(model_latest "$fam") && printf '%s\n' "$id"
    done < <(model_families)
    [[ "$own" == claude-* ]] && printf '%s\n' "$own"
  } | jq -R . | jq -sc 'unique'
}
rc=$(import_rc olivia demo-ai opus)
[[ "$rc" != 0 ]] && ok_t "pre-fix body: import exits $rc (the harness sees the death)" \
  || bad_t 'pre-fix body: import still exits 0 — this harness cannot see the defect' ''
# The CLI's EXIT-trap backstop is not armed in a sourced harness, so the silence
# is graded directly: the last thing the import said is "persona installed" —
# lodar's hires, byte for byte — and nothing after it, no fail line.
case "$(tail -n1 "$TMP/err")" in
  *'persona installed at '*) ok_t 'pre-fix body: dies silently right after "persona installed", as on lodar'"'"'s hires' ;;
  *) bad_t 'pre-fix body: the death was not the silent one after the persona step' "$(last_err)" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
