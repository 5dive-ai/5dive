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
#   * AS ROOT ONLY: the same reconcile on real files and a real group, and a
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
_sp_chgrp()        { printf '%s\t%s\n' "$2" "$1" >> "$OS/fgroup"; }
_sp_setfacl()      { printf '%s\t%s\n' "$2" "$1" >> "$OS/acl"; }
_sp_unsetfacl()    { awk -F'\t' -v f="$2" -v e="$1:" '!($1==f && index($2, e)==1)' "$OS/acl" > "$OS/acl.tmp"; mv "$OS/acl.tmp" "$OS/acl"; }
_sp_acl_users()    { awk -F'\t' -v f="$1" '$1==f {sub(/^u:/,"",$2); sub(/:r$/,"",$2); print $2}' "$OS/acl" | sort -u; }
acl_of() { awk -F'\t' -v f="$1" '$1==f {print $2}' "$OS/acl" | sort -u | tr '\n' ' '; }

C="$TMP/connectors"; mkdir -p "$C"
# Account logins live under $TMP too, so no arm ever globs the box's own.
AUTH_PROFILES_DIR="$TMP/auth-profiles" ENV_DIR="$TMP/agents.d"; mkdir -p "$AUTH_PROFILES_DIR" "$ENV_DIR"
export CONNECTORS_DIR="$C" FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
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
if can_lock; then
  chmod 000 "$TMP/auth/anthropic.env"
  out=$(run_block CLAUDE_CODE_OAUTH_TOKEN=from-systemd CLAUDE_AUTH_WAIT_SECS=6 "${AS_SEAT[@]}")
  [[ "$out" == *SEED_OK* && "$out" == *took=0* ]] && ok_t "T8 unreadable login + env token -> ok, no wait" || bad_t "T8 env ok" "$out"
  out=$(run_block CLAUDE_AUTH_WAIT_SECS=6 "${AS_SEAT[@]}")
  [[ "$out" == *SEED_FAILED* && "$out" == *took=0* ]] && ok_t "T8 unreadable login + no env token -> degraded at once, not after the wait" || bad_t "T8 env empty" "$out"
  chmod 644 "$TMP/auth/anthropic.env"
else
  printf 'skip - T8 unreadable arms need a non-root uid or setpriv\n'
fi
out=$(run_block CLAUDE_AUTH_WAIT_SECS=6)
[[ "$out" == *SEED_OK* && "$out" == *took=0* ]] && ok_t "T8 readable login (admin seat) -> unchanged path" || bad_t "T8 readable" "$out"
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
  STATE_DIR="$S" AGENT_SHARED_GROUP="$WS" FIVEDIVE_SECRETS_GROUP="$KG" CONNECTORS_DIR="$R/connectors" FIVEDIVE_CONNECTORD_ENV="$R/connectord.env" \
    bash -c 'source src/header.sh; source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
             secrets_posture_reconcile "{\"agents\":{}}"' >/dev/null 2>&1
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
  out=$(seat "sudo -n test -f /etc/passwd && echo ROOT")
  [[ "$out" != *ROOT* ]] && ok_t "T9 positive control: the seat uid has no root" || bad_t "T9 seat has root"
else
  printf 'skip - T9 real-uid arm needs root, groupadd and setpriv (CI runs it)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
