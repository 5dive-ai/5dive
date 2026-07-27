#!/usr/bin/env bash
# DIVE-2118's push loop, DIVE-2143's honesty.
#
# WHY THIS IS A SCRIPT AND NOT TEN MORE LINES OF YAML. It used to live inline in
# .github/workflows/version-assign.yml, where it was unreachable by every harness in
# tests/ — the only way to exercise it was to merge to main and watch. It shipped a
# retry loop that reported the wrong cause on a real failure (run 30231912328) and
# nothing could have caught that before the fact. A branch of logic that decides
# whether to retry and what to blame is exactly the kind that needs a mutation test,
# so it moved somewhere a test can reach it. Graded by tests/version_assign_push_unit.sh.
#
# Usage: version-assign-push-loop.sh <base-rev> [attempts]
# Exit:  0 = an assignment was applied and pushed (caller should grade it)
#        3 = nothing was owed; no push happened, so there is nothing to grade
#        1 = failure, already reported loudly on stderr / as ::error::
set -uo pipefail

BEFORE="${1:?usage: version-assign-push-loop.sh <base-rev> [attempts]}"
ATTEMPTS="${2:-3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classify() { bash "$HERE/git-push-reject-class.sh"; }

# The identity lives with the commit that uses it: any other author fails the Vercel
# team check on this org.
git config user.name  'lodar'
git config user.email 'markounik@gmail.com'

# THE RACE, and why `concurrency` does not close it (found in review, iteration 1).
# concurrency serialises RUNS — but a human MERGE is not in the group, and
# actions/checkout on a push event pins to github.sha, NOT main's tip. So if a merge
# lands between this job's checkout and its push, the push is non-fast-forward and the
# job dies. It is a WINDOW, not a certainty (a merge landing after we push is fine,
# and that run computes correctly), but it is likeliest in exactly the batched-merge
# scenario this job exists for. So: refetch, recompute against the moved tip, retry,
# and fail loudly.
#
# BASE stays github.event.before across retries, deliberately. If a previous run
# already assigned, the version HAS moved relative to that base, so the script reports
# "already moved" and we stop — one version per batch, which is the batching lodar
# wants. If nobody assigned, we assign once for the whole batch. Both are correct;
# neither double-bumps.
assigned=""
for (( try=1; try<=ATTEMPTS; try++ )); do
  git fetch -q origin main
  tip=$(git rev-parse FETCH_HEAD)
  if [[ "$tip" != "$(git rev-parse HEAD)" ]]; then
    echo "version-assign: main moved to ${tip:0:12} since checkout (attempt $try/$ATTEMPTS) — recomputing against the new tip."
    git reset -q --hard "$tip"
  fi

  out=$(bash scripts/version-assign.sh HEAD "$BEFORE" --apply); rc=$?
  echo "$out"
  if (( rc == 2 )); then
    echo "::error::version-assign could not determine whether a bump is owed — NOT a pass, see above."
    exit 1
  fi
  if ! grep -q '^version-assign: applied ' <<<"$out"; then
    exit 3   # nothing owed; the reason is printed above
  fi

  # DIVE-2091: the bundle is generated at tag time and gitignored on main, so
  # `git add 5dive` here would fail ("paths are ignored") and break the performer.
  # Only the version bump belongs on main now.
  git add src/header.sh
  git commit -q -m "release: assign $(grep -m1 -oE 'FIVE_VERSION="[^"]+"' src/header.sh | sed 's/.*"\(.*\)"/\1/') at merge (DIVE-2118, automated)

The bundle changed on main without FIVE_VERSION moving. CONTRIBUTING assigns the
version at merge by merge order; this performs that step so a box on the previous
version is not silently left without the merged fixes (the shared-checkout updater is
version-triggered, not content-hash triggered — DIVE-2065).

No tag and no release: those are batched, deliberately (lodar, 2026-07-26)."

  # DIVE-2143: keep the remote's OWN words. Every message below quotes them rather
  # than paraphrasing, because on the failure that opened this ticket the paraphrase
  # was the entire defect — the remote had already said the true thing.
  if perr=$(git push origin HEAD:main 2>&1); then
    echo "$perr"
    assigned=$(grep -m1 -oE 'FIVE_VERSION="[^"]+"' src/header.sh | sed 's/.*"\(.*\)"/\1/')
    break
  fi
  echo "$perr"

  case "$(classify <<<"$perr")" in
    protection)
      # DETERMINISTIC. Attempts 2 and 3 cannot succeed, and calling this a race sends
      # the reader after a concurrency bug in code that is working correctly. The fix
      # for this class is a branch-protection configuration, so say so and stop.
      echo "::error::version-assign: push rejected by branch protection on main — NOT a race, main did not move. Retrying cannot help, so no further attempt was made (attempt $try/$ATTEMPTS). The remote's own words:"
      sed 's/^/    /' <<<"$perr" >&2
      echo "::error::The fix is a branch-protection / ruleset change (or DIVE-2144's tag-based publish), not a retry. NO assignment was made and the bundle on main is still unassigned."
      exit 1
      ;;
    race)
      echo "version-assign: push rejected — main moved under us (attempt $try/$ATTEMPTS). Dropping the local assignment and recomputing."
      git reset -q --hard "$tip"
      ;;
    *)
      # We do not know. Say we do not know — the one thing we must not do is reach for
      # the nearest familiar cause, which is how this ticket happened.
      echo "::error::version-assign: push rejected for an UNRECOGNISED reason (attempt $try/$ATTEMPTS) — this is NOT known to be a race, so it was not retried. The remote's own words:"
      sed 's/^/    /' <<<"$perr" >&2
      echo "::error::NO assignment was made and the bundle on main is still unassigned. If this class is in fact retryable, add it to scripts/git-push-reject-class.sh with a captured stderr fixture."
      exit 1
      ;;
  esac
done

if [[ -z "$assigned" ]]; then
  echo "::error::version-assign: main kept moving across $ATTEMPTS attempts, so NO assignment was made and the bundle on main is still unassigned. Bump by hand (scripts/version-assign.sh HEAD <prev> --apply) or re-run this workflow."
  exit 1
fi
echo "::notice::assigned ${assigned} — no tag cut, releases are batched"
echo "version-assign: assigned ${assigned}"
