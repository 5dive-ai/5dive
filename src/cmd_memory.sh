# cmd_memory — queryable team memory, read-path (DIVE-726 Phase 1a).
#
# `5dive memory search "<query>"` ranks and returns the most relevant snippets
# from the agent's markdown memory stores, capped at a token ceiling, with source
# provenance. BM25-first (lexical) per the Phase 1a decision (lodar 2026-07-02):
# no embedding model, no new dependency, nothing leaves the box — the moat is the
# accumulated fleet history, retrieved not injected (flat, bounded context cost).
#
# Read-only (same posture as `usage` / `digest`): scans markdown files only, no
# registry mutation, no lock, no audit.
#
# Stores (default): the calling user's own memory dirs — every
#   ~/.claude/projects/*/memory/**.md
# plus the shared wiki (community/wiki) when present on this box (internal fleet).
# Cross-agent recall (reading another agent's store) is Phase 1b — gated on the
# group-readable-store decision — so Phase 1a stays single-agent + shared wiki.
#
# Usage:
#   5dive memory search "<query>" [--limit=N] [--max-tokens=T] [--roots=a,b,...]
#     --limit       max snippets to return (default 8)
#     --max-tokens  ceiling on total snippet tokens returned (default 1500)
#     --roots       comma-separated dirs to search (overrides the defaults)

_memory_usage() {
  cat >&2 <<'EOF'
5dive memory — queryable team memory

  5dive memory search "<query>" [--limit=N] [--max-tokens=T] [--roots=a,b]
                                [--store=all|mine|wiki] [--agent=<name>]
      Rank markdown memory snippets by relevance (BM25), newest-fleet-history
      first, capped at a token ceiling, with file+heading provenance.
      --store  all (default): own stores + shared wiki · mine: own stores only
               · wiki: shared wiki only
      --agent  search ANOTHER agent's store (per-user 0600 — root only; the
               shared path for cross-agent knowledge is the wiki)

  5dive memory add --name=<kebab-slug> --description="<one-liner>"
                   [--type=user|feedback|project|reference] [--store=mine|wiki]
                   [--tags=a,b] [--force]   (body on stdin)
      Compile a durable memory: writes a frontmatter markdown file into your
      own store (default) or the shared team wiki (--store=wiki, the publish
      path other agents can search), stamps provenance (who/when), appends the
      store's index line, and refuses token/key-shaped content (tripwire;
      --force does NOT bypass it). Existing file needs --force to overwrite.

  5dive memory doctor [--roots=a,b] [--agent=<name>] [--code-root=<dir>] [--json]
      Hygiene pass over the memory store(s): index drift (MEMORY.md vs files on
      disk), dangling [[wiki-links]], stale source refs (file:line no longer in
      the codebase), and near-duplicate memories. Also runs inside the
      `memory` category of `5dive doctor` for the whole box.

Searches the agent's own ~/.claude/projects/*/memory stores (+ the shared wiki
when present) unless --roots/--store/--agent narrow it.
EOF
}

# Root helpers (DIVE-897): own stores, another agent's stores, the shared wiki.
# Each emits a comma-separated list (may be empty).
_memory_own_roots() {
  # $1 (optional) = an agent short name — that agent's home instead of ours.
  # Per-user memory dirs are 0600, so another agent's store only resolves for
  # root; a non-root caller gets an empty list (the caller errors clearly).
  local base="$HOME" roots=() d
  if [ -n "${1:-}" ]; then
    base="/home/agent-$1"
    [ -d "$base" ] || base="/home/$1"   # the main `claude` user has no agent- prefix
  fi
  for d in "$base"/.claude/projects/*/memory; do
    [ -d "$d" ] && [ -r "$d" ] && roots+=("$d")
  done
  local IFS=,; echo "${roots[*]}"
}

_memory_wiki_root() {
  # Shared wiki (internal fleet only; absent on customer boxes — harmless).
  local d
  for d in "$HOME"/projects/5dive/community/wiki /home/claude/projects/5dive/community/wiki; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  echo ""
}

# Default search roots: own stores + wiki (the pre-scoping behavior).
_memory_default_roots() {
  local own wiki
  own=$(_memory_own_roots)
  wiki=$(_memory_wiki_root)
  if [ -n "$own" ] && [ -n "$wiki" ]; then echo "$own,$wiki"
  else echo "${own}${wiki}"
  fi
}

_memory_search() {
  local query="" limit=8 maxtok=1500 roots="" store="all" agent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit=*)      limit="${1#*=}" ;;
      --max-tokens=*) maxtok="${1#*=}" ;;
      --roots=*)      roots="${1#*=}" ;;
      --store=*)      store="${1#*=}" ;;
      --agent=*)      agent="${1#*=}" ;;
      -h|--help)      _memory_usage; return 0 ;;
      --*)            fail "$E_USAGE" "memory search: unknown flag: $1" ;;
      *)              [ -z "$query" ] && query="$1" || query="$query $1" ;;
    esac
    shift
  done
  [ -n "$query" ] || { _memory_usage; fail "$E_USAGE" "memory search: a query is required"; }
  command -v node >/dev/null 2>&1 || fail "$E_GENERIC" "memory search needs node on PATH"
  case "$store" in all|mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (all | mine | wiki)" ;; esac
  if [ -n "$roots" ] && { [ "$store" != "all" ] || [ -n "$agent" ]; }; then
    fail "$E_USAGE" "--roots overrides scoping — don't combine it with --store/--agent"
  fi
  # Scoping (DIVE-897): resolve roots from --store/--agent unless --roots wins.
  # --agent reads another agent's per-user store — 0600, so root only; the
  # sanctioned cross-agent path is the shared wiki (agents PUBLISH there via
  # `memory add --store=wiki`; private stores stay private, deny-by-default per
  # the DIVE-481 distillation-gate posture).
  if [ -z "$roots" ]; then
    local own="" wiki=""
    if [ -n "$agent" ]; then
      [ "$store" = "wiki" ] && fail "$E_USAGE" "--agent scopes a private store; it can't combine with --store=wiki"
      own=$(_memory_own_roots "$agent")
      [ -n "$own" ] || fail "$E_PERMISSION" "can't read agent '$agent''s memory store (per-user 0600 — run as root, or search the shared wiki instead)"
      [ "$store" = "all" ] && wiki=$(_memory_wiki_root)
    else
      [ "$store" != "wiki" ] && own=$(_memory_own_roots)
      [ "$store" != "mine" ] && wiki=$(_memory_wiki_root)
      [ "$store" = "wiki" ] && [ -z "$wiki" ] && fail "$E_NOT_FOUND" "no shared wiki on this box (community/wiki)"
    fi
    if [ -n "$own" ] && [ -n "$wiki" ]; then roots="$own,$wiki"; else roots="${own}${wiki}"; fi
  fi
  [ -n "$roots" ] || fail "$E_NOT_FOUND" "no memory stores found (looked in ~/.claude/projects/*/memory); pass --roots="

  local js; js="$(mktemp -t 5dive-memsearch.XXXXXX.mjs)" || fail "$E_GENERIC" "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f '$js'" RETURN
  cat > "$js" <<'MEMJS'
// DIVE-726 Phase 1a — BM25 lexical read-path over the markdown memory stores.
// Section-chunked (by md heading) for provenance; YAML frontmatter stripped with
// the description kept as each chunk's lead; token-ceilinged output. Zero deps.
import fs from "node:fs";
import path from "node:path";
const argv = process.argv.slice(2);
const query = argv.find((a) => !a.startsWith("--")) ?? "";
const opt = (k, d) => { const h = argv.find((a) => a.startsWith(`--${k}=`)); return h ? h.slice(k.length + 3) : d; };
const LIMIT = Number(opt("limit", 8));
const MAX_TOKENS = Number(opt("max-tokens", 1500));
const ROOTS = String(opt("roots", "")).split(",").filter(Boolean);
const estTokens = (s) => Math.ceil(s.length / 4);
const STOP = new Set("a an and are as at be but by for from has have if in into is it its of on or that the their then there these this to was were will with you your our we".split(" "));
const tokenize = (s) => s.toLowerCase().replace(/`[^`]*`/g, " ").replace(/[^a-z0-9]+/g, " ").split(" ").filter((t) => t.length > 1 && !STOP.has(t));
function mdFiles(root) {
  const out = [];
  const walk = (d) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) { const full = path.join(d, e.name); if (e.isDirectory()) walk(full); else if (e.isFile() && e.name.endsWith(".md")) out.push(full); }
  };
  walk(root); return out;
}
function chunk(file) {
  let text; try { text = fs.readFileSync(file, "utf-8"); } catch { return []; }
  const fm = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  let front = "";
  if (fm) { const desc = /^description:\s*["']?(.+?)["']?\s*$/m.exec(fm[1]); if (desc) front = desc[1].replace(/^>\s*/, "").trim(); text = text.slice(fm[0].length); }
  const lines = text.split("\n");
  const chunks = [];
  let cur = { heading: path.basename(file), body: [] };
  for (const line of lines) {
    const m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) { if (cur.body.join("").trim()) chunks.push(cur); cur = { heading: m[2].trim(), body: [] }; }
    else cur.body.push(line);
  }
  if (cur.body.join("").trim()) chunks.push(cur);
  return chunks.map((c, i) => { let t = c.body.join("\n").trim(); if (i === 0 && front) t = `${front}\n\n${t}`; return { file, heading: c.heading, text: t }; }).filter((c) => c.text.length > 0);
}
const docs = [];
for (const root of ROOTS) for (const f of mdFiles(root)) docs.push(...chunk(f));
if (!query) { console.error('usage: memory search "<query>"'); process.exit(2); }
if (docs.length === 0) { console.log("(no markdown found in the given roots)"); process.exit(0); }
const k1 = 1.5, b = 0.75;
const docTokens = docs.map((d) => tokenize(`${d.heading} ${d.text}`));
const avgdl = docTokens.reduce((s, t) => s + t.length, 0) / docTokens.length;
const df = new Map();
for (const toks of docTokens) for (const t of new Set(toks)) df.set(t, (df.get(t) ?? 0) + 1);
const N = docs.length;
const idf = (t) => Math.log(1 + (N - (df.get(t) ?? 0) + 0.5) / ((df.get(t) ?? 0) + 0.5));
const qToks = [...new Set(tokenize(query))];
const scored = docs.map((d, i) => {
  const toks = docTokens[i]; const tf = new Map();
  for (const t of toks) tf.set(t, (tf.get(t) ?? 0) + 1);
  let score = 0;
  for (const qt of qToks) { const f = tf.get(qt) ?? 0; if (!f) continue; score += idf(qt) * (f * (k1 + 1)) / (f + k1 * (1 - b + b * (toks.length / avgdl))); }
  return { ...d, score };
}).filter((d) => d.score > 0).sort((a, b) => b.score - a.score);
const home = process.env.HOME || "";
const rel = (f) => f.replace(`${home}/.claude/projects/`, "").replace(/^-home[^/]*\/memory\//, "memory/").replace(`${home}/projects/5dive/`, "").replace("/home/claude/projects/5dive/", "");
let used = 0, shown = 0;
console.log(`\n🔎 "${query}"  —  ${scored.length} hits across ${N} chunks / ${new Set(docs.map((d) => d.file)).size} files (BM25, ≤${MAX_TOKENS} tok)\n`);
for (const d of scored) {
  if (shown >= LIMIT) break;
  const snippet = d.text.length > 500 ? d.text.slice(0, 500) + " …" : d.text;
  const cost = estTokens(snippet);
  if (used + cost > MAX_TOKENS && shown > 0) break;
  used += cost; shown++;
  console.log(`[${d.score.toFixed(2)}] ${rel(d.file)}  ›  ${d.heading}`);
  console.log(snippet.split("\n").map((l) => "    " + l).join("\n"));
  console.log("");
}
console.log(`— shown ${shown}/${scored.length} hits, ~${used} tokens —`);
MEMJS
  node "$js" "$query" --limit="$limit" --max-tokens="$maxtok" --roots="$roots"
}

# memory add — the write/compile path (DIVE-897, DIVE-726 Phase 1b).
# Deterministic half of "compile before you close": the AGENT authors the body
# (that's LLM work, guided by the compile-knowledge skill); this command gives
# it one mechanical, provenance-stamped, tripwired way to persist it. Writing
# to --store=wiki is the PUBLISH path that makes a fact fleet-searchable —
# cross-agent recall happens by publishing here, never by opening the 0600
# per-agent stores (deny-by-default, same posture as the DIVE-481 gate).
_memory_add() {
  local name="" type="" desc="" store="mine" tags="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name=*)        name="${1#*=}" ;;
      --type=*)        type="${1#*=}" ;;
      --description=*) desc="${1#*=}" ;;
      --store=*)       store="${1#*=}" ;;
      --tags=*)        tags="${1#*=}" ;;
      --force)         force=1 ;;
      -h|--help)       _memory_usage; return 0 ;;
      *)               fail "$E_USAGE" "memory add: unknown arg: $1" ;;
    esac
    shift
  done
  [ -n "$name" ] || fail "$E_USAGE" "memory add: --name=<kebab-slug> is required"
  printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9-]{0,63}$' \
    || fail "$E_VALIDATION" "--name must be kebab-case, ≤ 64 chars"
  [ -n "$desc" ] || fail "$E_USAGE" "memory add: --description is required (it's what recall ranks on)"
  case "$store" in mine|wiki) : ;; *) fail "$E_VALIDATION" "bad --store '$store' (mine | wiki)" ;; esac
  if [ "$store" = "mine" ]; then
    [ -n "$type" ] || fail "$E_USAGE" "--type=user|feedback|project|reference is required for your own store"
    case "$type" in user|feedback|project|reference) : ;; *) fail "$E_VALIDATION" "bad --type '$type' (user | feedback | project | reference)" ;; esac
  fi
  [ -t 0 ] && fail "$E_USAGE" "memory add reads the body on stdin — pipe or heredoc it"
  local body; body=$(cat)
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || fail "$E_USAGE" "empty body on stdin — nothing to remember"

  # Secret tripwire (L3 posture, shared shape with cmd_pack's): refuse content
  # that looks like a live token/key. High-signal patterns only — memory notes
  # legitimately MENTION paths like .credentials.json, so the bare word is not
  # blocked (unlike the pack exporter, which stages whole files). --force does
  # not bypass this: a secret in a memory store outlives the session that knew
  # why it was there.
  if printf '%s\n%s' "$desc" "$body" | grep -qiE 'BOT_TOKEN=|API_KEY=|-----BEGIN|sk-[A-Za-z0-9]{8,}|[0-9]{8,}:[A-Za-z0-9_-]{30,}'; then
    fail "$E_VALIDATION" "the body looks like it contains a token/key (tripwire) — memories must reference where a secret LIVES, never its value"
  fi

  # Provenance: the pre-sudo invoker (agent short name or human login) + UTC date.
  local who="${SUDO_USER:-$(whoami)}"; who="${who#agent-}"
  local today; today=$(date -u +%F)

  local dir="" file="" index_file="" index_line=""
  if [ "$store" = "wiki" ]; then
    dir=$(_memory_wiki_root)
    [ -n "$dir" ] || fail "$E_NOT_FOUND" "no shared wiki on this box (community/wiki) — use --store=mine"
    [ -w "$dir" ] || fail "$E_PERMISSION" "wiki dir $dir is not writable by $(whoami)"
    file="$dir/$name.md"
    index_file="$dir/index.md"
    index_line="- [$name]($name.md) — $desc"
  else
    # Own store: prefer the dir that already has a MEMORY.md index, else the
    # first existing memory dir. No store yet = nothing bootstrapped this agent's
    # memory — that's the harness's job, don't invent a location.
    local d
    for d in "$HOME"/.claude/projects/*/memory; do
      [ -d "$d" ] || continue
      [ -z "$dir" ] && dir="$d"
      [ -f "$d/MEMORY.md" ] && { dir="$d"; break; }
    done
    [ -n "$dir" ] || fail "$E_NOT_FOUND" "no memory store found under ~/.claude/projects/*/memory"
    file="$dir/${type}_$(printf '%s' "$name" | tr '-' '_').md"
    index_file="$dir/MEMORY.md"
    index_line="- [$name]($(basename "$file")) — $desc"
  fi
  if [ -f "$file" ] && [ "$force" -ne 1 ]; then
    fail "$E_CONFLICT" "$(basename "$file") already exists — update it with --force, or pick a new --name"
  fi
  local existed=0; [ -f "$file" ] && existed=1

  if [ "$store" = "wiki" ]; then
    { printf -- '---\ntitle: %s\n' "$name"
      [ -n "$tags" ] && printf 'tags: [%s]\n' "$tags"
      printf 'updated: %s\ncompiled_by: %s\n---\n\n%s\n' "$today" "$who" "$body"
    } > "$file"
  else
    { printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n  compiled_by: %s\n  compiled_at: %s\n' \
        "$name" "$(printf '%s' "$desc" | sed 's/"/\\"/g')" "$type" "$who" "$today"
      [ -n "$tags" ] && printf '  tags: [%s]\n' "$tags"
      printf -- '---\n\n%s\n' "$body"
    } > "$file"
  fi
  # Index line (skip when updating in place, or when the index doesn't exist —
  # never invent a MEMORY.md/index.md the store's owner didn't set up).
  if [ "$existed" -eq 0 ] && [ -f "$index_file" ] && ! grep -qF "]($(basename "$file"))" "$index_file"; then
    printf '%s\n' "$index_line" >> "$index_file"
  fi

  if (( JSON_MODE )); then
    jq -nc --arg file "$file" --arg store "$store" --arg by "$who" --arg updated "$([ "$existed" -eq 1 ] && echo true || echo false)" \
      '{ok:true, data:{file:$file, store:$store, compiled_by:$by, updated:($updated=="true")}}'
  else
    echo "✓ compiled → $file${existed:+}"
    [ "$store" = "wiki" ] && echo "  published to the shared wiki — fleet-searchable via: 5dive memory search --store=wiki"
  fi
  return 0
}

# ---- memory hygiene (DIVE-991) ---------------------------------------------
#
# A runnable hygiene pass over one or more memory stores (per-agent stores +
# the shared wiki). Surfaces four classes of rot the karpathy-method stores
# accumulate as they grow:
#   - index-drift : MEMORY.md/index.md points at a file that no longer exists,
#                   OR a memory file on disk that the index never lists (a search
#                   miss — the index is what gets read into context each session).
#   - dangling-link : a [[wiki-link]] whose target slug matches no file in the
#                     store. Forward-references are legal (the memory rules bless
#                     them), so these are warnings, not errors — a nudge to write
#                     the stub or fix a typo'd slug.
#   - stale-ref : a memory citing a source path / file:line that no longer exists
#                 in the codebase (agent-main's bloated MEMORY.md is the live
#                 motivating case). Only checked when a --code-root to verify
#                 against is available, so we never cry wolf on customer boxes.
#   - near-dup : two memories in the same store with high token overlap — a
#                merge candidate (the rules say update-in-place, don't duplicate).
#
# The scan itself is a pure function of (code-root, store dirs) and lives in
# _memory_scan_json so both `5dive memory doctor` and `5dive doctor` (memory
# category) share one implementation. Python (a doctor-checked dep) does the
# parsing — bash regex over frontmatter + link graphs is a foot-gun.

# _memory_scan_json <code-root|""> <store-dir> [store-dir...]
# Emits a JSON array of {store,file,kind,severity,message} findings on stdout.
# code-root "" (or a missing dir) skips stale-ref verification.
_memory_scan_json() {
  local code_root="$1"; shift
  python3 - "$code_root" "$@" <<'PYEOF'
import os, re, sys, json

code_root = sys.argv[1]
stores = sys.argv[2:]

INDEX_NAMES = ("MEMORY.md", "index.md")
LINK_RE  = re.compile(r'\[\[([^\]|#]+)')                 # [[slug]] / [[slug|Label]] / [[slug#h]]
MDLINK_RE = re.compile(r'\]\(([^)\s]+\.md)\)')           # ](file.md)
# path-ish token: optional dirs + name + code extension, optional :line
# Extensions ordered longest-first and closed with a boundary so 'page.tsx'
# isn't truncated to 'page.ts' (nor 'plugin.json' to 'plugin.js') by the
# alternation matching a shorter prefix.
PATH_RE = re.compile(
    r'(?<![\w./@-])((?:[\w.-]+/)*[\w.-]+\.'
    r'(?:tsx|ts|jsx|mjs|cjs|json|js|yaml|yml|sh|py|go|rs|sql|toml|conf|env))'
    r'(?![A-Za-z0-9])(?::(\d+))?')
WORD_RE = re.compile(r'[a-z0-9]+')
PRUNE = {"node_modules", ".git", "dist", "build", ".next", "vendor",
         "coverage", ".venv", "__pycache__", ".turbo"}

# Prebuild a basename set from the code tree so a source ref counts as "exists"
# if the file lives anywhere in the repo (memories cite repo-relative paths from
# assorted cwds). Empty set => skip stale-ref checks entirely.
basenames = set()
if code_root and os.path.isdir(code_root):
    seen = 0
    for dp, dns, fns in os.walk(code_root):
        dns[:] = [d for d in dns if d not in PRUNE]
        for fn in fns:
            basenames.add(fn)
            seen += 1
        if seen > 400000:
            break

def split_front(text):
    """Return (name, mtype, body). name/mtype default to '' if absent."""
    name, mtype = "", ""
    body = text
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            fm = text[3:end]
            body = text[end + 4:]
            in_meta = False
            for ln in fm.splitlines():
                s = ln.strip()
                if s.startswith("name:"):
                    name = s[5:].strip().strip('"\'')
                elif s.startswith("metadata:"):
                    in_meta = True
                elif in_meta and s.startswith("type:"):
                    mtype = s[5:].strip().strip('"\'')
    return name, mtype, body

def slugs_of(fname, name):
    out = {os.path.splitext(fname)[0].lower()}
    if name:
        out.add(name.lower())
    return out

def ref_exists(store_dir, token):
    if os.path.isabs(token):
        return os.path.exists(token)
    if code_root and os.path.exists(os.path.join(code_root, token)):
        return True
    return os.path.basename(token) in basenames

findings = []
def add(store, f, kind, sev, msg):
    findings.append({"store": store, "file": f, "kind": kind,
                     "severity": sev, "message": msg})

def store_name(store):
    """Stable, agent-unique label: '<home-user>/<project-slug>' for per-user
    stores (…/home/<user>/.claude/projects/<slug>/memory), else the parent dir
    name. Avoids collisions when two agents share a project slug."""
    parts = store.rstrip("/").split("/")
    if ".claude" in parts:
        ci = parts.index(".claude")
        user = parts[ci - 1] if ci >= 1 else "?"
        slug = parts[-2] if len(parts) >= 2 else parts[-1]
        return f"{user}/{slug}"
    return parts[-2] if len(parts) >= 2 else parts[-1]

roster = []
for store in stores:
    if not os.path.isdir(store):
        continue
    sname = store_name(store)
    roster.append(sname)
    try:
        entries = sorted(os.listdir(store))
    except OSError:
        continue
    mem_files = [f for f in entries
                 if f.endswith(".md") and f not in INDEX_NAMES]
    index_file = next((n for n in INDEX_NAMES
                       if os.path.isfile(os.path.join(store, n))), None)

    all_slugs = set()
    docs = {}   # fname -> (name, mtype, body, wordset)
    for f in mem_files:
        try:
            with open(os.path.join(store, f), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        name, mtype, body = split_front(text)
        all_slugs |= slugs_of(f, name)
        docs[f] = (name, mtype, body, set(WORD_RE.findall(body.lower())))

    # --- index drift ---
    if index_file:
        try:
            with open(os.path.join(store, index_file), encoding="utf-8", errors="replace") as fh:
                idx = fh.read()
        except OSError:
            idx = ""
        indexed = {os.path.basename(t) for t in MDLINK_RE.findall(idx)}
        for t in sorted(indexed):
            if t not in INDEX_NAMES and not os.path.isfile(os.path.join(store, t)):
                add(sname, t, "index-drift", "error",
                    f"{index_file} links '{t}' but the file is missing")
        for f in mem_files:
            if f not in indexed:
                add(sname, f, "index-drift", "warn",
                    f"on disk but not listed in {index_file} (won't load into context)")

    # --- dangling links + stale refs ---
    for f, (name, mtype, body, words) in docs.items():
        for m in LINK_RE.findall(body):
            target = m.strip().lower()
            if target and target not in all_slugs:
                add(sname, f, "dangling-link", "warn",
                    f"[[{m.strip()}]] resolves to no file in this store")
        if basenames:
            checked = set()
            for tok, _line in PATH_RE.findall(body):
                if tok in checked or tok.startswith(("http", "@")):
                    continue
                checked.add(tok)
                if ("/" in tok or f"{tok}:" in body) and not ref_exists(store, tok):
                    add(sname, f, "stale-ref", "warn",
                        f"cites '{tok}' which no longer exists in the codebase")

    # --- near-duplicate (Jaccard over body word-sets, same store) ---
    names = list(docs)
    for i in range(len(names)):
        wi = docs[names[i]][3]
        if len(wi) < 12:
            continue
        for j in range(i + 1, len(names)):
            wj = docs[names[j]][3]
            if len(wj) < 12:
                continue
            inter = len(wi & wj)
            if not inter:
                continue
            jac = inter / len(wi | wj)
            if jac >= 0.6:
                add(sname, names[i], "near-dup", "warn",
                    f"{int(jac*100)}% token overlap with '{names[j]}' — merge candidate")

json.dump({"stores": roster, "findings": findings}, sys.stdout)
PYEOF
}

# _memory_doctor — `5dive memory doctor`: run the hygiene scan over the caller's
# own stores + wiki (or --roots / --agent), printing a report or --json.
_memory_doctor() {
  local roots="" agent="" code_root="${MEMORY_DOCTOR_CODE_ROOT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --roots=*)     roots="${1#*=}" ;;
      --agent=*)     agent="${1#*=}" ;;
      --code-root=*) code_root="${1#*=}" ;;
      -h|--help)     _memory_usage; return 0 ;;
      *)             fail "$E_USAGE" "memory doctor: unknown arg: $1" ;;
    esac
    shift
  done
  if [ -z "$roots" ]; then
    local own wiki
    own=$(_memory_own_roots "$agent")
    wiki=$(_memory_wiki_root)
    if [ -n "$own" ] && [ -n "$wiki" ]; then roots="$own,$wiki"
    else roots="${own}${wiki}"; fi
  fi
  [ -n "$roots" ] || fail "$E_NOT_FOUND" "no memory stores found (looked in ~/.claude/projects/*/memory); pass --roots="
  # Default code-root for stale-ref checks: the 5dive monorepo if it's here.
  if [ -z "$code_root" ]; then
    for d in /home/claude/projects/5dive "$HOME/projects/5dive"; do
      [ -d "$d" ] && { code_root="$d"; break; }
    done
  fi

  local dirs=() IFS=,
  for d in $roots; do [ -n "$d" ] && dirs+=("$d"); done
  unset IFS
  local scan
  scan=$(_memory_scan_json "$code_root" "${dirs[@]}")
  [ -n "$scan" ] || scan='{"stores":[],"findings":[]}'
  local findings
  findings=$(jq -c '.findings' <<<"$scan")

  if (( JSON_MODE )); then
    jq -cn --argjson f "$findings" --argjson stores "$(jq -c '.stores' <<<"$scan")" '{ok:true, data:{
      stores_scanned: ($stores | length),
      findings: $f,
      summary: ($f | {
        total: length,
        errors: [.[]|select(.severity=="error")]|length,
        warnings: [.[]|select(.severity=="warn")]|length,
        by_kind: (group_by(.kind) | map({(.[0].kind): length}) | add // {})
      })
    }}'
    return 0
  fi

  local n
  n=$(jq 'length' <<<"$findings")
  if [ "$n" -eq 0 ]; then
    echo "✓ memory hygiene: no issues across ${#dirs[@]} store(s)"
    return 0
  fi
  jq -r '
    group_by(.store) | .[] as $g |
    "── \($g[0].store) ──",
    ($g | sort_by(.kind)[] | "  [\(.severity)] \(.kind)  \(.file): \(.message)"),
    ""
  ' <<<"$findings"
  jq -r '{
    total: length,
    errors: [.[]|select(.severity=="error")]|length,
    warnings: [.[]|select(.severity=="warn")]|length
  } | "summary: \(.total) findings, \(.errors) error, \(.warnings) warn"' <<<"$findings"
  return 0
}

# cmd_memory — dispatch for the `memory` subcommand tree.
cmd_memory() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    search)      _memory_search "$@" ;;
    add|compile) _memory_add "$@" ;;
    doctor|hygiene) _memory_doctor "$@" ;;
    ""|-h|--help) _memory_usage ;;
    *)           _memory_usage; fail "$E_USAGE" "memory: unknown subcommand: $sub" ;;
  esac
}
