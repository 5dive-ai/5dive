
# -------- quota wall — the account's usage, joined to the health surfaces ------
#
# DIVE-4342. Before this file, three surfaces answered "can this seat work?"
# without ever consulting the one number that decides it:
#
#   * `agent list`     said `ready`   — process up, credential parses.
#   * `liveness`       said `alive`   — the seat wrote a row before it was walled.
#   * `supervisor`     said `healthy` — its `quota-exhausted` class is scraped off
#                                       the seat's PANE, so it can only fire AFTER
#                                       the seat has tried and been refused, and
#                                       only while the tick is armed.
#
# Meanwhile `sudo 5dive account usage` printed `7D 101%` in one line. All three
# green words and the wall were true at the same moment, on a customer box
# (exact-swallow, 0.35.0, reported 2026-09-12).
#
# THE JOIN IS seat -> auth profile -> account usage, and the awkward half is
# PRIVILEGE: `account usage` needs root (it reads sibling agents' 0750 homes for
# their statusline caches), while `liveness` and `supervisor` run unprivileged.
# We do not widen sudo. Instead the privileged reader PUBLISHES what it read to
# a world-readable snapshot, and the unprivileged surfaces read the snapshot.
#
# WHAT IS STORED IS THE MEASUREMENT, NOT THE VERDICT. The snapshot carries the
# raw fiveHour/sevenDay pct + resetsAt + asOf it read; the exhausted/clear
# decision is made HERE, at read time, against the caller's own clock. Storing
# "exhausted" instead would freeze a classification into the file and leave every
# downstream consumer unable to ask a different question of it — and unable to
# notice that the reset has since passed.
#
# A SNAPSHOT HAS AN AGE AND THE AGE IS PART OF THE ANSWER. `unmeasured` is a
# first-class third state and never folds into `clear`: no snapshot, a snapshot
# older than QUOTA_SNAPSHOT_MAX_AGE, or an account with no usage record all mean
# WE DO NOT KNOW — which must not print as a green word on surfaces whose whole
# job is to stop printing green words they have not measured.

# The wall itself. Anthropic reports used_percentage; at 100 the account cannot
# spend another token until the window resets.
QUOTA_WALL_PCT="${QUOTA_WALL_PCT:-100}"
# Past this age the snapshot is not a reading any more. Ten minutes matches
# HEADROOM_FRESH_SECS (cmd_account.sh) — the same freshness the rotation
# destination fence already trusts for the same caches.
QUOTA_SNAPSHOT_MAX_AGE="${QUOTA_SNAPSHOT_MAX_AGE:-600}"
QUOTA_SNAPSHOT_FILE="${QUOTA_SNAPSHOT_FILE:-${STATE_DIR}/account-usage.json}"

# Field separator for the one-line wall record (unit separator, so a note
# containing spaces or pipes is safe).
QUOTA_US=$'\037'

# quota_snapshot_publish <rows-json> — write the world-readable snapshot.
# Root-only in practice (only root could have read the caches in the first
# place); a failure here is never fatal to the command that produced the rows,
# because `account usage` printing its table matters more than a warm cache.
quota_snapshot_publish() {
  local rows="${1:-}" tmp
  [[ -n "$rows" ]] || return 0
  [[ -d "$STATE_DIR" ]] || return 0
  tmp="${QUOTA_SNAPSHOT_FILE}.tmp.$$"
  jq -cn --argjson rows "$rows" --argjson at "$(date +%s)" \
    '{writtenAt:$at, accounts:$rows}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$QUOTA_SNAPSHOT_FILE" 2>/dev/null || { rm -f "$tmp"; return 0; }
  return 0
}

# quota_snapshot_read — emit the snapshot object, or nothing.
quota_snapshot_read() {
  [[ -s "$QUOTA_SNAPSHOT_FILE" ]] || return 0
  [[ -r "$QUOTA_SNAPSHOT_FILE" ]] || return 0
  jq -ce '.' "$QUOTA_SNAPSHOT_FILE" 2>/dev/null || return 0
}

# quota_wall_account <account> -> ONE line, six unit-separated fields:
#   <state> <window> <pct> <resetsAt> <ageSec> <note>
# state: exhausted | clear | unmeasured.
# `window` names WHICH limit is at the wall (7d or 5h) so the surfaces can say
# it; when both are walled the longer window wins, because it is the one the
# operator cannot wait out.
quota_wall_account() {
  local account="${1:-}" snap now
  now=$(date +%s)
  if [[ -z "$account" ]]; then
    printf 'unmeasured%s%s%s%s%s%sseat is not bound to an auth account\n' \
      "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US"
    return 0
  fi
  snap=$(quota_snapshot_read)
  if [[ -z "$snap" ]]; then
    printf 'unmeasured%s%s%s%s%s%sno account-usage snapshot at %s (run: sudo 5dive account usage)\n' \
      "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_SNAPSHOT_FILE"
    return 0
  fi
  jq -r --arg a "$account" --argjson now "$now" \
        --argjson wall "$QUOTA_WALL_PCT" --argjson maxage "$QUOTA_SNAPSHOT_MAX_AGE" '
    def esc: [.state, .window, .pct, .resetsAt, .age, .note]
             | map(if . == null then "" else tostring end) | join("");
    ($now - (.writtenAt // 0)) as $age
    | if $age > $maxage then
        {state:"unmeasured", age:$age,
         note:"account-usage snapshot is \($age)s old (>\($maxage)s) — not a current reading"} | esc
      else
        ((.accounts // []) | map(select(.name == $a)) | first) as $row
        | if $row == null then
            {state:"unmeasured", age:$age, note:"no usage row for account \($a)"} | esc
          elif ($row.usage == null) then
            {state:"unmeasured", age:$age, note:"account \($a) has no readable usage"} | esc
          else
            (($row.usage.sevenDay) // null) as $d7
            | (($row.usage.fiveHour) // null) as $h5
            | (if ($d7 != null and (($d7.pct // -1) >= $wall)) then {w:"7d", u:$d7}
               elif ($h5 != null and (($h5.pct // -1) >= $wall)) then {w:"5h", u:$h5}
               else null end) as $hit
            | if $hit != null then
                {state:"exhausted", window:$hit.w, pct:($hit.u.pct | floor),
                 resetsAt:($hit.u.resetsAt // ""), age:$age,
                 note:"account \($a) is at \($hit.u.pct | floor)% of its \($hit.w) limit"} | esc
              elif ($d7 == null and $h5 == null) then
                {state:"unmeasured", age:$age, note:"account \($a) reported neither window"} | esc
              else
                {state:"clear", window:(if $d7 != null then "7d" else "5h" end),
                 pct:((if $d7 != null then $d7.pct else $h5.pct end) | floor),
                 age:$age, note:"account \($a) below the wall"} | esc
              end
          end
      end' <<<"$snap" 2>/dev/null \
    || printf 'unmeasured%s%s%s%s%s%saccount-usage snapshot is not parseable\n' \
         "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US" "$QUOTA_US"
}

# quota_seat_account <seat> — the seat's bound auth profile, from the registry.
# Empty when the seat has no binding (it then runs on the box default, which this
# join cannot name — so the answer is `unmeasured`, never `clear`).
quota_seat_account() {
  local seat="${1:-}" reg
  [[ -n "$seat" ]] || return 0
  reg=$(registry_read 2>/dev/null) || return 0
  [[ -n "$reg" ]] || return 0
  jq -r --arg n "$seat" '.agents[$n].authProfile // ""' <<<"$reg" 2>/dev/null || return 0
}

# quota_wall_seat <seat> — same line shape as quota_wall_account, resolved
# through the seat's binding.
quota_wall_seat() {
  local seat="${1:-}" acct
  acct=$(quota_seat_account "$seat")
  quota_wall_account "$acct"
}

# quota_wall_phrase <window> <pct> <resetsAt> — the one human clause all three
# surfaces print, so `agent list`, `liveness` and `supervisor` cannot drift into
# describing the same wall three different ways.
quota_wall_phrase() {
  local win="${1:-}" pct="${2:-}" reset="${3:-}"
  printf 'account at %s%% of its %s limit' "${pct:-?}" "${win:-quota}"
  [[ -n "$reset" ]] && printf ' — resets %s' "$reset"
  printf '\n'
}
