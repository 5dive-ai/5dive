#!/usr/bin/env bash
# DIVE-4093 — the bundled Distribution team is a roster AND a scheduled loop.
set +e -o pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TPL="$ROOT/team-templates/distribution.5dive.yaml"
# Keep the verdict counter in statement position on its own line: the empirical
# harness-verdict probe identifies and mutates this variable to prove failures
# reach the process exit status. A second assignment on the PASS line is valid
# shell but invisible to that instrument.
PASS=0
FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null \
  || { echo 'SKIP - python3 + PyYAML unavailable'; exit 0; }
command -v jq >/dev/null || { echo 'SKIP - jq unavailable'; exit 0; }
command -v column >/dev/null || { echo 'SKIP - column unavailable'; exit 0; }

# Source the real compose implementation; it is function definitions only.
# Shared CLI helpers are replaced below only at their external seams.
. "$ROOT/src/cmd_compose.sh"
unset TEAM_TG_TOKEN
SPEC=$(_compose_parse "$TPL" 2>"$TMP/parse.err"); parse_rc=$?
if (( parse_rc == 0 )) && jq -e '.team.slug == "distribution"' <<<"$SPEC" >/dev/null; then
  ok_t 'the bundled distribution template parses through the real schema'
else
  bad_t 'the distribution template does not parse' "$(<"$TMP/parse.err")"
fi

[[ "$(jq -r '.agents | length' <<<"$SPEC")" == 7 ]] \
  && ok_t 'the marketplace product has exactly seven roles' \
  || bad_t 'the roster is not seven roles' "$(jq -c '.agents|keys' <<<"$SPEC")"

roles=$(jq -r '[.agents[].role] | sort | join("|")' <<<"$SPEC")
want='Brand Verifier|Content Packager|Distribution Analyst|Head of Distribution|Opportunity Scout|Outreach|Publisher'
[[ "$roles" == "$want" ]] \
  && ok_t 'all seven named Distribution roles are present' \
  || bad_t 'the named roster drifted' "$roles"

jq -e '.agents.head.loops | length == 1 and
       .[0].id == "distribution-cycle" and
       .[0].title == "Run the approved-source distribution cycle" and
       .[0].cron == "0 9 * * 1-5" and
       .[0].ceiling == 180000 and
       (.[0].prompt | length > 0)' <<<"$SPEC" >/dev/null \
  && ok_t 'the imported roster carries one recurring core loop owned by the Head' \
  || bad_t 'the core loop is absent or has no cadence' "$(jq -c '.agents.head.loops' <<<"$SPEC")"

if jq -e '
  .team.capabilities.browser == "optional" and
  .distribution.engage_first.enabled == false and
  .distribution.retention.unpublished_ttl_days == 7 and
  .distribution.retention.retrieval == "published-only" and
  .distribution.channels.x.cost_per_post_usd == 0.20 and
  .distribution.channels.x.permission == "AUTO" and
  .distribution.channels.linkedin.permission == "APPROVAL" and
  .distribution.channels.reddit.permission == "HUMAN"
' <<<"$SPEC" >/dev/null; then
  ok_t 'browser fallback, cost/tier fields,comment lane default and retention are manifest data'
else
  bad_t 'one of the marketplace policy fields is missing' "$(jq -c '.team.capabilities,.distribution' <<<"$SPEC")"
fi

prompt=$(jq -r '.agents.head.loops[0].prompt' <<<"$SPEC")
missing_prompt=0
for phrase in '<<src:ID>>' 'publish nonce' '1/1 adapter success' 'zero unresolved verifier violations' 'seven days'; do
  if ! grep -Fq "$phrase" <<<"$prompt"; then
    bad_t 'the executable loop prompt lost a release rule' "$phrase"
    missing_prompt=$((missing_prompt+1))
  fi
done
(( missing_prompt == 0 )) && ok_t 'the loop prompt carries attribution, verification, reliability and TTL controls'

jq -e '([.companies[] | select(.slug=="distribution")] | length) == 1 and
       (.companies[] | select(.slug=="distribution") | .size==7 and .loop.id=="distribution-cycle")' \
  "$ROOT/team-templates/index.json" >/dev/null \
  && ok_t 'the marketplace registry advertises the roster and loop' \
  || bad_t 'index.json does not advertise the working team' ''
grep -Eq 'for _tpl in .*distribution\.5dive\.yaml' "$ROOT/install.sh" \
  && ok_t 'the installer stages the template onto fresh boxes' \
  || bad_t 'the template exists in source but is absent from the installer manifest' ''

cat >"$TMP/untrusted-capability.yaml" <<'YAML'
version: "2"
team:
  capabilities:
    browser: "sh -c whoami"
agents:
  lead: { role: Lead }
YAML
if _compose_parse "$TMP/untrusted-capability.yaml" >/dev/null 2>&1; then
  bad_t 'a marketplace manifest can inject a capability probe command' ''
else
  ok_t 'the parser refuses manifest-supplied browser commands'
fi

# Exercise the user-facing status path twice. A marketplace manifest may only
# declare browser: optional; the CLI owns the fixed probe and never runs a
# command supplied by YAML.
cat >"$TMP/self.sh" <<'STUB'
#!/usr/bin/env bash
[[ "${HAS_BROWSER:-0}" == 1 && "${1:-}" == browser && "${2:-}" == --help ]]
STUB
chmod +x "$TMP/self.sh"
JSON_MODE=0
_compose_self() { printf '%s' "$TMP/self.sh"; }
_team_templates_dir() { printf '%s' "$ROOT/team-templates"; }
ensure_state_ro() { :; }
tasks_db_init() { :; }
sqlq() { printf "'%s'" "$1"; }
db() {
  if [[ "$1" == *"assignee='head'"* ]]; then
    printf '[{"title":"Run the approved-source distribution cycle","schedule":"0 9 * * 1-5"}]\n'
  else
    printf '[]\n'
  fi
}
registry_read() {
  jq -nc '{agents:{head:{},scout:{},packager:{},outreach:{},publisher:{},verifier:{},analyst:{}}}'
}
systemctl() { [[ "${1:-}" == is-active ]] && printf 'active\n'; }
fail() { printf 'FAIL-CMD %s\n' "$*" >&2; return 3; }

export HAS_BROWSER=0
out=$(cmd_team ps distribution 2>&1); rc=$?
if (( rc == 0 )) && grep -q '^PUBLISHING  api-only$' <<<"$out" \
   && grep -q 'head.*0 9 \* \* 1-5.*Run the approved-source distribution cycle' <<<"$out"; then
  ok_t 'team ps shows the seven-seat roster, scheduled loop and api-only fallback'
else
  bad_t 'team ps does not expose the imported product state' "rc=$rc out=$out"
fi

out_auto=$(cmd_team ps 2>&1); rc_auto=$?
if (( rc_auto == 0 )) && grep -q '^PUBLISHING  api-only$' <<<"$out_auto" \
   && grep -q 'head.*0 9 \* \* 1-5.*Run the approved-source distribution cycle' <<<"$out_auto"; then
  ok_t 'slug-free team ps detects the imported team and serves as its receipt'
else
  bad_t 'the exact post-import team ps command cannot find the installed roster' "rc=$rc_auto out=$out_auto"
fi

export HAS_BROWSER=1
out2=$(cmd_team ps distribution 2>&1); rc2=$?
if (( rc2 == 0 )) && grep -q '^PUBLISHING  browser+api$' <<<"$out2"; then
  ok_t 'the same fixed preflight reports browser+api when the capability exists'
else
  bad_t 'browser capability did not change the reported mode' "rc=$rc2 out=$out2"
fi

echo "distribution_team_template_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
