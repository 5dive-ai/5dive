
# -------- doctor (health check + optional auto-repair) --------
#
# Mental model: the dashboard invokes `5dive doctor --json` periodically, and
# users hit `5dive doctor --repair` from a "fix problems" button. Each check
# reports:
#   - severity: ok | warn | error
#   - fixable:  does this check know how to repair itself?
#   - repaired: did --repair actually fix it this run?
# The envelope is always {ok:true, data:{summary,checks}} (exit 0) so the
# dashboard can render partial results even when individual checks fail.
# Use data.summary.errors to branch in CI.

# Accumulator rebuilt on every cmd_doctor invocation. Script-scope so the
# check helpers below don't need to pass it around.
DOCTOR_CHECKS='[]'
DOCTOR_REPAIR=0
# Capability report (DIVE-3076). Empty means "not built this run" — the JSON
# key is then `null`, which a reader must not confuse with a measured NO.
DOCTOR_CAPS=''

# doctor_add <category> <name> <severity> <message> [fixable:true|false] [repaired:true|false]
doctor_add() {
  local category="$1" name="$2" severity="$3" message="$4"
  local fixable="${5:-false}" repaired="${6:-false}"
  DOCTOR_CHECKS=$(jq -c \
    --arg c "$category" --arg n "$name" --arg s "$severity" --arg m "$message" \
    --argjson f "$fixable" --argjson r "$repaired" \
    '. + [{category:$c, name:$n, severity:$s, message:$m, fixable:$f, repaired:$r}]' \
    <<<"$DOCTOR_CHECKS")
  [[ "$severity" != "ok" ]] && step "[$severity] $category/$name: $message"
  return 0
}

# doctor_check_cmd <name> <executable> [apt-repair-package]
# Uses the host's PATH (root). Not suitable for "is bun on user claude's
# PATH" — that needs a sudo hop; handled inline in cmd_doctor.
doctor_check_cmd() {
  local name="$1" exe="$2" pkg="${3:-}"
  if command -v "$exe" >/dev/null 2>&1; then
    doctor_add deps "$name" ok "$exe found at $(command -v "$exe")"
    return 0
  fi
  local fixable=false
  [[ -n "$pkg" ]] && fixable=true
  if (( DOCTOR_REPAIR )) && [[ -n "$pkg" ]]; then
    step "Installing $pkg (apt-get)"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >&2 \
       && command -v "$exe" >/dev/null 2>&1; then
      doctor_add deps "$name" ok "$exe installed via apt ($pkg)" true true
      return 0
    fi
    doctor_add deps "$name" error "$exe missing; apt install $pkg failed" "$fixable" false
    return 1
  fi
  doctor_add deps "$name" error "$exe not found on PATH" "$fixable" false
  return 1
}

# doctor_check_audit_drop_dir [path] [expected-group]
#
# The audit drop marker is the evidence rail for an audit append that failed.
# It can only do that job when its parent already exists with the shape
# audit_init promises: a real, setgid, group-writable directory owned by group
# claude. Checking the marker file itself is insufficient: before the first
# drop there is no file, and a missing/regular-file parent is a structural
# failure rather than a disk-write failure.
doctor_check_audit_drop_dir() {
  local dir="${1:-${AUDIT_LOG%/*}/notify}"
  local expected_group="${2:-claude}"
  local mode group

  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    doctor_add host audit-drop-dir error \
      "$dir is missing — lost audit rows cannot leave a drop marker (expected directory mode 2770, group $expected_group)"
    return 0
  fi
  if [[ ! -d "$dir" || -L "$dir" ]]; then
    doctor_add host audit-drop-dir error \
      "$dir is not a real directory — lost audit rows cannot leave a drop marker (expected mode 2770, group $expected_group)"
    return 0
  fi

  mode=$(stat -c '%a' "$dir" 2>/dev/null) || mode="unknown"
  group=$(stat -c '%G' "$dir" 2>/dev/null) || group="unknown"
  if [[ "$mode" != "2770" || "$group" != "$expected_group" ]]; then
    doctor_add host audit-drop-dir error \
      "$dir has mode $mode and group $group — lost audit rows need a setgid, group-writable directory (expected 2770, group $expected_group)"
    return 0
  fi

  doctor_add host audit-drop-dir ok \
    "$dir is a directory with mode 2770 and group $expected_group; lost audit rows can leave a drop marker"
}

# doctor_check_cli_freshness [installed-bin] [probe-output]
#
# DIVE-2640 (split of DIVE-2621 item a) — NOTHING ON THIS BOARD DISTINGUISHED
# MERGED FROM INSTALLED. On 2026-08-03 four agents who did not know about each
# other closed rows against `origin/main` while the artifact their readers
# actually execute — `/usr/local/bin/5dive`, driven by cron every five minutes —
# was a different, older bundle. See
# community/wiki/merged-to-main-is-a-claim-about-the-authors-artifact-not-the-readers.md.
# This is the per-host surface that answers, in one command, the question that
# board had no way to ask: IS WHAT IS RUNNING WHAT WE MERGED?
#
# Three rows, because they are three different facts and collapsing them is how
# the strong one gets read off the weak one:
#
#   cli-installed    what the binary IS   — path, the version it declares, mtime
#   cli-freshness    is it BEHIND         — declared version vs the newest tag
#                                           the installer would actually resolve
#   cli-provenance   is that version TRUE — sha256 of the installed bytes vs the
#                                           bundle published at that tag
#
# WHY PROVENANCE IS ITS OWN ROW AND NOT A DETAIL ON THE FRESHNESS ONE. A version
# string is a claim a bundle makes about itself. `0.18.0+dive2563` satisfied a
# "runtime reads 0.18.x" criterion while being hand-built, carrying unmerged
# code, and missing two published releases — and `sort -V` ranks that suffix
# ABOVE the plain tag, so it also disabled the self-update that would have
# corrected it (see
# community/wiki/a-hand-stamped-build-suffix-satisfies-a-version-criterion.md).
# Byte identity against the bundle committed at the tag is what makes the version
# a CONSEQUENCE of provenance instead of an assertion about it.
#
# TWO CONSTRAINTS FROM THE INCIDENT, both load-bearing:
#
#  1. NO SYMBOL GREPPING. It is tempting to answer "is the fix deployed" with
#     `grep -c <function> /usr/local/bin/5dive`. A function present in a bundle
#     is not a function that executed, and the identity check below is strictly
#     stronger anyway: it grades ALL the bytes against a known published object
#     rather than one string against an expectation. Where the evidence really is
#     only presence, it gets labelled presence.
#
#  2. NO GREEN THE CHECK DID NOT EARN. Every way this can fail to run — no
#     binary, an unreadable one, a bundle with no version line, no network, a
#     tag that will not resolve — defaults to the empty, reassuring answer. Each
#     one is filed as UNKNOWN at `warn`, never `ok`. A freshness check inherits
#     its denominator from its own visibility
#     (community/wiki/a-freshness-check-inherits-its-denominator-from-its-own-visibility.md),
#     so the accepting evidence for this function is the STALE arm going red and
#     each cannot-run arm reading UNKNOWN — a pass on a host that happens to be
#     current is a non-vacuity control and never the result.
#
# Both parameters exist so the arms above can be MUTATED offline: $1 points the
# check at a deliberately stale or unreadable bundle, $2 substitutes the probe's
# four-line answer so no arm needs the network to be graded.
doctor_check_cli_freshness() {
  local bin="${1:-/usr/local/bin/5dive}"
  local probe="${2-}"
  local installed_ver="" mtime="" sha=""

  # --- row 1: what IS installed -------------------------------------------
  # `-e` then `-r`: absent and denied are different answers and only one of them
  # is about this box being unprovisioned. Neither is "fine".
  if [[ ! -e "$bin" ]]; then
    doctor_add host cli-installed warn \
      "UNKNOWN — no installed CLI at $bin; this host runs 5dive from somewhere else (or not at all), so nothing here can say what is running"
    doctor_add host cli-freshness warn "UNKNOWN — no installed CLI at $bin to compare against the published release"
    doctor_add host cli-provenance warn "UNKNOWN — no installed CLI at $bin to identify"
    return 0
  fi
  if [[ ! -r "$bin" ]]; then
    doctor_add host cli-installed warn \
      "UNKNOWN — $bin exists but is not readable by $(id -un); an unreadable binary is a permission answer, not a freshness one"
    doctor_add host cli-freshness warn "UNKNOWN — $bin is unreadable, so its version cannot be compared to the published release"
    doctor_add host cli-provenance warn "UNKNOWN — $bin is unreadable, so its bytes cannot be identified"
    return 0
  fi

  mtime=$(stat -c '%y' "$bin" 2>/dev/null | cut -d. -f1) || mtime=""
  [[ -n "$mtime" ]] || mtime="unknown"
  # The bundle's own declaration, read the same way _published_cli_probe reads
  # the published one. This is a CLAIM until cli-provenance confirms it.
  installed_ver=$(grep -m1 -oP '(?<=^readonly FIVE_VERSION=")[^"]+' "$bin" 2>/dev/null) || installed_ver=""
  sha=$(sha256sum "$bin" 2>/dev/null | awk '{print $1}') || sha=""

  if [[ -z "$installed_ver" ]]; then
    doctor_add host cli-installed warn \
      "UNKNOWN — $bin declares no FIVE_VERSION (mtime $mtime); a bundle that will not say what it is cannot be graded fresh"
    doctor_add host cli-freshness warn "UNKNOWN — $bin declares no version to compare against the published release"
    doctor_add host cli-provenance warn "UNKNOWN — $bin declares no version, so there is no claim to check its bytes against"
    return 0
  fi

  doctor_add host cli-installed ok \
    "$bin declares $installed_ver, mtime $mtime${sha:+, sha256 ${sha:0:12}} — this is the artifact cron and every agent on this host actually execute"

  # --- the reference, resolved from the REMOTE ----------------------------
  # Never from a local checkout: a reference that shares a failure mode with the
  # population makes staleness self-cancelling, and the check is then most
  # confidently green exactly when the box is most stale. _published_cli_probe
  # mirrors install.sh's own tag resolution and fails CLOSED, which is why it is
  # reused here instead of a second resolver that would drift from it.
  [[ -n "$probe" ]] || probe=$(_published_cli_probe)
  local -a p=()
  mapfile -t p <<<"$probe"
  local state="${p[0]:-unavailable}" latest="${p[1]:-}" detail="${p[2]:-no detail}" pubsha="${p[3]:-}"

  if [[ "$state" != "consistent" || -z "$latest" ]]; then
    doctor_add host cli-freshness warn \
      "UNKNOWN — installed $installed_ver, but the newest published release could not be resolved ($state: $detail); this is not a statement that $installed_ver is current"
    doctor_add host cli-provenance warn \
      "UNKNOWN — no published bundle to identify $bin against ($state: $detail)"
    return 0
  fi

  # --- row 2: is it BEHIND ------------------------------------------------
  local age=""
  [[ "$mtime" != "unknown" ]] && age=", installed bundle dated $mtime"
  if version_lt "$installed_ver" "$latest"; then
    doctor_add host cli-freshness error \
      "STALE — this host runs $installed_ver but $latest is published$age; anything merged after $installed_ver is NOT running here, whatever the board says. Fix: sudo 5dive update"
  elif version_lt "$latest" "$installed_ver"; then
    # DIVE-2287: above the newest release is its own state, and it is the state
    # DIVE-2243's monotonicity guard REFUSES every subsequent upgrade from — so
    # this box will never self-correct back onto the release line.
    doctor_add host cli-freshness warn \
      "AHEAD — this host runs $installed_ver, above the newest published $latest$age; self-update refuses to move a box that is ahead, so it will not return to the release line on its own"
  else
    doctor_add host cli-freshness ok \
      "installed $installed_ver matches the newest published release $latest (from $detail)$age"
  fi

  # --- row 3: is that version TRUE ----------------------------------------
  #
  # ANCESTRY IS A POSITIVE-ONLY ORACLE AND THIS ROW IS BUILT TO INHERIT THAT
  # RATHER THAN FIGHT IT. Under squash merges a `git merge-base --is-ancestor`
  # answers FALSE for reasons that have nothing to do with whether the work
  # landed, because the squash rewrote the sha
  # (community/wiki/ancestry-is-a-positive-only-oracle-under-squash-merges.md).
  # Byte identity has the same asymmetry by construction: a MATCH proves the
  # installed bundle is the published release, and a NON-MATCH proves nothing
  # whatsoever. So the negative side is never rendered as "not merged" — it is
  # rendered as UNPROVEN, with the reason. A doctor row that printed the strong
  # negative would manufacture alarms about healthy boxes, which is the same
  # class of false report this row exists to end, pointed the other way.
  if [[ -z "$sha" || -z "$pubsha" ]]; then
    doctor_add host cli-provenance warn \
      "UNKNOWN — could not checksum both sides (installed ${sha:-unreadable}, published ${pubsha:-unavailable}), so $installed_ver stays an unverified claim"
  elif [[ "$sha" == "$pubsha" ]]; then
    # Two of the three legs of the identity, and the third is named rather than
    # assumed. A release tag is cut from main, so byte-equality with the bundle
    # committed at that tag is a positive answer to "does this correspond to a
    # commit that is an ancestor of main" — for THIS tag only.
    doctor_add host cli-provenance ok \
      "$bin is byte-identical to the bundle published at $detail (sha256 ${sha:0:12}) — the release tag is cut from main, so what is running here IS what we merged as of $latest"
  elif [[ "$installed_ver" == "$latest" ]]; then
    # The hand-stamp shape, and the only case where differing bytes are a defect
    # rather than an ordinary lag: the bundle CLAIMS the published version and is
    # not the published object.
    doctor_add host cli-provenance error \
      "$bin declares $installed_ver — the newest published version — but its bytes differ from the bundle published at $detail (installed ${sha:0:12}, published ${pubsha:0:12}). This is a hand-built or locally-staged bundle wearing a release number; its version string corresponds to no published commit and reading it as 'we are on $latest' is exactly the substitution DIVE-2621 is about"
  else
    # Stale or ahead: differing bytes are EXPECTED, and the only published object
    # we hold is the newest tag's. Say plainly that we cannot tell, rather than
    # inferring ancestry from a version string.
    doctor_add host cli-provenance warn \
      "CANNOT TELL — $bin declares $installed_ver, which is not the newest published $latest, so its bytes have nothing to be compared against here. This identity is a POSITIVE-ONLY oracle: a match proves the installed build is what we merged, a non-match proves NOTHING, because a squash merge rewrites the sha and this check holds only the newest tag's bundle anyway. Read this as UNPROVEN, never as 'not merged' — a row that printed 'not merged' here would manufacture alarms about healthy boxes"
  fi
}

# doctor_marketplace_reference_sha [remote-url] [branch]
#
# The PUBLISHED head of the plugin marketplace, read from the remote rather than
# from any local checkout: a shared clone on this box can sit arbitrarily far
# behind and would make every reader look current against it. Prints a 40-hex
# sha, or nothing with rc 1 when it could not be resolved (no network, renamed
# branch, unauthenticated remote). The caller must treat rc 1 as UNKNOWN.
doctor_marketplace_reference_sha() {
  local url="${1:-https://github.com/5dive-ai/5dive-plugins.git}"
  local branch="${2:-main}" out
  out=$(git ls-remote --heads "$url" "$branch" 2>/dev/null) || return 1
  out="${out%%[!0-9a-f]*}"
  [[ "$out" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$out"
}

# doctor_check_marketplace_clones [homes-root] [reference-sha] [clone-relpath]
#
# DIVE-2642 / DIVE-2621 item (d). The reader of a merged marketplace change is a
# CLONED AGENT, not a git tree — and the clone lives under each agent's own
# $HOME, so "is this deployed?" has a DIFFERENT ANSWER PER AGENT. On 2026-08-03
# one merged commit had five distinct shas live on this box at once and nothing
# reported it. A boolean would have been a lie: four agents on four shas have no
# single refresh.
#
# So this check reports a POPULATION — N of M, every sha named — and never a
# yes/no. Three rules it must not break:
#
#   1. Never green when it could not run. A missing reference, an unreadable
#      clone, or a home root with no agents in it reads UNKNOWN. An absence of
#      complaint is not evidence.
#   2. Never infer freshness from presence. The sha a clone's HEAD resolves to is
#      what that agent EXECUTES; a file existing under the clone is not.
#   3. A path we could not LOOK at is not a path we know is absent. Denial and
#      absence are indistinguishable from outside the permission boundary, so a
#      home whose plugins dir we cannot read counts as UNKNOWN, not as "no clone".
doctor_check_marketplace_clones() {
  local homes_root="${1:-/home}"
  local ref_sha="${2:-}"
  local rel="${3:-.claude/plugins/marketplaces/5dive-plugins}"
  local home name clone sha behind total msg sev
  local -a current=() stale=() unknown=() absent=()

  for home in "$homes_root"/*/; do
    home="${home%/}"
    name="${home##*/}"
    [[ -d "$home/.claude" ]] || continue   # not an agent home; not part of M
    clone="$home/$rel"
    if [[ ! -d "$clone" ]]; then
      if [[ -e "$home/.claude/plugins" && ! -r "$home/.claude/plugins" ]]; then
        unknown+=("$name:unreadable-home")
      else
        absent+=("$name")
      fi
      continue
    fi
    sha=$(git -C "$clone" rev-parse HEAD 2>/dev/null) || sha=""
    if [[ -z "$sha" ]]; then
      unknown+=("$name:unreadable-clone")
    elif [[ -z "$ref_sha" ]]; then
      unknown+=("$name:${sha:0:7}")
    elif [[ "$sha" == "$ref_sha" ]]; then
      current+=("$name:${sha:0:7}")
    else
      # Distance is only computable when the published commit is in THIS clone's
      # object store; a clone that never fetched it can still be graded stale.
      behind=""
      if git -C "$clone" cat-file -e "${ref_sha}^{commit}" 2>/dev/null; then
        behind=$(git -C "$clone" rev-list --count "HEAD..$ref_sha" 2>/dev/null)
      fi
      if [[ -n "$behind" ]]; then
        stale+=("$name:${sha:0:7} (behind by $behind)")
      else
        stale+=("$name:${sha:0:7} (distance unknown)")
      fi
    fi
  done

  total=$(( ${#current[@]} + ${#stale[@]} + ${#unknown[@]} + ${#absent[@]} ))

  if (( total == 0 )); then
    doctor_add plugins marketplace-freshness warn \
      "UNKNOWN: no agent home found under $homes_root — nothing was measured, which is not the same as fresh"
    return 0
  fi

  if [[ -z "$ref_sha" ]]; then
    doctor_add plugins marketplace-freshness warn \
      "UNKNOWN: the published marketplace head could not be resolved (git ls-remote), so none of the $total agent clone(s) can be graded — UNKNOWN, not fresh$(doctor_mp_list ' | running:' "${unknown[@]}")"
    return 0
  fi

  msg="${#current[@]} of $total agent clones run published main ${ref_sha:0:7}"
  sev=ok
  if (( ${#stale[@]} || ${#unknown[@]} )); then
    sev=warn
    msg="STALE: $msg"
  fi
  msg+="$(doctor_mp_list ' | behind:' "${stale[@]}")"
  msg+="$(doctor_mp_list ' | UNKNOWN:' "${unknown[@]}")"
  msg+="$(doctor_mp_list ' | no clone:' "${absent[@]}")"
  if [[ "$sev" == warn ]]; then
    msg+=" — a clone's version is per-AGENT, so one refresh does not fix the fleet; each listed clone is its own git checkout under that agent's \$HOME/$rel"
  fi
  doctor_add plugins marketplace-freshness "$sev" "$msg"
}

# doctor_mp_list <label> [item...]  — " label a, b", or "" when there are none.
doctor_mp_list() {
  local label="$1"; shift
  (( $# )) || return 0
  local IFS=', '
  printf '%s %s' "$label" "$*"
}

# doctor_check_reaped_homes [dir]
#
# DIVE-2138 quarantines a removed agent's home under REAPED_DIR instead of
# deleting it: the home can hold credentials (auth.json, credentials.toml,
# channel .env) an operator still wants, and delete is not the moment to make
# that call irreversibly. DIVE-2165 is lodar's decision on what happens next —
# option B: no TTL, stay operator-managed forever, but STOP being invisible
# (root:root 0700 means it never shows up in a normal `ls`). This check is
# that visibility, and nothing else: count + oldest age, never a size (`du`
# here would slow the periodic `doctor --json` poll the same way the
# worktree-residue check below avoids it), and it never deletes anything.
doctor_check_reaped_homes() {
  local dir="${1:-$REAPED_DIR}"
  if [[ ! -e "$dir" ]]; then
    doctor_add host reaped-homes ok "$dir does not exist — no quarantined agent homes"
    return 0
  fi
  if [[ ! -d "$dir" || -L "$dir" ]]; then
    doctor_add host reaped-homes error \
      "$dir exists but is not a real directory — quarantine (DIVE-2138) cannot land there; a later \`agent rm\` will warn and leave the home in place"
    return 0
  fi

  local mode
  mode=$(stat -c '%a' "$dir" 2>/dev/null) || mode="unknown"
  if [[ "$mode" != "700" ]]; then
    doctor_add host reaped-homes warn \
      "$dir is mode $mode, not 700 — quarantined homes here can hold credentials (auth.json, credentials.toml, channel .env) and must not be group/world-readable"
  fi

  local n=0 oldest_ts=0 oldest_name="" entry ts
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    n=$((n + 1))
    ts=$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)
    if (( oldest_ts == 0 || ts < oldest_ts )); then
      oldest_ts=$ts
      oldest_name=$(basename "$entry")
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)

  if (( n == 0 )); then
    doctor_add host reaped-homes ok "$dir exists, 0 quarantined agent homes"
    return 0
  fi

  local days=$(( ($(date +%s) - oldest_ts) / 86400 ))
  doctor_add host reaped-homes ok \
    "$n quarantined agent home(s) under $dir, oldest is ${oldest_name} (~${days}d old) — operator-managed by design (DIVE-2165, no TTL); delete by hand once you're sure: sudo rm -rf $dir/<name>"
}

# --- caps: the per-seat capability probe (DIVE-3076) ------------------------
#
# WHAT THIS ANSWERS, AND WHY IT IS NOT A DOC. DIVE-3017: a seat declined to
# grade two items on the stated ground that it had no authenticated remote path,
# citing three true observations — https `git ls-remote` prompts, `gh auth
# status` is logged out, `/home/claude/.ssh/id_ed25519` is Permission denied.
# The conclusion was still false for four of nine seats: `sudo -u claude gh auth
# status` is logged in. Two seats spent a round trip each on a capability
# question, and a verifier nearly handed a grade back to the maker — the exact
# outcome the independence rule exists to prevent.
#
# The failure class is AN AGENT FORMING A FALSE BELIEF ABOUT ITS OWN
# CAPABILITY. A wiki page cannot close that: a page only reaches the agent who
# thinks to look it up, and the whole defect is believing there is nothing to
# look up. So the answer has to be DERIVED, per seat, by a command the seat
# already runs.
#
# AND IT IS NOT UNIFORM — this is the part that makes a documented answer worse
# than none. Measured across the live fleet 2026-08-09 (olivia,
# community/wiki/sudo-u-claude-is-per-seat-and-the-registry-already-measured-it.md):
#
#   olivia, main, dev, community      -> `sudo -u claude id -un` prints claude
#   dev2, dev3, main2, quinn, codex   -> sudo: a password is required
#
# Publishing "just use sudo -u claude" fixes a false negative for four seats and
# MINTS A FALSE POSITIVE FOR FIVE. A confident YES on a seat with no path is the
# one output this probe must never produce, which is what the negative arm of
# caps_probe_unit.sh grades (with a reason string, not an absence).
#
# WE DO NOT MEASURE THIS AFRESH. `agent_sudo_grant`'s `runas` field already
# predicted all nine results above with zero misses, because it is the same
# fact: `runas: any` means the sudoers entry permits an arbitrary runas target,
# `runas: root` means root ONLY. Note that isolation is the WRONG field to key
# on — two seats can both be `isolation: admin` and differ here, since `root-all`
# implies beyond-admin and `cli-root` does not.
#
# BOTH ARMS ARE REQUIRED. `runas: any` says the uid switch is PERMITTED. It says
# nothing about whether the claude uid's `gh` token is still valid or still
# scoped, so the account and scopes are read off a LIVE call and never off a
# cached string. A permitted switch onto a dead token is the one genuinely
# check-shaped state here, and it is the only one that files a row.
#
# WHY THIS IS A REPORT AND NOT A PILE OF CHECKS (the DIVE-2328 lesson, applied
# rather than re-learned): the dashboard renders `severity == "ok"` rows as
# PASSED CHECKS in green. `github:write NO` is a correct, permanent, by-design
# state on every seat — as a passing check it asserts a health nobody claimed,
# and as a `warn` it would light up half the fleet forever for being configured
# the way it is meant to be. Capability facts ride ALONGSIDE the checks in
# `capabilities`, exactly as env_overrides does, and touch no count.

# Seam 1 — WHICH SEAT IS ASKING. `doctor` is require_root, so `id -un` is always
# `root` and answers the wrong question; the seat is the REAL sudo caller. Empty
# means the caller is not an agent seat (a human, or cron, invoking as root
# directly), which is a different answer and not a failure. $SUDO_USER is
# forgeable by anyone who can set an env var, so this must never feed
# AUTHORIZATION — a seat that lies here gets a capability report for another
# seat, which grants it nothing it did not already have.
doctor_caps_seat() {
  local s="${SUDO_USER:-}"
  [[ "$s" == agent-* ]] && printf '%s' "$s"
  return 0
}

# Seam 2 — THE MEASURED GRANT for a seat, as `class|runas`. Wraps
# agent_sudo_grant (which fails closed to `unknown|-`) so the harness can drive
# the derivation without a sudoers fixture for every case.
doctor_caps_runas() {
  local g rest
  g=$(agent_sudo_grant "$1" 2>/dev/null) || g="unknown|-|0"
  [[ -n "$g" ]] || g="unknown|-|0"
  rest="${g#*|}"
  printf '%s|%s' "${g%%|*}" "${rest%%|*}"
}

# Seam 3 — THE LIVE TOKEN PROBE. Echoes `account<TAB>scopes` and returns 0 only
# when the claude uid answers as an authenticated gh. `sudo -n` so a seat
# without the grant is refused immediately instead of blocking doctor on a
# password prompt. Failure text is returned on stdout too (rc says which it is),
# because "permitted but the token is dead" has to name what went wrong.
doctor_caps_gh_probe() {
  local out acct scopes
  if ! out=$(sudo -n -u claude gh auth status 2>&1); then
    printf '%s' "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -1)"
    return 1
  fi
  acct=$(printf '%s\n' "$out" | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)
  scopes=$(printf '%s\n' "$out" | sed -n "s/.*[Tt]oken scopes: *//p" | head -1)
  scopes="${scopes//\'/}"
  printf '%s\t%s' "${acct:-unknown}" "${scopes:-none reported}"
  return 0
}

# doctor_build_caps — SETS $DOCTOR_CAPS; writes NOTHING to stdout. Files at
# most ONE check (the dead-token case); everything else is a fact about how this
# box is configured.
#
# THE RETURN CHANNEL IS A GLOBAL ON PURPOSE, and the first cut got this wrong in
# a way that only the harness saw. Written as `DOCTOR_CAPS=$(doctor_build_caps)`
# it reads fine and the report is correct — but a command substitution is a
# SUBSHELL, so the one thing here that is not a report, the `doctor_add` warn for
# a permitted-but-dead token, was appended to a copy of DOCTOR_CHECKS that died
# with the subshell. The report a reader sees would have been right while the
# check row that makes the dead path VISIBLE in --json silently never existed.
# A function that both emits a value and mutates accumulator state cannot be
# called by substitution; this one therefore emits no value at all.
doctor_build_caps() {
  local seat class runas probe read_state read_detail write_detail seat_label

  seat=$(doctor_caps_seat)
  if [[ -n "$seat" ]]; then
    local cr; cr=$(doctor_caps_runas "$seat")
    class="${cr%%|*}"; runas="${cr#*|}"
    seat_label="${seat#agent-} (sudo grant ${class}, runas ${runas})"
  else
    # Not an agent seat: the caller reached root directly, so the uid switch is
    # not in question. Reported as its own state rather than folded into `any`,
    # so nobody reads a human's YES as a statement about their seat.
    class="not-an-agent-seat"; runas="any"
    seat_label="${SUDO_USER:-root} — not an agent seat; this is the ROOT caller's answer, not a seat's"
  fi

  write_detail='push identity is per-seat and the claude-uid borrow is RETIRED for the push class (DIVE-3017) — this report is NOT permission to reopen it. Delegated route: `5dive push` (brokered, gated).'

  if [[ "$runas" != "any" ]]; then
    # THE NEGATIVE ARM. The reason is load-bearing: without it a reader on a
    # cli-root seat goes hunting for a password that does not exist.
    read_state="NO"
    read_detail="this seat's sudo grant is ${class}: root only, not arbitrary uids — there is no \`sudo -u claude\` path from here, and no password will make one. Route the read to a seat with runas=any (\`5dive agent list --json | jq -r '.data[]|select(.sudo.runas==\"any\")|.name'\`)."
  elif probe=$(doctor_caps_gh_probe); then
    read_state="YES"
    read_detail="via \`sudo -u claude gh\` (account ${probe%%$'\t'*}, scopes ${probe#*$'\t'}). A READ of a build product under a shared token mints nothing and authors nothing — verifier independence attaches to accepting a maker's CLAIM, not to whose credential opened the file."
  else
    read_state="NO"
    read_detail="\`sudo -u claude\` is permitted here (runas any) but gh is not usable as that uid: ${probe:-no output}"
    # The one genuinely check-shaped state: the fleet-wide read path is
    # advertised and dead. Every seat that trusts the advertisement is about to
    # burn a round trip discovering this.
    doctor_add caps github-read-token warn \
      "the claude-uid read path is permitted from this seat but its gh token is not usable: ${probe:-no output} — re-auth as claude (sudo -u claude gh auth login) or the fleet's documented CI-read route is dead"
  fi

  DOCTOR_CAPS=$(jq -cn \
    --arg seat "$seat_label" --arg class "$class" --arg runas "$runas" \
    --arg rstate "$read_state" --arg rdetail "$read_detail" --arg wdetail "$write_detail" \
    '{seat: $seat, sudoGrant: $class, runas: $runas,
      "github:read":  {state: $rstate, detail: $rdetail},
      "github:write": {state: "NO",    detail: $wdetail}}')
  return 0
}

# ── openclaw model-pin re-grade (DIVE-3457) ────────────────────────────────
#
# WHY THIS EXISTS. An OPENCLAW_PROVIDER_MODEL row is graded against
# `openclaw models list --provider <native> --plain` AT THE MOMENT THE ROW IS
# WRITTEN (that is the rule in the header; DIVE-3184 is a worked example of
# following it). Nothing re-checks it afterwards. The installed openclaw then
# upgrades underneath the row, and the already-written pin in a seat's
# openclaw.json is never rewritten. So a pin that has stopped resolving is a
# DATED OBSERVATION GONE STALE, not a bad write — and it is BYTE-IDENTICAL at
# the file level to one that still resolves, dying at the same place with the
# same 401 (community/wiki/an-unconfigured-model-authenticates-against-the-
# wrong-provider.md: the error names auth and hides provider selection).
#
# WHY IT IS NOT IN THE DEFAULT SWEEP, and why it is not a create-time probe.
# Each provider costs a full openclaw process: measured 5.8s for one
# `--provider minimax --plain` on this host, so the seven catalog rows are ~40s.
# The dashboard polls `doctor --json`, and `selfcheck_cred_reached_agent` re-runs
# continuously on the agent-list health rail — paying 40s there buys nothing,
# because the answer cannot change between runs on a fixed openclaw build
# (dev2 + quinn, DIVE-3442). So this is its OWN opt-in category: it runs from
# `doctor --category=models`, on a schedule or right after an openclaw upgrade,
# and never from a bare `doctor`.
#
# WHY THE CONTROLS ARE PART OF THE CHECK AND NOT PART OF THE TEST. On the
# version the rows were graded against, every row resolves — so an all-green run
# proves only that the probe RETURNED. Two controls run first, every time, and
# their failure SUPPRESSES the verdict rather than colouring it:
#
#   non-vacuity  the control provider's list must be non-empty. `models list`
#                prints "No models found." at EXIT 0 for a provider it does not
#                enumerate AND for a provider spelled wrong (DIVE-3184 measured
#                those two byte-identical), so an openclaw that answers nothing
#                for everything would otherwise report all seven pins STALE —
#                the false ALARM, the mirror of the false green.
#   discrimination  a sentinel id known ABSENT must MISS. openai carries no
#                gpt-4 family at all on 2026.7.1-2 (20 ids, starting at gpt-5.3
#                — DIVE-2631), while models.dev still lists gpt-4o as present,
#                which is exactly why it is the sentinel: it is a live id
#                somewhere else and absent HERE. If it hits, the matcher is
#                looser than an exact id comparison and every green below is
#                worthless.
#
# The oracle is one-sided in the other direction too, and this check inherits
# that: a HIT is authoritative, a MISS on a provider whose whole list is empty
# says nothing (DIVE-3130/3184 — zai, qwen and huggingface enumerate nothing and
# are deliberately unpinned). A pin under an EMPTY list is therefore reported
# `warn` NO-ORACLE, never `error` stale.

OPENCLAW_PIN_CONTROL_PROVIDER="openai"
OPENCLAW_PIN_CONTROL_ABSENT="openai/gpt-4o"

# The node the openclaw shim is executed under. A VARIABLE and not a literal,
# and that is a fix, not a refactor: with the path hardcoded, the runtime guard
# below is a THIRD live seam the offline harness could not stub, so on any box
# without openclaw installed the check emitted one warn and returned at its
# first line. Every arm of tests/openclaw_pin_regrade_unit.sh then observed an
# empty tree — including the two arms that assert a verdict is ABSENT, which
# passed on that emptiness and reported the suppression working. An
# absence-assertion arm passes on empty output; the seam it depends on has to
# be injectable or the positive control cannot be written.
OPENCLAW_PIN_NODE_BIN="${OPENCLAW_PIN_NODE_BIN:-/home/claude/.local/bin/node}"

# openclaw_catalog_ids <native> — the provider's `--plain` id list on stdout.
# rc 1 when the runtime is missing (caller must not read that as an empty
# catalog). "No models found." is filtered out here rather than at the call
# sites: it is prose on stdout at exit 0, and leaving it in makes an empty
# catalog look like a one-id catalog.
openclaw_catalog_ids() {
  local native="$1"
  local node="$OPENCLAW_PIN_NODE_BIN" bin="${TYPE_BIN[openclaw]:-}"
  [[ -n "$bin" && -x "$node" && -x "$bin" ]] || return 1
  sudo -u claude -H env HOME=/home/claude PATH=/home/claude/.local/bin:/usr/bin:/bin \
    "$node" "$bin" models list --provider "$native" --plain 2>/dev/null \
    | grep -vxF 'No models found.' | grep . || true
}

# openclaw_written_pins — every ALREADY-WRITTEN model pin on this box, one
# `<path>\t<pin>` row per line. These are the rows the catalog table cannot
# speak for: `_apply_byo_openclaw` validates at WRITE time and the write already
# happened, DIVE-3442's push is a faithful copy of an already-graded value, and
# the boot seed re-syncs whatever is there. Three shapes hold one:
#   shared   /home/claude/.openclaw/openclaw.json
#   profile  <auth-profiles>/<name>/openclaw/.openclaw/openclaw.json  (HOME redirect)
#   seat     /home/agent-*/.openclaw/openclaw.json  (start-time sync target)
openclaw_written_pins() {
  local f pin
  for f in /home/claude/.openclaw/openclaw.json \
           "${AUTH_PROFILES_DIR}"/*/openclaw/.openclaw/openclaw.json \
           /home/agent-*/.openclaw/openclaw.json; do
    [[ -f "$f" ]] || continue
    pin=$(jq -r '.agents.defaults.model.primary // empty' "$f" 2>/dev/null) || continue
    [[ -n "$pin" ]] || continue
    printf '%s\t%s\n' "$f" "$pin"
  done
}

# doctor_check_openclaw_model_pins — re-grade catalog rows AND written pins
# against the INSTALLED catalog. Adds its own checks via doctor_add.
doctor_check_openclaw_model_pins() {
  local bin="${TYPE_BIN[openclaw]:-}"
  local node="$OPENCLAW_PIN_NODE_BIN"
  if [[ -z "$bin" || ! -x "$node" || ! -x "$bin" ]]; then
    doctor_add models openclaw-runtime warn \
      "openclaw is not installed here, so no pin was graded — this is a NOT-MEASURED, not a clean bill of health (install: 5dive agent install openclaw --upgrade)"
    return 0
  fi

  local version
  version=$(sudo -u claude -H env HOME=/home/claude PATH=/home/claude/.local/bin:/usr/bin:/bin \
    "$node" "$bin" --version 2>/dev/null | head -1)
  [[ -n "$version" ]] || version="unknown"

  # ── controls, before any verdict ────────────────────────────────────────
  local ctl_ids ctl_n
  ctl_ids=$(openclaw_catalog_ids "$OPENCLAW_PIN_CONTROL_PROVIDER")
  ctl_n=$(grep -c . <<<"${ctl_ids}" 2>/dev/null || printf 0)
  [[ -n "$ctl_ids" ]] || ctl_n=0
  if (( ctl_n == 0 )); then
    doctor_add models openclaw-pin-control error \
      "non-vacuity control FAILED: '$OPENCLAW_PIN_CONTROL_PROVIDER' enumerates 0 ids on $version, so the probe cannot tell a stale pin from a silent catalog — NO pin was graded this run (a verdict here would have called every pin stale)"
    return 0
  fi
  if grep -qxF "$OPENCLAW_PIN_CONTROL_ABSENT" <<<"$ctl_ids"; then
    doctor_add models openclaw-pin-control error \
      "discrimination control FAILED: sentinel '$OPENCLAW_PIN_CONTROL_ABSENT' is supposed to be ABSENT from '$OPENCLAW_PIN_CONTROL_PROVIDER' on this build and it MATCHED — the matcher is looser than an exact id comparison, so NO pin was graded this run"
    return 0
  fi
  doctor_add models openclaw-pin-control ok \
    "controls passed on $version: '$OPENCLAW_PIN_CONTROL_PROVIDER' enumerates $ctl_n ids (non-vacuity) and absent sentinel '$OPENCLAW_PIN_CONTROL_ABSENT' did not match (discrimination)"

  # ── catalog rows ────────────────────────────────────────────────────────
  # `rows` is counted in the loop rather than read as ${#OPENCLAW_PROVIDER_MODEL[@]}
  # in the summary line. That was forced (DIVE-3457, quinn iteration 1): arm G of
  # tests/local_array_unbound_default_unit.sh resolved every such read against a
  # creation earlier in the SAME function, so a file-scope `declare -A` in
  # src/header.sh could never satisfy it and the read red a guard with no defect
  # behind it. DIVE-3471 taught the resolver to accept a file-scope creation in
  # any sourced src file, so the read is no longer barred here — the loop count
  # simply stays, because rewriting a shipped, working summary line to exercise
  # the new capability buys nothing.
  local canonical native pin ids n stale=0 noracle=0 graded=0 rows=0
  for canonical in $(printf '%s\n' "${!OPENCLAW_PROVIDER_MODEL[@]}" | sort); do
    rows=$((rows + 1))
    pin="${OPENCLAW_PROVIDER_MODEL[$canonical]}"
    native="${OPENCLAW_PROVIDER_ID[$canonical]:-$canonical}"
    ids=$(openclaw_catalog_ids "$native")
    n=$(grep -c . <<<"${ids}" 2>/dev/null || printf 0)
    [[ -n "$ids" ]] || n=0
    if (( n == 0 )); then
      noracle=$((noracle + 1))
      doctor_add models "openclaw-row-${canonical}" warn \
        "NO ORACLE: '$native' enumerates nothing on $version, so pin '$pin' is neither confirmed nor refuted — an unenumerated namespace is not a proof of unroutability (DIVE-3130/3184). Do not delete the row on this."
    elif grep -qxF "$pin" <<<"$ids"; then
      graded=$((graded + 1))
      doctor_add models "openclaw-row-${canonical}" ok \
        "pin '$pin' still resolves on $version ($n ids in '$native')"
    else
      stale=$((stale + 1))
      doctor_add models "openclaw-row-${canonical}" error \
        "STALE PIN: '$pin' is ABSENT from '$native' on $version ($n ids). Every new openclaw seat on provider '$canonical' will be created with an id this build cannot resolve, report AUTH ok, and 401. Re-grade and edit OPENCLAW_PROVIDER_MODEL[$canonical] in src/header.sh: openclaw models list --provider $native --plain"
    fi
  done

  # ── already-written pins ────────────────────────────────────────────────
  local line path wpin wnative wids wn wrote=0
  while IFS=$'\t' read -r path wpin; do
    [[ -n "$path" ]] || continue
    wrote=$((wrote + 1))
    wnative="${wpin%%/*}"
    wids=$(openclaw_catalog_ids "$wnative")
    wn=$(grep -c . <<<"${wids}" 2>/dev/null || printf 0)
    [[ -n "$wids" ]] || wn=0
    if (( wn == 0 )); then
      doctor_add models "openclaw-written-${wrote}" warn \
        "NO ORACLE for written pin '$wpin' in $path: provider '$wnative' enumerates nothing on $version"
    elif grep -qxF "$wpin" <<<"$wids"; then
      doctor_add models "openclaw-written-${wrote}" ok \
        "written pin '$wpin' still resolves on $version ($path)"
    else
      doctor_add models "openclaw-written-${wrote}" error \
        "STALE WRITTEN PIN: '$wpin' in $path is ABSENT from '$wnative' on $version ($wn ids). This seat is already on disk — nothing rewrites it, so it will 401 on every message while reporting AUTH ok. Repair: sudo -u claude -H env HOME=$(dirname "$(dirname "$path")") PATH=/home/claude/.local/bin:/usr/bin:/bin $node $bin config set agents.defaults.model.primary <graded-id>"
    fi
  done < <(openclaw_written_pins)

  doctor_add models openclaw-pin-summary \
    "$( (( stale > 0 )) && printf error || printf ok )" \
    "graded ${graded}/${rows} catalog rows + ${wrote} written pin(s) against installed openclaw $version — ${stale} stale, ${noracle} no-oracle"
  return 0
}

# doctor_seat_claude_pid <agent-name> <user> — echo the PID of the seat's
# persistent claude session, or nothing. Prints ONE pid on stdout; never fails
# the caller (all pipelines end `|| true` for `set -euo pipefail`).
#
# DIVE-3958. The two callers below used to pick it as the longest-`etimes`
# `pgrep -u "$user" -f 'claude'` match. Two independent defects made that select
# a process the --repair restart can never reach:
#   1. `-f` matches the full ARGV, and this box's install root is /home/claude/,
#      so ANY long-lived process a seat owns whose path passes through that dir
#      (a discord bot, a stray helper) matches "claude" without being a claude
#      runtime. On agent-marketing it deterministically picked a 46-day-old
#      welcome_bot.py — older than the real session, so it won the etimes tiebreak.
#   2. pgrep is per-UID but `--repair` restarts a per-UNIT service. The evidence
#      set (UID) is strictly larger than what the remedy can change (unit), so
#      every process in the difference is a PERMANENT false positive: the plugin-
#      version check reads the decoy's ancient start, warns "stale", restarts a
#      unit that cannot contain the decoy, and loops forever.
# Fix both at once: scope to the seat's systemd unit (cgroup membership, which
# `systemctl restart` also keys on) AND match the EXECUTABLE (`comm=claude`), not
# a string a `.claude/` path component can satisfy. Within the unit's cgroup the
# telegram poller's cwd still contains `.claude`, so an argv match would re-pick
# it — comm does not.
doctor_seat_claude_pid() {
  local name="$1" user="$2" cg procs base="${DOCTOR_CGROUP_BASE:-/sys/fs/cgroup}"
  cg=$(systemctl show -p ControlGroup --value "5dive-agent@${name}.service" 2>/dev/null || true)
  [[ -n "$cg" && -r "${base}${cg}/cgroup.procs" ]] || return 0
  # Longest-running claude EXECUTABLE among the unit's own processes = the
  # persistent session, not a transient hook subprocess.
  procs=$(while read -r p; do
            [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == "claude" ]] || continue
            printf '%s %s\n' "$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')" "$p"
          done < "${base}${cg}/cgroup.procs" | sort -rn | awk 'NR==1{print $2}' || true)
  printf '%s' "$procs"
}

cmd_doctor() {
  require_root
  local filter="" want_fix=0 dry=0
  DOCTOR_REPAIR=0
  DOCTOR_CHECKS='[]'
  DOCTOR_CAPS=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      # --fix is the discoverable alias for the older --repair (both apply the
      # reversible auto-heals). --dry-run forces a preview: report what --fix
      # WOULD do without touching anything. (A bare `doctor` with no --fix is
      # already a preview — every fixable check says "run with --fix".)
      --fix|--repair) want_fix=1 ;;
      --dry-run)      dry=1 ;;
      # --caps is the name DIVE-3076 asked for and the name an agent will
      # type; it is exactly --category=caps, never a second code path.
      --caps)         filter="caps" ;;
      --category=*)   filter="${1#--category=}" ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  (( want_fix && ! dry )) && DOCTOR_REPAIR=1
  case "$filter" in
    # DIVE-2327: `policy` was MISSING from this allow-list while run_policy below
    # dispatches it and the usage text right underneath advertises it — so
    # `--category=policy` failed usage for every caller who read the error message
    # and did what it said. Pre-existing; fixed here because this change lands its
    # surface under that category and would otherwise be unreachable by filter.
    ""|deps|types|auth|creds|registry|shelld|channels|host|memory|policy|plugins|caps|models) ;;
    *) fail "$E_USAGE" "unknown --category (deps|types|auth|creds|registry|shelld|channels|host|memory|policy|plugins|caps|models)" ;;
  esac

  local run_deps=0 run_types=0 run_auth=0 run_creds=0 run_registry=0 run_shelld=0 run_channels=0 run_host=0 run_memory=0 run_policy=0
  local run_plugins=0 run_caps=0
  # DIVE-3457: `models` is the ONE category a bare `doctor` does NOT run. It
  # shells to openclaw once per provider (5.8s measured), and the dashboard
  # polls `doctor --json`. Opt-in keeps the poll cheap; the schedule and the
  # post-upgrade run ask for it by name.
  local run_models=0
  [[ -z "$filter" || "$filter" == "deps"     ]] && run_deps=1
  [[ -z "$filter" || "$filter" == "types"    ]] && run_types=1
  [[ -z "$filter" || "$filter" == "auth"     ]] && run_auth=1
  [[ -z "$filter" || "$filter" == "creds"    ]] && run_creds=1
  [[ -z "$filter" || "$filter" == "registry" ]] && run_registry=1
  [[ -z "$filter" || "$filter" == "shelld"   ]] && run_shelld=1
  [[ -z "$filter" || "$filter" == "channels" ]] && run_channels=1
  [[ -z "$filter" || "$filter" == "host"     ]] && run_host=1
  [[ -z "$filter" || "$filter" == "memory"   ]] && run_memory=1
  [[ -z "$filter" || "$filter" == "policy"   ]] && run_policy=1
  [[ -z "$filter" || "$filter" == "plugins"  ]] && run_plugins=1
  [[ -z "$filter" || "$filter" == "caps"     ]] && run_caps=1
  [[ "$filter" == "models" ]] && run_models=1

  # --- deps ---
  if (( run_deps )); then
    # /dev/null must be the character device. An agent with sudo (admin
    # isolation) can clobber it — e.g. `tmux -S /dev/null` unlinks it — which
    # crash-loops EVERY agent on the box (teal-fox 2026-06-03). Checked first
    # so --repair fixes it before other checks that redirect to /dev/null run.
    # 5dive-agent-start also self-heals this on each start.
    if [[ -c /dev/null ]]; then
      doctor_add deps devnull ok "/dev/null is a character device"
    elif (( DOCTOR_REPAIR )); then
      step "Recreating /dev/null device node"
      if sudo sh -c 'rm -f /dev/null && mknod /dev/null c 1 3 && chmod 666 /dev/null && chown root:root /dev/null' \
         && [[ -c /dev/null ]]; then
        doctor_add deps devnull ok "/dev/null recreated as character device" true true
      else
        doctor_add deps devnull error "/dev/null not a char device and repair failed (run: sudo mknod /dev/null c 1 3 && sudo chmod 666 /dev/null)" true false
      fi
    else
      doctor_add deps devnull error "/dev/null is not a character device — every agent crash-loops (fix: sudo 5dive doctor --repair)" true false
    fi

    doctor_check_cmd tmux      tmux      tmux
    doctor_check_cmd jq        jq        jq
    doctor_check_cmd python3   python3   python3
    doctor_check_cmd curl      curl      curl
    doctor_check_cmd sqlite3   sqlite3   sqlite3
    doctor_check_cmd sudo      sudo
    doctor_check_cmd systemctl systemctl
    doctor_check_cmd journalctl journalctl

    # bun is needed by the telegram plugin runtime. Checked via the agent
    # user's login shell (which sources /etc/profile.d/5dive-shared-configs.sh
    # + nvm), i.e. the same environment systemd ends up with. Falls back to
    # checking user `claude` if no agents exist yet.
    local bun_user="claude"
    if [[ -f "$REGISTRY" ]]; then
      local first_agent
      first_agent=$(jq -r '.agents | keys[0] // empty' "$REGISTRY" 2>/dev/null)
      [[ -n "$first_agent" ]] && id -u "agent-${first_agent}" &>/dev/null \
        && bun_user="agent-${first_agent}"
    fi
    local bun_path
    bun_path=$(sudo -u "$bun_user" -i bash -lc 'command -v bun' 2>/dev/null || true)
    if [[ -n "$bun_path" ]]; then
      doctor_add deps bun ok "bun at $bun_path (checked as $bun_user)"
    elif (( DOCTOR_REPAIR )); then
      step "Installing bun for user claude"
      if sudo -u claude -i bash -lc 'curl -fsSL https://bun.sh/install | bash' >&2 \
         && sudo -u "$bun_user" -i bash -lc 'command -v bun' >/dev/null 2>&1; then
        doctor_add deps bun ok "bun installed for user claude" true true
      else
        doctor_add deps bun error "bun install failed (telegram plugin won't start)" true false
      fi
    else
      doctor_add deps bun error "bun not on PATH for $bun_user (telegram plugin requires it)" true false
    fi

    # nvm + node + npm (node-based CLIs like codex depend on these)
    if [[ -s /home/claude/.nvm/nvm.sh ]]; then
      doctor_add deps nvm ok "/home/claude/.nvm/nvm.sh present"
    else
      doctor_add deps nvm error "/home/claude/.nvm/nvm.sh missing (codex won't run)" false false
    fi
    local node_ver npm_ver
    node_ver=$(sudo -u claude -i bash -lc 'node --version' 2>/dev/null || true)
    npm_ver=$(sudo -u claude -i bash -lc 'npm --version' 2>/dev/null || true)
    [[ -n "$node_ver" ]] \
      && doctor_add deps node ok "node $node_ver (via nvm)" \
      || doctor_add deps node error "node not available for user claude" false false
    [[ -n "$npm_ver" ]] \
      && doctor_add deps npm  ok "npm $npm_ver (via nvm)" \
      || doctor_add deps npm  error "npm not available for user claude" false false

    # 5dive shared helpers that every agent create/start depends on.
    for f in /usr/local/bin/5dive-agent-start; do
      if [[ -x "$f" ]]; then
        doctor_add deps "$(basename "$f")" ok "$f present"
      else
        doctor_add deps "$(basename "$f")" error "$f missing or not executable (rerun install.sh)" false false
      fi
    done
    # The StopFailure (rate-limit DM) and PreToolUse (AskUserQuestion/ExitPlanMode)
    # hooks used to be standalone scripts under /usr/local/lib/5dive checked here
    # via $STOP_FAILURE_HOOK / $PRETOOL_TELEGRAM_HOOK. They now ship bundled inside
    # the telegram plugin (per-agent, no fixed path), so those vars were removed —
    # the stale checks were left referencing them and crashed `doctor --json` with
    # an unbound-variable error under `set -u`. Dropped; nothing standalone to probe.
    local resume_helper="/usr/local/lib/5dive/resume-after-reset.sh"
    if [[ -x "$resume_helper" ]]; then
      doctor_add deps resume-after-reset ok "$resume_helper present"
    else
      doctor_add deps resume-after-reset warn "$resume_helper missing — agents won't auto-resume when usage limit resets" false false
    fi
  fi

  # --- type binaries ---
  if (( run_types )); then
    local type
    for type in "${!TYPE_BIN[@]}"; do
      local bin="${TYPE_BIN[$type]}"
      local recipe="${TYPE_INSTALL[$type]:-}"
      if [[ -x "$bin" ]]; then
        doctor_add types "$type" ok "$bin installed"
        continue
      fi
      if (( DOCTOR_REPAIR )) && [[ -n "$recipe" ]]; then
        step "Installing $type CLI"
        if sudo -u claude -i bash -lc "$recipe" >&2 && [[ -x "$bin" ]]; then
          doctor_add types "$type" ok "$type installed at $bin" true true
        else
          doctor_add types "$type" error "$type install recipe failed" true false
        fi
      elif [[ -n "$recipe" ]]; then
        doctor_add types "$type" warn "$bin missing (run with --repair to auto-install)" true false
      else
        doctor_add types "$type" warn "$bin missing (no automated installer for $type)" false false
      fi
    done
  fi

  # --- auth (live probe for installed types) ---
  if (( run_auth )); then
    local type status
    for type in "${!TYPE_BIN[@]}"; do
      [[ -x "${TYPE_BIN[$type]}" ]] || continue
      status=$(auth_status_one "$type")
      case "$status" in
        ok)
          doctor_add auth "$type" ok "live probe succeeded" ;;
        needs_login)
          doctor_add auth "$type" error "no credentials on file — run: sudo 5dive agent auth login $type" false false ;;
        stale)
          doctor_add auth "$type" error "credentials rejected by provider — re-auth required" false false ;;
        not_installed)
          : ;;  # already flagged by types/
        *)
          doctor_add auth "$type" warn "status=$status" false false ;;
      esac
    done
  fi

  # --- claude shadow-credential heal (DIVE-329) ---
  #
  # A leftover ~/.claude/.credentials.json in an agent's config dir takes
  # precedence over the CLAUDE_CODE_OAUTH_TOKEN that systemd injects. Once that
  # file's OAuth token expires and can't refresh, Claude Code 401s on the dead
  # file even though the env-token is valid (teal-fox class). heal_claude_shadow_creds
  # (cmd_auth.sh) renames a stale shadow file to .stale-<ts> so CC falls back to
  # the env-token — but ONLY for agents that carry a verified env-token, so it
  # can never strand an agent. --repair renames; otherwise we just warn. This is
  # file-only (no network), so it's safe to run on every soft-update tick.
  if (( run_creds )); then
    local heal_out
    heal_out=$(heal_claude_shadow_creds "$DOCTOR_REPAIR")
    if [[ -z "$heal_out" ]]; then
      doctor_add creds shadow-credentials ok "no stale ~/.claude/.credentials.json shadowing an env-token"
    else
      local hline verb nm bak
      while IFS= read -r hline; do
        [[ -n "$hline" ]] || continue
        verb=$(awk '{print $1}' <<<"$hline")
        nm=$(awk '{print $2}'   <<<"$hline")
        case "$verb" in
          healed)
            bak=$(awk '{print $4}' <<<"$hline")
            doctor_add creds "agent:$nm" ok \
              "renamed stale shadow creds -> $(basename "$bak"); CC now falls back to the env-token" true true ;;
          stale)
            doctor_add creds "agent:$nm" warn \
              "stale ~/.claude/.credentials.json shadows the env-token (expired/unrenewable) — will 401 as it ages; run with --repair to neutralize it" true false ;;
          error)
            doctor_add creds "agent:$nm" error \
              "stale shadow creds present but rename failed (check perms on /home/agent-$nm/.claude)" true false ;;
        esac
      done <<<"$heal_out"
    fi
  fi

  # --- registry + per-agent state ---
  if (( run_registry )); then
    if [[ ! -f "$REGISTRY" ]]; then
      if (( DOCTOR_REPAIR )); then
        ensure_state
        doctor_add registry file ok "initialized empty $REGISTRY" true true
      else
        doctor_add registry file error "$REGISTRY missing (run with --repair to init)" true false
      fi
    elif ! jq -e '.agents | type == "object"' "$REGISTRY" >/dev/null 2>&1; then
      doctor_add registry file error "$REGISTRY unparseable or missing .agents object (manual fix required)" false false
    else
      doctor_add registry file ok "$REGISTRY intact"
      local schema_v
      schema_v=$(jq -r '.schemaVersion // 0' "$REGISTRY" 2>/dev/null || echo 0)
      if (( schema_v == REGISTRY_SCHEMA_VERSION )); then
        doctor_add registry schema ok "schemaVersion=$schema_v (current)"
      elif (( schema_v < REGISTRY_SCHEMA_VERSION )); then
        if (( DOCTOR_REPAIR )); then
          ensure_state   # stamps the current version in place
          doctor_add registry schema ok "migrated schemaVersion $schema_v -> $REGISTRY_SCHEMA_VERSION" true true
        else
          doctor_add registry schema warn "schemaVersion=$schema_v (expected $REGISTRY_SCHEMA_VERSION) — run with --repair" true false
        fi
      else
        doctor_add registry schema error "schemaVersion=$schema_v is newer than this CLI ($REGISTRY_SCHEMA_VERSION) — upgrade 5dive" false false
      fi
      local reg
      reg=$(registry_read)
      local name
      for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
        local type env_file user
        type=$(jq -r --arg n "$name" '.agents[$n].type // empty' <<<"$reg")
        env_file="${ENV_DIR}/${name}.env"
        user="agent-${name}"
        if ! is_known_type "$type"; then
          doctor_add registry "agent:$name" error "unknown type '$type' in registry" false false
          continue
        fi
        if ! id -u "$user" &>/dev/null; then
          doctor_add registry "agent:$name" error "user $user missing (orphan registry entry — rm manually)" false false
          continue
        fi
        if [[ ! -f "$env_file" ]]; then
          if (( DOCTOR_REPAIR )); then
            local channels workdir profile
            channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'    <<<"$reg")
            workdir=$(jq  -r --arg n "$name" '.agents[$n].workdir // empty'      <<<"$reg")
            profile=$(jq  -r --arg n "$name" '.agents[$n].authProfile // empty'  <<<"$reg")
            write_agent_env "$name" "$type" "$channels" "$workdir" "$profile"
            link_agent_profile "$name" "$profile"
            doctor_add registry "agent:$name" ok "recreated $env_file" true true
          else
            doctor_add registry "agent:$name" error "$env_file missing (run with --repair)" true false
          fi
        else
          doctor_add registry "agent:$name" ok "entry + user + env file all present"
        fi
      done
    fi
  fi

  # --- channels: managed-settings allowlist + per-agent registration health ---
  #
  # Two failure modes we surface here:
  #   1. /etc/claude-code/managed-settings.json missing or missing the
  #      telegram@5dive-plugins entry — the local self-hosted case. Install.sh
  #      writes this on first install; flag if it's been hand-edited away.
  #   2. Claude logs "Channel notifications skipped: plugin telegram@5dive-plugins
  #      is not on the approved channels allowlist" — strong signal the agent
  #      is on a Teams org whose admin hasn't allowlisted us via remote
  #      managed-settings (remote overrides local). Linked from README.
  if (( run_channels )); then
    # DIVE-2041 (follow-up to the DIVE-2031 outage): the pinned "needs-you"
    # banner is single-pinner by design — only the resolved org coordinator
    # posts it (DIVE-1568), and every other agent unpins any banner it left
    # behind. When `task coordinator` resolves to NOBODY, "every other agent"
    # is ALL of them: the banner is unpinned in every paired DM and re-unpinned
    # on a 60s timer forever, while every component reports success. That is
    # how 12 pending human gates sat invisible for days.
    #
    # This check is the surface that names it. It computes the resolution HERE
    # rather than asking the plugin, deliberately: the plugin can only report
    # what it saw on its last tick, and a bot that is down reports nothing at
    # all — the state we most need to see. Severity is keyed to CONSEQUENCE,
    # not to the config: no coordinator with an empty gate queue is a latent
    # warn; no coordinator while human gates are pending is a live outage of a
    # human-safety surface, so it is an error and `summary.errors` carries it.
    if [[ -f "${TASKS_DB:-}" ]]; then
      local coord roots pending fixhint
      coord=$(_task_resolve_coordinator 2>/dev/null || true)
      if [[ -n "$coord" ]]; then
        doctor_add channels needs-banner-coordinator ok \
          "task coordinator resolves to '$coord' — the pinned needs-you banner has an owner"
      else
        roots=$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);" 2>/dev/null || echo 0)
        pending=$(db "SELECT COUNT(*) FROM tasks WHERE need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled');" 2>/dev/null || echo 0)
        fixhint="fix: give the chart ONE root (5dive org set <agent> --manager=<mgr>), or put 'coordinator' in one agent's role (5dive org set <agent> --role='<their prose> coordinator')"
        if [[ "${roots:-0}" == "0" ]]; then
          doctor_add channels needs-banner-coordinator warn \
            "no org chart — no coordinator, so the pinned needs-you banner is suppressed in every paired DM (5dive org set …)" false false
        elif [[ "${pending:-0}" -gt 0 ]]; then
          doctor_add channels needs-banner-coordinator error \
            "NO coordinator resolves (${roots} org roots, none tagged) and ${pending} human gate(s) are pending — the pinned needs-you banner is suppressed in EVERY paired DM and nothing else reports it (DIVE-2031/2041); ${fixhint}" false false
        else
          doctor_add channels needs-banner-coordinator warn \
            "no coordinator resolves (${roots} org roots, none tagged) — the pinned needs-you banner is suppressed in every paired DM; harmless while 0 gates are pending, invisible the moment one opens (DIVE-2031/2041); ${fixhint}" false false
        fi
      fi
    fi

    local ms=/etc/claude-code/managed-settings.json
    # DIVE-3537: human-readable rendering of the ONE canonical set, so the [ok]
    # line names what it actually asserted instead of a hand-typed pair that can
    # go stale the next time a channel ships.
    local ms_want
    ms_want=$(jq -r '[.[] | "\(.plugin)@\(.marketplace)"] | join(", ")' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON" 2>/dev/null) \
      || ms_want="the 5dive fork channels"
    # DIVE-1843: the DIVE-1816 fix reconciles this allowlist on install.sh rerun
    # only, so boxes provisioned before the dashboard channel shipped stayed
    # broken (dashboard-chat pings silently dropped) until a human reran
    # install.sh per box. These checks are now SELF-HEALING under --fix (and the
    # nightly selfupdate calls the same reconcile), so an existing box repairs
    # itself with no human action. reconcile_managed_settings ensures
    # channelsEnabled:true + EVERY 5dive fork channel, never clobbering operator
    # or upstream entries; exit 0=changed, 3=already-current, 1=can't reconcile.
    #
    # DIVE-3537: the gate below is managed_settings_channels_ok, which sits next
    # to that fixer and reads the same FIVEDIVE_CHANNEL_PLUGINS_JSON. It used to
    # be an inline jq naming telegram+dashboard by hand, and it went stale the
    # day buzz was added to the fixer — so this check printed [ok] on every box
    # missing buzz and the self-heal never ran. Do not re-inline the list here.
    if [[ ! -f "$ms" ]]; then
      doctor_add channels managed-settings warn \
        "$ms missing — rerun install.sh, or expect channel-skipped errors" false false
    elif managed_settings_channels_ok "$ms"; then
      doctor_add channels managed-settings ok \
        "$ms has channelsEnabled + every 5dive fork channel allowlisted ($ms_want)"
    else
      # Stale/incomplete allowlist: channelsEnabled off, or a 5dive fork channel
      # unlisted → Claude drops those inbound pings. Name the specific gap so the
      # report is precise, then auto-heal under --fix.
      local gap="" missing=""
      jq -e '.channelsEnabled == true' "$ms" >/dev/null 2>&1 \
        || gap="missing channelsEnabled:true (Claude Code 2.1.150+ requires it; allowlist otherwise inert)"
      # DIVE-3537: the gap names whichever of FIVEDIVE_CHANNEL_PLUGINS_JSON is
      # absent, derived — the old version asked about dashboard and telegram by
      # hand and could not see a missing buzz at all, which is what let this
      # check pass [ok] on boxes where the buzz channel was installed and deaf.
      missing=$(managed_settings_channels_missing "$ms") || missing=""
      if [[ -z "$gap" && -n "$missing" ]]; then
        gap="doesn't list $missing — inbound pings on those channels are silently dropped"
      fi
      if [[ -z "$gap" ]]; then
        gap="allowlist could not be read as expected — rerun install.sh"
      fi
      if (( DOCTOR_REPAIR )); then
        reconcile_managed_settings "$ms"
        case $? in
          0) doctor_add channels managed-settings warn \
               "$ms was stale ($gap) — reconciled in place (+channelsEnabled / +5dive fork channels)" true true ;;
          3) doctor_add channels managed-settings ok \
               "$ms already current after reconcile" ;;
          *) doctor_add channels managed-settings error \
               "$ms $gap; auto-reconcile failed (jq unavailable or invalid JSON) — rerun install.sh" true false ;;
        esac
      else
        doctor_add channels managed-settings warn \
          "$ms $gap; self-heal: 5dive doctor --fix (or rerun install.sh)" true false
      fi
    fi

    # Per-agent: read the MOST RECENT MCP log for the telegram plugin and
    # check whether the last channel-registration event was "registered" or
    # "skipped". The log path is per-user, per-cwd (slashes → dashes):
    #   ~/.cache/claude-cli-nodejs/<cwd-dashed>/mcp-logs-plugin-telegram-*/*.jsonl
    # We glob the plugin dir to stay tolerant of marketplace name changes.
    # "Skipped" almost always means a Teams-org remote managed-settings is
    # overriding the local allowlist — admin action required; we link docs.
    if [[ -f "$REGISTRY" ]]; then
      local reg name channels
      reg=$(registry_read 2>/dev/null || echo '{"agents":{}}')
      for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
        channels=$(jq -r --arg n "$name" '.agents[$n].channels // ""' <<<"$reg")
        [[ "$channels" == *telegram* ]] || continue
        local user="agent-${name}"
        id -u "$user" &>/dev/null || continue
        # Latest jsonl across any telegram-plugin mcp-logs dir for this user.
        local latest
        latest=$(sudo -u "$user" bash -lc \
          'ls -1t "$HOME"/.cache/claude-cli-nodejs/*/mcp-logs-plugin-telegram-*/*.jsonl 2>/dev/null | head -1' \
          2>/dev/null)
        if [[ -z "$latest" ]]; then
          doctor_add channels "agent:$name" warn \
            "no telegram MCP logs found for $user (agent never started? channel not actually attached?)" false false
          continue
        fi
        # Look at the LAST occurrence of either event — agents may have
        # registered earlier then been told to skip, or vice versa.
        local last_event
        last_event=$(sudo -u "$user" grep -E 'Channel notifications (registered|skipped|.*not on the approved channels allowlist)' "$latest" 2>/dev/null | tail -1) || last_event=""
        if [[ "$last_event" == *"not on the approved channels allowlist"* ]]; then
          doctor_add channels "agent:$name" error \
            "claude logged 'Channel notifications skipped' — likely on an Anthropic Teams org. Org admin must allowlist telegram@5dive-plugins via console. See: https://github.com/$(gh_org)/5dive-plugins#anthropic-teams-accounts" \
            false false
        elif [[ "$last_event" == *"registered"* ]]; then
          doctor_add channels "agent:$name" ok "channel registered (latest MCP log: $(basename "$latest"))"
        else
          doctor_add channels "agent:$name" warn \
            "no channel-registration event found in latest MCP log $(basename "$latest") — restart the agent to refresh" false false
        fi

        # Dead inbound poller (reference_telegram_plugin_poller_dead_after_restart):
        # the plugin's `bun ... start` child is BOTH the getUpdates poller AND the
        # MCP send/edit host. A service restart can leave it un-respawned — outbound
        # replies (direct curl) still work, so inbound breaks SILENTLY (the user's
        # DMs queue at Telegram). Only meaningful when the service is active and the
        # session has been up long enough to have spawned it (don't flag an agent
        # mid-restart). If the poller process is gone we confirm with a getWebhookInfo
        # probe before any disruptive restart: queued updates => auto-heal; none =>
        # warn only (could just be idle), never a false-positive bounce.
        local svc="5dive-agent@${name}.service"
        if [[ "$(systemctl is-active "$svc" 2>/dev/null)" == "active" ]]; then
          local cpid2 etimes2
          # DIVE-3958: unit-scoped, executable-matched pick of the seat's claude
          # session (see doctor_seat_claude_pid). Previously a per-UID `pgrep -f
          # claude`, which selected any /home/claude/-path process the seat owned.
          cpid2=$(doctor_seat_claude_pid "$name" "$user")
          etimes2=$(ps -o etimes= -p "${cpid2:-0}" 2>/dev/null | tr -d ' ' || true)
          if [[ "$etimes2" =~ ^[0-9]+$ ]] && (( etimes2 > 90 )); then
            # The poller is `bun run --cwd .../plugins/cache/5dive-plugins/telegram/<ver>
            # --shell=bun --silent start` — other args sit between the version and
            # `start`, so match on the cache path + start with `.*` (spans spaces).
            # The claude parent carries `telegram@5dive-plugins` (reversed), never
            # `5dive-plugins/telegram/`, so this can't false-match it.
            if pgrep -u "$user" -f 'plugins/cache/5dive-plugins/telegram/.*start' >/dev/null 2>&1; then
              doctor_add channels "agent:$name poller" ok "telegram inbound poller alive"
            else
              local tok="" pend=0 wh=""
              tok=$(grep -oE '^TELEGRAM_BOT_TOKEN=.*' "${ENV_DIR}/${name}.env" 2>/dev/null \
                    | head -1 | cut -d= -f2- | tr -d '"'"'"'"' | tr -d ' ' || true)
              if [[ -n "$tok" ]]; then
                wh=$(curl -fsS --max-time 4 "https://api.telegram.org/bot${tok}/getWebhookInfo" 2>/dev/null || echo '')
                pend=$(jq -r '.result.pending_update_count // 0' <<<"$wh" 2>/dev/null || echo 0)
                [[ "$pend" =~ ^[0-9]+$ ]] || pend=0
              fi
              if (( pend > 0 )) && (( DOCTOR_REPAIR )); then
                if systemd-run --on-active=1 --collect /bin/systemctl restart "$svc" >/dev/null 2>&1; then
                  doctor_add channels "agent:$name poller" warn \
                    "inbound telegram poller was dead ($pend update(s) queued, nobody polling) — restart scheduled to respawn the plugin server + drain the backlog" true true
                else
                  doctor_add channels "agent:$name poller" error \
                    "inbound telegram poller dead ($pend queued); auto-restart failed — run: systemctl restart $svc" true false
                fi
              elif (( pend > 0 )); then
                doctor_add channels "agent:$name poller" error \
                  "inbound telegram poller dead — $pend update(s) queued at Telegram, nobody polling; DMs silently lost. Fix: 5dive doctor --fix (or systemctl restart $svc)" true false
              else
                doctor_add channels "agent:$name poller" warn \
                  "telegram plugin poller process not found (no queued updates — may be idle); if inbound is dead, restart to respawn it: systemctl restart $svc" true false
              fi
            fi
          fi
        fi

        # Plugin-version drift: Claude loads plugins once at launch, so an
        # agent that's been running since before the last `plugin update` is
        # still executing the OLD telegram plugin in memory (and its old hooks)
        # even though the on-disk cache is newer. This is the recurring
        # "/account mis-gated, /status missing the 5dive line, stale stop-hook"
        # class of bug. We detect it WITHOUT introspecting process memory: if
        # installed_plugins.json was modified AFTER the agent's claude process
        # started, the running code predates the update. --repair restarts the
        # agent (deferred) to load the fresh version.
        local manifest_f="/home/${user}/.claude/plugins/installed_plugins.json"
        if [[ -f "$manifest_f" ]]; then
          local ondisk_ver plug_mtime cpid
          ondisk_ver=$(jq -r '.plugins["telegram@5dive-plugins"][0].version // empty' "$manifest_f" 2>/dev/null)
          plug_mtime=$(stat -c %Y "$manifest_f" 2>/dev/null || echo 0)
          # DIVE-3958: the persistent claude session, scoped to the seat's unit
          # and matched by executable (see doctor_seat_claude_pid). The prior
          # per-UID `pgrep -f claude` picked any /home/claude/-path process the
          # seat owned; on agent-marketing that was a 46-day-old discord bot, so
          # this check warned "stale plugin" on a healthy seat and --repair
          # restarted it forever (the decoy lived in a different unit the restart
          # could not touch). Empty when the session can't be located -> the
          # guard below skips the check rather than false-warning.
          cpid=$(doctor_seat_claude_pid "$name" "$user")
          if [[ -n "$cpid" && -n "$ondisk_ver" ]]; then
            local etimes start_epoch now_epoch
            etimes=$(ps -o etimes= -p "$cpid" 2>/dev/null | tr -d ' ')
            now_epoch=$(date +%s)
            if [[ "$etimes" =~ ^[0-9]+$ ]]; then
              start_epoch=$((now_epoch - etimes))
              if [[ "$plug_mtime" -gt "$start_epoch" ]]; then
                if (( DOCTOR_REPAIR )); then
                  if systemd-run --on-active=1 --collect \
                       /bin/systemctl restart "5dive-agent@${name}.service" >/dev/null 2>&1; then
                    doctor_add channels "agent:$name plugin-version" warn \
                      "was running a stale telegram plugin (on-disk $ondisk_ver, loaded before last update) — restart scheduled to load it" true true
                  else
                    doctor_add channels "agent:$name plugin-version" warn \
                      "running a stale telegram plugin (on-disk $ondisk_ver) — auto-restart failed; run: systemctl restart 5dive-agent@${name}.service" true false
                  fi
                else
                  doctor_add channels "agent:$name plugin-version" warn \
                    "running a stale telegram plugin — on-disk is $ondisk_ver but the agent loaded an older build at launch. Restart to apply: systemctl restart 5dive-agent@${name}.service (or 5dive doctor --repair)" true false
                fi
              else
                doctor_add channels "agent:$name plugin-version" ok "telegram plugin $ondisk_ver loaded (running matches on-disk)"
              fi
            fi
          fi
        fi
      done
    fi
  fi

  # --- host: needrestart auto-restart cascade (reference_needrestart_autorestart_cascade) ---
  #
  # unattended-upgrades patching a shared lib triggers needrestart, which under
  # no-tty falls back to auto mode 'a' and bounces EVERY service linking the lib
  # in one cascade — once SIGTERM'd every agent mid-turn plus a ~3s postgres
  # outage. Fix: force list-only ($nrconf{restart}='l') so security patches still
  # apply but services are only LISTED; controlled restarts run on the host/nightly
  # cron. Idempotent conf.d drop-in, same shape harden.sh ships to customer VMs.
  if (( run_host )); then
    # DIVE-2009: `_audit_note_drop` deliberately never fails its caller, so its
    # parent directory is the only observable precondition preventing an audit
    # append failure from becoming a second silent loss. Assert the directory
    # shape itself; testing a marker path for writability cannot distinguish a
    # missing parent (partial/hand-built provision) from an actual disk fault.
    doctor_check_audit_drop_dir

    # DIVE-2640: is what is RUNNING on this host what we merged? Nothing else on
    # the board distinguishes merged from installed, and a category that is
    # dispatched nowhere is a check that never runs.
    doctor_check_cli_freshness

    # --- disk headroom (DIVE-1966/1967) ---
    #
    # A full disk never announces itself: it surfaces as a failure in whatever
    # touched it NEXT — an agent's memory write dying with ENOSPC mid-edit, a
    # shell losing stdout because the harness could not write its temp dir. Both
    # read as "that tool is broken", so the wrong thing gets debugged for an
    # hour. This check is how the host reports exhaustion AS ITSELF.
    local _seen=" " _p _mnt _free _pct _gb
    for _p in / "$DEFAULT_WORKDIR" "$STATE_DIR" /var; do
      [[ -d "$_p" ]] || continue
      _mnt=$(disk_mount "$_p"); [[ -n "$_mnt" ]] || continue
      [[ "$_seen" == *" ${_mnt} "* ]] && continue
      _seen+="${_mnt} "
      _free=$(disk_free_kb "$_p"); _pct=$(disk_used_pct "$_p")
      _gb=$(disk_gb "${_free:-0}")
      if [[ -z "$_free" ]]; then
        doctor_add host "disk ${_mnt}" warn "could not read free space for ${_mnt} (df failed) — UNKNOWN, not fine"
      elif (( _free < DISK_ERROR_KB )); then
        doctor_add host "disk ${_mnt}" error "only ${_gb}G free on ${_mnt} (${_pct}% used) — reclaim: 5dive task reclaim --all --dry-run"
      elif (( _free < DISK_WARN_KB )); then
        doctor_add host "disk ${_mnt}" warn "${_gb}G free on ${_mnt} (${_pct}% used) — one npm install is ~1G; reclaim: 5dive task reclaim --all --dry-run"
      else
        doctor_add host "disk ${_mnt}" ok "${_gb}G free on ${_mnt} (${_pct}% used)"
      fi
    done

    # --- worktree residue (report only, DIVE-1967) ---
    #
    # Counts, never sizes: `du` across a few hundred worktrees would make the
    # dashboard's periodic `doctor --json` take minutes. Sizes come from
    # `5dive task reclaim --all --dry-run`, which is a deliberate ask.
    local _wt _nm _wtn=0 _nmn=0
    while IFS= read -r _wt; do
      [[ -n "$_wt" ]] || continue
      _wtn=$((_wtn + 1))
      while IFS= read -r _nm; do [[ -n "$_nm" ]] && _nmn=$((_nmn + 1)); done < <(wt_node_modules "$_wt")
    done < <(wt_all)
    if (( _nmn > 20 )); then
      doctor_add host worktrees warn "${_wtn} worktrees under $WORKTREE_ROOT carry ${_nmn} node_modules trees (~1G each) — the DIVE-1966 shape; size them with: 5dive task reclaim --all --dry-run"
    else
      doctor_add host worktrees ok "${_wtn} worktrees under $WORKTREE_ROOT, ${_nmn} node_modules trees"
    fi

    # --- quarantined agent homes (report only, DIVE-2165) ---
    doctor_check_reaped_homes

    if ! command -v needrestart >/dev/null 2>&1 && [[ ! -d /etc/needrestart ]]; then
      doctor_add host needrestart ok "needrestart not installed — no auto-restart cascade risk"
    else
      local nr_listonly=0 nrf
      for nrf in /etc/needrestart/needrestart.conf /etc/needrestart/conf.d/*.conf; do
        [[ -f "$nrf" ]] || continue
        if grep -qE "^[[:space:]]*\\\$nrconf\{restart\}[[:space:]]*=[[:space:]]*'l'" "$nrf" 2>/dev/null; then
          nr_listonly=1; break
        fi
      done
      if (( nr_listonly )); then
        doctor_add host needrestart ok "needrestart is list-only (\$nrconf{restart}='l') — no auto-bounce cascade"
      elif (( DOCTOR_REPAIR )); then
        local nrdrop=/etc/needrestart/conf.d/99-5dive-overrides.conf
        if mkdir -p /etc/needrestart/conf.d 2>/dev/null && printf '%s\n' \
             "# 5dive: LIST services needing restart, never auto-bounce them on a" \
             "# library upgrade. An unattended-upgrades + needrestart cascade once" \
             "# SIGTERM'd every agent mid-turn (ref: needrestart-autorestart-cascade)." \
             "# Controlled restarts run on the host/nightly cron instead." \
             "\$nrconf{restart} = 'l';" > "$nrdrop" 2>/dev/null; then
          doctor_add host needrestart ok "wrote $nrdrop (list-only) — auto-restart cascade neutralized" true true
        else
          doctor_add host needrestart error "failed to write needrestart list-only drop-in (check perms on /etc/needrestart)" true false
        fi
      else
        doctor_add host needrestart warn "needrestart may auto-restart services on library upgrades — a mass agent-bounce cascade risk; fix: 5dive doctor --fix" true false
      fi
    fi
  fi

  # --- shelld reachability (managed platform only) ---
  if (( run_shelld )); then
    if [[ ! -f /etc/5dive/provisioning.env ]]; then
      doctor_add shelld service ok "self-hosted install — shelld only runs on the managed platform"
    else
      local shelld_active
      shelld_active=$(systemctl is-active shelld 2>/dev/null || true)
      if [[ "$shelld_active" == "active" ]]; then
        doctor_add shelld service ok "shelld.service active"
      elif (( DOCTOR_REPAIR )); then
        step "Restarting shelld"
        if systemctl restart shelld >&2 \
           && [[ "$(systemctl is-active shelld 2>/dev/null)" == "active" ]]; then
          doctor_add shelld service ok "shelld restarted" true true
        else
          doctor_add shelld service error "shelld restart failed (check: journalctl -u shelld)" true false
        fi
      else
        doctor_add shelld service error "shelld.service not active (state=$shelld_active)" true false
      fi

      local health_code
      health_code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
        http://127.0.0.1:3101/shell/health 2>/dev/null || echo "000")
      if [[ "$health_code" == "200" ]]; then
        doctor_add shelld health ok "http://127.0.0.1:3101/shell/health -> 200"
      else
        doctor_add shelld health error "shelld health endpoint returned $health_code (expected 200)" false false
      fi
    fi
  fi

  # --- memory hygiene (DIVE-991) ---
  # Scans every agent's per-user memory store (0600, readable here since doctor
  # is root) plus the shared wiki for index drift, dangling [[links]], stale
  # source refs, and near-duplicates. Findings roll up as one doctor check per
  # store (kept coarse so a rotting store doesn't flood the dashboard with rows);
  # `5dive memory doctor --json` gives the itemized list. Non-fatal: a scan
  # failure (e.g. no python) degrades to a single warn, never aborts doctor.
  # --- plugins (marketplace clone freshness, DIVE-2642) ---
  #
  # Per AGENT, never per host: the clone lives under each agent's own $HOME, so a
  # single verdict for "this box" cannot exist. The reference is read from the
  # REMOTE; if that fails the whole check reads UNKNOWN rather than green.
  if (( run_plugins )); then
    local _mp_ref=""
    _mp_ref=$(doctor_marketplace_reference_sha) || _mp_ref=""
    doctor_check_marketplace_clones /home "$_mp_ref"
  fi

  if (( run_memory )); then
    local mem_roots=() code_root=""
    for d in /home/claude/projects/5dive /home/claude/projects; do
      [[ -d "$d" ]] && { code_root="$d"; break; }
    done
    # Wiki (shared) + every agent home's memory stores.
    local wd
    for wd in /home/claude/projects/5dive/community/wiki; do
      [[ -d "$wd" ]] && mem_roots+=("$wd")
    done
    local home
    for home in /home/claude /home/agent-*; do
      [[ -d "$home/.claude/projects" ]] || continue
      local md
      for md in "$home"/.claude/projects/*/memory; do
        [[ -d "$md" ]] && mem_roots+=("$md")
      done
    done
    if (( ${#mem_roots[@]} == 0 )); then
      doctor_add memory stores warn "no memory stores found under /home/*/.claude/projects/*/memory"
    elif ! command -v python3 >/dev/null 2>&1; then
      doctor_add memory scan warn "python3 unavailable — memory hygiene scan skipped"
    else
      local mem_json=""
      mem_json=$(_memory_scan_json "$code_root" "${mem_roots[@]}" 2>/dev/null) || mem_json=""
      if [[ -z "$mem_json" ]] || ! jq -e '.stores' >/dev/null 2>&1 <<<"$mem_json"; then
        doctor_add memory scan warn "hygiene scan produced no parseable output"
      else
        # One row per store: ok when clean, else severity = worst finding with a
        # by-kind tally. The scanner's own roster is authoritative for store
        # names (single-sourced with the finding labels), so stores with zero
        # findings still report ok and the dashboard shows full coverage.
        local store_lines
        store_lines=$(jq -r '
          (.stores | unique) as $all |
          (.findings | group_by(.store) | map({key:.[0].store, value:.}) | from_entries) as $bys |
          $all[] |
          . as $s | ($bys[$s] // []) as $fs |
          {
            store: $s,
            errors: ([$fs[]|select(.severity=="error")]|length),
            warns:  ([$fs[]|select(.severity=="warn")]|length),
            tally:  ($fs | group_by(.kind) | map("\(length) \(.[0].kind)") | join(", "))
          } | @base64
        ' <<<"$mem_json")
        local line
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          local rec store errors warns tally sev msg
          rec=$(base64 -d <<<"$line")
          store=$(jq -r '.store' <<<"$rec")
          errors=$(jq -r '.errors' <<<"$rec")
          warns=$(jq -r '.warns' <<<"$rec")
          tally=$(jq -r '.tally' <<<"$rec")
          if (( errors > 0 )); then sev=error
          elif (( warns > 0 )); then sev=warn
          else sev=ok; fi
          if [[ "$sev" == ok ]]; then
            msg="clean"
          else
            msg="$tally (see: 5dive memory doctor --json)"
          fi
          doctor_add memory "$store" "$sev" "$msg"
        done <<<"$store_lines"
      fi
    fi
  fi

  # --- policy: gate auto-clear switches (OSS-21) ---
  # Surface the fleet-wide precedent_autoclear pref so an operator can see, from
  # the one health command, whether tier-1 gates are silently clearing themselves
  # from human precedent. Reads the tasks store directly; a missing store just
  # degrades to a warn (never aborts doctor). ON is reported as a warn severity so
  # it stands out in the summary — it's a deliberately-flipped policy, not a fault.
  if (( run_policy )); then
    if [[ -z "${TASKS_DB:-}" || ! -f "${TASKS_DB:-}" ]]; then
      doctor_add policy precedent-autoclear ok "tasks store absent — precedent auto-clear defaults OFF"
    else
      local _pac
      _pac=$(_task_pref_get precedent_autoclear 2>/dev/null); _pac="${_pac:-off}"
      if [[ "$_pac" == "on" ]]; then
        doctor_add policy precedent-autoclear warn "precedent auto-clear is ON — resolved tier-1 gates with proven human precedent clear without a ping (5dive task precedent off to disable)"
      else
        doctor_add policy precedent-autoclear ok "precedent auto-clear is OFF — every tier-1 gate surfaces to a human"
      fi
    fi

    # DIVE-2328: the FIVE_* override report is assembled here but is NOT a check and
    # never enters DOCTOR_CHECKS. See below the summary for why that matters.
    # DIVE-2336: BOTH arms used to coerce to '{}', which reads as "no overrides set".
    # The empty-string arm is the one the real failure mode reaches (measured: every jq
    # failure position cascades to rc!=0 with EMPTY stdout), so fixing only the visible
    # `|| printf` would have left the live path untouched.
    DOCTOR_ENV_OVERRIDES=$(_env_overrides_json 2>/dev/null)
    # One condition covers BOTH old coercions: a non-zero exit and an empty result both
    # arrive here as empty. The fallback is a CONSTANT, never `_env_ov_unavailable` — that
    # function ships in the same file as the reporter, so it is missing in exactly the
    # cases the fallback exists for.
    [[ -n "$DOCTOR_ENV_OVERRIDES" ]] || DOCTOR_ENV_OVERRIDES="$_5D_ENV_OV_UNAVAILABLE"
  fi

  # --- caps (report; see doctor_build_caps) ---
  # Constant fallback, never a function call: doctor_build_caps ships in this
  # same file, so it is missing in exactly the cases a fallback exists for.
  if (( run_caps )); then
    doctor_build_caps
    [[ -n "$DOCTOR_CAPS" ]] || DOCTOR_CAPS='{"seat":"unknown","sudoGrant":"unknown","runas":"unknown","github:read":{"state":"UNKNOWN","detail":"the capability probe itself failed to run — this is NOT a NO; nothing was measured"},"github:write":{"state":"NO","detail":"push identity is per-seat; the claude-uid borrow is RETIRED for the push class (DIVE-3017)."}}'
  fi

  if (( run_models )); then
    doctor_check_openclaw_model_pins
  fi

  # --- summary + output ---
  local summary
  summary=$(jq -c '{
    total:    length,
    passed:   [.[] | select(.severity == "ok")]    | length,
    warnings: [.[] | select(.severity == "warn")]  | length,
    errors:   [.[] | select(.severity == "error")] | length,
    repaired: [.[] | select(.repaired == true)]    | length
  }' <<<"$DOCTOR_CHECKS")

  # DIVE-2328: env_overrides is a REPORT and rides ALONGSIDE the checks, never inside
  # them. The first cut used doctor_add with severity=ok, reasoning that `ok` is the
  # schema's neutral member because it feeds no warning/error count. True of the PAYLOAD
  # and false at the READER, which is where it matters: the dashboard computes
  # `passing = checks.filter(c => c.severity === "ok").length` and renders that in green,
  # so sixteen configured-knob lines became sixteen PASSED CHECKS — an assertion of health
  # nobody made. Worse, its default view is `checks.filter(c => c.severity !== "ok")`, so
  # the surface built to make an unintended knob FINDABLE was hidden unless you clicked
  # "show all". A neutral value in the payload is not neutral once a consumer sums it.
  # selfcheck already had this right (env_overrides is a sibling of probes/summary and
  # touches no count); this makes doctor agree with it.
  local payload
  payload=$(jq -cn --argjson checks "$DOCTOR_CHECKS" --argjson summary "$summary" \
    --argjson eov "${DOCTOR_ENV_OVERRIDES:-{\}}" \
    --argjson caps "${DOCTOR_CAPS:-null}" \
    '{summary: $summary, checks: $checks, env_overrides: $eov, capabilities: $caps}')

  if (( JSON_MODE )); then
    jq -c '{ok:true, data: .}' <<<"$payload"
  else
    jq -r '
      .checks | group_by(.category) | .[] as $g |
      "── \($g[0].category) ──",
      ($g[] | "  [\(.severity)] \(.name): \(.message)\(if .repaired then " (repaired)" else "" end)"),
      ""
    ' <<<"$payload"
    jq -r '.summary |
      "summary: \(.total) checks, \(.passed) ok, \(.warnings) warn, \(.errors) error" +
      (if .repaired > 0 then ", \(.repaired) repaired" else "" end)
    ' <<<"$payload"
    # Capabilities, above env overrides and below the summary, and likewise a
    # REPORT not results. Two lines, both derived per-seat at run time. The
    # detail is printed in full rather than truncated: on the NO arm the reason
    # IS the payload — a bare NO sends the reader hunting for a password that
    # does not exist.
    jq -r '
      .capabilities // empty |
      "", "── capabilities (per-seat report, not checks) ──",
      "  seat          \(.seat)",
      "  github:read   \(.["github:read"].state)  \(.["github:read"].detail)",
      "  github:write  \(.["github:write"].state)  \(.["github:write"].detail)"
    ' <<<"$payload"
    # Its own section, below the summary, so it reads as a report rather than as results.
    # Prints NOTHING when there is nothing to say — which is why the negative is graded by
    # mutation and not by looking at empty output.
    jq -r '
      .env_overrides // {} |
      ( (.process // [])    | map("  in effect (process env): \(.name)=\(.value)") ) +
      ( (.configured // []) | map("  configured (\(.file)): \(.name)=\(.value)") ) +
      ( (.configured_unreadable // []) | map("  could not read \(.) — configured overrides NOT determined there") )
      | if length > 0 then ["", "── env overrides (report, not checks) ──"] + . else [] end
      | .[]
    ' <<<"$payload"
  fi
  # Always exit 0 — the envelope carries the real state via summary.errors.
  # Matches `auth status` (also informational). CI branches on the payload.
  return 0
}
