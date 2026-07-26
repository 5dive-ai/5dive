#!/usr/bin/env bash
# DIVE-2018 — tests/meta/harness-verdict-union.sh
#
# The union check is itself an instrument that can succeed in appearance: every
# way it could wrongly report full coverage is a way the DIVE-2013 probe goes back
# to being silently environment-dependent. So the cases below are weighted toward
# the FALSE-CLEAN direction — a missing report, a headerless report, reports about
# different corpora, and the two verdicts that look like observations but are not
# (`already-red`, `UNPROBEABLE`) must all REFUSE, not pass.
#
# Hermetic: fixture corpora and fixture reports in a throwaway dir, `--corpus-dir`
# pointed at them. Never reads the real tests/ and never invokes the probe.
#
# Negative control (run by hand when changing the union script): delete the
# `[[ "$PROBED" == *" $h "* ]] && continue` line and case 1 reds; drop the
# `hdr_corpus != ${#corpus[@]}` guard and case 6 reds.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
UNION="$PWD/tests/meta/harness-verdict-union.sh"
[[ -x "$UNION" || -r "$UNION" ]] || { printf 'FAIL: %s not found\n' "$UNION"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hvu.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ # <name> <expected-rc> <actual-rc> <output>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected rc=$2 got rc=$3 — $4"; fi
}

# A fixture corpus of N harnesses named h1.sh..hN.sh
mkcorpus() { local d="$TMP/$1" n="$2" i; mkdir -p "$d"; for ((i=1;i<=n;i++)); do : > "$d/h$i.sh"; done; printf '%s' "$d"; }
# mkreport <file> <corpus-n> <allowlist-csv> <label> <verdict:name>...
mkreport() {
  local f="$TMP/$1" cn="$2" al="$3" lb="$4"; shift 4
  { printf '# harness-verdict-probe report\n# corpus=%s\n# allowlist=%s\n# label=%s\n' "$cn" "$al" "$lb"
    local spec; for spec in "$@"; do printf '%s\t%s\n' "${spec%%:*}" "${spec#*:}"; done
  } > "$f"; printf '%s' "$f"
}

C3=$(mkcorpus c3 3)

# 1. The union covers the corpus even though NEITHER run covers it alone.
#    This is the whole point: two green runs, different corpora, together complete.
A=$(mkreport a.txt 3 "" pristine wired:h1.sh wired:h2.sh not-reached:h3.sh)
B=$(mkreport b.txt 3 "" installed not-reached:h1.sh not-reached:h2.sh wired:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A" "$B" 2>&1); rc=$?
check "union of two partial environments is full coverage" 0 "$rc" "$out"

# 2. A harness skipped in EVERY environment is the defect DIVE-2018 filed — it must
#    fail, and it must say which environments skipped it (the old output could not).
A2=$(mkreport a2.txt 3 "" pristine wired:h1.sh wired:h2.sh not-reached:h3.sh)
B2=$(mkreport b2.txt 3 "" installed wired:h1.sh wired:h2.sh not-reached:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A2" "$B2" 2>&1); rc=$?
check "never-probed harness fails the union" 1 "$rc" "$out"
grep -q 'NEVER PROBED  h3.sh' <<<"$out" && ok "names the never-probed harness" \
  || bad "names the never-probed harness" "$out"
grep -q 'pristine=not-reached' <<<"$out" && grep -q 'installed=not-reached' <<<"$out" \
  && ok "names the verdict in EACH environment" || bad "names the verdict in EACH environment" "$out"

# 3. Allowlisted harnesses are excused — the exemption comes from the REPORT, so the
#    union never restates an allowlist the probe owns.
A3=$(mkreport a3.txt 3 "h3.sh" pristine wired:h1.sh wired:h2.sh allowlisted:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A3" 2>&1); rc=$?
check "allowlisted harness does not fail the union" 0 "$rc" "$out"

# 4. FAIL CLOSED — a missing report must never read as a clean one. This is the
#    single most important case: in CI a job that died before writing its report
#    would otherwise silently shrink the union to whatever survived.
A4=$(mkreport a4.txt 3 "" pristine wired:h1.sh wired:h2.sh wired:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A4" "$TMP/does-not-exist.txt" 2>&1); rc=$?
check "missing report fails closed even when the others are complete" 1 "$rc" "$out"

# 5. A file that is not a probe report at all (no header) is refused, not parsed
#    optimistically into zero findings.
printf 'wired\th1.sh\nwired\th2.sh\nwired\th3.sh\n' > "$TMP/nohdr.txt"
out=$(bash "$UNION" --corpus-dir="$C3" "$TMP/nohdr.txt" 2>&1); rc=$?
check "headerless report is refused" 1 "$rc" "$out"

# 6. THE DIVE-2018 SIGNATURE ITSELF: a report describing a different-sized corpus.
#    135+3+16 and 151+3 were both 154 and nothing said so; here they differ and it does.
A6=$(mkreport a6.txt 9 "" stale-checkout wired:h1.sh wired:h2.sh wired:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A6" 2>&1); rc=$?
check "report about a different corpus is refused" 1 "$rc" "$out"
grep -q 'not about the same code' <<<"$out" && ok "says the reports are not about the same code" \
  || bad "says the reports are not about the same code" "$out"

# 7. No reports at all is a usage error, not vacuous success.
out=$(bash "$UNION" --corpus-dir="$C3" 2>&1); rc=$?
check "zero reports is exit 2, not a green run" 2 "$rc" "$out"

# 8. already-red and UNPROBEABLE are NOT observations of a wired exit status.
#    Counting either as coverage would excuse a harness twice over.
A8=$(mkreport a8.txt 3 "" pristine wired:h1.sh already-red:h2.sh UNPROBEABLE:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A8" 2>&1); rc=$?
check "already-red and UNPROBEABLE do not count as probed" 1 "$rc" "$out"
grep -q 'NEVER PROBED  h2.sh' <<<"$out" && grep -q 'NEVER PROBED  h3.sh' <<<"$out" \
  && ok "names both non-observations" || bad "names both non-observations" "$out"

# 9. UNWIRED counts as PROBED — the mutation ran and the harness was measured. It
#    reds the probe, not the union; the union asks "was it looked at", not "did it pass".
A9=$(mkreport a9.txt 3 "" pristine wired:h1.sh wired:h2.sh UNWIRED:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A9" 2>&1); rc=$?
check "UNWIRED is coverage (the probe fails it, not the union)" 0 "$rc" "$out"

# 10. Reports disagreeing on the allowlist is one contract with two authors (DIVE-2004).
A10=$(mkreport a10.txt 3 "h3.sh" pristine wired:h1.sh wired:h2.sh allowlisted:h3.sh)
B10=$(mkreport b10.txt 3 "" installed wired:h1.sh wired:h2.sh not-reached:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A10" "$B10" 2>&1); rc=$?
check "reports disagreeing on the allowlist are refused" 1 "$rc" "$out"

# 11. An empty corpus dir must not report 100% coverage of nothing.
EMPTY=$(mkcorpus cempty 0)
A11=$(mkreport a11.txt 0 "" pristine)
out=$(bash "$UNION" --corpus-dir="$EMPTY" "$A11" 2>&1); rc=$?
check "empty corpus refuses to declare full coverage" 1 "$rc" "$out"

# 12. A stale allowlist name is drift worth SAYING and not worth reddening — it can
#     only ever excuse nothing, and a renamed harness turns UNPROBEABLE at the probe.
A12=$(mkreport a12.txt 3 "gone.sh" pristine wired:h1.sh wired:h2.sh wired:h3.sh)
out=$(bash "$UNION" --corpus-dir="$C3" "$A12" 2>&1); rc=$?
check "stale allowlist entry is reported, not fatal" 0 "$rc" "$out"
grep -q 'stale-allowlist  gone.sh' <<<"$out" && ok "names the stale allowlist entry" \
  || bad "names the stale allowlist entry" "$out"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
