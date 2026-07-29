# --- env overrides: REPORT the FIVE_* knobs in effect and configured (DIVE-2327) ---
#
# WHAT THIS IS FOR. `doctor` and `selfcheck` answer "what is true on this box". A
# product knob in effect IS true on this box, and until now no surface anywhere said
# so. That silence is correct for an INTENDED knob and identical for an accidental
# one, and nothing distinguished them.
#
# THIS REPORTS. IT DOES NOT WARN. Name and value, nothing else — no "unexpected", no
# severity, no advice, no colour. The knobs are normally deliberate (lodar's
# 2026-07-29 backlog policy sets FIVE_VERIFY_DEFAULT=0 for sixteen agents), so
# alarming on them would be crying wolf on correct configuration. Reporting them costs
# nothing when intended and is the only thing that makes an unintended one findable.
# A line that judges is the defect this exists to prevent, not a nicer version of it.
#
# TWO SOURCES, DISTINCTLY LABELLED, and the second is the whole point:
#   process    — FIVE_* exported in the environment of THIS running command.
#   configured — FIVE_*= assignments in the EnvironmentFile targets systemd injects.
# A knob present in `configured` and absent from `process` is a knob that will bind on
# the next restart and is INVISIBLE to any process-side read. That gap cost an hour on
# DIVE-2325: a /proc/<pid>/environ sweep across the fleet found the knob in one session
# and was read as "one operator exported it", when sixteen agents were configured and
# fifteen had not restarted yet. The sweep measured RESTART ORDER and looked exactly
# like it measured configuration.
#
# WHERE THE TWO DISAGREE, BOTH LINES ARE PRINTED AND NOTHING IS CONCLUDED. No "drift",
# no "mismatch". A difference is a fact about restart order, not about correctness, and
# this code cannot tell which — naming it would be the warning this row exists to avoid.
#
# UNREADABLE IS NOT ABSENT, and this is the trap the fix could most easily reintroduce.
# `selfcheck` does NOT require_root and /var/lib/5dive/agents.d is drwxr-s--- root:claude
# with 0640 files (measured), so a caller outside group `claude` globs it and gets
# nothing. Rendering that as an empty list says "no overrides are configured" when the
# truth is "I could not look" — the exact could-not-check-as-negative shape DIVE-2318
# was about. So the state is explicit and three-valued: read | unreadable | absent.
# "I could not read this" is a measurement fact, not a judgement.
#
# AND `partial` IS A FOURTH STATE, added after measuring rather than from the spec.
# DIVE-2327 asked for read | unreadable | absent. On the real host the unit resolves an
# EnvironmentFile outside agents.d that this caller cannot read, so sixteen files were
# read AND one was not — and a single flag rendered the whole thing "unreadable", which
# understates a read that mostly worked exactly as an empty list overstates one that did
# not. Same reasoning that produced the third state, applied one step further: a scan
# that covered some of its sources is neither a clean answer nor a failed one, and the
# consumer needs to know which files were missed (they are in configured_unreadable).
#
# NEVER DUMP A FILE. Several agents.d entries are SYMLINKS into
# /var/lib/5dive/auth-profiles/*/combined.env, which carry auth material. Only
# assignments whose NAME matches FIVE_* are ever extracted, and the value of any knob
# whose name looks credential-shaped is replaced before it is emitted. None match today;
# it is a forward guard so a reporting surface can never become an exfil path. Redaction
# says nothing about whether a knob should be set, so it is not judgement either.

# _env_ov_redact <name> <value> — the value, or a placeholder when the NAME is
# credential-shaped. Name-based on purpose: a value-based heuristic would have to look
# at the secret to decide, and would leak it through its own logic.
_env_ov_redact() {
  case "${1^^}" in
    *TOKEN*|*KEY*|*SECRET*|*PASSWORD*) printf '<redacted>' ;;
    *) printf '%s' "$2" ;;
  esac
}

# _env_ov_paths — the EnvironmentFile targets, one per line, resolved FROM THE UNIT so
# this reports what systemd actually injects rather than a path this file believes in.
# `%i` is the systemd instance specifier; every instance is a candidate, so it expands
# to a glob. Falls back to $ENV_DIR when systemctl is unavailable (containers, CI) —
# the fallback is the same directory, and callers label which source answered.
_env_ov_paths() {
  local line p out=""
  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r line; do
      p="${line#EnvironmentFile=}"; p="${p#-}"          # `-` = optional-if-missing
      [[ "$p" == *"%i"* ]] && p="${p//%i/*}"
      [[ -n "$p" ]] && out+="$p"$'\n'
    done < <(systemctl cat '5dive-agent@.service' 2>/dev/null \
             | grep -E '^EnvironmentFile=' || true)
  fi
  [[ -z "$out" ]] && out="${ENV_DIR:-/var/lib/5dive/agents.d}/*.env"$'\n'
  printf '%s' "$out"
}

# _env_overrides_json — the whole surface, as one compact JSON object.
#
#   {"process":[{name,value}],
#    "configured":[{name,value,file}],
#    "configured_state":"read"|"partial"|"unreadable"|"absent",
#    "configured_unreadable":[path,...]}
#
# `configured` stays an ARRAY, exactly as DIVE-2327 specified, and the third state rides
# alongside it rather than replacing it — a consumer written against the specified shape
# keeps working, and one that cares about the difference between "none" and "could not
# look" has an explicit field to read instead of inferring it from emptiness.
#
# OPTIONAL ARGS ARE THE TEST SEAM: each argument is a path GLOB to read instead of the
# unit-resolved defaults. Deliberately an argument and NOT an environment variable — a
# `FIVE_*` override hook would be scrubbed by tests/lib/env_isolation.sh (DIVE-2325) and,
# worse, would show up in this surface's own output as a knob in effect. A reporting
# surface must not report its own test rig.
_env_overrides_json() {
  local n v pat f raw name val d
  local proc='[]' conf='[]' unread='[]' state="absent" touched=0 missed=0
  local -a _paths=()
  if [[ $# -gt 0 ]]; then _paths=("$@"); else mapfile -t _paths < <(_env_ov_paths); fi

  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    v=$(_env_ov_redact "$n" "${!n-}")
    proc=$(jq -c --arg k "$n" --arg v "$v" '. + [{name:$k, value:$v}]' <<<"$proc")
  done < <(compgen -e 2>/dev/null | grep '^FIVE_' | sort || true)

  while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    # A glob that matches nothing leaves the pattern itself in $f — that is "no such
    # file", i.e. absent, and must not be confused with a file we failed to read.
    for f in $pat; do
      if [[ ! -e "$f" ]]; then continue; fi
      if [[ ! -r "$f" ]]; then
        unread=$(jq -c --arg p "$f" '. + [$p]' <<<"$unread"); missed=1; continue
      fi
      touched=1
      # ONLY FIVE_*-named assignments ever leave this loop. The file is never echoed.
      while IFS= read -r raw; do
        raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw#export }"
        name="${raw%%=*}"; val="${raw#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        val=$(_env_ov_redact "$name" "$val")
        conf=$(jq -c --arg k "$name" --arg v "$val" --arg f "$f" \
                 '. + [{name:$k, value:$v, file:$f}]' <<<"$conf")
      done < <(grep -E '^[[:space:]]*(export[[:space:]]+)?FIVE_[A-Za-z0-9_]+=' "$f" 2>/dev/null || true)
    done
  done < <(printf '%s\n' "${_paths[@]}")

  # A directory we cannot even enumerate returns "no files matched" above, which would
  # render as absent. Check each pattern's CONTAINING DIRECTORY so a permission wall is
  # reported as one. Derived from the patterns rather than from $ENV_DIR so it covers the
  # unit-resolved paths outside agents.d too — on this host the unit names an
  # EnvironmentFile under /etc that a non-root caller cannot read, which is precisely the
  # mixed case the single-flag version got wrong.
  for pat in "${_paths[@]}"; do
    [[ -n "$pat" ]] || continue
    d="${pat%/*}"; [[ "$d" == "$pat" ]] && continue
    if [[ -d "$d" ]] && { [[ ! -x "$d" ]] || [[ ! -r "$d" ]]; }; then
      unread=$(jq -c --arg p "$d" '. + [$p]' <<<"$unread"); missed=1
    fi
  done
  unread=$(jq -c 'unique' <<<"$unread")

  # Fold the two measured facts into one state LAST, so the ordering of files on disk
  # cannot decide the answer. touched=did we read anything, missed=was anything denied.
  if   (( touched && missed )); then state="partial"
  elif (( touched ));            then state="read"
  elif (( missed ));             then state="unreadable"
  else                                state="absent"
  fi

  jq -cn --argjson p "$proc" --argjson c "$conf" --arg s "$state" --argjson u "$unread" \
    '{process:$p, configured:$c, configured_state:$s, configured_unreadable:$u}'
}
