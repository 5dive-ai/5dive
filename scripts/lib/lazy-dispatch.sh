# shellcheck shell=bash
# -----------------------------------------------------------------------------
# DIVE-4087 — the lazy-dispatch index generator.
#
# WHAT PROBLEM THIS SOLVES. The installed artifact is ONE file (install.sh does
# `mv -f "$_bundle_tmp" "$BIN_DIR/5dive"`), and by 2026-09 that file was 93,846
# lines. bash parses a script before it runs anything in it, so EVERY fleet call
# — every heartbeat tick, every `task ls`, every `agent send` — paid 0.20s of
# parsing to reach a dispatcher that then used one module. Measured on this host
# at v0.27.1: `5dive --version` 0.24s wall, of which `bash -n` on the bundle is
# 0.20s.
#
# THE MECHANISM, in one sentence: bash does not parse past a top-level `exit`, so
# the bundle carries its command modules as UNPARSED TRAILING TEXT and reads back
# the byte range it needs with `sed`.
#
# WHY NOT `command_not_found_handle` (the obvious answer, and it does not work):
# bash runs that handler in a SUBSHELL. A module sourced inside it is gone the
# moment the handler returns, so every call re-sources the module and any state
# the function set is lost. Measured on bash 5.2.21.
#
# WHAT WE DO INSTEAD — AUTOLOAD STUBS. For every function a payload module
# defines, the core carries a one-line stub:
#
#     cmd_login() { _lazy_autoload cmd_auth cmd_login; cmd_login "$@"; }
#
# The stub loads the module IN THE CALLER'S SHELL (no subshell), which overwrites
# the stub with the real definition, and then calls it — bash resolves a function
# name at call time, so the recursive line reaches the REAL function. ~1,300
# stubs cost ~1,300 lines of core parsing, which is noise.
#
# WHY THIS SHAPE AND NOT A STATIC DEPENDENCY CLOSURE. The obvious alternative is
# to compute, per command, the transitive set of modules it calls into and load
# exactly that. 181 of the 1,026 `cmd_*` functions are called from a DIFFERENT
# module, so that table is large — and, the important part, a table that is WRONG
# produces a missing function at runtime, i.e. a fleet-wide outage on a path
# nobody exercised. With autoload stubs the same staleness produces at worst an
# extra `sed`: correctness does not depend on the table being complete. That is
# the whole reason for the design.
#
# WHAT THE TABLE IS STILL FOR — `set -u`, NOT functions. src/header.sh runs
# `set -euo pipefail`. 111 references cross a module boundary to read a variable
# another module assigns AT ITS TOP LEVEL (measured: cmd_heartbeat reads
# cmd_selfupdate's `_PR_FIRED`; task/notify.sh reads cmd_agent_runtime's
# `MIRROR_POST_*`; cmd_supervisor reads cmd_watch's `WATCH_*` escapes). A
# function stub cannot cover those — reading one before its provider is loaded is
# an `unbound variable` and the CLI dies. So `__MODDEPS` carries exactly the
# variable-provider edges, transitively closed. It over-approximates on purpose:
# a spurious edge costs one more module in the same `sed`, a missing one is a
# crash. Every heuristic below is therefore chosen to over-, never under-, report.
#
# A LINE INDEX IS A CLAIM ABOUT A FILE NOBODY PROMISED NOT TO REWRITE. Several
# harnesses build a bundle and then edit it — `tests/buzz_by_design_rc3_not_a_panic_unit.sh`
# awk-deletes `require_root`'s body to run the artifact unprivileged, which
# removed 48 lines of core and silently slid every payload range by 48. The
# symptom was `line 11582: name: No such file or directory`: sed handed back a
# module cut mid-function and bash ran a fragment. So the payload is also framed
# with `#@MOD <name>` / `#@ENDMOD <name>` comment lines, the loader CHECKS that
# what it read is what it asked for, and falls back to matching those frames
# instead of trusting the offsets. Fast path when the file is pristine, correct
# path when it is not.
#
# See community/wiki/bash-does-not-parse-past-exit.md.
# -----------------------------------------------------------------------------

# src/task/need.sh -> task__need ; src/cmd_auth.sh -> cmd_auth
lazy_mod_name() {
  local p="${1#src/}"
  p="${p%.sh}"
  printf '%s' "${p//\//__}"
}

# Column-0 function definitions — `name() {`, or `name()` with the brace on the
# next line. Column 0 is the module's own surface: an INDENTED definition is
# nested inside another function (32 of those exist, all test fixtures inside
# cmd_selfcheck / task/loops) and is created when its parent runs, so it needs no
# stub and must not get one.
lazy_funcs() {
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$1" | tr -d '()' | sort -u
}

# Column-0 variable assignments — the module's own top-level globals — with
# readonly/declare/export/typeset unwrapped.
#
# HEREDOC BODIES ARE SKIPPED, and that is not tidiness. src/cmd_* embeds whole
# python/node/shell programs in heredocs, and those programs assign at column 0
# too: cmd_skill's installer heredoc sets TMPDIR and SRC_DIR, cmd_agent_teambot's
# python sets MODE and GROUP, cmd_push's env template sets GITHUB_APP_ID. Counted
# as module globals they make almost every module look like a dependant of
# cmd_skill and cmd_agent_create, and `5dive task ls` then drags ~4.7k lines of
# unrelated payload in on every call. Skipping the bodies is what keeps the win.
lazy_assigns() {
  awk -v file="$1" '
    # --- inside a heredoc: only its terminator matters. <<- strips leading tabs.
    term != "" {
      line = $0
      if (dash) { sub(/^\t+/, "", line) }
      if (line == term) { term = ""; dash = 0 }
      next
    }
    {
      t = $0
      # `<<<` is a HERESTRING, not a heredoc, and `<<< WORD` otherwise reads as
      # one. This cost a whole file once: the prose comment "# <<< DIVE-3172
      # agent payload fingerprint" in cmd_selfupdate.sh opened a heredoc named
      # DIVE that never closed, so every assignment below it — the whole _PR_*
      # set cmd_heartbeat reads — vanished from the scan, and its dep edge with
      # them. Neutralise them before matching.
      gsub(/<<</, "\001", t)
      # A comment line cannot open a heredoc for the shell either.
      if (t ~ /^[[:space:]]*#/) { t = "" }
      # UPPERCASE terminator only. `<< to` and `(1 << attempts)` are arithmetic
      # left shifts, and taking them for heredocs swallowed the rest of two more
      # files. Every one of the ~90 real heredoc words in src/ is uppercase, and
      # tests/lazy_dispatch_unit.sh keeps it that way — that convention is what
      # makes a one-line regex safe here instead of a shell parser.
      if (match(t, /<<-?[[:space:]]*("[A-Z_][A-Z0-9_]*"|'"'"'[A-Z_][A-Z0-9_]*'"'"'|[A-Z_][A-Z0-9_]*)/)) {
        h = substr(t, RSTART, RLENGTH)
        dash = (h ~ /^<<-/)
        sub(/^<<-?[[:space:]]*/, "", h)
        gsub(/["'"'"']/, "", h)
        term = h
        openline = FNR
      }
    }
    # Column 0 only — an indented assignment is inside a function, i.e. not a
    # module-level global. `;`-split because 7 lines in src/ init a whole set on
    # one line (`_PR_FIRED=0; _PR_DEFERRED=0; ...`, all six of them read by
    # cmd_heartbeat) and taking only the first is exactly the under-report this
    # table must not make. Splitting on `;` can over-report; that is the safe way.
    /^[A-Za-z_]/ {
      nseg = split($0, seg, ";")
      for (i = 1; i <= nseg; i++) {
        line = seg[i]
        sub(/^[[:space:]]+/, "", line)
        sub(/^(readonly|export|typeset)[[:space:]]+/, "", line)
        sub(/^declare[[:space:]]+-[a-zA-Z]+[[:space:]]+/, "", line)
        if (line !~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) {
          # The FIRST segment decides whether this line is an assignment line at
          # all. Without that, a one-line function definition leaks its body:
          # `cmd_task_start() { _task_status_cmd in_progress ", started_at=..."; }`
          # starts at column 0, and its second segment reads as a global named
          # started_at. That mistake put 8 phantom providers on every module and
          # would have loaded most of the payload on every call.
          if (i == 1) next
          continue
        }
        n = line
        sub(/(\[[^]]*\])?\+?=.*$/, "", n)
        print n
      }
    }
    END {
      # An unterminated heredoc means the scan swallowed the rest of the file and
      # under-reported this module`s globals. Under-reporting is the direction
      # that reaches users (an `unbound variable` on a cold path), so it is a
      # BUILD FAILURE, never a quiet partial answer.
      if (term != "") {
        printf "lazy-dispatch: %s: heredoc \"%s\" opened at line %d never closed — the assignment scan is not trustworthy\n", file, term, openline > "/dev/stderr"
        exit 3
      }
    }
  ' "$1" | sort -u
}

# Every identifier-shaped token in a file. This is the REFERENCE side, and it is
# deliberately blunt: `$FOO`, `${FOO:-}`, `${FOO[1]}` and the bare `FOO` of
# `(( FOO + 1 ))` all have to count, because under `set -u` an arithmetic read of
# an unset name is fatal exactly like a `$` read. Matching every word costs us
# some phantom edges (a name mentioned in a comment) and misses none.
lazy_tokens() {
  grep -ohE '[A-Za-z_][A-Za-z0-9_]*' "$1" | sort -u
}

# lazy_core_names <core-file>...
# Names the core already defines, plus the build shell's own environment. Used
# only to SUBTRACT from the payload's assignment scan.
lazy_core_names() {
  local f
  for f in "$@"; do lazy_assigns "$f"; done
  compgen -v || true
  compgen -e || true
}

# lazy_build_index <payload-index-file> <core-names-file> <workdir>
#
# <payload-index-file> lines: "<module> <relstart> <relend> <srcpath>"
# Writes <workdir>/{funcs,provides,deps}. Kept as files rather than assoc arrays
# so the test arm can diff them against an independently derived answer.
lazy_build_index() {
  local index="$1" corenames="$2" work="$3"
  local mod relstart relend path

  : >"$work/funcs"      # "<fn> <mod>"
  : >"$work/assigns"    # "<name> <mod>"
  : >"$work/tokens"     # "<mod> <token>"

  while read -r mod relstart relend path; do
    [[ -n "$mod" ]] || continue
    lazy_funcs "$path"   | sed "s|\$| $mod|" >>"$work/funcs"
    lazy_assigns "$path" | sed "s|\$| $mod|" >>"$work/assigns"
    lazy_tokens "$path"  | sed "s|^|$mod |"  >>"$work/tokens"
  done <"$index"

  # A function defined at column 0 by two different payload modules would make
  # "which module defines it" ambiguous, and today's bundle resolves it by
  # cat order (last wins) — a property lazy loading cannot reproduce. Refuse.
  local dupes
  dupes="$(awk '{print $1}' "$work/funcs" | sort | uniq -d)"
  if [[ -n "$dupes" ]]; then
    printf 'lazy-dispatch: function defined by more than one payload module:\n%s\n' "$dupes" >&2
    return 1
  fi

  # provides: a payload top-level assignment to a name the core does not own.
  # A name assigned by two modules is dropped, not guessed — it is either a
  # heredoc coincidence or a genuinely shared scratch global, and in both cases
  # an edge to one arbitrary provider would be a lie.
  # NOT `sort -u "$corenames" >"$work/corenames"`: build.sh passes that very path,
  # and a redirect truncates the file before sort opens it. The whole table then
  # comes out EMPTY, which looks exactly like "no module shares a global" — a
  # silent under-report, and under-reporting here is the one failure mode that
  # reaches users (an `unbound variable` on a cold path). Hence the assert.
  if [[ ! -s "$corenames" ]]; then
    echo "lazy-dispatch: core-name list is empty — refusing to emit an empty dep table" >&2
    return 1
  fi
  awk '{print $1}' "$work/assigns" | sort | uniq -u >"$work/uniqassigns"
  awk 'NR==FNR { core[$1]; next } ($1 in core) { next } { print }' \
    "$corenames" "$work/assigns" \
    | awk 'NR==FNR { keep[$1]; next } ($1 in keep) { print $1, $2 }' \
        "$work/uniqassigns" - \
    | sort -u >"$work/provides"

  # deps: module -> module, from "this module mentions a name another module
  # assigns at ITS top level". Under `set -u` reading one of those before its
  # provider is loaded kills the CLI, which is why this table exists at all.
  #
  # CALL edges are deliberately NOT in here, and that was measured, not assumed.
  # Adding "m mentions a function module n defines" closes the graph over 51 of
  # the 71 modules — the token scan matches a function name in a comment or an
  # error string just as happily as a call site, and transitivity does the rest.
  # `5dive whoami` went 84ms -> 4924ms. The stubs already make calls correct; the
  # only thing call edges could buy is avoiding subshell thrash, and they cost
  # two orders of magnitude more than the thrash does (see FIVE_LAZY_TRACE).
  awk 'NR==FNR { prov[$1] = $2; next }
       ($2 in prov) && prov[$2] != $1 { print $1, prov[$2] }' \
    "$work/provides" "$work/tokens" | sort -u >"$work/edges"

  # Transitive closure. The graph is ~15 nodes wide after dedup; a fixpoint loop
  # is plenty and keeps the generator dependency-free.
  awk '
    { edge[$1 " " $2] = 1; node[$1] = 1; node[$2] = 1 }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (e in edge) {
          split(e, a, " ")
          for (f in edge) {
            split(f, b, " ")
            if (a[2] == b[1] && a[1] != b[2] && !((a[1] " " b[2]) in edge)) {
              edge[a[1] " " b[2]] = 1
              changed = 1
            }
          }
        }
      }
      for (e in edge) { split(e, a, " "); print a[1], a[2] }
    }
  ' "$work/edges" | sort -u >"$work/deps"
}

# lazy_emit <payload-index-file> <workdir> <payload-offset>
# Prints the generated core block on stdout.
lazy_emit() {
  local index="$1" work="$2" offset="$3"

  cat <<'LAZY_HEAD'

# ===========================================================================
# LAZY DISPATCH (generated by build.sh — DIVE-4087). Nothing below this comment
# was hand-written; edit scripts/lib/lazy-dispatch.sh instead.
#
# Everything after the `exit` at the end of this file is UNPARSED TEXT: bash
# stops reading a script at a top-level exit, so the command modules cost
# nothing until one is asked for. __MOD holds each module's line range within
# that trailing region; the stubs at the bottom of this block pull a range in
# with sed and eval it into the CALLING shell.
# ===========================================================================
__FIVE_BUNDLE="${BASH_SOURCE[0]:-$0}"
# Resolve now, without forking: the dispatcher and half of cmd_* change
# directory, and $0 is relative whenever the CLI was invoked as ./5dive.
[[ "$__FIVE_BUNDLE" == /* ]] || __FIVE_BUNDLE="$PWD/$__FIVE_BUNDLE"
LAZY_HEAD

  printf 'readonly __FIVE_PAYLOAD_AT=%s\n' "$offset"
  printf 'declare -A __MODLOADED=()\n'

  printf 'declare -gA __MOD=(\n'
  local mod relstart relend path
  while read -r mod relstart relend path; do
    [[ -n "$mod" ]] || continue
    printf '  [%s]=%q\n' "$mod" "$relstart $relend"
  done <"$index"
  printf ')\n'

  printf 'declare -gA __MODDEPS=(\n'
  awk '{ d[$1] = d[$1] " " $2 } END { for (m in d) print m, substr(d[m], 2) }' \
    "$work/deps" | sort | while read -r mod deps; do
    printf '  [%s]=%q\n' "$mod" "$deps"
  done
  printf ')\n'

  cat <<'LAZY_BODY'

# Load one or more modules and everything they read a top-level global from.
# Locals are __lz_-prefixed on purpose: the eval below runs IN THIS FUNCTION, so
# a module's own top-level `FOO=bar` would bind to a local of the same name
# instead of the global the rest of the CLI reads. (Plain assignment, `readonly`
# and `export` all reach the global from function scope; `declare` does NOT,
# which is why every column-0 `declare -A` in src/cmd_* is written `declare -gA`
# and tests/lazy_dispatch_unit.sh refuses a new one that is not.)
_load_module() {
  local -a __lz_queue=("$@") __lz_pending=() __lz_sed=()
  local __lz_m __lz_dep __lz_s __lz_e __lz_txt
  while ((${#__lz_queue[@]})); do
    __lz_m="${__lz_queue[0]}"
    __lz_queue=("${__lz_queue[@]:1}")
    [[ -n "${__MOD[$__lz_m]:-}" && -z "${__MODLOADED[$__lz_m]:-}" ]] || continue
    __MODLOADED[$__lz_m]=1
    __lz_pending+=("$__lz_m")
    for __lz_dep in ${__MODDEPS[$__lz_m]:-}; do __lz_queue+=("$__lz_dep"); done
  done
  ((${#__lz_pending[@]})) || return 0

  # FAST PATH: one sed for the whole set. sed emits the ranges in FILE order
  # however they were passed — which is bundle order, the order the eager bundle
  # cat'd them in. src/task/*.sh relies on that: a few of those files open with
  # top-level assignments a later one reads.
  for __lz_m in "${__lz_pending[@]}"; do
    read -r __lz_s __lz_e <<<"${__MOD[$__lz_m]}"
    __lz_sed+=( -e "$((__lz_s + __FIVE_PAYLOAD_AT)),$((__lz_e + __FIVE_PAYLOAD_AT))p" )
  done
  __lz_txt="$(sed -n "${__lz_sed[@]}" "$__FIVE_BUNDLE")"

  # Did we get what we asked for? Every module is framed by its own name, so
  # this is a real check on the bytes, not a checksum of the offsets against
  # themselves. It fires when something rewrote the file after the build.
  for __lz_m in "${__lz_pending[@]}"; do
    # The trailing newline in the pattern is load-bearing: "#@MOD cmd_agent" is
    # a prefix of "#@MOD cmd_agent_create", so an unanchored match would accept
    # the wrong module and report success on a slice that never contained it.
    if [[ "$__lz_txt" != *"#@MOD $__lz_m"$'\n'* || "$__lz_txt" != *"#@ENDMOD $__lz_m"$'\n'* ]]; then
      # SLOW PATH, and it is the correct one: match the frames instead of
      # trusting line numbers. A full pass over the bundle, paid only by a
      # rewritten artifact.
      __lz_sed=()
      for __lz_m in "${__lz_pending[@]}"; do
        __lz_sed+=( -e "/^#@MOD $__lz_m\$/,/^#@ENDMOD $__lz_m\$/p" )
      done
      __lz_txt="$(sed -n "${__lz_sed[@]}" "$__FIVE_BUNDLE")"
      break
    fi
  done

  # FIVE_LAZY_TRACE=1 reports what a command actually pulled in, one line per
  # load. The cost of lazy dispatch is not the sed, it is a call whose FIRST
  # invocation happens inside `$( )` — the module lands in the subshell and is
  # gone on return, so the next call re-reads it. This is how you find one.
  [[ -z "${FIVE_LAZY_TRACE:-}" ]] \
    || printf '5dive[lazy] load %s\n' "${__lz_pending[*]}" >&2
  eval "$__lz_txt"
}

# The stub's own backstop. If the module has already been loaded and we are
# still standing in the stub, the real definition never arrived — the index in
# this bundle disagrees with the payload it was built from. That is a build bug,
# not a user error, so say so and stop rather than recursing until FUNCNEST.
_lazy_autoload() { # <module> <function>
  if [[ -n "${__MODLOADED[$1]:-}" ]]; then
    printf '5dive: internal error: %s() is missing from module %s.\n' "$2" "$1" >&2
    printf '  This bundle'"'"'s lazy-dispatch index does not match its payload. Reinstall:\n' >&2
    printf '  curl -fsSL https://install.5dive.com | sudo bash\n' >&2
    exit 70
  fi
  _load_module "$1"
}
LAZY_BODY

  printf '\n# --- autoload stubs (%s) ---\n' "$(wc -l <"$work/funcs" | tr -d ' ')"
  # `name(){` with NO space, and that is deliberate. Two dozen harnesses rewrite
  # a BUILT bundle with awk or sed anchored on `^name() {` — the shape every real
  # definition in src/ uses — to neuter or instrument one function.
  # tests/silent_nonzero_exit_backstop_unit.sh injects a line after
  # `^cmd_whoami() {`; with a spaced stub it matched the STUB first and injected
  # an unguarded `$(… | grep <no-match>)` at TOP LEVEL of the core, which under
  # `set -euo pipefail` killed the CLI at load — before the verb was set and
  # before the trap was installed. Four arms went red reporting the absence of a
  # banner that could not have printed. Dropping the space makes every one of
  # those patterns miss the stub and find the definition it meant, with no
  # harness edits at all.
  sort "$work/funcs" | while read -r fn mod; do
    printf '%s(){ _lazy_autoload %s %s; %s "$@"; }\n' "$fn" "$mod" "$fn" "$fn"
  done
  printf '# --- end lazy dispatch ---\n'
}
