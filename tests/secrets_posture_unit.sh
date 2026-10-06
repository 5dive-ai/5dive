#!/usr/bin/env bash
# DIVE-5690: a standard seat must not read the box's keys.
#   * the reconcile moves every group-claude file in the connectors dir, and
#     connectord.env, to group claude-keys; it leaves tools.sh (every seat's
#     BASH_ENV) and an already-tighter root:root file alone, and never follows
#     a symlink
#   * `claude` keeps u:claude:r on each moved file group claude could read; a
#     seat keeps u:agent-<x>:r on its OWN telegram-/discord-<x>.env and on no
#     other; a 600 key moves group and gains no reader
#   * membership follows the registry tier: admin in, standard out (a stale
#     member is dropped), and a second pass changes nothing and says nothing
#   * a failed groupadd changes no file and says so
#   * the standard sudoers template carries the three box-identity grants and
#     still classifies cli-scoped with no extra entries (so the installer's
#     reconcile keeps re-rendering existing seats)
#   * push-notify.sh and box_identity_elevate re-run as root only when sudo
#     grants the exact command, and stay silent otherwise
#   * 5dive-agent-start's claude block does not wait 45s on a login file the
#     seat cannot read: it grades the environment systemd injected
#   * an account login (auth-profiles/<p>/combined.env) moves to claude-keys
#     and its seat readers are exactly the seats whose agents.d/<x>-auth.env
#     links to it; moving a seat to another account moves its read on the next
#     tick (or at once through link_agent_profile); the profile writer keeps
#     that posture across its rename; agents.d/<x>.env (metadata) is untouched
#   * a host with no claude group still writes a key (no chgrp, rc 0, o-rwx)
#   * DIVE-5701: the vendor CLI logins inside an account (auth-profiles/<p>/
#     <type>/) move to claude-keys; their seat readers are the seats of that
#     type on that account, plus every unbound codex seat for the canonical
#     codex account; a backup beside a login has no seat reader; a rebind moves
#     the read; the seed list matches 5dive-agent-start (T13, T9 as root)
#   * DIVE-5714: the same for the default (no-account) logins in /home/claude
#     (.hermes/auth.json, config.yaml, ...): read by the seats of that type on
#     no account; a non-seed file and the codex symlink are left alone (T14, T9)
#   * AS ROOT ONLY (CI: the root-arms job, SP_REQUIRE_ROOT_ARM=1 makes a skip
#     a failure): the same reconcile on real files and a real group, and a
#     real non-member uid in the workspace group is refused every key and still
#     reads tools.sh (the row's acceptance shape)
# The posture lives in src/lib/validation.sh beside _write_connector, so no
# harness can source one without the other.
# Isolation: src/ sourced with OS seams; no network. Run: bash tests/secrets_posture_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${REAL_USERS:-}" ]] && for u in $REAL_USERS; do userdel "$u" 2>/dev/null; done; [[ -n "${REAL_GROUPS:-}" ]] && for g in $REAL_GROUPS; do groupdel "$g" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/secrets-posture-unit.XXXXXX)"
chmod 755 "$TMP"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- fake OS: groups, file groups and ACLs live in files under $TMP/os -------
OS="$TMP/os"; mkdir -p "$OS/groups"
_sp_group_exists() { [[ -f "$OS/groups/$1" ]]; }
_sp_groupadd()     { [[ -z "${FAKE_GROUPADD_FAILS:-}" ]] && : > "$OS/groups/$1"; }
_sp_members()      { cat "$OS/groups/$1" 2>/dev/null; }
_sp_member_add()   { printf '%s\n' "$1" >> "$OS/groups/$2"; }
_sp_member_del()   { grep -vxF "$1" "$OS/groups/$2" > "$OS/tmp"; mv "$OS/tmp" "$OS/groups/$2"; }
_sp_user_exists()  { grep -qxF "$1" "$OS/users"; }
_sp_file_group()   { awk -F'\t' -v f="$1" '$1==f {g=$2} END {print g}' "$OS/fgroup"; }
_sp_chgrp()        {
  # FAKE_CHGRP_REFUSED: what a non-root caller outside the group gets from chgrp.
  [[ -z "${FAKE_CHGRP_REFUSED:-}" ]] || { echo "chgrp: changing group of '$2': Operation not permitted" >&2; return 1; }
  printf '%s\t%s\n' "$2" "$1" >> "$OS/fgroup"; }
_sp_setfacl()      { printf '%s\t%s\n' "$2" "$1" >> "$OS/acl"; }
_sp_unsetfacl()    { awk -F'\t' -v f="$2" -v e="$1:" '!($1==f && index($2, e)==1)' "$OS/acl" > "$OS/acl.tmp"; mv "$OS/acl.tmp" "$OS/acl"; }
_sp_acl_users()    { awk -F'\t' -v f="$1" '$1==f {sub(/^u:/,"",$2); sub(/:r$/,"",$2); print $2}' "$OS/acl" | sort -u; }
acl_of() { awk -F'\t' -v f="$1" '$1==f {print $2}' "$OS/acl" | sort -u | tr '\n' ' '; }

C="$TMP/connectors"; mkdir -p "$C"
# Account logins live under $TMP too, so no arm ever globs the box's own.
AUTH_PROFILES_DIR="$TMP/auth-profiles" ENV_DIR="$TMP/agents.d"; mkdir -p "$AUTH_PROFILES_DIR" "$ENV_DIR"
export CONNECTORS_DIR="$C" FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
# The default (no-account) vendor logins live in /home/claude on a box: a fixture here.
export FIVEDIVE_DEFAULT_CRED_HOME="$TMP/home-claude"
printf 'claude\nagent-seat_a\nagent-seat_b\nagent-x\n' > "$OS/users"
: > "$OS/acl"
for n in anthropic.env openrouter.env telegram-seat_a.env telegram-seat_b.env tools.sh; do
  printf 'K=v\n' > "$C/$n"; chmod 640 "$C/$n"; printf '%s\tclaude\n' "$C/$n" >> "$OS/fgroup"
done
printf 'K=v\n' > "$C/github-app.env"; chmod 600 "$C/github-app.env"; printf '%s\troot\n' "$C/github-app.env" >> "$OS/fgroup"
printf 'K=v\n' > "$C/npm.env"; chmod 600 "$C/npm.env"; printf '%s\tclaude\n' "$C/npm.env" >> "$OS/fgroup"
printf 'CONNECTORD_TOKEN=t\n' > "$FIVEDIVE_CONNECTORD_ENV"; chmod 644 "$FIVEDIVE_CONNECTORD_ENV"
printf '%s\tclaude\n' "$FIVEDIVE_CONNECTORD_ENV" >> "$OS/fgroup"
ln -s "$C/anthropic.env" "$C/link.env"; printf '%s\tclaude\n' "$C/link.env" >> "$OS/fgroup"
REG='{"agents":{"seat_a":{"isolation":"admin"},"seat_b":{"isolation":"standard"},"x":{"isolation":"sandboxed"},"gone":{"isolation":"admin"}}}'

# --- T1: a failed groupadd changes no file and says so ------------------------
out=$(FAKE_GROUPADD_FAILS=1 secrets_posture_reconcile "$REG" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"could not create group claude-keys"* && "$(_sp_file_group "$C/anthropic.env")" == claude ]] \
  && ok_t "T1 no group -> rc!=0, named, files untouched" || bad_t "T1 failed groupadd" "rc=$rc $out"

# --- T2: the reconcile moves the keys and nothing else -------------------------
: > "$OS/groups/claude-keys"; printf 'agent-seat_b\n' > "$OS/groups/claude-keys"   # seat_b: stale member
out=$(secrets_posture_reconcile "$REG" 2>&1); rc=$?
for n in anthropic.env openrouter.env telegram-seat_a.env telegram-seat_b.env; do
  [[ "$(_sp_file_group "$C/$n")" == claude-keys ]] && ok_t "T2 $n -> claude-keys" || bad_t "T2 $n group" "$(_sp_file_group "$C/$n")"
done
[[ "$(_sp_file_group "$FIVEDIVE_CONNECTORD_ENV")" == claude-keys ]] && ok_t "T2 connectord.env -> claude-keys" || bad_t "T2 connectord.env"
[[ "$(stat -c %a "$FIVEDIVE_CONNECTORD_ENV")" == 640 ]] && ok_t "T2 a world bit on a key is cleared (644 -> 640)" || bad_t "T2 o-rwx" "$(stat -c %a "$FIVEDIVE_CONNECTORD_ENV")"
[[ "$(_sp_file_group "$C/tools.sh")" == claude ]] && ok_t "T2 tools.sh stays group claude (every seat's BASH_ENV)" || bad_t "T2 tools.sh moved"
[[ "$(_sp_file_group "$C/github-app.env")" == root ]] && ok_t "T2 an already-tighter root:root file is left alone" || bad_t "T2 root file touched"
[[ "$(_sp_file_group "$C/link.env")" == claude && -z "$(acl_of "$C/link.env")" ]] && ok_t "T2 a symlink is never followed" || bad_t "T2 symlink followed"
[[ "$(_sp_file_group "$C/npm.env")" == claude-keys && -z "$(acl_of "$C/npm.env")" ]] \
  && ok_t "T2 a 600 root:claude key moves group and gains NO reader" || bad_t "T2 600 widened" "$(acl_of "$C/npm.env")"
[[ "$(acl_of "$C/anthropic.env")" == "u:claude:r " ]] && ok_t "T2 anthropic.env: only u:claude:r" || bad_t "T2 anthropic ACL" "$(acl_of "$C/anthropic.env")"
[[ "$(acl_of "$C/telegram-seat_a.env")" == "u:agent-seat_a:r u:claude:r " ]] && ok_t "T2 telegram-seat_a.env: seat_a reads its own token, nobody else added" || bad_t "T2 seat_a ACL" "$(acl_of "$C/telegram-seat_a.env")"
[[ "$(acl_of "$C/telegram-seat_b.env")" == "u:agent-seat_b:r u:claude:r " ]] && ok_t "T2 telegram-seat_b.env: seat_b reads only its own" || bad_t "T2 seat_b ACL" "$(acl_of "$C/telegram-seat_b.env")"
mem=$(sort "$OS/groups/claude-keys" | tr '\n' ' ')
[[ "$mem" == "agent-seat_a claude " ]] && ok_t "T2 members: claude + admin seat_a; standard seat_b dropped; no account -> not added" || bad_t "T2 members" "$mem"
[[ $rc -eq 0 && "$out" == *"6 file(s) moved"*"2 member(s) added, 1 dropped"* ]] && ok_t "T2 summary names the counts" || bad_t "T2 summary" "rc=$rc $out"

# --- T3: idempotent, and --quiet says nothing when nothing changed ------------
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok_t "T3 second --quiet pass: no change, no output" || bad_t "T3 idempotent" "rc=$rc $out"
printf '%s\tclaude\n' "$FIVEDIVE_CONNECTORD_ENV" >> "$OS/fgroup"   # shelld rotated the token
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ "$(_sp_file_group "$FIVEDIVE_CONNECTORD_ENV")" == claude-keys && "$out" == *"1 file(s) moved"* ]] \
  && ok_t "T3 a rewrite back to group claude is re-tightened on the next tick" || bad_t "T3 re-tighten" "$out"

# --- T4: an unreadable registry removes nobody --------------------------------
printf 'agent-seat_b\n' >> "$OS/groups/claude-keys"
registry_read() { return 1; }
secrets_posture_reconcile --quiet "" >/dev/null 2>&1
grep -qxF agent-seat_b "$OS/groups/claude-keys" && ok_t "T4 registry unreadable -> no member removed" || bad_t "T4 removed on a blind read"
_sp_member_del agent-seat_b claude-keys

# --- T5: per-seat sync and the connector writer ------------------------------
secrets_member_sync agent-x admin; grep -qxF agent-x "$OS/groups/claude-keys" && ok_t "T5 sync admin -> member" || bad_t "T5 sync admin"
secrets_member_sync agent-x standard; ! grep -qxF agent-x "$OS/groups/claude-keys" && ok_t "T5 sync standard -> dropped" || bad_t "T5 sync standard"
chown() { :; }
printf 'OPENAI_API_KEY=k\n' | _write_connector openai.env
[[ "$(_sp_file_group "$C/openai.env")" == claude-keys && "$(stat -c %a "$C/openai.env")" == 640 ]] \
  && ok_t "T5 _write_connector writes 640 group claude-keys" || bad_t "T5 writer" "$(_sp_file_group "$C/openai.env") $(stat -c %a "$C/openai.env")"
unset -f chown
secret_file_secure "$C/tools.sh"
[[ "$(_sp_file_group "$C/tools.sh")" == claude ]] && ok_t "T5 secret_file_secure refuses tools.sh" || bad_t "T5 tools.sh secured"

# --- T6: the standard sudoers template ---------------------------------------
source src/cmd_agent_create.sh
sud=$(render_standard_sudoers agent-seat_b 0 0)
for want in '/usr/local/bin/5dive partner hire \*' '/usr/local/bin/5dive hire-link \*' '/usr/local/lib/5dive/push-notify.sh \*'; do
  grep -qE "^agent-seat_b ALL=\(root\) NOPASSWD: ${want}$" <<<"$sud" \
    && ok_t "T6 grant: ${want//\\/}" || bad_t "T6 missing grant ${want//\\/}"
done
grep -q 'telegram-app' <<<"$(grep -v '^#' <<<"$sud")" && bad_t "T6 telegram-app granted" || ok_t "T6 telegram-app link is not granted"
[[ "$(classify_sudo_grant <<<"$sud")" == "cli-scoped|root|0" ]] \
  && ok_t "T6 template still classifies cli-scoped, no extra entries" || bad_t "T6 classify" "$(classify_sudo_grant <<<"$sud")"
if command -v visudo >/dev/null 2>&1; then
  printf '%s\n' "$sud" > "$TMP/sudoers"
  visudo -cf "$TMP/sudoers" >/dev/null 2>&1 && ok_t "T6 visudo accepts the template" || bad_t "T6 visudo" "$(visudo -cf "$TMP/sudoers" 2>&1)"
else
  printf 'skip - T6 visudo not installed here\n'
fi

# --- T7: push-notify.sh and box_identity_elevate ------------------------------
# A file only a non-root uid is refused: as root, the arms run as uid 65534.
AS_SEAT=()
(( EUID == 0 )) && command -v setpriv >/dev/null && AS_SEAT=(setpriv --reuid=65534 --regid=65534 --clear-groups)
can_lock() { (( EUID != 0 )) || (( ${#AS_SEAT[@]} )); }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
[ "$1 $2" = "-n -l" ] && exit "${SUDO_L_RC:-0}"
exit 0
STUB
chmod 755 "$TMP/bin" "$TMP/bin/sudo"
export SUDO_LOG="$TMP/sudo.log"; : > "$SUDO_LOG"; chmod 666 "$SUDO_LOG"
HOOK="$TMP/push-notify.sh"
sed "s#/etc/5dive/connectord.env#$TMP/locked.env#" hooks/push-notify.sh > "$HOOK"; chmod 644 "$HOOK"
sed -n '/^# -------- who may read a key on this box/,$p' src/lib/validation.sh > "$TMP/sp.sh"; chmod 644 "$TMP/sp.sh"
seat_env() { env PATH="$TMP/bin:$PATH" SUDO_LOG="$SUDO_LOG" "$@"; }
printf 'CONNECTORD_TOKEN=t\n' > "$TMP/locked.env"
if can_lock; then
  chmod 000 "$TMP/locked.env"
  : > "$SUDO_LOG"; seat_env "${AS_SEAT[@]}" bash "$HOOK" "done" "hi there" seat_b; rc=$?
  [[ $rc -eq 0 && "$(tail -1 "$SUDO_LOG")" == "-n /usr/local/lib/5dive/push-notify.sh done hi there seat_b" ]] \
    && ok_t "T7 push-notify: unreadable token -> re-runs as root with the same args" || bad_t "T7 push elevate" "rc=$rc $(cat "$SUDO_LOG")"
  : > "$SUDO_LOG"; seat_env SUDO_L_RC=1 "${AS_SEAT[@]}" bash "$HOOK" "done" x seat_b; rc=$?
  [[ $rc -eq 0 && "$(wc -l < "$SUDO_LOG")" == 1 ]] && ok_t "T7 push-notify: no grant -> silent no-op, only sudo -l asked" || bad_t "T7 push no grant" "rc=$rc $(cat "$SUDO_LOG")"
  rm -f "$TMP/locked.env"; : > "$SUDO_LOG"; seat_env "${AS_SEAT[@]}" bash "$HOOK" "done" x seat_b
  [[ ! -s "$SUDO_LOG" ]] && ok_t "T7 push-notify: no token file (OSS box) -> sudo never asked" || bad_t "T7 push OSS" "$(cat "$SUDO_LOG")"
  printf 'CONNECTORD_TOKEN=t\n' > "$TMP/locked.env"; chmod 000 "$TMP/locked.env"
  : > "$SUDO_LOG"
  out=$(seat_env FIVEDIVE_CONNECTORD_ENV="$TMP/locked.env" JSON_MODE=1 "${AS_SEAT[@]}" \
        bash -c '. "$1"; box_identity_elevate hire-link acme; echo RETURNED' _ "$TMP/sp.sh" 2>&1)
  [[ "$out" != *RETURNED* && "$(tail -1 "$SUDO_LOG")" == "-n /usr/local/bin/5dive hire-link acme --json" ]] \
    && ok_t "T7 box_identity_elevate: exec sudo with the verb, keeping --json" || bad_t "T7 elevate" "$out | $(cat "$SUDO_LOG")"
  : > "$SUDO_LOG"
  out=$(seat_env FIVEDIVE_CONNECTORD_ENV="$TMP/locked.env" SUDO_L_RC=1 "${AS_SEAT[@]}" \
        bash -c '. "$1"; box_identity_elevate hire-link acme; echo RETURNED' _ "$TMP/sp.sh" 2>&1)
  [[ "$out" == *RETURNED* && "$(wc -l < "$SUDO_LOG")" == 1 ]] && ok_t "T7 box_identity_elevate: no grant -> returns, the verb refuses as before" || bad_t "T7 elevate no grant" "$out"
  chmod 644 "$TMP/locked.env"; : > "$SUDO_LOG"
  out=$(seat_env FIVEDIVE_CONNECTORD_ENV="$TMP/locked.env" "${AS_SEAT[@]}" \
        bash -c '. "$1"; box_identity_elevate hire-link acme; echo RETURNED' _ "$TMP/sp.sh" 2>&1)
  [[ "$out" == *RETURNED* && ! -s "$SUDO_LOG" ]] && ok_t "T7 box_identity_elevate: readable file -> no sudo at all" || bad_t "T7 elevate readable" "$out"
else
  printf 'skip - T7 needs a non-root uid or setpriv\n'
fi

# --- T8: 5dive-agent-start's claude block -------------------------------------
BLOCK=$(awk '
  $0 == "if [[ \"$TYPE\" == \"claude\" ]]; then" { on=1; b="" }
  on { b = b $0 ORS }
  on && $0 == "fi" { if (b ~ /_creds_re=/) { printf "%s", b; exit } on=0 }
' 5dive-agent-start)
[[ "$BLOCK" == *_creds_env_only* ]] && ok_t "T8 extracted the real claude credential block" || bad_t "T8 extract" "${BLOCK:0:200}"
mkdir -p "$TMP/auth"; chmod 755 "$TMP/auth"
{ printf 'TYPE=claude PROFILE="" NAME=seat_b\n'
  printf 'cred_seed_ok() { echo SEED_OK; }; cred_seed_failed() { echo SEED_FAILED; }\n'
  printf 'start=$SECONDS\n'
  printf '%s\n' "${BLOCK//\/etc\/5dive\/connectors\/anthropic.env/$TMP/auth/anthropic.env}"
  printf 'echo "took=$((SECONDS - start))"\n'
} > "$TMP/block.sh"; chmod 644 "$TMP/block.sh"
run_block() { env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN "$@" bash "$TMP/block.sh" 2>&1; }
printf 'CLAUDE_CODE_OAUTH_TOKEN=x\n' > "$TMP/auth/anthropic.env"
# $SECONDS is whole wall-clock seconds, so a no-wait run that crosses a second
# boundary reads took=1 (a merge-queue flake). took=[01] still tells it from the 6s wait.
if can_lock; then
  chmod 000 "$TMP/auth/anthropic.env"
  out=$(run_block CLAUDE_CODE_OAUTH_TOKEN=from-systemd CLAUDE_AUTH_WAIT_SECS=6 "${AS_SEAT[@]}")
  [[ "$out" == *SEED_OK* && "$out" =~ took=[01]($|[^0-9]) ]] && ok_t "T8 unreadable login + env token -> ok, no wait" || bad_t "T8 env ok" "$out"
  out=$(run_block CLAUDE_AUTH_WAIT_SECS=6 "${AS_SEAT[@]}")
  [[ "$out" == *SEED_FAILED* && "$out" =~ took=[01]($|[^0-9]) ]] && ok_t "T8 unreadable login + no env token -> degraded at once, not after the wait" || bad_t "T8 env empty" "$out"
  chmod 644 "$TMP/auth/anthropic.env"
else
  printf 'skip - T8 unreadable arms need a non-root uid or setpriv\n'
fi
out=$(run_block CLAUDE_AUTH_WAIT_SECS=6)
[[ "$out" == *SEED_OK* && "$out" =~ took=[01]($|[^0-9]) ]] && ok_t "T8 readable login (admin seat) -> unchanged path" || bad_t "T8 readable" "$out"
rm -f "$TMP/auth/anthropic.env"
out=$(run_block CLAUDE_CODE_OAUTH_TOKEN=from-systemd CLAUDE_AUTH_WAIT_SECS=2)
[[ "$out" == *SEED_FAILED* && "$out" =~ took=[23] ]] && ok_t "T8 absent login in a readable dir -> still waits for it (first-boot race kept)" || bad_t "T8 absent waits" "$out"

# --- T10: account logins -----------------------------------------------------
P="$AUTH_PROFILES_DIR"
for p in p1 p2; do
  mkdir -p "$P/$p"; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$p" > "$P/$p/combined.env"
  chmod 640 "$P/$p/combined.env"; printf '%s\tclaude\n' "$P/$p/combined.env" >> "$OS/fgroup"
done
ln -s "$P/p1/combined.env" "$ENV_DIR/seat_a-auth.env"
ln -s "$P/p1/combined.env" "$ENV_DIR/seat_b-auth.env"
ln -s "$P/p2/combined.env" "$ENV_DIR/x-auth.env"
ln -s "$P/p1/combined.env" "$ENV_DIR/gone-auth.env"        # a seat with no account
printf 'AGENT_NAME=seat_a\n' > "$ENV_DIR/seat_a.env"; printf '%s\tclaude\n' "$ENV_DIR/seat_a.env" >> "$OS/fgroup"
printf 'u:agent-old:r\n' | sed "s#^#$P/p1/combined.env\t#" >> "$OS/acl"   # left by a seat that moved off
printf '%s\t%s\n' "$P/p1/combined.env" "u:4242:r" >> "$OS/acl"            # left by a deleted seat
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1); rc=$?
for p in p1 p2; do
  [[ "$(_sp_file_group "$P/$p/combined.env")" == claude-keys ]] && ok_t "T10 $p/combined.env -> claude-keys" || bad_t "T10 $p group" "$(_sp_file_group "$P/$p/combined.env")"
done
[[ "$(acl_of "$P/p1/combined.env")" == "u:agent-seat_a:r u:agent-seat_b:r u:claude:r " ]] \
  && ok_t "T10 p1: only its two bound seats + claude; stale and deleted-seat readers dropped" || bad_t "T10 p1 ACL" "$(acl_of "$P/p1/combined.env")"
[[ "$(acl_of "$P/p2/combined.env")" == "u:agent-x:r u:claude:r " ]] \
  && ok_t "T10 p2: only seat x + claude" || bad_t "T10 p2 ACL" "$(acl_of "$P/p2/combined.env")"
[[ "$(_sp_file_group "$ENV_DIR/seat_a.env")" == claude && -z "$(acl_of "$ENV_DIR/seat_a.env")" ]] \
  && ok_t "T10 agents.d/<x>.env (metadata, no key) is left alone" || bad_t "T10 agents.d touched"
[[ $rc -eq 0 && "$out" == *"2 file(s) moved"*"login reader(s) changed"* ]] && ok_t "T10 summary names the move" || bad_t "T10 summary" "rc=$rc $out"
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ -z "$out" ]] && ok_t "T10 second --quiet pass: nothing to say" || bad_t "T10 idempotent" "$out"
ln -sfn "$P/p2/combined.env" "$ENV_DIR/seat_b-auth.env"      # seat_b moved to p2 by hand
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ "$(acl_of "$P/p1/combined.env")" == "u:agent-seat_a:r u:claude:r " && "$(acl_of "$P/p2/combined.env")" == "u:agent-seat_b:r u:agent-x:r u:claude:r " \
   && "$out" == *"2 login reader(s) changed"* ]] \
  && ok_t "T10 a seat moved to another account: its read follows on the next tick" || bad_t "T10 rebind tick" "$out | p1=$(acl_of "$P/p1/combined.env") p2=$(acl_of "$P/p2/combined.env")"
link_agent_profile seat_b p1
[[ "$(acl_of "$P/p1/combined.env")" == "u:agent-seat_a:r u:agent-seat_b:r u:claude:r " && "$(acl_of "$P/p2/combined.env")" == "u:agent-x:r u:claude:r " ]] \
  && ok_t "T10 link_agent_profile moves the read at once (old login dropped, new granted)" || bad_t "T10 link" "p1=$(acl_of "$P/p1/combined.env") p2=$(acl_of "$P/p2/combined.env")"
# The profile writer: a fresh account and a rewrite (the rename drops ACLs).
source src/cmd_auth.sh
chown() { :; }; require_root() { :; }
ln -s "$P/p3/combined.env" "$ENV_DIR/x-auth.env.new"; mv -T "$ENV_DIR/x-auth.env.new" "$ENV_DIR/x-auth.env"
printf 'k1' | profile_set_var p3 ANTHROPIC_API_KEY
[[ "$(_sp_file_group "$P/p3/combined.env")" == claude-keys && "$(stat -c %a "$P/p3/combined.env")" == 640 \
   && "$(acl_of "$P/p3/combined.env")" == "u:agent-x:r u:claude:r " ]] \
  && ok_t "T10 profile_set_var: a new login is 640 claude-keys, read by claude + its bound seat only" || bad_t "T10 writer" "$(_sp_file_group "$P/p3/combined.env") $(stat -c %a "$P/p3/combined.env") $(acl_of "$P/p3/combined.env")"
grep -v "^$P/p3/combined.env"$'\t' "$OS/acl" > "$OS/acl.tmp"; mv "$OS/acl.tmp" "$OS/acl"   # a rename forgets the ACL
printf 'k2' | profile_set_var p3 ANTHROPIC_API_KEY
[[ "$(acl_of "$P/p3/combined.env")" == "u:agent-x:r u:claude:r " && "$(grep -c '^ANTHROPIC_API_KEY=k2$' "$P/p3/combined.env")" == 1 ]] \
  && ok_t "T10 profile_set_var rewrite: readers restored after the rename" || bad_t "T10 rewrite" "$(acl_of "$P/p3/combined.env")"
unset -f chown require_root

# --- T11: a host with no claude group (CI runner, fresh container) ------------
# secrets_group falls back to `claude` when claude-keys cannot be created; with
# THAT group missing too, a key write must still succeed (pre-DIVE-5690 it did),
# keep the file's group, and still drop the world bits.
mv "$OS/groups/claude-keys" "$OS/claude-keys.saved"
C11="$TMP/c11"; mkdir -p "$C11"
fg_before=$(wc -l < "$OS/fgroup")
out=$(FAKE_GROUPADD_FAILS=1 CONNECTORS_DIR="$C11" _write_connector openrouter.env <<<'OPENROUTER_API_KEY=k' 2>&1); rc=$?
[[ $rc -eq 0 && "$(cat "$C11/openrouter.env" 2>/dev/null)" == OPENROUTER_API_KEY=k ]] \
  && ok_t "T11 no claude group: the connector write still succeeds" || bad_t "T11 write failed" "rc=$rc $out"
[[ "$(wc -l < "$OS/fgroup")" == "$fg_before" ]] && ok_t "T11 no chgrp to a group that does not exist" || bad_t "T11 chgrp attempted" "$(tail -1 "$OS/fgroup")"
[[ "$(stat -c %a "$C11/openrouter.env")" == 640 ]] && ok_t "T11 the key is still 640 (no world bits)" || bad_t "T11 mode" "$(stat -c %a "$C11/openrouter.env")"
printf 'K=v\n' > "$C11/w.env"; chmod 644 "$C11/w.env"
FAKE_GROUPADD_FAILS=1 secret_file_secure "$C11/w.env"; rc=$?
[[ $rc -eq 0 && "$(stat -c %a "$C11/w.env")" == 640 ]] && ok_t "T11 secret_file_secure: rc 0 and o-rwx with no group to move to" || bad_t "T11 secure" "rc=$rc mode=$(stat -c %a "$C11/w.env")"
mv "$OS/claude-keys.saved" "$OS/groups/claude-keys"

# --- T12: the group exists but chgrp is refused (non-root, not a member) -----
# An installed-host leg: claude-keys exists, the caller is not root and not in
# it. The write must still succeed, quietly (a caller parses its --json), keep
# the file's group for the root reconcile to move, and still drop world bits.
C12="$TMP/c12"; mkdir -p "$C12"
fg_before=$(wc -l < "$OS/fgroup")
out=$(FAKE_CHGRP_REFUSED=1 CONNECTORS_DIR="$C12" _write_connector openrouter.env <<<'OPENROUTER_API_KEY=k' 2>&1); rc=$?
[[ $rc -eq 0 && "$(cat "$C12/openrouter.env" 2>/dev/null)" == OPENROUTER_API_KEY=k ]] \
  && ok_t "T12 group exists, chgrp refused: the connector write still succeeds" || bad_t "T12 write failed" "rc=$rc $out"
[[ -z "$out" ]] && ok_t "T12 the refused chgrp prints nothing" || bad_t "T12 noise" "$out"
[[ "$(wc -l < "$OS/fgroup")" == "$fg_before" && "$(stat -c %a "$C12/openrouter.env")" == 640 ]] \
  && ok_t "T12 the key keeps its group and stays 640 (no world bits)" || bad_t "T12 state" "mode=$(stat -c %a "$C12/openrouter.env") $(tail -1 "$OS/fgroup")"
printf 'K=v\n' > "$C12/w.env"; chmod 644 "$C12/w.env"
FAKE_CHGRP_REFUSED=1 secret_file_secure "$C12/w.env" 2>/dev/null; rc=$?
[[ $rc -eq 0 && "$(stat -c %a "$C12/w.env")" == 640 ]] && ok_t "T12 secret_file_secure: rc 0 and o-rwx when chgrp is refused" || bad_t "T12 secure" "rc=$rc mode=$(stat -c %a "$C12/w.env")"

# --- T13: vendor CLI logins inside an account (DIVE-5701) ---------------------
# acme/codex/auth.json is read by the codex seat bound to acme and nobody else:
# not a claude seat on acme, not a codex seat on another account. The canonical
# codex/codex/auth.json is read by the seat bound to it AND by every unbound
# codex seat (DIVE-1322). A backup beside a login is a key with no seat reader.
printf 'agent-cx_bound\nagent-cx_free\nagent-cx_canon\nagent-cx_other\nagent-cl_acme\nagent-hm\nagent-oc\nagent-cx_new\n' >> "$OS/users"
cred() {   # cred <path> [mode]: a real file, group claude in the fake OS
  mkdir -p "$(dirname "$1")"; printf 'TOKEN\n' > "$1"; chmod "${2:-640}" "$1"; printf '%s\tclaude\n' "$1" >> "$OS/fgroup"
}
seat_env() { printf 'AGENT_NAME=%s\nAGENT_TYPE=%s\n' "$1" "$2" > "$ENV_DIR/$1.env"; [[ -z "${3:-}" ]] || printf 'AGENT_AUTH_PROFILE=%s\n' "$3" >> "$ENV_DIR/$1.env"; }
OC=.openclaw/agents/main/agent
cred "$P/acme/codex/auth.json"; cred "$P/acme/codex/auth.json.bak-20260101T000000Z"
cred "$P/codex/codex/auth.json"; cred "$P/p2/codex/auth.json"
cred "$P/acme/hermes/auth.json"; cred "$P/acme/hermes/config.yaml"
cred "$P/acme/openclaw/$OC/openclaw-agent.sqlite"; cred "$P/acme/openclaw/$OC/openclaw-agent.sqlite-wal"
cred "$P/acme/grok/.grok/auth.json" 600                      # never normalized: gains no reader
cred "$P/acme/claude/.claude.json"                           # the claude type is out of scope
seat_env cx_bound codex acme; seat_env cx_free codex; seat_env cx_canon codex codex
seat_env cx_other codex p2;   seat_env cl_acme claude acme; seat_env hm hermes acme; seat_env oc openclaw acme
printf '%s\tu:agent-old:r\n' "$P/acme/codex/auth.json" >> "$OS/acl"   # left by a seat that moved off
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1); rc=$?
[[ "$(_sp_file_group "$P/acme/codex/auth.json")" == claude-keys && "$(acl_of "$P/acme/codex/auth.json")" == "u:agent-cx_bound:r u:claude:r " ]] \
  && ok_t "T13 acme/codex/auth.json: claude-keys, read by its bound codex seat + claude only (claude seat on acme, codex seat on p2, stale reader: none)" \
  || bad_t "T13 acme codex" "$(_sp_file_group "$P/acme/codex/auth.json") $(acl_of "$P/acme/codex/auth.json")"
[[ "$(_sp_file_group "$P/codex/codex/auth.json")" == claude-keys && "$(acl_of "$P/codex/codex/auth.json")" == "u:agent-cx_canon:r u:agent-cx_free:r u:claude:r " ]] \
  && ok_t "T13 canonical codex/codex/auth.json: its bound seat + the UNBOUND codex seat (DIVE-1322), not cx_bound or cx_other" \
  || bad_t "T13 canonical" "$(_sp_file_group "$P/codex/codex/auth.json") $(acl_of "$P/codex/codex/auth.json")"
[[ "$(acl_of "$P/p2/codex/auth.json")" == "u:agent-cx_other:r u:claude:r " ]] && ok_t "T13 p2/codex/auth.json: only its own codex seat" || bad_t "T13 p2" "$(acl_of "$P/p2/codex/auth.json")"
b="$P/acme/codex/auth.json.bak-20260101T000000Z"
[[ "$(_sp_file_group "$b")" == claude-keys && "$(acl_of "$b")" == "u:claude:r " ]] \
  && ok_t "T13 a hand-made auth.json.bak-<ts> beside the login: claude-keys, no seat reader" || bad_t "T13 backup" "$(_sp_file_group "$b") $(acl_of "$b")"
for f in hermes/auth.json hermes/config.yaml; do
  [[ "$(_sp_file_group "$P/acme/$f")" == claude-keys && "$(acl_of "$P/acme/$f")" == "u:agent-hm:r u:claude:r " ]] \
    && ok_t "T13 acme/$f: the hermes seat on acme only" || bad_t "T13 $f" "$(_sp_file_group "$P/acme/$f") $(acl_of "$P/acme/$f")"
done
for f in openclaw-agent.sqlite openclaw-agent.sqlite-wal; do
  [[ "$(_sp_file_group "$P/acme/openclaw/$OC/$f")" == claude-keys && "$(acl_of "$P/acme/openclaw/$OC/$f")" == "u:agent-oc:r u:claude:r " ]] \
    && ok_t "T13 openclaw $f (a seed, not a backup): the openclaw seat on acme" || bad_t "T13 oc $f" "$(acl_of "$P/acme/openclaw/$OC/$f")"
done
[[ "$(_sp_file_group "$P/acme/grok/.grok/auth.json")" == claude-keys && -z "$(acl_of "$P/acme/grok/.grok/auth.json")" ]] \
  && ok_t "T13 a 600 vendor login moves group and gains no reader" || bad_t "T13 grok 600" "$(acl_of "$P/acme/grok/.grok/auth.json")"
[[ "$(_sp_file_group "$P/acme/claude/.claude.json")" == claude && -z "$(acl_of "$P/acme/claude/.claude.json")" ]] \
  && ok_t "T13 the claude type's dir is not touched" || bad_t "T13 claude touched"
[[ $rc -eq 0 && "$out" == *"file(s) moved"*"login reader(s) changed"* ]] && ok_t "T13 summary names the move" || bad_t "T13 summary" "rc=$rc $out"
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ -z "$out" ]] && ok_t "T13 second --quiet pass: nothing to say" || bad_t "T13 idempotent" "$out"
seat_env cx_free codex acme                                  # the unbound seat is bound to acme
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ "$(acl_of "$P/codex/codex/auth.json")" == "u:agent-cx_canon:r u:claude:r " \
   && "$(acl_of "$P/acme/codex/auth.json")" == "u:agent-cx_bound:r u:agent-cx_free:r u:claude:r " ]] \
  && ok_t "T13 an unbound codex seat bound to acme: loses the canonical login, gains acme's, on the next tick" \
  || bad_t "T13 rebind" "canon=$(acl_of "$P/codex/codex/auth.json") acme=$(acl_of "$P/acme/codex/auth.json")"
seat_env cx_new codex
link_agent_profile cx_new ""
[[ "$(acl_of "$P/codex/codex/auth.json")" == "u:agent-cx_canon:r u:agent-cx_new:r u:claude:r " ]] \
  && ok_t "T13 link_agent_profile for a new unbound codex seat grants the canonical login at once (first boot seeds)" \
  || bad_t "T13 link unbound" "$(acl_of "$P/codex/codex/auth.json")"
seat_env cx_new codex acme; cred "$P/acme/combined.env"
link_agent_profile cx_new acme
[[ "$(acl_of "$P/codex/codex/auth.json")" == "u:agent-cx_canon:r u:claude:r " && "$(acl_of "$P/acme/codex/auth.json")" == *u:agent-cx_new:r* ]] \
  && ok_t "T13 link_agent_profile binding that seat to acme drops its canonical read at once and grants acme's" \
  || bad_t "T13 link bind" "canon=$(acl_of "$P/codex/codex/auth.json") acme=$(acl_of "$P/acme/codex/auth.json")"
# A re-login writes a fresh 0600 file in group claude (the setgid dir); the
# normalizer that makes it 0640 must leave it closed, not open to every seat.
source src/cmd_auth.sh
f="$P/acme/codex/auth.json"; grep -v "^$f"$'\t' "$OS/acl" > "$OS/acl.tmp"; mv "$OS/acl.tmp" "$OS/acl"
chmod 600 "$f"; printf '%s\tclaude\n' "$f" >> "$OS/fgroup"
normalize_profile_seed_perms acme; rc=$?
[[ $rc -eq 0 && "$(stat -c %a "$f")" == 640 && "$(_sp_file_group "$f")" == claude-keys \
   && "$(acl_of "$f")" == "u:agent-cx_bound:r u:agent-cx_free:r u:agent-cx_new:r u:claude:r " ]] \
  && ok_t "T13 normalize_profile_seed_perms after a re-login: 640, claude-keys, bound seats only" \
  || bad_t "T13 normalize" "rc=$rc $(stat -c %a "$f") $(_sp_file_group "$f") $(acl_of "$f")"
# Drift: every seed path is one 5dive-agent-start copies and, where cmd_auth
# names a credential path for the type, that path is in the seed list.
drift=""
for t in $SP_CRED_TYPES; do
  path=$(profile_type_auth_path acme "$t") && { grep -qxF "${path#"$P/acme/$t/"}" < <(_sp_cred_seeds "$t") || drift+=" $t:auth-path"; }
  while IFS= read -r rel; do
    grep -qF "${rel##*/}" 5dive-agent-start || drift+=" $t:$rel"
  done < <(_sp_cred_seeds "$t")
done
[[ -z "$drift" ]] && ok_t "T13 the seed list matches profile_type_auth_path and 5dive-agent-start's seed blocks" || bad_t "T13 seed list drift" "$drift"
rm -f "$ENV_DIR"/cx_*.env "$ENV_DIR"/cl_acme.env "$ENV_DIR"/hm.env "$ENV_DIR"/oc.env

# --- T14: the default (no-account) vendor logins (DIVE-5714) ----------------
# /home/claude/.hermes/auth.json and config.yaml are read by the hermes seats on
# no account and nobody else. A file in that home that is not a seed is left
# alone; the codex default is a symlink to the canonical account and is never
# followed.
H="$FIVEDIVE_DEFAULT_CRED_HOME"
printf 'agent-hm_free\nagent-hm_acme\nagent-cx_free2\nagent-hm_new\n' >> "$OS/users"
cred "$H/.hermes/auth.json"; cred "$H/.hermes/config.yaml"; cred "$H/.hermes/auth.json.bak-20260101T000000Z"
cred "$H/.hermes/.env" 600; cred "$H/.hermes/memories/notes.md"
cred "$H/.grok/auth.json"
mkdir -p "$H/.codex"; ln -s "$P/codex/codex/auth.json" "$H/.codex/auth.json"
seat_env hm_free hermes; seat_env hm_acme hermes acme; seat_env cx_free2 codex
canon_before=$(acl_of "$P/codex/codex/auth.json")
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1); rc=$?
for f in .hermes/auth.json .hermes/config.yaml; do
  [[ "$(_sp_file_group "$H/$f")" == claude-keys && "$(acl_of "$H/$f")" == "u:agent-hm_free:r u:claude:r " ]] \
    && ok_t "T14 /home/claude/$f: claude-keys, read by the hermes seat on no account + claude only" \
    || bad_t "T14 $f" "$(_sp_file_group "$H/$f") $(acl_of "$H/$f")"
done
b="$H/.hermes/auth.json.bak-20260101T000000Z"
[[ "$(_sp_file_group "$b")" == claude-keys && "$(acl_of "$b")" == "u:claude:r " ]] \
  && ok_t "T14 a backup beside the default login: claude-keys, no seat reader" || bad_t "T14 backup" "$(_sp_file_group "$b") $(acl_of "$b")"
[[ "$(_sp_file_group "$H/.hermes/.env")" == claude && -z "$(acl_of "$H/.hermes/.env")" \
   && "$(_sp_file_group "$H/.hermes/memories/notes.md")" == claude ]] \
  && ok_t "T14 files in the home that are not seeds are left alone" || bad_t "T14 non-seed touched"
[[ "$(acl_of "$H/.grok/auth.json")" == "u:claude:r " ]] \
  && ok_t "T14 the default grok login: no seat reader when no grok seat is on no account" || bad_t "T14 grok" "$(acl_of "$H/.grok/auth.json")"
[[ -z "$(_sp_file_group "$H/.codex/auth.json")" && -z "$(acl_of "$H/.codex/auth.json")" \
   && "$(acl_of "$P/codex/codex/auth.json")" == *u:agent-cx_free2:r* ]] \
  && ok_t "T14 the codex default symlink is not followed; the canonical login it points at keeps its own readers" \
  || bad_t "T14 codex symlink" "link=$(acl_of "$H/.codex/auth.json") canon=$(acl_of "$P/codex/codex/auth.json") before=$canon_before"
[[ $rc -eq 0 && "$out" == *"file(s) moved"* ]] && ok_t "T14 summary names the move" || bad_t "T14 summary" "rc=$rc $out"
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ -z "$out" ]] && ok_t "T14 second --quiet pass: nothing to say" || bad_t "T14 idempotent" "$out"
seat_env hm_free hermes acme
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ "$(acl_of "$H/.hermes/auth.json")" == "u:claude:r " ]] \
  && ok_t "T14 the hermes seat bound to an account loses the default login on the next tick" || bad_t "T14 rebind" "$(acl_of "$H/.hermes/auth.json")"
seat_env hm_new hermes
link_agent_profile hm_new ""
[[ "$(acl_of "$H/.hermes/auth.json")" == "u:agent-hm_new:r u:claude:r " ]] \
  && ok_t "T14 link_agent_profile for a new hermes seat on no account grants the default login at once" || bad_t "T14 link" "$(acl_of "$H/.hermes/auth.json")"
# Drift: each default sentinel cmd_auth names (TYPE_AUTH) is a seed under the
# default dir, so the posture covers the file the box treats as the login.
drift=""
for t in $SP_CRED_TYPES; do
  [[ -n "${TYPE_AUTH[$t]:-}" ]] || { drift+=" $t:no-TYPE_AUTH"; continue; }
  sent="${TYPE_AUTH[$t]/#\/home\/claude/$H}"
  grep -qxF "$sent" < <(_sp_cred_seeds "$t" | sed "s#^#$(_sp_default_cred_dir "$t")/#") || drift+=" $t:${TYPE_AUTH[$t]}"
done
[[ -z "$drift" ]] && ok_t "T14 every default login TYPE_AUTH names is in the default seed list" || bad_t "T14 default drift" "$drift"
rm -f "$ENV_DIR"/hm_*.env "$ENV_DIR"/cx_free2.env "$ENV_DIR"/hm_new-auth.env

# --- T9: AS ROOT, real files, a real group, a real non-member uid -------------
if (( EUID == 0 )) && command -v groupadd >/dev/null && command -v setpriv >/dev/null; then
  suf=$$; WS="sp-ws-$suf"; KG="sp-keys-$suf"; REAL_GROUPS="$WS $KG"
  groupadd "$WS"; wsgid=$(getent group "$WS" | cut -d: -f3)
  R="$TMP/real"; mkdir -p "$R/connectors"; chgrp "$WS" "$R" "$R/connectors"; chmod 750 "$R" "$R/connectors"; chmod 755 "$TMP"
  for n in anthropic.env openrouter.env telegram-seat_a.env tools.sh; do
    printf 'SECRET=%s\n' "$n" > "$R/connectors/$n"; chgrp "$WS" "$R/connectors/$n"; chmod 640 "$R/connectors/$n"
  done
  printf 'CONNECTORD_TOKEN=t\n' > "$R/connectord.env"; chgrp "$WS" "$R/connectord.env"; chmod 640 "$R/connectord.env"
  # An account login bound to one real seat account; the 65534 seat is not bound.
  BOUND="agent-sp$suf"; REAL_USERS="$BOUND"
  useradd -r -M -N -g "$WS" -s /usr/sbin/nologin "$BOUND" 2>/dev/null
  S="$R/state"; mkdir -p "$S/auth-profiles/acct" "$S/agents.d"
  chgrp "$WS" "$S" "$S/auth-profiles" "$S/auth-profiles/acct" "$S/agents.d"; chmod 2750 "$S" "$S/auth-profiles" "$S/auth-profiles/acct" "$S/agents.d"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=login\n' > "$S/auth-profiles/acct/combined.env"; chgrp "$WS" "$S/auth-profiles/acct/combined.env"; chmod 640 "$S/auth-profiles/acct/combined.env"
  ln -s "$S/auth-profiles/acct/combined.env" "$S/agents.d/${BOUND#agent-}-auth.env"
  # DIVE-5701: the same seat is a codex seat on acct; FREE is a codex seat on no
  # account, which seeds from the canonical codex/codex/auth.json.
  FREE="agent-spf$suf"; HERM="agent-sph$suf"; REAL_USERS="$BOUND $FREE $HERM"
  useradd -r -M -N -g "$WS" -s /usr/sbin/nologin "$FREE" 2>/dev/null
  # DIVE-5714: HERM is a hermes seat on no account; it seeds /home/claude/.hermes.
  useradd -r -M -N -g "$WS" -s /usr/sbin/nologin "$HERM" 2>/dev/null
  printf 'AGENT_TYPE=hermes\n' > "$S/agents.d/${HERM#agent-}.env"
  HC="$R/home-claude"; mkdir -p "$HC/.hermes"; chgrp "$WS" "$HC" "$HC/.hermes"; chmod 750 "$HC"; chmod 2775 "$HC/.hermes"
  for n in auth.json config.yaml; do
    printf 'HERMES=%s\n' "$n" > "$HC/.hermes/$n"; chgrp "$WS" "$HC/.hermes/$n"; chmod 640 "$HC/.hermes/$n"
  done
  printf 'AGENT_TYPE=codex\nAGENT_AUTH_PROFILE=acct\n' > "$S/agents.d/${BOUND#agent-}.env"
  printf 'AGENT_TYPE=codex\n' > "$S/agents.d/${FREE#agent-}.env"
  for a in acct codex; do
    mkdir -p "$S/auth-profiles/$a/codex"; chgrp "$WS" "$S/auth-profiles/$a" "$S/auth-profiles/$a/codex"; chmod 2750 "$S/auth-profiles/$a" "$S/auth-profiles/$a/codex"
    printf '{"auth_mode":"chatgpt","who":"%s"}\n' "$a" > "$S/auth-profiles/$a/codex/auth.json"
    chgrp "$WS" "$S/auth-profiles/$a/codex/auth.json"; chmod 640 "$S/auth-profiles/$a/codex/auth.json"
  done
  # FIVEDIVE_CONNECTOR_DIR, not CONNECTORS_DIR: header.sh derives CONNECTORS_DIR
  # from it, so a CONNECTORS_DIR passed in is overwritten and the reconcile walks
  # /etc/5dive/connectors instead (the first root-arms run did exactly that and
  # read as three keys left readable). The guard refuses to reconcile unless every
  # path it would walk is inside this fixture, so T9 can never touch a real box.
  out=$(STATE_DIR="$S" AGENT_SHARED_GROUP="$WS" FIVEDIVE_SECRETS_GROUP="$KG" FIVEDIVE_CONNECTOR_DIR="$R/connectors" FIVEDIVE_CONNECTORD_ENV="$R/connectord.env" \
    FIVEDIVE_DEFAULT_CRED_HOME="$HC" \
    bash -c 'source src/header.sh; source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
             for p in "$(_sp_connectors_dir)" "$(_sp_connectord_env)" "$(_sp_profiles_dir)" "$(_sp_env_dir)" "$(_sp_default_home)"; do
               [[ "$p" == "$1"/* ]] || { echo "OUTSIDE-FIXTURE $p"; exit 3; }
             done
             secrets_posture_reconcile "{\"agents\":{}}" >/dev/null 2>&1; echo "RECONCILED rc=$?"' fixture "$R" 2>&1)
  [[ "$out" == "RECONCILED rc=0" ]] && ok_t "T9 the reconcile ran on the fixture's own paths, rc 0" || bad_t "T9 reconcile did not run on the fixture" "$out"
  moved=""
  for f in connectors/anthropic.env connectors/openrouter.env connectors/telegram-seat_a.env connectord.env; do
    [[ "$(stat -c %G "$R/$f")" == "$KG" ]] || moved+=" $f:$(stat -c %G "$R/$f")"
  done
  [[ -z "$moved" ]] && ok_t "T9 every key file is in $KG on disk" || bad_t "T9 key files not moved" "$moved"
  seat() { setpriv --reuid=65534 --regid="$wsgid" --clear-groups bash -c "$1" 2>&1; }
  for f in connectors/anthropic.env connectors/openrouter.env connectors/telegram-seat_a.env connectord.env; do
    out=$(seat "cat '$R/$f'")
    [[ "$out" == *"Permission denied"* ]] && ok_t "T9 a workspace-group seat outside $KG: cat $f refused" || bad_t "T9 $f readable" "$out"
  done
  out=$(seat "cat '$R/connectors/tools.sh'")
  [[ "$out" == "SECRET=tools.sh" ]] && ok_t "T9 the same seat still reads tools.sh" || bad_t "T9 tools.sh" "$out"
  out=$(setpriv --reuid=65534 --regid="$wsgid" --groups="$(getent group "$KG" | cut -d: -f3)" bash -c "cat '$R/connectord.env'" 2>/dev/null)
  [[ "$out" == "CONNECTORD_TOKEN=t" ]] && ok_t "T9 a $KG member (admin seat) still reads the box identity" || bad_t "T9 member read" "$out"
  out=$(seat "cat '$S/auth-profiles/acct/combined.env'")
  [[ "$out" == *"Permission denied"* ]] && ok_t "T9 an unbound workspace-group seat: cat of an account login refused" || bad_t "T9 login readable" "$out"
  if id -u "$BOUND" >/dev/null 2>&1 && command -v setfacl >/dev/null; then
    out=$(setpriv --reuid="$(id -u "$BOUND")" --regid="$wsgid" --clear-groups bash -c "cat '$S/agents.d/${BOUND#agent-}-auth.env'" 2>&1)
    [[ "$out" == "CLAUDE_CODE_OAUTH_TOKEN=login" ]] && ok_t "T9 the seat bound to that login still reads it through its -auth.env link" || bad_t "T9 bound seat refused" "$out"
  else
    bad_t "T9 bound-seat arm could not run (useradd or setfacl missing)"
  fi
  # DIVE-5701, the row's acceptance shape: the codex login inside an account.
  for a in acct codex; do
    out=$(seat "cat '$S/auth-profiles/$a/codex/auth.json'")
    [[ "$out" == *"Permission denied"* ]] && ok_t "T9 an unbound non-codex seat: cat $a/codex/auth.json refused" || bad_t "T9 $a codex login readable" "$out"
  done
  # The bound and the unbound codex seat seed through 5dive-agent-start's own
  # codex block, run as their real uid with a plain read (no sudo).
  CBLOCK=$(awk '/^  AGENT_CODEX_HOME="\$HOME\/.codex"$/ {on=1} /^  # Set <key> = true under \[features\]/ {exit} on' 5dive-agent-start)
  CBLOCK=${CBLOCK//\/var\/lib\/5dive\/auth-profiles/$S/auth-profiles}
  # The block's legacy fallback is /home/claude/.codex/auth.json, a symlink to
  # the host's own canonical login: point it into the fixture, never the host.
  CBLOCK=${CBLOCK//\/home\/claude\/.codex/$S/legacy-codex}
  { printf 'cred_seed_ok() { echo SEED_OK; }; cred_seed_failed() { echo "SEED_FAILED $1"; }\n'
    printf 'cred_src_readable() { [[ -r "$1" ]]; }; cred_seed_why() { echo why; }\n'
    printf '%s\n' "$CBLOCK"
    printf 'cat "$LOCAL_AUTH"\n'
  } > "$TMP/codex-seed.sh"; chmod 644 "$TMP/codex-seed.sh"
  seed_as() {   # seed_as <user> <PROFILE_STATE_DIR or empty>
    local h="$TMP/home-$1"; install -d -m 700 -o "$1" -g "$WS" "$h"
    HOME="$h" PROFILE_STATE_DIR="$2" setpriv --reuid="$(id -u "$1")" --regid="$wsgid" --clear-groups bash "$TMP/codex-seed.sh" 2>&1
  }
  if id -u "$BOUND" >/dev/null 2>&1 && id -u "$FREE" >/dev/null 2>&1 && command -v setfacl >/dev/null \
     && [[ "$CBLOCK" == *SHARED_AUTH* && "$CBLOCK" != */home/claude/* && "$CBLOCK" != */var/lib/5dive/* ]]; then
    out=$(seed_as "$BOUND" "$S/auth-profiles/acct/codex")
    [[ "$out" == *SEED_OK*'"who":"acct"'* ]] && ok_t "T9 the codex seat bound to acct seeds its login through the real start block" || bad_t "T9 bound codex seed" "$out"
    out=$(seed_as "$FREE" "")
    [[ "$out" == *SEED_OK*'"who":"codex"'* ]] && ok_t "T9 an unbound codex seat seeds the canonical codex login (DIVE-1322)" || bad_t "T9 unbound codex seed" "$out"
    out=$(setpriv --reuid="$(id -u "$FREE")" --regid="$wsgid" --clear-groups bash -c "cat '$S/auth-profiles/acct/codex/auth.json'" 2>&1)
    [[ "$out" == *"Permission denied"* ]] && ok_t "T9 the unbound codex seat cannot read acct's codex login" || bad_t "T9 unbound reads acct" "$out"
    out=$(setpriv --reuid="$(id -u "$BOUND")" --regid="$wsgid" --clear-groups bash -c "cat '$S/auth-profiles/codex/codex/auth.json'" 2>&1)
    [[ "$out" == *"Permission denied"* ]] && ok_t "T9 the seat bound to acct cannot read the canonical codex login" || bad_t "T9 bound reads canonical" "$out"
  else
    bad_t "T9 codex seed arms could not run (useradd, setfacl or the codex block extract missing)" "${CBLOCK:0:120}"
  fi
  # DIVE-5714: the default hermes login.
  for n in auth.json config.yaml; do
    out=$(seat "cat '$HC/.hermes/$n'")
    [[ "$out" == *"Permission denied"* ]] && ok_t "T9 a seat that is not a hermes seat on no account: cat default .hermes/$n refused" || bad_t "T9 default hermes $n readable" "$out"
    if id -u "$HERM" >/dev/null 2>&1; then
      out=$(setpriv --reuid="$(id -u "$HERM")" --regid="$wsgid" --clear-groups bash -c "cat '$HC/.hermes/$n'" 2>&1)
      [[ "$out" == "HERMES=$n" ]] && ok_t "T9 the hermes seat on no account still reads default .hermes/$n (its seed source)" || bad_t "T9 hermes seat refused $n" "$out"
    else
      bad_t "T9 hermes seat arm could not run (useradd)"
    fi
  done
  out=$(seat "sudo -n test -f /etc/passwd && echo ROOT")
  [[ "$out" != *ROOT* ]] && ok_t "T9 positive control: the seat uid has no root" || bad_t "T9 seat has root"
elif [[ "${SP_REQUIRE_ROOT_ARM:-}" == 1 ]]; then
  bad_t "T9 required (SP_REQUIRE_ROOT_ARM=1) but could not run" "EUID=$EUID groupadd=$(command -v groupadd) setpriv=$(command -v setpriv)"
else
  printf 'skip - T9 real-uid arm needs root, groupadd and setpriv (unit-tests.yml root-arms runs it as root)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
