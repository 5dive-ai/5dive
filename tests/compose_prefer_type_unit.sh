#!/usr/bin/env bash
# DIVE-7080 — `prefer_type:` on a seat: the harness it runs on WHEN the box can
# sign it in there.
#
# The Dropshipping Team's Pixel makes real product pictures only on Codex. With
# no per-seat harness in the template (a pack seat's `type:` is never forwarded,
# by design), she came up on Claude on every box and drew icons in code. These
# arms pin the spec transform and the import argv:
#
#   1. A box with an account signed in to the preferred harness moves the seat
#      there, on that account, and drops the Claude-only pins.
#   2. A box with none leaves the seat as it was and marks it for the summary's
#      one-line step. That is the negative control: no sign-in, no change.
#   3. A seat whose account was chosen (template or --auth-profile) keeps it.
#
# COVERAGE LIMIT: no agent is provisioned (that needs real unix users), and the
# account probe is stubbed. What is claimed is the spec and the `agent import`
# argv each case produces.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
source src/cmd_compose.sh
set +e

TMP="$(mktemp -d)"
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

# The account probe, stubbed: each account dir holds a `serves` file (claude,
# codex or both), standing in for the per-type sign-ins switch reads.
export AUTH_PROFILES_DIR="$TMP/profiles"
switch_account_harness() { cat "${AUTH_PROFILES_DIR}/${1}/serves" 2>/dev/null; }
account() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf '%s\n' "$2" > "$AUTH_PROFILES_DIR/$1/serves"; }
reset_accounts() { rm -rf "$AUTH_PROFILES_DIR"; mkdir -p "$AUTH_PROFILES_DIR"; }

cat > "$TMP/team.yaml" <<'YAML'
version: "2"
defaults:
  type: claude
agents:
  clip:  {pack: clip, role: "Shop manager", model: opus}
  pixel:
    pack: pixel
    role: "Designer"
    reports_to: [clip]
    model: sonnet
    effort: high
    prefer_type: codex
    prefer_why: "real product pictures"
YAML
BASE="$(_compose_parse "$TMP/team.yaml" 2>"$TMP/parse.err")" || bad_t 'T0 _compose_parse failed' "$(cat "$TMP/parse.err")"
eq_t 'T0 prefer_type and prefer_why are known keys (no unknown-key warning)' '' \
     "$(grep -c 'unknown key' "$TMP/parse.err" | grep -v '^0$')"
eq_t 'T0b the parsed seat keeps prefer_type' 'codex' "$(jq -r '.agents.pixel.prefer_type' <<<"$BASE")"

pixel_import() { _compose_import_args "$(jq -c '.agents.pixel' <<<"$1")" pixel pixel "$TMP" "" | paste -sd' '; }
clip_import()  { _compose_import_args "$(jq -c '.agents.clip'  <<<"$1")" clip  clip  "$TMP" "" | paste -sd' '; }

# --- T1 a ChatGPT sign-in on the box: Pixel moves there ---------------------
reset_accounts; account main claude; account chatgpt codex
S1="$(_compose_apply_prefer_type "$BASE")"
eq_t 'T1 pixel becomes codex on the account signed in to it' \
     'codex chatgpt true' "$(jq -r '.agents.pixel | "\(.type) \(.auth_profile) \(.prefer_applied)"' <<<"$S1")"
eq_t 'T1b the Claude-only model and effort pins are dropped on codex' \
     'null null' "$(jq -r '.agents.pixel | "\(.model) \(.effort)"' <<<"$S1")"
eq_t 'T1c a seat with no prefer_type is untouched' \
     "$(jq -c '.agents.clip' <<<"$BASE")" "$(jq -c '.agents.clip' <<<"$S1")"
eq_t 'T1d the pack import is told the harness and the account' \
     'pixel --as=pixel --type=codex --auth-profile=chatgpt' "$(pixel_import "$S1" | sed 's/ --isolation=.*//')"
case "$(clip_import "$S1")" in
  *--type=*) bad_t 'T1e a seat without prefer_type still never forwards its inherited type' "$(clip_import "$S1")" ;;
  *)         ok_t  'T1e a seat without prefer_type still never forwards its inherited type' ;;
esac

# --- T2 NEGATIVE CONTROL: no ChatGPT sign-in, no change ---------------------
reset_accounts; account main claude
S2="$(_compose_apply_prefer_type "$BASE")"
eq_t 'T2 with no account signed in to codex pixel stays on claude, marked for the summary' \
     'claude null true' "$(jq -r '.agents.pixel | "\(.type) \(.prefer_applied) \(.prefer_missed)"' <<<"$S2")"
eq_t 'T2b ...and keeps its pins' 'sonnet high' "$(jq -r '.agents.pixel | "\(.model) \(.effort)"' <<<"$S2")"
case "$(pixel_import "$S2")" in
  *--type=*) bad_t 'T2c ...and the import is not given a --type' "$(pixel_import "$S2")" ;;
  *)         ok_t  'T2c ...and the import is not given a --type' ;;
esac
reset_accounts
eq_t 'T2d a box with no accounts at all is the same' \
     'claude true' "$(_compose_apply_prefer_type "$BASE" | jq -r '.agents.pixel | "\(.type) \(.prefer_missed)"')"

# --- T3 the owner's chosen account is kept ----------------------------------
reset_accounts; account mp claude; account chatgpt codex
PINNED="$(jq '.agents.pixel.auth_profile = "mp"' <<<"$BASE")"
eq_t 'T3 a seat on a Claude-only account it was given stays there' \
     'claude mp true' "$(_compose_apply_prefer_type "$PINNED" | jq -r '.agents.pixel | "\(.type) \(.auth_profile) \(.prefer_missed)"')"
account mp both
eq_t 'T3b ...and moves when that same account is also signed in to codex' \
     'codex mp' "$(_compose_apply_prefer_type "$PINNED" | jq -r '.agents.pixel | "\(.type) \(.auth_profile)"')"

# --- T4 a seat already on its preferred harness is not touched --------------
reset_accounts
ON="$(jq '.agents.pixel.type = "codex"' <<<"$BASE")"
eq_t 'T4 a seat already on codex gets neither mark' \
     'null null' "$(_compose_apply_prefer_type "$ON" | jq -r '.agents.pixel | "\(.prefer_applied) \(.prefer_missed)"')"

# --- T5 the one line the summary prints ------------------------------------
eq_t 'T5 the step signs in to ChatGPT and moves the seat, in one line' \
     'sudo 5dive account login chatgpt --type=codex && sudo 5dive agent switch pixel --to=codex --account=chatgpt' \
     "$(_compose_prefer_hint pixel codex)"

# --- T6 the parser refuses what it cannot act on ----------------------------
printf 'version: "2"\nagents:\n  a: {type: claude, prefer_type: grok}\n' > "$TMP/bad1.yaml"
_compose_parse "$TMP/bad1.yaml" >/dev/null 2>"$TMP/bad1.err"
eq_t 'T6 prefer_type outside claude|codex is refused' '1' "$(grep -c 'prefer_type must be claude or codex' "$TMP/bad1.err")"
printf 'version: "2"\nagents:\n  a: {type: claude, prefer_why: "x"}\n' > "$TMP/bad2.yaml"
_compose_parse "$TMP/bad2.yaml" >/dev/null 2>"$TMP/bad2.err"
eq_t 'T6b prefer_why without prefer_type is refused' '1' "$(grep -c 'prefer_why is a line of text' "$TMP/bad2.err")"

# --- T7 the SEAM: `up` applies it, and the summary says it ------------------
# T1-T6 drive the transform and the argv. A mutation that never calls the
# transform from cmd_compose_up survives all of them, so drive the real command
# with the child `5dive` swapped for a recorder (same rig as
# team_import_type_override_unit.sh T10).
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
_compose_self() { printf '%s' "$TMP/fake5dive"; }
ensure_state()  { :; }
registry_read() { printf '%s' '{"agents":{}}'; }

reset_accounts; account chatgpt codex
export REC="$TMP/rec-moved.log"; : > "$REC"
OUT="$(cmd_compose_up -f "$TMP/team.yaml" 2>&1)"
eq_t 'T7 with a ChatGPT sign-in, up imports pixel onto codex on that account' \
     '1' "$(grep -c '^agent import pixel --as=pixel --type=codex --auth-profile=chatgpt' "$REC")"
eq_t 'T7b ...and the summary says where pixel runs' \
     '1' "$(grep -c "── pixel runs on ChatGPT (Codex) (account 'chatgpt'), as this team asks." <<<"$OUT")"

reset_accounts; account main claude
export REC="$TMP/rec-missed.log"; : > "$REC"
OUT="$(cmd_compose_up -f "$TMP/team.yaml" 2>&1)"
eq_t 'T7c NEGATIVE CONTROL: no ChatGPT sign-in, pixel is imported as the pack packs it' \
     '0' "$(grep '^agent import pixel' "$REC" | grep -c -- '--type=')"
eq_t 'T7d ...and the summary names what is missing and the one line that fixes it' \
     '1 1' "$(grep -c '── pixel needs ChatGPT (Codex) for real product pictures, and this box is not signed in to it' <<<"$OUT") $(grep -cxF "     $(_compose_prefer_hint pixel codex)" <<<"$OUT")"

reset_accounts; account chatgpt codex
export REC="$TMP/rec-override.log"; : > "$REC"
OUT="$(cmd_compose_up -f "$TMP/team.yaml" --type=claude 2>&1)"
eq_t 'T7e a roster --type= wins: every seat claude, no prefer line' \
     '2 0' "$(grep -c -- '--type=claude' "$REC") $(grep -c 'pixel runs on\|pixel needs' <<<"$OUT")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
