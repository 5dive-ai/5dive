#!/usr/bin/env bash
# DIVE-8088 — run a CI step again when it failed on a DOWNLOAD, and only then.
#
#   scripts/net-retry.sh <command> [args...]
#
# On 2026-11-10 main went red five times in one night and never on our code:
# security.ubuntu.com served 404 for perl debs its own index had just listed
# (the index is published before every mirror IP has the pool), archive.ubuntu.com
# dropped connections mid-layer, and raw.githubusercontent.com answered 429. Each
# one passed on a hand re-run ~10 minutes later. This is that re-run, without the
# human: if <command> fails AND its output carries a download error, wait and run
# it again from the top. A `docker build` re-run repeats the failed apt layer with
# a FRESH `apt-get update` (a failed RUN is never cached), which is what clears a
# stale-pool 404 — apt's own Acquire::Retries never retries a 404.
#
# What it does NOT do, on purpose:
# - It never retries a failure that is not a download error. A bad package name, a
#   failing assertion, a broken install.sh: those fail on the first attempt, as
#   before, with nothing added to the output.
# - It never changes what the wrapped step checks. Same command, same assertions.
# - A download that fails every time still fails the job, after the last wait, and
#   the last lines of the log name the download error.
#
# NET_RETRY_SLEEPS — seconds to wait before each re-run (default "30 90 180": four
# attempts over ~5 minutes of waiting; the 2026-11-10 stale pool healed in ~10
# minutes across a hand re-run, so most of that window is covered). Tests set
# "0 0".
set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: net-retry.sh <command> [args...]" >&2; exit 2; }

# A download error, as apt, curl, docker and GitHub print one. Kept narrow: every
# alternative names the network or a mirror, never a package or a test.
NET_RETRY_PATTERN='Failed to fetch|Unable to fetch some archives|Temporary failure resolving|Could not resolve host|Connection failed|Connection timed out|Could not connect to|Hash Sum mismatch|File has unexpected size|Mirror sync in progress|returned error: (408|429|5[0-9][0-9])|toomanyrequests|TLS handshake timeout'

read -r -a sleeps <<<"${NET_RETRY_SLEEPS-30 90 180}"
attempts=$(( ${#sleeps[@]} + 1 ))
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for (( i = 1; i <= attempts; i++ )); do
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) && exit 0
  why="$(grep -aE -m1 "$NET_RETRY_PATTERN" "$log" || true)"
  # Not a download error: fail now, exactly as the bare command would have.
  [[ -n "$why" ]] || exit "$rc"
  if (( i < attempts )); then
    wait_s="${sleeps[i-1]}"
    echo "net-retry: attempt $i/$attempts failed on a download error; running it again in ${wait_s}s" >&2
    echo "net-retry:   $why" >&2
    sleep "$wait_s"
  fi
done

echo "net-retry: gave up after $attempts attempts; every one failed on a download. The last error:" >&2
grep -aE "$NET_RETRY_PATTERN" "$log" | tail -5 >&2
exit "$rc"
