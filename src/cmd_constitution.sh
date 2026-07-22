# cmd_constitution.sh — DIVE-1742
# Top-level `5dive constitution` verb family. The machine-enforced constitution (guardrails,
# thresholds, veto, ship/comms) is sealed + verified by the COUNCIL machinery; this namespace is a
# solo-user-friendly front door onto it — `show` now (READ), `init` (DIVE-1701) and `set` (DIVE-1743)
# land next in the same namespace. The dashboard (DIVE-1732) consumes `constitution show --json`
# instead of parsing constitution.yaml in-browser (DIVE-1731 no-mutation line + DIVE-1700 YAML bug
# class); the engine loadConstitution is the ONE shared parser for CLI + dashboard.
#
# Aliases into the council internals: it reuses `_council_constitution_path`,
# `_council_sealed_constitution_digest`, `_council_live_constitution_digest`, `$COUNCIL_LINEAGE`, and
# the `_council_write_runtime` node materializer — all defined in cmd_council.sh (assembled before this).

cmd_constitution() {
  local action="${1:-show}"
  [[ $# -gt 0 ]] && shift
  case "$action" in
    show) _constitution_show "$@" ;;
    init) _constitution_init "$@" ;;
    set|edit) _constitution_set "$action" "$@" ;;
    -h|--help|help)
      cat >&2 <<'CONSTITUTION_HELP'
5dive constitution — view + amend the machine-enforced constitution (guardrails, thresholds, veto, seal state)

  sudo 5dive constitution init [--force] [--json]
      SEED path (DIVE-1701). Write the full default constitution.yaml — GUARDRAILS first
      (hard_gates / ship / comms, what a solo user edits), then the Council keys present but
      DORMANT and commented as optional. Creates NO council genesis/lineage: a one-agent user
      seeds + edits guardrails with zero Council. UNSEALED — edit it, then 'constitution edit' to
      seal. REFUSES to clobber a Council-sealed constitution (amend those via 'council amend');
      refuses an existing unsealed file unless --force.

  5dive constitution show [--json]
      Read the enforced constitution as ONE envelope: hard_gates (per-class ERE + default/custom
      flag), ship / comms, thresholds, veto, the sealed + live digest (sealedDigest is null when no
      council has sealed), drift + council-verify status, and the amendment receipts. Read-only, no
      root. --json emits the machine envelope the dashboard consumes.

  sudo 5dive constitution set --file=<constitution.yaml> [--principal=<human:agent|tg:id>] [--dry-run] [--json]
      WRITE path. Validate the proposed doc via the SAME parser as `show`, then route by mode:
        · a real multi-seat COUNCIL governs  -> a constitutional amendment (council amend:
          2/3 + full quorum + founder veto); sealed on pass, untouched on non-pass.
        · SOLO (no council, or a single-principal genesis) -> direct-seal via a single-principal
          genesis (no convene, no quorum/liveness). --principal names the solo authority the first
          time (default human:<you>); re-seals inherit it. Root-owned write, so run under sudo.
      Honors DIVE-1695: the sealed digest is the authority; a later hand-edit drifts + fails closed.

  sudo 5dive constitution edit [--json]
      Open the current constitution (or the v0 default) in $EDITOR, then seal the edited bytes via
      the same routing as `set`. No-op if you exit without changes.

  (init → DIVE-1701 seeds the full default; today `set`/`edit` seal a proposed file.)
CONSTITUTION_HELP
      ;;
    *) fail "$E_USAGE" "unknown: 5dive constitution $action (want: show)" ;;
  esac
}

# Compose the DIVE-1742 read envelope. node parses the constitution + lineage receipts (the shared
# loadConstitution parser); bash supplies the ROOT-sealed digests + the chain-verify passthrough (it
# owns the gate-proof key). Read-only: needs no root, never mutates.
_constitution_show() {
  command -v node >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "constitution show needs node on PATH"
  local a
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      -h|--help) cmd_constitution --help; return 0 ;;
      *) fail "$E_USAGE" "unknown flag for constitution show: $a" ;;
    esac
  done
  local dir path sealed live verify_file="" envelope rc=0 genesis_exists=0
  path="$(_council_constitution_path)"
  sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  live="$(_council_live_constitution_digest 2>/dev/null || true)"
  [[ -f "$COUNCIL_GENESIS" ]] && genesis_exists=1
  dir="$(mktemp -d -t 5dive-constitution-show.XXXXXX)" || fail "$E_GENERIC" "mktemp failed"
  _council_write_runtime "$dir"
  # Chain-verify status is authoritative from `council verify` (re-seals each record; root owns the
  # key). Best-effort passthrough: capture its --json .data when a lineage exists, else the envelope's
  # verify field stays null. A verify that can't run (no key / no root) never fails the READ.
  if [[ -f "$COUNCIL_LINEAGE" ]]; then
    verify_file="$dir/verify.json"
    if ! JSON_MODE=1 cmd_council verify --json 2>/dev/null | jq -c '.data // empty' > "$verify_file" 2>/dev/null || [[ ! -s "$verify_file" ]]; then
      verify_file=""
    fi
  fi
  envelope="$(node "$dir/cli.mjs" constitution-show \
    --path="$path" --sealed="$sealed" --live="$live" --genesis-exists="$genesis_exists" \
    --lineage="$COUNCIL_LINEAGE" ${verify_file:+--verify-file="$verify_file"})" || rc=$?
  rm -rf "$dir"
  [[ "$rc" -eq 0 && -n "$envelope" ]] || fail "$E_GENERIC" "constitution show failed to compose the envelope"
  if (( JSON_MODE )); then
    printf '%s\n' "$envelope" | jq '{ok:true,data:.}'
  else
    _constitution_show_human "$envelope"
  fi
}

# Human render — a compact, honest snapshot (dashboard uses --json; this is the terminal view).
_constitution_show_human() {
  local env="$1"
  printf '%s' "$env" | jq -r '
    "Constitution  (" + (.source) + (if .valid then "" else "; INVALID: " + (.error // "") end) + ")\n" +
    "  file:    " + (.path // "(defaults)") + "\n" +
    "  sealed:  " + (if .sealedDigest == null then "(none — no council seal)" else (.sealedDigest[0:16] + "…") end) +
      (if .drifted then "   ⚠ DRIFT: " + (.driftReason // "") else "" end) + "\n" +
    "  verify:  " + (if .verify == null then "(not run)" else ("verified=" + (.verify.verified|tostring) + " chain=" + (.verify.chain|tostring) + " constitutionOk=" + (.verify.constitutionOk|tostring)) end) + "\n" +
    "  ship.require_ci: " + ((.ship.require_ci // "(unset)")|tostring) +
      "   comms.public_requires_human: " + ((.comms.public_requires_human // "(unset)")|tostring) + "\n" +
    "  hard_gates:\n" +
    ( [ .hard_gates | to_entries[] | "    - " + .key + " (" + (.value|tostring|.[0:52]) + (if (.value|length)>52 then "…" else "" end) + ")" ] | join("\n") ) + "\n" +
    "  amendments: " + ((.amendments|length)|tostring) + " sealed record(s)"
  '
}

# DIVE-1701 — SEED path. `constitution init` writes the full default constitution.yaml so a SOLO
# user who never wants a Council can still seed + edit the machine-enforced guardrails (hard_gates /
# ship / comms). It creates NO genesis/lineage: the Council governance keys are written present-but-
# DORMANT (they only take effect once `5dive council init` seals a real Council). The file is left
# UNSEALED — the solo user edits it, then `constitution edit`/`set` direct-seals it. Anti-clobber:
# HARD-refuses to overwrite a Council-SEALED constitution (route to `council amend`), and refuses an
# existing unsealed file unless --force. (v0.15 enforcement reads hard_gates independent of any
# Council; that wiring is out of scope here — this is the seed + the guard.)
_constitution_init() {
  command -v node >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "constitution init needs node on PATH"
  local force=0 a
  for a in "$@"; do
    case "$a" in
      --force)   force=1 ;;
      --json)    JSON_MODE=1 ;;
      -h|--help) cmd_constitution --help; return 0 ;;
      *) fail "$E_USAGE" "unknown flag for constitution init: $a" ;;
    esac
  done
  local cpath; cpath="$(_council_constitution_path)"

  # Anti-clobber (HARD): a Council has SEALED a constitution into the lineage. `init` must NEVER
  # silently rewrite governed policy — route to the sanctioned amend path. --force does NOT override.
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  if [[ -n "$sealed" ]]; then
    fail "$E_VALIDATION" "a Council has SEALED this constitution (digest ${sealed:0:12}…) — 'init' will not clobber governed policy. Amend via 'sudo 5dive council amend --file=…' (org) or 'sudo 5dive constitution edit' (solo re-seal)."
  fi

  # Anti-clobber (soft): an unsealed constitution.yaml already exists — don't blow away hand edits
  # without an explicit --force.
  if [[ -f "$cpath" && $force -eq 0 ]]; then
    fail "$E_VALIDATION" "$cpath already exists (unsealed) — refusing to overwrite. Pass --force to replace it with the fresh default, or edit it with 'sudo 5dive constitution edit'."
  fi

  local dir; dir="$(mktemp -d -t 5dive-constitution-init.XXXXXX)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  _council_write_runtime "$dir"

  mkdir -p "$(dirname "$cpath")" 2>/dev/null || true
  if { [[ -e "$cpath" ]] && [[ ! -w "$cpath" ]]; } || { [[ ! -e "$cpath" ]] && [[ ! -w "$(dirname "$cpath")" ]]; }; then
    fail "$E_PERMISSION" "cannot write $cpath (need write access — re-run with sudo if it is root-owned): sudo 5dive constitution init"
  fi

  # Render the default (guardrails-first, Council keys dormant) and validate it parses BEFORE placing
  # it (ONE parser, fail-closed) — never leave a broken governance file on disk.
  local tmp="$dir/constitution.yaml"
  node "$dir/cli.mjs" constitution-render > "$tmp" || fail "$E_GENERIC" "could not render the default constitution"
  node "$dir/cli.mjs" constitution --path="$tmp" | jq -e '.valid == true' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "the rendered default constitution did not validate — refusing to write it (fail-closed)"
  ( umask 022; cat "$tmp" > "$cpath" ) || fail "$E_GENERIC" "could not write $cpath"

  if (( JSON_MODE )); then
    jq -nc --arg p "$cpath" '{ok:true,data:{path:$p,sealed:false,council:"dormant",wrote:true}}'
  else
    echo "constitution init: wrote the default guardrails to $cpath (UNSEALED, no Council)." >&2
    echo "  Edit the hard_gates / ship / comms guardrails, then seal them with: sudo 5dive constitution edit" >&2
    echo "  The Council keys are present but DORMANT — they only activate after: sudo 5dive council init" >&2
  fi
  return 0
}

# DIVE-1743 — WRITE path. `constitution set --file=` / `constitution edit`. Validate the proposed
# constitution via the SAME engine normalizer as the read verb (ONE parser, fail-closed), then route:
#   ORG  — a real MULTI-seat council governs -> a constitutional amendment via `council amend`
#          (2/3 + full quorum + founder veto). Sealed on pass, left untouched on a non-pass.
#   SOLO — no genesis, or a single-principal (solo) genesis -> DIRECT-seal via `council init` with a
#          single-principal genesis: NO convene, no quorum / DIVE-1739 liveness (no seats to poll).
#          Reuses the exact council lineage + ROOT-seal machinery, so DIVE-1695 drift detection and
#          `council verify` work identically. --principal names the solo authority the first time
#          (default human:<you>); re-seals inherit it from the existing genesis.
# Both write paths are root-owned (COUNCIL_DIR + constitution.yaml) => sudo (inherited from init/amend).
_constitution_set() {
  local verb="${1:-set}"; [[ $# -gt 0 ]] && shift
  command -v node >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "constitution $verb needs node on PATH"
  command -v jq   >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "constitution $verb needs jq on PATH"
  local file="" principal="" dry=0 a
  for a in "$@"; do
    case "$a" in
      --file=*)      file="${a#--file=}" ;;
      --principal=*) principal="${a#--principal=}" ;;
      --dry-run)     dry=1 ;;
      --json)        JSON_MODE=1 ;;
      -h|--help)     cmd_constitution --help; return 0 ;;
      *) fail "$E_USAGE" "unknown flag for constitution $verb: $a" ;;
    esac
  done

  local dir; dir="$(mktemp -d -t 5dive-constitution-set.XXXXXX)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  _council_write_runtime "$dir"

  # `edit`: materialize the CURRENT constitution (or the v0 default when none) into a scratch file,
  # open $EDITOR on it, then seal the edited bytes through the same routing as `set`. No-op on no change.
  if [[ "$verb" == "edit" ]]; then
    [[ -z "$file" ]] || fail "$E_USAGE" "constitution edit opens \$EDITOR — pass no --file (use 'set --file=' for a non-interactive write)"
    local cur scratch before after
    cur="$(_council_constitution_path)"; scratch="$dir/constitution.yaml"
    if [[ -f "$cur" ]]; then cp "$cur" "$scratch"; else node "$dir/cli.mjs" constitution-render > "$scratch"; fi
    before="$(sha256sum < "$scratch" | awk '{print $1}')"
    "${EDITOR:-vi}" "$scratch" || fail "$E_GENERIC" "editor exited non-zero — constitution unchanged"
    after="$(sha256sum < "$scratch" | awk '{print $1}')"
    [[ "$before" != "$after" ]] || { echo "constitution edit: no changes — nothing to seal" >&2; return 0; }
    file="$scratch"
  fi

  [[ -n "$file" ]] || fail "$E_USAGE" "constitution $verb needs --file=<proposed constitution.yaml>"
  [[ -f "$file" ]] || fail "$E_NOT_FOUND" "no such file: $file"
  # ONE parser: validate the proposed doc with the SAME engine normalizer the read verb uses.
  # loadConstitution always exits 0 (it emits {valid, error} in the payload, defaulting when a file
  # can't parse), so gate on the `valid` flag — not the exit code — and surface its error. Fail-closed.
  local vout vvalid
  vout="$(node "$dir/cli.mjs" constitution --path="$file" 2>/dev/null)"
  vvalid="$(printf '%s' "$vout" | jq -r '.valid // false' 2>/dev/null)"
  [[ "$vvalid" == "true" ]] \
    || fail "$E_VALIDATION" "the proposed $file is not a valid constitution ($(printf '%s' "$vout" | jq -r '.error // "parse error"' 2>/dev/null)) — refusing to seal it (fail-closed)"

  # Route by mode: a REAL council = a sealed genesis whose head roster has MORE THAN ONE seat -> org
  # amend. No genesis, or a single-principal (solo) genesis -> direct seal. seatCount from the SEALED
  # lineage head (the same source `council amend` reads its roster from).
  local seat_count=0
  if [[ -f "$COUNCIL_GENESIS" && -f "$COUNCIL_LINEAGE" ]]; then
    seat_count="$(jq -sr 'map(select(.record.seats != null and (.record.seats|length)>0)) | (last.record.seats|length) // 0' "$COUNCIL_LINEAGE" 2>/dev/null)"
    [[ "$seat_count" =~ ^[0-9]+$ ]] || seat_count=0
  fi

  if [[ "$seat_count" -gt 1 ]]; then
    # ORG-with-council: hand the proposed file to `council amend`, which owns validate -> convene
    # (constitutional class) -> seal-FIRST -> swap. We only route; it does the governance.
    if (( dry )); then
      if (( JSON_MODE )); then jq -nc --argjson n "$seat_count" '{ok:true,data:{mode:"council",seats:$n,dryRun:true,route:"council amend (constitutional)"}}'
      else echo "constitution $verb: a $seat_count-seat council governs — would convene a constitutional amendment (council amend)"; fi
      return 0
    fi
    _council_amend "$dir" --file="$file"
    return $?
  fi

  # ---- SOLO direct-seal --------------------------------------------------------------------------
  local cpath; cpath="$(_council_constitution_path)"
  mkdir -p "$COUNCIL_DIR" 2>/dev/null || true
  if [[ ! -w "$COUNCIL_DIR" ]]; then
    fail "$E_PERMISSION" "constitution $verb seals the governance file — it writes ${COUNCIL_DIR} + ${cpath} (root-owned) and must be sudo-run: sudo 5dive constitution $verb --file=$file"
  fi

  # A solo genesis already present -> re-seal (init --force), inheriting its principal. Otherwise a
  # first-time seal: --principal (or default human:<you>). init resolves + fails closed on a bad one.
  local forced="" existing_principal=""
  if [[ "$seat_count" -ge 1 && -f "$COUNCIL_GENESIS" ]]; then
    forced="--force"
    existing_principal="$(jq -r '.veto.principal // empty' "$COUNCIL_GENESIS" 2>/dev/null)"
  fi
  [[ -n "$principal" ]] || principal="$existing_principal"
  [[ -n "$principal" ]] || principal="human:$(id -un 2>/dev/null || echo solo)"
  local seat_id="${principal#*:}"; seat_id="${seat_id//[^A-Za-z0-9_-]/_}"; [[ -n "$seat_id" ]] || seat_id="solo"

  if (( dry )); then
    if (( JSON_MODE )); then jq -nc --arg p "$principal" --arg s "$seat_id" --argjson f "$([[ -n "$forced" ]] && echo true || echo false)" \
      '{ok:true,data:{mode:"solo",dryRun:true,principal:$p,seat:$s,reseal:$f,route:"council init (direct-seal, no convene)"}}'
    else echo "constitution $verb: would direct-seal (solo, principal=$principal, seat=$seat_id${forced:+, re-seal}) — no convene"; fi
    return 0
  fi

  # Place the proposed constitution as the LIVE file before init so init digests + seals ITS bytes
  # (init only renders the v0 default when no file exists). init then builds a single-principal
  # genesis, seals the constitution digest into it, and hash-chains the lineage — all with no convene.
  ( umask 022; cat "$file" > "$cpath" ) || fail "$E_GENERIC" "could not write the constitution to $cpath"
  _council_init_or_lineage "init" "$dir" --seats="$seat_id:chair" --veto="$principal" $forced
  local rc=$?
  if (( rc != 0 )); then
    fail "$E_GENERIC" "solo direct-seal failed (council init returned $rc) — constitution at $cpath may be updated but UNSEALED; re-run once the cause is fixed"
  fi
  if (( ! JSON_MODE )); then
    echo "constitution $verb: SOLO direct-seal OK — sealed $cpath under a single-principal genesis (principal=$principal). No convene; DIVE-1695 drift + council verify now apply." >&2
  fi
  return 0
}
