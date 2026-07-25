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
# Where the installed cron sends the tick's output. Overridable for tests.
_PROOF_LOG="${_PROOF_LOG:-/var/log/5dive-proof.log}"
_PROOF_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"
_PROOF_METHODOLOGY_URL="https://github.com/5dive-ai/5dive/blob/main/docs/zero-human.md"

_proof_pref_get() {
  # _proof_pref_get <jq-filter> [default] — read a field from proof.json.
  local f filt def; f="$(_proof_pref_file)"; filt="$1"; def="${2:-}"
  if [ -r "$f" ]; then jq -r "$filt // \"$def\"" "$f" 2>/dev/null || echo "$def"; else echo "$def"; fi
}

# _proof_host — the box's own name, for the publisher identity stamp (DIVE-1888).
_proof_host() { hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown"; }

# _proof_state_writable — CAN the current user persist proof.json at all?
# Echoes the mechanism: "dir" (writable dir → atomic tmp+rename), "file"
# (only the file itself is writable → truncate in place), or "" (neither).
# The "file" fallback is what lets a LOCKED-DOWN state dir still work: on a box
# where ${STATE_DIR} is root-owned with no group write (holding agents.json,
# auth-sessions, …), granting group-write on the single proof.json file is
# enough, instead of opening the whole directory to every agent user.
_proof_state_writable() {
  local f dir; f="$(_proof_pref_file)"; dir="$(dirname "$f")"
  if [ -d "$dir" ] && [ -w "$dir" ]; then echo dir
  elif [ -f "$f" ] && [ -w "$f" ]; then echo file
  else echo ""; fi
}

# _proof_pref_write <jq-args...> — persist a mutation to proof.json, LOUDLY.
#
# DIVE-1888: this replaces five hand-rolled `jq … > "$f.tmp" && mv … || true`
# write sites that ALL failed for two weeks without anyone noticing, in two
# different silent ways: the lastPublished stamp sat behind a `[ -w ]` guard
# that SKIPPED the write with no output at all (a defensive guard that erased
# its own evidence), and the rest let the redirection error escape to the log
# and then returned 0 anyway via `|| true`. Root cause was a permission:
# ${STATE_DIR} was root:<group> with no group-write while the publisher ran as
# a non-root user. State that cannot be persisted must SAY SO and must not
# report success — a publisher that silently forgets it ran is worse than one
# that crashes, because staleness monitoring is built on the state it forgets.
_proof_pref_write() {
  local f dir cur out tmp mode
  f="$(_proof_pref_file)"; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || true
  cur="$(cat "$f" 2>/dev/null || true)"; [ -n "$cur" ] || cur='{}'
  out="$(jq "$@" <<<"$cur" 2>/dev/null)" || out=""
  [ -n "$out" ] || { echo "proof: refusing to write ${f} — jq produced nothing. State NOT saved." >&2; return 1; }

  mode="$(_proof_state_writable)"
  case "$mode" in
    dir)
      tmp="$(mktemp "${f}.tmp.XXXXXX" 2>/dev/null)" \
        || { echo "proof: cannot create a temp file in ${dir}. State NOT saved." >&2; return 1; }
      # Carry the existing owner/mode onto the replacement — otherwise a
      # root-run write silently strips the group-write bit the non-root
      # publisher depends on, re-breaking the exact bug this fixes.
      if [ -f "$f" ]; then
        chown --reference="$f" "$tmp" 2>/dev/null || true
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp" 2>/dev/null || true
      else
        chmod 0644 "$tmp" 2>/dev/null || true
      fi
      if ! printf '%s\n' "$out" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$f" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        echo "proof: could not replace ${f} (as $(id -un)). State NOT saved." >&2
        return 1
      fi
      ;;
    file)
      printf '%s\n' "$out" > "$f" 2>/dev/null \
        || { echo "proof: could not write ${f} (as $(id -un)). State NOT saved." >&2; return 1; }
      ;;
    *)
      echo "proof: CANNOT PERSIST STATE — ${f} is not writable by $(id -un), and neither is ${dir}." >&2
      echo "proof: every publish will look like it worked and then forget it ran (\`proof status\` stays on 'last published: never')." >&2
      echo "proof: fix with:  sudo chgrp $(id -gn 2>/dev/null || echo '<your-group>') ${f} && sudo chmod g+w ${f}" >&2
      return 1
      ;;
  esac
  return 0
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
      # Not fatal if it can't persist: the approval is re-derived from $ident on
      # every run, so publishing still proceeds. But say it out loud.
      _proof_pref_write '.publishApproved=true' \
        || echo "proof publish: approval NOT cached in ${f}; it will be re-read from ${ident} every run." >&2
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
  # If THIS write is lost the verb re-files a brand-new approval task on every
  # single run, so the failure has to be shouted, not swallowed.
  _proof_pref_write --arg id "$newident" '.approvalTaskIdent=$id | .publishApproved=false' \
    || echo "proof publish: ${newident} was NOT recorded in ${f} — every future run will file ANOTHER approval task. Fix the permission above first." >&2
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

  local self day_json week_json today now_iso cli_version
  self="$(command -v 5dive 2>/dev/null || echo "$0")"
  day_json="$("$self" digest --json 2>/dev/null)"
  week_json="$("$self" digest --json --7d 2>/dev/null)"
  [ -n "$day_json" ] && [ -n "$week_json" ] || { echo "digest produced no output" >&2; return "$E_GENERIC"; }
  # DIVE-1908: today_label ("%b %-d") was computed and exported for years and
  # read by NOTHING — which is how the missing badge date stayed invisible. The
  # badge now uses $today (full ISO) directly, so the label is dead again and is
  # removed rather than left lying around to imply a consumer that isn't there.
  #
  # ONE clock read, and $today is DERIVED from it rather than computed by a
  # second `date -u`. Two independent computations that merely happen to agree
  # are exactly what drifts — and across a midnight boundary two calls can
  # genuinely disagree. This way badge.json's date, zero-human.json's `date` and
  # its `generatedAtUtc` all describe the same instant structurally, so the
  # equality the test asserts is wiring rather than a formatting convention.
  now_iso="$(date -u +%FT%TZ)"; today="${now_iso%%T*}"
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
  # extracts this exact python block): it reads the digest numbers from a file
  # pointer (env fallback) and writes them out with NO edit path; exit 3 ==
  # already published today (idempotent no-op).
  local summary rc
  set +e
  # DIVE-1864: pass the digest JSON to python via files, not env vars. A single
  # environment string over MAX_ARG_STRLEN (32 * page = 128KB) makes the exec
  # fail with E2BIG ("Argument list too long"); week_json crossed 128KB as the
  # ledger grew, silently breaking every publish. Files carry the numbers
  # verbatim with no size limit. Written under $work (NOT cwd=$work/repo) so the
  # later `git add -A` never commits them. The python still falls back to the
  # inline DAY_JSON/WEEK_JSON env vars when no *_FILE is set (the unit harness).
  printf '%s' "$day_json"  > "$work/day.json"
  printf '%s' "$week_json" > "$work/week.json"
  summary="$(DAY_JSON_FILE="$work/day.json" WEEK_JSON_FILE="$work/week.json" TODAY="$today" \
    NOW_ISO="$now_iso" CLI_VERSION="$cli_version" \
    PUB_HOST="$(_proof_host)" PUB_USER="$(id -un)" \
    METHODOLOGY_URL="$_PROOF_METHODOLOGY_URL" \
    python3 <<'PROOFPY'
import json, os, pathlib, sys

def _load(name):
    """Digest JSON arrives via a *_FILE pointer (no MAX_ARG_STRLEN cap); fall
    back to the inline env var for the unit harness / shim callers."""
    path = os.environ.get(name + "_FILE")
    if path:
        return json.loads(pathlib.Path(path).read_text())
    return json.loads(os.environ[name])

day = _load("DAY_JSON")
week = _load("WEEK_JSON")
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

# DIVE-1888: stamp WHO published, into the append-only history as well as the
# current datapoint. A version field DATES an artifact, it does not IDENTIFY
# its author — reading cliVersion as identity is exactly what sent the
# DIVE-1865 publisher hunt to a machine that did not exist. host+user is the
# identity. Additive-only, per the zero-human.json API contract.
_pub = {k: v for k, v in (("host", os.environ.get("PUB_HOST", "")),
                          ("user", os.environ.get("PUB_USER", ""))) if v}
if _pub:
    row["publishedBy"] = _pub
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

# DIVE-1908: the badge carries its OWN date. The standing design claim was that
# a dead publisher stops the date moving and "a stale date IS the alarm" — but
# the date lived only in zero-human.json, which no README reader ever fetches.
# badge.json had no date at all, so it rendered a stale number as CURRENT for as
# long as the publisher stayed dead. That is our own defect class aimed at the
# honesty instrument: the credibility artifact misrepresenting its own freshness.
#
# The date is appended to BOTH message branches deliberately — a zero-ship week
# is exactly when someone would want to know how old the number is, so the date
# must never be the thing that drops out when the reading gets unusual.
#
# Full ISO date, not a "Jul 25" label. This artifact's entire job is making
# staleness visible to a reader who has NONE of our instrumentation, and a
# month-day label is unambiguous only inside a 12-month window — a known-wrong
# reading on the one artifact that exists in order not to be wrong. Pointing at
# the internal hourly monitor as mitigation would be the very move that produced
# this bug: "a stale date IS the alarm" was internal reasoning about an external
# artifact. Better to delete the limit than document it.
#
# It is literally `today` — the SAME string that becomes datapoint["date"] just
# below — so the badge and zero-human.json agree by being identical, not by
# surviving a format transformation that could drift. That is why this reads
# `today` rather than the TODAY_LABEL the shell used to derive for it.
#
# A DATE, never an AGE. A date is a FACT the artifact carries; an age ("2d ago")
# is an ASSERTION that decays the moment it stops being rewritten. A dead
# publisher frozen at "0d ago" would be actively LYING, where a frozen date is
# merely stale and the reader can see it. Same reason there is no publisher-set
# "stale" flag: a dead publisher cannot mark itself dead. Freshness has to be
# readable from the last value the publisher WROTE, never from a status it would
# have to keep updating while broken.
badge = {"schemaVersion": 1, "label": "zero-human",
         "message": f"{message} · {today}",
         "color": "blueviolet"}

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
if _pub:
    datapoint["publishedBy"] = _pub

hist_path.write_text("".join(json.dumps(h, sort_keys=True) + "\n" for h in hist))
# ensure_ascii=False so the middot stays a middot instead of a \u00b7 escape —
# badge.json is read by shields (which parses JSON fine either way) but also by
# humans checking whether the badge is stale, and that is the whole point of it.
pathlib.Path("badge.json").write_text(json.dumps(badge, indent=2, ensure_ascii=False) + "\n")
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
  # Stamp lastPublished (+ WHO published, DIVE-1888) for `proof status`
  # staleness. This used to be wrapped in a `[ -w ]` guard that skipped the
  # write in total silence — the single line that hid the whole bug. It is now
  # unguarded and FATAL: a publish that cannot record that it ran must not
  # report success, because staleness monitoring reads exactly this field.
  if [ "$dry" -ne 1 ]; then
    if ! _proof_pref_write --arg d "$(date -u +%F)" --arg h "$(_proof_host)" --arg u "$(id -un)" \
           '.lastPublished=$d | .lastPublishedBy={host:$h,user:$u}'; then
      echo "proof publish: the push SUCCEEDED but the state write did not — \`proof status\` will keep reporting stale/never and the staleness alarm is blind. Reporting failure deliberately." >&2
      return "$E_GENERIC"
    fi
  fi
  return 0
}

# _proof_install_cron <hour> [user] — idempotent cron that runs `proof tick`
# daily at <hour> as [user] (default root). Rewritten (never appended) so
# on/off/re-on is clean. OSS-30: the cron's effective user must own the box's
# git push credentials — on boxes where root has none, pass --user=<name>.
_proof_install_cron() {
  local hour="$1" user="${2:-root}" log="$_PROOF_LOG"
  [ -d /etc/cron.d ] || { echo "proof: /etc/cron.d absent — skipping cron install" >&2; return 0; }
  # DIVE-1888: the cron line redirects into $log, and the shell opens that file
  # AS ${user} BEFORE /usr/local/bin/5dive ever runs. On this box the file was
  # root:root 0644 while the publisher runs as a non-root user, so the whole
  # command would have died on the redirect — before the publisher started, with
  # cron mail as the only signal. Same shape as the DIVE-1896 monitor failure:
  # a destination nobody proved. Prove it HERE, while we still have root, rather
  # than discovering it at 02:40. Best-effort by design: a box without the log
  # still gets its cron, it just gets told the output has nowhere to go.
  if : >> "$log" 2>/dev/null \
     || { mkdir -p "$(dirname "$log")" 2>/dev/null && : >> "$log" 2>/dev/null; }; then
    if [ "$user" != "root" ] && ! chown "$user" "$log" 2>/dev/null; then
      echo "proof: WARNING — could not chown ${log} to ${user}; the cron cannot open it, so its output (including publish failures) is lost." >&2
    fi
  else
    echo "proof: WARNING — cannot create ${log}; the cron redirects there and will fail on the redirect before publishing anything." >&2
  fi
  cat > "$_PROOF_CRON" <<CRON
# 5dive zero-human proof publisher (OSS-17) — daily; gated on the per-box pref
# (${STATE_DIR}/proof.json). Removed by \`5dive proof off\`.
0 ${hour} * * * ${user} /usr/local/bin/5dive proof tick >> ${log} 2>&1
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
      _proof_pref_write --arg r "$repo" --arg b "$branch" --argjson h "$hour" --arg u "$user" \
        '.enabled=true | .repo=$r | .branch=$b | .hour=$h | .user=$u' \
        || fail "$E_GENERIC" "proof on: could not persist ${f} — nothing enabled"
      _proof_install_cron "$hour" "$user"
      local as=""; [ "$user" = "root" ] || as=" as ${user}"
      echo "proof: ON — daily ${hour}:00 → ${repo} (${branch})${as}"
      # THE TRAP (DIVE-1888): repointing the publisher at a non-root user LOOKS
      # like it worked even when that user cannot write the state file — this
      # command runs as root, so it persists fine and tells you nothing. Check
      # writability AS the configured user, here, once, loudly.
      if [ "$user" != "root" ] && command -v runuser >/dev/null 2>&1; then
        if ! runuser -u "$user" -- test -w "$f" 2>/dev/null \
           && ! runuser -u "$user" -- test -w "$(dirname "$f")" 2>/dev/null; then
          echo "proof: WARNING — ${user} cannot write ${f}, so its publishes will not persist lastPublished (they will look fine and forget they ran)." >&2
          echo "proof: fix with:  chgrp $(id -gn "$user" 2>/dev/null || echo "$user") ${f} && chmod g+w ${f}" >&2
        fi
      fi
      ;;
    off)
      require_root
      _proof_pref_write '.enabled=false' \
        || echo "proof: the cron is removed but ${f} still says enabled — the pref did not persist." >&2
      rm -f "$_PROOF_CRON"
      echo "proof: OFF (cron removed, config kept)"
      ;;
    status)
      # OSS-38/39: the LOCAL autonomy badge, computed from the ledger. No clone,
      # no publish — `proof status` is read-only and never touches the network.
      local led; led="$(_proof_ledger)"
      if [ "${JSON_MODE:-0}" = 1 ]; then
        jq -c --argjson autonomy "$led" --arg wr "$(_proof_state_writable)" \
          '{autonomy:$autonomy, enabled:(.enabled//false), publishApproved:(.publishApproved//false), repo:(.repo//null), branch:(.branch//"status"), hour:(.hour//9), lastPublished:(.lastPublished//null), lastPublishedBy:(.lastPublishedBy//null), stateWritable:($wr != "")}' <<<"$cur"
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
        local by; by="$(jq -r 'if .lastPublishedBy then " by \(.lastPublishedBy.user // "?")@\(.lastPublishedBy.host // "?")" else "" end' <<<"$cur" 2>/dev/null || echo "")"
        echo "last published: ${last} (${staleness})${by}"
      else
        echo "last published: never"
      fi
      # DIVE-1888: "never" is ambiguous — it reads identically whether nothing
      # has ever published or every publish was unable to record that it did.
      # Say which.
      if [ -z "$(_proof_state_writable)" ]; then
        echo "state: ⚠ ${f} is NOT writable by $(id -un) — publishes cannot persist, so the line above is not evidence of anything"
      fi
      [ -f "$_PROOF_CRON" ] && echo "cron: ${_PROOF_CRON} installed" || echo "cron: not installed"
      ;;
    *) fail "$E_USAGE" "proof: unknown subcommand: $sub" ;;
  esac
}

# _proof_tick — cron driver. Gated on the pref: only publishes when enabled.
# The publish is itself idempotent per-day (exit 3), so a double-fire is harmless.
#
# NB (DIVE-1888): this verb has **no live caller on the 5dive box**. Its only
# caller is the cron that `proof on` installs, and that cron was removed under
# DIVE-1865; the real 02:40 publisher invokes `proof publish` directly from an
# agent session. Anything re-wiring the publisher (DIVE-1889) should target
# `proof publish`, or re-install the cron via `proof on` — do not assume a tick
# is running just because this function exists.
#
# It no longer swallows failures. The old body was
# `_proof_publish >/dev/null 2>&1 || true`, which discarded BOTH the message and
# the exit code — the state-write failure this release makes fatal would have
# died right here, which is the whole defect class. stdout stays quiet (a cron
# should be silent on success) while stderr AND the exit code escape, so a
# failing tick is visible to whatever runs it even if its log is unreadable.
# The old "always return 0 so a miss never spams cron mail" trade is exactly
# backwards: cron mail is a channel, silence is not. Exit 3 (already published
# today) is a genuine success for a scheduled run and is mapped to 0.
_proof_tick() {
  local f rc=0; f="$(_proof_pref_file)"
  [ -r "$f" ] || return 0
  [ "$(jq -r '.enabled // false' "$f" 2>/dev/null)" = "true" ] || return 0
  _proof_publish >/dev/null || rc=$?
  [ "$rc" -eq 3 ] && rc=0
  return "$rc"
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
