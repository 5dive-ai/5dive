# shellcheck shell=bash
# tests/lib/isolate_read_tokens.sh — make `$HOME` pinning actually isolate the seat.
#
# DIVE-3888 iteration 1 (quinn's reject, 2026-09-02). Both merge-gate harnesses pinned
# `HOME=$TMP/home` and believed that put `_gate_read_tokens_file` inside the sandbox. It
# does not. That function has TWO arms:
#
#     "${HOME}/.config/5dive/gh-read-tokens.env"
#     "$(getent passwd "$(actor_caller_unix_name)" | cut -d: -f6)/.config/..."
#
# and the second walks to the CALLER'S REAL HOME whatever `$HOME` says — that is why it
# exists (under `sudo 5dive task done`, `$HOME` is root's). On a verifier seat root cron
# writes that file every 30 minutes, so the sandbox read the LIVE file and handed a real
# minted token to the stub `gh`. The harnesses were green on CI only because a runner has
# no such file: they graded a configuration no verifier is ever in.
#
# So a harness about blind credentials must neutralise BOTH arms, and it must PROVE it did
# rather than assume it — the failure mode here was silent, and on the one seat the row
# exists for it was the difference between 29/29 and 28/1.
#
# Two independent neutralisations, deliberately, because either alone is one edit away from
# being a no-op again:
#   1. `getent` is stubbed on PATH to answer nothing, so no passwd home can be resolved.
#   2. `actor_caller_unix_name` is overridden to print nothing, so no name is looked up.
# Neither touches src/. The gate keeps the second arm it needs in production.
#
# Usage, AFTER the `source "$SRC/..."` loop (the override must win over the real
# definition) and with <bindir> already on PATH:
#
#     isolate_read_tokens "$TMP/bin"
#     chk "T0 ..." "$(read_tokens_isolated_probe)" ""
#
isolate_read_tokens() { # <bindir-already-on-PATH>
  local bin="${1:?isolate_read_tokens needs the harness bin dir}"
  # Installed, not merely attempted: a harness that ran WITHOUT the stub is the exact
  # silent-green failure this file exists to end, so say what went wrong and stop.
  # shellcheck disable=SC2016  # writing a script; $1 must reach the stub, not expand here
  { printf '%s\n' '#!/usr/bin/env bash' \
      '# DIVE-3888 harness stub: answers the probe, refuses every passwd lookup.' \
      '[[ "${1:-}" == __5dive_stub_probe ]] && { printf STUBBED; exit 0; }' \
      'exit 2' >"$bin/getent" && chmod +x "$bin/getent"; } || {
    printf 'isolate_read_tokens: could not install the getent stub in %s — refusing to run\n' \
      "$bin" >&2; return 1; }
  # shellcheck disable=SC2317  # invoked indirectly, by src/'s _gate_read_tokens_file
  actor_caller_unix_name() { printf ''; }
}

# read_tokens_isolated_probe — what `_gate_read_tokens_file` resolves to when the sandbox
# HOME holds no tokens file. MUST be empty. Anything else is the real seat leaking in, and
# every "a seat with nothing" arm in the harness is then grading a seat that has something.
read_tokens_isolated_probe() {
  ( export HOME="${TMPDIR:-/tmp}/.5dive-no-such-home.$$"; _gate_read_tokens_file )
}

# read_tokens_stub_control — proves OUR `getent` is the one on PATH. It must be a POSITIVE
# control: asserting that `getent passwd root` comes back empty would also pass on a box
# with no `getent` at all, i.e. it would pass for the wrong reason on exactly the runner
# where the isolation is doing nothing. So the stub answers a private probe with a sentinel
# no real `getent` can produce, and the harness asserts the sentinel. A negative result with
# no positive control is not evidence (DIVE-3175).
read_tokens_stub_control() {
  getent __5dive_stub_probe 2>/dev/null
}

# Sibling isolators, same family, all opt-in per harness rather than blanket:
#   tests/lib/grading_tree.sh   — WHICH TREE these numbers grade (DIVE-2211)
#   tests/lib/env_isolation.sh  — WHICH ENVIRONMENT they grade (DIVE-2325)
#   this file                   — WHICH SEAT'S CREDENTIALS are reachable (DIVE-3888)
# Not folded into env_isolation.sh on purpose: this one overrides a src/ function, and a
# harness that legitimately grades `actor_caller_unix_name` must not get it by default.
