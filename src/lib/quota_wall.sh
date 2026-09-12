
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
#
# TWO AGES, AND THE FILE'S AGE IS THE WEAKER ONE (iteration 3, quinn's finding).
# `account usage` falls back to the account's REMEMBERED reading when no bound
# seat carries a live cache, and then republishes it stamped `writtenAt = now`.
# Ageing only the snapshot would launder an eleven-day-old number into a current
# measurement — and the loop is self-sustaining, because a seat condemned on a
# stale number is a seat nobody starts, and a seat nobody starts never refreshes
# the cache. So the reading is aged by its OWN `asOf` (when it was MEASURED),
# not by when the file was written; an undated reading is `unmeasured` outright;
# and a reading whose window has already RESET is `unmeasured` too, because a
# percentage from a window that has since turned over is not a statement about
# the window we are in. Both fences point at `unmeasured`, never at `clear`:
# the failure we refuse is a green word we did not measure, and the failure we
# refuse just as hard is a red one.

# The wall itself. Anthropic reports used_percentage; at 100 the account cannot
# spend another token until the window resets.
QUOTA_WALL_PCT="${QUOTA_WALL_PCT:-100}"
# Past this age the reading is not a reading any more. Ten minutes matches
# HEADROOM_FRESH_SECS (cmd_account.sh) — the same freshness the rotation
# destination fence already trusts for the same caches. It fences BOTH the
# snapshot file and the reading inside it.
QUOTA_SNAPSHOT_MAX_AGE="${QUOTA_SNAPSHOT_MAX_AGE:-600}"
QUOTA_SNAPSHOT_FILE="${QUOTA_SNAPSHOT_FILE:-${STATE_DIR}/account-usage.json}"

# Field separator for the one-line wall record (unit separator, so a note
# containing spaces or pipes is safe).
QUOTA_US=$'\037'

# quota_wall_line <state> <window> <pct> <resetsAt> <age> <note> — the record.
quota_wall_line() {
  printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
    "${1:-}" "$QUOTA_US" "${2:-}" "$QUOTA_US" "${3:-}" "$QUOTA_US" \
    "${4:-}" "$QUOTA_US" "${5:-}" "$QUOTA_US" "${6:-}"
}

# quota_snapshot_publish <rows-json> — write the world-readable snapshot.
# Root-only in practice (only root could have read the caches in the first
# place); a failure here is never fatal to the command that produced the rows,
# because `account usage` printing its table matters more than a warm cache.
# The rows keep their own `asOf`/`remembered`: `writtenAt` says when we wrote,
# never when the number was true.
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

# quota_wall_reset_guard <record> <now> <account> — a reading whose window has
# reset is not a measurement of the window we are in. jq cannot parse the
# vendor's timestamp shapes ("…T00:00:00Z", "…T00:00Z", a bare date), so the
# comparison is done here with `date -d`; an UNPARSEABLE reset is left alone,
# because the reading itself is fresh (the asOf fence ran first) and we do not
# discard a measured wall over a timestamp format.
quota_wall_reset_guard() {
  local rec="$1" now="$2" acct="${3:-}" state window pct reset age note rts
  IFS="$QUOTA_US" read -r state window pct reset age note <<<"$rec"
  if [[ "$state" == "exhausted" && -n "$reset" ]]; then
    rts=$(date -d "$reset" +%s 2>/dev/null) || rts=""
    if [[ "$rts" =~ ^-?[0-9]+$ ]] && (( rts < now )); then
      quota_wall_line unmeasured "" "" "" "$age" \
        "account ${acct:-?} reading predates its own reset (that ${window:-quota} window reset at ${reset}) — it is not a measurement of the current window"
      return 0
    fi
  fi
  printf '%s\n' "$rec"
}

# quota_wall_account <account> -> ONE line, six unit-separated fields:
#   <state> <window> <pct> <resetsAt> <ageSec> <note>
# state: exhausted | clear | unmeasured.
# `window` names WHICH limit is at the wall (7d or 5h) so the surfaces can say
# it; when both are walled the longer window wins, because it is the one the
# operator cannot wait out. `ageSec` is the age of the READING (now - asOf),
# which is the number that decides freshness — not the age of the file.
quota_wall_account() {
  local account="${1:-}" snap now rec
  now=$(date +%s)
  if [[ -z "$account" ]]; then
    quota_wall_line unmeasured "" "" "" "" "seat is not bound to an auth account"
    return 0
  fi
  snap=$(quota_snapshot_read)
  if [[ -z "$snap" ]]; then
    quota_wall_line unmeasured "" "" "" "" \
      "no account-usage snapshot at ${QUOTA_SNAPSHOT_FILE} (run: sudo 5dive account usage)"
    return 0
  fi
  rec=$(jq -r --arg a "$account" --arg us "$QUOTA_US" --argjson now "$now" \
        --argjson wall "$QUOTA_WALL_PCT" --argjson maxage "$QUOTA_SNAPSHOT_MAX_AGE" '
    def esc: [.state, .window, .pct, .resetsAt, .age, .note]
             | map(if . == null then "" else tostring end) | join($us);
    ($now - (.writtenAt // 0)) as $fileage
    | if $fileage > $maxage then
        {state:"unmeasured", age:$fileage,
         note:"account-usage snapshot is \($fileage)s old (>\($maxage)s) — not a current reading"} | esc
      else
        ((.accounts // []) | map(select(.name == $a)) | first) as $row
        | if $row == null then
            {state:"unmeasured", age:$fileage, note:"no usage row for account \($a)"} | esc
          elif ($row.usage == null) then
            {state:"unmeasured", age:$fileage, note:"account \($a) has no readable usage"} | esc
          else
            ($row.usage.asOf) as $asof
            | ($row.usage.remembered // false) as $rem
            | (if ($asof | type) == "number" then (($now - $asof) | floor) else null end) as $readage
            | if $readage == null then
                {state:"unmeasured", age:$fileage,
                 note:"account \($a) reading carries no measurement time — we cannot tell when it was true"} | esc
              elif $readage > $maxage then
                {state:"unmeasured", age:$readage,
                 note:"account \($a) reading was MEASURED \($readage)s ago (>\($maxage)s)\(if $rem then ", recalled from the account record" else "" end) — the snapshot is fresh, the number in it is not"} | esc
              else
                (($row.usage.sevenDay) // null) as $d7
                | (($row.usage.fiveHour) // null) as $h5
                | (if ($d7 != null and (($d7.pct // -1) >= $wall)) then {w:"7d", u:$d7}
                   elif ($h5 != null and (($h5.pct // -1) >= $wall)) then {w:"5h", u:$h5}
                   else null end) as $hit
                | if $hit != null then
                    {state:"exhausted", window:$hit.w, pct:($hit.u.pct | floor),
                     resetsAt:($hit.u.resetsAt // ""), age:$readage,
                     note:"account \($a) is at \($hit.u.pct | floor)% of its \($hit.w) limit"} | esc
                  elif ($d7 == null and $h5 == null) then
                    {state:"unmeasured", age:$readage, note:"account \($a) reported neither window"} | esc
                  else
                    {state:"clear", window:(if $d7 != null then "7d" else "5h" end),
                     pct:((if $d7 != null then $d7.pct else $h5.pct end) | floor),
                     age:$readage, note:"account \($a) below the wall"} | esc
                  end
              end
          end
      end' <<<"$snap" 2>/dev/null) || rec=""
  if [[ -z "$rec" ]]; then
    quota_wall_line unmeasured "" "" "" "" "account-usage snapshot is not parseable"
    return 0
  fi
  quota_wall_reset_guard "$rec" "$now" "$account"
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
