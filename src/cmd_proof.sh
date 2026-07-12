# cmd_proof — publish this box's zero-human proof to a git status branch.
#
# OSS-17: generalizes scripts/publish-zero-human.sh into a first-class verb so
# ANY self-hosted box publishes its own proof (badge.json + zero-human.json +
# history.jsonl) to its own repo's status branch, same methodology as ours
# (docs/zero-human.md). The thesis gets proven repeatedly by users, not just us.
#
# Honesty invariants (non-negotiable, carried over from the script verbatim):
#   - Numbers come from `5dive digest --json` VERBATIM. There is deliberately
#     NO flag that edits a number — the no-edit path IS the product.
#   - history.jsonl is append-only; the status branch's git history is the
#     tamper-evident audit trail.
#   - Idempotent per-day: a re-run is a no-op (exit 3).
#   - Failure mode is visible staleness: if the digest or push fails, nothing
#     publishes and the badge date stops moving. No curated pauses; bad weeks
#     and fresh-box zeros publish exactly like good ones.
#
# Config: ${STATE_DIR}/proof.json {enabled,repo,branch,hour,lastPublished},
# the same pref-file pattern as digest. Push auth is the box's ambient git
# credentials — the verb never stores tokens.
#
# Usage:
#   5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]
#   5dive proof on --repo=<url> [--branch=status] [--at=<0-23>] [--user=<u>]
#   5dive proof off
#   5dive proof status [--json]
#   5dive proof tick        # cron driver; gated on the pref
#
# OSS-30: the daily cron runs as --user (default root). The cron's effective
# user must own the box's git push credentials — on boxes where root has none
# (creds live with a service user), pass --user=<that user>.

_proof_pref_file() { echo "${STATE_DIR}/proof.json"; }
# Overridable for isolated tests; the real path needs root to write.
_PROOF_CRON="${_PROOF_CRON:-/etc/cron.d/5dive-proof}"
_PROOF_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"
_PROOF_METHODOLOGY_URL="https://github.com/5dive-ai/5dive/blob/main/docs/zero-human.md"

_proof_pref_get() {
  # _proof_pref_get <jq-filter> [default] — read a field from proof.json.
  local f filt def; f="$(_proof_pref_file)"; filt="$1"; def="${2:-}"
  if [ -r "$f" ]; then jq -r "$filt // \"$def\"" "$f" 2>/dev/null || echo "$def"; else echo "$def"; fi
}

# _proof_repo_slug <repo-url> — OWNER/REPO from an https or ssh git URL (drops
# the .git suffix). Empty if it doesn't look like a github-style URL.
_proof_repo_slug() {
  local u="$1"
  u="${u%.git}"
  case "$u" in
    *github.com[:/]*) echo "${u#*github.com}" | sed -E 's#^[:/]+##' ;;
    *) echo "" ;;
  esac
}

# _proof_badge_snippet <repo-url> <branch> — the copy-paste README markdown for
# the shields endpoint badge, rendered from the USER'S OWN status branch (D5).
_proof_badge_snippet() {
  local repo="$1" branch="$2" slug raw tree
  slug="$(_proof_repo_slug "$repo")"
  if [ -n "$slug" ]; then
    raw="https://raw.githubusercontent.com/${slug}/${branch}/badge.json"
    tree="https://github.com/${slug}/tree/${branch}"
  else
    raw="https://raw.githubusercontent.com/<owner>/<repo>/${branch}/badge.json"
    tree="<your repo>/tree/${branch}"
  fi
  cat <<SNIP

Add this to your README (renders from YOUR status branch, updates itself):

[![zero-human](https://img.shields.io/endpoint?url=${raw})](${tree})

Methodology and limits: ${_PROOF_METHODOLOGY_URL}
SNIP
}

# _proof_build <repo> <branch> <dry> — clone the status branch, build the three
# files from the live digest verbatim, commit + push (unless dry). Echoes the
# one-line summary on success. Returns: 0 published, 3 already published today,
# non-zero on failure. First-publish (orphan branch) is detected by the caller.
_proof_build() {
  local repo="$1" branch="$2" dry="$3"
  local git_name git_email
  git_name="${ZH_GIT_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  git_email="${ZH_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"

  local self day_json week_json today today_label now_iso cli_version
  self="$(command -v 5dive 2>/dev/null || echo "$0")"
  day_json="$("$self" digest --json 2>/dev/null)"
  week_json="$("$self" digest --json --7d 2>/dev/null)"
  [ -n "$day_json" ] && [ -n "$week_json" ] || { echo "digest produced no output" >&2; return "$E_GENERIC"; }
  today="$(date -u +%F)"; today_label="$(date -u '+%b %-d')"; now_iso="$(date -u +%FT%TZ)"
  cli_version="$("$self" --version 2>/dev/null | head -1 | awk '{print $2}')"

  local work; work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  if git ls-remote --exit-code --heads "$repo" "$branch" >/dev/null 2>&1; then
    git clone --quiet --depth 200 --branch "$branch" --single-branch "$repo" "$work/repo" || return "$E_GENERIC"
    cd "$work/repo" || return "$E_GENERIC"
  else
    # first run: create the branch as an orphan so status history stays separate
    git clone --quiet --depth 1 "$repo" "$work/repo" || return "$E_GENERIC"
    cd "$work/repo" || return "$E_GENERIC"
    git checkout --quiet --orphan "$branch" || return "$E_GENERIC"
    git rm -rfq . 2>/dev/null || true
  fi
  [ -n "$git_name" ] && git config user.name "$git_name"
  [ -n "$git_email" ] && git config user.email "$git_email"

  # Build the three files from the digest output verbatim. The builder is the
  # honesty-critical core (unit-tested via tests/proof_publish_unit.sh, which
  # extracts this exact python block): it reads the digest numbers from the
  # environment and writes them out with NO edit path; exit 3 == already
  # published today (idempotent no-op).
  local summary rc
  set +e
  summary="$(DAY_JSON="$day_json" WEEK_JSON="$week_json" TODAY="$today" \
    TODAY_LABEL="$today_label" NOW_ISO="$now_iso" CLI_VERSION="$cli_version" \
    METHODOLOGY_URL="$_PROOF_METHODOLOGY_URL" \
    python3 <<'PROOFPY'
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

# Message is the self-shipped ratio over the rolling 7-day window,
# 1 - asks/shipped, with the shipped count as the sample size. One decimal,
# trailing .0 dropped. The window deliberately lives only in
# zero-human.json/history.jsonl so the badge stays tight. A week with more
# asks than ships goes negative and publishes anyway; a week with zero ships
# has no ratio, so the raw counts show instead.
if w_ship > 0:
    pct = (1 - w_ask / w_ship) * 100
    pct_str = f"{pct:.1f}".rstrip("0").rstrip(".")
    message = f"{pct_str}%"
else:
    message = f"0 shipped, {w_ask} {ask_word}"

badge = {"schemaVersion": 1, "label": "zero-human",
         "message": message, "color": "blueviolet"}

datapoint = {
    "generatedAtUtc": os.environ["NOW_ISO"],
    "date": today,
    "week": row["week"],
    "day": row["day"],
    "cumulative": cum,
    "cliVersion": os.environ["CLI_VERSION"],
    "source": "5dive digest --json [--7d]",
    "methodology": os.environ["METHODOLOGY_URL"],
}

hist_path.write_text("".join(json.dumps(h, sort_keys=True) + "\n" for h in hist))
pathlib.Path("badge.json").write_text(json.dumps(badge, indent=2) + "\n")
pathlib.Path("zero-human.json").write_text(json.dumps(datapoint, indent=2) + "\n")
pathlib.Path("README.md").write_text(
    "# status\n\n"
    "Machine-published zero-human proof for this company of agents.\n"
    "Written daily by `5dive proof publish`; methodology and limits: "
    f"{os.environ['METHODOLOGY_URL']}.\n\n"
    "- `badge.json` is what the README badge renders (shields.io endpoint schema)\n"
    "- `zero-human.json` is the full current datapoint\n"
    "- `history.jsonl` is every daily datapoint, append-only\n"
)
print(f"{today} (7d: {w_ship} shipped, {w_ask} {ask_word})")
PROOFPY
)"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] && return 3
  [ "$rc" -eq 0 ] || return "$rc"

  git add -A
  if git diff --cached --quiet; then echo "no changes"; return 0; fi
  if [ "$dry" = 1 ]; then
    echo "--dry-run: would commit 'status: $summary'"
    git diff --cached --stat
    echo "$summary"
    return 0
  fi
  git commit --quiet -m "status: $summary" || return "$E_GENERIC"
  git push --quiet origin "$branch" || return "$E_GENERIC"
  echo "$summary"
  return 0
}

# _proof_publish [--dry-run] [--repo=<url>] [--branch=<b>] — one-shot publish.
# repo/branch resolve: flag > proof.json config > ZH_REPO/ZH_BRANCH env (shim
# back-compat) > default. Prints the README badge snippet on a repo's first
# publish (D5). Exit 3 preserved for the already-published no-op.
_proof_publish() {
  local dry=0 repo="" branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --repo=*)  repo="${1#*=}" ;;
      --branch=*) branch="${1#*=}" ;;
      *) fail "$E_USAGE" "proof publish: unknown arg: $1" ;;
    esac
    shift
  done
  [ -n "$repo" ]   || repo="$(_proof_pref_get '.repo')"
  [ -n "$repo" ]   || repo="${ZH_REPO:-$_PROOF_DEFAULT_REPO}"
  [ -n "$branch" ] || branch="$(_proof_pref_get '.branch')"
  [ -n "$branch" ] || branch="${ZH_BRANCH:-status}"

  # first publish = the status branch doesn't exist on the remote yet.
  local first=0
  git ls-remote --exit-code --heads "$repo" "$branch" >/dev/null 2>&1 || first=1

  local rc=0
  _proof_build "$repo" "$branch" "$dry" || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "proof: already published today for $branch, nothing to do"
    return 3
  fi
  [ "$rc" -eq 0 ] || fail "$E_GENERIC" "proof publish: failed (rc=$rc) — nothing published"
  if [ "$first" -eq 1 ]; then
    _proof_badge_snippet "$repo" "$branch"
  fi
  # stamp lastPublished for `proof status` staleness (real publishes only).
  if [ "$dry" -ne 1 ]; then
    local f cur today; f="$(_proof_pref_file)"; today="$(date -u +%F)"
    if [ -w "$(dirname "$f")" ] 2>/dev/null || [ -w "$f" ] 2>/dev/null; then
      cur="$(cat "$f" 2>/dev/null || true)"; [ -n "$cur" ] || cur='{}'
      jq --arg d "$today" '.lastPublished=$d' <<<"$cur" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || true
    fi
  fi
  return 0
}

# _proof_install_cron <hour> [user] — idempotent cron that runs `proof tick`
# daily at <hour> as [user] (default root). Rewritten (never appended) so
# on/off/re-on is clean. OSS-30: the cron's effective user must own the box's
# git push credentials — on boxes where root has none, pass --user=<name>.
_proof_install_cron() {
  local hour="$1" user="${2:-root}"
  [ -d /etc/cron.d ] || { echo "proof: /etc/cron.d absent — skipping cron install" >&2; return 0; }
  cat > "$_PROOF_CRON" <<CRON
# 5dive zero-human proof publisher (OSS-17) — daily; gated on the per-box pref
# (${STATE_DIR}/proof.json). Removed by \`5dive proof off\`.
0 ${hour} * * * ${user} /usr/local/bin/5dive proof tick >> /var/log/5dive-proof.log 2>&1
CRON
  chmod 644 "$_PROOF_CRON"
}

# _proof_onoff <on|off|status> [--repo=] [--branch=] [--at=] — pref + cron mgmt.
_proof_onoff() {
  local sub="$1"; shift || true
  local repo="" branch="" hour="" user="" f; f="$(_proof_pref_file)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo=*)   repo="${1#*=}" ;;
      --branch=*) branch="${1#*=}" ;;
      --at=*)     hour="${1#*=}" ;;
      --user=*)   user="${1#*=}" ;;
      *) fail "$E_USAGE" "proof $sub: unknown arg: $1" ;;
    esac
    shift
  done
  local cur; cur="$(cat "$f" 2>/dev/null || true)"; [ -n "$cur" ] || cur='{"enabled":false,"branch":"status","hour":9}'

  case "$sub" in
    on)
      require_root
      [ -n "$repo" ] || repo="$(jq -r '.repo // ""' <<<"$cur")"
      [ -n "$repo" ] || fail "$E_USAGE" "proof on: --repo=<url> is required (no repo configured yet)"
      [ -n "$branch" ] || branch="$(jq -r '.branch // "status"' <<<"$cur")"
      [ -n "$hour" ] || hour="$(jq -r '.hour // 9' <<<"$cur")"
      # OSS-30: cron user carries git push creds; default root, persist across re-on.
      [ -n "$user" ] || user="$(jq -r '.user // "root"' <<<"$cur")"
      case "$hour" in ''|*[!0-9]*) fail "$E_USAGE" "proof on: --at must be an hour 0-23" ;; esac
      { [ "$hour" -ge 0 ] && [ "$hour" -le 23 ]; } || fail "$E_USAGE" "proof on: --at must be 0-23"
      id "$user" >/dev/null 2>&1 || fail "$E_USAGE" "proof on: --user=$user is not a known system user"
      mkdir -p "$(dirname "$f")"
      jq --arg r "$repo" --arg b "$branch" --argjson h "$hour" --arg u "$user" \
        '.enabled=true | .repo=$r | .branch=$b | .hour=$h | .user=$u' <<<"$cur" > "$f.tmp" && mv "$f.tmp" "$f"
      _proof_install_cron "$hour" "$user"
      local as=""; [ "$user" = "root" ] || as=" as ${user}"
      echo "proof: ON — daily ${hour}:00 → ${repo} (${branch})${as}"
      ;;
    off)
      require_root
      jq '.enabled=false' <<<"$cur" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || true
      rm -f "$_PROOF_CRON"
      echo "proof: OFF (cron removed, config kept)"
      ;;
    status)
      if [ "${JSON_MODE:-0}" = 1 ]; then
        jq -c '{enabled:(.enabled//false),repo:(.repo//null),branch:(.branch//"status"),hour:(.hour//9),lastPublished:(.lastPublished//null)}' <<<"$cur"
        return 0
      fi
      local enabled repo_c branch_c hour_c user_c last today staleness as
      enabled="$(jq -r '.enabled // false' <<<"$cur")"
      repo_c="$(jq -r '.repo // ""' <<<"$cur")"
      branch_c="$(jq -r '.branch // "status"' <<<"$cur")"
      hour_c="$(jq -r '.hour // 9' <<<"$cur")"
      user_c="$(jq -r '.user // "root"' <<<"$cur")"
      as=""; [ "$user_c" = "root" ] || as=" as ${user_c}"
      last="$(jq -r '.lastPublished // ""' <<<"$cur")"
      if [ "$enabled" = "true" ]; then
        echo "proof: ON — daily ${hour_c}:00 → ${repo_c} (${branch_c})${as}"
      elif [ -n "$repo_c" ]; then
        echo "proof: OFF (configured: ${repo_c} ${branch_c})"
      else
        echo "proof: OFF (not configured — run: 5dive proof on --repo=<url>)"
      fi
      if [ -n "$last" ]; then
        today="$(date -u +%F)"
        if [ "$last" = "$today" ]; then staleness="today"; else
          local d; d=$(( ( $(date -u -d "$today" +%s) - $(date -u -d "$last" +%s) ) / 86400 ))
          staleness="${d}d ago"
          [ "$enabled" = "true" ] && [ "$d" -gt 1 ] && staleness="${staleness} ⚠ STALE (pipeline may be broken)"
        fi
        echo "last published: ${last} (${staleness})"
      else
        echo "last published: never"
      fi
      [ -f "$_PROOF_CRON" ] && echo "cron: ${_PROOF_CRON} installed" || echo "cron: not installed"
      ;;
    *) fail "$E_USAGE" "proof: unknown subcommand: $sub" ;;
  esac
}

# _proof_tick — cron driver (root). Gated on the pref: only publishes when
# enabled. The publish is itself idempotent per-day (exit 3), so a double-fire
# is harmless. Best-effort: always returns 0 so a miss never spams cron mail.
_proof_tick() {
  local f; f="$(_proof_pref_file)"
  [ -r "$f" ] || return 0
  [ "$(jq -r '.enabled // false' "$f" 2>/dev/null)" = "true" ] || return 0
  _proof_publish >/dev/null 2>&1 || true
  return 0
}

cmd_proof() {
  case "${1:-}" in
    publish)       shift; _proof_publish "$@" ;;
    on|off|status) local _s="$1"; shift; _proof_onoff "$_s" "$@" ;;
    tick)          shift; _proof_tick "$@" ;;
    -h|--help|"")
      cat <<'HELP'
usage: 5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]
       5dive proof on --repo=<url> [--branch=status] [--at=<0-23>] [--user=<u>]
       5dive proof off
       5dive proof status [--json]
       5dive proof tick        # cron driver; gated on the pref

Publishes this box's zero-human proof (badge.json + zero-human.json +
history.jsonl) to a git status branch, computed VERBATIM from `5dive digest`.
There is no flag to edit a number — the no-edit path is the point. Publish is
idempotent per day (a re-run exits 3). See docs/zero-human.md for methodology.

--user sets the cron's effective user (default root). It must own the box's
git push credentials, or the nightly push fails silently as visible staleness.
HELP
      ;;
    *) fail "$E_USAGE" "proof: unknown subcommand: ${1:-} (publish|on|off|status|tick)" ;;
  esac
}
