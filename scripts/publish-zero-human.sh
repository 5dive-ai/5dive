#!/usr/bin/env bash
# publish-zero-human.sh — publish this box's zero-human KPI to the repo's
# `status` branch: badge.json (rendered by the README badge via shields.io),
# zero-human.json (the full datapoint) and history.jsonl (append-only log).
#
# The whole proof chain stays in this repo: the numbers are computed by
# `5dive digest` (src/cmd_digest.sh, OSS-10/OSS-14, unit-tested in
# tests/digest_autonomy_unit.sh), republished verbatim here, and rendered by
# the badge. There is deliberately no flag to edit a number. If the digest
# fails, nothing publishes and the date in the badge stops moving; a stale
# badge means a broken pipeline, not a curated pause.
#
# Usage: publish-zero-human.sh [--dry-run]
#   --dry-run  build the files and show the diff, skip commit and push
#
# Needs: 5dive on PATH, python3, git push rights to $ZH_REPO.
# Intended to run from a daily cron on the box whose numbers you publish.

set -euo pipefail

REPO="${ZH_REPO:-https://github.com/5dive-ai/5dive.git}"
BRANCH="${ZH_BRANCH:-status}"
GIT_NAME="${ZH_GIT_NAME:-lodar}"
GIT_EMAIL="${ZH_GIT_EMAIL:-markounik@gmail.com}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

day_json="$(5dive digest --json 2>/dev/null)"
week_json="$(5dive digest --json --7d 2>/dev/null)"
[[ -n "$day_json" && -n "$week_json" ]] || { echo "digest produced no output" >&2; exit 1; }
today="$(date -u +%F)"
today_label="$(date -u '+%b %-d')"
now_iso="$(date -u +%FT%TZ)"
cli_version="$(5dive --version 2>/dev/null | head -1 | awk '{print $2}')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if git ls-remote --exit-code --heads "$REPO" "$BRANCH" >/dev/null 2>&1; then
  git clone --quiet --depth 200 --branch "$BRANCH" --single-branch "$REPO" "$work/repo"
  cd "$work/repo"
else
  # first run: create the branch as an orphan so status history stays separate
  git clone --quiet --depth 1 "$REPO" "$work/repo"
  cd "$work/repo"
  git checkout --quiet --orphan "$BRANCH"
  git rm -rfq .
fi
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"

# Build the three files from the digest output, verbatim. Exit 3 = already
# published today (idempotent no-op for a re-run).
set +e
summary="$(DAY_JSON="$day_json" WEEK_JSON="$week_json" TODAY="$today" \
  TODAY_LABEL="$today_label" NOW_ISO="$now_iso" CLI_VERSION="$cli_version" \
  python3 <<'PY'
import json, os, pathlib, sys

day = json.loads(os.environ["DAY_JSON"])
week = json.loads(os.environ["WEEK_JSON"])
today = os.environ["TODAY"]

hist_path = pathlib.Path("history.jsonl")
hist = []
if hist_path.exists():
    hist = [json.loads(l) for l in hist_path.read_text().splitlines() if l.strip()]
if any(h.get("date") == today for h in hist):
    print(f"already published for {today}", file=sys.stderr)
    sys.exit(3)

row = {
    "date": today,
    "day": {"shipped": day["zeroHuman"]["shipped"],
            "humanAsks": day["zeroHuman"]["humanTouches"]},
    "week": {"shipped": week["zeroHuman"]["shipped"],
             "humanAsks": week["zeroHuman"]["humanTouches"]},
    "cliVersion": os.environ["CLI_VERSION"],
}
hist.append(row)

# Cumulative totals sum the non-overlapping 24h datapoints, never the rolling
# 7d windows (those overlap and would double-count).
cum = {
    "daysPublished": len(hist),
    "shipped": sum(h["day"]["shipped"] for h in hist),
    "humanAsks": sum(h["day"]["humanAsks"] for h in hist),
    "since": hist[0]["date"],
}

w_ship = row["week"]["shipped"]
w_ask = row["week"]["humanAsks"]
ask_word = "ask" if w_ask == 1 else "asks"
message = f"7d: {w_ship} shipped, {w_ask} {ask_word}"

# Label is the entity, message is the scorecard. The window end date lives in
# zero-human.json/history.jsonl; the badge stays short so it reads at a glance.
badge = {"schemaVersion": 1, "label": "zero human",
         "message": message, "color": "blueviolet"}

datapoint = {
    "generatedAtUtc": os.environ["NOW_ISO"],
    "date": today,
    "week": row["week"],
    "day": row["day"],
    "cumulative": cum,
    "cliVersion": os.environ["CLI_VERSION"],
    "source": "5dive digest --json [--7d] on the production box that runs 5dive-the-company",
    "methodology": "https://github.com/5dive-ai/5dive/blob/main/docs/zero-human.md",
}

hist_path.write_text("".join(json.dumps(h, sort_keys=True) + "\n" for h in hist))
pathlib.Path("badge.json").write_text(json.dumps(badge, indent=2) + "\n")
pathlib.Path("zero-human.json").write_text(json.dumps(datapoint, indent=2) + "\n")
pathlib.Path("README.md").write_text(
    "# status\n\n"
    "Machine-published zero-human KPI for the company of agents that builds 5dive.\n"
    "Written daily by [scripts/publish-zero-human.sh](https://github.com/5dive-ai/5dive/blob/main/scripts/publish-zero-human.sh); "
    "methodology and limits in [docs/zero-human.md](https://github.com/5dive-ai/5dive/blob/main/docs/zero-human.md).\n\n"
    "- `badge.json` is what the README badge renders (shields.io endpoint schema)\n"
    "- `zero-human.json` is the full current datapoint\n"
    "- `history.jsonl` is every daily datapoint, append-only\n"
)
print(f"{today} (7d: {w_ship} shipped, {w_ask} {ask_word})")
PY
)"
rc=$?
set -e
if [[ $rc -eq 3 ]]; then echo "already published today, nothing to do"; exit 0; fi
[[ $rc -eq 0 ]] || exit "$rc"

git add -A
if git diff --cached --quiet; then echo "no changes"; exit 0; fi
if [[ $DRY -eq 1 ]]; then
  echo "--dry-run: would commit 'status: $summary'"
  git diff --cached --stat
  exit 0
fi
git commit --quiet -m "status: $summary"
git push --quiet origin "$BRANCH"
echo "published: $summary"
