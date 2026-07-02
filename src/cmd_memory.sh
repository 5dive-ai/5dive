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
5dive memory — queryable team memory (read-path)

  5dive memory search "<query>" [--limit=N] [--max-tokens=T] [--roots=a,b]
      Rank markdown memory snippets by relevance (BM25), newest-fleet-history
      first, capped at a token ceiling, with file+heading provenance.

Searches the agent's own ~/.claude/projects/*/memory stores (+ the shared wiki
when present) unless --roots overrides.
EOF
}

# Compute the default search roots: the calling user's memory dirs + the shared
# wiki if it exists on this box. Emits a comma-separated list (may be empty).
_memory_default_roots() {
  local roots=() d
  for d in "$HOME"/.claude/projects/*/memory; do
    [ -d "$d" ] && roots+=("$d")
  done
  # Shared wiki (internal fleet only; absent on customer boxes — harmless).
  for d in "$HOME"/projects/5dive/community/wiki /home/claude/projects/5dive/community/wiki; do
    [ -d "$d" ] && { roots+=("$d"); break; }
  done
  local IFS=,; echo "${roots[*]}"
}

_memory_search() {
  local query="" limit=8 maxtok=1500 roots=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit=*)      limit="${1#*=}" ;;
      --max-tokens=*) maxtok="${1#*=}" ;;
      --roots=*)      roots="${1#*=}" ;;
      -h|--help)      _memory_usage; return 0 ;;
      --*)            fail "$E_USAGE" "memory search: unknown flag: $1" ;;
      *)              [ -z "$query" ] && query="$1" || query="$query $1" ;;
    esac
    shift
  done
  [ -n "$query" ] || { _memory_usage; fail "$E_USAGE" "memory search: a query is required"; }
  command -v node >/dev/null 2>&1 || fail "$E_GENERIC" "memory search needs node on PATH"
  [ -n "$roots" ] || roots="$(_memory_default_roots)"
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

# cmd_memory — dispatch for the `memory` subcommand tree.
cmd_memory() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in
    search)      _memory_search "$@" ;;
    ""|-h|--help) _memory_usage ;;
    *)           _memory_usage; fail "$E_USAGE" "memory: unknown subcommand: $sub" ;;
  esac
}
