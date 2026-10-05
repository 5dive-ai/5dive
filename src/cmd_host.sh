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
#   host timezone       timedatectl show -p Timezone --value
#   host timezone set   timedatectl list-timezones ; timedatectl set-timezone <validated zone> ;
#                       systemctl try-restart cron.service ;
#                       systemctl restart <each ACTIVE 5dive-agent@<name>.service, names read
#                       back from systemd and re-validated, never from the caller;
#                       a parked agent (registry desiredState=stopped) is skipped>
#   host companion      reads the files below; systemctl is-active <the FIXED proxy unit>
#   host companion set  writes FIXED-path files whose only variable parts are a validated IPv4,
#                       a validated host-key line and an OpenSSH private key read from stdin
#                       (armor + base64 checked); systemctl daemon-reload ;
#                       systemctl enable + restart <the FIXED proxy unit>, which runs
#                       `ssh -N -D 127.0.0.1:1080` as nobody:claude, never as root
#   host companion remove  systemctl disable --now <the FIXED proxy unit> ; rm -f <those files>
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

# --- host timezone (DIVE-5165) -----------------------------------------------
# The box's system zone. A partner client's assistant keeps their calendar
# (OINOA): on a UTC box, "remind me at 9" fires at 12:00 Moscow time and "today"
# rolls over at 03:00. 5dive-api calls `set` over /shell/exec with the zone the
# client's device reported; 5dive's own boxes are never sent it and stay UTC.
#
# The zone is the ONLY caller input, and it reaches timedatectl only after two
# checks: an IANA name shape (no dot, no leading slash, so no path), and exact
# membership in this box's own `timedatectl list-timezones`. The restart set is
# read back from systemd, not taken from the caller. A process caches its zone at
# start, so the running agents are restarted to pick it up (and cron, which reads
# /etc/localtime for its schedule) — only when the zone actually changed.
HOST_TZ_RE='^[A-Z][A-Za-z0-9_+-]*(/[A-Z][A-Za-z0-9_+-]*){0,2}$'
HOST_AGENT_UNIT_RE='^5dive-agent@[a-z][a-z0-9-]*\.service$'

# Single seam onto timedatectl, so the harness drives every decision without a
# live systemd (the _host_unit_property precedent).
_host_timedatectl() {
  timedatectl "$@"
}

_host_tz_current() {
  _host_timedatectl show -p Timezone --value 2>/dev/null || true
}

_host_validate_tz() {
  local tz="$1"
  [[ "$tz" =~ $HOST_TZ_RE ]] \
    || fail "$E_VALIDATION" "not an IANA time zone name: '${tz:0:64}' (e.g. Europe/Moscow)"
  _host_timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$tz" \
    || fail "$E_VALIDATION" "time zone '$tz' is not in this box's zone list (timedatectl list-timezones)"
}

_host_active_agent_units() {
  local u
  while read -r u _; do
    [[ "$u" =~ $HOST_AGENT_UNIT_RE ]] && printf '%s\n' "$u"
  done < <(_host_systemctl list-units --type=service --state=active --plain --no-legend '5dive-agent@*.service' 2>/dev/null)
  return 0
}

# PARKED AGENTS ARE NOT RESTARTED (DIVE-5165, DIVE-4033). `desiredState: stopped`
# is the operator's recorded intent (`5dive agent stop` writes it). The restart set
# is already only the ACTIVE units, and a parked agent's unit is normally stopped,
# so it is not in that set — but the list is read BEFORE the loop restarts, and a
# `systemctl restart` of a unit stopped in between STARTS it. Asking the registry
# per unit closes that window, and it also leaves a running-but-parked
# contradiction for the operator to reconcile rather than bouncing it.
# Same reading as cmd_selfupdate.sh's _agent_is_parked: only an explicit,
# parseable `stopped` skips; absent field, missing registry or no jq restart.
_host_agent_parked() {
  local name="${1:-}" desired=""
  [[ -n "$name" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "${REGISTRY:-}" && -f "$REGISTRY" ]] || return 1
  desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // "running"' "$REGISTRY" 2>/dev/null) || return 1
  [[ "$desired" == "stopped" ]]
}

cmd_host_timezone() {
  local action="" tz="" do_restart=1
  while (( $# )); do
    case "$1" in
      --json) JSON_MODE=1 ;;
      --no-restart) do_restart=0 ;;
      -h|--help) printf '%s\n' \
        "usage: 5dive host timezone                          # this box's system time zone" \
        "       5dive host timezone set <IANA zone> [--no-restart]" \
        "  set   change the system zone, then restart cron and every running agent so they" \
        "        pick it up. A no-op (nothing restarted) when the zone is already that one." \
        "        --no-restart leaves the running processes on the old zone until they restart."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$action" ]]; then action="$1"
        elif [[ "$action" == set && -z "$tz" ]]; then tz="$1"
        else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done

  local cur; cur=$(_host_tz_current)
  case "$action" in
    "")
      ok "time zone: ${cur:-unknown}" '{timezone:(if $t=="" then null else $t end)}' --arg t "$cur"
      ;;
    set)
      [[ -n "$tz" ]] || fail "$E_USAGE" "usage: 5dive host timezone set <IANA zone> [--no-restart]"
      require_root "host timezone set $tz"
      _host_validate_tz "$tz"
      if [[ "$tz" == "$cur" ]]; then
        ok "time zone already $tz — nothing changed" \
           '{timezone:$t, previous:$t, changed:false, restarted:[]}' --arg t "$tz"
        return 0
      fi
      _host_timedatectl set-timezone "$tz" \
        || fail "$E_GENERIC" "timedatectl set-timezone $tz failed"
      local -a restarted=()
      if (( do_restart )); then
        _host_systemctl try-restart cron.service >/dev/null 2>&1 || true
        local u
        while read -r u; do
          [[ -n "$u" ]] || continue
          local n="${u#5dive-agent@}"; n="${n%.service}"
          if _host_agent_parked "$n"; then
            warn "agent '$n' is parked (desiredState=stopped) — not restarting it; it picks up $tz when it is started"
            continue
          fi
          if _host_systemctl restart "$u" >&2; then restarted+=("$u"); fi
        done < <(_host_active_agent_units)
      fi
      ok "time zone ${cur:-unknown} -> $tz${restarted[*]:+ (restarted: ${restarted[*]})}" \
         '{timezone:$t, previous:(if $p=="" then null else $p end), changed:true,
           restarted:($r | split("\n") | map(select(. != "")))}' \
         --arg t "$tz" --arg p "$cur" --arg r "$(printf '%s\n' "${restarted[@]}")"
      ;;
    *) fail "$E_USAGE" "usage: 5dive host timezone [set <IANA zone>] [--no-restart]" ;;
  esac
}

# --- host companion (DIVE-5622) -----------------------------------------------
# A partner client who picks Russia gets a normal EU box plus the smallest
# Russian box, its "companion". The agent stays here; the companion is only its
# door to Russian-only websites (a SOCKS proxy through the companion's egress)
# and the place it deploys Russia-facing services (plain `ssh ru-box`).
# 5dive-api builds the companion, puts this box's public key on it, then calls
# `set` over /shell/exec with the companion's address and host key, and the
# private key on stdin (never on argv: argv is audited and visible in ps).
#
# Every path written is fixed. The only caller inputs are the IPv4, the host-key
# line and the private key, each refused unless it has its exact shape. The
# proxy is `ssh -N -D 127.0.0.1:1080`: no remote command, bound to loopback, run
# as nobody with group claude (the group that reads the key), never as root. The
# ssh config pins the host key (StrictHostKeyChecking yes), so a caller cannot
# make the proxy trust a host it did not name.
HOST_COMPANION_ALIAS="ru-box"
HOST_COMPANION_SOCKS_PORT=1080
HOST_COMPANION_UNIT="5dive-companion-proxy.service"
HOST_COMPANION_GROUP="claude"
HOST_COMPANION_MD_BEGIN="<!-- 5dive-companion:begin (DIVE-5622; written by 5dive host companion) -->"
HOST_COMPANION_MD_END="<!-- 5dive-companion:end -->"
HOST_IPV4_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
HOST_HOSTKEY_RE='^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa) [A-Za-z0-9+/]+={0,2}$'
HOST_PRIVKEY_BODY_RE='^[A-Za-z0-9+/=]+$'

# Fixed paths. The FIVE_COMPANION_* overrides exist for the unit harness only.
_host_companion_dir()  { printf '%s' "${FIVE_COMPANION_DIR:-/etc/5dive/companion}"; }
_host_companion_ssh_conf() { printf '%s' "${FIVE_COMPANION_SSH_CONF:-/etc/ssh/ssh_config.d/50-5dive-companion.conf}"; }
_host_companion_unit_path() { printf '%s/%s' "${FIVE_COMPANION_UNIT_DIR:-/etc/systemd/system}" "$HOST_COMPANION_UNIT"; }
# Claude Code's managed memory: every seat on the box reads it, including seats
# created after this ran (a per-seat ~/.claude/CLAUDE.md would miss those).
_host_companion_md() { printf '%s' "${FIVE_COMPANION_MD:-/etc/claude-code/CLAUDE.md}"; }

# Seams onto chgrp and the group lookup, so the harness runs without the group or root.
_host_companion_chgrp() { chgrp "$@"; }
_host_companion_group_exists() { getent group "$HOST_COMPANION_GROUP" >/dev/null 2>&1; }

_host_companion_validate_key() {   # <key text>
  local key="$1" line first="" last="" n=0
  (( ${#key} <= 16384 )) || fail "$E_VALIDATION" "private key on stdin is over 16 KiB"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    n=$((n+1))
    if (( n == 1 )); then first="$line"; continue; fi
    if [[ -n "$last" ]]; then
      [[ "$last" =~ $HOST_PRIVKEY_BODY_RE ]] || fail "$E_VALIDATION" "private key on stdin is not an OpenSSH private key"
    fi
    last="$line"
  done <<<"$key"
  [[ "$first" == "-----BEGIN OPENSSH PRIVATE KEY-----" && "$last" == "-----END OPENSSH PRIVATE KEY-----" ]] \
    || fail "$E_VALIDATION" "private key on stdin is not an OpenSSH private key (-----BEGIN OPENSSH PRIVATE KEY-----)"
  (( n >= 3 )) || fail "$E_VALIDATION" "private key on stdin is empty"
}

_host_companion_render_ssh_conf() {   # <ipv4>
  local d; d=$(_host_companion_dir)
  printf '%s\n' \
    "# Written by \`5dive host companion set\` (DIVE-5622). Rewritten on every set; do not edit." \
    "Host ${HOST_COMPANION_ALIAS} $1" \
    "  HostName $1" \
    "  User root" \
    "  Port 22" \
    "  IdentityFile ${d}/id_ed25519" \
    "  IdentitiesOnly yes" \
    "  HostKeyAlias ${HOST_COMPANION_ALIAS}" \
    "  UserKnownHostsFile ${d}/known_hosts" \
    "  StrictHostKeyChecking yes" \
    "  BatchMode yes" \
    "  ServerAliveInterval 15" \
    "  ServerAliveCountMax 3"
}

_host_companion_render_unit() {
  printf '%s\n' \
    "# Written by \`5dive host companion set\` (DIVE-5622)." \
    "[Unit]" \
    "Description=5dive: SOCKS proxy through the Russian companion box (127.0.0.1:${HOST_COMPANION_SOCKS_PORT})" \
    "After=network-online.target" \
    "Wants=network-online.target" \
    "" \
    "[Service]" \
    "User=nobody" \
    "Group=${HOST_COMPANION_GROUP}" \
    "ExecStart=/usr/bin/ssh -F $(_host_companion_ssh_conf) -N -D 127.0.0.1:${HOST_COMPANION_SOCKS_PORT} -o ExitOnForwardFailure=yes ${HOST_COMPANION_ALIAS}" \
    "Restart=always" \
    "RestartSec=5" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target"
}

_host_companion_render_md() {
  printf '%s\n' \
    "$HOST_COMPANION_MD_BEGIN" \
    "## Russian companion server" \
    "This server is in the EU. It has a companion server in Russia, reachable as \`ssh ru-box\` (root)." \
    "- When a website refuses this server, or it is a Russian (.ru) service, go through the Russian proxy: \`curl --proxy socks5h://127.0.0.1:${HOST_COMPANION_SOCKS_PORT} <url>\` (a browser: \`--proxy-server=socks5://127.0.0.1:${HOST_COMPANION_SOCKS_PORT}\`)." \
    "- Russia-facing services, and data that must stay in Russia, are deployed to ru-box over SSH. Everything else stays here." \
    "$HOST_COMPANION_MD_END"
}

# The managed CLAUDE.md with our block removed (the rest of the file untouched).
_host_companion_md_without_block() {
  local f; f=$(_host_companion_md)
  [[ -f "$f" ]] || return 0
  awk -v b="$HOST_COMPANION_MD_BEGIN" -v e="$HOST_COMPANION_MD_END" \
    '$0==b{skip=1; next} skip && $0==e{skip=0; next} !skip' "$f"
}

_host_companion_write() {   # <path> <mode> <content>  — atomic, same directory
  local path="$1" mode="$2" tmp
  mkdir -p "$(dirname "$path")" || fail "$E_GENERIC" "cannot create $(dirname "$path")"
  tmp=$(mktemp "${path}.XXXXXX") || fail "$E_GENERIC" "cannot write $path"
  printf '%s' "$3" > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path" \
    || { rm -f "$tmp"; fail "$E_GENERIC" "cannot write $path"; }
}

_host_companion_configured_host() {
  local f; f=$(_host_companion_ssh_conf)
  [[ -f "$f" ]] || return 0
  awk '$1=="HostName"{print $2; exit}' "$f"
}

cmd_host_companion() {
  local action="" host="" hostkey="" key_stdin=0
  while (( $# )); do
    case "$1" in
      --json) JSON_MODE=1 ;;
      --host=*) host="${1#--host=}" ;;
      --host-key=*) hostkey="${1#--host-key=}" ;;
      --key-stdin) key_stdin=1 ;;
      -h|--help) printf '%s\n' \
        "usage: 5dive host companion                       # is a Russian companion box set up here?" \
        "       5dive host companion set --host=<ipv4> --host-key='<type> <base64>' --key-stdin" \
        "       5dive host companion remove" \
        "  set     5dive-api runs this once the companion is built: the OpenSSH private key comes on" \
        "          stdin. Writes \`ssh ${HOST_COMPANION_ALIAS}\`, the SOCKS proxy 127.0.0.1:${HOST_COMPANION_SOCKS_PORT} (unit ${HOST_COMPANION_UNIT})" \
        "          and a short note in /etc/claude-code/CLAUDE.md telling the agents when to use them." \
        "  remove  undoes all of it."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$action" ]]; then action="$1"; else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done

  local dir conf unit md
  dir=$(_host_companion_dir); conf=$(_host_companion_ssh_conf); unit=$(_host_companion_unit_path); md=$(_host_companion_md)
  case "$action" in
    "")
      local cur state="inactive"
      cur=$(_host_companion_configured_host)
      [[ -n "$cur" ]] && state=$(_host_systemctl is-active "$HOST_COMPANION_UNIT" 2>/dev/null || true)
      [[ -n "$state" ]] || state="unknown"
      if [[ -z "$cur" ]]; then
        ok "no companion box set up on this box" '{configured:false, host:null, proxy:null}'
      else
        ok "companion box ${cur} (ssh ${HOST_COMPANION_ALIAS}); proxy socks5h://127.0.0.1:${HOST_COMPANION_SOCKS_PORT} is ${state}" \
           '{configured:true, host:$h, alias:$a, proxy:$p, proxyState:$s}' \
           --arg h "$cur" --arg a "$HOST_COMPANION_ALIAS" --arg p "socks5h://127.0.0.1:${HOST_COMPANION_SOCKS_PORT}" --arg s "$state"
      fi
      ;;
    set)
      require_root "host companion set"
      [[ "$host" =~ $HOST_IPV4_RE ]] || fail "$E_VALIDATION" "--host must be an IPv4 address, got '${host:0:64}'"
      [[ "$hostkey" =~ $HOST_HOSTKEY_RE ]] || fail "$E_VALIDATION" "--host-key must be '<key type> <base64>' (an ssh host public key)"
      (( key_stdin )) || fail "$E_USAGE" "the private key comes on stdin: pass --key-stdin"
      local key; key=$(cat)
      _host_companion_validate_key "$key"
      _host_companion_group_exists \
        || fail "$E_GENERIC" "group '$HOST_COMPANION_GROUP' does not exist on this box"

      mkdir -p "$dir" && chmod 0755 "$dir" || fail "$E_GENERIC" "cannot create $dir"
      _host_companion_write "$dir/id_ed25519" 0640 "${key}"$'\n'
      _host_companion_chgrp "$HOST_COMPANION_GROUP" "$dir/id_ed25519" \
        || fail "$E_GENERIC" "cannot give group $HOST_COMPANION_GROUP the key at $dir/id_ed25519"
      _host_companion_write "$dir/known_hosts" 0644 "${HOST_COMPANION_ALIAS} ${hostkey}"$'\n'
      _host_companion_write "$conf" 0644 "$(_host_companion_render_ssh_conf "$host")"$'\n'
      _host_companion_write "$unit" 0644 "$(_host_companion_render_unit)"$'\n'
      local rest sep=$'\n\n'; rest=$(_host_companion_md_without_block)
      [[ -n "${rest//[$'\n ']/}" ]] || { rest=""; sep=""; }
      _host_companion_write "$md" 0644 "${rest}${sep}$(_host_companion_render_md)"$'\n'

      _host_systemctl daemon-reload >/dev/null 2>&1 || fail "$E_GENERIC" "systemctl daemon-reload failed"
      _host_systemctl enable "$HOST_COMPANION_UNIT" >/dev/null 2>&1 || fail "$E_GENERIC" "systemctl enable $HOST_COMPANION_UNIT failed"
      _host_systemctl restart "$HOST_COMPANION_UNIT" >/dev/null 2>&1 || fail "$E_GENERIC" "systemctl restart $HOST_COMPANION_UNIT failed"
      ok "companion box $host set up: ssh ${HOST_COMPANION_ALIAS}, proxy socks5h://127.0.0.1:${HOST_COMPANION_SOCKS_PORT} (${HOST_COMPANION_UNIT})" \
         '{configured:true, host:$h, alias:$a, proxy:$p, unit:$u}' \
         --arg h "$host" --arg a "$HOST_COMPANION_ALIAS" --arg p "socks5h://127.0.0.1:${HOST_COMPANION_SOCKS_PORT}" --arg u "$HOST_COMPANION_UNIT"
      ;;
    remove)
      require_root "host companion remove"
      _host_systemctl disable --now "$HOST_COMPANION_UNIT" >/dev/null 2>&1 || true
      rm -f "$unit" "$conf" "$dir/id_ed25519" "$dir/known_hosts"
      rmdir "$dir" 2>/dev/null || true
      _host_systemctl daemon-reload >/dev/null 2>&1 || true
      if [[ -f "$md" ]]; then
        local rest; rest=$(_host_companion_md_without_block)
        if [[ -n "${rest//[$'\n ']/}" ]]; then _host_companion_write "$md" 0644 "${rest}"$'\n'; else rm -f "$md"; fi
      fi
      ok "companion box removed from this box" '{configured:false}'
      ;;
    *) fail "$E_USAGE" "usage: 5dive host companion [set --host=<ipv4> --host-key=<line> --key-stdin | remove]" ;;
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
    timezone) cmd_host_timezone "$@" ;;
    companion) cmd_host_companion "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive host <unit|journal|cron|timezone|companion> ... (see: 5dive --help)" ;;
  esac
}
