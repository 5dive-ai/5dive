# -------- crew (DIVE-787) — 5dive as the always-on runtime for CrewAI crews --------
# The 0.5.0 flagship. CrewAI is a Python lib: you write Agent/Task/Crew and call
# crew.kickoff(), which runs-to-completion then exits. We do NOT force that into
# our long-lived REPL model — a crew is a finite TRIGGERED JOB and the "24/7" is
# the box + scheduler + durable state around it (the Loops primitive). We provide
# what a bare crew lacks: persistent install, durable memory (CrewAI's memory dir
# mounted on the box's persistent disk via CREWAI_STORAGE_DIR), a did:key identity,
# and a co-signed work receipt per run that feeds the ZeroHuman work-history net.
#
# LLM auth = BYO customer key (litellm env), NEVER our Claude subscription — that
# sidesteps the consumer-ToS line and we monetize the runtime, not tokens. The key
# is supplied via `crew secret set` (gate DIVE-787 = option A): a root/owner-600
# env file, never group-readable, injected only at kickoff.
#
# Spike proof + design detail: community/wiki/crewai-on-5dive-spike.md.

# Base dir for all installed crews (per box/owner). Each crew gets:
#   <name>/repo     the cloned CrewAI project
#   <name>/venv     its python venv (deps isolated per crew)
#   <name>/storage  CREWAI_STORAGE_DIR — durable memory across kickoffs/reboots
#   <name>/secret.env   BYO LLM key(s), chmod 600 (gate A)
#   <name>/identity.json  the crew's did:key keypair (from = deliverer)
#   <name>/crew.json    install marker (repo, entry, createdAt)
_crew_base() { echo "${CREW_HOME:-$HOME/.5dive/crews}"; }
_crew_dir()  { echo "$(_crew_base)/$1"; }
# Box-level runtime identity (the co-signer; stable across crews on this box).
_crew_runtime_identity() { echo "${CREW_HOME:-$HOME/.5dive}/runtime-identity.json"; }
# ZeroHuman ingest endpoint for receipts (overridable for tests/self-host).
_crew_ingest_url() { echo "${ZEROHUMAN_INGEST_URL:-https://api.5dive.com/a2a/receipts}"; }

cmd_crew() {
  local sub="${1:-help}"; shift || true
  # DIVE-1002 invariant: no `sudo 5dive` subcommand may exec agent-controlled
  # input as root. Crews install + run agent-authored Python from their own venv
  # (cmd_crew_run) and are a per-user feature — installed and run under the
  # invoking user's $HOME/.5dive/crews, never needing root. Refuse EUID 0 so the
  # admin "5dive CLI as root" grant can't reach crew exec and become an
  # admin->root escalation. Run crews as yourself, without sudo. (help is
  # allowed as root so `sudo 5dive crew` still prints usage.)
  if [[ "$sub" != "help" && "$sub" != "-h" && "$sub" != "--help" && "$(id -u)" == "0" ]]; then
    fail "$E_PERMISSION" "5dive crew must run as your own user, not root — crews execute agent-authored code from their venv, so running as root would be a privilege escalation. Re-run without sudo (crews live in your \$HOME)."
  fi
  case "$sub" in
    install)          cmd_crew_install "$@" ;;
    secret)           cmd_crew_secret "$@" ;;
    run)              cmd_crew_run "$@" ;;
    show)             cmd_crew_show "$@" ;;
    list|ls)          cmd_crew_list "$@" ;;
    uninstall|remove) cmd_crew_uninstall "$@" ;;
    help|-h|--help)   _crew_help ;;
    *)                fail "$E_USAGE" "unknown crew command: $sub (install|secret|run|show|list|uninstall)" ;;
  esac
}

_crew_help() {
  cat <<'EOF'
5dive crew — run your CrewAI crew 24/7 on 5dive (always-on runtime)

  crew install <git-url> --as=<name> [--entry=<module:Crew>] [--branch=<b>]
  crew secret  set <name> KEY=VALUE [KEY=VALUE ...]   # BYO LLM key (root/owner-600)
  crew run     <name> [--input='{"k":"v"}'] [--no-receipt]
  crew show    <name>
  crew list
  crew uninstall <name> [--purge]

  A crew is a finite job: `crew run` does one crew.kickoff() then exits. Schedule
  it (recurring task / heartbeat) or trigger it from telegram for the "always-on"
  shape. Memory persists across runs in <name>/storage (CREWAI_STORAGE_DIR).
  Each run emits a co-signed work receipt to the ZeroHuman feed (skip: --no-receipt).

  LLM auth is BYO: set the customer's own key with `crew secret set` (e.g.
  ANTHROPIC_API_KEY=...). We never route crew inference through 5dive's auth.
EOF
}

# crew install <git-url> --as=<name> — clone, isolate deps, mint identity, wire storage.
cmd_crew_install() {
  local url="" name="" entry="" branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as=*)     name="${1#*=}" ;;
      --entry=*)  entry="${1#*=}" ;;
      --branch=*) branch="${1#*=}" ;;
      --) shift; [[ -z "$url" && $# -gt 0 ]] && { url="$1"; shift; }; break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$url" ]] && url="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$url" ]]  || fail "$E_USAGE" "usage: 5dive crew install <git-url> --as=<name> [--entry=<module:Crew>]"
  [[ -n "$name" ]] || fail "$E_USAGE" "--as=<name> is required (a short id for the crew)"
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "$E_VALIDATION" "bad crew name '$name' (lowercase a-z0-9, - and _)"
  command -v python3 >/dev/null || fail "$E_GENERIC" "python3 not found on this box"
  command -v git >/dev/null     || fail "$E_GENERIC" "git not found on this box"

  local dir; dir="$(_crew_dir "$name")"
  [[ -e "$dir" ]] && fail "$E_VALIDATION" "crew '$name' already exists at $dir (uninstall it first)"
  mkdir -p "$dir"/{storage} || fail "$E_GENERIC" "could not create $dir"

  step "cloning $url → $dir/repo ..."
  local -a gitargs=(clone --depth=1)
  [[ -n "$branch" ]] && gitargs+=(--branch "$branch")
  git "${gitargs[@]}" "$url" "$dir/repo" >/dev/null 2>&1 \
    || { rm -rf "$dir"; fail "$E_GENERIC" "git clone failed for $url"; }

  step "creating venv + installing deps (crewai + repo requirements) ..."
  python3 -m venv "$dir/venv" >/dev/null 2>&1 || { rm -rf "$dir"; fail "$E_GENERIC" "venv creation failed"; }
  "$dir/venv/bin/pip" install --quiet --disable-pip-version-check crewai >/dev/null 2>&1 \
    || warn "base 'crewai' install hit an error — check $dir/repo deps"
  if [[ -f "$dir/repo/requirements.txt" ]]; then
    "$dir/venv/bin/pip" install --quiet -r "$dir/repo/requirements.txt" >/dev/null 2>&1 || warn "requirements.txt install had errors"
  elif [[ -f "$dir/repo/pyproject.toml" ]]; then
    "$dir/venv/bin/pip" install --quiet -e "$dir/repo" >/dev/null 2>&1 || warn "pyproject install had errors"
  fi

  # Mint a did:key identity for the crew (from = deliverer) and ensure a box-level
  # runtime identity (to = co-signer). Uses @5dive/openagent so the receipt signs
  # byte-identically to what ZeroHuman verifies. Installed locally for the emitter.
  step "minting crew identity + receipt tooling ..."
  ( cd "$dir" && npm init -y >/dev/null 2>&1 && npm install --silent @5dive/openagent@0.35.0 >/dev/null 2>&1 ) \
    || warn "could not install @5dive/openagent locally — receipts will be skipped until present"
  _crew_write_helpers "$dir"
  node "$dir/.mint-identity.js" "$dir/identity.json" >/dev/null 2>&1 || warn "crew identity mint failed (receipts disabled)"
  [[ -f "$(_crew_runtime_identity)" ]] || node "$dir/.mint-identity.js" "$(_crew_runtime_identity)" >/dev/null 2>&1 || true

  # Auto-detect the entry (module:Crew) if not given: look for a crew.py / main.py.
  if [[ -z "$entry" ]]; then
    entry="$(_crew_detect_entry "$dir/repo")"
  fi

  local crew_did; crew_did="$(jq -r '.did // empty' "$dir/identity.json" 2>/dev/null)"
  jq -n --arg url "$url" --arg entry "$entry" --arg br "$branch" --arg did "$crew_did" \
        '{repo:$url, branch:($br|if .=="" then null else . end), entry:($entry|if .=="" then null else . end), did:($did|if .=="" then null else . end)}' \
        > "$dir/crew.json"

  step "installed crew '$name' (did: ${crew_did:-none}); storage: $dir/storage"
  step "next: 5dive crew secret set $name ANTHROPIC_API_KEY=...   then   5dive crew run $name"
  ok "installed crew '$name'" \
     '{name:$n, repo:$u, entry:($e|if .=="" then null else . end), did:($d|if .=="" then null else . end), storage:$s}' \
     --arg n "$name" --arg u "$url" --arg e "$entry" --arg d "$crew_did" --arg s "$dir/storage"
}

# Best-effort entry detection: first "module:ClassName" we can spot, else blank.
_crew_detect_entry() {
  local repo="$1" f
  for f in crew.py main.py src/crew.py app.py; do
    if [[ -f "$repo/$f" ]]; then
      local cls; cls="$(grep -oE 'class [A-Za-z_][A-Za-z0-9_]*' "$repo/$f" | head -1 | awk '{print $2}')"
      local mod="${f%.py}"; mod="${mod//\//.}"
      [[ -n "$cls" ]] && { echo "${mod}:${cls}"; return; }
    fi
  done
  echo ""
}

# crew secret set <name> KEY=VALUE ... — write the BYO LLM key, owner-600 (gate A).
cmd_crew_secret() {
  local action="${1:-}"; shift || true
  [[ "$action" == "set" ]] || fail "$E_USAGE" "usage: 5dive crew secret set <name> KEY=VALUE [KEY=VALUE ...]"
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive crew secret set <name> KEY=VALUE [...]"
  local dir; dir="$(_crew_dir "$name")"
  [[ -d "$dir" ]] || fail "$E_NOT_FOUND" "no crew '$name' (see: 5dive crew list)"
  [[ $# -gt 0 ]] || fail "$E_USAGE" "give at least one KEY=VALUE"
  local envf="$dir/secret.env"
  umask 077
  touch "$envf"; chmod 600 "$envf"
  local kv k
  local -a setk=()
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || fail "$E_VALIDATION" "not KEY=VALUE: '$kv'"
    k="${kv%%=*}"
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || fail "$E_VALIDATION" "bad env key '$k'"
    # Replace existing line for this key, then append.
    grep -vE "^${k}=" "$envf" > "$envf.tmp" 2>/dev/null || true
    mv "$envf.tmp" "$envf"; chmod 600 "$envf"
    printf '%s\n' "$kv" >> "$envf"
    setk+=("$k")
  done
  step "stored ${#setk[@]} secret(s) for crew '$name' (owner-600, never group-readable): ${setk[*]}"
  ok "set ${#setk[@]} secret(s) for crew '$name'" '{name:$n, keys:$k}' \
     --arg n "$name" --argjson k "$(printf '%s\n' "${setk[@]}" | jq -R . | jq -sc .)"
}

# crew run <name> — one kickoff, then emit a co-signed receipt.
cmd_crew_run() {
  local name="" input="" no_receipt=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input=*)   input="${1#*=}" ;;
      --no-receipt) no_receipt=1 ;;
      --) shift; [[ -z "$name" && $# -gt 0 ]] && { name="$1"; shift; }; break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive crew run <name> [--input='{...}'] [--no-receipt]"
  local dir; dir="$(_crew_dir "$name")"
  [[ -d "$dir" ]] || fail "$E_NOT_FOUND" "no crew '$name' (see: 5dive crew list)"
  local entry; entry="$(jq -r '.entry // empty' "$dir/crew.json" 2>/dev/null)"
  [[ -n "$entry" ]] || fail "$E_VALIDATION" "crew '$name' has no entry (module:Crew) — reinstall with --entry=..."

  # BYO key + durable memory: source the owner-600 secret env, point CrewAI at the
  # persistent storage dir. Then run the crew in its own venv against its repo.
  local out rc started ended
  started="$(date -u +%FT%TZ)"
  step "running crew '$name' (kickoff: $entry) ..."
  out="$(
    set -a
    [[ -f "$dir/secret.env" ]] && . "$dir/secret.env"
    set +a
    export CREWAI_STORAGE_DIR="$dir/storage"
    cd "$dir/repo" && "$dir/venv/bin/python" "$dir/.crew_runner.py" "$entry" "$input" 2>&1
  )"; rc=$?
  ended="$(date -u +%FT%TZ)"
  if (( rc != 0 )); then
    printf '%s\n' "$out" >&2
    fail "$E_GENERIC" "crew '$name' kickoff failed (rc=$rc)"
  fi

  # Emit a co-signed work receipt (crew=from, runtime=to) over task/result hashes,
  # crew metadata as the signed x-crew extension. Feeds the ZeroHuman feed.
  local receipt_id="" receipt_status="skipped"
  if (( ! no_receipt )) && [[ -f "$dir/identity.json" && -f "$(_crew_runtime_identity)" ]]; then
    local rj
    rj="$(node "$dir/.emit-receipt.js" \
          --crew-identity="$dir/identity.json" \
          --runtime-identity="$(_crew_runtime_identity)" \
          --crew-name="$name" \
          --task="kickoff $entry @ $started" \
          --result="$out" \
          --at="$ended" \
          --ingest="$(_crew_ingest_url)" 2>/dev/null)" || true
    receipt_id="$(jq -r '.id // empty' <<<"$rj" 2>/dev/null)"
    receipt_status="$(jq -r '.status // "error"' <<<"$rj" 2>/dev/null)"
  fi

  step "crew '$name' done — receipt: ${receipt_status}${receipt_id:+ ($receipt_id)}"
  if (( JSON_MODE )); then
    ok "crew '$name' run complete" \
       '{name:$n, entry:$e, startedAt:$s, endedAt:$en, receipt:{status:$rs, id:($ri|if .=="" then null else . end)}, output:$o}' \
       --arg n "$name" --arg e "$entry" --arg s "$started" --arg en "$ended" \
       --arg rs "$receipt_status" --arg ri "$receipt_id" --arg o "$out"
  else
    printf '%s\n' "$out"
    ok "crew '$name' run complete (receipt: $receipt_status)"
  fi
}

# crew show <name> — install state (no secrets values, only which keys are set).
cmd_crew_show() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive crew show <name>"
  local dir; dir="$(_crew_dir "$name")"
  [[ -d "$dir" ]] || fail "$E_NOT_FOUND" "no crew '$name'"
  local keys="[]"
  [[ -f "$dir/secret.env" ]] && keys="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$dir/secret.env" | sed 's/=$//' | jq -R . | jq -sc .)"
  local meta; meta="$(cat "$dir/crew.json" 2>/dev/null || echo '{}')"
  if (( JSON_MODE )); then
    ok "" '($m + {name:$n, dir:$d, secretKeys:$k, hasStorage:$hs})' \
       --argjson m "$meta" --arg n "$name" --arg d "$dir" --argjson k "$keys" \
       --argjson hs "$([[ -d "$dir/storage" ]] && echo true || echo false)"
  else
    jq -r --arg n "$name" --arg d "$dir" --argjson k "$keys" '
      "crew: \($n)",
      "  repo:    \(.repo // "-")",
      "  entry:   \(.entry // "(unset)")",
      "  did:     \(.did // "(none)")",
      "  dir:     \($d)",
      "  secrets: \($k | join(", "))"
    ' <<<"$meta"
  fi
}

# crew list — installed crews on this box.
cmd_crew_list() {
  local base; base="$(_crew_base)"
  local -a names=()
  if [[ -d "$base" ]]; then
    local d
    for d in "$base"/*/; do [[ -f "$d/crew.json" ]] && names+=("$(basename "$d")"); done
  fi
  if (( JSON_MODE )); then
    ok "" '$n' --argjson n "$(printf '%s\n' "${names[@]:-}" | jq -R . | jq -sc 'map(select(.!=""))')"
  else
    if (( ${#names[@]} == 0 )); then echo "no crews installed (try: 5dive crew install <git-url> --as=<name>)"; else
      printf 'installed crews:\n'; printf '  %s\n' "${names[@]}"; fi
  fi
}

# crew uninstall <name> [--purge] — remove the crew. --purge also wipes its
# durable memory (storage) and secrets; without it those are kept for reinstall.
cmd_crew_uninstall() {
  local name="" purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=1 ;;
      --) shift; [[ -z "$name" && $# -gt 0 ]] && { name="$1"; shift; }; break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive crew uninstall <name> [--purge]"
  local dir; dir="$(_crew_dir "$name")"
  [[ -d "$dir" ]] || fail "$E_NOT_FOUND" "no crew '$name'"
  if (( purge )); then
    rm -rf "$dir"
    step "uninstalled + purged crew '$name' (repo, venv, memory, secrets all removed)"
  else
    # Keep storage (durable memory) + secret.env; remove code + venv + tooling.
    rm -rf "$dir/repo" "$dir/venv" "$dir/node_modules" "$dir/package.json" "$dir/package-lock.json" \
           "$dir/.crew_runner.py" "$dir/.emit-receipt.js" "$dir/.mint-identity.js" "$dir/crew.json"
    step "uninstalled crew '$name' (kept memory + secrets; --purge to wipe)"
  fi
  ok "uninstalled crew '$name'" '{name:$n, purged:($p=="1")}' --arg n "$name" --arg p "$purge"
}

# Write the python runner + node identity/receipt helpers into the crew dir. Kept
# as dotfiles next to the crew so each crew is self-contained and the bundle stays
# pure bash. The receipt helpers use @5dive/openagent for byte-identical signing.
_crew_write_helpers() {
  local dir="$1"

  cat > "$dir/.crew_runner.py" <<'PYEOF'
import sys, json, importlib
# argv: <module:Crew> [input-json-or-text]
spec = sys.argv[1]
raw  = sys.argv[2] if len(sys.argv) > 2 else ""
mod_name, _, attr = spec.partition(":")
mod = importlib.import_module(mod_name)
obj = getattr(mod, attr) if attr else None
# Resolve to a Crew instance: a CrewBase class (.crew()), a Crew, or a factory fn.
crew = None
if obj is None:
    for cand in ("crew", "Crew"):
        if hasattr(mod, cand):
            obj = getattr(mod, cand); break
if obj is None:
    print("crew_runner: could not resolve a Crew from %r" % spec, file=sys.stderr); sys.exit(2)
inst = obj() if callable(obj) else obj
crew = inst.crew() if hasattr(inst, "crew") else inst
inputs = {}
if raw:
    try: inputs = json.loads(raw)
    except Exception: inputs = {"input": raw}
result = crew.kickoff(inputs=inputs) if inputs else crew.kickoff()
# CrewOutput -> str
print(getattr(result, "raw", None) or str(result))
PYEOF

  cat > "$dir/.mint-identity.js" <<'JSEOF'
// Mint an ed25519 did:key keypair via @5dive/openagent (byte-compatible signing).
// argv: <out.json>
const fs = require("fs");
const crypto = require("crypto");
const out = process.argv[2];
if (fs.existsSync(out)) process.exit(0);
const r = require("@5dive/openagent/lib/receipts");
const { privateKey } = crypto.generateKeyPairSync("ed25519");
const priv = privateKey.export({ type: "pkcs8", format: "pem" });
// derive the did:key by signing a throwaway body and reading sig.by
const did = r.sign(r.buildReceipt({ taskHash: r.hash("init"), resultHash: r.hash("init"), fromDid: "did:x", toDid: "did:y", at: "1970-01-01T00:00:00Z" }), priv).by;
fs.writeFileSync(out, JSON.stringify({ did, priv }, null, 2), { mode: 0o600 });
console.log(did);
JSEOF

  cat > "$dir/.emit-receipt.js" <<'JSEOF'
// Build + co-sign a canonical work receipt (crew=from, runtime=to), crew metadata
// as the signed x-crew extension, and POST it to the ZeroHuman ingest endpoint.
// Flags: --crew-identity --runtime-identity --crew-name --task --result --at --ingest
const fs = require("fs");
const r = require("@5dive/openagent/lib/receipts");
function arg(n){ const p=`--${n}=`; const a=process.argv.find(x=>x.startsWith(p)); return a?a.slice(p.length):""; }
const crew = JSON.parse(fs.readFileSync(arg("crew-identity"), "utf8"));
const rt   = JSON.parse(fs.readFileSync(arg("runtime-identity"), "utf8"));
const body = r.buildReceipt({
  taskHash:   r.hash(arg("task")),
  resultHash: r.hash(arg("result")),
  fromDid:    crew.did,
  toDid:      rt.did,
  at:         arg("at"),
  title:      `crew run: ${arg("crew-name")}`,
});
body["x-crew"] = { crewId: arg("crew-name"), role: "crew", framework: "crewai", runtime: "5dive" };
const cosigned = r.cosign(body, crew.priv, rt.priv);
const v = r.verify(cosigned, { requireBoth: true });
if (!v.ok) { console.log(JSON.stringify({ status: "invalid", reason: v.reason })); process.exit(0); }
const ingest = arg("ingest");
(async () => {
  let status = "signed", id = "";
  try {
    const res = await fetch(ingest, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(cosigned) });
    if (res.ok) { status = "ingested"; try { id = (await res.json()).id || ""; } catch {} }
    else status = `signed (ingest ${res.status})`;
  } catch (e) { status = "signed (ingest unreachable)"; }
  console.log(JSON.stringify({ status, id, signers: v.signers }));
})();
JSEOF
}
