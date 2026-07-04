# -------- hire (DIVE-603 / DIVE-993) — ergonomic alias for `agent create` -----
#
# Two shapes of the same verb — "hire a teammate":
#
#   1. FRESH  (DIVE-603, default): `hire <name> [--role=…] [+ create flags]`
#      Sugar over the canonical `agent create` (+ `org set`). Spins up a blank
#      agent under a name you pick. See `cmd_hire` fresh path below.
#
#   2. MARKET (DIVE-993): `hire <role> --from-market [--as=<name>]`
#      One command from the OPEN MARKET to an employed teammate. Resolves <role>
#      against the character-pack registry (rarity/completeness-tiered pick),
#      PROVISIONS from that persona (the registry-slug path of `agent import`,
#      i.e. straight from the pack synthesized off an OpenAgent persona), then
#      SLOTS the new hire into the org chart under the pack's role. This is the
#      headline "hire from the open market" story — one call, zero yak-shaving.
#
# hire never reimplements create/import logic: fresh mode forwards to cmd_create,
# market mode forwards to cmd_import. The `hire)` route in main.sh takes the
# registry lock; with_registry_lock is re-entrant so the inner call is a no-op
# re-lock. If the inner call fails it exits the lock subshell and the org step is
# correctly skipped.

# Rarity ladder → numeric rank (higher = rarer). Unknown/absent = 0.
# Strict JSON (quoted keys) — this is fed to jq via --argjson, not jq literal syntax.
_hire_rarity_rank='{"mythical":6,"legendary":5,"epic":4,"rare":3,"uncommon":2,"common":1}'

# Resolve a role query against the character-pack registry. Echoes a single TSV
# line `slug<TAB>character<TAB>rarity` for the BEST match, or returns non-zero.
#
# Match (case-insensitive): exact slug, OR the query appears in the pack's
# `character` (its role), `name`, or any `tag`. Ranked by rarity DESC, then
# completeness — skill count, then bundled memory — so `hire cto` picks the most
# complete, rarest teammate that fits the role, deterministically.
_hire_resolve_market() {
  local q idx
  q=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  idx=$(_marketplace_index) || return 2   # 2 = registry unreachable
  jq -e '.packs' >/dev/null 2>&1 <<<"$idx" || return 2
  jq -r --arg q "$q" --argjson rank "$_hire_rarity_rank" '
    [ .packs[]
      | select(
          (.slug|ascii_downcase) == $q
          or ((.character // "")|ascii_downcase|contains($q))
          or ((.name // "")|ascii_downcase|contains($q))
          or (any((.tags // [])[]; ascii_downcase|contains($q)))
        )
    ]
    | sort_by([ ($rank[.rarity // ""] // 0),
                ((.skills // [])|length),
                (if (.includesMemory // false) then 1 else 0 end) ])
    | reverse
    | if length == 0 then empty
      else "\(.[0].slug)\t\(.[0].character // "teammate")\t\(.[0].rarity // "common")"
      end
  ' <<<"$idx"
}

cmd_hire() {
  # Detect market mode first (a whole-args scan) so we can branch cleanly; the
  # positional means different things in each mode (name vs role query).
  local from_market=0 a
  for a in "$@"; do [[ "$a" == "--from-market" || "$a" == "--market" ]] && from_market=1; done
  if (( from_market )); then cmd_hire_market "$@"; return; fi

  # ---- FRESH mode (DIVE-603): sugar over `agent create` (+ org set) ----------
  local name="" role="" title="" role_set=0 title_set=0 have_type=0
  local create_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role=*)   role="${1#--role=}";   role_set=1 ;;
      --title=*)  title="${1#--title=}"; title_set=1 ;;
      --type=*)   have_type=1; create_args+=("$1") ;;
      -h|--help)
        cat <<'EOF'
usage: 5dive hire <name> [--type=claude] [--role=<text>] [--title=<text>] [+ any 'agent create' flag]
       5dive hire <role> --from-market [--as=<name>] [--role=<text>] [--title=<text>] [+ any 'agent import' flag]

FRESH  — sugar for `agent create` (+ `org set` when --role/--title given):
  5dive hire cto --role="CTO" --title="Chief Technology Officer"
  5dive hire scout --type=codex --channels=telegram --role="Researcher"

MARKET — hire from the open market: resolve <role> against the character-pack
registry (rarest, most-complete match), provision from that persona, slot into
the org chart under the pack's role:
  5dive hire ceo --from-market                    # -> imports the top CEO pack
  5dive hire engineer --from-market --as=nova     # into a fresh name 'nova'

Defaults --type=claude. Other flags pass through to `agent create` (fresh) or
`agent import` (market).
EOF
        return 0 ;;
      -*)         create_args+=("$1") ;;
      *)          [[ -z "$name" ]] && name="$1" || create_args+=("$1") ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive hire <name> [--type=claude] [--role=<text>] [--title=<text>] [--channels=...] [+ any 'agent create' flag]  (or: 5dive hire <role> --from-market)"
  # Default the type so `hire bob --role=CTO` just works (create requires --type).
  (( have_type )) || create_args+=("--type=claude")

  # Create the agent via the canonical path (re-entrant lock = no double-lock).
  with_registry_lock cmd_create "$name" "${create_args[@]}"

  # Place the new hire on the org chart if a role/title was given. org store is
  # sqlite (separate from the registry), lockless by design — safe to call here.
  if (( role_set || title_set )); then
    local org_args=("$name")
    (( role_set ))  && org_args+=("--role=$role")
    (( title_set )) && org_args+=("--title=$title")
    cmd_org_set "${org_args[@]}"
  fi
}

# ---- MARKET mode (DIVE-993): registry -> provision -> org --------------------
cmd_hire_market() {
  local role_query="" as="" role_override="" title="" role_set=0 title_set=0
  local import_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-market|--market) ;;                       # mode flag, already consumed
      --as=*)     as="${1#--as=}" ;;
      --role=*)   role_override="${1#--role=}"; role_set=1 ;;
      --title=*)  title="${1#--title=}";       title_set=1 ;;
      -h|--help)  cmd_hire --help; return 0 ;;
      -*)         import_args+=("$1") ;;                # forwarded to agent import
      *)          [[ -z "$role_query" ]] && role_query="$1" || import_args+=("$1") ;;
    esac
    shift
  done
  [[ -n "$role_query" ]] || fail "$E_USAGE" "usage: 5dive hire <role> --from-market [--as=<name>]  (e.g. 5dive hire ceo --from-market)"

  # 1) Resolve the role against the open market (rarity/completeness-tiered pick).
  step "Scanning the character-pack registry for a '$role_query'"
  local pick rc
  pick=$(_hire_resolve_market "$role_query"); rc=$?
  if (( rc == 2 )); then
    fail "$E_GENERIC" "could not reach the character-pack registry ($(_marketplace_base))"
  fi
  [[ -n "$pick" ]] || fail "$E_NOT_FOUND" "no market pack matches role '$role_query' (browse: 5dive agent marketplace ls)"
  local slug pack_role rarity
  IFS=$'\t' read -r slug pack_role rarity <<<"$pick"
  step "Matched '$slug' ($rarity) — $pack_role"

  # 2) Provision from the persona: the registry-slug path of `agent import`
  #    fetches the pack (synthesized from the OpenAgent persona) and recreates it.
  local name="${as:-$slug}"
  cmd_import "$slug" --as="$name" "${import_args[@]}"

  # 3) Slot the new hire into the org chart under the pack's role (or an override).
  local eff_role="$pack_role"; (( role_set )) && eff_role="$role_override"
  local org_args=("$name" --role="$eff_role")
  (( title_set )) && org_args+=("--title=$title")
  cmd_org_set "${org_args[@]}"

  step "Hired '$name' from the open market as $eff_role"
}
