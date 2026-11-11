#!/usr/bin/env bash
# DIVE-8181 — a hire starts with the app's chat on, so the owner's first
# "Chat here" opens at once instead of "Getting X ready… about a minute".
#
# lodar, 2026-11-11: "should we install dashboard chat on default for single
# agents and teams leads? so human dont wait". Graded three ways:
#   H. hire_app_chat, the one rule (validation.sh), over box x type x channels;
#   I. the REAL cmd_import's argv to cmd_create (the 7848 seam): a single hire
#      gets dashboard, an explicit --channels is kept, a team member does not;
#   T. the REAL cmd_compose_up of a team import: the lead's create/import carries
#      the chat, the member's does not, and a bare `up` changes nothing.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }
for t in jq python3; do command -v "$t" >/dev/null || { printf 'SKIP - %s unavailable\n' "$t"; exit 0; }; done

export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env" FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
hosted()   { rm -f "$FIVEDIVE_CHAT_ONLY_MARK"; : > "$FIVEDIVE_CONNECTORD_ENV"; }
selfhost() { rm -f "$FIVEDIVE_CHAT_ONLY_MARK" "$FIVEDIVE_CONNECTORD_ENV"; }
linked()   { rm -f "$FIVEDIVE_CONNECTORD_ENV"; : > "$FIVEDIVE_CHAT_ONLY_MARK"; }

# --------------------------------------------------------------------------
echo '== H. hire_app_chat =='
(
  cd "$ROOT" || exit 1
  # shellcheck disable=SC1091
  source src/header.sh; source src/lib/output.sh; source src/lib/error_codes.sh; source src/lib/validation.sh
  r() { "$1"; hire_app_chat "$2" "$3"; }
  printf '%s\n' \
    "$(r hosted claude '')" "$(r hosted codex none)" "$(r hosted claude telegram)" \
    "$(r hosted claude telegram,dashboard)" "$(r hosted hermes '')" "$(r linked claude '')" \
    "$(r selfhost claude '')" "$(r selfhost claude telegram)" "$(r hosted nosuchtype telegram)"
) > "$TMP/h.out" 2>&1
mapfile -t H < "$TMP/h.out"
eq_t 'H1 a box 5dive runs, claude, nothing named: dashboard' dashboard "${H[0]:-}"
eq_t 'H2 codex, "none": dashboard' dashboard "${H[1]:-}"
eq_t 'H3 telegram named: telegram stays first, dashboard after it' telegram,dashboard "${H[2]:-}"
eq_t 'H4 dashboard already there: unchanged, not doubled' telegram,dashboard "${H[3]:-}"
eq_t 'H5 another web-chat runtime (hermes): dashboard' dashboard "${H[4]:-}"
eq_t 'H6 a self-hosted box linked for chat: dashboard' dashboard "${H[5]:-}"
eq_t 'H7 a self-hosted box the app cannot reach: nothing added (NEGATIVE CONTROL)' '' "${H[6]:-}"
eq_t 'H8 ...and a named channel stays as given (NEGATIVE CONTROL)' telegram "${H[7]:-}"
eq_t 'H9 a runtime with no web chat: unchanged (NEGATIVE CONTROL)' telegram "${H[8]:-}"

# --------------------------------------------------------------------------
echo '== I. agent import (the real cmd_import, up to cmd_create) =='
imp() { # <label> [env assignments via env] args… -> the --channels= value cmd_create got ("-" = none)
  local label="$1"; shift
  (
    cd "$ROOT" || exit 1
    set +u
    # shellcheck disable=SC1091
    source src/header.sh; source src/lib/output.sh; source src/lib/error_codes.sh
    source src/lib/validation.sh; source src/lib/models.sh; source src/lib/agent_setup.sh; source src/lib/registry.sh
    STATE_DIR="$TMP/state-$label"; mkdir -p "$STATE_DIR"
    source src/cmd_auth.sh; source src/cmd_agent_create.sh; source src/cmd_pack.sh; source src/cmd_init.sh
    set +e
    account_default_v() { return 1; }
    require_root() { :; }
    AUTH_PROFILES_DIR="$TMP/ap"; mkdir -p "$AUTH_PROFILES_DIR/mp"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture\n' > "$AUTH_PROFILES_DIR/mp/combined.env"
    REGISTRY="$TMP/reg-$label.json"; REGISTRY_LOCK="$TMP/reg.lock"; printf '{"agents":{}}\n' > "$REGISTRY"
    registry_write() { local t; t=$(cat); printf '%s\n' "$t" > "$REGISTRY"; }
    printf '%s\n' '{"packFormat":1,"agentName":"olivia","config":{"type":"claude"},"includes":{"memory":false}}' > "$TMP/manifest.json"
    : > "$TMP/olivia.tar.gz"
    _agents_md_is() { return 1; }
    _pack_safe_extract() { cp "$TMP/manifest.json" "$2/manifest.json"; }
    _pack_harness_targets() { printf '%s\n' claude codex; }
    _pack_targets_declared() { return 1; }
    _pack_disclosure_json() { printf '%s\n' '{}'; }
    _pack_disclosure_print() { :; }
    _pack_rename_persona() { :; }
    _import_can_ask_ai() { return 1; }
    resolve_model_alias() { printf '%s' "$1"; }
    resolve_model_for_profile() { printf '%s' "$1"; }
    cmd_create() { printf '%s\n' "$@" > "$TMP/$label.argv"; exit 0; }
    cmd_import "$TMP/olivia.tar.gz" --as=olivia --auth-profile=mp "$@"
  ) > "$TMP/$label.out" 2>&1
  [[ -f "$TMP/$label.argv" ]] || { echo "(cmd_create not reached: $(tail -2 "$TMP/$label.out" | tr '\n' ' '))"; return; }
  local c; c=$(sed -n 's/^--channels=//p' "$TMP/$label.argv" | head -1); printf '%s' "${c:--}"
}
hosted
eq_t 'I1 a single hire on a box 5dive runs: the seat is created with the app chat' dashboard "$(imp i1)"
eq_t 'I2 a single hire with a Telegram bot: telegram first, app chat after' telegram,dashboard "$(imp i2 --telegram-token=123:abc)"
eq_t 'I3 an explicit --channels is kept as given' telegram "$(imp i3 --channels=telegram)"
eq_t 'I4 explicit --channels=none is kept (the owner said none)' none "$(imp i4 --channels=none)"
eq_t 'I5 a team member (FIVEDIVE_HIRE_CHAT=0): as before, nothing named' - "$(FIVEDIVE_HIRE_CHAT=0 imp i5)"
eq_t "I6 a team's lead: app chat added to the template's own channels" telegram,dashboard "$(FIVEDIVE_HIRE_CHAT=lead imp i6 --channels=telegram)"
eq_t 'I7 the pack is codex (--type=codex): app chat too' dashboard "$(imp i7 --type=codex)"
selfhost
eq_t 'I8 a self-hosted box the app cannot reach: nothing named, as before (NEGATIVE CONTROL)' - "$(imp i8)"

# --------------------------------------------------------------------------
echo '== T. team import (the real cmd_compose_up) =='
python3 -c 'import yaml' 2>/dev/null && command -v sqlite3 >/dev/null || { printf 'SKIP - T arms need PyYAML + sqlite3\n'; T_SKIP=1; }
if [[ -z "${T_SKIP:-}" ]]; then
  BIN="$TMP/5dive"
  ( cd "$ROOT" && BUILD_OUT="$BIN" ./build.sh >/dev/null 2>&1 ) || bad_t 'T0 the CLI does not build' ''
  export STATE_DIR="$TMP/state" TASKS_DB="$TMP/state/tasks/tasks.db" REGISTRY="$TMP/state/agents.json"
  export FIVEDIVE_HARNESS=1 FIVEDIVE_NO_HUMAN_SEND=1 FIVE_WIP_CAP=0
  SELF="$TMP/self.sh"
  cat > "$SELF" <<EOF
#!/usr/bin/env bash
a=("\$@"); [[ "\${a[0]:-}" == --json ]] && a=("\${a[@]:1}")
case "\${a[0]:-} \${a[1]:-}" in
  "agent create"|"agent import")
    n="\${a[2]}"; [[ "\$n" == --as=* ]] && n="\${n#--as=}"
    for x in "\${a[@]}"; do [[ "\$x" == --as=* ]] && n="\${x#--as=}"; done
    ch=-; for x in "\${a[@]}"; do [[ "\$x" == --channels=* ]] && ch="\${x#--channels=}"; done
    printf '%s %s ch=%s hire=%s\n' "\${a[1]}" "\$n" "\$ch" "\${FIVEDIVE_HIRE_CHAT:-unset}" >> "$TMP/calls.log"
    tmp=\$(mktemp); jq --arg n "\$n" '.agents[\$n] = {type:"claude"}' "$REGISTRY" > "\$tmp" && mv "\$tmp" "$REGISTRY"
    exit 0 ;;
  "agent "*|"org "*|"browser "*) exit 0 ;;
esac
exec "$BIN" "\$@"
EOF
  chmod +x "$SELF"
  run_up() { # <team key> <spec>
    rm -rf "$STATE_DIR" "$TMP/calls.log"; mkdir -p "$STATE_DIR/tasks"; : > "$TMP/calls.log"
    printf '{"schemaVersion":2,"agents":{}}\n' > "$REGISTRY"
    printf '%s\n' "$2" > "$TMP/team.yaml"
    (
      cd "$ROOT/src" || exit 1
      for f in header.sh lib/*.sh; do . "./$f"; done
      . ./cmd_task.sh; . ./cmd_heartbeat.sh; . ./cmd_loop_pack.sh; . ./cmd_compose.sh
      ensure_state() { :; }; registry_write() { cat > "$REGISTRY"; }
      persona_append_block() { :; }; _skill_list_json() { printf '[]'; }
      _compose_self() { printf '%s' "$SELF"; }
      JSON_MODE=1; COMPOSE_TEAM_KEY="$1"
      cmd_compose_up -f "$TMP/team.yaml" --start-now
    ) >/dev/null 2>"$TMP/up.err"
  }
  call() { grep -m1 " $1 " "$TMP/calls.log" | cut -d' ' -f1,3-; }
  PLAIN='version: "2"
agents:
  desk:
    type: claude
    role: "Lead"
  reviewer:
    type: claude
    role: "Reviewer"
    reports_to: desk'
  PACKS='version: "2"
agents:
  olivia:
    pack: olivia
    role: "Lead"
  sam:
    pack: sam
    role: "Analyst"
    reports_to: olivia'
  hosted
  run_up trading "$PLAIN"
  eq_t 'T1 team import, lead created: with the app chat' 'create ch=dashboard hire=unset' "$(call desk)"
  eq_t 'T2 ...and the member: as before (NEGATIVE CONTROL)' 'create ch=- hire=unset' "$(call reviewer)"
  run_up trading "$PACKS"
  eq_t 'T3 team import of packs: the lead import is told it is the lead' 'import ch=- hire=lead' "$(call olivia)"
  eq_t 'T4 ...and the member import that it is a member' 'import ch=- hire=0' "$(call sam)"
  run_up "" "$PLAIN"
  eq_t 'T5 a bare up (not a team import): the root is not touched (NEGATIVE CONTROL)' 'create ch=- hire=unset' "$(call desk)"
  selfhost
  run_up trading "$PLAIN"
  eq_t 'T6 team import on a box the app cannot reach: nothing added (NEGATIVE CONTROL)' 'create ch=- hire=unset' "$(call desk)"
  [[ -s "$TMP/calls.log" ]] || bad_t 'T7 compose never reached create — T arms vacuous' "$(tail -5 "$TMP/up.err")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
