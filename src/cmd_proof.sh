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

# _proof_ledger — OSS-38 autonomy ledger, MATERIALIZED from existing task data
# (no new capture path). One shipped action = a done standard task. It "needed a
# human" iff it carried a gate a HUMAN answered — the DIVE-1117 provenance floor:
# need_answered_by LIKE 'human:%' (answered through a human rail) OR a
# human_nonce_hash (a human tap token). A lead/agent clearance ('lead:*', a bare
# agent name, 'auto:*') is NOT an ask.
#
# NB we deliberately DON'T key off need_answered_uid: DIVE-756 captures that REAL
# uid on EVERY sudo'd answer (lead agents included) as tamper-evidence, so it is
# not a human marker — counting it would over-count asks and dishonestly
# understate autonomy (measured live: 76 uid-set vs 45 truly-human on a 312-ship
# board → 75% vs the honest ~86%). The whole point is an honest number.
#
# Core metric = 1 - asks/shipped (the autonomy %). Emits ONE compact JSON object
# on stdout; read-only, so `proof status` can call it locally. TASKS_DB is the
# test seam (point it at a fixture db).
_proof_ledger() {
  local db_file="${TASKS_DB:-${TASKS_DIR:-/var/lib/5dive/tasks}/tasks.db}"
  local shipped=0 asks=0 row=""
  if [ -r "$db_file" ]; then
    # Single row "shipped|asks"; COALESCE guards the all-NULL SUM on an empty set.
    row="$(db "SELECT COUNT(*) || '|' || COALESCE(SUM(
                 CASE WHEN need_type IS NOT NULL
                       AND (need_answered_by LIKE 'human:%'
                            OR (human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''))
                      THEN 1 ELSE 0 END), 0)
               FROM tasks
               WHERE status = 'done' AND kind = 'standard';" 2>/dev/null || true)"
    [ -n "$row" ] && { shipped="${row%%|*}"; asks="${row##*|}"; }
  fi
  case "$shipped" in ''|*[!0-9]*) shipped=0 ;; esac
  case "$asks"    in ''|*[!0-9]*) asks=0 ;; esac
  # pct = 1 - asks/shipped, one decimal, trailing .0 dropped. Null when no ships.
  local pct="null" pct_str=""
  if [ "$shipped" -gt 0 ]; then
    pct_str="$(awk -v a="$asks" -v s="$shipped" 'BEGIN{printf "%.1f", (1 - a/s)*100}')"
    pct_str="${pct_str%.0}"
    pct="$pct_str"
  fi
  jq -cn --argjson shipped "$shipped" --argjson asks "$asks" \
     --argjson autonomous "$((shipped - asks))" --argjson pct "$pct" \
     '{shipped:$shipped, asks:$asks, autonomous:$autonomous, autonomyPct:$pct}'
}

# _proof_publish_gate — LOAD-BEARING guardrail (OSS-39, olivia/lodar). A PUBLIC
# badge must never fire without lodar's explicit tap. The FIRST publish files an
# approval `task need` to lodar and BLOCKS; only a HUMAN-answered approve flips
# proof.json .publishApproved=true and lets the publish proceed. Idempotent: it
# reuses one approval task rather than re-filing on every attempt. Returns 0 to
# proceed, non-zero (blocked) otherwise. Test seam: _PROOF_GATE_SKIP=1 bypasses
# it for tests that exercise the publisher mechanics themselves.
_proof_publish_gate() {
  [ "${_PROOF_GATE_SKIP:-0}" = 1 ] && return 0
  local f cur approved ident
  f="$(_proof_pref_file)"; cur="$(cat "$f" 2>/dev/null || true)"; [ -n "$cur" ] || cur='{}'
  approved="$(jq -r '.publishApproved // false' <<<"$cur" 2>/dev/null || echo false)"
  [ "$approved" = "true" ] && return 0

  ident="$(jq -r '.approvalTaskIdent // ""' <<<"$cur" 2>/dev/null || echo "")"
  if [ -n "$ident" ]; then
    # An approval task already exists — is its gate HUMAN-answered 'approve'?
    local rec ans by nonce
    rec="$(db "SELECT COALESCE(need_answer,'') || X'1f' || COALESCE(need_answered_by,'') || X'1f'
                   || COALESCE(human_nonce_hash,'')
               FROM tasks WHERE ident = $(sqlq "$ident");" 2>/dev/null || true)"
    ans="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"
    by="${rec%%$'\x1f'*}"; nonce="${rec#*$'\x1f'}"
    # AUTHORIZING a public emission demands the STRONGEST human proof: the
    # DIVE-756/1448 human-tap nonce. A 'human:*' provenance string WITHOUT a nonce
    # (seen live on FUNNEA-3, main 2026-07-23) is NOT enough to flip the public
    # badge — the tap is the tamper-evident signal, the rail label alone is not.
    # This is deliberately STRICTER than the autonomy ledger, which inclusively
    # counts any human-answered gate (human:* OR nonce) as an ask: measuring "did
    # a human touch it" is inclusive; authorizing "go public" is strict.
    local human=0 approve=0
    [ -n "$nonce" ] && human=1
    case "$(printf '%s' "$ans" | tr 'A-Z' 'a-z')" in
      approve|approved|yes|ok|go|"go ahead") approve=1 ;;
    esac
    if [ "$human" = 1 ] && [ "$approve" = 1 ]; then
      cur="$(cat "$f" 2>/dev/null || echo '{}')"; [ -n "$cur" ] || cur='{}'
      jq '.publishApproved=true' <<<"$cur" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || true
      return 0
    fi
    if [ "$human" = 1 ] && [ -n "$ans" ]; then
      echo "proof publish: BLOCKED — lodar declined the public badge on ${ident} (answer: ${ans}). Nothing published." >&2
      return 1
    fi
    if [ -n "$ans" ]; then
      # Answered, but without a verifiable human-tap nonce (e.g. a human:* rail
      # answer that never satisfied the tap — the FUNNEA-3 shape). Do NOT authorize.
      echo "proof publish: BLOCKED — the approval on ${ident} (by=${by:-?}) has no verifiable human-tap nonce; not authorizing a public badge. Re-approve via the inline tap. Nothing published." >&2
      return 1
    fi
    echo "proof publish: BLOCKED — waiting on lodar's approval (gate on ${ident}). Nothing published." >&2
    return 1
  fi

  # No approval task yet — create one + file an approval gate to lodar, then block.
  local newident
  newident="$(JSON_MODE=1 cmd_task_add "Approve public zero-human proof badge" \
      --from=proof --priority=high \
      --body="First public fire of the zero-human proof badge (\`5dive proof publish\`). Emitting it puts a public-facing brand/comms artifact live, so it needs lodar's explicit approval before anything publishes. Approve once you're ready for the badge to go live; publishing stays enabled afterward." \
      2>/dev/null | jq -r '.data.ident // empty' 2>/dev/null || true)"
  if [ -z "$newident" ]; then
    echo "proof publish: BLOCKED — could not file the lodar approval gate; refusing to publish. Nothing published." >&2
    return 1
  fi
  cmd_task_need "$newident" --type=approval --from=proof \
    --ask="Approve publishing the PUBLIC zero-human proof badge? First public fire (brand/public-comms) — it goes live on your tap." \
    --recommend="approve" >/dev/null 2>&1 || true
  cur="$(cat "$f" 2>/dev/null || echo '{}')"; [ -n "$cur" ] || cur='{}'
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  jq --arg id "$newident" '.approvalTaskIdent=$id | .publishApproved=false' <<<"$cur" > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f" || true
  echo "proof publish: BLOCKED — the public badge needs lodar's approval. Filed an approval gate on ${newident} to lodar." >&2
  echo "  Nothing published. Once lodar taps approve, re-run \`5dive proof publish\` (or the daily tick) and it goes live." >&2
  return 1
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

# DIVE-1552: derive the rolling 7-day window from the append-only daily
# datapoints (which survive a board wipe), NOT the live-board WEEK_JSON set
# above. After the 2026-07-19 board wipe the live board lost pre-wipe history,
# so its 7d query under-counted (badge read 51/7 vs the true ~343/53). Daily
# datapoints are non-overlapping 24h counts (same basis as `cum`), so summing
# the last 7 is the true rolling week — and immune to future wipes.
_last7 = hist[-7:]
row["week"] = {
    "shipped": sum(h["day"]["shipped"] for h in _last7),
    "humanAsks": sum(h["day"]["humanAsks"] for h in _last7),
}

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

  # OSS-39 LOAD-BEARING guardrail: a real publish must clear the lodar approval
  # gate before anything public is emitted. A --dry-run builds locally and pushes
  # nothing, so it previews without the gate.
  if [ "$dry" -ne 1 ]; then
    _proof_publish_gate || return 1
  fi

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
      # OSS-38/39: the LOCAL autonomy badge, computed from the ledger. No clone,
      # no publish — `proof status` is read-only and never touches the network.
      local led; led="$(_proof_ledger)"
      if [ "${JSON_MODE:-0}" = 1 ]; then
        jq -c --argjson autonomy "$led" \
          '{autonomy:$autonomy, enabled:(.enabled//false), publishApproved:(.publishApproved//false), repo:(.repo//null), branch:(.branch//"status"), hour:(.hour//9), lastPublished:(.lastPublished//null)}' <<<"$cur"
        return 0
      fi
      local _ship _ask _apct
      _ship="$(jq -r '.shipped' <<<"$led")"; _ask="$(jq -r '.asks' <<<"$led")"
      _apct="$(jq -r '.autonomyPct // empty' <<<"$led")"
      if [ -n "$_apct" ]; then
        echo "autonomy: ${_apct}% — ${_ship} shipped, ${_ask} needed a human (lifetime, 1 − asks/shipped)"
      else
        echo "autonomy: no shipped actions yet"
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
usage: 5dive proof status [--json]                    # LOCAL autonomy badge + config (no network)
       5dive proof on --repo=<url> [--branch=status] [--at=<0-23>] [--user=<u>]
       5dive proof off
       5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]
       5dive proof tick        # cron driver; gated on the pref

`proof status` shows this company's autonomy badge — 1 − asks/shipped over the
lifetime ledger (OSS-38), materialized from task data: a shipped action is a
done task; it "needed a human" only if it carried a gate a HUMAN answered (a
lead/agent clearance does not count). Read-only, local, no publish.

`proof publish` writes the badge (badge.json + zero-human.json + history.jsonl)
to a git status branch, computed VERBATIM from `5dive digest` — there is no flag
to edit a number, the no-edit path is the point; idempotent per day (re-run
exits 3). GUARDRAIL: publishing is a PUBLIC brand/comms act, so the FIRST fire
files an approval gate to lodar and BLOCKS — no badge goes live without lodar's
tap. `proof on/off` toggle the daily publisher; `--user` sets the cron's
effective user (default root), which must own the box's git push credentials or
the nightly push fails silently as visible staleness. See docs/zero-human.md.
HELP
      ;;
    *) fail "$E_USAGE" "proof: unknown subcommand: ${1:-} (publish|on|off|status|tick)" ;;
  esac
}
