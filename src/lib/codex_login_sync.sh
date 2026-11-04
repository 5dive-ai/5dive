# -------- one ChatGPT sign-in, many Codex seats (DIVE-7724) --------
#
# A Codex seat copies its account's login (auth-profiles/<p>/codex/auth.json)
# into its own ~/.codex/auth.json at start (5dive-agent-start), and from then on
# Codex refreshes that LOCAL copy. ChatGPT refresh tokens are single-use: the
# first seat to refresh spends the token every other copy still holds. Nothing
# wrote the new one back, so the account kept the spent token and every seat
# hired after that (chill-gorge's marcus, 2026-11-04) booted signed out, as did
# any other seat on the account at its own next refresh.
#
# The fix: the newest copy of the login wins, everywhere. For each account this
# compares the account's file with every seat copy that is THE SAME ChatGPT
# account (tokens.account_id), picks the one with the latest `last_refresh`
# (Codex stamps it on every login and refresh), and writes it back into the
# account and out to every older seat copy. A new seat then seeds a live token,
# and a running seat finds it on disk: before Codex refreshes, and on a 401, it
# reloads auth.json and keeps what it finds when the account id matches
# ("Reloading auth for account", codex 0.166), so it never spends a dead one.
#
# Why this and not one shared file: a seat's copy is 0600 in its own home, and
# the account's file is readable (never writable) by just the seats on it
# (DIVE-5701). One file every seat writes would give each of them write access
# to every other seat's login. Here only root writes across seats.
#
# Two seats refreshing at once: both spend the same token, one wins at OpenAI,
# the other is refused. The next pass sees the winner's copy as newest and
# hands it to the loser, whose Codex then reloads it. A copy is never written
# back while it is mid-write (a file that does not parse is skipped), and a
# seat copy that changed after it was read is left for the next pass instead of
# being overwritten with an older one.
#
# Runs as root: every heartbeat tick, at sign-in, and before a seat starts
# (normalize_profile_seed_perms). It never moves a login across accounts:
# a copy of another ChatGPT account, an API-key login, or a file that is a
# symlink is never read as a candidate and never written.

# The default (no-account) login lives in the claude user's home. A seam: the
# harness points it at a fixture.
_cls_claude_home() { printf '%s' "${FIVEDIVE_DEFAULT_CRED_HOME:-/home/claude}"; }
_cls_seat_home()   { printf '%s/agent-%s' "${AGENT_HOME_ROOT:-/home}" "$1"; }

# _cls_read <file> -> "<epoch> <account_id>" for a ChatGPT login; rc 1 for
# anything else (missing, a symlink, unparsable, an API key, no account id).
_cls_read() {
  local f="$1" out ts acct ep
  [[ -f "$f" && ! -L "$f" ]] || return 1
  out=$(jq -r 'select((.tokens.refresh_token // "") != "" and (.tokens.account_id // "") != "")
               | [(.last_refresh // ""), .tokens.account_id] | @tsv' "$f" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  ts="${out%%$'\t'*}"; acct="${out#*$'\t'}"
  [[ -n "$acct" && "$acct" != "$out" ]] || return 1
  ep=0
  [[ -z "$ts" ]] || ep=$(date -u -d "$ts" +%s 2>/dev/null) || ep=0
  printf '%s %s\n' "$ep" "$acct"
}

# _cls_write <src> <dst> — replace <dst> with <src>'s bytes, keeping <dst>'s
# owner, mode and ACLs, by rename (a reader never sees a half file). <dst> must
# exist. rc 1 if anything failed (dst is then untouched).
_cls_write() {
  local src="$1" dst="$2" tmp
  [[ -f "$dst" && ! -L "$dst" ]] || return 1
  tmp=$(mktemp -p "$(dirname "$dst")" .auth-sync.XXXXXX) || return 1
  if cat "$src" > "$tmp" \
     && chown --reference="$dst" "$tmp" 2>/dev/null \
     && chmod --reference="$dst" "$tmp"; then
    if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
      getfacl -p "$dst" 2>/dev/null | setfacl --set-file=- "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$dst" && return 0
  fi
  rm -f "$tmp"
  return 1
}

# codex_login_sync_profile <profile> — one account. Prints one line per file it
# wrote ("<profile>: <path> <- <winner>"). Always rc 0.
codex_login_sync_profile() {
  local p="$1" pdir pf seats x f r ep acct p_acct win="" win_ep=-1 snap
  [[ -n "$p" && "$p" != */* ]] || return 0
  pdir="$(_sp_profiles_dir)/$p/codex"
  pf="$pdir/auth.json"
  r=$(_cls_read "$pf") || return 0          # no ChatGPT login in this account
  p_acct="${r#* }"
  win="$pf"; win_ep="${r%% *}"

  # Candidates: every seat copy of this same account, and, for the canonical
  # account the no-account seats seed from, the claude user's own copy.
  local -a files=() eps=() sums=()
  seats=$(_sp_cred_seats "$p" codex 2>/dev/null) || seats=""
  while IFS= read -r x; do
    [[ -n "$x" ]] || continue
    files+=("$(_cls_seat_home "$x")/.codex/auth.json")
  done <<<"$seats"
  f="$(_cls_claude_home)/.codex/auth.json"
  [[ -f "$f" && ! -L "$f" ]] && files+=("$f")

  for f in "${files[@]}"; do
    r=$(_cls_read "$f") || { eps+=(""); sums+=(""); continue; }
    acct="${r#* }"; ep="${r%% *}"
    if [[ "$acct" != "$p_acct" ]]; then eps+=(""); sums+=(""); continue; fi
    eps+=("$ep"); sums+=("$(cksum < "$f")")
    (( ep > win_ep )) && { win="$f"; win_ep="$ep"; }
  done

  # Snapshot the winner: a seat may refresh again while we copy.
  snap=$(mktemp) || return 0
  cat "$win" > "$snap" 2>/dev/null || { rm -f "$snap"; return 0; }
  _cls_read "$snap" >/dev/null || { rm -f "$snap"; return 0; }

  if [[ "$win" != "$pf" ]] && ! cmp -s "$snap" "$pf"; then
    _cls_write "$snap" "$pf" && printf '%s: %s <- %s\n' "$p" "$pf" "$win"
  fi
  local i
  for i in "${!files[@]}"; do
    f="${files[$i]}"
    [[ -n "${eps[$i]}" && "$f" != "$win" ]] || continue
    (( ${eps[$i]} < win_ep )) || continue
    cmp -s "$snap" "$f" && continue
    # Changed since we read it (Codex refreshed it just now): next pass.
    [[ "$(cksum < "$f")" == "${sums[$i]}" ]] || continue
    _cls_write "$snap" "$f" && printf '%s: %s <- %s\n' "$p" "$f" "$win"
  done
  rm -f "$snap"
  return 0
}

# codex_login_sync [<profile>...] — every account with a Codex login when none
# is named. Root only (a seat cannot write another seat's home); a no-op
# otherwise. Serialized: two passes at once would race each other's renames.
codex_login_sync() {
  [[ $EUID -eq 0 || -n "${FIVEDIVE_CLS_ANY_USER:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local -a profiles=("$@")
  local d
  if (( ${#profiles[@]} == 0 )); then
    for d in "$(_sp_profiles_dir)"/*/codex; do
      [[ -d "$d" ]] || continue
      d="${d%/codex}"; profiles+=("${d##*/}")
    done
  fi
  (( ${#profiles[@]} )) || return 0
  local lock="${FIVEDIVE_CLS_LOCK:-/run/lock/5dive-codex-login-sync.lock}" p
  {
    flock -w 10 9 || return 0
    for p in "${profiles[@]}"; do codex_login_sync_profile "$p"; done
  } 9>>"$lock"
  return 0
}
