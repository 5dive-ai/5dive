#!/usr/bin/env bash
# DIVE-2039 — tests/meta/selfcheck-union.sh.
#
# The union is the only thing that stops NOT-REACHED from being a free pass, so every
# way it could WRONGLY report full coverage is a way selfcheck goes back to being
# silently environment-dependent. The cases below are weighted toward the FALSE-CLEAN
# direction: a missing report, a headerless report, reports about different corpora,
# and the two verdicts that look like observations but are not (`not-reached`,
# `error`) must all REFUSE, not pass.
#
# Hermetic: fixture reports in a throwaway dir. Never runs `5dive selfcheck`.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
UNION="$PWD/tests/meta/selfcheck-union.sh"
[[ -r "$UNION" ]] || { printf 'FAIL: %s not found\n' "$UNION"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/scu.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected rc=$2, got rc=$3) — $4"; fi }

# mkreport <file> <corpus-csv> <label> <verdict:probe>...   (ALLOW= sets the allowlist)
mkreport() {
  local f="$TMP/$1" corpus="$2" label="$3"; shift 3
  { printf '# selfcheck report\n# probes=%s\n# allow=%s\n# label=%s\n' "$corpus" "${ALLOW:-}" "$label"
    local s; for s in "$@"; do printf '%s\t%s\t\n' "${s%%:*}" "${s#*:}"; done
  } > "$f"; printf '%s' "$f"
}
C="gate-delivery,audit-root,audit-nonroot"

# ── 1. THE WHOLE POINT: neither run covers the corpus, the union does ────────
# A root cron can never measure the non-root audit leg and an agent run can never
# measure the root one. Both are honest; together they are complete.
A=$(mkreport a.txt "$C" root      pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
B=$(mkreport b.txt "$C" agent-dev pass:gate-delivery not-reached:audit-root pass:audit-nonroot)
out=$(bash "$UNION" "$A" "$B" 2>&1); chk "union of two partial environments is full coverage" 0 "$?" "$out"

# ── 2. not-reached EVERYWHERE is the defect this exists to catch ─────────────
A2=$(mkreport a2.txt "$C" root      pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
B2=$(mkreport b2.txt "$C" installed pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
out=$(bash "$UNION" "$A2" "$B2" 2>&1); chk "a probe not-reached in EVERY environment fails" 1 "$?" "$out"
grep -q 'NEVER REACHED  audit-nonroot' <<<"$out" && ok_t "names the never-reached probe" \
  || fail_t "does not name the probe: $out"
grep -q 'root=not-reached' <<<"$out" && grep -q 'installed=not-reached' <<<"$out" \
  && ok_t "names the verdict in EACH environment" || fail_t "per-env verdicts missing: $out"

# ── 3. a FAIL is coverage — the probe ran and measured the rail ──────────────
# The union asks "was this rail looked at", not "did it pass". Selfcheck's own exit
# code is what fails on a fail; conflating the two would make a red rail look like a
# coverage hole and hide both.
A3=$(mkreport a3.txt "$C" only fail:gate-delivery pass:audit-root pass:audit-nonroot)
out=$(bash "$UNION" "$A3" 2>&1); chk "a failing probe counts as reached" 0 "$?" "$out"

# ── 4. FAIL CLOSED — a missing report is never a clean one ───────────────────
# In CI a job that died before writing its report would otherwise silently shrink the
# union to whatever survived, and a shrunken union is indistinguishable from a complete one.
A4=$(mkreport a4.txt "$C" full pass:gate-delivery pass:audit-root pass:audit-nonroot)
out=$(bash "$UNION" "$A4" "$TMP/nope.txt" 2>&1)
chk "a missing report fails closed even when the others are complete" 1 "$?" "$out"

# ── 5. a file that is not a report is refused, not parsed into zero findings ─
printf 'pass\tgate-delivery\t\n' > "$TMP/nohdr.txt"
out=$(bash "$UNION" "$TMP/nohdr.txt" 2>&1); chk "a headerless report is refused" 1 "$?" "$out"

# ── 6. reports about different corpora ───────────────────────────────────────
A6=$(mkreport a6.txt "$C" current pass:gate-delivery pass:audit-root pass:audit-nonroot)
B6=$(mkreport b6.txt "gate-delivery,audit-root" stale pass:gate-delivery pass:audit-root)
out=$(bash "$UNION" "$A6" "$B6" 2>&1); chk "reports about different corpora are refused" 1 "$?" "$out"
grep -q 'not about the same code' <<<"$out" && ok_t "says the reports are not about the same code" \
  || fail_t "no drift message: $out"

# ── 7. no reports is a usage error, not a vacuous pass ───────────────────────
out=$(bash "$UNION" 2>&1); chk "zero reports is exit 2, not a green run" 2 "$?" "$out"

# ── 8. an empty corpus must not read as 100% coverage of nothing ─────────────
E=$(mkreport e.txt "" empty)
out=$(bash "$UNION" "$E" 2>&1); chk "an empty corpus refuses to declare coverage" 1 "$?" "$out"

# ── 9. `error` is not an observation of the rail ─────────────────────────────
# A probe that broke before it could measure says nothing about the rail; counting it
# as coverage would excuse the probe with its own malfunction.
A9=$(mkreport a9.txt "$C" one pass:gate-delivery pass:audit-root error:audit-nonroot)
out=$(bash "$UNION" "$A9" 2>&1); chk "a probe that errored does not count as reached" 1 "$?" "$out"

# ── 10. a probe absent from a report entirely is not coverage ────────────────
A10=$(mkreport a10.txt "$C" partial pass:gate-delivery pass:audit-root)
out=$(bash "$UNION" "$A10" 2>&1); chk "a probe missing from the rows is not reached" 1 "$?" "$out"
grep -q 'audit-nonroot' <<<"$out" && ok_t "names the probe that never appeared" || fail_t "silent about it: $out"

# ── 11. an allowlisted probe is excused, and the allowlist comes FROM the report ─
# GitHub CI has no ops repo, so snapshot-rails can never be reached there in any
# job. That exemption belongs to the deployment that knows it, declared once by the
# producer — never restated here, where it would drift (DIVE-2004).
ALLOW="audit-nonroot" A11=$(mkreport a11.txt "$C" ci pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
out=$(bash "$UNION" "$A11" 2>&1); chk "an allowlisted probe does not fail the union" 0 "$?" "$out"
grep -q 'allowlisted   audit-nonroot' <<<"$out" && ok_t "the exemption is stated, not silent" \
  || fail_t "allowlisted probe excused silently: $out"

# ── 12. reports disagreeing on the allowlist are refused ────────────────────
ALLOW="audit-nonroot" A12=$(mkreport a12.txt "$C" ci   pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
ALLOW=""              B12=$(mkreport b12.txt "$C" host pass:gate-delivery pass:audit-root not-reached:audit-nonroot)
out=$(bash "$UNION" "$A12" "$B12" 2>&1); chk "reports disagreeing on the allowlist are refused" 1 "$?" "$out"

# ── 13. the allowlist excuses ONLY what it names ────────────────────────────
# The property that has to survive: a NEW probe reached nowhere still reds, even
# alongside a legitimately allowlisted one.
ALLOW="audit-nonroot" A13=$(mkreport a13.txt "$C" ci not-reached:gate-delivery pass:audit-root not-reached:audit-nonroot)
out=$(bash "$UNION" "$A13" 2>&1); chk "an unlisted never-reached probe still fails" 1 "$?" "$out"
grep -q 'NEVER REACHED  gate-delivery' <<<"$out" && ok_t "names it despite the allowlist" || fail_t "swallowed: $out"

# ── 14. a stale allowlist name is drift worth SAYING, not worth reddening ───
ALLOW="probe-that-was-renamed" A14=$(mkreport a14.txt "$C" ci pass:gate-delivery pass:audit-root pass:audit-nonroot)
out=$(bash "$UNION" "$A14" 2>&1); chk "a stale allowlist name does not red a covered union" 0 "$?" "$out"
grep -q 'stale name' <<<"$out" && ok_t "the stale name is reported" || fail_t "stale name silent: $out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
