#!/usr/bin/env bash
# DIVE-6543 — a team names its pushers, and nobody else can push.
#
# THE DEFECT: a team spec had no per-seat push key, so the deploy team's grader
# (vesper) came up with exactly the engineer's push rights — none on a standard
# box, all of them on an admin-tier box, where a seat's sudo reaches push. "The
# reviewer can't push" lived only in the role text.
#
# The parser arms run the real `_compose_parse` over real YAML; the argv arms run
# the real create/import argv builders; the grant arms run the real
# `render_standard_sudoers`, the policy those flags land in.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"
TMP="$(mktemp -d)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has_t()  { if [[ $'\n'"$2"$'\n' == *$'\n'"$3"$'\n'* ]]; then ok_t "$1"; else bad_t "$1" "missing line '$3' in: $2"; fi; }
hasnt_t(){ if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "unwanted '$3' in: $2"; fi; }

command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || {
  printf 'SKIP - python3 + PyYAML unavailable; the parser arms cannot run\n'; exit 0
}

awk '/^_compose_parse\(\)/{f=1} f{print} f&&/^PY$/{p=1} p&&/^}$/{exit}' "$SRC" > "$TMP/parse.sh"
{
  sed -n '/^_compose_resolve_path()/,/^}/p' "$SRC"
  sed -n '/^_compose_create_args()/,/^}/p'  "$SRC"
  sed -n '/^_compose_push_args()/,/^}/p'    "$SRC"
  sed -n '/^_compose_seat_isolation()/,/^}/p' "$SRC"   # DIVE-7236: the tier both builders forward
  sed -n '/^_compose_by_role()/,/^}/p'      "$SRC"
  sed -n '/^_compose_is_member()/,/^}/p'    "$SRC"
  sed -n '/^_compose_import_args()/,/^}/p'  "$SRC"
} > "$TMP/args.sh"
bash -n "$TMP/parse.sh" && bash -n "$TMP/args.sh" && grep -q '_compose_push_args()' "$TMP/args.sh" \
  && ok_t 'T0 the parser and the argv builders extract and parse' \
  || { bad_t 'T0 extraction failed — every arm below is vacuous' ''; exit 1; }

parse() { ( set -uo pipefail; . "$TMP/parse.sh"; _compose_parse "$1" ); }
imp()   { ( . "$TMP/args.sh"; _compose_import_args "$(jq -c --arg n "$2" '.agents[$n]' <<<"$1")" "$2" "$2" /tmp ); }
cre()   { ( . "$TMP/args.sh"; _compose_create_args "$(jq -c --arg n "$2" '.agents[$n]' <<<"$1")" "$2" /tmp ); }

# The deploy team's shape: four pack seats, the two pushers named.
cat >"$TMP/deploy.yaml" <<'Y'
version: "2"
defaults: { type: claude, channels: none, defer_auth: true }
agents:
  marcus: { pack: marcus, role: CTO }
  anton:  { pack: anton,  role: Ops,      reports_to: marcus, can_push: true }
  dario:  { pack: dario,  role: Engineer, reports_to: anton,  can_push: true }
  vesper: { pack: vesper, role: Verifier, reports_to: anton }
Y
SPEC=$(parse "$TMP/deploy.yaml" 2>"$TMP/err"); rc=$?
[[ $rc -eq 0 && -n "$SPEC" ]] && ok_t 'P1 the deploy team parses' || bad_t 'P1 parse' "rc=$rc $(cat "$TMP/err")"
hasnt_t 'P1 ...with no unknown-key warning for can_push' "$(cat "$TMP/err")" "unknown key 'can_push'"
[[ "$(jq -c '[.agents[] | .can_push]' <<<"$SPEC")" == '[false,true,true,false]' ]] \
  && ok_t 'P2 a seat that does not name itself a pusher is NOT one, once any seat is named' \
  || bad_t 'P2 unnamed seats default false' "$(jq -c '.agents | map_values(.can_push)' <<<"$SPEC")"

V=$(imp "$SPEC" vesper); D=$(imp "$SPEC" dario); M=$(imp "$SPEC" marcus)
has_t   'A1 vesper (the grader) is pinned standard — no box admin default, no manifest tier' "$V" "--isolation=standard"
hasnt_t 'A1 ...and gets no push grant'                                                   "$V" "--can-push"
has_t   'A2 dario (the engineer) gets the push grant'                                     "$D" "--can-push"
hasnt_t 'A2 ...and keeps the tier his pack and box give him'                              "$D" "--isolation="
has_t   'A3 marcus (CTO, not named) is pinned standard too'                               "$M" "--isolation=standard"

# The grant those flags land in: the real sudoers renderer.
sed -n '/^render_standard_sudoers()/,/^}/p' "$ROOT/src/cmd_agent_create.sh" > "$TMP/sud.sh"
SV=$( . "$TMP/sud.sh"; render_standard_sudoers agent-vesper 0 )
SD=$( . "$TMP/sud.sh"; render_standard_sudoers agent-dario 1 )
hasnt_t 'G1 a standard seat without --can-push holds no _push_do grant' "$SV" "_push_do"
[[ "$SD" == *"_push_do"* ]] && ok_t 'G2 ...and with it, holds one' || bad_t 'G2 push grant rendered' "$SD"

# NEGATIVE CONTROL — drop the key everywhere: today's argv, byte for byte, so
# vesper's tier is again whatever the box gives (admin on an admin-tier box).
sed -E 's/, +can_push: true//' "$TMP/deploy.yaml" >"$TMP/nokey.yaml"
NK=$(parse "$TMP/nokey.yaml" 2>/dev/null)
[[ "$(jq -c '[.agents[] | has("can_push")]' <<<"$NK")" == '[false,false,false,false]' ]] \
  && ok_t 'N1 a team that names no pusher gets no can_push field (unchanged)' \
  || bad_t 'N1 no key, no field' "$(jq -c '.agents' <<<"$NK")"
NV=$(imp "$NK" vesper)
hasnt_t 'N2 ...and vesper is no longer pinned — the hole this row closes' "$NV" "--isolation="
hasnt_t 'N2 ...nor granted'                                               "$NV" "--can-push"

# A spec tier wins over the pin, but an admin non-pusher is refused.
cat >"$TMP/sbx.yaml" <<'Y'
version: "2"
agents:
  dario:  { type: claude, can_push: true }
  vesper: { type: claude, isolation: sandboxed }
Y
S2=$(parse "$TMP/sbx.yaml" 2>/dev/null)
has_t 'S1 a non-pusher the spec makes sandboxed stays sandboxed (pack path)' "$(imp "$S2" vesper)" "--isolation=sandboxed"
C=$(cre "$S2" vesper)
has_t 'S2 ...and on the bare create path'                            "$C" "--isolation=sandboxed"
[[ $(grep -c -- '--isolation=' <<<"$C") == 1 ]] && ok_t 'S2 ...exactly one --isolation' || bad_t 'S2 one isolation flag' "$C"
has_t 'S3 a bare-create non-pusher with no tier is pinned standard' "$(cre "$(parse "$TMP/deploy.yaml" | jq -c '.agents.vesper |= del(.pack)')" vesper)" "--isolation=standard"

printf 'version: "2"\nagents:\n  dario: { type: claude, can_push: true }\n  vesper: { type: claude, isolation: admin }\n' >"$TMP/adm.yaml"
E=$(parse "$TMP/adm.yaml" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && "$E" == *"admin seat can push through its sudo"* ]] \
  && ok_t 'E1 an admin seat declared a non-pusher is refused, not silently a pusher' \
  || bad_t 'E1 admin non-pusher refused' "rc=$rc $E"
printf 'version: "2"\nagents:\n  dario: { type: claude, can_push: "yes" }\n' >"$TMP/str.yaml"
E=$(parse "$TMP/str.yaml" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && "$E" == *"must be true or false"* ]] \
  && ok_t 'E2 a non-boolean can_push is refused' || bad_t 'E2 non-bool refused' "rc=$rc $E"

# `agent import` forwards --can-push into create (DIVE-4416's passthrough).
grep -q -- '--can-push' <<<"$(grep '^_IMPORT_CREATE_PASSTHRU_BOOL_FLAGS=' "$ROOT/src/cmd_pack.sh")" \
  && ok_t 'I1 agent import forwards --can-push to create' || bad_t 'I1 import passthrough' ''

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
