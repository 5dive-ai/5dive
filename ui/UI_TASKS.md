# 5dive Local UI — Tasks

Bringing the open-source dashboard UI to flagship quality and full CLI coverage.
Tasks are ordered by impact. Work through them sequentially.

---

## T01 · App shell — sidebar nav + layout  ✅ DONE
The current single-column layout with a sticky header is very basic.
Flagship uses a collapsible left sidebar with nav items, dark/light theme toggle,
and a content area.

**Changes:**
- Replace sticky header with a left sidebar (collapsible, 220px expanded / 56px icon-only)
- Nav items: Agents, Accounts, Health (doctor)
- Persist collapsed state to `localStorage`
- Content area takes remaining width with proper scroll
- Keep logo + "local" badge in sidebar header

---

## T02 · Toast notification system  ✅ DONE
Currently zero feedback after actions (create, start, stop, delete). The flagship uses
toasts for all mutations.

**Changes:**
- Lightweight toast hook (no external dep — just a state array + portal div)
- Show success/error toasts after all API calls
- Auto-dismiss after 4s; closeable
- Position: bottom-right

---

## T03 · Agent card redesign  ✅ TODO
Current cards don't match flagship agent rows.

**Changes:**
- Provider/type icon in a rounded square (already there but needs sizing polish)
- Status dot inline with name (already there — verify sizing)
- Show `workdir` as a secondary line when it's not the default path
- Show channel icon + handle (botUsername for telegram, already partially there)
- Show account/auth-profile if not default
- Hover: actions slide in from right (already there — verify opacity transition)
- Active agents: subtle left border accent in `--color-signal`

---

## T04 · Skeleton loaders  ✅ DONE
Blank flash while agents load looks broken.

**Changes:**
- 3 placeholder skeleton rows while `agents === null` (initial load)
- Pulse animation using `animate-pulse` on rounded rectangles
- Replace the current spinner-based loading in App.tsx

---

## T05 · Agent detail — full tab set  ✅ DONE
Current AgentDetail only has Logs + Stats tabs. Need Config and (for Telegram agents) Pair tab.

**Changes (new tabs):**
- **Config tab**: editable fields — workdir, channels (dropdown), telegram token, account/auth-profile, allowed-users. Submit calls `POST /api/agents/:name/config` with `{key, value}`.
- **Pair tab** (visible when channels=telegram/discord): show pairing status, QR-style link, trigger `POST /api/agents/:name/pair`, poll for completion.
- **Send tab**: free-text input to `POST /api/agents/:name/send`. Show last 5 sent messages in a mini history.
- Improve Logs tab: add Follow toggle that streams via existing SSE endpoint.

---

## T06 · Create modal — advanced options  ✅ TODO
Current wizard is step 1 (config) + step 2 (auth). Several important options are missing.

**Changes to Step 1:**
- **Workdir** field (optional, defaults shown as placeholder `/home/claude/projects`)
- **Skills** checkbox: "Auto-inherit skills" on by default (passes `--with-skills=5dive-cli` when creating claude agents from here). Advanced: text field for custom skill spec.
- **Auth profile** dropdown — populated from `GET /api/accounts` (T09 adds that endpoint). Defaults to `default`.
- For **hermes** / **openclaw**: show Provider dropdown (`openrouter`, `anthropic`, `openai`, etc.) + API key field in Step 2 instead of generic key input.
- **Defer auth** checkbox — creates the agent without auth gate (uses `--defer-auth`).

---

## T07 · Clone agent  ✅ DONE
Not exposed at all. Simple modal: source name (read-only pre-filled from context), new name, optional channel override.

**Changes:**
- "Clone" action in agent card dropdown menu
- `CloneAgentModal` component — name input + optional channel dropdown
- `POST /api/agents/:name/clone` endpoint in server.ts → calls `5dive agent clone`

---

## T08 · Ask / sync send  ✅ DONE
`agent ask` is "send + wait for reply" — a powerful capability not in the UI.

**Changes:**
- In the Send tab (T05): toggle between "Send" (fire-and-forget) and "Ask" (sync, waits for reply)
- Ask calls `POST /api/agents/:name/ask` which streams the reply via SSE or returns after completion
- Show reply inline below the input

---

## T09 · Accounts page  ✅ DONE
Account management (`5dive account *`) is entirely missing.

**New page:** `/accounts` in sidebar nav

**Changes:**
- `GET /api/accounts` → `5dive account list --json`
- `GET /api/accounts/:name` → `5dive account show --json`
- `POST /api/accounts` → `5dive account add`
- `DELETE /api/accounts/:name` → `5dive account remove`
- `PATCH /api/accounts/:name` → `5dive account rename`
- UI: table of accounts with name, types signed in, # bound agents
- Account detail: show which env keys are present, bound agents list
- "Add account" button — name input only (auth is done separately via auth flow)
- OAuth / API-key auth flow per type within an account (reuses CreateAgentModal auth step logic)

---

## T10 · Health / Doctor page  ✅ DONE
`5dive doctor` checks deps, type bins, auth probes, registry — entirely missing from UI.

**New page:** `/health` in sidebar nav

**Changes:**
- `GET /api/doctor` already exists in server.ts — just needs a UI
- Show summary badge: ✓ healthy / ⚠ N warnings / ✗ N errors
- Expandable check list: dep name, status icon, message
- "Run repair" button → `POST /api/doctor/repair` → `5dive doctor --repair`
- Auto-refresh every 30s

---

## T11 · Install missing type CLI  ✅ DONE
When `5dive doctor` reports a type binary is missing, let user fix it in one click.

**Changes:**
- Doctor page: "Install" button next to each missing type
- `POST /api/agent/install/:type` → `5dive agent install <type>`
- Stream install output via SSE

---

## T12 · Telegram access management  ✅ DONE
`telegram-access get/set` + `telegram-discover` flow for pairing.

**Changes (extends T05 Pair tab):**
- Show current `dmPolicy`, `allowFrom` list, group settings
- Add/remove allowed users by Telegram user ID
- "Auto-discover" button — calls `POST /api/agents/:name/telegram-discover` which polls until first inbound message, then auto-pairs

---

## T13 · Mobile / responsive layout  ✅ DONE
Current layout is desktop-only. Flagship has a bottom tab bar on mobile.

**Changes:**
- Sidebar collapses to off-canvas drawer on `<768px`
- Hamburger toggle in top bar
- Agent cards stack cleanly at narrow widths
- Modal full-screen on mobile

---

## Execution order

1. T01 – shell (everything else sits inside it)
2. T02 – toasts (used by every subsequent task)
3. T03 + T04 – card polish + skeletons
4. T05 – agent detail tabs
5. T06 – create modal advanced options
6. T07 – clone
7. T09 – accounts page
8. T10 + T11 – health page + install
9. T08 – ask/send
10. T12 – telegram access
11. T13 – mobile

---

## Server endpoints needed (summary)

| Endpoint | Method | CLI command |
|---|---|---|
| /api/agents/:name/clone | POST | `agent clone <src> <dst>` |
| /api/agents/:name/config | POST `{key,value}` | `agent config <name> set key=value` |
| /api/agents/:name/pair | POST | `agent pair <name>` |
| /api/agents/:name/pair | GET | `agent pair <name>` status |
| /api/agents/:name/ask | POST `{text}` | `agent ask <name> <text>` |
| /api/agents/:name/telegram-access | GET | `agent telegram-access get` |
| /api/agents/:name/telegram-access | POST | `agent telegram-access set` |
| /api/agents/:name/telegram-discover | POST | `agent telegram-discover` |
| /api/accounts | GET | `account list` |
| /api/accounts | POST | `account add` |
| /api/accounts/:name | GET | `account show` |
| /api/accounts/:name | DELETE | `account remove` |
| /api/accounts/:name | PATCH `{name}` | `account rename` |
| /api/doctor | GET | `doctor` (already exists) |
| /api/doctor/repair | POST | `doctor --repair` |
| /api/agent/install/:type | POST | `agent install <type>` |
