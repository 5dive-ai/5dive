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
#
# `proof publish` exit contract (verb-local, NOT the global error_codes table):
#   0  published
#   3  already published today — a healthy no-op
#   4  REFUSED: no publishing identity configured (DIVE-2051)
#   *  other failure
# 3 and 4 are deliberately distinct and must stay that way. They are semantic
# opposites — "everything is fine and already done" vs "your config is broken
# and I refused" — and the caller that cannot tell them apart is the cron:
# _proof_tick maps 3 to success, so a refusal sharing that code would report a
# permanently broken box as a healthy night, which is the DIVE-2044 silent-stop
# shape (26h of no publishes read as business as usual). Asserted by
# tests/proof_identity_guard_unit.sh so they cannot converge again.
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
#   5dive proof tick [--log=<path>]   # cron driver; gated on the pref
#
# `tick --log=` writes its own run record (one stamped line per outcome, success
# included) and falls back to journald when the path is unwritable. The cron line
# carries NO shell redirect: DIVE-2044 lost 26h of publishes to a `>>` that the
# shell opened, and failed, before the publisher ever ran.
#
# OSS-30: the daily cron runs as --user (default root). The cron's effective
# user must own the box's git push credentials — on boxes where root has none
# (creds live with a service user), pass --user=<that user>.

# DIVE-2080. `five_self_bundle` lives in src/lib/self.sh, concatenated ahead of this
# file in the bundle — so in the built artifact this block is dead. It exists for the
# unit harnesses that source ONLY this file out of the split tree: without it the call
# sites below would die as command-not-found, which is how a "resolve myself honestly"
# rule turns back into a silent wrong answer.
if ! declare -F five_self_bundle >/dev/null 2>&1; then
  _five_self_lib="$(dirname -- "${BASH_SOURCE[0]}")/lib/self.sh"
  # shellcheck source=lib/self.sh
  [[ -r "$_five_self_lib" ]] && source "$_five_self_lib"
  unset _five_self_lib
fi

_proof_pref_file() { echo "${STATE_DIR}/proof.json"; }
# Overridable for isolated tests; the real path needs root to write.
_PROOF_CRON="${_PROOF_CRON:-/etc/cron.d/5dive-proof}"
# Where the installed cron sends the tick's output. Overridable for tests.
_PROOF_LOG="${_PROOF_LOG:-/var/log/5dive-proof.log}"
_PROOF_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"
# DIVE-2051: resolved publishing identity (set by _proof_identity). Declared
# here so `set -u` holds on every read path, including `proof status`.
_PROOF_ID_NAME=""; _PROOF_ID_EMAIL=""; _PROOF_ID_SOURCE=""; _PROOF_ID_UNCHECKED=0
# The refusal's OWN exit code, separate from 3 (idempotent no-op) — see the exit
# contract at the top of this file. Verb-local by design: `proof publish` already
# owns 3 for its no-op, so its codes are read against that contract and not
# against the global error_codes table (where 4 is E_NOT_FOUND).
_PROOF_RC_NO_IDENTITY=4
# DIVE-2044: the tick's own "I did not even try" code — not configured, or the
# pref says disabled. Produced only by _proof_tick_run before any publish, so it
# cannot collide with a _proof_publish code. It exists because the first cut
# returned plain 0 here and the run record then read "PUBLISHED" on a box that
# published nothing: the exact defect this ticket is about, rebuilt inside its
# own fix. A skip and a success must never share a value.
_PROOF_RC_TICK_SKIP=5
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
# DIVE-2119 — the two arms are guarded DIFFERENTLY, on purpose:
#
#   need_answered_by arm  → now requires need_answered_at IS NOT NULL.
#     This arm asks "did a human ANSWER this?", and until now it read the
#     answerer without checking that anyone answered — so a re-filed gate wearing
#     the PREVIOUS gate's `human:*` provenance (DIVE-2094's re-file residue) would
#     have counted an ask that never happened. Latent, not live: measured 0 rows
#     in this partition on the live board (it also requires status='done' AND
#     kind='standard'), so adding the guard moves the published number by zero
#     today and closes the channel for good. Every other reader of
#     need_answered_by in the tree already guards on need_answered_at first;
#     this was the one that didn't.
#
#   human_nonce_hash arm  → deliberately NOT guarded on need_answered_at.
#     A minted nonce means the gate was DELIVERED to a human for a tap. Work that
#     stopped on a human and got no answer still needed a human — arguably more
#     so — and counting it keeps the autonomy number CONSERVATIVE (an unanswered
#     ask stays an ask, so the badge understates autonomy rather than flattering
#     it). Adding the guard here would have silently RAISED a published metric by
#     dropping 5 live rows from the ask count, which is not a change to make as a
#     side effect of a residue fix. The residue risk this arm did carry is closed
#     at the source instead: DIVE-2119 resets human_nonce_hash whenever a gate is
#     retired (_gate_archive_and_clear_sql), so a surviving nonce now always
#     belongs to the gate being counted.
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
                       AND ((need_answered_at IS NOT NULL
                             AND need_answered_by LIKE 'human:%')
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

# _proof_identity [user] — resolve the identity this box AUTHORS PUBLIC COMMITS
# WITH, and record where it came from. Sets _PROOF_ID_NAME / _PROOF_ID_EMAIL /
# _PROOF_ID_SOURCE; an empty source means nothing resolved.
#
# DIVE-2051. Precedence, most explicit first:
#   1. ZH_GIT_NAME / ZH_GIT_EMAIL           env — per-invocation pin
#   2. proof.json .identity.{name,email}    `proof on --as-name= --as-email=`
#   3. git config --global user.{name,email} of the publishing user
#
# Why this is not plumbing: these commits are public and permanent. A box with
# no identity of its own leaves the author to be resolved by whoever is holding
# the terminal — and for an agent the most available value is the operator's
# personal email, which Claude Code injects into every agent's system prompt by
# default with no opt-out (anthropics/claude-code#81138). So layer 3 is the LAST
# resort, and "nothing resolved" is a refusal, never a guess (see _proof_build).
#
# [user] resolves layer 3 AS that user instead of the caller: `proof on` runs as
# root while the cron publishes as --user, and root's ~/.gitconfig says nothing
# about theirs. Checking as the caller is how you get a green configure and a
# broken 02:00 publish.
_proof_identity() {
  local as="${1:-}" gname="" gemail="" cname cemail
  _PROOF_ID_UNCHECKED=0
  if [ -n "$as" ] && [ "$as" != "$(id -un 2>/dev/null)" ]; then
    if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1; then
      gname="$(runuser -u "$as" -- git config --global user.name 2>/dev/null || true)"
      gemail="$(runuser -u "$as" -- git config --global user.email 2>/dev/null || true)"
    else
      # Another user's ~/.gitconfig is unreadable without root. Record that the
      # check did not run — reporting "unset" here would be a false alarm about
      # a box that is fine, which is the same defect as a false green pointed
      # the other way: a claim about a check that never happened.
      _PROOF_ID_UNCHECKED=1
    fi
  else
    gname="$(git config --global user.name 2>/dev/null || true)"
    gemail="$(git config --global user.email 2>/dev/null || true)"
  fi
  cname="$(_proof_pref_get '.identity.name')"
  cemail="$(_proof_pref_get '.identity.email')"

  _PROOF_ID_NAME="${ZH_GIT_NAME:-${cname:-$gname}}"
  _PROOF_ID_EMAIL="${ZH_GIT_EMAIL:-${cemail:-$gemail}}"
  # The source is named off the EMAIL — that is the field carrying the PII.
  if   [ -n "${ZH_GIT_EMAIL:-}" ]; then _PROOF_ID_SOURCE="env ZH_GIT_EMAIL"
  elif [ -n "$cemail" ];           then _PROOF_ID_SOURCE="proof.json identity"
  elif [ -n "$gemail" ];           then _PROOF_ID_SOURCE="git config --global (${as:-$(id -un 2>/dev/null)})"
  else                                  _PROOF_ID_SOURCE=""
  fi
}

# _proof_identity_help [user] — what to run when no identity resolved. Printed
# on refusal and on the `proof on` warning, so the fix is never a guess either.
_proof_identity_help() {
  local as="${1:-$(id -un 2>/dev/null)}"
  cat <<HELP
proof publish: NO GIT IDENTITY CONFIGURED — refusing to author public commits
  as an inferred identity. Nothing was published.
  Whatever address this box happens to have lying around would otherwise become
  the permanent, public author of the badge history. Pin one explicitly:

    5dive proof on --as-name="acme status bot" --as-email="bot@users.noreply.github.com"
    ZH_GIT_NAME=… ZH_GIT_EMAIL=… 5dive proof publish
    (as ${as}) git config --global user.name/user.email

  Prefer a role address you are content to see in public git history forever —
  GitHub's <user>@users.noreply.github.com form is the usual choice. Do NOT
  point it at a personal inbox just to get past this message.
HELP
}

# _proof_build <repo> <branch> <dry> — clone the status branch, build the three
# files from the live digest verbatim, commit + push (unless dry). Echoes the
# one-line summary on success. Returns: 0 published, 3 already published today,
# 4 no publishing identity, non-zero on other failure. First-publish (orphan
# branch) is detected by the caller.
_proof_build() {
  local repo="$1" branch="$2" dry="$3"
  local git_name git_email
  _proof_identity
  git_name="$_PROOF_ID_NAME"; git_email="$_PROOF_ID_EMAIL"

  # DIVE-2051: refuse BEFORE any work, including under --dry-run — a dry run
  # that quietly skips the check is how the box first learns it is misconfigured
  # at 02:00 from cron. A half identity (name, no email) refuses too: git would
  # fill the gap with a synthesized user@hostname, which is the same guess in a
  # different costume.
  if [ -z "$git_name" ] || [ -z "$git_email" ]; then
    _proof_identity_help >&2
    return 4
  fi

  local self day_json week_json today now_iso cli_version
  # DIVE-2080: the published badge IS the evidence, so it must be computed by the
  # bundle that is publishing it. `command -v 5dive` sat here and handed the job to
  # whatever was installed on the box — a badge describing a different artifact.
  self="$(five_self_bundle)" \
    || { echo "proof badges: could not identify the running 5dive bundle to compute the digest" >&2; return "$E_GENERIC"; }
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
  git config user.name "$git_name"
  git config user.email "$git_email"

  # DIVE-2654 (spec settled in DIVE-2652): two denominator-side corroborator
  # fields ship alongside the badge inside zero-human.json — the badge MESSAGE
  # itself stays untouched (DIVE-1924), only the JSON gains fields. Both share
  # the badge's own rolling 7d window so a reader never reconciles a third span.
  #
  # LEAD — verifier first-pass rate, carrying its own coverage (how much of the
  # window's shipped standard work got graded at all, same shipped_db source as
  # `proof scorecard`'s tier coverage) and the iteration-NULL disclosure: a NULL
  # iteration reads as first-pass (COALESCE(iteration,1)<=1), which biases the
  # rate UP by however many of the graded rows that affects.
  local sql_window="-7 days" corr_rows
  corr_rows="$(db "SELECT
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window"))) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND verifier IS NOT NULL AND verifier<>'') || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND verifier IS NOT NULL AND verifier<>'' AND COALESCE(iteration,1)<=1) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND verifier IS NOT NULL AND verifier<>'' AND iteration IS NULL);" 2>/dev/null || true)"

  # SECOND — policy-blocked attempts, carrying the fired-vs-instrumented site
  # split (a silent site is not evidence of compliance, DIVE-1922) and the
  # ledger's own age (a young ledger has no baseline to compare against yet).
  # Rollback is DROPPED per DIVE-2652: its aggregate has never moved, so it
  # cannot constrain the claim in either direction.
  local corr_refusals="" corr_fired_win="" corr_fired_life="" corr_sites="" corr_since=""
  if [ "$(db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='policy_refusals' LIMIT 1;" 2>/dev/null)" = "1" ]; then
    corr_refusals="$(db "SELECT COUNT(*) FROM policy_refusals WHERE ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    corr_fired_win="$(db "SELECT COUNT(DISTINCT policy) FROM policy_refusals WHERE ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    corr_fired_life="$(db "SELECT COUNT(DISTINCT policy) FROM policy_refusals;" 2>/dev/null || true)"
    corr_since="$(db "SELECT COALESCE(MIN(ts),'') FROM policy_refusals;" 2>/dev/null || true)"
    # Same grep `proof scorecard` uses: instrumented sites are DERIVED from the
    # resolved bundle, not hand-maintained, so the denominator cannot drift out
    # from under the count.
    corr_sites="$( { grep -oE 'policy_refuse "[^"]+" [a-z0-9-]+' "$self" 2>/dev/null || true; } \
                 | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')"
  fi

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
    CORR_ROWS="$corr_rows" \
    CORR_REFUSALS="$corr_refusals" CORR_FIRED_WINDOW="$corr_fired_win" \
    CORR_FIRED_LIFETIME="$corr_fired_life" CORR_SITES="$corr_sites" \
    CORR_LEDGER_SINCE="$corr_since" \
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

# DIVE-2654 (spec: DIVE-2652) — two denominator-side corroborator fields, so
# the badge is not published bare. Same honesty rule as `proof scorecard`: a
# number ships only with the sample/coverage it rests on, or it degrades to an
# explicit no-data marker naming why — never a bare 0.
corroborators = {}

_cr = (os.environ.get("CORR_ROWS") or "").strip().split("|")
def _corr_int(i):
    try: return int(_cr[i])
    except Exception: return None

shipped_db, graded_db, first_pass_db, iter_null_db = (
    _corr_int(0), _corr_int(1), _corr_int(2), _corr_int(3))

if graded_db:
    fp_entry = {
        "value": f"{round(first_pass_db / graded_db * 100, 1)}%",
        "window": "7d",
        "firstPass": first_pass_db,
        "graded": graded_db,
    }
    if shipped_db:
        # DIVE-2654 review (main2): NOT named "shipped" — this datapoint's own
        # week.shipped above is a DIVE-1552 FROZEN SUM over the last 7
        # PUBLISHED daily datapoints (overwritten in from `hist[-7:]` after
        # `row` is built), while this is a LIVE datetime('now','-7 days') SQL
        # count. Two instruments both labelled "7d" in the same file is
        # exactly the defect this row exists to prevent, and the gap between
        # them WIDENS for as long as publishing stays paused (hist[-7:] then
        # spans more than 7 calendar days while this SQL span stays exactly
        # 7) — so the name and basis travel with the number rather than
        # trusting a shared label.
        fp_entry["shippedStandardTasks"] = shipped_db
        fp_entry["coveragePct"] = round(graded_db / shipped_db * 100, 1)
        fp_entry["basis"] = ("live tasks.db query: status='done' AND kind='standard' AND done_at "
                              "within the last 7 calendar days from datetime('now') — a DIFFERENT "
                              "instrument from this datapoint's own week.shipped above (a frozen sum "
                              "of the last 7 PUBLISHED daily datapoints, DIVE-1552, which can span "
                              "more than 7 calendar days while publishing is paused). Do not read "
                              "the two as the same number.")
    if iter_null_db:
        fp_entry["iterationNullGraded"] = iter_null_db
        fp_entry["iterationNullBiasPctPtsMax"] = round(iter_null_db / graded_db * 100, 1)
        fp_entry["note"] = ("rows with a NULL iteration count as first-pass, biasing this "
                             "rate UP by at most iterationNullBiasPctPtsMax")
    corroborators["verifierFirstPassRate"] = fp_entry
else:
    corroborators["verifierFirstPassRate"] = {
        "value": None, "window": "7d",
        "nodata": "no verifier-graded standard tasks in the 7d window",
    }

_pref   = (os.environ.get("CORR_REFUSALS") or "").strip()
_psites = (os.environ.get("CORR_SITES") or "").strip()
_pfw    = (os.environ.get("CORR_FIRED_WINDOW") or "").strip()
_pfl    = (os.environ.get("CORR_FIRED_LIFETIME") or "").strip()
_psince = (os.environ.get("CORR_LEDGER_SINCE") or "").strip()

if _pref.isdigit() and _psites.isdigit() and int(_psites) > 0:
    pb_entry = {
        "value": int(_pref),
        "window": "7d",
        "instrumentedSites": int(_psites),
    }
    if _pfw.isdigit():
        pb_entry["firedSites"] = int(_pfw)
    if _pfl.isdigit():
        pb_entry["firedSitesLifetime"] = int(_pfl)
    if _psince:
        pb_entry["ledgerSince"] = _psince
        try:
            from datetime import datetime, timezone
            _since_dt = datetime.strptime(_psince[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
            _now_dt = datetime.strptime(os.environ["NOW_ISO"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
            pb_entry["ledgerAgeDays"] = round((_now_dt - _since_dt).total_seconds() / 86400, 1)
        except Exception:
            pass
    _never_fired = (int(_psites) - int(_pfl)) if _pfl.isdigit() else None
    _note = "a site that never fires is not evidence of compliance"
    if _never_fired is not None:
        _note += (f" — {_never_fired} of {_psites} instrumented sites have never fired lifetime")
    _note += "; no baseline exists yet while the ledger is young (see ledgerAgeDays)"
    pb_entry["note"] = _note
    corroborators["policyBlockedAttempts"] = pb_entry
elif _psites.isdigit() and int(_psites) == 0:
    corroborators["policyBlockedAttempts"] = {
        "value": None, "window": "7d",
        "nodata": "the running 5dive bundle has no instrumented policy sites — upgrade it to record refusals (DIVE-1922)",
    }
else:
    corroborators["policyBlockedAttempts"] = {
        "value": None, "window": "7d",
        "nodata": "no policy_refusals table in this store — nothing has recorded a refused attempt (DIVE-1922)",
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

# DIVE-1924: the badge message carries the NUMBER ONLY — no date, no suffix.
# DIVE-1908 briefly appended the ISO date here, because badge.json had none and
# so rendered a stale number as CURRENT for as long as the publisher stayed dead
# (our own defect class aimed at the honesty instrument). lodar's call: the date
# is visual noise on the one asset whose value is being instantly readable, and
# he is right that the fix does not have to live in the message.
#
# WHAT REPLACES IT: .github/workflows/badge-staleness.yml, an INDEPENDENT hourly
# watcher that reads zero-human.json's own generatedAtUtc and rewrites THIS file
# to a visibly stale badge once the newest publish is older than 26h. The next
# successful publish overwrites it back, so the healthy badge needs no repair.
#
# WHY A WATCHER IS ALLOWED TO DO WHAT THE PUBLISHER IS NOT: a dead publisher
# cannot mark itself dead — that is why there is no publisher-set "stale" flag
# and no self-set colour, and the rule stands. The workflow is not the publisher:
# it runs on GitHub, not on this box, so it survives precisely the failures that
# take the publisher down. That independence is also the one guarantee the
# DIVE-1896 host monitor cannot make, since that monitor shares a host with the
# thing it watches.
#
# A DATE, never an AGE — still true, and it is why zero-human.json below keeps
# `date` and `generatedAtUtc` rather than gaining a "2d ago". A date is a FACT
# the artifact carries; an age is an ASSERTION that decays the moment it stops
# being rewritten, so a dead publisher frozen at "0d ago" would be actively
# LYING where a frozen date is merely stale. The watcher reads those fields; do
# not replace them with anything that has to keep being updated to stay true.
badge = {"schemaVersion": 1, "label": "zero-human",
         "message": message,
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
    # DIVE-2654: denominator-side signals the badge does not carry on its own
    # face. Additive-only, same zero-human.json API contract as publishedBy.
    "corroborators": corroborators,
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
  # DIVE-2051: the resolved identity is passed through the GIT_AUTHOR_*/
  # GIT_COMMITTER_* env, not left to the repo config written above. Config is
  # the WEAKER source: an exported GIT_AUTHOR_EMAIL in the publishing shell
  # overrides it, so a box that pinned an identity could still commit as
  # whatever the environment happened to carry. This is the one place the
  # authored identity is decided, and it is the one we refused to guess at.
  GIT_AUTHOR_NAME="$git_name" GIT_AUTHOR_EMAIL="$git_email" \
  GIT_COMMITTER_NAME="$git_name" GIT_COMMITTER_EMAIL="$git_email" \
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
  # DIVE-2051: the identity refusal exits 4, its OWN code — not the E_GENERIC
  # catch-all (which reads as "the network flaked tonight" and invites a retry
  # that cannot succeed) and above all NOT 3, which this verb already spends on
  # the healthy already-published-today no-op. _proof_tick maps 3 to success, so
  # a refusal sharing it would report a permanently broken box as a good night.
  # _proof_build already printed the how-to-fix block.
  if [ "$rc" -eq 4 ]; then
    echo "error: proof publish: REFUSED — no publishing identity configured (nothing was published, and nothing will publish until one is pinned)" >&2
    return "$_PROOF_RC_NO_IDENTITY"
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
  # DIVE-1888: prepare the log while we still have root, rather than discovering
  # at 02:00 that ${user} cannot write it. Best-effort by design: a box without
  # the log still gets its cron.
  #
  # DIVE-2044 is why that preparation is no longer LOAD-BEARING. The cron line
  # used to end `>> ${log} 2>&1`, and the shell opens that file AS ${user} BEFORE
  # /usr/local/bin/5dive ever runs. Something re-chowned the log to nobody:root
  # months after install; every night from then on the redirect failed with
  # EACCES and the shell died with the publisher never invoked — while cron
  # dutifully logged the CMD line, so journalctl showed the job "running" for 26
  # hours of not publishing. An install-time check cannot cover a permission
  # that changes later, so the redirect is GONE: the tick owns its own logging
  # and degrades to journald (see _proof_emit_log). The publish must never be
  # downstream of its own observability.
  if : >> "$log" 2>/dev/null \
     || { mkdir -p "$(dirname "$log")" 2>/dev/null && : >> "$log" 2>/dev/null; }; then
    if [ "$user" != "root" ] && ! chown "$user" "$log" 2>/dev/null; then
      echo "proof: WARNING — could not chown ${log} to ${user}; the tick will log to journald instead (\`journalctl -t 5dive-proof\`). Publishing is unaffected." >&2
    fi
  else
    echo "proof: WARNING — cannot create ${log}; the tick will log to journald instead (\`journalctl -t 5dive-proof\`). Publishing is unaffected." >&2
  fi
  cat > "$_PROOF_CRON" <<CRON
# 5dive zero-human proof publisher (OSS-17) — daily; gated on the per-box pref
# (${STATE_DIR}/proof.json). Removed by \`5dive proof off\`.
#
# DIVE-2044: NO shell redirect on this line, deliberately. \`>> ${log} 2>&1\` is
# opened by the shell BEFORE 5dive runs, so an unwritable log killed the publish
# before it started. --log= hands the path to the tick, which writes its record
# AFTER the publish and falls back to journald if the file is unwritable.
0 ${hour} * * * ${user} /usr/local/bin/5dive proof tick --log=${log}
CRON
  chmod 644 "$_PROOF_CRON"
}

# _proof_cron_legacy_check — DIVE-2044. Crons installed before this fix still
# carry the `>> <log> 2>&1` redirect, and nothing re-runs `proof on` on a box
# that is already configured. Detect it on `proof status` and repair in place
# when we hold the rights; a loud warning is the fallback. Never silence — the
# whole defect was a box that looked configured and published nothing.
_proof_cron_legacy_check() {
  [ -f "$_PROOF_CRON" ] || return 0
  grep -qE '^[0-9].*5dive proof tick.*>>' "$_PROOF_CRON" 2>/dev/null || return 0
  local hour user
  hour="$(sed -n 's/^0 \([0-9]*\) \* \* \* .*/\1/p' "$_PROOF_CRON" | head -1)"
  user="$(sed -n 's/^0 [0-9]* \* \* \* \([^ ]*\) .*/\1/p' "$_PROOF_CRON" | head -1)"
  echo "proof: WARNING — ${_PROOF_CRON} still uses the legacy \`>> ${_PROOF_LOG}\` redirect. The shell opens that file BEFORE 5dive runs, so an unwritable log kills the publish before it starts (DIVE-2044)." >&2
  if [ -n "$hour" ] && [ -n "$user" ] && [ -w "$_PROOF_CRON" ] && _proof_install_cron "$hour" "$user"; then
    echo "proof: rewrote ${_PROOF_CRON} without the redirect — the tick now logs to ${_PROOF_LOG} itself and falls back to journald." >&2
  else
    echo "proof: fix with:  sudo 5dive proof on --at=${hour:-2} --user=${user:-root}" >&2
  fi
}

# _proof_onoff <on|off|status> [--repo=] [--branch=] [--at=] — pref + cron mgmt.
_proof_onoff() {
  local sub="$1"; shift || true
  local repo="" branch="" hour="" user="" as_name="" as_email="" f; f="$(_proof_pref_file)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo=*)   repo="${1#*=}" ;;
      --branch=*) branch="${1#*=}" ;;
      --at=*)     hour="${1#*=}" ;;
      --user=*)   user="${1#*=}" ;;
      # DIVE-2051: pin the identity the badge commits are authored with, on the
      # box, in config — so it is a decision someone made once rather than
      # whatever ambient git config the publishing user happens to carry.
      --as-name=*)  as_name="${1#*=}" ;;
      --as-email=*) as_email="${1#*=}" ;;
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
      # DIVE-2051: an --as-email that is not an address would be persisted as
      # the permanent public author of every badge commit, so validate here
      # rather than at 02:00. --as-name/--as-email are set together or not at
      # all; half an identity refuses at publish time anyway.
      if [ -n "$as_email" ] || [ -n "$as_name" ]; then
        [ -n "$as_name" ]  || fail "$E_USAGE" "proof on: --as-email needs --as-name (both, or neither)"
        [ -n "$as_email" ] || fail "$E_USAGE" "proof on: --as-name needs --as-email (both, or neither)"
        case "$as_email" in
          *@*.*) : ;;
          *) fail "$E_VALIDATION" "proof on: --as-email=$as_email does not look like an email address" ;;
        esac
        _proof_pref_write --arg n "$as_name" --arg e "$as_email" \
          '.identity={name:$n,email:$e}' \
          || fail "$E_GENERIC" "proof on: could not persist the publishing identity to ${f} — nothing enabled"
      fi
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
      # DIVE-2051: same shape, for identity. Resolve AS the cron user (root's
      # ~/.gitconfig says nothing about theirs) and say so now — otherwise the
      # box looks configured and the first thing it does at ${hour}:00 is
      # refuse. Warn, don't fail: enabling the cron is still the right outcome,
      # and the refusal at publish time is the actual guard.
      _proof_identity "$user"
      if [ -z "$_PROOF_ID_NAME" ] || [ -z "$_PROOF_ID_EMAIL" ]; then
        echo "proof: WARNING — no publishing identity resolves for ${user}; the daily publish will REFUSE until one is pinned." >&2
        _proof_identity_help "$user" >&2
      else
        echo "publish identity: ${_PROOF_ID_NAME} <${_PROOF_ID_EMAIL}> (${_PROOF_ID_SOURCE})"
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
      # DIVE-2051: resolve the publishing identity as the CRON user, not the
      # caller — `proof status` is mostly read by someone other than the user
      # that actually publishes, and reporting the reader's identity would be a
      # confident answer to a question nobody asked.
      _proof_identity "$(jq -r '.user // "root"' <<<"$cur")"
      # DIVE-2044: warn (and repair, with the rights) on a pre-fix cron line.
      # Runs on the --json path too — it prints to stderr, so stdout stays clean.
      _proof_cron_legacy_check
      if [ "${JSON_MODE:-0}" = 1 ]; then
        jq -c --argjson autonomy "$led" --arg wr "$(_proof_state_writable)" \
          --arg idn "$_PROOF_ID_NAME" --arg ide "$_PROOF_ID_EMAIL" --arg ids "$_PROOF_ID_SOURCE" \
          --argjson idu "$_PROOF_ID_UNCHECKED" \
          '{autonomy:$autonomy, enabled:(.enabled//false), publishApproved:(.publishApproved//false), repo:(.repo//null), branch:(.branch//"status"), hour:(.hour//9), lastPublished:(.lastPublished//null), lastPublishedBy:(.lastPublishedBy//null), stateWritable:($wr != ""), identity:(if $ids == "" then null else {name:$idn,email:$ide,source:$ids} end), identityUnchecked:($idu == 1)}' <<<"$cur"
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
      # DIVE-2051: WHAT the badge commits get authored as, and from where. An
      # unset identity is a live misconfiguration on any box with the publisher
      # on, so it is stated on the status line rather than discovered at 02:00.
      if [ -n "$_PROOF_ID_SOURCE" ]; then
        echo "publish identity: ${_PROOF_ID_NAME} <${_PROOF_ID_EMAIL}> (${_PROOF_ID_SOURCE})"
      elif [ "$_PROOF_ID_UNCHECKED" = 1 ]; then
        echo "publish identity: not checked — reading ${user_c}'s git config needs root (sudo 5dive proof status)"
      elif [ "$enabled" = "true" ]; then
        echo "publish identity: UNSET ⚠ — publish will REFUSE (5dive proof on --as-name=… --as-email=…)"
      else
        echo "publish identity: unset (pin one before enabling: --as-name=… --as-email=…)"
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
#
# DIVE-2044 gave the tick two more jobs, both about being READABLE afterwards:
#
#   --log=<path>  own the logging instead of letting the cron shell redirect
#                 into it. The redirect ran BEFORE the publisher and killed it
#                 outright when the file was unwritable; this write happens
#                 AFTER, so a broken log costs a log line, never a publish.
#   a success record. `proof tick` used to print literally nothing on a good
#                 night: the log accumulated skips and failures only, so an
#                 operator reading it could not tell "published fine" from
#                 "never ran". Every outcome now leaves one stamped line.
_proof_tick() {
  local logf="" a
  for a in "$@"; do
    case "$a" in
      --log=*) logf="${a#--log=}" ;;
      *) fail "$E_USAGE" "proof tick: unknown arg: $a" ;;
    esac
  done
  local out rc=0
  # Captured, not discarded: the publisher's own summary is the only place the
  # published stamp appears, and it is exactly what the record needs to carry.
  out="$(_proof_tick_run 2>&1)" || rc=$?
  local pubrc="$rc"
  # 5 (not configured / disabled) is not a failure — a box that never turned the
  # publisher on is not broken — but it is emphatically not a publish either, and
  # the record below says so.
  [ "$rc" -eq "$_PROOF_RC_TICK_SKIP" ] && rc=0
  # 3 (already published today) is a genuine success for a scheduled run. 4 (no
  # publishing identity, DIVE-2051) is NOT, and is deliberately left non-zero:
  # it is the one failure that repeats every night until a human acts, so it is
  # exactly the one a scheduled run must not report as fine. This is the ONE
  # place the mapping happens; the record below still names the real outcome.
  [ "$rc" -eq 3 ] && rc=0
  _proof_emit_log "$logf" "$(_proof_tick_record "$pubrc" "$out")"
  # A FAILING tick names its reason on stderr as well, whichever rail took the
  # record above. cron surfaces stderr; the record may have gone to a file or to
  # journald, where a nightly cron failure is not where the operator is looking.
  # Sending a failure ONLY to the log rail would rebuild this ticket's own defect
  # one layer over: the DIVE-2051 identity refusal is precisely the failure that
  # repeats every night until a human acts, so it is the one that must never be
  # quiet on the channel a scheduled run reports through.
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
  fi
  return "$rc"
}

# _proof_tick_run — the tick's actual work, with its exit code UNMAPPED (3 still
# means the healthy already-published no-op) so the caller can name the outcome.
# The two "not configured" exits print rather than returning in silence: a log
# whose only content is a skip is what made a dead publisher look alive.
_proof_tick_run() {
  local f rc=0; f="$(_proof_pref_file)"
  [ -r "$f" ] || { echo "not configured on this box (${f} unreadable) — nothing to do"; return "$_PROOF_RC_TICK_SKIP"; }
  [ "$(jq -r '.enabled // false' "$f" 2>/dev/null)" = "true" ] \
    || { echo "disabled in ${f} (.enabled != true) — nothing to do"; return "$_PROOF_RC_TICK_SKIP"; }
  _proof_publish || rc=$?
  return "$rc"
}

# _proof_tick_record <publish-rc> <output> — one stamped line naming the outcome,
# plus the publisher's own output indented beneath it. DIVE-2044 defect 2: the
# 26h outage was invisible partly because a SUCCESSFUL tick wrote nothing at all,
# so "published fine" and "never ran" produced identical logs.
_proof_tick_record() {
  local rc="$1" out="$2" now stamp verdict
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  stamp="$(_proof_pref_get '.lastPublished' 2>/dev/null || true)"
  case "$rc" in
    0) verdict="PUBLISHED (lastPublished=${stamp:-unrecorded})" ;;
    3) verdict="no-op — already published for ${stamp:-today}" ;;
    "$_PROOF_RC_TICK_SKIP")
       verdict="SKIPPED — the publisher is not enabled on this box; nothing was published" ;;
    "$_PROOF_RC_NO_IDENTITY")
       verdict="FAILED rc=${rc} — no publishing identity; nothing published, and nothing will until one is pinned (DIVE-2051)" ;;
    *) verdict="FAILED rc=${rc} — nothing published" ;;
  esac
  printf '%s proof tick: %s\n' "$now" "$verdict"
  [ -n "$out" ] && printf '%s\n' "$out" | sed "s/^/${now}   | /"
  return 0
}

# _proof_emit_log <path|""> <record> — put the run record where an operator will
# find it, and NEVER let that write change what already happened. The publish is
# done by the time this runs. Three rails, most durable first:
#   file → journald (`journalctl -t 5dive-proof`) → stderr (cron mail).
# A degraded rail SAYS SO on the rail it fell back to, so "the log stopped" can
# never again be read as "the publisher stopped" (or vice versa).
_proof_emit_log() {
  local logf="$1" rec="$2" why
  [ -n "$rec" ] || return 0
  # `2>/dev/null` FIRST, deliberately: redirections are applied left to right, so
  # with the append first bash writes its own "No such file or directory"
  # diagnostic — naming a bundle line number — to the real stderr before the
  # silencer takes effect. Every failed nightly tick would have cron-mailed it.
  if [ -n "$logf" ] && printf '%s\n' "$rec" 2>/dev/null >> "$logf"; then
    return 0
  fi
  if [ -n "$logf" ]; then
    # Says "the run happened", not "the publish happened" — the run below may be a
    # SKIP, and a fallback banner that asserts a publish would be its own small lie.
    why="proof tick: could NOT append to ${logf} as $(id -un) — logging degraded to this rail; the run itself completed and is recorded below (DIVE-2044)."
  else
    why="proof tick: no --log= given; run record follows."
  fi
  if command -v logger >/dev/null 2>&1 \
     && printf '%s\n%s\n' "$why" "$rec" | logger -t 5dive-proof 2>/dev/null; then
    return 0
  fi
  printf '%s\n%s\n' "$why" "$rec" >&2
}

# _proof_scorecard — DIVE-1914. Multi-dimensional autonomy metrics, LOCAL and
# read-only, broken down by risk tier. The badge (1 - asks/shipped) stays the
# HEADLINE number; this exists so a single score is not the only score and
# therefore not worth gaming (the DIVE-1441 anti-Goodhart argument).
#
# THE RULE THIS VERB IS BUILT AROUND: every rendered number is backed by a
# source that was PROVEN to exist before the metric shipped. A metric with no
# source renders 0.0% and reads as "we never get blocked" / "we never roll
# back" — a confident zero on the honesty instrument itself, which is the
# succeeding-in-appearance class we keep deleting. Absent, or an explicit
# no-data marker WITH the reason, beats a confident zero every time.
#
# Ground-truthed against live digest + tasks.db on 2026-07-25. The spec claimed
# cost was available at digest.usage; digest.usage is EMPTY in every window
# (checked 1d and 7d, and --30d does not exist). Empty is not thin, it is
# absent. Tokens come from usage_collect instead — a different source than the
# spec named, and it measures tokens, not money.
#
# Numbers come VERBATIM from digest / tasks.db / usage_collect. There is
# deliberately NO flag anywhere that adjusts one — same no-edit path as publish.
_proof_scorecard() {
  # --json is stripped GLOBALLY by main.sh before dispatch (it sets JSON_MODE),
  # so a local `--json)` case here would be dead code that silently never fires
  # and leaves --json rendering text. Read the global.
  local json="${JSON_MODE:-0}" window="7d" by="tier"
  while [ $# -gt 0 ]; do
    case "$1" in
      --7d)   window="7d" ;;
      # DIVE-1921 shipped digest --30d, so the window this verb was specified
      # with (DIVE-1914: [--7d|--30d]) is finally computable and the refusal
      # that stood here is gone. 30d is the FIX for the thin-n rows below —
      # median recovery time off one episode, precedent acceptance off n=2.
      --30d)  window="30d" ;;
      --by=*) by="${1#*=}" ;;
      *) fail "$E_USAGE" "proof scorecard: unknown arg: $1" ;;
    esac
    shift
  done
  case "$by" in tier|class) ;; *) fail "$E_USAGE" "proof scorecard: --by must be tier|class" ;; esac

  # DIVE-1921: the window must move as ONE unit. Every number below comes from
  # one of three readers — the digest sub-call, the tasks/ship/policy SQL, and
  # the token collector — and they are combined into single ratios (asks over
  # shipped, first-pass over graded, tokens over shipped). A site left behind at
  # 7 days therefore does not render as a wrong window; it renders as a
  # PLAUSIBLE RATE with a numerator and denominator measured over different
  # spans, which is invisible in the output. That is why nothing past this point
  # is allowed to spell a span out by hand: it all derives from here.
  local sql_window usage_secs
  case "$window" in
    7d)  sql_window="-7 days"  ; usage_secs=604800 ;;
    30d) sql_window="-30 days" ; usage_secs=2592000 ;;
    *)   fail "$E_USAGE" "proof scorecard: unsupported window: $window" ;;
  esac

  local self db work
  # DIVE-2080, the hole DIVE-2061 closed one call up. selfcheck's probe 7 carefully
  # resolves the bundle under test and shells `"$self" proof scorecard --7d` into it —
  # and this line then re-resolved onto the INSTALLED CLI, so the metric rows the probe
  # grades came from a different artifact. Fail loudly rather than grade a stranger.
  self="$(five_self_bundle)" \
    || fail "$E_GENERIC" "proof scorecard: could not identify the running 5dive bundle to compute the digest"
  db="${TASKS_DB:-${STATE_DIR}/tasks/tasks.db}"
  # DIVE-1864 lesson, same trap one verb along: a live digest blows past
  # MAX_ARG_STRLEN, so these go through FILES, never the environment. Passing
  # them as env vars fails with a bare "Argument list too long" and no metric.
  work="$(mktemp -d)"
  "$self" digest --json "--$window" 2>/dev/null > "$work/digest.json"
  [ -s "$work/digest.json" ] || fail "$E_GENERIC" "proof scorecard: digest produced no output"

  # Tokens: usage_collect scans agent transcripts. Guarded — this lib is also
  # sourced in contexts without cmd_usage.sh, and a missing collector must
  # degrade to an honest no-data row, never to a zero.
  : > "$work/usage.json"
  if declare -F usage_collect >/dev/null 2>&1; then
    usage_collect "$usage_secs" 2>/dev/null > "$work/usage.json" || : > "$work/usage.json"
  fi

  # DIVE-1914 iteration 2 (olivia): --by used to be VALIDATED as legal and then
  # never used — grouping was always by tier, so `--by=class` emitted
  # "by":"class" beside a breakdown of tier data. Output asserting what the code
  # never computed is precisely the class this verb exists to prevent. --by now
  # selects both the grouping expression and what "known" means for coverage,
  # and the label ships INSIDE the breakdown object so the two cannot disagree.
  #
  # class = project_key + priority (the ticket's approximation). Ground-truthed
  # 2026-07-25: both columns are non-empty on all 408 shipped tasks in the
  # window, so class coverage is complete where tier coverage is 27%.
  local group_expr known_expr
  case "$by" in
    tier)  group_expr="COALESCE(CAST(tier AS TEXT),'untiered')"
           known_expr="tier IS NOT NULL" ;;
    class) group_expr="COALESCE(NULLIF(project_key,''),'unknown')||'/'||COALESCE(NULLIF(priority,''),'unknown')"
           known_expr="project_key IS NOT NULL AND project_key<>'' AND priority IS NOT NULL AND priority<>''" ;;
  esac

  local rows
  rows="$(db "SELECT
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window"))) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND verifier IS NOT NULL AND verifier<>'') || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND verifier IS NOT NULL AND verifier<>'' AND COALESCE(iteration,1)<=1) || '|' ||
      (SELECT COUNT(*) FROM tasks WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window")) AND ${known_expr});" 2>/dev/null || true)"

  # DIVE-1922: the policy-refusal source now EXISTS, so this metric stops being
  # NO DATA. Two numbers are needed, not one. The count alone would read as
  # "we never get blocked" when it is 0 — the same failure the marker existed to
  # prevent — so it ships with the number of INSTRUMENTED sites beside it. An
  # uninstrumented refusal site is invisible to this count, and the reader has to
  # be told that. The site count is DERIVED from the shipped bundle rather than
  # hand-maintained, because a hand-kept constant drifts and then lies.
  local refusals="" refusal_sites=""
  if [ "$(db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='policy_refusals' LIMIT 1;" 2>/dev/null)" = "1" ]; then
    refusals="$(db "SELECT COUNT(*) FROM policy_refusals WHERE ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    # `|| true` is LOAD-BEARING, not defensive noise. Under `set -euo pipefail` a
    # grep that matches nothing exits 1, pipefail propagates it, and set -e kills
    # the whole verb — printing NOTHING and exiting 1. That happens on any box
    # whose INSTALLED bundle predates DIVE-1922 (this greps $self, the resolved
    # `5dive` on PATH, not the tree being built), so the scorecard would have
    # died silently on every box until the new version rolled. A silent exit is
    # the failure mode this whole verb exists to argue against.
    # NB $self is the 5dive resolved on PATH, which is DELIBERATE and is not the
    # bundle you may be running from a build tree: refusals are recorded by
    # whatever CLI the box actually runs, so that is the artifact whose coverage
    # the denominator has to describe. The marker below therefore NAMES that path
    # — an earlier wording said "this 5dive build", which was false whenever the
    # two differed, and a marker whose stated reason is wrong is its own small
    # lie in the one metric that exists to argue against those.
    refusal_sites="$( { grep -oE 'policy_refuse "[^"]+" [a-z0-9-]+' "$self" 2>/dev/null || true; } \
                     | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')"
  fi

  local group_rows
  group_rows="$(db "SELECT ${group_expr}, COUNT(*) FROM tasks
                    WHERE status='done' AND kind='standard' AND done_at>=datetime('now',$(sqlq "$sql_window"))
                    GROUP BY 1 ORDER BY 2 DESC, 1;" 2>/dev/null || true)"

  # DIVE-1923: the ship ledger now sources "autonomous rollback rate". Four
  # numbers, not one. The rate's numerator and denominator come from the SAME
  # instrument (`5dive push`), which is what lets it state its own coverage
  # instead of leaving the reader to guess at it; the unattributable reverts and
  # the ledger's start date are part of the metric, not metadata about it.
  local ships="" rollbacks="" rollbacks_unproven="" ledger_since=""
  if [ "$(db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='ship_events' LIMIT 1;" 2>/dev/null)" = "1" ]; then
    ships="$(db "SELECT COUNT(*) FROM ship_events WHERE kind='ship' AND ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    rollbacks="$(db "SELECT COUNT(*) FROM ship_events WHERE kind='rollback' AND self=1 AND ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    rollbacks_unproven="$(db "SELECT COUNT(*) FROM ship_events WHERE kind='rollback' AND self=0 AND ts>=datetime('now',$(sqlq "$sql_window"));" 2>/dev/null || true)"
    ledger_since="$(db "SELECT COALESCE(MIN(ts),'') FROM ship_events;" 2>/dev/null || true)"
  fi

  DIGEST_FILE="$work/digest.json" USAGE_FILE="$work/usage.json" DB_ROWS="$rows" GROUP_ROWS="$group_rows" \
  REFUSALS="$refusals" REFUSAL_SITES="$refusal_sites" SELF_PATH="$self" \
  SHIPS="$ships" ROLLBACKS="$rollbacks" ROLLBACKS_UNPROVEN="$rollbacks_unproven" LEDGER_SINCE="$ledger_since" \
  WINDOW="$window" BY="$by" AS_JSON="$json" python3 <<'SCOREPY'
import os, json, sys

dg = json.load(open(os.environ["DIGEST_FILE"]))
as_json = os.environ["AS_JSON"] == "1"
parts = (os.environ.get("DB_ROWS") or "").strip().split("|")
def num(i):
    try: return int(parts[i])
    except Exception: return None

shipped_db, graded, first_pass, tiered = num(0), num(1), num(2), num(3)

zh    = dg.get("zeroHuman") or {}
stuck = dg.get("stuck") or {}
pre   = dg.get("precedentPrefill") or {}

shipped = zh.get("shipped")
asks    = zh.get("humanTouches")

# A metric is either SOURCED (value + the sample it rests on) or it is no-data
# WITH a reason. There is no third state, and no path that emits a bare 0.
def metric(name, value, sample=None, note=None, nodata=None):
    return {"name": name, "value": value, "sample": sample, "note": note, "nodata": nodata}

metrics = []

# 1. human interruptions per accepted outcome — digest.zeroHuman (solid, n=408).
if shipped:
    metrics.append(metric("human interruptions per accepted outcome",
                          round(asks / shipped, 3), f"{asks} asks / {shipped} shipped"))
else:
    metrics.append(metric("human interruptions per accepted outcome", None,
                          nodata="no accepted outcomes in the window"))

# 2. verifier first-pass rate — tasks.db maker/verifier rail. NOT in digest.
if graded:
    metrics.append(metric("verifier first-pass rate",
                          f"{round(first_pass / graded * 100, 1)}%", f"n={graded} graded"))
else:
    metrics.append(metric("verifier first-pass rate", None,
                          nodata="no verifier-graded tasks in the window"))

# 3. median recovery time — digest.stuck, already computed upstream. The sample
#    sits ON the number: one episode is not a median, and a reader must not have
#    to find that in a footnote.
if stuck.get("mttuSec") is not None and stuck.get("episodes"):
    ep = stuck["episodes"]
    metrics.append(metric("median recovery time", f"{stuck['mttuSec']}s",
                          f"n={ep} episode" + ("" if ep == 1 else "s")))
else:
    metrics.append(metric("median recovery time", None,
                          nodata="no recovery episodes in the window"))

# 4. precedent acceptance — digest.precedentPrefill.
if pre.get("count"):
    metrics.append(metric("precedent acceptance rate",
                          f"{pre.get('acceptanceRate')}%", f"n={pre['count']}"))
else:
    metrics.append(metric("precedent acceptance rate", None,
                          nodata="no precedent prefills in the window"))

# 5. TOKENS per accepted outcome. The row is NAMED for what it measures —
#    a label is a footnote, the name is the claim, and a reader scanning a
#    scorecard reads names. Never called "cost": see the money line below.
#
#    DIVE-1929: this row is caller-dependent. usage_collect can only read the
#    transcripts the CALLER can read, and an unreadable agent used to look
#    exactly like an idle one — root saw 4,670,188/outcome, agent-olivia saw
#    220,391 (4.7% of the truth, 21x low), agent-dev3 saw 46,253, and all three
#    rendered as confident complete numbers with no marker. The denominator
#    makes it worse: `shipped` is always company-wide, so a partial numerator
#    over a whole denominator is not even a slice of a real ratio.
#
#    The rule is DIVE-1922's: a number never ships without its coverage. Here
#    that means the number ships ONLY at full coverage (carrying it), and any
#    partial read degrades to NO DATA naming what was missed. Unknown coverage
#    counts as partial — an old collector's unlabelled total is exactly the
#    thing that cannot be trusted.
tok_total = None
cov = None
try:
    with open(os.environ["USAGE_FILE"]) as fh:
        raw = fh.read().strip()
    if raw:
        u = json.loads(raw)
        tok_total = sum(int(a.get("total") or 0) for a in (u.get("agents") or []))
        cov = u.get("coverage") or None
except Exception:
    tok_total, cov = None, None

if not (tok_total and shipped):
    metrics.append(metric("tokens per accepted outcome", None,
                          nodata="token transcripts unreadable from here (needs root)"))
elif not cov:
    metrics.append(metric("tokens per accepted outcome", None,
                          nodata="token coverage unknown — the collector did not report which "
                                 "transcript sets it could read, and an unlabelled total cannot "
                                 "be told apart from a partial one"))
elif not cov.get("complete"):
    read, exp = cov.get("agentsRead"), cov.get("agentsExpected")
    metrics.append(metric("tokens per accepted outcome", None,
                          nodata=f"only {read} of {exp} agent transcript sets readable from here — "
                                 f"a partial read over company-wide outcomes understates this row "
                                 f"(needs root)"))
else:
    metrics.append(metric("tokens per accepted outcome", f"{round(tok_total / shipped):,}",
                          f"{tok_total:,} tokens / {shipped} shipped; "
                          f"{cov.get('agentsRead')} of {cov.get('agentsExpected')} agent transcript sets readable",
                          note="subscription tokens"))

# 6/7. No source exists. Rendered as an explicit marker naming the task that
#      would build it — telling the reader WHY beats telling them THAT.
# DIVE-1922 built the source (policy_refuse -> policy_refusals). A 0 is now a
# real measurement rather than an absence — but only across the sites that are
# INSTRUMENTED, so the count never ships without that denominator beside it.
# Pre-DIVE-1922 stores have no table at all, which stays honest no-data.
_ref = os.environ.get("REFUSALS", "").strip()
_sites = os.environ.get("REFUSAL_SITES", "").strip()
if _ref.isdigit() and _sites.isdigit() and int(_sites) > 0:
    metrics.append(metric("policy-blocked action attempts", int(_ref),
                          f"across {_sites} instrumented policy sites"))
elif _sites.isdigit() and int(_sites) == 0:
    # The store can record refusals but the RUNNING bundle has no instrumented
    # sites (an installed CLI older than DIVE-1922). Rendering the raw count
    # here would imply a denominator that does not exist. Say which of the two
    # causes it actually is — a marker whose stated reason is wrong is its own
    # small lie, and this metric exists to argue against exactly that.
    metrics.append(metric("policy-blocked action attempts", None,
                          nodata=f"the 5dive on PATH ({os.environ.get('SELF_PATH') or '5dive'}) has no instrumented policy sites — upgrade it to record refusals (DIVE-1922)"))
else:
    metrics.append(metric("policy-blocked action attempts", None,
                          nodata="no policy_refusals table in this store — nothing has recorded a refused attempt (DIVE-1922)"))
# DIVE-1923 built the source (5dive push -> ship_events). The three states of a
# metric all live on this one row, and telling them apart is the whole point:
#   - no ledger at all        -> honest NO DATA (a store older than this build)
#   - a ledger with 0 ships   -> STILL no data. A rate over zero ships is
#     UNDEFINED, not 0.0%, and 0.0% is exactly the reading ("we never roll back")
#     the original marker existed to refuse. An empty denominator must never
#     render as a confident numerator.
#   - ships > 0               -> a real rate, shipping with the sample it rests
#     on and with the reverts it could NOT attribute, because a rate that hides
#     what it excluded is a coverage claim it never earned.
#
# The denominator is named for what it COUNTS — commits pushed through
# `5dive push` — and never as bare "ships" (main, reviewing this change). Both of
# its errors are then visible in the label rather than in a note the reader may
# not reach. Work that bypasses `5dive push` under-counts it and biases the rate
# UP, which is pessimistic and safe in a published autonomy number; a branch
# pushed and then ABANDONED counts as a ship, which inflates the denominator and
# biases the rate DOWN. A flattering denominator produces a flattering rate, and
# that is the 0.0%-reads-as-"we never roll back" failure one level up. Naming the
# denominator honestly makes the row honest by construction rather than
# honest-if-you-read-the-note. Reconciling pushed-vs-merged is DIVE-2127.
_ships = os.environ.get("SHIPS", "").strip()
_rb    = os.environ.get("ROLLBACKS", "").strip()
_rbu   = os.environ.get("ROLLBACKS_UNPROVEN", "").strip()
_since = (os.environ.get("LEDGER_SINCE", "").strip() or "")[:10]
if not _ships.isdigit():
    metrics.append(metric("autonomous rollback rate", None,
                          nodata="no ship_events ledger in this store — nothing records a "
                                 "self-revert yet (DIVE-1923)"))
elif int(_ships) == 0:
    metrics.append(metric("autonomous rollback rate", None,
                          nodata=("nothing pushed through `5dive push` in this window"
                                  + (f" (ledger opened {_since})" if _since else " (ledger is empty)")
                                  + " — a rate over an empty denominator is undefined, not 0.0% (DIVE-1923)")))
else:
    _s, _r, _u = int(_ships), int(_rb or 0), int(_rbu or 0)
    _sample = f"{_r} of {_s} commits pushed through `5dive push` were reverted"
    if _u:
        _sample += (f"; {_u} further revert(s) undid commits absent from this ledger, so they "
                    f"cannot be shown to be self-inflicted and are excluded from the numerator")
    metrics.append(metric("autonomous rollback rate", f"{round(_r / _s * 100, 1)}%", _sample,
                          note="the denominator is commits PUSHED, not commits merged — a branch "
                               "pushed and abandoned still counts (which biases this rate DOWN), "
                               "and work landed by any other route is invisible (which biases it UP)"))

by = os.environ["BY"]
groups = []
for line in (os.environ.get("GROUP_ROWS") or "").strip().splitlines():
    if "|" in line:
        k, v = line.rsplit("|", 1)
        groups.append({"key": k, "shipped": int(v)})

# The dimension label lives INSIDE the breakdown, so the header and the rows
# cannot describe different things (the exact defect this iteration fixes).
coverage = None
if shipped_db:
    coverage = {"dimension": by, "known": tiered, "total": shipped_db,
                "pct": round((tiered or 0) / shipped_db * 100, 1)}

# The money line is a FACT worth stating, not an omission to leave silent, and
# it says WHY rather than that something is missing. It restates the standing
# stance in cmd_usage.sh: subscription inference has no per-token price, so a
# "$" column would be fiction.
money_note = ("no money figure exists here: this work runs on a subscription plan, "
              "so there is no per-token price and a \"$\" column would be fiction")

out = {"window": os.environ["WINDOW"], "by": by,
       "headline": {"note": "the badge (1 - asks/shipped) remains the headline number",
                    "shipped": shipped, "humanAsks": asks},
       "metrics": metrics,
       "breakdown": {"by": by, "rows": groups},
       "coverage": coverage,
       "moneyNote": money_note}

if as_json:
    print(json.dumps(out, indent=2))
    sys.exit(0)

print(f"SCORECARD — last {out['window']}   (local, read-only; the badge stays the headline)")
print()
w = max(len(m["name"]) for m in metrics)
for m in metrics:
    if m["value"] is None:
        print(f"  {m['name']:<{w}}   NO DATA — {m['nodata']}")
    else:
        tail = f"  ({m['sample']}" + (f"; {m['note']}" if m["note"] else "") + ")" if m["sample"] else ""
        print(f"  {m['name']:<{w}}   {m['value']}{tail}")
print()
print(f"  {money_note}.")
if groups:
    print()
    print("BY RISK TIER" if by == "tier" else "BY TASK CLASS (project / priority)")
    # Coverage sits NEXT TO the breakdown, not under it: without this a reader
    # takes 0/1/2 as the shape of the whole, when it describes only the tiered
    # slice. The coverage number is the most actionable thing on the row — it
    # says our own tiering discipline is the gap, not the metric.
    if coverage:
        print(f"  {by} known for {coverage['pct']}% of shipped work "
              f"({coverage['known']} of {coverage['total']})")
    kw = max(len(g["key"]) for g in groups)
    for g in groups:
        print(f"    {g['key']:<{max(kw, 10)}} {g['shipped']}")
SCOREPY
  local _rc=$?
  rm -rf "$work"
  return "$_rc"
}

cmd_proof() {
  case "${1:-}" in
    publish)       shift; _proof_publish "$@" ;;
    on|off|status) local _s="$1"; shift; _proof_onoff "$_s" "$@" ;;
    scorecard)     shift; _proof_scorecard "$@" ;;
    tick)          shift; _proof_tick "$@" ;;
    -h|--help|"")
      cat <<'HELP'
usage: 5dive proof status [--json]                    # LOCAL autonomy badge + config (no network)
       5dive proof scorecard [--json] [--7d|--30d] [--by=tier|class]   # LOCAL multi-dim metrics by risk tier
       5dive proof on --repo=<url> [--branch=status] [--at=<0-23>] [--user=<u>]
                      [--as-name=<n> --as-email=<e>]   # identity commits are authored with
       5dive proof off
       5dive proof publish [--dry-run] [--repo=<url>] [--branch=<b>]
       5dive proof tick [--log=<path>]   # cron driver; gated on the pref

`proof tick --log=` makes the tick own its logging: it writes ONE stamped line
per run naming the outcome (PUBLISHED / no-op / FAILED, success included) and
falls back to journald when the path is unwritable. The installed cron carries
no `>>` redirect on purpose — the shell opens a redirect BEFORE the publisher
runs, and an unwritable log silently killed 26h of publishes.

`proof status` shows this company's autonomy badge — 1 − asks/shipped over the
lifetime ledger, materialized from task data: a shipped action is a
done task; it "needed a human" only if it carried a gate a HUMAN answered (a
lead/agent clearance does not count). Read-only, local, no publish.

`proof scorecard` breaks autonomy into several dimensions by risk
tier, so a single score is not the only score and therefore not worth gaming.
The badge stays the HEADLINE number. Local and read-only, like `proof status`.
Every rendered number is backed by a source proven to exist before the metric
shipped; a metric with no source shows an explicit NO DATA marker naming WHY,
never a confident 0.0% that reads as "we never get blocked". No dollars — the
work runs on a subscription plan, so the row is honestly named "tokens per
accepted outcome" rather than a "cost" row with a footnote.

`proof publish` writes the badge (badge.json + zero-human.json + history.jsonl)
to a git status branch, computed VERBATIM from `5dive digest` — there is no flag
to edit a number, the no-edit path is the point; idempotent per day (re-run
exits 3). GUARDRAIL: publishing is a PUBLIC brand/comms act, so the FIRST fire
files an approval gate to lodar and BLOCKS — no badge goes live without lodar's
tap. `proof on/off` toggle the daily publisher; `--user` sets the cron's
effective user (default root), which must own the box's git push credentials or
the nightly push fails silently as visible staleness. See docs/zero-human.md.

PUBLISHING IDENTITY: these are public, permanent commits, so the
author is never inferred. It resolves ZH_GIT_NAME/ZH_GIT_EMAIL (env) > the
identity pinned by `proof on --as-name= --as-email=` > the publishing user's
`git config --global` — and if none of those is set, `proof publish` REFUSES
instead of authoring as whatever address the box has lying around. Pin a role
address (e.g. <user>@users.noreply.github.com), not a personal inbox: on a box
where an agent publishes, the most available address is the operator's own,
which Claude Code puts in every agent's prompt by default. `proof status` shows
the resolved identity and its source.

`proof publish` exit codes: 0 published, 3 already published today (a healthy
no-op), 4 REFUSED for no identity, other non-zero for other failures. 3 and 4
are separate on purpose — a scheduled run treats 3 as success, so a refusal
sharing that code would report a permanently broken box as a healthy night.
HELP
      ;;
    *) fail "$E_USAGE" "proof: unknown subcommand: ${1:-} (publish|on|off|status|scorecard|tick)" ;;
  esac
}
