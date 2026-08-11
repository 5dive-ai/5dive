#!/usr/bin/env bash
# DIVE-3221 unit harness: `5dive host` may not become an agent -> root escape.
#
# WHAT THIS PINS, AND WHY IT IS THE WHOLE REVIEW.
#
# An `admin` agent's sudo grant is `/usr/local/bin/5dive, /usr/local/bin/5dive *`
# — the whole CLI as root, INCLUDING subcommands that did not exist when the
# drop-in was written. That grant is a boundary only because of one standing
# invariant (stated above write_admin_sudoers): no 5dive subcommand may exec
# agent-controlled input as root. `5dive host` is the first subcommand written
# specifically to touch systemd, the journal and crontab, so it is the first one
# where a careless edit converts `cli-root` into `root-all` for EVERY admin agent
# on the box at once.
#
# So this harness asserts two different kinds of thing:
#
#   1. VALUE assertions — each validator refuses the inputs that would turn a
#      structured parameter back into free-form content (traversal in a unit
#      name, a newline or a systemd %-specifier in a WorkingDirectory value, a
#      free-form journalctl time string, an option-shaped user name).
#
#   2. STRUCTURAL assertions — greps over src/cmd_host.sh itself: no eval, no
#      `sh -c`, no editor, no crontab verb other than `-l -u`, no raw
#      systemctl/journalctl outside the two pager-pinned wrappers, and exactly
#      one writable path under /etc/systemd/system. A value assertion cannot see
#      a NEW verb someone adds later; the structural ones can, which is why both
#      are here. They read the SOURCE file rather than the built bundle so a
#      finding names the line a contributor would edit.
#
# Sources the src/ libs directly — no root, no systemd, no network. The one
# systemd-shaped decision (does this unit run as root?) is driven through the
# _host_unit_property seam, so the root-refusal is exercised deterministically
# whether or not the runner has systemd.
#
# Run: bash tests/host_verbs_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/host-verbs-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_host.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }

# A refusal is `fail`, which exits. Run in a subshell so the harness survives it
# and the exit code + message are both observable.
refuses() {
  local desc="$1"; shift
  local out rc
  out=$( "$@" 2>&1 ); rc=$?
  if (( rc != 0 )); then
    pass "$desc (refused, rc=$rc)"
  else
    bad "$desc — ACCEPTED, expected a refusal. Output: ${out:-<none>}"
  fi
}

accepts() {
  local desc="$1"; shift
  local out rc
  out=$( "$@" 2>&1 ); rc=$?
  if (( rc == 0 )); then
    pass "$desc"
  else
    bad "$desc — REFUSED (rc=$rc): ${out:-<none>}"
  fi
}

echo "== unit names: the string becomes a DIRECTORY under /etc/systemd/system =="
refuses "empty unit"                        _host_validate_unit ""            service
refuses "leading '-' (reads as an option)"  _host_validate_unit "-x.service"  service
refuses "path traversal"                    _host_validate_unit "../../etc/systemd/system/x.service" service
refuses "'..' anywhere"                     _host_validate_unit "a..b.service" service
refuses "a slash"                           _host_validate_unit "a/b.service" service
refuses "no type suffix (systemd would assume .service; we would validate a different name than it resolves)" \
                                            _host_validate_unit "5dive-api"   service
refuses "shell metacharacters"              _host_validate_unit '5dive-api.service; id' service
refuses "command substitution"              _host_validate_unit '$(id).service' service
refuses "a newline in the unit name"        _host_validate_unit "$(printf 'a.service\nb.service')" service
refuses "a .timer where a .service is required (WorkingDirectory is a service property)" \
                                            _host_validate_unit "backup.timer" service
accepts "a plain service"                   _host_validate_unit "5dive-api.service" service
accepts "a templated instance"              _host_validate_unit "5dive-agent@dev.service" service
accepts "a .timer for the read verbs"       _host_validate_unit "backup.timer" any
accepts "a .socket for the read verbs"      _host_validate_unit "x.socket"    any
refuses "an unknown suffix even for reads"  _host_validate_unit "x.conf"      any

echo
echo "== workdir: this value lands on a WorkingDirectory= line in a unit file =="
refuses "empty"                             _host_validate_workdir ""
refuses "relative path"                     _host_validate_workdir "opt/5dive-api/current"
refuses "'..' component"                    _host_validate_workdir "/opt/../etc"
refuses "'%' — a systemd specifier introducer, not inert text" \
                                            _host_validate_workdir "/opt/%h"
refuses "a newline (would append a SECOND directive to [Service])" \
                                            _host_validate_workdir "$(printf '/tmp\nExecStart=/bin/sh')"
refuses "a semicolon"                       _host_validate_workdir "/tmp;id"
refuses "a space"                           _host_validate_workdir "/tmp/a b"
refuses "'\$' expansion-shaped"             _host_validate_workdir '/tmp/$HOME'
refuses "root itself"                       _host_validate_workdir "/"
refuses "a path that does not exist"        _host_validate_workdir "/nonexistent-$$-dive3221"
mkdir -p "$TMP/wd" && : > "$TMP/plain-file"
accepts "an existing absolute directory"    _host_validate_workdir "$TMP/wd"
refuses "an existing FILE"                  _host_validate_workdir "$TMP/plain-file"

echo
echo "== the drop-in is a fixed template: one section, one directive =="
DROPIN_OUT=$(_host_render_workdir_dropin "$TMP/wd")
if [[ $(grep -c '^WorkingDirectory=' <<<"$DROPIN_OUT") -eq 1 ]]; then
  pass "renders exactly one WorkingDirectory= line"
else
  bad "expected exactly one WorkingDirectory= line, got: $DROPIN_OUT"
fi
if [[ $(grep -cE '^[A-Za-z]+=' <<<"$DROPIN_OUT") -eq 1 ]]; then
  pass "renders exactly one directive of ANY kind"
else
  bad "the drop-in carries more than one directive: $DROPIN_OUT"
fi
if grep -qE '^(ExecStart|ExecStartPre|ExecStartPost|ExecStop|ExecReload|User|Environment)' <<<"$DROPIN_OUT"; then
  bad "the drop-in can emit an exec-bearing or identity-bearing directive"
else
  pass "no Exec*/User/Environment directive is reachable from the renderer"
fi
if [[ $(grep -c '^\[' <<<"$DROPIN_OUT") -eq 1 && "$(grep '^\[' <<<"$DROPIN_OUT")" == "[Service]" ]]; then
  pass "exactly one section, and it is [Service]"
else
  bad "expected exactly one [Service] section: $DROPIN_OUT"
fi

echo
echo "== repoint/revert refuse a ROOT-running unit (the invariant's sharp edge) =="
# Drive the systemd seam. WorkingDirectory is a code pointer whenever ExecStart
# carries a relative argument (measured on this host: 5dive-api.service runs
# `node dist/index.js`), so repointing a ROOT unit is 'exec caller-chosen content
# as root' with two extra steps — exactly what the cli-root grant forbids.
STUB_USER="claude"; STUB_LOAD="loaded"
_host_unit_property() {
  case "$2" in
    User)      printf '%s' "$STUB_USER" ;;
    LoadState) printf '%s' "$STUB_LOAD" ;;
    *)         printf '' ;;
  esac
}

STUB_USER="root";   refuses "User=root"                        _host_require_repointable "x.service"
# The fail-open case: systemd's default for a system unit IS root, so an EMPTY
# User= must land on the same branch as the literal string "root". Reading empty
# as "not root" would disable this guard on almost every unit on the box.
STUB_USER="";       refuses "User= empty (systemd default is root)" _host_require_repointable "x.service"
STUB_USER="0";      refuses "User=0"                           _host_require_repointable "x.service"
STUB_USER="claude"; accepts "User=claude (the driver case: 5dive-api / 5dive-frontend)" \
                                                               _host_require_repointable "x.service"
STUB_USER="agent-marketing"; accepts "User=agent-marketing (5dive-discord-welcome)" \
                                                               _host_require_repointable "x.service"
STUB_USER="claude"; STUB_LOAD="not-found"
refuses "a unit systemd does not know (LoadState!=loaded)"     _host_require_repointable "x.service"
STUB_LOAD="loaded"

echo
echo "== journal: --lines and --since are structured, not forwarded =="
refuses "--lines non-numeric"        _host_validate_lines "all"
refuses "--lines negative"           _host_validate_lines "-5"
refuses "--lines zero"               _host_validate_lines "0"
refuses "--lines over the cap"       _host_validate_lines "99999"
accepts "--lines=200"                _host_validate_lines "200"
refuses "--since free-form ('yesterday')"      _host_since_phrase "yesterday"
refuses "--since epoch form ('@0')"            _host_since_phrase "@0"
refuses "--since with an injected flag"        _host_since_phrase "1h --output=cat"
refuses "--since empty"                        _host_since_phrase ""
accepts "--since=30m"                          _host_since_phrase "30m"
for spec in 30m 2h 7d; do
  phrase=$(_host_since_phrase "$spec" 2>/dev/null)
  case "$phrase" in
    *" minutes ago"|*" hours ago"|*" days ago")
      pass "--since=$spec maps to a fixed phrase: '$phrase'" ;;
    *)
      bad "--since=$spec produced an unexpected phrase: '$phrase'" ;;
  esac
done

echo
echo "== cron target: a login name, and the user must exist =="
refuses "empty user"                 _host_validate_user ""
refuses "leading '-'"                _host_validate_user "-u"
refuses "metacharacters"             _host_validate_user 'root;id'
refuses "a path"                     _host_validate_user "/etc/passwd"
refuses "a user that does not exist" _host_validate_user "nosuchuser3221"
accepts "root (exists; read-only)"   _host_validate_user "root"

echo
echo "== structural: what the SOURCE file can exec at all =="
# Strip comments and blank lines first: every dangerous token is NAMED in this
# file's own rationale, and a grep that cannot tell a warning from a call site
# would report the documentation as the defect.
CODE="$TMP/cmd_host.code.sh"
grep -vE '^[[:space:]]*#' "$SRC/cmd_host.sh" | grep -vE '^[[:space:]]*$' > "$CODE"

structural_absent() {   # <desc> <extended-regex>
  local desc="$1" re="$2" hits
  hits=$(grep -nE "$re" "$CODE")
  if [[ -z "$hits" ]]; then
    pass "$desc"
  else
    bad "$desc — found: $hits"
  fi
}

structural_absent "no eval"                        '(^|[^A-Za-z_])eval[[:space:]]'
structural_absent "no sh -c / bash -c"             '(^|[^A-Za-z_-])(sh|bash|dash|zsh)[[:space:]]+-[a-z]*c'
structural_absent "no systemd-run"                 'systemd-run'
structural_absent "no editor handed to a child"    '(EDITOR|VISUAL)='
structural_absent "no su / sudo -u re-entry"       '(^|[[:space:]])(su|sudo)[[:space:]]'
structural_absent "no crontab verb other than a read" \
                                                   'crontab[^|]*(-e|-r|--remove|-l[[:space:]]+[^-])'
structural_absent "no unit-file write outside the fixed basename" \
                                                   '>[[:space:]]*"?/etc/systemd'
structural_absent "no recursive removal"           'rm[[:space:]]+(-[a-zA-Z]*r|-[a-zA-Z]*R|-rf|-fr)'
structural_absent "no chmod/chown of a caller-named path" \
                                                   'ch(mod|own)[^\n]*\$\{?[0-9]'

# The pager escape (`!sh` out of less) is what DIVE-1088 excluded raw journalctl
# and `systemctl status` grants FOR. Closing it by convention is not closing it:
# every call must go through the two wrappers that pin SYSTEMD_PAGER in code.
# Cut the two wrapper bodies out before looking for raw calls: the wrappers are
# the SANCTIONED call sites, and the search is for a call that bypasses them.
NOWRAP="$TMP/cmd_host.nowrap.sh"
awk '
  /^_host_(systemctl|journalctl)\(\)/ { skip=1 }
  skip && /^}/ { skip=0; next }
  !skip { print }
' "$CODE" > "$NOWRAP"

# Anchored at COMMAND position (line start, $(, |, &&, ;) — the binary names also
# appear inside this file's refusal messages, and a grep that cannot tell a call
# from a diagnostic reports the error text as the defect.
cmd_position='(^[[:space:]]*|\$\([[:space:]]*|\|[[:space:]]*|&&[[:space:]]*|;[[:space:]]*)'
for binary in systemctl journalctl; do
  hits=$(grep -nE "${cmd_position}${binary}([[:space:]]|\$)" "$NOWRAP")
  if [[ -z "$hits" ]]; then
    pass "every $binary call goes through the pager-pinned _host_$binary wrapper"
  else
    bad "raw $binary call outside the wrapper: $hits"
  fi
done

for wrapper in _host_systemctl _host_journalctl; do
  body=$(sed -n "/^${wrapper}()/,/^}/p" "$CODE")
  if grep -q -- '--no-pager' <<<"$body" && grep -q 'SYSTEMD_PAGER=cat' <<<"$body" && grep -q 'PAGER=cat' <<<"$body"; then
    pass "$wrapper pins --no-pager AND SYSTEMD_PAGER/PAGER in code, not in the caller's env"
  else
    bad "$wrapper no longer pins the pager: $body"
  fi
done

# The write surface, stated as a number. Exactly one basename is ever created or
# removed under /etc/systemd/system, and it is a constant — so `revert` cannot be
# steered at a drop-in someone else owns.
if grep -q 'HOST_WORKDIR_DROPIN="50-5dive-workdir.conf"' "$SRC/cmd_host.sh" \
   && [[ $(grep -c '_host_dropin_path' "$CODE") -ge 2 ]] \
   && ! grep -qE 'rm[[:space:]]+-f[[:space:]]+"?\$\{?(dir|path)?[^}]*\}?/[^"]*\$' "$CODE"; then
  pass "the removable path is composed from one constant basename, not from caller input"
else
  bad "the drop-in basename is no longer a single constant — re-check what revert can delete"
fi

echo
echo "== registration: the verb is reachable and bundled =="
if grep -qE '^\s+host\)' "$SRC/main.sh" && grep -q 'cmd_host "\$@"' "$SRC/main.sh"; then
  pass "main.sh dispatches 'host'"
else
  bad "main.sh does not dispatch 'host' — the subcommand is unreachable"
fi
if grep -q 'src/cmd_host.sh' build.sh; then
  pass "build.sh concatenates src/cmd_host.sh into the bundle"
else
  bad "src/cmd_host.sh is not in build.sh — it would exist in src/ and not in the shipped binary"
fi
if grep -q 'AUDIT_CMD="host"' "$SRC/main.sh"; then
  pass "host runs are audited"
else
  bad "no AUDIT_CMD for host — 'who repointed this unit' would be unanswerable"
fi

echo
echo "passed=$PASSED failed=$FAILED"
(( FAILED == 0 ))
