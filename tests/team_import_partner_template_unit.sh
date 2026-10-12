#!/usr/bin/env bash
# DIVE-6088 — a partner's team, from the partner's own private registry.
#
# THE GAP. `team import` read the template and every member pack from ONE place,
# the public marketplace. A partner's packs live in a PRIVATE registry that only
# 5dive-api can read, so a partner's team could not list its own characters.
# 5dive-api now reads the template from that registry and hands it to the box
# (`team import <slug> --template=-`), each partner seat carrying `pack_url:`,
# a signed link to its pack (the same link a single partner hire imports from).
#
# WHAT IS PINNED, through the real resolver and the real `up` (only the network
# and the per-agent CLI calls are replaced):
#   T1  a two-member template imports both seats BY LINK (agent import
#       --from-url), never by slug, so the public registry is never consulted;
#   T2  the saved manifest keeps the org chart and loses every link, comments kept;
#   T3  the links never reach the output;
#   N1  one member whose link is refused (a signature that does not verify: the
#       API answers 403) refuses the WHOLE team: no agent, no manifest, no row;
#   N2  a link that answers with something that is not a pack is refused the same;
#   N3  a bare `up -f` with a refused link refuses the same way;
#   N4  the parser's rules for the key; N5 the flag's rules;
#   C1  without pack_url the import argv is the slug, byte for byte as before.
#
# COVERAGE LIMIT: agents are not provisioned (that needs real unix users) and
# `agent import --from-url` itself is not run — it has its own harness. What is
# graded here is which argv the roster is brought up with, and that nothing is.
#
# Run: bash tests/team_import_partner_template_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_partner_template_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-import-partner.XXXXXX)"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR" "$TMP/tmpd"
tasks_db_init
export TMPDIR="$TMP/tmpd"

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

export TEAM_AUTH_PROFILE=fixture

# ---- the network: a fake API. sig=good answers a pack, sig=bad a 403, --------
# sig=notpack a tarball with no manifest.json. Every fetched URL is recorded.
mkdir -p "$TMP/pack" "$TMP/notpack"
printf '{"packFormat":1}\n' >"$TMP/pack/manifest.json"
printf 'hello\n' >"$TMP/notpack/README.md"
tar -czf "$TMP/pack.tgz" -C "$TMP/pack" .
tar -czf "$TMP/notpack.tgz" -C "$TMP/notpack" .
export FETCHED="$TMP/fetched.log"; : >"$FETCHED"
curl() {
  local out="" url="" a
  while (( $# )); do
    case "$1" in
      -o) out="$2"; shift ;;
      https://*) url="$1" ;;
    esac
    shift
  done
  printf '%s\n' "$url" >>"$FETCHED"
  case "$url" in
    *sig=good*)    cp "$TMP/pack.tgz" "$out" ;;
    *sig=notpack*) cp "$TMP/notpack.tgz" "$out" ;;
    *)             return 22 ;;   # curl -f on a 403
  esac
}
# The public registry must never be asked: a partner template is handed in.
_teams_get() { printf '%s\n' "REGISTRY $1" >>"$FETCHED"; return 1; }

# ---- provisioning seams, as in the sibling team harnesses -------------------
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
export REC="$TMP/rec.log"; : > "$REC"
_compose_self()   { printf '%s' "$TMP/fake5dive"; }
ensure_state()    { :; }
ensure_state_ro() { :; }
registry_read()   { printf '%s' '{"agents":{}}'; }
PERSONA="$TMP/persona"; mkdir -p "$PERSONA"
persona_append_block() { printf '%s' "$3" >> "$PERSONA/$1.md"; }

API="https://api.example.test/partner/packs/acme"
template() {  # <member's sig>
  cat <<YAML
# Partner test team (DIVE-6088 fixture)
version: "2"
team:
  name: "Partner test team"
  slug: partner-test
defaults:
  type: claude
  channels: none
  auth_profile: "\${TEAM_AUTH_PROFILE}"
agents:
  lead:
    role: "Lead"
    pack: lead
    pack_url: ${API}/lead.tar.gz?e=9999999999&sig=good
  member:
    role: "Analyst"
    reports_to: lead   # the org chart edge
    pack: member
    pack_url: ${API}/member.tar.gz?e=9999999999&sig=$1
YAML
}
template good >"$TMP/good.yaml"
template bad >"$TMP/bad.yaml"
template notpack >"$TMP/notpack.yaml"
WANT="$STATE_DIR/teams/partner-test.5dive.yaml"
project_row() { db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key='partner-test';" 2>/dev/null; }

# ============ 0. PRECONDITIONS ================================================
spec=$(_compose_parse "$TMP/good.yaml" 2>"$TMP/parse.err"); rc=$?
if (( rc == 0 )) && [[ "$(jq -r '.agents.member.pack_url' <<<"$spec")" == *sig=good ]] && ! grep -q 'unknown key' "$TMP/parse.err"; then
  ok_t 'T0 the parser keeps pack_url per seat, with no unknown-key warning'
else
  bad_t 'T0 pack_url did not parse as a known key' "rc=$rc $(cat "$TMP/parse.err")"
fi

# ============ N1. a refused signature refuses the WHOLE team ==================
: >"$REC"; : >"$FETCHED"
( cmd_team import partner-test --template="$TMP/bad.yaml" ) >"$TMP/n1.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q "'member' seat's pack was refused by api.example.test" "$TMP/n1.out" \
   && grep -q 'no agent was created' "$TMP/n1.out"; then
  ok_t 'N1 a member link that does not verify fails the import, naming the seat and the host'
else
  bad_t 'N1 the refused link did not fail the import as expected' "rc=$rc $(tail -3 "$TMP/n1.out")"
fi
eq_t 'N1b no agent was created or imported (not even the lead, fetched first and fine)' '' "$(cat "$REC")"
if [[ ! -e "$WANT" ]]; then ok_t 'N1c no manifest was saved'; else bad_t 'N1c a manifest was saved for a refused team' "$(ls "$STATE_DIR/teams")"; fi
eq_t 'N1d no project row was written' '' "$(project_row)"
if ! grep -q 'sig=' "$TMP/n1.out"; then ok_t 'N1e the refusal never prints the link'; else bad_t 'N1e the link leaked into the output' "$(grep 'sig=' "$TMP/n1.out")"; fi

# ============ N2. a link that is not a pack ===================================
: >"$REC"
( cmd_team import partner-test --template="$TMP/notpack.yaml" ) >"$TMP/n2.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q "is not a character pack" "$TMP/n2.out" && [[ ! -s "$REC" ]]; then
  ok_t 'N2 a link that answers with no manifest.json is refused, and nothing is created'
else
  bad_t 'N2 a non-pack link was not refused cleanly' "rc=$rc rec=$(cat "$REC") $(tail -2 "$TMP/n2.out")"
fi

# ============ N3. a bare `up -f` checks the links too =========================
: >"$REC"
( cmd_compose_up -f "$TMP/bad.yaml" ) >"$TMP/n3.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'no agent was created' "$TMP/n3.out" && [[ ! -s "$REC" ]]; then
  ok_t 'N3 up -f with a refused link creates nothing'
else
  bad_t 'N3 up -f did not refuse the refused link' "rc=$rc rec=$(cat "$REC")"
fi

# ============ T1. the good team, from a file ==================================
: >"$REC"; : >"$FETCHED"
( cmd_team import partner-test --template="$TMP/good.yaml" ) >"$TMP/t1.out" 2>&1; rc=$?
eq_t 'T1 the import succeeds' '0' "$rc"
imports=$(grep '^agent import ' "$REC")
if grep -q "^agent import --from-url=${API}/lead.tar.gz?e=9999999999&sig=good --as=lead" <<<"$imports" \
   && grep -q "^agent import --from-url=${API}/member.tar.gz?e=9999999999&sig=good --as=member" <<<"$imports"; then
  ok_t 'T1b both seats are imported BY LINK'
else
  bad_t 'T1b the seats were not imported from their links' "$imports"
fi
eq_t 'T1c and never by slug (the public registry resolves a bare slug)' '' "$(grep -E '^agent import (lead|member)( |$)' "$REC")"
eq_t 'T1d the public team registry was never asked' '' "$(grep '^REGISTRY' "$FETCHED")"
eq_t 'T1e each link fetched once by the preflight (the import re-fetches it on the box)' '2' "$(grep -c 'sig=good' "$FETCHED")"
eq_t 'T1f the team is recorded, led by its root' 'lead' "$(project_row)"
if grep -q 'org set member.*lead\|org.*member.*--reports-to=lead\|reports.*member.*lead' "$REC"; then
  ok_t 'T1g the org chart edge member -> lead is wired'
else
  bad_t 'T1g no org wiring for member -> lead was issued' "$(grep -i org "$REC" | head -3)"
fi

# ============ T2. the saved manifest: org chart yes, links no =================
if [[ -f "$WANT" ]] && ! grep -q 'pack_url\|sig=' "$WANT"; then
  ok_t 'T2 the manifest is saved without a single link'
else
  bad_t 'T2 the manifest is missing or still carries a link' "$(grep -n 'pack_url\|sig=' "$WANT" 2>&1 | head -3)"
fi
if grep -q '^# Partner test team' "$WANT" && grep -q 'reports_to: lead   # the org chart edge' "$WANT"; then
  ok_t 'T2b comments and the org chart survive the strip'
else
  bad_t 'T2b the strip lost comments or the org chart' "$(head -5 "$WANT")"
fi
eq_t 'T2c the stripped manifest still parses to the same two seats' 'lead member' \
     "$(_compose_parse "$WANT" 2>/dev/null | jq -r '.agents | keys | join(" ")')"
eq_t 'T2d no staged copy of the template (with its links) is left in TMPDIR' '' \
     "$(grep -rl 'sig=good' "$TMP/tmpd" 2>/dev/null)"

# ============ T3. links never reach the output ================================
if ! grep -q 'sig=' "$TMP/t1.out"; then ok_t 'T3 the import output never prints a link'; else bad_t 'T3 a link leaked into the output' "$(grep 'sig=' "$TMP/t1.out" | head -2)"; fi

# ============ T4. stdin, the form 5dive-api uses ==============================
rm -rf "$STATE_DIR/teams"; db "DELETE FROM projects WHERE key='partner-test';" >/dev/null 2>&1
: >"$REC"
( cmd_team import partner-test --template=- <"$TMP/good.yaml" ) >"$TMP/t4.out" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(grep -c '^agent import --from-url=' "$REC")" == 2 ]] && [[ -f "$WANT" ]]; then
  ok_t 'T4 --template=- reads the template from stdin and brings up the same team'
else
  bad_t 'T4 the stdin form did not import the team' "rc=$rc $(tail -3 "$TMP/t4.out")"
fi

# ============ N4. the key's rules =============================================
bad_spec() {  # <label> <yaml> <expected stderr fragment>
  printf '%s\n' "$2" >"$TMP/n4.yaml"
  if ! _compose_parse "$TMP/n4.yaml" >/dev/null 2>"$TMP/n4.err" && grep -q "$3" "$TMP/n4.err"; then
    ok_t "$1"
  else
    bad_t "$1" "$(cat "$TMP/n4.err")"
  fi
}
bad_spec 'N4a pack_url without pack: is refused' \
  $'agents:\n  a:\n    type: claude\n    pack_url: https://x.test/a.tar.gz' 'pack_url needs pack:'
bad_spec 'N4b a plain-http pack_url is refused' \
  $'agents:\n  a:\n    type: claude\n    pack: a\n    pack_url: http://x.test/a.tar.gz' 'must be an https link'
bad_spec 'N4c pack_url as a default (every seat one pack) is refused' \
  $'defaults:\n  pack_url: https://x.test/a.tar.gz\nagents:\n  a:\n    type: claude\n    pack: a' 'cannot be a default'

# ============ N5. the flag's rules ============================================
( cmd_team import ./x.yaml --template="$TMP/good.yaml" ) >"$TMP/n5.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q "must be the team's slug" "$TMP/n5.out"; then
  ok_t 'N5a with --template, the ref must be a slug'
else
  bad_t 'N5a a path ref was accepted with --template' "rc=$rc $(tail -2 "$TMP/n5.out")"
fi
( cmd_team import partner-test --template=- --telegram-token=- </dev/null ) >"$TMP/n5b.out" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'both read stdin' "$TMP/n5b.out"; then
  ok_t 'N5b --template=- with --telegram-token=- is refused (one stdin)'
else
  bad_t 'N5b two stdin readers were accepted' "rc=$rc $(tail -2 "$TMP/n5b.out")"
fi

# ============ C1. without pack_url, nothing changes ===========================
eq_t 'C1 a slug-only seat still imports by its slug, argv unchanged' \
     $'olivia\n--as=olivia\n--auth-profile=work' \
     "$(_compose_import_args '{"pack":"olivia","auth_profile":"work"}' olivia olivia "$TMP" '')"

SUMMARY_PRINTED=1
printf '\n%s\n' "team_import_partner_template_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
