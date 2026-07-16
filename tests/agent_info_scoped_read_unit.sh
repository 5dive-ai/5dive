#!/usr/bin/env bash
# DIVE-1343: read-only agent info/list probes must not attempt nested sudo when
# the CLI is running under a scoped agent identity. Read accessible config and
# binaries directly; treat inaccessible sibling config as unknown.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/cmd_agent.sh
set +e

TMP="$(mktemp -d /tmp/agent-info-scoped-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SUDO_MARKER="$TMP/sudo-called"
sudo() { printf 'called\n' >> "$SUDO_MARKER"; return 1; }

printf '#!/usr/bin/env bash\nprintf "scoped-cli 1.2.3\\n"\n' > "$TMP/fake-cli"
chmod +x "$TMP/fake-cli"
TYPE_BIN[scoped-test]="$TMP/fake-cli"

if (( EUID != 0 )); then
  got=$(resolve_cli_version scoped-test)
  [[ "$got" == "scoped-cli 1.2.3" ]] \
    && ok_t "scoped version probe runs the shared binary directly" \
    || bad_t "scoped version probe" "got '$got'"
else
  printf '# root run: scoped version branch is not reachable; skipping dynamic probe\n'
fi

printf '{"model":"claude-opus","effortLevel":"high"}\n' > "$TMP/settings.json"
printf 'model = "gpt-5-codex"\n[tools]\nweb = true\n' > "$TMP/config.toml"

[[ "$(read_agent_json_value "$TMP/settings.json" '.model // empty')" == "claude-opus" ]] \
  && ok_t "readable JSON runtime config is read directly" \
  || bad_t "JSON runtime config direct read"
[[ "$(read_agent_json_value "$TMP/settings.json" '.effortLevel // empty')" == "high" ]] \
  && ok_t "readable effort setting is read directly" \
  || bad_t "effort runtime config direct read"
[[ "$(read_agent_toml_model "$TMP/config.toml")" == "gpt-5-codex" ]] \
  && ok_t "readable TOML runtime config is read directly" \
  || bad_t "TOML runtime config direct read"

if (( EUID != 0 )); then
  chmod 000 "$TMP/settings.json"
  [[ -z "$(read_agent_json_value "$TMP/settings.json" '.model // empty')" ]] \
    && ok_t "unreadable sibling config degrades to unknown" \
    || bad_t "unreadable sibling config should be unknown"
fi

if [[ ! -e "$SUDO_MARKER" ]]; then
  ok_t "scoped read probes never invoke sudo"
else
  bad_t "scoped read probes invoked sudo" "$(<"$SUDO_MARKER")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
