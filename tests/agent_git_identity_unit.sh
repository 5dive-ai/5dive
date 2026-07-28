#!/usr/bin/env bash
# DIVE-2051 isolated unit harness for seed_agent_git_identity: every agent user
# gets an EXPLICIT, non-personal git identity at provisioning time, so an agent
# is never one "git refuses to commit" away from resolving one itself — and the
# most available value on the box is the operator's personal email, which Claude
# Code puts in every agent's system prompt by default (anthropics/claude-code#81138).
# Drives the function with a stubbed `sudo` that reads/writes a fake per-user
# gitconfig, so no user is created and nothing on the host is touched.
# Asserts:
#   - a user with NO identity gets the synthetic one,
#   - a user who ALREADY has one is never clobbered (operator intent wins),
#   - a HALF identity is completed, not left for git to synthesize,
#   - the seeded address is non-personal and obviously synthetic.
# Run: bash tests/agent_git_identity_unit.sh   (no root, no user creation).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/agent-git-identity.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

E_GENERIC=1
warn() { echo "warn: $*" >&2; }

# Stub `sudo -u <user> -H git config --global …` onto a per-user file under TMP.
# Everything else about the real create path stays out of this harness.
sudo() {
  local user=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -u) user="$2"; shift 2 ;;
      -H) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "git" ] || return 0
  shift
  GIT_CONFIG_GLOBAL="$TMP/${user}.gitconfig" command git "$@"
}
# The function guards on `id -u <user>` existing; every user is real here.
id() { case "${1:-}" in -u) return 0 ;; *) command id "$@" ;; esac; }

# shellcheck disable=SC1091
source src/cmd_agent_create.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
cfg() { GIT_CONFIG_GLOBAL="$TMP/agent-${1}.gitconfig" command git config --global "$2" 2>/dev/null; }

# --- Case 1: no identity -> seeded -------------------------------------------
: > "$TMP/agent-fresh.gitconfig"
seed_agent_git_identity fresh
[[ -n "$(cfg fresh user.name)" && -n "$(cfg fresh user.email)" ]] \
  && ok_t "a user with no identity gets one at provisioning time" \
  || bad_t "seeded identity" "name=$(cfg fresh user.name) email=$(cfg fresh user.email)"
[[ "$(cfg fresh user.email)" == "agent-fresh@agents.noreply.5dive.ai" ]] \
  && ok_t "seeded address is synthetic, per-agent and obviously non-personal" \
  || bad_t "seeded address" "got=$(cfg fresh user.email)"
[[ "$(cfg fresh user.email)" == *"noreply"* ]] \
  && ok_t "seeded address is a noreply form" || bad_t "noreply form"

# --- Case 2: existing identity is NEVER clobbered ----------------------------
# The whole point is to remove inference, not to overwrite a deliberate choice.
: > "$TMP/agent-owned.gitconfig"
GIT_CONFIG_GLOBAL="$TMP/agent-owned.gitconfig" command git config --global user.name "operator choice"
GIT_CONFIG_GLOBAL="$TMP/agent-owned.gitconfig" command git config --global user.email "ops@example.com"
seed_agent_git_identity owned
[[ "$(cfg owned user.email)" == "ops@example.com" && "$(cfg owned user.name)" == "operator choice" ]] \
  && ok_t "an identity the operator already set is never overwritten" \
  || bad_t "clobbered operator identity" "got=$(cfg owned user.name) <$(cfg owned user.email)>"

# Re-running create on the same box must stay a no-op too.
seed_agent_git_identity owned
[[ "$(cfg owned user.email)" == "ops@example.com" ]] \
  && ok_t "re-provisioning is idempotent (still not overwritten)" || bad_t "idempotence"

# --- Case 3: a HALF identity is completed ------------------------------------
# git would otherwise fill the missing half with a synthesized user@hostname.
: > "$TMP/agent-half.gitconfig"
GIT_CONFIG_GLOBAL="$TMP/agent-half.gitconfig" command git config --global user.name "half"
seed_agent_git_identity half
[[ "$(cfg half user.name)" == "half" ]] \
  && ok_t "the half that was set is kept" || bad_t "kept half" "got=$(cfg half user.name)"
[[ "$(cfg half user.email)" == "agent-half@agents.noreply.5dive.ai" ]] \
  && ok_t "the missing half is filled rather than left to git to synthesize" \
  || bad_t "filled half" "got=$(cfg half user.email)"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
