#!/usr/bin/env bash
# DIVE-5370: `secret write --connector=tools` — the secret gate's one-time link
# lands a key where EVERY agent reads it.
#   * every other connector file is 600 root, so an agent seat that asked its
#     owner for a key through the link could never read the answer
#   * with --connector=tools the value becomes an `export KEY='value'` line in
#     tools.sh (640, the file 5dive-agent@.service hands every agent through
#     BASH_ENV, DIVE-5366), and a fresh bash sees $KEY
#   * the quote rule holds: a value that could leave its quotes is refused and
#     nothing is written or run
#   * the gate is still cleared on --task, and a plain connector is unchanged
# Isolation: src/ sourced into a throwaway connectors dir; `5dive` is a stub on
# PATH; no root, no network.
# Run: bash tests/secret_tools_connector_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/secret-tools-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR" "$TMP/bin"

# The gate clear shells out to `5dive task answer`; record it instead.
cat > "$TMP/bin/5dive" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/answer.log"
EOF
chmod +x "$TMP/bin/5dive"
export PATH="$TMP/bin:$PATH"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_tool.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
TOOLS_WRITE_LOCK="$TMP/tool.lock"
SECRET_WRITE_LOCK="$TMP/secret.lock"
require_root() { :; }
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
F="$TOOLS_ENV_FILE"
# `fail` exits, so every write runs in a subshell; the value goes on stdin.
put() { local v="$1"; shift; ( printf '%s\n' "$v" | _secret_write "$@" ) 2>&1; }
seen() { BASH_ENV="$F" /bin/bash -c "printf '%s' \"\${$1:-}\""; }

# --- S1: a tools key becomes an export line every agent's bash reads -----------
out=$(put sk_el_FAKE_123456 ELEVENLABS_API_KEY --connector=tools); rc=$?
[[ $rc -eq 0 ]] && ok_t "S1 secret write --connector=tools succeeds" || bad_t "S1 write" "rc=$rc $out"
[[ "$(grep -c "^export ELEVENLABS_API_KEY='sk_el_FAKE_123456'$" "$F" 2>/dev/null)" == 1 ]] \
  && ok_t "S1 tools.sh holds it as one export line" || bad_t "S1 export line" "$(cat "$F" 2>&1)"
[[ "$(stat -c %a "$F" 2>/dev/null)" == 640 ]] && ok_t "S1 tools.sh is 640 (group claude reads it)" || bad_t "S1 mode" "$(stat -c %a "$F" 2>&1)"
[[ "$(seen ELEVENLABS_API_KEY)" == sk_el_FAKE_123456 ]] \
  && ok_t "S1 a fresh bash with BASH_ENV sees \$ELEVENLABS_API_KEY" || bad_t "S1 BASH_ENV pickup" "$(seen ELEVENLABS_API_KEY)"
[[ ! -e "$FIVEDIVE_CONNECTOR_DIR/tools.env" ]] \
  && ok_t "S1 no root-only tools.env was written" || bad_t "S1 stray tools.env" "$(ls -l "$FIVEDIVE_CONNECTOR_DIR")"
[[ "$out" == *"every agent's environment"* && "$out" != *sk_el_FAKE* ]] \
  && ok_t "S1 says where it went, never the value" || bad_t "S1 message" "$out"

# --- S2: a second write replaces; a tool-verb key beside it survives -----------
printf 'ghp_FAKE1234567890\n' | ( cmd_tool set github ) >/dev/null 2>&1
out=$(put sk_el_SECOND_7890 ELEVENLABS_API_KEY --connector=tools); rc=$?
[[ $rc -eq 0 && "$(grep -c '^export ELEVENLABS_API_KEY=' "$F")" == 1 && "$(seen ELEVENLABS_API_KEY)" == sk_el_SECOND_7890 ]] \
  && ok_t "S2 a second write replaces, never duplicates" || bad_t "S2 replace" "$(cat "$F")"
[[ "$out" == *updated* ]] && ok_t "S2 reports updated" || bad_t "S2 action" "$out"
[[ "$(seen GH_TOKEN)" == ghp_FAKE1234567890 ]] && ok_t "S2 the GitHub key saved by \`tool set\` survives" || bad_t "S2 github lost" "$(cat "$F")"

# --- S3: a value that could leave its quotes is refused, nothing written -------
before=$(cat "$F")
for bad in "x';touch\${IFS}$TMP/pwned;'" 'has space'; do
  out=$(put "$bad" FAL_KEY --connector=tools); rc=$?
  [[ $rc -ne 0 && "$(cat "$F")" == "$before" ]] && ok_t "S3 refused: $bad" || bad_t "S3 must refuse: $bad" "rc=$rc"
done
seen FAL_KEY >/dev/null
[[ ! -e "$TMP/pwned" ]] && ok_t "S3 nothing executed on the next bash" || bad_t "S3 injection ran"

# --- S4: --task still clears the gate ------------------------------------------
: > "$TMP/answer.log"
put fal_FAKE_KEY_0001 FAL_KEY --connector=tools --task=DIVE-9 >/dev/null
[[ "$(cat "$TMP/answer.log")" == "task answer DIVE-9 --human --from=drop" ]] \
  && ok_t "S4 --task clears the gate (task answer --human --from=drop)" || bad_t "S4 gate clear" "$(cat "$TMP/answer.log")"
[[ "$(seen FAL_KEY)" == fal_FAKE_KEY_0001 ]] && ok_t "S4 and the key is in the environment" || bad_t "S4 key" "$(cat "$F")"

# --- S5 (control): any other connector is unchanged, 600 KEY=value -------------
out=$(put sk-FAKE-openai-01 OPENAI_API_KEY --connector=openai); rc=$?
O="$FIVEDIVE_CONNECTOR_DIR/openai.env"
[[ $rc -eq 0 && "$(cat "$O" 2>/dev/null)" == "OPENAI_API_KEY=sk-FAKE-openai-01" && "$(stat -c %a "$O" 2>/dev/null)" == 600 ]] \
  && ok_t "S5 --connector=openai still writes a 600 KEY=value file" || bad_t "S5 plain connector" "rc=$rc $(ls -l "$O" 2>&1)"
grep -q OPENAI_API_KEY "$F" && bad_t "S5 a plain connector leaked into tools.sh" || ok_t "S5 a plain connector stays out of tools.sh"

# --- S6: the agent's ping names its environment, not a file it cannot read -----
grep -q '_ping_conn" == tools' src/task/answer.sh \
  && grep -q 'is set in your environment from your next command' src/task/answer.sh \
  && ok_t "S6 the gate-cleared ping for a tools key says \$KEY is in the environment" \
  || bad_t "S6 answer.sh ping" "no tools branch in the secret-gate ping"

# --- S7: only a credential name may go in tools.sh, and a refusal moves nothing -
# tools.sh is every agent's BASH_ENV: `export PATH='<key>'` there leaves every
# seat on the box unable to run a command, and `export HTTPS_PROXY='<key>'`
# fails every curl/git/gh call the same way (NODE_TLS_REJECT_UNAUTHORIZED,
# NPM_CONFIG_REGISTRY: silently). The rule is an allowlist (a _KEY/_TOKEN/
# _SECRET/_PASSWORD name or a catalog variable), minus the per-seat prefixes.
# Each refusal is graded on rc, reason AND an unchanged file (rc alone passes
# the wrong refusal). Same value as S1, so only the NAME decides.
before=$(cat "$F")
for name in PATH LD_PRELOAD IFS HOME BASH_ENV PS4 LC_ALL ANTHROPIC_API_KEY OPENAI_API_KEY TELEGRAM_BOT_TOKEN OPENROUTER_API_KEY \
            HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY NODE_TLS_REJECT_UNAUTHORIZED NODE_EXTRA_CA_CERTS SSL_CERT_FILE \
            CURL_CA_BUNDLE REQUESTS_CA_BUNDLE NPM_CONFIG_REGISTRY PIP_INDEX_URL JAVA_TOOL_OPTIONS FUNCNEST POSIXLY_CORRECT \
            GIT_ASKPASS_TOKEN NODE_AUTH_TOKEN NPM_CONFIG__AUTH_TOKEN; do
  out=$(put sk_el_FAKE_123456 "$name" --connector=tools); rc=$?
  [[ $rc -eq 3 && "$out" == *"$name is not allowed for --connector=tools"* && "$(cat "$F")" == "$before" ]] \
    && ok_t "S7 $name is refused for --connector=tools and tools.sh is unchanged" \
    || bad_t "S7 must refuse $name" "rc=$rc out=$out"
done
[[ "$(BASH_ENV="$F" /bin/bash -c 'command -v git >/dev/null && printf ran')" == ran ]] \
  && ok_t "S7 a fresh agent bash still finds its commands" || bad_t "S7 PATH broken" "$(cat "$F")"
# The same names are fine in a plain connector: it is a 600 file nothing sources.
out=$(put sk-FAKE-openai-02 OPENAI_API_KEY --connector=openai); rc=$?
[[ $rc -eq 0 ]] && ok_t "S7 a refused name still writes to a plain connector" || bad_t "S7 plain connector" "rc=$rc $out"
# Credential names are accepted, and land where a fresh agent bash sees them.
for name in ELEVENLABS_API_KEY GH_TOKEN STRIPE_API_KEY FAL_KEY CLOUDFLARE_API_TOKEN SENDGRID_API_KEY HF_API_SECRET SMTP_PASSWORD; do
  out=$(put "sk_FAKE_${name}_1" "$name" --connector=tools); rc=$?
  [[ $rc -eq 0 && "$(seen "$name")" == "sk_FAKE_${name}_1" ]] \
    && ok_t "S7 $name is accepted for --connector=tools" || bad_t "S7 must accept $name" "rc=$rc out=$out"
done
# Every variable the tools catalog fills (cmd_tool.sh TOOL_ENV) is accepted, so
# a new catalog entry whose name is not a credential suffix reds here until it
# is added to TOOLS_VAR_CATALOG_EXTRA.
for id in "${TOOL_IDS[@]}"; do
  for name in ${TOOL_ENV[$id]}; do
    _tools_var_reserved "$name" \
      && bad_t "S7 catalog variable $name ($id) must be accepted" "refused by _tools_var_reserved" \
      || ok_t "S7 catalog variable $name ($id) is accepted"
  done
done

# S8 (the gate cannot be FILED with a reserved name for tools) lives in
# tests/secret_gate_delivery_path_unit.sh N8/P8, which already pays for a task DB.

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
