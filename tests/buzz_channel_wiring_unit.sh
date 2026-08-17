#!/usr/bin/env bash
# DIVE-2895 unit harness for the buzz (Nostr) channel CLI wiring.
#
# Adding a channel is not one edit, it is FIVE, spread across three files, and
# four of the five fail SILENTLY when missed — the fifth (5dive-agent-start's
# dispatch) is the only one that says anything, and it says it at boot on a box
# rather than at the keystroke. Measured while wiring the first live buzz agent:
# the plugin was merged to main and installable, and `channels=buzz` was still
# rejected by valid_channel with no hint that four other sites were already
# ready. This harness grades all five together so the next channel cannot ship
# four-fifths wired.
#
#   1. valid_channel()                     accepts it            (validation.sh)
#   2. install_channel_plugin_for_agent()  routes it to the
#                                          5dive-plugins marketplace
#                                          (NOT claude-plugins-official)
#   3. install_channel_for_agent()         refuses non-claude types by name
#   4. cmd_agent_config's staging gate     knows the marketplace, so a
#                                          restart is refused into a deaf
#                                          session rather than allowed
#   5. 5dive-agent-start                   emits --channels plugin:<ch>@<mkt>
#      reconcile_managed_settings()        allowlists it (channelsEnabled)
#
# Run: bash tests/buzz_channel_wiring_unit.sh  (no root, no network, no tmux).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. valid_channel accepts buzz, alone and in a list ---------------------
valid_channel buzz            && ok_t "valid_channel buzz"                  || bad_t "valid_channel buzz"
valid_channel telegram,buzz   && ok_t "valid_channel telegram,buzz"         || bad_t "valid_channel telegram,buzz"
valid_channel buzz,dashboard  && ok_t "valid_channel buzz,dashboard"        || bad_t "valid_channel buzz,dashboard"

# Negative controls: the accept must not have widened to everything. A test that
# only asserts the new value passes just as well against `=~ .*`.
valid_channel buzzz  && bad_t "NEGATIVE: buzzz must be rejected"            || ok_t "NEGATIVE: buzzz rejected"
valid_channel bzz    && bad_t "NEGATIVE: bzz must be rejected"              || ok_t "NEGATIVE: bzz rejected"
valid_channel none,buzz && bad_t "NEGATIVE: none,buzz must be rejected"     || ok_t "NEGATIVE: none,buzz rejected (none is alone-only)"

# --- 2. marketplace routing: buzz is OURS, not upstream ---------------------
# Graded on source text rather than by calling the installer, which needs a real
# agent user, bun, and network. The predicate is one line and this asserts the
# line, plus the negative that the upstream default did not swallow it.
AS=$SRC/lib/agent_setup.sh
if grep -qE '\$plugin" == "telegram" \|\| "\$plugin" == "dashboard" \|\| "\$plugin" == "buzz"' "$AS"; then
  ok_t "install_channel_plugin_for_agent routes buzz to 5dive-plugins"
else
  bad_t "install_channel_plugin_for_agent routes buzz to 5dive-plugins" \
        "buzz missing from the marketplace predicate in $AS — it would install from claude-plugins-official, which has no buzz plugin"
fi

# --- 3. claude-only refusal names the channel -------------------------------
if grep -qE 'plugin" == "buzz" && "\$type" != "claude"' "$AS"; then
  ok_t "install_channel_for_agent refuses buzz on non-claude types"
else
  bad_t "install_channel_for_agent refuses buzz on non-claude types" \
        "no claude-only guard for buzz in $AS"
fi

# --- 4. the config staging gate knows buzz's marketplace --------------------
# Without this, channels_changed_to=buzz hits `*) continue` and the restart
# proceeds into a session whose plugin cache may not be staged — a deaf agent.
if grep -qE 'telegram\|dashboard\|buzz\) gate_marketplace="5dive-plugins"' "$SRC/cmd_agent_config.sh"; then
  ok_t "cmd_agent_config staging gate covers buzz"
else
  bad_t "cmd_agent_config staging gate covers buzz" \
        "buzz falls through to '*) continue' — restart into a possibly-deaf session is not refused"
fi

# --- 4b. THE SATISFIER, not just the gate (DIVE-3333) -----------------------
# Arm 4 above passed for months while `config set channels=<cur>,buzz` was
# UNSATISFIABLE on every seat not created with buzz. A gate that names a value
# proves the value is RECOGNISED, never that it is REACHABLE: the gate polls for
# a plugin cache dir, and nothing in cmd_config ever created one for buzz.
# cmd_create staged it (which is why the one seat created with --channels buzz
# looked fine) and cmd_config did not, so the gate refused forever and its own
# "Re-run: …" advice re-entered the identical path. Grade the dispatch that
# SATISFIES the gate, not only the gate that reads the list.
if grep -qE 'install_channel_for_agent "\$type" buzz "\$name"' "$SRC/cmd_agent_config.sh"; then
  ok_t "cmd_agent_config DISPATCHES the buzz install (satisfies the gate)"
else
  bad_t "cmd_agent_config DISPATCHES the buzz install (satisfies the gate)" \
        "no buzz install dispatch — the staging gate at arm 4 is unsatisfiable on any seat not CREATED with buzz"
fi

# --- 4c. claude-only pre-check lands BEFORE the registry write --------------
# install_channel_for_agent refuses buzz on non-claude types (arm 3), but it
# runs AFTER `registry_write`. Without a pre-loop check the refusal still leaves
# a codex/grok/pi seat declaring a channel it can never have.
if grep -qE 'channels=buzz is claude-only' "$SRC/cmd_agent_config.sh"; then
  ok_t "cmd_agent_config rejects buzz on non-claude BEFORE the registry write"
else
  bad_t "cmd_agent_config rejects buzz on non-claude BEFORE the registry write" \
        "a non-claude seat is left declaring buzz by a call that always fails"
fi

# --- 4d. BEHAVIORAL: a gate refusal ROLLS BACK the declared channel ---------
# The registry + agents.d env write commit at the top of cmd_config, hundreds of
# lines ahead of the fail-closed gate. A refusal that leaves them written does
# not prevent the deaf session, it DEFERS it: the seat boots
# `--channels plugin:buzz@5dive-plugins` on its next supervisor wake / reboot /
# `agent start` / selfupdate with no plugin staged. Drive the real function with
# an install stub that stages nothing, and assert the declared value is restored.
# Greps cannot see this — only running it can.
if command -v jq >/dev/null 2>&1; then
  RB_TMP=$(mktemp -d)
  RB_REG="$RB_TMP/agents.json"
  export RB_HOME="$RB_TMP/home"; mkdir -p "$RB_HOME"
  cat >"$RB_REG" <<'JSON'
{"agents":{"rbseat":{"type":"claude","channels":"telegram"}}}
JSON
  (
    set +e
    ENV_DIR="$RB_TMP/agents.d";        mkdir -p "$ENV_DIR"
    CONNECTORS_DIR="$RB_TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
    printf 'TELEGRAM_BOT_TOKEN=x\n' >"$CONNECTORS_DIR/telegram-rbseat.env"
    declare -A TYPE_CHANNELS=([claude]=1)
    ensure_state()  { :; }
    registry_read() { cat "$RB_REG"; }
    registry_write(){ cat >"$RB_REG"; }
    # The stub is the whole point: it stages NO plugin cache dir, so the gate
    # must refuse — exactly what a marketplace fetch failure looks like.
    install_channel_for_agent() { :; }
    # DIVE-3450 gear 0: and BECAUSE the stub above guarantees the cache dir never
    # appears, cmd_config's gate loop (src/cmd_agent_config.sh:399) is guaranteed
    # to run to its full bound — 15 x `sleep 1`. That is 15.13s of this harness's
    # 15.20s, and not one of the four assertions below runs during it; they all
    # land AFTER the wait. A negative-path arm drives a timeout ON PURPOSE, so the
    # bound stops being a worst case and becomes a fixed invoice paid on every CI
    # run forever — the tell was this file's local:CI runtime ratio of 1.01 while
    # every other harness in the tier's top 14 sat at 1.44-1.84 (compute scales
    # with the machine, a sleep does not).
    #
    # Record the polls instead of serving them. The loop still runs its full 15
    # iterations, still exits with the dir absent, and still refuses — every
    # assertion below grades exactly the state it graded before. What is gone is
    # only the dead air, and the count is now ASSERTED rather than merely endured,
    # so a gate that stopped polling (or lost its bound) is caught here instead of
    # being invisible. See
    # community/wiki/a-test-that-stubs-out-what-it-waits-for-pays-the-full-timeout-every-run.md
    sleep() { printf 'GATE_SLEEP\n'; }
    write_channel_secret() { :; }
    teardown_telegram_wiring() { :; }
    ensure_hermes_gateway() { :; }
    fetch_bot_username() { return 1; }
    write_runtime_model() { :; }
    write_runtime_effort() { :; }
    link_agent_profile() { :; }
    write_agent_env() { printf 'AGENT_CHANNELS=%s\n' "$3" >"$ENV_DIR/$1.env"; }
    step() { :; }
    ok()   { :; }
    fail() { printf 'FAILMSG:%s\n' "${2:-}"; exit "${1:-1}"; }
    systemd-run() { :; }        # never reached on the refusal path
    # shellcheck source=/dev/null
    source "$SRC/cmd_agent_config.sh"
    cmd_config rbseat set channels=telegram,buzz
  ) >"$RB_TMP/out" 2>&1
  rb_rc=$?
  rb_chan=$(jq -r '.agents.rbseat.channels' "$RB_REG" 2>/dev/null)
  rb_env=$(grep -h '^AGENT_CHANNELS=' "$RB_TMP/agents.d/rbseat.env" 2>/dev/null | cut -d= -f2-)
  [[ "$rb_rc" != "0" ]] \
    && ok_t "gate refusal is a non-zero exit (rc=$rb_rc)" \
    || bad_t "gate refusal is a non-zero exit" "rc=0 — the refusal did not fail the call"
  [[ "$rb_chan" == "telegram" ]] \
    && ok_t "gate refusal ROLLS BACK registry channels to the pre-call value" \
    || bad_t "gate refusal ROLLS BACK registry channels" \
             "registry left at '$rb_chan' (expected 'telegram') — the seat boots --channels plugin:buzz@… deaf on its next start"
  [[ "$rb_env" == "telegram" ]] \
    && ok_t "gate refusal ROLLS BACK the agents.d env file too" \
    || bad_t "gate refusal ROLLS BACK the agents.d env file" \
             "env left at '$rb_env' (expected 'telegram') — 5dive-agent-start reads THIS file"
  grep -q 'rolled back' "$RB_TMP/out" \
    && ok_t "the refusal message tells the operator the change was rolled back" \
    || bad_t "the refusal message tells the operator the change was rolled back" \
             "got: $(grep FAILMSG "$RB_TMP/out" | head -1)"
  # DIVE-3450 gear 0: the polls the stub above recorded instead of serving. Two
  # things are graded that nothing graded while this was real wall-clock: the gate
  # DOES absorb an in-flight stager rather than refusing on first look, and its
  # wait is BOUNDED. Asserting a range, not the constant, so retuning the bound is
  # not a test edit — an UNBOUNDED loop is the failure this catches, and it would
  # previously have hung CI rather than failed it.
  rb_polls=$(grep -c '^GATE_SLEEP$' "$RB_TMP/out")
  (( rb_polls >= 1 && rb_polls <= 60 )) \
    && ok_t "the staging gate polls for the cache dir and its wait is BOUNDED ($rb_polls polls)" \
    || bad_t "the staging gate polls for the cache dir and its wait is BOUNDED" \
             "$rb_polls polls — 0 means the gate refused without absorbing an in-flight stager; >60 means the bound is gone and CI pays it every run"
  # POSITIVE CONTROL on the harness itself: with a stub that DOES stage the
  # cache dir the same call must reach the restart, not the rollback. Without
  # this arm every assertion above would still pass against a cmd_config that
  # refuses unconditionally.
  cat >"$RB_REG" <<'JSON'
{"agents":{"rbseat":{"type":"claude","channels":"telegram"}}}
JSON
  (
    set +e
    ENV_DIR="$RB_TMP/agents.d"; CONNECTORS_DIR="$RB_TMP/connectors"
    declare -A TYPE_CHANNELS=([claude]=1)
    ensure_state()  { :; }
    registry_read() { cat "$RB_REG"; }
    registry_write(){ cat >"$RB_REG"; }
    install_channel_for_agent() { mkdir -p "$RB_HOME/.claude/plugins/cache/5dive-plugins/$2"; }
    write_channel_secret() { :; }; teardown_telegram_wiring() { :; }
    ensure_hermes_gateway() { :; }; fetch_bot_username() { return 1; }
    write_runtime_model() { :; }; write_runtime_effort() { :; }
    link_agent_profile() { :; }
    write_agent_env() { printf 'AGENT_CHANNELS=%s\n' "$3" >"$ENV_DIR/$1.env"; }
    step() { :; }; ok() { printf 'REACHED_OK\n'; }
    fail() { printf 'FAILMSG:%s\n' "${2:-}"; exit "${1:-1}"; }
    systemd-run() { printf 'REACHED_RESTART\n'; }
    # shellcheck source=/dev/null
    source "$SRC/cmd_agent_config.sh"
    # Point the gate's hardcoded /home/agent-<n> at the fixture tree.
    eval "$(declare -f cmd_config | sed 's#/home/agent-\${name}#$RB_HOME#')"
    cmd_config rbseat set channels=telegram,buzz
  ) >"$RB_TMP/out2" 2>&1
  if grep -q 'REACHED_RESTART' "$RB_TMP/out2"; then
    ok_t "POSITIVE CONTROL: with the cache staged the same call reaches the restart"
  else
    bad_t "POSITIVE CONTROL: with the cache staged the same call reaches the restart" \
          "never reached systemd-run — the rollback arms above may be passing against an unconditional refusal. out2: $(head -3 "$RB_TMP/out2" | tr '\n' ' ')"
  fi
  rm -rf "$RB_TMP"
else
  printf 'SKIP - rollback behavioral arms (no jq on PATH)\n'
fi

# --- 5. 5dive-agent-start emits the channel arg, claude-only ----------------
if grep -qE 'ARGS\+=\(--channels "plugin:buzz@5dive-plugins"\)' 5dive-agent-start; then
  ok_t "5dive-agent-start emits --channels plugin:buzz@5dive-plugins"
else
  bad_t "5dive-agent-start emits --channels plugin:buzz@5dive-plugins" \
        "channels=buzz would hit the 'unknown channels' arm and exit 2"
fi
if grep -qE 'channels=buzz is claude-only' 5dive-agent-start; then
  ok_t "5dive-agent-start refuses buzz on non-claude types"
else
  bad_t "5dive-agent-start refuses buzz on non-claude types"
fi

# --- 6. managed-settings reconcile allowlists buzz --------------------------
# channelsEnabled gates inbound channel pings on a personal/self-hosted box; a
# plugin absent from allowedChannelPlugins is installed, running, and ignored.
if grep -qE '\{"plugin":"buzz","marketplace":"5dive-plugins"\}' "$AS"; then
  ok_t "reconcile_managed_settings allowlists buzz@5dive-plugins"
else
  bad_t "reconcile_managed_settings allowlists buzz@5dive-plugins" \
        "existing boxes would never self-heal to allow the buzz channel"
fi

# Positive control on the reconcile jq itself: run it over a fixture that has
# only telegram, and assert buzz is ADDED and the operator's own entry is kept.
# This is the arm that would catch a syntactically-present-but-wrong jq edit —
# grep alone cannot tell a well-formed allowlist from a broken one.
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$AS" 2>/dev/null
  FIX=$(mktemp)
  cat >"$FIX" <<'JSON'
{"allowedChannelPlugins":[{"plugin":"telegram","marketplace":"5dive-plugins"},
                          {"plugin":"custom","marketplace":"operator-own"}]}
JSON
  reconcile_managed_settings "$FIX" >/dev/null 2>&1
  rc=$?
  got_buzz=$(jq -r '[.allowedChannelPlugins[] | select(.plugin=="buzz" and .marketplace=="5dive-plugins")] | length' "$FIX" 2>/dev/null)
  kept_own=$(jq -r '[.allowedChannelPlugins[] | select(.plugin=="custom")] | length' "$FIX" 2>/dev/null)
  enabled=$(jq -r '.channelsEnabled' "$FIX" 2>/dev/null)
  if [[ "$rc" == "0" && "$got_buzz" == "1" ]]; then
    ok_t "reconcile_managed_settings ADDS buzz to an existing file (rc=0)"
  else
    bad_t "reconcile_managed_settings ADDS buzz to an existing file" "rc=$rc buzz_entries=$got_buzz"
  fi
  [[ "$kept_own" == "1" ]] \
    && ok_t "reconcile_managed_settings keeps the operator's own entry" \
    || bad_t "reconcile_managed_settings keeps the operator's own entry" "custom entries=$kept_own"
  [[ "$enabled" == "true" ]] \
    && ok_t "reconcile_managed_settings sets channelsEnabled=true" \
    || bad_t "reconcile_managed_settings sets channelsEnabled=true" "got $enabled"
  # Idempotence: a second run must report already-current (3), not rewrite.
  reconcile_managed_settings "$FIX" >/dev/null 2>&1
  [[ "$?" == "3" ]] \
    && ok_t "reconcile_managed_settings is idempotent (second run = already current)" \
    || bad_t "reconcile_managed_settings is idempotent" "second run rc=$?"
  rm -f "$FIX"
else
  printf 'SKIP - reconcile jq arms (no jq on PATH)\n'
fi

# --- 7. THE SIXTH SITE: cmd_create actually INSTALLS the plugin (DIVE-3509) --
# The header above said "adding a channel is FIVE edits". It is six, and the
# sixth was missing for buzz from the day it shipped: `agent create
# --channels=buzz` recorded the channel, launched claude with
# `--channels plugin:buzz@5dive-plugins`, and NEVER FETCHED THE PLUGIN, because
# cmd_create's per-channel case has no buzz arm. Measured on a fresh box
# (sure-redwood, 2026-08-17): plugin cache held only dashboard/, no
# config.json, no `buzz` binary — and the create printed OK.
#
# Sites 1-6 above all passed the whole time. That is the point of this arm: five
# green wiring checks are exactly what a four-fifths-wired channel looks like.
CC=$SRC/cmd_agent_create.sh
if grep -qE 'install_channel_for_agent "\$type" buzz "\$name"' "$CC"; then
  ok_t "cmd_create installs the buzz plugin (the sixth site)"
else
  bad_t "cmd_create installs the buzz plugin (the sixth site)" \
        "no buzz arm in cmd_create's channel case in $CC — --channels=buzz would enable the channel and never fetch the plugin"
fi
# Negative control on the grep: the dashboard arm it is modelled on must be
# found by the same pattern shape, or the assertion above is proving nothing
# about how this file spells an install.
grep -qE 'install_channel_for_agent "\$type" dashboard "\$name"' "$CC" \
  && ok_t "CONTROL: the same pattern shape finds the dashboard arm" \
  || bad_t "CONTROL: the same pattern shape finds the dashboard arm" \
           "the pattern in the arm above cannot be trusted — it does not match a site known to exist"

# --- 8. the create self-check has a REAL buzz predicate ---------------------
# The same create printed `(ok: poller up …)` over a box with no buzz plugin at
# all, because "poller up" reads the AGENT's systemd unit. A create-time check
# that greens on the thing an operator would look at is worse than none.
if grep -q 'buzz is UNCONFIGURED' "$CC"; then
  ok_t "create self-check reports buzz UNCONFIGURED rather than 'poller up'"
else
  bad_t "create self-check reports buzz UNCONFIGURED rather than 'poller up'" \
        "no buzz predicate in the self-check — a buzz create still self-reports healthy"
fi

# --- 9. the onboarding command exists and is BUNDLED ------------------------
# A src/ file that build.sh does not concatenate is dead code that greps green.
BZ=$SRC/cmd_agent_buzz.sh
[[ -f "$BZ" ]] \
  && ok_t "src/cmd_agent_buzz.sh exists" \
  || bad_t "src/cmd_agent_buzz.sh exists" "the CLI half of buzz onboarding is missing"
grep -qE '^\s*src/cmd_agent_buzz\.sh \\$' build.sh \
  && ok_t "build.sh bundles src/cmd_agent_buzz.sh" \
  || bad_t "build.sh bundles src/cmd_agent_buzz.sh" \
           "the file is present but never concatenated — \`5dive agent buzz\` would be 'command not found' in the built bundle"
grep -qE 'cmd_agent_buzz "\$@"' "$SRC/main.sh" \
  && ok_t "main.sh dispatches \`agent buzz\`" \
  || bad_t "main.sh dispatches \`agent buzz\`" "the verb is unreachable"

# Behavioural arms on the enable path. No agent user, no network, no root: probe
# the two refusals that must fire BEFORE anything is minted or written.
if [[ -f "$BZ" ]]; then
  # shellcheck source=/dev/null
  source "$BZ" 2>/dev/null
  out=$(cmd_agent_buzz enable 2>&1); rc=$?
  [[ "$rc" != "0" && "$out" == *"usage: 5dive agent buzz enable"* ]] \
    && ok_t "enable with no agent name refuses with usage" \
    || bad_t "enable with no agent name refuses with usage" "rc=$rc out=$out"
  out=$(cmd_agent_buzz frobnicate 2>&1); rc=$?
  [[ "$rc" != "0" && "$out" == *"unknown buzz verb"* ]] \
    && ok_t "an unknown buzz verb is refused by name" \
    || bad_t "an unknown buzz verb is refused by name" "rc=$rc out=$out"
  # The relay refusal is the load-bearing one: guessing a relay is how you get a
  # channel that reports success and connects to nothing.
  grep -q 'no relay chosen' "$BZ" \
    && ok_t "enable refuses rather than guessing a relay URL" \
    || bad_t "enable refuses rather than guessing a relay URL" \
             "a defaulted relay reproduces the exact defect this row fixes"
  # The key must be minted once, not on every run — a silent rotation reads to a
  # paired handset as the agent having left the room.
  grep -q 'rotate' "$BZ" && grep -q 'Reusing the existing buzz identity' "$BZ" \
    && ok_t "enable reuses an existing identity unless --rotate-key" \
    || bad_t "enable reuses an existing identity unless --rotate-key" \
             "a re-run would rotate the key underneath a paired handset"
  # 0600, owned by the agent: the private key is the agent's alone.
  grep -q '0o600' "$BZ" \
    && ok_t "the minted config is written 0600" \
    || bad_t "the minted config is written 0600" "an agent's private key must not be group/world readable"

  # The writer, RUN — not grepped. It is factored to take a runas user so this
  # arm needs no agent user, no root and no relay: pass our own name, the sudo
  # hop is skipped, and the file it produces is graded against the contract in
  # plugins/buzz/server.ts (five fields; private_key must match /^[0-9a-f]{64}$/
  # or the plugin refuses to derive a pubkey and the channel is silently dead).
  if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    TD=$(mktemp -d)
    FAKE_KEY=$(printf 'a%.0s' {1..64})
    _buzz_write_config "$(id -un)" "$TD/buzz" "https://relay.example.com" \
      "$FAKE_KEY" "general, ops" 9000 /usr/local/bin/buzz >/dev/null 2>&1
    W="$TD/buzz/config.json"
    if [[ -f "$W" ]] && jq -e . "$W" >/dev/null 2>&1; then
      ok_t "_buzz_write_config writes parseable JSON"
      jq -e '.relay_url == "https://relay.example.com"
             and (.private_key | test("^[0-9a-fA-F]{64}$"))
             and .channels == ["general","ops"]
             and .poll_ms == 9000
             and .buzz_path == "/usr/local/bin/buzz"' "$W" >/dev/null 2>&1 \
        && ok_t "the written config matches the plugin's five-field contract" \
        || bad_t "the written config matches the plugin's five-field contract" "got: $(cat "$W")"
      # poll_ms must be a NUMBER: server.ts does Number(cfg.poll_ms) on the env
      # path but reads the file value straight, so a quoted "9000" is a config
      # the plugin loads and mis-schedules.
      [[ "$(jq -r '.poll_ms | type' "$W")" == "number" ]] \
        && ok_t "poll_ms is written as a number, not a string" \
        || bad_t "poll_ms is written as a number, not a string" "type=$(jq -r '.poll_ms | type' "$W")"
      [[ "$(stat -c '%a' "$W")" == "600" ]] \
        && ok_t "the written config is mode 600 on disk" \
        || bad_t "the written config is mode 600 on disk" "mode=$(stat -c '%a' "$W")"
    else
      bad_t "_buzz_write_config writes parseable JSON" "no readable config at $W"
    fi
    rm -rf "$TD"

    # --- the key must never become an ARGV element (ops, DIVE-3509 push gate) --
    # The first shape passed it as `env KEY=<hex> …`. /proc/<pid>/cmdline is
    # world-readable (no hidepid on our boxes), so every other agent user could
    # read a freshly minted private key for the width of the write; environ is
    # 0400 and would have been fine, argv is not.
    #
    # Graded BEHAVIOURALLY, not by grep: shadow `env` with a stub that records
    # the argv it was handed and then execs the real one, so this asserts what
    # the process actually receives rather than what the source appears to say.
    TD=$(mktemp -d)
    mkdir -p "$TD/bin"
    cat >"$TD/bin/env" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
exec /usr/bin/env "$@"
STUB
    chmod +x "$TD/bin/env"
    SECRET=$(printf 'b%.0s' {1..64})
    ARGV_LOG="$TD/argv.txt"; : >"$ARGV_LOG"
    ( export ARGV_LOG PATH="$TD/bin:$PATH"
      _buzz_write_config "$(id -un)" "$TD/buzz" "https://relay.example.com" \
        "$SECRET" general 15000 buzz >/dev/null 2>&1 )
    if [[ -s "$ARGV_LOG" ]]; then
      ok_t "CONTROL: the argv-recording stub actually fired"
      if grep -q "$SECRET" "$ARGV_LOG"; then
        bad_t "the private key never appears in argv" \
              "the minted key is a command-line argument — readable from /proc/<pid>/cmdline by every user on the box"
      else
        ok_t "the private key never appears in argv (it travels on stdin)"
      fi
      # And the key really did arrive: a leak-free call that also wrote nothing
      # would pass the arm above for the wrong reason.
      [[ "$(jq -r '.private_key' "$TD/buzz/config.json" 2>/dev/null)" == "$SECRET" ]] \
        && ok_t "POSITIVE CONTROL: the key still reached the config via stdin" \
        || bad_t "POSITIVE CONTROL: the key still reached the config via stdin" \
                 "no-leak is trivially true if the write never happened"
    else
      bad_t "CONTROL: the argv-recording stub actually fired" \
            "nothing recorded — the arm below would pass without observing anything"
    fi
    rm -rf "$TD"
  else
    printf 'SKIP - _buzz_write_config run arms (need python3 + jq)\n'
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
