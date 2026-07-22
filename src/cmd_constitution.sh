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
    init)
      fail "$E_USAGE" "5dive constitution init is not available yet (DIVE-1701 — seeds the full default constitution.yaml). Today: 5dive constitution show [--json]." ;;
    set|edit)
      fail "$E_USAGE" "5dive constitution set is not available yet (DIVE-1743 — solo write, refuses to clobber a Council-sealed file). Today: 5dive constitution show [--json]. To change a sealed constitution: sudo 5dive council amend --file=<new constitution.yaml>." ;;
    -h|--help|help)
      cat >&2 <<'CONSTITUTION_HELP'
5dive constitution — view the machine-enforced constitution (guardrails, thresholds, veto, seal state)

  5dive constitution show [--json]
      Read the enforced constitution as ONE envelope: hard_gates (per-class ERE + default/custom
      flag), ship / comms, thresholds, veto, the sealed + live digest (sealedDigest is null when no
      council has sealed), drift + council-verify status, and the amendment receipts. Read-only, no
      root. --json emits the machine envelope the dashboard consumes.

  (init → DIVE-1701 · set/edit → DIVE-1743; a sealed constitution changes via `sudo 5dive council amend`)
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
