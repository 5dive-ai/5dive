# -------- DIVE-9107: a whole team as ONE .tar.gz ------------------------------
#
#   5dive team export <team> [-o <file.tar.gz>] [--with-memory] [--audience=publish|self]
#   5dive team import <file.tar.gz> [the usual team import flags]
#
# One agent already moves between boxes as a file (`agent export`/`agent import`).
# A team is several agents plus who reports to whom, their roles and their
# recurring work, so its file is a team yaml with every member's agent pack
# beside it:
#
#   manifest.json        {"kind":"5dive-team","format":1,"team":<slug>,...}
#   team.5dive.yaml      version 2; each seat carries pack_file: packs/<name>.tar.gz
#   packs/<name>.tar.gz  that member's `agent export` pack (persona, skill bodies,
#                        settings subset, and its memory only with --with-memory)
#
# The far side needs no registry: every seat imports from its own file, through
# the same `up` path a yaml import takes. Memory is off by default and, when
# asked for, is the distilled set `agent share --with-memory` carries (knowledge
# facts only, never notes about people), scanned by the export's own checks.
#
# A bundle is untrusted input: it skipped registry signing. `team import`
# refuses any traversal or link member before extracting (_pack_safe_extract),
# the parser refuses a pack_file that climbs or is absolute, and `up` checks
# every seat's file before creating the first agent.

TEAM_BUNDLE_KIND="5dive-team"
TEAM_BUNDLE_FORMAT=1

# -------- DIVE-9109: a PREMIUM team file — signed by 5dive, stamped with its buyer
#
# A paid team is not on the public registry. Its buyer gets ONE .gz that wraps a
# normal team bundle (above):
#
#   manifest.json        {"format":1,"kind":"5dive-premium-team","team":<slug>,
#                         "version":"X.Y.Z","buyer":{"account":<id>,"name":<name>},
#                         "issued_at":<epoch>,"files":{"payload/team.tar.gz":<sha256>},
#                         "trust":{"team_key","team_key_sig","revoked","revoked_sig"}}
#   manifest.sig         raw ed25519 over manifest.json's exact bytes, by the team key
#   payload/team.tar.gz  the team bundle; its own manifest.json repeats the buyer
#                        (licensed_to), so a copy with the wrapper torn off still
#                        names who it was sold to
#
# The team key is trusted ONLY through 5dive's root, certified for this one kind
# (5dive-team-key): the update key, the office app key and an expired or revoked
# key are refused (_ou_chain, src/lib/offline_update.sh). A box without the root
# refuses every premium file. packaging/premium-team/build.sh makes one.
# Deliberately no DRM: the file can be passed on; the signature says it came
# from 5dive, the stamp says whose copy it was.
TEAM_PREMIUM_KIND="5dive-premium-team"

# <outer-dir> -> 0 when the unpacked premium wrapper in <outer-dir> verifies:
# exactly its three members, the team key through the root, the signature, the
# manifest and the payload's sha256. 1 = refused, _OU_WHY says why in plain words.
# <outer-dir> was unpacked by _pack_safe_extract (no links, no traversal).
_team_premium_verify() {
  local d="$1" meta root rrc=0 m members want got
  _OU_WHY=""
  command -v openssl >/dev/null 2>&1 || { _OU_WHY="openssl is not installed, so the signature cannot be checked"; return 1; }
  members=$(cd "$d" && find . -mindepth 1 -printf '%y %P\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ';')
  [[ "$members" == "d payload;f manifest.json;f manifest.sig;f payload/team.tar.gz;" ]] \
    || { _OU_WHY="the file holds something other than its manifest, signature and team"; return 1; }
  meta=$(mktemp -d) || { _OU_WHY="internal: could not stage the check"; return 1; }
  chmod 700 "$meta"
  cp "$d/manifest.json" "$meta/manifest.json" || { rm -rf "$meta"; _OU_WHY="could not read the manifest"; return 1; }
  root="$meta/root.pem"
  _ou_root_key "$root" || rrc=$?
  if (( rrc != 0 )); then
    (( rrc == 2 )) || _OU_WHY="this server holds no 5dive root key, so it cannot check a premium team file — update 5dive first"
    rm -rf "$meta"; return 1
  fi
  _ou_chain "$meta" "$root" team_key || { rm -rf "$meta"; return 1; }
  if ! _ou_sig_ok "$meta/certified.pem" "$meta/manifest.json" "$d/manifest.sig"; then
    rm -rf "$meta"; _OU_WHY="the signature does not match the team key 5dive's root key certified — the file was changed or was not made by 5dive"; return 1
  fi
  m="$meta/manifest.json"
  if ! jq -e --arg k "$TEAM_PREMIUM_KIND" '.format == 1 and .kind == $k
         and (.team|type == "string" and test("^[a-z0-9][a-z0-9-]{0,63}$"))
         and (.version|type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
         and (.buyer.account|type == "string" and length > 0) and (.buyer.name|type == "string")
         and (.issued_at|type == "number")
         and (.files|type == "object") and ((.files|keys) == ["payload/team.tar.gz"])' "$m" >/dev/null 2>&1; then
    rm -rf "$meta"; _OU_WHY="the manifest is not a premium team manifest this 5dive reads"; return 1
  fi
  want=$(jq -r '.files["payload/team.tar.gz"]' "$m"); got=$(_ou_sha256 "$d/payload/team.tar.gz")
  if [[ ! "$want" =~ ^[0-9a-f]{64}$ || "$got" != "$want" ]]; then
    rm -rf "$meta"; _OU_WHY="the team was changed after the file was signed — refused"; return 1
  fi
  _ou_keep_revoked
  rm -rf "$meta"
  return 0
}

# <file> -> 0 when it is a gzip file (a team bundle candidate), else 1.
_team_is_bundle() {
  local f="$1" magic
  [[ -f "$f" ]] || return 1
  magic=$(head -c 2 -- "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [[ "$magic" == "1f8b" ]]
}

# <signed-label-json> -> $STATE_DIR/premium-teams/<team>.json: which version of
# a premium team this box runs and whose copy it is. A box that cannot write it
# still has the team; it warns.
_team_premium_record() {
  local j="$1" team dir
  team=$(jq -r '.team // empty' <<<"$j" 2>/dev/null)
  [[ "$team" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || return 0
  dir="${STATE_DIR:-/var/lib/5dive}/premium-teams"
  if mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$j" >"$dir/$team.json.tmp.$$" 2>/dev/null \
     && mv -f "$dir/$team.json.tmp.$$" "$dir/$team.json"; then
    return 0
  fi
  rm -f "$dir/$team.json.tmp.$$" 2>/dev/null
  warn "could not record premium team $team's label in $dir (the team is imported)"
  return 0
}

# <file> <dir> -> unpack a team bundle into <dir>, print its team slug.
# Return: 0 ok; 1 not readable; 2 unsafe member; 3 not a team bundle;
# 4 a premium team file that did not verify (<dir>/.premium-why says why).
# A premium file that verifies leaves its signed manifest at <dir>/.premium.json
# and the team it wraps unpacked in <dir>, exactly like a plain bundle.
_team_bundle_unpack() {
  local f="$1" dir="$2" rc=0 slug outer
  _pack_safe_extract "$f" "$dir" || { rc=$?; return "$rc"; }
  [[ -f "$dir/manifest.json" && ! -L "$dir/manifest.json" ]] || return 3
  if [[ "$(jq -r '.kind // empty' "$dir/manifest.json" 2>/dev/null)" == "$TEAM_PREMIUM_KIND" ]]; then
    outer=$(mktemp -d) || return 1
    find "$dir" -mindepth 1 -maxdepth 1 -exec mv -t "$outer" -- {} + || { rm -rf "$outer"; return 1; }
    if ! _team_premium_verify "$outer"; then
      printf '%s' "$_OU_WHY" >"$dir/.premium-why"; rm -rf "$outer"; return 4
    fi
    _pack_safe_extract "$outer/payload/team.tar.gz" "$dir" || { rc=$?; rm -rf "$outer"; return "$rc"; }
    # The stamp inside the team must name the same buyer as the signed wrapper.
    if [[ -f "$dir/manifest.json" && ! -L "$dir/manifest.json" ]] \
       && ! jq -e --slurpfile o "$outer/manifest.json" \
            '.team == $o[0].team and .licensed_to.account == $o[0].buyer.account' "$dir/manifest.json" >/dev/null 2>&1; then
      printf '%s' "the team inside this file does not match its signed label (team or buyer) — refused" >"$dir/.premium-why"
      rm -rf "$outer"; return 4
    fi
    jq 'del(.trust)' "$outer/manifest.json" >"$dir/.premium.json" 2>/dev/null
    rm -rf "$outer"
    [[ -f "$dir/manifest.json" && ! -L "$dir/manifest.json" ]] || return 3
  fi
  [[ -f "$dir/team.5dive.yaml" && ! -L "$dir/team.5dive.yaml" ]] || return 3
  [[ "$(jq -r '.kind // empty' "$dir/manifest.json" 2>/dev/null)" == "$TEAM_BUNDLE_KIND" ]] || return 3
  slug=$(jq -r '.team // empty' "$dir/manifest.json" 2>/dev/null)
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || return 3
  printf '%s' "$slug"
}

# <persona-file> -> the role instructions a team import wrote into it: the text
# between the LAST "## Role" heading and the "## Reporting" heading after it.
# Nothing when there is none (a seat with no role text).
_team_export_instructions() {
  [[ -f "$1" ]] || return 0
  python3 - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
rep = max((i for i, l in enumerate(lines) if l.rstrip() == "## Reporting"), default=-1)
if rep < 0:
    sys.exit(0)
role = max((i for i, l in enumerate(lines[:rep]) if re.fullmatch(r"## Role(: .*)?", l.rstrip())), default=-1)
if role < 0:
    sys.exit(0)
text = "\n".join(lines[role + 1:rep]).strip()
if text:
    print(text)
PY
}

cmd_team_export() {
  local team="" out="" with_memory=0 audience="publish"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output) shift; [[ $# -gt 0 ]] || fail "$E_USAGE" "-o needs a path"; out="$1" ;;
      --output=*|--out=*) out="${1#*=}" ;;
      --with-memory) with_memory=1 ;;
      --audience=*)  audience="${1#--audience=}" ;;
      -h|--help)
        cat >&2 <<'HELP'
usage: 5dive team export <team> [-o <file.tar.gz>] [--with-memory] [--audience=publish|self]
  Write a whole team to ONE file: every member's agent pack (persona, skills,
  settings), their roles, who reports to whom, and their recurring work.
  Import it on any box with: 5dive team import <file.tar.gz>
  --with-memory   also carry what each member learned (knowledge facts only,
                  never notes about people). Off by default.
  --audience=self for your own box: skips the check that refuses memory naming
                  hosts, people or ids (the secret check always runs).
  Logins, bots, keys and chats are never in the file.
HELP
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$team" ]] && team="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$team" ]] || fail "$E_USAGE" "usage: 5dive team export <team> [-o <file.tar.gz>] [--with-memory]"
  [[ "$team" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "$E_USAGE" "'$team' is not a team name (5dive team ps lists them)"
  [[ "$audience" == publish || "$audience" == self ]] || fail "$E_USAGE" "--audience must be 'publish' (default) or 'self'"
  require_root "team export"
  [[ -n "$out" ]] || out="./${team}.team.tar.gz"
  tasks_db_init
  _team_members_backfill "$team" || true
  local rows; rows=$(db "SELECT agent || char(9) || COALESCE(reports_to,'') FROM team_members
                         WHERE team=$(sqlq "$team") ORDER BY rowid;" 2>/dev/null)
  [[ -n "$rows" ]] || fail "$E_NOT_FOUND" "no team '$team' on this box (5dive team ps lists the installed teams)"

  local reg; reg=$(registry_read)
  local -a names=() mgrs=()
  local n m i
  while IFS=$'\t' read -r n m; do
    [[ -n "$n" ]] || continue
    if [[ "$(jq -r --arg n "$n" '.agents[$n] | if . == null then "gone" elif (.system // "") != "" then "system" else "ok" end' <<<"$reg")" != ok ]]; then
      warn "team '$team': '$n' is not an agent on this box any more — left out of the file"
      continue
    fi
    names+=("$n"); mgrs+=("$m")
  done <<<"$rows"
  (( ${#names[@]} > 0 )) || fail "$E_NOT_FOUND" "team '$team' has no agents left on this box"

  # ONE root: an import derives the team's lead from the one seat that reports to
  # nobody. The recorded lead wins, else the first member with no manager. A
  # member whose manager is outside the team reports to that lead in the file.
  local lead; lead=$(_team_installed_lead "$team")
  local roster; roster=$(printf '%s\n' "${names[@]}")
  grep -qxF -- "${lead:-}" <<<"$roster" || lead=""
  if [[ -z "$lead" ]]; then
    for i in "${!names[@]}"; do [[ -z "${mgrs[$i]}" ]] && { lead="${names[$i]}"; break; }; done
  fi
  [[ -n "$lead" ]] || lead="${names[0]}"

  local stage; stage=$(mktemp -d) || fail "$E_GENERIC" "no temp dir"
  mkdir -p "$stage/packs"
  local agents="{}" type pslug role mgr model effort instr loops pf err obj counts kept
  local -a exp_args
  for i in "${!names[@]}"; do
    n="${names[$i]}"; mgr="${mgrs[$i]}"
    # A manager outside the team is not this team's edge (the far side would
    # refuse a reports_to that names no seat): that member reports to the lead.
    [[ -n "$mgr" ]] && ! grep -qxF -- "$mgr" <<<"$roster" && mgr=""
    if [[ "$n" == "$lead" ]]; then mgr=""; elif [[ -z "$mgr" ]]; then mgr="$lead"; fi
    type=$(jq -r --arg n "$n" '.agents[$n].type // "claude"' <<<"$reg")
    pslug=$(jq -r --arg n "$n" '.agents[$n].pack.slug // empty' <<<"$reg")
    role=$(db "SELECT COALESCE(role,'') FROM agents_org WHERE name=$(sqlq "$n");" 2>/dev/null | head -1)
    model=$(resolve_agent_model "$type" "$n" 2>/dev/null) || model=""
    effort=$(resolve_agent_effort "$type" "$n" 2>/dev/null) || effort=""
    pf=$(persona_target "$n" "$type" 2>/dev/null) || pf=""
    instr=$(_team_export_instructions "$pf")
    loops=$(_compose_export_loops "$n" 2>/dev/null) || loops="[]"
    step "[$n] packing"
    exp_args=("--audience=$audience")
    if (( with_memory )); then
      if counts=$(_share_memory_distill "$n" "$stage/mem-$n"); then
        kept="${counts%% *}"
        if (( kept > 0 )); then exp_args+=("--approve-memory=$stage/mem-$n")
        else warn "[$n] has nothing it learned to carry yet — packed without memory"; fi
      else
        warn "[$n] has no memory store 5dive can read — packed without memory"
      fi
    fi
    # cmd_export refuses by `fail` (exit); a subshell brings that back as a reason.
    if ! err=$( (JSON_MODE=0; cmd_export "$n" "${exp_args[@]}" -o "$stage/packs/$n.tar.gz") 2>&1 >/dev/null ); then
      rm -rf "$stage"
      fail "$E_GENERIC" "team '$team' was not exported: packing '$n' was refused: $(printf '%s' "$err" | grep -v '^==>' | tail -3 | tr '\n' ' ')"
    fi
    rm -rf "$stage/mem-$n"
    obj=$(jq -n --arg pf "packs/$n.tar.gz" --arg pack "$pslug" --arg role "$role" --arg mgr "$mgr" \
                --arg model "$model" --arg effort "$effort" --arg instr "$instr" \
                --argjson loops "${loops:-[]}" '
      {pack_file:$pf}
      | (if $pack   != "" then .pack = $pack else . end)
      | (if $role   != "" then .role = $role else . end)
      | (if $mgr    != "" then .reports_to = $mgr else . end)
      | (if $model  != "" then .model = $model else . end)
      | (if $effort != "" then .effort = $effort else . end)
      | (if $instr  != "" then .instructions = $instr else . end)
      | (if ($loops | length) > 0 then .loops = $loops else . end)')
    agents=$(jq -c --arg n "$n" --argjson o "$obj" '. + {($n): $o}' <<<"$agents")
  done

  jq -n --arg t "$team" --argjson a "$agents" '{version:"2", team:{name:$t, slug:$t}, agents:$a}' \
    | python3 -c 'import sys, json, yaml
print("# 5dive team bundle (5dive team export) — import with: 5dive team import <this file>.tar.gz")
print(yaml.safe_dump(json.load(sys.stdin), sort_keys=False, allow_unicode=True, default_flow_style=False), end="")' \
    >"$stage/team.5dive.yaml" || { rm -rf "$stage"; fail "$E_GENERIC" "could not write the team yaml"; }
  jq -n --arg k "$TEAM_BUNDLE_KIND" --argjson f "$TEAM_BUNDLE_FORMAT" --arg t "$team" \
        --argjson mem "$( (( with_memory )) && echo true || echo false)" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson a "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" \
        '{kind:$k, format:$f, team:$t, agents:$a, memory:$mem, exported_at:$at}' >"$stage/manifest.json"
  if ! tar -czf "$out" -C "$stage" manifest.json team.5dive.yaml packs 2>/dev/null; then
    rm -rf "$stage"; fail "$E_GENERIC" "cannot write $out"
  fi
  rm -rf "$stage"
  ok "exported team '$team' (${#names[@]} agents$( (( with_memory )) && echo ', with memory')) to $out — import it with: 5dive team import $out" \
    '{file:$f, team:$t, agents:($n|tonumber), memory:($m == "1")}' \
    --arg f "$out" --arg t "$team" --arg n "${#names[@]}" --arg m "$with_memory"
}
