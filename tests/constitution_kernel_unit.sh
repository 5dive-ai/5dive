#!/usr/bin/env bash
# DIVE-4869 phase 1: the constitution kernel is CORE, not council.
#
# `task need`'s tier-2 floor and its lead-clear authority read the constitution and trust it only
# when it matches the digest sealed in the council lineage. Before this change every one of those
# reads went through `_council_*` functions defined in the council engine, behind `declare -F`
# guards that FAIL CLOSED — so taking council out of the bundle would silently have dropped every
# box to the shipped floor and denied every sealed lead. This harness grades the property the
# extraction depends on: with src/cmd_council.sh NOT sourced at all, the gate floor and the
# lead-clear allowlist behave exactly as they do with it.
#
#   K1  the kernel's embedded modules match their canonical sources; the generator is reproducible
#   K2  control: the council engine really is absent in the K3 shell (no vacuous green)
#   K3  gate floor + seal + drift + lead allowlist, council ABSENT
#   K4  negative control: without the kernel the same shell fails closed (K3's green is the kernel)
#   K5  parity with the council's own copies while both exist (and a mutant proves it can fail)
#   K6  the kernel's loader and the council's loader print identical JSON for the same file
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d /tmp/constitution-kernel.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

CORE_LIBS=(header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh
           lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh)

# --- K1 embed + reproducibility ------------------------------------------------------------
heredoc() { awk -v d="$2" 'f && $0==d {exit} f {print} index($0, "<<'"'"'" d "'"'"'") {f=1}' "$1"; }
[[ "$(heredoc src/constitution_kernel.sh CONSTITUTION_KERNEL_MJS)" == "$(cat src/constitution/constitution.mjs)" ]] \
  && ok_t "K1 embedded constitution.mjs matches src/constitution/constitution.mjs" \
  || bad_t "K1 constitution.mjs embed drifted" "run: node src/constitution/gen_kernel.mjs"
[[ "$(heredoc src/constitution_kernel.sh CONSTITUTION_KERNEL_CLI_MJS)" == "$(cat src/constitution/cli.mjs)" ]] \
  && ok_t "K1 embedded cli.mjs matches src/constitution/cli.mjs" \
  || bad_t "K1 cli.mjs embed drifted" "run: node src/constitution/gen_kernel.mjs"
cp src/constitution_kernel.sh "$TMP/kernel.shipped"
node src/constitution/gen_kernel.mjs 2>/dev/null
cmp -s src/constitution_kernel.sh "$TMP/kernel.shipped" \
  && ok_t "K1 gen_kernel.mjs reproduces the committed src/constitution_kernel.sh" \
  || { bad_t "K1 generator not reproducible" "the committed file differs from what the generator writes"; cp "$TMP/kernel.shipped" src/constitution_kernel.sh; }

# Fixture helpers. STATE_DIR-relative paths, so the kernel resolves them itself.
write_c() { printf '%s\n' "$@" > "$STATE_DIR/constitution.yaml"; }
seal()    { mkdir -p "$STATE_DIR/council"
            printf '{"seq":0,"record":{"constitutionDigest":"%s"}}\n' \
              "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"; }
POLICY=('hard_gates:' "  money: 'spend|billing'" "  public_comms: 'brand|press'"
        'authority:' '  gate_clear_leads:' '    - marcus' '# kernel fixture')

# The whole K2-K4 scenario, run in a fresh shell. $1 = "kernel" | "no-kernel".
scenario() {
  bash -c '
    set -uo pipefail
    cd "$1"; shift; mode="$1"; tmp="$2"; shift 2
    for f in "$@"; do source "src/$f"; done
    [[ "$mode" == kernel ]] && source src/constitution_kernel.sh
    STATE_DIR="$tmp/state-$mode"; mkdir -p "$STATE_DIR"
    unset FIVEDIVE_CONSTITUTION_FILE
    COUNCIL_LINEAGE="$STATE_DIR/council/lineage.jsonl"
    source "$tmp/helpers.sh"
    say() { printf "%s=%s\n" "$1" "$2"; }
    hit() { _gate_tier2_floor_hit "$1" 2>/dev/null && echo yes || echo no; }
    say council_loaded "$(declare -F _council_constitution_path >/dev/null && echo yes || echo no)"
    say nofile_publish "$(hit "publish the launch post")"
    say nofile_brand "$(hit "review the brand strategy")"
    write_c "${POLICY[@]}"
    say unsealed_brand "$(hit "review the brand strategy")"
    seal
    say sealed_brand "$(hit "review the brand strategy")"
    say sealed_leads "$(_gate_clear_leads 2>/dev/null | tr "\n" ,)"
    say sealed_reason "$(_gate_clear_lead_denied_reason 2>/dev/null)"
    write_c "hard_gates:" "  public_comms: \"brand\"" "# tampered after sealing"
    say drift_billing "$(hit "approve billing")"
    say drift_brand "$(hit "review the brand strategy")"
    say drift_leads "$(_gate_clear_leads 2>/dev/null | tr "\n" ,)"
    say drift_reason "$(_gate_clear_lead_denied_reason 2>/dev/null)"
  ' _ "$ROOT" "$1" "$TMP" "${CORE_LIBS[@]}"
}
{ declare -f write_c seal; declare -p POLICY; } > "$TMP/helpers.sh"
K="$(scenario kernel)"; N="$(scenario no-kernel)"
get() { sed -n "s/^$2=//p" <<<"$1"; }

# --- K2 the council engine is absent (control for K3) --------------------------------------
[[ "$(get "$K" council_loaded)" == no ]] \
  && ok_t "K2 the K3 shell has NO council engine loaded (_council_constitution_path undefined)" \
  || bad_t "K2 council leaked into the kernel-only shell" "K3 would not prove independence"

# --- K3 council ABSENT, kernel present: behaviour is the full sealed-constitution behaviour ----
chk() { [[ "$(get "$K" "$1")" == "$2" ]] && ok_t "K3 $3" || bad_t "K3 $3" "$1: wanted '$2', got '$(get "$K" "$1")'"; }
chk nofile_publish yes "no constitution: the shipped floor still gates 'publish'"
chk nofile_brand   no  "no constitution: 'brand' is not in the shipped floor"
chk unsealed_brand yes "an unsealed constitution adds 'brand' (the kernel's node loader ran)"
chk sealed_brand   yes "a sealed, in-sync constitution is trusted"
chk sealed_leads   "marcus," "the sealed gate_clear_leads allowlist resolves to marcus"
chk sealed_reason  not-a-sealed-lead "the denial reason reaches the per-agent check (seal read, no drift)"
chk drift_billing  yes "a post-seal edit that deletes the money class still floors 'billing'"
chk drift_brand    no  "a drifted file's classes are ignored"
chk drift_leads    ""  "a drifted file grants no lead"
chk drift_reason   constitution-drifted "the denial names the drift"

# --- K4 negative control: the same shell WITHOUT the kernel fails closed -------------------
[[ "$(get "$N" unsealed_brand)" == no && "$(get "$N" sealed_leads)" == "" \
   && "$(get "$N" sealed_reason)" == no-council-loader ]] \
  && ok_t "K4 without the kernel the constitution is ignored and every lead denied (K3's green is the kernel's)" \
  || bad_t "K4 control did not fail closed" "$(tr '\n' ' ' <<<"$N")"

# --- K5 parity with the council's copies (they coexist until council leaves core) ----------
# Normalise the council's names to the kernel's, then compare the function bodies.
PAIRS="_council_constitution_path:_constitution_path _council_sealed_constitution_digest:_constitution_sealed_digest
_council_live_constitution_digest:_constitution_live_digest _council_constitution_drifted:_constitution_drifted"
norm() { sed 's/_council_constitution_path/_constitution_path/g; s/_council_sealed_constitution_digest/_constitution_sealed_digest/g; s/_council_live_constitution_digest/_constitution_live_digest/g; s/_council_constitution_drifted/_constitution_drifted/g'; }
parity() { # $1 = kernel file to compare; prints the first pair that differs, or nothing
  bash -c 'source "$1/src/header.sh"; source "$1/src/cmd_council.sh"; source "$2"; shift 2
    for p in $1; do printf "%s\n" "${p%%:*}:${p##*:}"; done' _ "$ROOT" "$1" "$PAIRS" |
  while IFS=: read -r c k; do
    [[ "$(bash -c 'source "$1/src/header.sh"; source "$1/src/cmd_council.sh"; declare -f "$2"' _ "$ROOT" "$c" | norm)" \
       == "$(bash -c 'source "$1/src/header.sh"; source "$2"; declare -f "$3"' _ "$ROOT" "$1" "$k")" ]] || echo "$c"
  done
}
d="$(parity "$ROOT/src/constitution_kernel.sh")"
[[ -z "$d" ]] && ok_t "K5 the four kernel functions are body-identical to the council's copies" \
              || bad_t "K5 kernel and council copies drifted" "differs: $d"
sed 's/\[\[ -z "\$live" \]\] \&\& return 0 /[[ -z "$live" ]] \&\& return 1 /' src/constitution_kernel.sh > "$TMP/mutant.sh"
if cmp -s "$TMP/mutant.sh" src/constitution_kernel.sh; then bad_t "K5 mutant did not apply" "the parity control proves nothing"
else
  d="$(parity "$TMP/mutant.sh")"
  [[ "$d" == _council_constitution_drifted ]] \
    && ok_t "K5 control: a mutant that trusts a deleted sealed file is caught by the parity arm" \
    || bad_t "K5 control: mutant not caught" "got '$d'"
fi

# --- K6 one parser: kernel loader == council loader, byte for byte ------------------------
printf '%s\n' "${POLICY[@]}" > "$TMP/doc-policy.yaml"
printf '%s\n' 'not yaml frontmatter' > "$TMP/doc-bad.yaml"
for doc in "" "$TMP/doc-policy.yaml" "$TMP/doc-bad.yaml" "$TMP/doc-missing.yaml"; do
  a="$(node src/constitution/cli.mjs constitution --path="$doc" 2>&1)"
  b="$(node src/council/cli.mjs constitution --path="$doc" 2>&1)"
  [[ -n "$a" && "$a" == "$b" ]] \
    && ok_t "K6 kernel and council loaders agree on '${doc##*/}' ($(jq -r .source <<<"$a"))" \
    || bad_t "K6 loaders disagree on '${doc##*/}'" "kernel=$a council=$b"
done

printf '\nconstitution_kernel_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
