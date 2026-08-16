# shellcheck shell=bash
# -------- 5dive host: hardened host-remediation verbs (DIVE-3221) --------
#
# WHY THIS FILE EXISTS, AND WHY IT IS NOT A NEW SUDOERS TIER.
#
# DIVE-3213 proposed a fourth isolation tier for a devops seat, scoped to
# `systemctl` + `daemon-reload` + writes under /etc/systemd/system + `crontab` +
# `journalctl`. Every one of those four is an independent one-line root escape,
# and THREE were already on write_admin_sudoers's deliberately-excluded list (the
# DIVE-1088/2079 comment block in cmd_agent_create.sh): journalctl and
# `systemctl status` page through less -> `!sh`; writing a unit + daemon-reload +
# start is `systemd-run` spelled slowly. So that tier would have read
# `host-admin` in `agent info` and MEANT `root-all`. lodar answered B on
# 2026-08-11: no tier — build the verbs.
#
# An `admin` agent already holds, measured:
#
#   agent-<name> ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
#
# The trailing `*` covers subcommands that do not exist yet, so these verbs ship
# remediation capability with NO sudoers change, no new tier, and nothing for the
# next `agent create` to silently revert — which was the whole objection to
# hand-editing a drop-in. `5dive agent _svc` is the precedent: DIVE-1088 dropped
# raw `systemctl` grants precisely because a scoped subcommand covered every case.
#
# THE LOAD-BEARING INVARIANT (write_admin_sudoers states it):
#   No 5dive subcommand may exec agent-controlled input as root.
# Granting the whole CLI as root is only a boundary because of it. The day one
# verb execs caller input as root, `cli-root` collapses to `root-all` for EVERY
# admin agent on the box at once, not just the devops seat.
#
# So, per verb, the finite set of things this file can exec as root:
#
#   host unit list      systemctl list-units --type=service --all [<validated-glob>]
#   host unit show      systemctl show <validated-unit> -p <FIXED property list>
#   host unit repoint   systemctl show ... ; systemctl daemon-reload ;
#                       systemctl restart <validated-unit>
#                       + writes ONE file of FIXED shape (see _host_render_workdir_dropin)
#   host unit revert    rm -f <that one fixed path> ; systemctl daemon-reload ;
#                       systemctl restart <validated-unit>
#   host journal        journalctl -u <validated-unit> -n <int> [--since "<int> <fixed word> ago"]
#   host cron show      crontab -l -u <validated-user>
#   host cron snapshot  crontab -l -u <validated-user>   (output stored under $STATE_DIR)
#   host cron diff      diff -u <two CLI-owned files>
#
# There is no eval, no `sh -c`, no editor, no caller-supplied file path, no
# caller-supplied unit-file content, and no pager anywhere in this file. Every
# external call goes through _host_systemctl / _host_journalctl, which pin
# SYSTEMD_PAGER=cat and pass --no-pager IN CODE rather than trusting the caller's
# environment (the body of DIVE-3221 asks for exactly this: the pager escapes
# above are excluded by CONVENTION today, and convention is not a control).
#
# WRITES ARE DELIBERATELY NARROWER THAN "WRITE /etc/systemd/system".
# `repoint` never authors a unit. It writes a drop-in whose ONLY variable part is
# a validated absolute path on one `WorkingDirectory=` line, at one fixed
# basename, under `<validated-unit>.d/`. `revert` removes exactly that basename
# and nothing else. A reviewer can hold the whole reachable output set in mind.
#
# WHAT `repoint` REFUSES, AND WHY IT IS NOT NEGOTIABLE.
# A unit's WorkingDirectory IS a code pointer whenever its ExecStart carries a
# relative argument. Measured on this host:
#     5dive-api.service  ExecStart={ path=/usr/bin/node ; argv[]=/usr/bin/node dist/index.js }
# `dist/index.js` resolves against WorkingDirectory. So repointing such a unit at
# a directory of the caller's choosing is exactly "exec agent-controlled input as
# root" with two extra steps — the invariant above, violated by the verb that was
# supposed to respect it.
#
# THE PREDICATE IS ROOT-EQUIVALENCE, NOT LITERAL ROOT. The first draft of this
# file refused only `User=` empty/"root"/"0", and carried this sentence:
#
#   "Every unit the devops charter named runs non-root (5dive-api and
#    5dive-frontend as `claude`, ...), so the refusal costs the driver case
#    nothing."
#
# That is the correct fact with the opposite conclusion drawn from it, and the
# code followed the comment faithfully. `claude` holds `ALL=(ALL) NOPASSWD: ALL`.
# Running as `claude` is not what made 5dive-api cheap to repoint, it is what
# made it the most dangerous unit on the box: the literal-root test returns
# false, repoint proceeds, and systemd execs the caller's file as an account that
# can sudo anything. Found by main reviewing this file; recorded here rather than
# quietly deleted, because the next person to "simplify" _host_account_class back
# into a `[[ $u == root ]]` one-liner needs to meet the reason it is not one.
#
# So repoint/revert refuse unless _host_account_class returns `restricted` — the
# only POSITIVELY established class. `root`, `root-equivalent` and `undetermined`
# all refuse; a cwd on any of them stays a human/root operation and is filed as a
# gate rather than unlocked by widening this verb.
#
# CRONTAB IS READ-ONLY, BY THE ROW'S OWN SCOPE. `crontab -e` for another user is
# an EDITOR=/bin/sh escape, and if the target is `claude` that seat is
# NOPASSWD: ALL. No verb here passes anything but `-l -u <user>`. A write path
# needs its own design pass and its own gate.
#
# Full write-up: community/wiki/a-devops-tier-scoped-to-systemctl-journalctl-and-
# crontab-is-root-in-a-costume.md

# The ONE basename this file ever writes or removes under /etc/systemd/system.
# Named, not composed, so `revert` cannot be steered at another file.
HOST_WORKDIR_DROPIN="50-5dive-workdir.conf"

# Unit suffixes the read verbs accept. `repoint`/`revert` narrow this to
# `.service` on their own (WorkingDirectory is a service property).
HOST_UNIT_SUFFIXES='service|timer|socket|target|path|mount|slice|scope'

# The FIXED property list `host unit show` reads. A caller-chosen property list
# would be harmless today, but it is also the seam through which "just let them
# pass -p" becomes "just let them pass any systemctl flag", so it is a literal.
HOST_SHOW_PROPS='Id,Description,LoadState,ActiveState,SubState,UnitFileState,User,Group,WorkingDirectory,ExecStart,ExecMainStatus,ExecMainPID,Result,FragmentPath,DropInPaths,Restart,NRestarts'

# --- pager-pinned wrappers ---------------------------------------------------
# journalctl and `systemctl status` page through less BY DEFAULT, and less's `!sh`
# is a root shell (GTFOBins). DIVE-1088 excluded raw grants on both for that
# reason. Under this file the escape is closed in code, not in the caller's env:
# --no-pager is passed on every call AND SYSTEMD_PAGER/PAGER are pinned to `cat`,
# so an inherited SYSTEMD_PAGER=less (or a LESSSECURE-unset box, which is what
# poke-two measured as) cannot reintroduce it. LESSOPEN is dropped too: it is an
# input preprocessor, i.e. a second exec that reads the caller's environment.
_host_systemctl() {
  env -u LESS -u LESSOPEN -u LESSCLOSE \
      SYSTEMD_PAGER=cat SYSTEMD_LESS='' PAGER=cat \
      systemctl --no-pager "$@"
}

_host_journalctl() {
  env -u LESS -u LESSOPEN -u LESSCLOSE \
      SYSTEMD_PAGER=cat SYSTEMD_LESS='' PAGER=cat \
      journalctl --no-pager "$@"
}

# _host_unit_property <unit> <property> — read ONE systemd property.
# Single reader, so the tests can drive every downstream decision (root-user
# refusal, LoadState refusal, before/after reporting) without a live systemd.
_host_unit_property() {
  _host_systemctl show "$1" -p "$2" --value 2>/dev/null || true
}

# --- validation --------------------------------------------------------------

# _host_validate_unit <unit> [service|any]
# The unit name becomes a DIRECTORY NAME under /etc/systemd/system on the repoint
# path, so traversal and separators are rejected before anything else; a leading
# '-' is rejected because systemctl would read it as an option rather than a unit
# (the same class as _svc's guard). An explicit type suffix is REQUIRED: without
# one, systemd's "assume .service" convenience means the string we validate and
# the unit systemd resolves are two different names.
_host_validate_unit() {
  local unit="${1:-}" kind="${2:-any}"
  [[ -n "$unit" ]] || fail "$E_USAGE" "--unit is required"
  if [[ "$unit" == -* ]]; then
    fail "$E_VALIDATION" "refusing unit '$unit': a leading '-' is read as an option, not a unit name"
  fi
  if [[ "$unit" == */* || "$unit" == *..* ]]; then
    fail "$E_VALIDATION" "refusing unit '$unit': path separators and '..' cannot appear in a unit name (it names a directory under /etc/systemd/system)"
  fi
  if [[ "$kind" == "service" ]]; then
    [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.service$ ]] \
      || fail "$E_VALIDATION" "refusing unit '$unit': repoint/revert take a .service unit (WorkingDirectory is a service property)"
  else
    [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.($HOST_UNIT_SUFFIXES)$ ]] \
      || fail "$E_VALIDATION" "refusing unit '$unit': expected <name>.<${HOST_UNIT_SUFFIXES//|/,}>"
  fi
  return 0
}

# _host_validate_workdir <path>
# The value lands on a `WorkingDirectory=` line in a systemd drop-in, so this is
# validated as UNIT-FILE INPUT, not just as a path:
#   - '%' is a systemd specifier introducer (%h, %i, %t ...). A '%' in the value
#     is not inert text, it is expansion, so it is refused outright rather than
#     escaped.
#   - the charset allowlist rejects newlines by construction, which is what stops
#     a path from appending a SECOND directive to the [Service] section.
#   - '..' is refused even though the path is resolved afterwards, so the string
#     written to disk is the string that was validated.
_host_validate_workdir() {
  local p="${1:-}"
  [[ -n "$p" ]] || fail "$E_USAGE" "--workdir is required"
  [[ "$p" == /* ]] || fail "$E_VALIDATION" "refusing --workdir '$p': must be an absolute path"
  if [[ "$p" == *..* ]]; then
    fail "$E_VALIDATION" "refusing --workdir '$p': '..' components are not accepted"
  fi
  if [[ "$p" == *%* ]]; then
    fail "$E_VALIDATION" "refusing --workdir '$p': '%' introduces a systemd specifier in a unit file, so it is not inert text"
  fi
  [[ "$p" =~ ^/[A-Za-z0-9._/@+-]*$ ]] \
    || fail "$E_VALIDATION" "refusing --workdir '$p': allowed characters are A-Za-z0-9 and . _ / @ + -"
  [[ "$p" != "/" ]] || fail "$E_VALIDATION" "refusing --workdir '/'"
  [[ -d "$p" ]] || fail "$E_VALIDATION" "refusing --workdir '$p': not an existing directory"
  return 0
}

# _host_validate_user <user> — read-only crontab target.
# Charset first (so nothing option-shaped or metacharacter-bearing reaches
# `crontab -u`), then existence: a typo must say "no such user", not hand back an
# empty crontab that reads as "this user has no cron jobs".
_host_validate_user() {
  local u="${1:-}"
  [[ -n "$u" ]] || fail "$E_USAGE" "--user is required"
  if [[ "$u" == -* ]]; then
    fail "$E_VALIDATION" "refusing user '$u': a leading '-' is read as an option"
  fi
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || fail "$E_VALIDATION" "refusing user '$u': expected a POSIX login name"
  id -u -- "$u" >/dev/null 2>&1 || fail "$E_VALIDATION" "no such user '$u'"
  return 0
}

# _host_validate_lines <n> — journalctl -n takes an integer, and only an integer.
_host_validate_lines() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]{1,5}$ ]] \
    || fail "$E_VALIDATION" "refusing --lines '$n': expected an integer"
  (( n >= 1 && n <= 20000 )) \
    || fail "$E_VALIDATION" "refusing --lines '$n': expected 1..20000"
  return 0
}

# _host_since_phrase <N>m|<N>h|<N>d — print the ONE literal phrase journalctl gets.
#
# journalctl's own --since accepts a rich time grammar ("@<epoch>", "yesterday",
# free-form phrases). That is caller text reaching a root process's argv, so it is
# never forwarded: the flag is a structured <int><unit> pair and the phrase handed
# to journalctl is assembled here from a fixed vocabulary of three words.
_host_since_phrase() {
  local s="${1:-}"
  [[ "$s" =~ ^([0-9]{1,4})([mhd])$ ]] \
    || fail "$E_VALIDATION" "refusing --since '$s': expected <N>m, <N>h or <N>d (free-form journalctl time strings are not accepted)"
  local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
  case "$u" in
    m) printf '%s minutes ago' "$n" ;;
    h) printf '%s hours ago' "$n" ;;
    d) printf '%s days ago' "$n" ;;
  esac
}

# _host_sudo_list <user> — enumerate a user's sudo privileges, or fail.
#
# Asks SUDO what the account can do rather than parsing /etc/sudoers.d ourselves.
# The drop-in is text; this is the enforced answer, and the gap between them is
# where the wrong answer lives (DIVE-2079: `isolation` is a stored label with
# nothing keeping it honest, and on this host it disagrees with the grant on more
# than one seat). Group membership, /etc/sudoers proper and every drop-in are all
# folded in for free. Separate function so the harness can drive it.
_host_sudo_list() {
  sudo -n -l -U "$1" 2>/dev/null
}

# _host_account_uid <user> — resolve a login name to a uid, or fail if unknown.
# Separate function for the same reason _host_sudo_list is: it is the second
# host-dependent lookup in the classifier, and a harness that cannot drive it
# ends up asserting a property of the RUNNER (does an account named `claude`
# exist here?) instead of a property of the code. That is not hypothetical — it
# is exactly how this file's first harness passed locally and red-ed CI.
_host_account_uid() {
  id -u -- "$1" 2>/dev/null
}

# _host_account_class <user> — root | root-equivalent | restricted | undetermined
#
# THE PREDICATE THAT MATTERS IS ROOT-EQUIVALENCE, NOT LITERAL ROOT, and getting
# that wrong is a live escalation rather than a lint (found by main reviewing
# DIVE-3221's first draft, which tested `User=` against "root"/""/"0" only):
#
#   5dive-api.service   User=claude
#   /etc/sudoers.d/claude   claude ALL=(ALL) NOPASSWD:ALL
#
# `claude` is not root, so a literal-root test returns false and repoint
# proceeds — pointing a unit whose ExecStart is `node dist/index.js` at a
# directory the caller created, and systemd then execs the caller's file as an
# account that can `sudo` anything. Caller-chosen content, exec'd as root, from
# the verb whose own refusal message describes that hazard.
#
# So: classify the ACCOUNT (a property of the account, not of the filesystem — it
# does not fall into DIVE-3258's "do not relocate a filesystem fact into a CLI
# check" trap), and FAIL CLOSED. `undetermined` is a refusal, not a shrug: an
# unknown user, an unreadable sudo policy, or a sudo that will not answer all
# mean the same thing here — we cannot show the target is safe, and the cost of
# being wrong is every admin agent on the box at once.
#
# `restricted` is the ONLY class that proceeds, and it is the positively
# established one.
#
# TWO LIMITS ON WHAT `restricted` MEANS. Both are known and neither is measured
# away, so do not read the word as "safe":
#
# 1. IT TESTS FOR A BARE `ALL`, NOT FOR A GTFOBINS GRANT. `(ALL) NOPASSWD: ALL`
#    is caught. `(ALL) NOPASSWD: /bin/sh`, an editor, or any interpreter is NOT —
#    those are root escapes with an ENUMERATED command list, and they classify as
#    `restricted` here. That is knowingly out of scope for this pass, not an
#    oversight: this same file's header cites `less`->`!sh` and `crontab -e` as
#    the reason DIVE-3213's tier died, so the class is well known to us. Nothing
#    on this host is exposed by it today — every WorkingDirectory-bearing unit is
#    already refused on other grounds — which makes it latent, not live, and a
#    latent hole is a row rather than a blocker. Whoever widens this predicate
#    next: the shape to add is "does the enumerated command list contain anything
#    that execs its own argument".
#
# 2. THE cli-root GRANT IS `restricted` CONDITIONALLY, NOT AS A MEASUREMENT.
#    `(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *` classifies as
#    `restricted`, so a unit running AS an admin seat IS repointable. That is
#    sound exactly as long as no 5dive subcommand execs agent-controlled input as
#    root — the invariant this file exists to protect. It is a dependency, not an
#    independent fact: the day that invariant breaks, this classification is
#    wrong too, and it will not announce itself. If cli-root were treated as
#    root-equivalent instead, the design would refuse itself, which is why the
#    dependency is accepted and written down rather than engineered away.
_host_account_class() {
  local u="${1:-}"
  # systemd's default User= for a system unit is root, so ABSENT and "root" must
  # land on the same branch. Reading empty as "not root" disables the guard on
  # nearly every unit on the box.
  if [[ -z "$u" || "$u" == "root" || "$u" == "0" ]]; then
    printf 'root'; return 0
  fi
  # $u arrives from systemd's own `User=`, not from the caller — but it is about
  # to become an argv to a root `sudo`, so it is charset-checked anyway. A value
  # that is not a POSIX login name (a leading '-' would be read as an option) is
  # UNDETERMINED, i.e. refused, never passed through.
  if [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    printf 'undetermined'; return 0
  fi
  local uid
  uid=$(_host_account_uid "$u") || { printf 'undetermined'; return 0; }
  [[ "$uid" == "0" ]] && { printf 'root'; return 0; }   # a second name for uid 0

  local listing
  listing=$(_host_sudo_list "$u") || { printf 'undetermined'; return 0; }
  if [[ -z "$listing" ]]; then
    printf 'undetermined'; return 0
  fi
  # sudo says so itself. This is the positive establishment `restricted` needs.
  if grep -qiE 'is not allowed to run sudo' <<<"$listing"; then
    printf 'restricted'; return 0
  fi
  # An entry whose COMMAND LIST is exactly ALL is unrestricted, whatever the
  # runas spec: `(ALL : ALL) ALL` and `(ALL) NOPASSWD: ALL` are both root. Tags
  # (NOPASSWD:, SETENV:, ...) may appear in any combination before the command,
  # so they are skipped rather than matched one shape at a time.
  if grep -qE '^[[:space:]]*\([^)]*\)[[:space:]]*((NOPASSWD|PASSWD|SETENV|NOSETENV|NOEXEC|EXEC|LOG_INPUT|NOLOG_INPUT|LOG_OUTPUT|NOLOG_OUTPUT|FOLLOW|NOFOLLOW|MAIL|NOMAIL):[[:space:]]*)*ALL[[:space:]]*$' <<<"$listing"; then
    printf 'root-equivalent'; return 0
  fi
  # Enumerated, and nothing in it is unrestricted.
  if grep -qE '^[[:space:]]*\([^)]*\)' <<<"$listing"; then
    printf 'restricted'; return 0
  fi
  printf 'undetermined'
}

# _host_render_workdir_dropin <validated-path> — the ONLY unit-file content this
# file can produce. One section, one directive, one validated value. There is no
# code path that writes a caller-supplied line.
_host_render_workdir_dropin() {
  cat <<DROPIN
# Managed by 5dive (DIVE-3221) — written by \`5dive host unit repoint\`.
# Do not edit by hand. Remove with: 5dive host unit revert --unit=<unit>
[Service]
WorkingDirectory=$1
DROPIN
}

_host_dropin_dir() { printf '/etc/systemd/system/%s.d' "$1"; }
_host_dropin_path() { printf '%s/%s' "$(_host_dropin_dir "$1")" "$HOST_WORKDIR_DROPIN"; }

# _host_require_repointable <unit> — the two refusals repoint and revert share.
_host_require_repointable() {
  local unit="$1" load
  load=$(_host_unit_property "$unit" LoadState)
  [[ "$load" == "loaded" ]] \
    || fail "$E_VALIDATION" "unit '$unit' is not loaded (LoadState=${load:-unknown}); refusing to touch /etc/systemd/system for a unit systemd does not know"
  local runas class
  runas=$(_host_unit_property "$unit" User)
  class=$(_host_account_class "$runas")
  case "$class" in
    restricted) return 0 ;;
    root)
      fail "$E_VALIDATION" "refusing '$unit': it runs as root. WorkingDirectory is a code pointer whenever ExecStart carries a relative argument (5dive-api's is 'node dist/index.js'), so repointing its cwd would let this subcommand exec caller-chosen content as root — which collapses the cli-root grant to root-all for every admin agent on the box. A root unit's cwd is a human/root operation: file a gate." ;;
    root-equivalent)
      fail "$E_VALIDATION" "refusing '$unit': it runs as '${runas}', which holds an UNRESTRICTED sudo grant (sudo -l -U ${runas} lists a bare ALL), so it is root-equivalent even though it is not literally root. WorkingDirectory is a code pointer whenever ExecStart carries a relative argument (5dive-api's is 'node dist/index.js'), so repointing its cwd execs caller-chosen content as an account that can sudo anything. Same refusal as root, for the same reason: file a gate." ;;
    *)
      fail "$E_VALIDATION" "refusing '$unit': cannot establish whether its user ('${runas:-<unset>}') is root-equivalent — sudo would not enumerate it, or the account does not exist. This guard FAILS CLOSED: not being able to show the target is safe is not the same as it being safe, and the cost of guessing wrong is every admin agent on the box at once." ;;
  esac
}

# --- verbs -------------------------------------------------------------------

cmd_host_unit_list() {
  local pattern=""
  while (( $# )); do
    case "$1" in
      --pattern=*) pattern="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host unit list [--pattern=<unit-glob>]" ;;
    esac
    shift
  done
  local -a pat_args=()
  if [[ -n "$pattern" ]]; then
    if [[ "$pattern" == -* ]]; then
      fail "$E_VALIDATION" "refusing --pattern '$pattern': a leading '-' is read as an option"
    fi
    [[ "$pattern" =~ ^[A-Za-z0-9._@*?-]+$ ]] \
      || fail "$E_VALIDATION" "refusing --pattern '$pattern': allowed characters are A-Za-z0-9 and . _ @ * ? -"
    pat_args=("$pattern")
  fi
  local out
  out=$(_host_systemctl list-units --type=service --all --no-legend ${pat_args[@]+"${pat_args[@]}"} 2>&1) || true
  if (( JSON_MODE )); then
    ok "" '{pattern:$p, units:$o}' --arg p "$pattern" --arg o "$out"
  else
    printf '%s\n' "$out"
  fi
}

cmd_host_unit_show() {
  local unit=""
  while (( $# )); do
    case "$1" in
      --unit=*) unit="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host unit show --unit=<unit>" ;;
    esac
    shift
  done
  _host_validate_unit "$unit" any
  local out
  out=$(_host_systemctl show "$unit" -p "$HOST_SHOW_PROPS" 2>&1) || true
  if (( JSON_MODE )); then
    ok "" '{unit:$u, properties:$o}' --arg u "$unit" --arg o "$out"
  else
    printf '%s\n' "$out"
  fi
}

cmd_host_unit_repoint() {
  require_root "host unit repoint"
  local unit="" workdir="" do_restart=1
  while (( $# )); do
    case "$1" in
      --unit=*)    unit="${1#*=}" ;;
      --workdir=*) workdir="${1#*=}" ;;
      --no-restart) do_restart=0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host unit repoint --unit=<unit>.service --workdir=<abs-path> [--no-restart]" ;;
    esac
    shift
  done
  _host_validate_unit "$unit" service
  _host_validate_workdir "$workdir"
  _host_require_repointable "$unit"

  local before; before=$(_host_unit_property "$unit" WorkingDirectory)
  local dir path
  dir=$(_host_dropin_dir "$unit"); path=$(_host_dropin_path "$unit")
  mkdir -p "$dir"
  chown root:root "$dir" 2>/dev/null || true
  chmod 755 "$dir"
  _host_render_workdir_dropin "$workdir" > "$path"
  chown root:root "$path" 2>/dev/null || true
  chmod 644 "$path"

  _host_systemctl daemon-reload
  local restarted="false"
  if (( do_restart )); then
    _host_systemctl restart "$unit"
    restarted="true"
  fi
  local after; after=$(_host_unit_property "$unit" WorkingDirectory)

  ok "repointed '$unit' WorkingDirectory: ${before:-<unset>} -> ${after:-<unset>} (drop-in $path; restarted=$restarted)" \
     '{unit:$u, workdir:$w, before:$b, after:$a, dropin:$p, restarted:($r=="true")}' \
     --arg u "$unit" --arg w "$workdir" --arg b "$before" --arg a "$after" \
     --arg p "$path" --arg r "$restarted"
}

cmd_host_unit_revert() {
  require_root "host unit revert"
  local unit="" do_restart=1
  while (( $# )); do
    case "$1" in
      --unit=*) unit="${1#*=}" ;;
      --no-restart) do_restart=0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host unit revert --unit=<unit>.service [--no-restart]" ;;
    esac
    shift
  done
  _host_validate_unit "$unit" service
  _host_require_repointable "$unit"

  local dir path
  dir=$(_host_dropin_dir "$unit"); path=$(_host_dropin_path "$unit")
  local existed="false"
  [[ -f "$path" ]] && existed="true"
  # Removes the one basename this file writes. Never `rm -r` the .d directory:
  # other drop-ins there belong to someone else, and rmdir refuses a non-empty
  # dir, which is the behaviour we want as a guard rather than as a courtesy.
  rm -f "$path"
  rmdir "$dir" 2>/dev/null || true

  _host_systemctl daemon-reload
  local restarted="false"
  if (( do_restart )); then
    _host_systemctl restart "$unit"
    restarted="true"
  fi
  local after; after=$(_host_unit_property "$unit" WorkingDirectory)

  ok "reverted '$unit' (drop-in present before: $existed); WorkingDirectory is now ${after:-<unset>} (restarted=$restarted)" \
     '{unit:$u, dropin:$p, removed:($e=="true"), after:$a, restarted:($r=="true")}' \
     --arg u "$unit" --arg p "$path" --arg e "$existed" --arg a "$after" --arg r "$restarted"
}

cmd_host_journal() {
  require_root "host journal"
  local unit="" lines="200" since=""
  while (( $# )); do
    case "$1" in
      --unit=*)  unit="${1#*=}" ;;
      --lines=*) lines="${1#*=}" ;;
      --since=*) since="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host journal --unit=<unit> [--lines=N] [--since=<N>m|<N>h|<N>d]" ;;
    esac
    shift
  done
  _host_validate_unit "$unit" any
  _host_validate_lines "$lines"
  # NOTE the explicit `||`: _host_since_phrase's refusal is a `fail`, which exits
  # the COMMAND SUBSTITUTION's subshell, not this one. Relying on errexit to
  # notice would be relying on an assignment's exit-status subtlety to enforce a
  # security boundary; the refusal is re-raised here in the caller's own shell.
  local -a since_args=()
  if [[ -n "$since" ]]; then
    local phrase
    phrase=$(_host_since_phrase "$since") \
      || fail "$E_VALIDATION" "refusing --since '$since': expected <N>m, <N>h or <N>d (free-form journalctl time strings are not accepted)"
    since_args=(--since "$phrase")
  fi
  local out
  out=$(_host_journalctl -u "$unit" -n "$lines" ${since_args[@]+"${since_args[@]}"} 2>&1) || true
  if (( JSON_MODE )); then
    ok "" '{unit:$u, lines:($l|tonumber), since:$s, log:$o}' \
       --arg u "$unit" --arg l "$lines" --arg s "$since" --arg o "$out"
  else
    printf '%s\n' "$out"
  fi
}

# `crontab -l -u <user>` and nothing else. There is no verb in this file that can
# reach `crontab -e` (EDITOR=/bin/sh) or `crontab -r`, and no caller-supplied
# path is ever read: `diff` compares two files the CLI itself owns under
# $STATE_DIR, so "diff my crontab against this file" cannot become "read any file
# as root".
_host_cron_read() {
  local user="$1"
  crontab -l -u "$user" 2>/dev/null || true
}

_host_cron_snapshot_path() { printf '%s/host-cron/%s.cron' "$STATE_DIR" "$1"; }

cmd_host_cron() {
  require_root "host cron"
  local action="${1:-}"; shift || true
  case "$action" in
    show|snapshot|diff) ;;
    *) fail "$E_USAGE" "usage: 5dive host cron <show|snapshot|diff> --user=<user>" ;;
  esac
  local user=""
  while (( $# )); do
    case "$1" in
      --user=*) user="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive host cron $action --user=<user>" ;;
    esac
    shift
  done
  _host_validate_user "$user"

  local snap; snap=$(_host_cron_snapshot_path "$user")
  local live; live=$(_host_cron_read "$user")

  case "$action" in
    show)
      if (( JSON_MODE )); then
        ok "" '{user:$u, crontab:$c}' --arg u "$user" --arg c "$live"
      else
        printf '%s\n' "$live"
      fi
      ;;
    snapshot)
      mkdir -p "$(dirname "$snap")"
      chmod 700 "$(dirname "$snap")"
      printf '%s\n' "$live" > "$snap"
      chmod 600 "$snap"
      ok "snapshot of ${user}'s crontab written to $snap" \
         '{user:$u, path:$p, bytes:($b|tonumber)}' \
         --arg u "$user" --arg p "$snap" --arg b "${#live}"
      ;;
    diff)
      [[ -f "$snap" ]] \
        || fail "$E_VALIDATION" "no snapshot for '$user' yet — run: 5dive host cron snapshot --user=$user"
      local out rc=0
      out=$(printf '%s\n' "$live" | diff -u "$snap" - ) || rc=$?
      if (( JSON_MODE )); then
        ok "" '{user:$u, snapshot:$p, changed:($c=="1"), diff:$d}' \
           --arg u "$user" --arg p "$snap" --arg c "$([[ $rc -ne 0 ]] && echo 1 || echo 0)" --arg d "$out"
      elif (( rc == 0 )); then
        echo "OK — ${user}'s crontab matches the snapshot at $snap"
      else
        printf '%s\n' "$out"
      fi
      ;;
  esac
}

cmd_host_unit() {
  local action="${1:-}"; shift || true
  case "$action" in
    list)    cmd_host_unit_list "$@" ;;
    show)    cmd_host_unit_show "$@" ;;
    repoint) cmd_host_unit_repoint "$@" ;;
    revert)  cmd_host_unit_revert "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive host unit <list|show|repoint|revert> [flags]" ;;
  esac
}

cmd_host() {
  local action="${1:-}"; shift || true
  case "$action" in
    unit)    cmd_host_unit "$@" ;;
    journal) cmd_host_journal "$@" ;;
    cron)    cmd_host_cron "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive host <unit|journal|cron> ... (see: 5dive --help)" ;;
  esac
}
