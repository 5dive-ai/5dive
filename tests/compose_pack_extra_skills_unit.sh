#!/usr/bin/env bash
# DIVE-6900 — a team template's `skills:` on a PACK seat must be installed, and the
# retry the import prints for a skill that did not install must be a command that runs.
#
# THE DEFECT, measured by main 2026-10-25 on a fresh box importing content-studio:
#
#   dude:  pack: dude   skills: [5dive-cli, deep-research]
#   OK — applied ...: ... skills_failed=1
#   ── 1 skill(s) FAILED to install — those agents are up but DEGRADED:
#        sudo 5dive agent skill dude add --skill=deep-research
#   → usage: 5dive agent skill dude add --source=<owner/repo> --skill=<id>
#
# Two causes. (1) _compose_import_args forwards no `skills:` to `agent import`, so on a
# pack seat a template extra was never attempted — deep-research IS in 5dive-ai/skills,
# and installs by hand. (2) the hint dropped --source, which `agent skill add` requires.
#
# COVERAGE: cmd_compose_up creates real agents, so these arms EXTRACT the two new
# functions verbatim from src/cmd_compose.sh and run them with the box stubbed out
# (installed-set reader, gh_org, the `bash $self` re-entry). The hint arm runs the
# REAL cmd_skill_add parser against the rendered command; it stops at "agent home
# missing", the first check past argument validation, so nothing is installed.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e

TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

fn_of() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$2"; }
EXTRA_FN=$(fn_of _compose_pack_extra_skills "$SRC")
HINT_FN=$(fn_of _compose_skill_hint "$SRC")
PARSE_FN=$(fn_of parse_skill_spec "$ROOT/src/cmd_skill.sh")
VSRC_FN=$(fn_of valid_skill_source "$ROOT/src/cmd_skill.sh")
VID_FN=$(fn_of valid_skill_id "$ROOT/src/lib/validation.sh")
ADD_FN=$(fn_of cmd_skill_add "$ROOT/src/cmd_skill.sh")

for f in EXTRA_FN HINT_FN PARSE_FN VSRC_FN VID_FN ADD_FN; do
  [[ -n "${!f}" ]] || bad_t "T0 could not extract ${f%_FN} — the arms that use it are vacuous" ''
done
(( fail == 0 )) && ok_t 'T0 every function under test was extracted from source'

# `bash "$self" agent skill <n> add ...` is the install; $self is a stub that logs argv.
STUB="$TMP/self"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$TMP" >"$STUB"; chmod +x "$STUB"

# $1 = agent spec JSON  $2 = agent name  $3 = installed skills (csv)
run_extra() {
  : >"$TMP/calls"
  bash -uo pipefail -c '
    set +e
    gh_org() { printf 5dive-ai; }
    warn() { printf "warn: %s\n" "$*" >&2; }
    _skill_list_json() { tr "," "\n" <<<"$INSTALLED" | jq -R "select(length>0) | {name:.}" | jq -sc .; }
    '"$PARSE_FN"'
    '"$VSRC_FN"'
    '"$VID_FN"'
    '"$EXTRA_FN"'
    _compose_pack_extra_skills "$1" "$2" "$3"
  ' _ "$1" "$2" "$STUB" 2>/dev/null
  cat "$TMP/calls"
}

# --- T1 the measured case: dude gets deep-research, from 5dive-ai/skills -----
out=$(INSTALLED="5dive-cli,community-triage" run_extra '{"pack":"dude","skills":["5dive-cli","deep-research"]}' dude)
if [[ "$out" == "agent skill dude add --source=5dive-ai/skills --skill=deep-research" ]]; then
  ok_t 'T1 a pack seat installs its template extra (dude/deep-research from 5dive-ai/skills), and only the missing one'
else
  bad_t 'T1 the template extra on a pack seat was not installed exactly once from 5dive-ai/skills' "calls: $(tr '\n' '|' <<<"$out")"
fi

# --- T2 ANCHOR: everything already there → no install call -------------------
out=$(INSTALLED="5dive-cli,deep-research" run_extra '{"pack":"dude","skills":["5dive-cli","deep-research"]}' dude)
[[ -z "$out" ]] \
  && ok_t 'T2 ANCHOR a pack seat that already has every skill makes NO install call (T1 is differential)' \
  || bad_t 'T2 ANCHOR installs were attempted for skills already present' "calls: $(tr '\n' '|' <<<"$out")"

# --- T3 an owner/repo:id entry installs from THAT repo -----------------------
out=$(INSTALLED="" run_extra '{"pack":"x","skills":["acme/tools:lint"]}' x)
[[ "$out" == "agent skill x add --source=acme/tools --skill=lint" ]] \
  && ok_t 'T3 a qualified owner/repo:id entry installs from the repo it names' \
  || bad_t 'T3 a qualified entry was not installed from its own repo' "calls: $(tr '\n' '|' <<<"$out")"

# --- T4 no_skills is respected ------------------------------------------------
out=$(INSTALLED="" run_extra '{"pack":"x","no_skills":true,"skills":["deep-research"]}' x)
[[ -z "$out" ]] \
  && ok_t 'T4 no_skills: true installs nothing on top of the pack' \
  || bad_t 'T4 no_skills was ignored' "calls: $(tr '\n' '|' <<<"$out")"

# --- T5 an install that fails does not fail the import ----------------------
printf '#!/usr/bin/env bash\nexit 7\n' >"$TMP/self-red"; chmod +x "$TMP/self-red"
bash -uo pipefail -c '
  set -e
  gh_org() { printf 5dive-ai; }
  warn() { :; }
  _skill_list_json() { echo "[]"; }
  '"$PARSE_FN"'
  '"$VSRC_FN"'
  '"$VID_FN"'
  '"$EXTRA_FN"'
  _compose_pack_extra_skills "{\"skills\":[\"deep-research\"]}" dude "$1"
  echo SURVIVED
' _ "$TMP/self-red" 2>/dev/null | grep -qx SURVIVED \
  && ok_t 'T5 a failed install leaves the run going under set -e (best-effort, like agent create)' \
  || bad_t 'T5 a failed skill install aborts the import' ''

# --- T6 the pack branch calls it, after a successful import only ------------
grep -A1 'bash "$self" agent import "${args\[@\]}" || brought_up=0' "$SRC" \
  | grep -q '(( brought_up )) && _compose_pack_extra_skills "$agent_spec" "$name" "$self"' \
  && ok_t 'T6 the pack branch installs the extras right after a successful import' \
  || bad_t 'T6 _compose_pack_extra_skills is not called after agent import' "$(grep -n '_compose_pack_extra_skills' "$SRC")"

# --- T7 the printed hint is a command `agent skill add` ACCEPTS --------------
# Render the hint, strip the `sudo 5dive agent skill <n> add` prefix, feed the rest to
# the REAL cmd_skill_add. A usage refusal is the bug; reaching the agent-home check
# means every argument passed validation.
run_add() {
  bash -uo pipefail -c '
    E_USAGE=2; E_VALIDATION=3; E_GENERIC=1; E_NOT_FOUND=4
    fail() { printf "REFUSED[%s] %s\n" "$1" "${*:2}"; exit "$1"; }
    '"$VSRC_FN"'
    '"$VID_FN"'
    '"$ADD_FN"'
    cmd_skill_add "$@"
  ' _ "$@" 2>&1
}
hint=$(bash -c "$HINT_FN"'
_compose_skill_hint "$@"' _ zz-dive6900-nohome deep-research 5dive-ai/skills)
read -r -a hv <<<"$hint"
if [[ "${hv[*]:0:4}" == "sudo 5dive agent skill" && "${hv[5]}" == add ]]; then
  res=$(run_add "${hv[4]}" "${hv[@]:6}")
  if grep -q 'agent home missing' <<<"$res" && ! grep -q 'usage:' <<<"$res"; then
    ok_t "T7 the printed hint passes cmd_skill_add's own argument checks ($hint)"
  else
    bad_t 'T7 the printed hint is refused by cmd_skill_add' "hint: $hint | result: $res"
  fi
else
  bad_t 'T7 the hint is not a `sudo 5dive agent skill <n> add ...` command' "hint: $hint"
fi

# --- T8 MUTATION: the pre-fix hint is refused by the same parser -------------
# Without this, T7 would pass just as well against a parser that accepts anything.
res=$(run_add zz-dive6900-nohome --skill=deep-research)
grep -q 'REFUSED\[2\] usage:' <<<"$res" \
  && ok_t 'T8 MUTATION the pre-fix hint (no --source) is refused with usage — T7 is differential' \
  || bad_t 'T8 MUTATION the parser accepted the pre-fix hint — T7 proves nothing' "result: $res"

# --- T9 the degraded block prints through the hint, not a hand-built line -----
if grep -q 'add --skill=\${_n##\* }' "$SRC"; then
  bad_t 'T9 the old source-less hint is still printed' "$(grep -n 'add --skill=' "$SRC")"
elif grep -q '_compose_skill_hint "$_a" "$_s" "$_src"' "$SRC"; then
  ok_t 'T9 the degraded block renders every retry through _compose_skill_hint'
else
  bad_t 'T9 the degraded block does not use _compose_skill_hint' ''
fi

echo "-----"
echo "compose_pack_extra_skills_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
