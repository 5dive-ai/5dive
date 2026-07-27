#!/usr/bin/env bash
# DIVE-2143: name the CAUSE of a `git push` rejection, or admit you cannot.
#
# MEASURED ON A REAL FAILURE, run 30231912328 (2026-07-27 02:19). version-assign's
# retry loop treated EVERY push rejection as a lost race: it printed "main moved
# under us" three times and finished with "main kept moving across 3 attempts".
# Main did not move once — the tip was 02b356e for the entire run. The remote had
# said the true thing on the first attempt:
#
#   remote: error: GH006: Protected branch update failed for refs/heads/main.
#   remote: - 6 of 6 required status checks are expected.
#    ! [remote rejected] HEAD -> main (protected branch hook declined)
#
# Two costs, and the second is the expensive one. A protection rejection is
# DETERMINISTIC, so attempts 2 and 3 cannot succeed — the retries are pure latency.
# And an error that names the wrong cause is worse than one that names none: it
# sends the next reader hunting a concurrency bug through code that is working
# correctly. That is [[succeeding-in-appearance-defect-class]] one level up from a
# rail that no-ops green — a rail that FAILS, loudly, in the wrong direction.
#
# Usage: git-push-reject-class.sh < <push-stderr>     (also accepts a file argument)
# Prints exactly one word on stdout, always exits 0:
#   protection - the ref is gated (GH006, required checks, PR-only rule). NOT a
#                race. Deterministic: retrying cannot help. Fail immediately.
#   race       - a genuine lost race (non-fast-forward / fetch first / stale info).
#                Refetch, recompute against the moved tip, retry.
#   unknown    - not recognised. The caller must echo the remote's own lines and
#                fail; it must NOT retry and must NOT name a cause.
#
# WHY `unknown` DOES NOT RETRY. A transient network failure would benefit from a
# retry, and under this rule it gets none. That is the deliberate trade: the defect
# being fixed is a confident wrong diagnosis, and "retry an unrecognised failure"
# is the same instinct that produced it. A job re-run is cheap; a false cause
# costs the next reader an investigation. Add a class here (with a captured stderr
# in tests/fixtures/push-reject/) rather than widening `race` to mean "dunno".
set -uo pipefail

err="$(cat -- "${1:--}")"

# Precedence is load-bearing, not cosmetic: a protection rejection ALSO carries
# "! [remote rejected]", and GH006's body mentions "Updates were rejected" in some
# variants. Protection is checked first so a gated ref can never be reported as a
# race — the exact misreading this script exists to prevent.
if grep -qiE 'GH006|protected branch (update failed|hook declined)|required status check|changes must be made through a pull request|protected branch' <<<"$err"; then
  echo protection; exit 0
fi

# A genuine race, in git's own words. Every phrase here appears in git's rejection
# output for a stale ref, not in GitHub's server-side hook output.
if grep -qiE 'non-fast-forward|fetch first|stale info|cannot lock ref|Updates were rejected because' <<<"$err"; then
  echo race; exit 0
fi

echo unknown
