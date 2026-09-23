#!/usr/bin/env bash
# DIVE-4869 phase 1 / DIVE-4893: the constitution kernel is CORE, not council — and the council is gone.
#
# `task need`'s tier-2 floor and its lead-clear authority read the constitution and trust it only
# when it matches the digest sealed in the council lineage. Before this change every one of those
# reads went through `_council_*` functions defined in the council engine, behind `declare -F`
# guards that FAIL CLOSED — so taking council out of the bundle would silently have dropped every
# box to the shipped floor and denied every sealed lead. This harness grades the property the
# extraction depends on: with no council code in scope at all, the gate floor and the lead-clear
# allowlist behave exactly as they did with it. DIVE-4893 deleted the council from core, so the
# parity arm against its copies became a GOLDEN arm: the solo seal core now writes into the shared
# lineage must stay byte-identical to what the council's own writer produced, because the council
# plugin still appends to — and verifies — that same chain.
#
#   K1  the kernel's embedded modules match their canonical sources; the generator is reproducible
#   K2  control: the council engine really is absent in the K3 shell (no vacuous green)
#   K3  gate floor + seal + drift + lead allowlist, council ABSENT
#   K4  negative control: without the kernel the same shell fails closed (K3's green is the kernel)
#   K5  the solo genesis writer's output is byte-identical to the pre-move council engine's
#       (golden bytes; a mutant proves the arm can fail)
#   K6  the structural chain check gives the pre-move verdicts (intact / broken link / reordered)
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
[[ "$(heredoc src/constitution_kernel.sh CONSTITUTION_KERNEL_SEAL_MJS)" == "$(cat src/constitution/seal.mjs)" ]] \
  && ok_t "K1 embedded seal.mjs matches src/constitution/seal.mjs" \
  || bad_t "K1 seal.mjs embed drifted" "run: node src/constitution/gen_kernel.mjs"
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

# --- K5 the solo seal is byte-identical to the council's writer -----------------------------
# Golden bytes captured from the council engine at 5dive-ai/5dive 853725fd (src/council/cli.mjs
# `init`, the last core commit that carried it — identical to the plugin's provenance fcd81d73) on
# exactly these arguments. Both writers append to ONE hash chain, so a divergence here is a record
# one of them cannot re-derive.
GEN_ARGS=(--seats=solo:chair --veto=human:solo --veto-resolved=1234567890 --prev-digest=0a1b2c
          --seq=3 --stamped-at=2026-01-01T00:00:00Z --constitution-digest=deadbeef --force --genesis-exists=1)
GOLDEN_CANONICAL='genesis: council v1 seq=3
stampedAt: 2026-01-01T00:00:00Z
forced: true
prevDigest: 0a1b2c
seat solo (chair): solo — council seat.
chair: solo
threshold: rule=majority value= flat=
veto: human:solo -> 1234567890
constitution: deadbeef'
GOLDEN_OUT_SHA=2e25c61d6ae04a0a4932582189e252ed0c1edf336bff840aa455d5bc0d8e71ee
GOLDEN_BENCH_SHA=bb658e78cb804596fc55d3a30fca44bc3749757bdbf4c87e2fb55cacfcb80acd
genesis_run() { # $1 = kernel dir holding cli.mjs + siblings; prints "<canonical>\n--\n<out sha> <bench sha>"
  local reg="$TMP/bench.$RANDOM.json" out
  out="$(node "$1/cli.mjs" genesis "${GEN_ARGS[@]}" --registry="$reg")" || return 1
  printf '%s\n--\n%s %s\n' "$(jq -r .canonical <<<"$out")" \
    "$(printf '%s\n' "$out" | sha256sum | awk '{print $1}')" "$(sha256sum < "$reg" | awk '{print $1}')"
}
WANT="$(printf '%s\n--\n%s %s\n' "$GOLDEN_CANONICAL" "$GOLDEN_OUT_SHA" "$GOLDEN_BENCH_SHA")"
[[ "$(genesis_run src/constitution)" == "$WANT" ]] \
  && ok_t "K5 the solo genesis record, canonical bytes and seeded bench match the council writer's golden" \
  || bad_t "K5 the solo seal drifted from the council's writer" "$(diff <(genesis_run src/constitution) <(printf '%s' "$WANT"))"
mkdir -p "$TMP/k5mut"; cp src/constitution/*.mjs "$TMP/k5mut/"
sed -i 's/L.push(`forced: ${!!rec.forced}`)/L.push(`forced:${!!rec.forced}`)/' "$TMP/k5mut/seal.mjs"
if cmp -s "$TMP/k5mut/seal.mjs" src/constitution/seal.mjs; then bad_t "K5 mutant did not apply" "the golden control proves nothing"
else
  [[ "$(genesis_run "$TMP/k5mut")" != "$WANT" ]] \
    && ok_t "K5 control: a one-space change to the canonical preimage is caught by the golden" \
    || bad_t "K5 control: mutant not caught" "the golden arm cannot fail"
fi

# --- K6 the chain check keeps the council's verdicts ----------------------------------------
chain() { node src/constitution/cli.mjs verify-chain --entries="$1"; echo "rc=$?"; }
[[ "$(chain '[{"seq":0,"prevDigest":"","digest":"a"},{"seq":1,"prevDigest":"a","digest":"b"}]')" \
   == $'{"ok":true,"head":"b","length":2}\nrc=0' ]] \
  && ok_t "K6 an intact two-record chain verifies (head b, rc 0)" || bad_t "K6 intact chain" "$(chain '[{"seq":0,"prevDigest":"","digest":"a"},{"seq":1,"prevDigest":"a","digest":"b"}]')"
[[ "$(chain '[{"seq":0,"prevDigest":"","digest":"a"},{"seq":1,"prevDigest":"x","digest":"b"}]')" == *'"ok":false,"reason":"broken chain at record 1'*'rc=5' ]] \
  && ok_t "K6 an edited link is a broken chain (rc 5)" || bad_t "K6 broken link not caught" ""
[[ "$(chain '[{"seq":1,"prevDigest":"","digest":"a"},{"seq":1,"prevDigest":"a","digest":"b"}]')" == *'non-monotonic seq'*'rc=5' ]] \
  && ok_t "K6 a reordered/duplicated seq is refused (rc 5)" || bad_t "K6 non-monotonic seq not caught" ""

printf '\nconstitution_kernel_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
