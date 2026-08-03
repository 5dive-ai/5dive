# Changelog

## Unreleased — feat(a2a): stamp `via=` when the claimed sender and the measured caller diverge (DIVE-2552)

Every `[5dive-msg ...]` stamp site already held both values and never compared them:

```bash
sender="$from"                       # CLAIMED  — from --from=, format-validated only
_caller="$(_envelope_caller)"        # MEASURED — EUID-first, not settable by a flag
_tier="$(envelope_tier "$_caller")"  # ...the measured one was used for tier=, and nothing else
```

So `5dive agent send X --from=marcus`, run by dev, rendered
`[5dive-msg from=marcus id=... tier=admin]` — byte-for-byte identical to a send marcus
actually made. `tier=` does not catch it: DIVE-1064/2210 built that field against a
**cross-tier** peer, and dev and marcus are both `admin`, so the unforgeable field agrees
with the forged one and corroborates it.

Now the two are compared at all three acceptors (`send`, `ask`, `_deliver`) and the result
is stamped:

```
[5dive-msg from=marcus id=… tier=admin]                              marcus really sent it
[5dive-msg from=marcus id=… tier=admin via=dev]                      dev asserted --from=marcus
[5dive-msg from=marcus id=… tier=unknown:no-caller via=unknown:no-caller]   nothing measured the claim
```

Not a refusal, deliberately: rejecting a `--from` that is not the caller breaks the
legitimate synthetic-label senders (`loop`, `task-engine`, `council`, `verifier`, `ask`,
`comment-watch`, `blocker-push`, `community-heartbeat`), none of which are agent names.
The marker keeps them working and hands the receiver the fact instead.

`via=` is absent on the ordinary path, and absence is itself a measurement — it is
produced by exactly one branch (measured, and the claim matched). Every path that could
not measure stamps a reason (`unknown:no-caller`, `unknown:malformed-caller`) rather than
nothing, which is DIVE-2210's property carried onto the new field. Reading the output:
absence of `via=` means "built before this release" **or** "the claim matched" — it does
not mean "unchecked".

`via=` is exactly as trustworthy as `tier=` and no more: both come from the same
EUID-first `_envelope_caller` resolver.

## Unreleased — fix(push): resolve the App installation PER REPO, not from one pinned id (DIVE-2563)

`_push_do` minted every installation token against a single `GITHUB_APP_INSTALLATION_ID`
read from `github-app.env`. A GitHub App gets a **separate installation per account**
it is installed on, and the token exchange refuses any repository outside the
installation it is addressed to — with a message that names the *repository*
(`There is at least one repository that does not exist or is not accessible to the
parent installation`), so it reads as a missing repo rather than a wrong installation.

Measured 2026-08-03: the App's only installation is the **5dive-ai org** (20 repos, all
`5dive-ai/*`), while `5dive-api` and `5dive-frontend` live under a **personal account**.
So `5dive-ai/5dive` pushed fine and every customer-facing repo 422'd — and had since the
rail was built. Pinning also means installing the App on the second account would *not*
fix it alone: that mints a second installation id and the box would keep addressing the
first.

`_push_do` now asks `GET /repos/{owner}/{repo}/installation` which installation owns the
target repo, and falls back to the pinned id when the lookup cannot answer — so a box
with one installation behaves exactly as before.

Two supporting fixes in the same block:

- **The refusal carries GitHub's own words.** `curl -fsS` prints nothing on a 4xx, so the
  mint failure rendered as a bare `installation token exchange failed` and the operator
  had to re-run the call by hand to learn the cause (DIVE-2143). It now reports the API
  `message` and names the owner the App is probably missing from.
- **`slug` is assigned before the lookup reads it.** The first cut of this change
  referenced it 40 lines above its assignment, which expands to empty and silently
  queries `/repos//installation` — a lookup that cannot fail loudly. `push_unit` pins
  the ordering, not just the presence.

This is the **code** half. Pushing to a repo on another account still requires the App to
be installed there; that is a human step, tracked separately.

`tests/push_unit.sh` 89 → 92 arms.

## Unreleased — fix(push): the workflow-scope probe fetched unauthenticated, so every private-repo push demanded `workflows:write` (DIVE-2547)

`_push_touches_workflows` decides whether a delegated push needs `workflows:write`
on top of `contents:write`. It ranged the branch by running `git fetch <repourl>`
with **no credential**. Against a private repo that can never succeed, so the probe
returned `unknown` and the caller escalated the token request — on every push, to
every private repo, forever. A probe that never measures anything is not insurance;
it is a permanently over-scoped token minted by a check that always abstains, which
is the exact inversion of the one-permission scope DIVE-1460 exists to hold.

It also did not degrade gracefully: the App is not granted `workflows:write`, so the
defensive request **422s** and the push fails *after* a human already cleared the
gate. Measured 2026-08-03, it blocked three agents across three repos — dev on
`lodar/5dive-api` (DIVE-1999) and `lodar/5dive-frontend` (DIVE-2535), dev2 on
`lodar/5dive-api` (DIVE-2033).

The probe now degrades to the **cached** remote-tracking ref, exactly as the author
scan one function over already did (DIVE-2161: *resolve the bound, degrade to a
cached bound and say it may be stale, or refuse and name what is missing*). The same
lesson was learned here and never applied.

The staleness is safe in the direction that matters: `base...branch` reports what the
branch *adds*, so an older base widens the range and can only over-report touched
files. It can turn a `no` into a `yes` (request a scope we did not need) but never a
`yes` into a `no` (push a workflow change under `contents:write` alone). Only when
neither a live nor a cached bound resolves is the answer still `unknown`.

`tests/push_unit.sh` 86 → 89 arms: the cached fallback measures `no` on a code-only
branch, still catches a workflow-touching branch, and names its own staleness on
stderr. The both-bounds-missing path still returns `unknown`.

## Unreleased — feat(actor): `5dive whoami`, one sealed actor derivation (DIVE-2517)

The CLI had **six** actor derivations and they disagreed. Only one failed closed;
the rest resolved identity from something the caller can set — `--from` on argv,
`$USER`, `$SUDO_USER`, `FIVEDIVE_AUDIT_USER`, or an `agent-` username prefix —
and none of them refused when they could not measure.

`src/lib/actor.sh` promotes the uid-first resolver into the single derivation.
Identity comes from `$EUID`, a kernel-backed bash builtin, mapped through
`/etc/passwd` in pure bash — no `id`, no `getent`, both of which resolve through
the caller's `PATH` (DIVE-2330). `$SUDO_UID` is honoured only at real EUID 0,
where forging it would require already being root. Agent-ness is the registry's
answer, never a username prefix. Authority is not redefined here: `_actor_authority`
in `lib/audit.sh` already single-sources `root` / `sudo:<who>` / `self`, and the
verb wires it.

`5dive whoami` reports actor, authority and tier **with the source of each**, plus
`--json`. An actor it cannot measure is an **exit 6**, not the word `unknown`
printed with `rc=0` — that refusal is the point of the verb, and it is
mutation-graded rather than asserted.

## Unreleased — feat(task): merge-audit LABELS findings delivered-vs-cited, and never filters them (DIVE-1975)

DIVE-1965 taught the merge *gate* to tell "I shipped this PR" from "I am writing about this PR",
and to skip the second. `task merge-audit` is the same predicate over the same data feeding a
different consumer, and it never learned the split: the retrospective sweep still reported a PR
that a done task merely CITED as if it were that task's own unmerged work.

Every finding now carries `delivered` or `cited`, in the columns and in `--json` (`origin` per row,
plus `delivered` / `cited` totals in the summary). Nothing is dropped.

The label is the whole change, and the refusal to filter is the load-bearing half. A blocking gate
and a non-blocking sweep want OPPOSITE safe defaults on the same predicate. The gate blocks a
close, so over-judging stalls the fleet and its default is CITED with delivery asserted. The sweep
blocks nothing and a human reads it, so over-reporting costs one line to dismiss while
under-reporting hides real unmerged work. Filtering to "delivered only" would rebuild the
blindness DIVE-1955 existed to remove, one layer down and harder to see: the sweep would come back
clean while the work it was built to find sat unmerged behind a maker's phrasing. DIVE-1965's own
known coverage seam, an own delivery phrased outside the shipping-verb vocabulary, lands exactly
there.

Two deliberate widenings of `delivered`, both harmless because nothing is dropped: the
`delivery_ref` column folds in (it never reaches the gate's prose classifier, but a bound
delivery_ref is the strongest delivery assertion there is), and the audit row arrives with
newlines collapsed, so the classifier's line-scoping degrades to text-scoping.

Seven arms added to `tests/task_merge_gate_delivered_vs_cited_unit.sh` (39 total), each
differential on the same PR number in the same repo so a hardcoded label fails at least one.
Graded by mutation: always-cited, always-delivered, filter-cited-out, and drop-the-column each
turn arms red.

## Unreleased — feat(broker): generalize the capability broker and fold in delegated deploy (INST-5)

`5dive push` was our only brokered capability: a dangerous action an agent can take without ever
holding a credential, gated on a cleared human/lead decision and executed atomically as root.
INST-5 asked to extend that template to the next surfaces — email, deploy, DNS, payments, secrets,
data-export. This lands the primitive and the first new surface.

The counterintuitive part is which half of delegated push generalizes. Its headline security
property is a repo-SCOPED, SHORT-LIVED token minted per use, and that half does NOT port: it
exists only because GitHub Apps expose a mint-on-demand API we can drive from the control plane.
Measured against our own Vercel credential, `POST /v3/user/tokens` returns HTTP 403 — there is no
equivalent to drive. Defining the broker as "it mints scoped short-lived credentials" would put
five of six surfaces out of scope by definition. The portable contract is the part that reads as
plumbing: a policy predicate plus a target binding, feeding a root-only single-action executor
that takes its parameters on stdin, feeding an audit record and a capability row.

`src/lib/broker.sh` holds that, surface-agnostic, plus the one surface table the sudoers policy,
the capability registry and every refusal string now derive from. `_push_gate_check` and
`_push_bind_branch` become one-line bindings of it, and the move is proven inert rather than
asserted to be: `tests/broker_surface_unit.sh` runs both the new and the pre-refactor
implementations over the same 13 fixture states and compares refusal text and exit status byte for
byte.

`5dive deploy <task>` is the first new executor. It deploys only the `Deploy: <project>@<ref>` the
task itself declares, only after that task's gate clears, with `VERCEL_TOKEN` read root-only and
never handed to the agent. It also gets a bound push does not have: the git repo is not a
parameter — it is read from the Vercel project's own link, so a granted agent cannot point one of
our projects at a repo it chose. The capability is a separate axis from `--can-push`
(`agent create --can-deploy`), because shipping a branch for review and shipping to production are
different authorities.

## Unreleased — fix(task): refuse a close that would REPLACE an already-closed row's result (DIVE-2464)

`5dive task done <id> --result=...` on a row that was already done overwrote the result column and
said nothing about it — no warning, no refusal, no merge, exit 0. It happened on DIVE-2451: one
agent closed at 21:08:59, another closed again at 21:11:43, and the first record was gone from the
board. The ledger does not cover this. `5dive trace` shows both `task.done` events with an
authority envelope and an `out:` field, but that field is a sha256 *of* the result, not the text —
it proves the record changed and cannot restore it. An integrity hash is not a backup. What
actually recovered the text was a `/var/lib/5dive/tasks-backups/` snapshot that happened to fall
between the two writes; a 3-minute window landing inside a 5-minute cron is luck, not a path.

The check has to live in the verb. "Read the status first" was already being done — the
overwriting invocation printed the row's status in the same call as the write, so the read could
not gate anything. DIVE-2067 had fixed exactly this clobber in `task verify`; `task done` was left
unguarded, and the DIVE-2007 guard above it deliberately falls through for closed rows because "a
repeat done stays idempotent" — true of the status write, false of the result write.

A close (`done` or `cancel`) that lands on an already-closed row carrying a result is now refused,
naming the close timestamp and the row's recorded holders, and pointing at `5dive trace` for the
actor the row itself does not store. Two flags answer it. `--append-result` is the common
legitimate case — a maker closes, then the owner of the other half adds theirs — and keeps the
prior text verbatim and first, with the addition beneath it. `--force-result` replaces, warns on
stderr, and writes the overwritten text (not its hash) to the audit log.

The guard is deliberately narrow, so nothing idempotent changed: it fires only when `--result=`
was actually passed, the stored result is non-empty, and the new text differs. A bare re-close, a
replay with identical text, an empty prior result, and any first close of an open row all behave
exactly as before.

A second change was needed, and review is what found it: the DIVE-477 verifier-routing branch
`return`s early and does its own unconditional result write, so on a row where `verifier` is set
and differs from `assignee` the guard was never reached at all and the clobber survived — plus
`_task_route_to_verifier` sets `status='todo'`, so a closed row was also **resurrected** and
re-delivered. A closed row is now stopped from routing in the first place, which is right on its
own merits, and the guard sits above that branch.

Their division of labour was measured by mutating each independently rather than assumed, and the
answer is not the intuitive one: removing the routing exclusion reds only the resurrection arms,
while reverting the guard's position reds **nothing** — the exclusion subsumes the ordering for
the result clobber. So no test arm pins the block's position; it is kept as defence-in-depth and
said so in the source rather than presented as coverage. The resurrection is a separate harm, not
a second symptom: it fires on a bare re-close where there is no result to protect.

Two adjacent clobbers on the same column are **not** fixed here and are named rather than left to
be discovered: `task deliver --result=` over a closed row (DIVE-2476), and
`_task_route_to_verifier` writing over an **open** row's existing result.

`tests/task_done_over_closed_result_unit.sh` — 29 arms. Checked against the pristine tree: the
defect (prior result destroyed) reproduces there, and the idempotence and DIVE-477-still-routes
arms pass on both trees, which is what makes them regression guards rather than evidence for the
fix.

## Unreleased — fix(release-cut): move the nightly off the contended top-of-hour and poll for CI to settle (DIVE-2466)

The nightly cut has never once run on time. `- cron: '0 3 * * *'` was byte-identical across all six
revisions of this file, and the top of the hour is the slot GitHub documents as worst for
`schedule` — it delays under load and sometimes drops. Both of our schedule runs started ~2h45m
late (05:43:31 and 05:47:58) and the third night produced no run at all.

That delay also silently voided the slot's own stated rationale: the comment justified 03:00 as
"an hour ahead of the fleet's 04:00 self-update, so a nightly cut is available to the boxes that
same night", and at +163 min the cut landed *after* the fleet had already updated. The reason for
the slot had never held in practice. It now runs at 02:37 with a 03:43 re-arm for the dropped-run
case — safe by construction rather than by a new guard, since the job already exits 0 early when
the incumbent tag was cut from main's current tip, and the existing `concurrency` group means the
re-arm cannot race the primary.

Second arm: the CI verdict polled instead of refusing on the first look. A nightly landing while
CI on the newest merge is still running used to skip the whole day, leaving every box on the
previous tag for 24h. It now re-reads the check-runs every 60s up to a 45-minute ceiling. The
fail-closed property is untouched and only the number of looks changed — RED still refuses
immediately and is never waited out, an expiry still exits non-zero with the same two messages,
and absence of check-runs is still never green. The `CI NOT REACHED` branch is included for the
same reason, and it was the easy one to miss: its own error text told a human to "let it complete,
then re-run this job", which is exactly the retry the job declined to do itself.

The poll budget is a hardcoded ceiling the env knob can only tighten; a larger or non-numeric
value falls back to the ceiling. `tests/release_cut_guards_unit.sh` grows from 23 to 37 assertions,
driving the extracted block with a stubbed fetch that returns a different board per look, plus a
mutant that drops the re-read and must turn the in-flight-then-green arm red.

## Unreleased — fix(release): the release page says WHAT shipped, and the tag stamps the CHANGELOG (DIVE-2452)

Every release published a body describing how it was cut. v0.17.9 carried 256 characters of
dispatch reason for 76 commits; v0.17.0 and v0.17.1 were the same shape. `gh release create` was
passed `--notes "${note}"`, and `note` is the cut reason.

The body is now derived from the git range: the lines CHANGELOG.md gained between the commit the
incumbent tag was cut from and the commit being cut, falling back to commit subjects grouped by
type, and **refusing the release page** if neither yields anything. The obvious implementation —
collect the sections headed `## Unreleased` — is wrong here and quietly so: nothing stamps
CHANGELOG.md on main, so every section on main carries that heading forever and a heading-based
reader would republish the whole file every time. The range needs no state and cannot drift.

The cut also stamps the CHANGELOG onto the release commit, so `git show <tag>:CHANGELOG.md`
answers "what shipped in this version" — which nothing could before, with eight `## Unreleased`
headings in the first 300 lines at v0.17.9. Like the `FIVE_VERSION` write beside it, the stamp
lands on the detached release commit and never on main: DIVE-2247 removed this job's ability to
push a protected branch, and the fix was to stop needing it.

Both halves live in `scripts/release-notes.sh` and `scripts/stamp-changelog.sh` rather than
inline in the workflow, for the reason this file already gives for `grade-release-commit.sh` — a
workflow body cannot be unit-tested. `tests/release_notes_unit.sh` covers them against a real
throwaway repo (27 assertions), including the arm that matters: an underivable body exits 1
rather than publishing the cut reason again.

## Unreleased — feat(gh): route agent GitHub writes through the machine account (DIVE-2448)

An agent `gh` write authenticated as the human account, so no field anywhere could tell an
agent action from a human one — measured across the PR actor field, the org audit log and the
merge commit, three no-answers (DIVE-2232). A machine account now exists and holds push on every
shipping repo, but nothing routed to it: acting as the bot meant an agent remembering to type
`GH_TOKEN=` by hand, which is the same self-declared shape that ticket rejected for attribution
markers.

`5dive gh` makes it configuration. Writes go out as the machine account; admin-class operations
and reads stay on the caller's credential, because the bot is `admin=false` on every repo and a
read leaves no actor field to attribute. The decision and its reason are printed on every call,
`--as=bot|caller` forces one identity, `--explain` runs nothing, and `5dive gh whoami` resolves
both identities so "who did that write go out as" is measurable rather than inferred.

An operation the router does not recognise goes to the caller — today's behaviour, unchanged, and
it says so, so an unrecognised write is a visible gap rather than a silent 403 on a path that
used to work. The credential keeps the delegated-push posture: the PAT is read inside the
root-only `_gh_do`, argv travels NUL-separated on stdin, the token is only ever an environment
prefix, and the agent process never holds it. `_gh_do` re-derives the routing class itself, so a
caller cannot talk the bot into an operation it must not perform. The sudoers grant rides the
existing `--can-push` builder capability. `tests/gh_actor_routing_unit.sh` covers the whole
non-credential surface (62 assertions).

## Unreleased — feat(task): CHANNEL PROOF of the human's answer clears a tier-2 gate, so a decision already made in chat is not re-entered as a button tap (DIVE-2412)

DIVE-2382 fix #4, approved 2026-07-30 04:27. A tier-2 gate could be cleared by exactly two
things: a per-gate nonce (the Telegram button) or a non-agent SUDO_UID (the dashboard exec).
Neither is what the human usually produces. The live illustration is DIVE-2247: the answer
`hold-schedule` was recorded at 05:14:26 with `human_nonce_hash=NULL`, and the only reason it
was credible at all was lodar's own chat message 27 seconds later saying he pressed it. Grading
that took a human-judgement pass, and the alternative on offer was asking him to re-enter as a
tap a decision he had already made in prose - the rubber-stamping he refused on 2026-07-29.

`task answer` now takes `--channel-msg=<message_id>` alongside `--channel-proof=<chat_id>`, and
that pair is a fourth evidence form that a TIER-2 gate accepts.

WHAT MAKES IT EVIDENCE RATHER THAN A CLAIM, because that boundary is the whole design. The
chat id on its own is not evidence and stays tier<2 exactly as DIVE-1305 scoped it: the calling
agent's session already knows that number, so alone it proves only that this bot has a paired
human. A citation is different in kind. The message id is checked against TELEGRAM, via
`forwardMessage` on the cited id, and the forwarded copy is deleted immediately - it is a probe,
not a post. Four conditions must all hold: the chat is the paired human's verified DM, the
message is live, its `forward_origin` is a USER whose id is that human (a bot's own message, a
third party and a privacy-hidden origin are all refused), and it is fresh and names BOTH the
task ident and the answer. Anything unresolvable - no readable token, no response, no attribution - REFUSES. An agent
asserting that a human answered is refused with the gate left open, because `--from` and a
quoted line are caller-supplied and are not evidence.

The reason the check is remote is that no local one exists: the plugin and the agent share a
unix user, so no file, uid or cgroup separates them. What an agent cannot do is make Telegram's
servers report a message that was never sent.

WHERE IT IS ADMITTED, because a tier-2 clear passes two guards and not one. Raising the human
flag only clears the first (the DIVE-1117 provenance floor). The second is DIVE-2233's evidence
site, which refuses a tier-2 `--human` claim that carries neither a valid per-gate nonce nor a
non-agent `SUDO_UID` - and it is scoped to gates that HAVE a minted nonce, which is every
approval and manual gate, i.e. exactly the ones this feature is for. The citation is therefore
listed there as a third evidence form, on the same footing: the other two are local to the box,
while this one is attested by Telegram, the party the caller cannot speak for. Its refusal
message and audit row now name it (`channel_session=`).

The row now carries `human_evidence`, so `nonce` (a tap), `sudo-uid` (dashboard/on-box),
`channel-chat` (the tier<2 form) and `channel-session` (this one) stay tellable apart after the
fact - all four persist as `need_answered_by=human:*`, and only the last cleared a tier-2 gate
with nobody touching a button. Stored on the row rather than derived from a log, per DIVE-2090.

THE FRESHNESS BOUND IS NOT THE CALLER'S TO SET. `task answer` is run by the agent, so the
freshness window may not be read from its environment - and the first cut of this change did
exactly that, then named that window as what bounded a replay of a non-unique answer value. Both
halves are fixed: the ceiling is hardcoded at 3600s and `GATE_CHANNEL_SESSION_MAX_AGE` can only
TIGHTEN it (wider, zero, negative and non-numeric all fall back to the ceiling), and the cited
message must name the task IDENT as well as the answer. An ident is unique to one gate; a value
is unique to none, and an ident on its own would attest only that the human spoke about the gate
while `--value` still came from the agent.

RESIDUAL, stated rather than buried: a human message naming this ident and this answer, sent
inside the hour, cited for this gate, is taken as the human answering this gate. Only a per-gate
nonce ties the two harder, and that nonce is the tap this exists to avoid.

Graded by `tests/gate_channel_session_t2_unit.sh` (33 arms) plus
`tests/gate_channel_session_t2_mutation.sh`, which deletes each condition in turn and requires
the named arm to go red - 14 mutants, 14 killed. Three arms were rewritten because that pass, and
then CI, showed they graded nothing: the hidden-origin fixture was being caught by the sender
check one condition down, the "invented message id" refusal was passing on rc alone, and the two
`human_evidence` arms were grading THE RUNNER. `_gate_sudo_uid_nonagent` answers "is this a
human?" by asking the host's passwd database whether the account is named `agent-*`, so on an
agent box the column read `channel-session` and on a CI runner the identical code appended
`+sudo-uid` and the exact-string arms went red. The seam is now pinned to the agent caller that
is this feature's whole premise, and CS13 flips the pin both ways so the pin is differential
rather than a way to keep the harness quiet.

AND THE MUTATION GRADER ITSELF WAS UNGRADED, which `harness-verdict-union` caught and reded the
build for. A mutation grader re-runs its whole unit suite once per mutant, so this one costs
~14 x 23s and the probe's 180s per-harness `timeout` killed it before its verdict line ever
executed - `not-reached` on BOTH the pristine and installed-host lanes, i.e. probed in no
environment at all. That is the permanently-unprobed limit case the union job was written for,
arriving on a harness whose own job is to catch tests that grade nothing.

It is fixed with a lane, not an exemption. `ALLOW_UNPROBEABLE` means "no identifiable verdict
variable" and this harness has one - measured `wired` at `PROBE_TIMEOUT=900` - so allowlisting it
would have put a false reason on the record and excused the coverage it was claiming. Instead a
`harness-verdict-slow` job probes the named slow harnesses with `--only` at 900s, and the union
consumes its report as a third environment. `--only` is deliberate: raising `PROBE_TIMEOUT` for
the whole 255-file sweep would also raise how long a genuinely hung harness can stall CI, which
is the property the 180s default buys. `probe-slow.txt` is named explicitly in the union call
rather than globbed, so a slow lane that dies reds the union instead of silently dropping back to
the two-environment corpus. Verified differentially against the real CI reports from the red run:
with the third report 252 probed / 0 NEVER PROBED / rc 0, without it 1 NEVER PROBED / rc 1.

Consumers are NOT wired yet and this ships inert until they are: the telegram plugin does not
pass `--channel-msg`, and the dashboard (DIVE-2371) is the second surface on the same rail.
DIVE-2371's fail-closed prefix change must still land AFTER them, or the dashboard's tier-2
clear goes offline with it.
## Unreleased — fix(task): pronoun options resolve to an account frame (DIVE-2212)

Two parties can no longer select the same second-person gate option and receive
only a confirmation whose actor silently changes with the reader. `task need`
now warns when a decision option contains `you`/`your`-family wording and asks
the filer to name accounts, while remaining backward-compatible with free text.

When such an option is answered, the prose receipt names the filer and answerer
and declares that second-person terms use the filer-addressing-answerer frame;
JSON callers receive the same mapping in `option_account_frame` while retaining
the raw `need_answer`. `tests/gate_option_account_frame_unit.sh` reproduces the
dev3-to-main incident, checks prose and JSON receipts, and guards word boundaries.

## Unreleased — feat(ledger): one append-only lifecycle log with the authority envelope (INST-4, phase A)

We were already event-sourcing, in four separate append-only silos — `supervisor_events`,
`objective_readings`, the council lineage, and the `_audit_append` log. Each is correct and each
answers a different question, which is the problem: none can answer "who was authorized to do
this, why, and what happened next", because the answer is split across four schemas with four
notions of actor and no shared key. `5dive trace` had to hand-join transition *columns* on the
tasks row to fake one timeline.

`lifecycle_events` is that one log. Every row carries the full envelope: actor, **authority**
(`root` / `sudo:<who>` / `self` — the elevation the audit log has never recorded), parent,
idempotency key, input/output digests, policy decision, usage and host. `ledger_emit` hashes
`in=`/`out=` payloads itself, so a call site physically cannot write content into the table;
a secret gate contributes no digest at all.

Additive by construction. No existing write was moved or removed, the state machine is
untouched, and a ledger write can never fail the action it describes. `trace` gains a `ledger:`
section shown *beside* the derived timeline rather than merged into it — one is reconstructed
from current state, the other was recorded at the time, and where they disagree that is the
finding.

An empty ledger has two meanings and the rows cannot separate them, so init stamps a
`ledger_started` marker once and `trace` says which it is: no events, predates the ledger, or —
if the marker is missing — unknown. Emitters are live on task create/start/deliver/done/cancel,
gate file/answer, policy refusal, and ship/rollback. Remaining lifecycle sites and the four
silos still write only where they write today; folding them in is the next phase.
`tests/ledger_unit.sh` covers the migration on a store that already has the neighbouring silos,
marker idempotency, the no-raw-payload property (mutation-graded), idempotency in both
directions, and the never-fails-the-caller contract.

## Unreleased — feat(task): displaced gates have a reader with an honest coverage boundary (DIVE-2133)

`gate_history` stopped gate retirement from destroying the previous ask, answer and
provenance, but nothing could read the table. `task show` now carries a compact previous-gate
count and `task gate-history <id>` lists the archived ask/answer plus `retired_by` and
`retired_at`; both human and JSON paths redact secret answers.

An empty archive on an upgraded store is not evidence that no gate was displaced before the
archive existed. Every store now stamps a conservative `gate_history_coverage` boundary once:
before the first task on a fresh store, the earliest already-archived row on an upgraded store
that has evidence, or migration time when it has none. The same value records whether the basis
is fresh or inferred, so a second-granular timestamp equality is trusted only on a fresh store.
Readers therefore say a bare `0` only when coverage reaches the task's creation; older tasks
say `0 recorded` and name the unknown earlier era. `tests/gate_history_unit.sh` covers the detailed
reader, both `task show` surfaces, secret redaction, complete-vs-partial zero, and the one-time
migration stamp.

## Unreleased — fix(up): a skill that FAILED to install is no longer summarised as `errors=0` (DIVE-2347)

`agent create` does not fail when a preseeded skill won't install, and that is the right
call — the agent itself is up and a rerun fixes the skill. The consequence was not: the
failure never reached `5dive up`'s `errors` counter, so the last line the user read
contradicted the red lines they had just watched scroll past.

Measured on the shipped content-studio template, whose writer and seo roles both request
a skill that is not in the repo the template names:

```
error: skill install failed for 'deep-research' on agent 'writer'
warn:  skill install failed for 'deep-research' from '5dive-ai/skills' (exit 1) — agent is up; rerun: ...
OK — applied ...: created=5 started=0 skipped=0 errors=0
```

A first run that reports success while two things failed is worse than one that fails
loudly: the customer concludes he broke it.

The summary now carries `skills_failed=<n>`, and a consolidated block after it names each
agent and the exact rerun command. This is the same defect and the same remedy as the
asleep row (DIVE-2341) — a true statement made once mid-scroll, then overwritten by a
cheerful one — so it is derived the same way: read back the INSTALLED SET via
`_skill_list_json` (the reader `skill list` already uses) rather than trusting the create's
exit code or scraping its render. Display only; it cannot fail a create.

Not fixed here, and deliberately: the templates that request the missing skill. That is a
separate call about what the templates should ask for — see DIVE-2347.
## Unreleased — fix(doctor): a FAILED env-override report no longer reads as "no overrides set" (DIVE-2336)

Both consumers of `_env_overrides_json` wrapped it twice — `|| printf '{}'` and
`[[ -n "$X" ]] || X='{}'` — so a hard failure rendered as `{}`: no process list, no
configured list, no state. Every consumer reads that as **no overrides are set**. That is
the could-not-check-as-negative shape DIVE-2318 closed in the merge gate and DIVE-2327
closed for an unreadable `agents.d`, reappearing one level up inside the code that closes
it. **Four sites, not two** (main, routing the row): the empty-string coercion is the same
defect as the `|| printf`.

**Which of the four mattered, measured, and it inverts the obvious reading.** Stubbing jq
to fail at each of the 7 invocations a clean run makes: *every* position produced rc≠0 with
**empty stdout**. So the visible `|| printf '{}'` arm is not the one the real failure mode
reaches — the empty-string coercion is. Fixing only the two obvious sites would have left
the live path untouched and looked complete.

`_env_ov_unavailable` emits a fifth state, `configured_state: "unavailable"`, and uses
**only `printf`** — the likeliest reason the reporter failed is that jq is gone, so a
fallback needing jq to say "jq is gone" says nothing. The function now guarantees a
well-formed payload rather than exiting non-zero with empty stdout: a caller forced to
invent a payload is a caller that will invent the wrong one, which is what happened at all
four sites.

**Corrects a claim I made filing the row.** I wrote that a mid-loop jq failure "could drop
entries and still emit a well-formed partial as if complete". It cannot — an emptied
accumulator makes the next jq fail on invalid `--argjson`, so the run dies instead of
shipping a short list. But that safety is **accidental**: it holds only because the poison
propagates, and one `|| true` downstream converts it into exactly the partial-as-complete
I wrongly claimed. The rc checks went in anyway, as a guard on a property that is currently
true by luck rather than by construction.

**A fallback must not live in the file it is a fallback for**, and the first cut of this
change broke exactly that. `tests/selfcheck_unit.sh` sources only
`header/error_codes/output/cmd_selfcheck` — not `lib/env_overrides.sh` — so a call-site
fallback calling `_env_ov_unavailable` found no function, produced an empty string, and
`jq --argjson eov ""` killed selfcheck's whole `--json` contract (33/0 → 26/7). Caught by
the full suite, not by the new harness. The fallback is now a constant in `header.sh`
(`_5D_ENV_OV_UNAVAILABLE`, deliberately not `FIVE_*`-named, which `env_isolation.sh` would
clear inside every harness), and T8 stands guard over it.

`tests/env_overrides_unavailable_unit.sh` — 16 arms, mutation-graded six ways, **two of my
four original predictions wrong**: restoring either call-site coercion reds only the
*structural* arm, because with the function holding its contract the call-site guard is
unreachable defence-in-depth. That reachability is the finding, and it is why the structural
arm is a grep rather than a run.

## Unreleased — feat(doctor): REPORT the FIVE_* knobs in effect and configured (DIVE-2328/2327)

`doctor` and `selfcheck` answer "what is true on this box". A product knob in effect is
true on this box, and no surface said so. That silence is correct for an **intended** knob
and identical for an accidental one, and nothing distinguished them.

**This reports. It does not warn.** Name and value only — no "unexpected", no severity, no
advice. The knobs are normally deliberate (lodar's 2026-07-29 policy sets
`FIVE_VERIFY_DEFAULT=0` for sixteen agents), so alarming on them would be crying wolf on
correct configuration. Reporting costs nothing when intended and is the only thing that
makes an unintended one findable.

Two sources, distinctly labelled, and the second is the point:

- **process** — `FIVE_*` exported in the environment of the running command.
- **configured** — `FIVE_*=` assignments in the `EnvironmentFile` targets systemd injects.

A knob in `configured` but not in `process` binds on the next restart and is invisible to
any process-side read. That gap cost an hour on DIVE-2325, where a `/proc/<pid>/environ`
sweep found the knob in one session and was read as one operator's stray export, when
sixteen agents were configured and fifteen had not restarted. **Where the two disagree,
both lines print and nothing is concluded** — a difference is a fact about restart order,
not about correctness.

`configured_state` is four-valued: `read` / `partial` / `unreadable` / `absent`, with the
missed paths carried in `configured_unreadable`.

- **`unreadable` is not `absent`.** `selfcheck` does not `require_root` and
  `/var/lib/5dive/agents.d` is `drwxr-s--- root:claude` with 0640 files, so a caller
  outside group `claude` globs it and gets nothing. Rendering that as an empty list says
  "none are configured" when the truth is "I could not look".
- **`partial` was added after measuring**, not from the spec. The unit resolves an
  `EnvironmentFile` outside `agents.d` that a non-root caller cannot read, so 16 files are
  read and 1 denied; a single flag rendered that "unreadable", which understates a read
  that mostly worked exactly as an empty list overstates one that did not.

**Never dumps a file.** Several `agents.d` entries are symlinks into
`auth-profiles/*/combined.env`, which carry auth material — only `FIVE_*`-named
assignments are ever extracted, and any knob whose *name* is credential-shaped has its
*value* replaced. Redaction says nothing about whether a knob should be set.

Also fixes a pre-existing defect this surface would otherwise sit behind:
`--category=policy` failed usage because the allow-list omitted it while `run_policy`
dispatched it and the usage error text advertised it — so anyone who read the error and
did what it said got a usage failure.

**The report is not a check.** `env_overrides` rides alongside `checks` in doctor's
payload, never inside it. The first cut used `doctor_add` with `severity=ok`, reasoning
that `ok` is the schema's neutral member because it feeds no warning/error count. True of
the payload and false at the reader: the dashboard computes
`passing = checks.filter(c => c.severity === "ok").length` and renders it green, so sixteen
configured-knob lines became sixteen *passed checks* — `--category=policy` reported
"17 checks, 17 ok" where one check had run. Its default view is
`checks.filter(c => c.severity !== "ok")`, so the surface built to make an unintended knob
findable was hidden behind "show all". `selfcheck` already had this right; doctor now agrees.

`tests/env_overrides_report_unit.sh` — 20 arms, mutation-graded six ways with the measured
results in its header. Two harness defects are recorded there too, because both are the
kind that ship green: T10 was green **and vacuous** (`require_root` fires before argv is
parsed, so both branches died at the permission check; only the anchor went red), and the
first run stopped mid-file with fifteen `ok`, no `FAIL` and **no summary**, because
sourcing `src/header.sh` re-enables `errexit`.

## Unreleased — fix(tests): harnesses no longer inherit the caller's product knobs (DIVE-2325)

`task_core_unit` (28/7) and `task_verifier_rail_unit` (17/6) were red on the control-plane
host and GREEN in CI at the same commit. It presented as host state — the DIVE-1919 class
`test-installed-host` exists to catch — and it was not. No amount of seeding a runner would
have reproduced it.

`FIVE_VERIFY_DEFAULT=0` is in the caller's environment. The DIVE-969 verifier-by-default
rail reads `${FIVE_VERIFY_DEFAULT:-1}`, so the whole mechanism goes inert: not a wrong
value, no mechanism at all. Reproduced exactly — with that one export, the two harnesses
give 28/7 and 17/6, same arm names.

**That knob is deliberate fleet policy. Do not delete it to make a test pass.** lodar set it
for sixteen agents on 2026-07-29 00:49 via the unit's
`EnvironmentFile=-/var/lib/5dive/agents.d/%i.env`, and each file carries the decision and
its own revert instruction. Tasks filed without a rail since then are **policy-conformant,
not damage** — there is no backlog of broken rows to audit.

That is precisely why the harnesses are the only thing that can move. The configuration is
not an accident awaiting cleanup; it is correct, intentional and permanent. **A harness
asserting what DIVE-969 does BY DEFAULT while reading that default from the environment is
grading fleet policy instead of the code.** It has to supply its own.

This is DIVE-2211 one axis over. That change pinned WHICH TREE a harness grades, because
"21 passed" was a claim about whatever was on disk. The same sentence was still true of the
ENVIRONMENT: src reads **14 caller-overridable `FIVE_*` knobs**, every harness inherits the
caller's, and a green log from a clean shell and a red log from a configured one are
byte-identical apart from the number.

- New `tests/lib/env_isolation.sh` unsets the whole `FIVE_*` namespace and **says on stderr
  what it cleared** — the reader needs to know a knob was in effect, not be silently fixed
  up. Silent on a clean environment, so the line means something when it appears.
- Applied at `tests/lib/grading_tree.sh`, which all 235 harnesses already source near the
  top before any fixture setup. One seam, no 235-file diff. Verified no harness assigns a
  `FIVE_*` variable before that point, so nothing a harness meant to set can be clobbered.
- Blanket rather than one knob on purpose: `FIVE_GATE_REPOS`, `FIVE_GATE_MAIN_BRANCH` and
  `FIVE_GATE_ANCESTRY_SCAN` would each silently rewrite what the merge-gate harnesses
  measure, and knob #15 will be added by someone who has never read this file.

`tests/env_isolation_unit.sh` — 13 arms, mutation-graded five ways. T6 anchors T5 (a
variable that was never going to be set proves nothing when found unset), T7 reproduces the
incident end-to-end, and T9 exists because mutation found the helper announcing the same
readonly knob as *both* stuck and cleared — a report of work that did not happen, which is
not allowed to live in the reporter for that defect class.

Diagnostic caveat recorded in the helper, because the instrument misled first: a
`/proc/<pid>/environ` sweep found the knob in one session only and that read as a stray
export. A live environ reflects the env file as of that session's **last exec**, so the
sweep measured RESTART ORDER, not configuration. Read the config source, not the running
processes.

## Unreleased — fix(gate): the merge gate stops reporting COULD-NOT-CHECK as NOT-MERGED (DIVE-2318)

`task done`'s merge gate makes four GitHub queries. Every one of them can come back
empty for reasons that have nothing to do with the merge, and all four empties were
rendered as a merge verdict. On DIVE-2286 it printed *"its delivery PR is not merged to
main yet (pull/295, state=unknown)"* about a PR that had merged 90 minutes earlier. That
sentence is false about the world, and two agents misdiagnosed from it in sequence: dev2
went hunting a deleted branch, then a confident wrong mechanism (squash/ancestry) was
filed on top of dev2's reading.

`task merge-audit` already gets this right on the SAME fault — it names the missing
credential and tells you to authenticate. Two verbs, one cause, opposite diagnostics.
Four refusal sites now follow the correct one:

* **no gh credential resolved** — `done-merge-gate-no-credential`. No query ran at all,
  so the refusal says so and names the resolution order. Which callers hit this is a
  property of the CALLER'S OWN SUDOERS, not of being a builder: `_gate_gh_token`'s last
  resort is `sudo -n -u claude gh auth token`, so an agent with `ALL=(ALL) NOPASSWD: ALL`
  resolves one and an agent scoped to `/usr/local/bin/5dive *` cannot.
* **PR-state query returned nothing** — `done-pr-state-unresolved`, distinct from a
  measured OPEN.
* **attribution scan unreachable in any searched repo** — `done-attribution-unresolved`,
  reported as PARTIAL COVERAGE. A negative over a set that was not fully covered is not
  a negative.
* **the branch refusal no longer offers ANCESTRY as a way to satisfy the gate.** It has
  accepted nothing since DIVE-2120/2184, and under our default squash merge it is
  unsatisfiable by construction (measured on PR #300: the branch tip is not an ancestor
  of main while the content diff over the changed paths is empty). An error naming an
  impossible condition is what sent dev2 and dev3 looking for a missing branch. It now
  names the two roads that can accept — attribution on main, a merged PR for the head —
  and says why ancestry is not one of them.

**ACCEPTANCE IS UNCHANGED.** Every close that passed before still passes and every
refusal is still a refusal; the credential guard sits ahead of probes that all returned
empty anyway. What changed is which cause the refusal names. `tests/task_merge_gate_diagnostic_unit.sh`
pins both directions, with anchor arms on the accepting side so a guard that simply
refused everything would go red.

## Unreleased — fix(loop): a spend read that FAILED is NOT-REACHED, not zero — and no longer clobbers the running total (DIVE-2304)

`_loop_refresh_spend` had three fail-open sites feeding one control decision: a missing
`loop_runs` row returned `0`, a python recompute that exited non-zero returned `0` with its
stderr sent to `/dev/null`, and any non-numeric output was coerced to `0`. `0` is also what a
loop that just started legitimately reports, so `spent >= ceiling` could not tell "no budget
used" from "no idea" — an unreadable spend silently DISABLED the token ceiling.

THE PERSIST WAS THE SEVERITY. The `UPDATE loop_runs SET tokens_spent=...` ran unconditionally,
on the fail-open path too, so one transient read failure overwrote the accumulated running
total with `0` in durable state — and the throttled fast path then read that `0` back on every
later call. That is not a blind spot that self-heals on the next poll; it destroys the figure
the ceiling exists to test against. Bounded honestly: the loop still halts at its `deadline`,
so this is "the budget control stopped binding", not unbounded spend.

The producer now has a three-state contract — rc 0 with a real integer (and only then a
persist), or rc 2 with NOTHING on stdout, no write, and the cause named on stderr. The
`2>/dev/null` on the python call is gone; it is why this was invisible for the life of the
ceiling. `_loop_spent` propagates rather than re-laundering the stale row as fresh, and a new
`_loop_ceiling_check` carries the third state to the six `--wait` polls, which halt with
haltReason `spend-unreadable` (an integer could not carry it, which is why fixing the call
sites alone would not have helped). The heartbeat sweep — the only ceiling enforcement a
fire-and-forget loop has — no longer turns a broken recompute into "0 tokens spent", and
`goal status` fails the job instead of sailing past a ceiling it never evaluated.

Graded two-sided by `tests/loop_spend_not_reached_unit.sh` (17 assertions): every unreadable
arm is paired with a healthy arm on the same fixture, and the consumer arms drive the shipped
`cmd_loop_spawn --wait` through the REAL broken producer rather than a stub. Against pre-fix
`src/` the harness reds 13 and keeps 4 healthy arms green — including the clobber (60000 -> 0)
and a `--wait` that ran to its deadline instead of halting.

## Unreleased — fix(task): the tier-2 category floor stops reading `press` inside `suppression`, without dropping `$500` out of the un-appealable half (DIVE-2301)

The floor terms were a bare alternation with no boundary, which made every one of them a
SUBSTRING matcher. `press` fired on suppression, expression, compressed, impressive and
depression; `charge` fired on recharge and supercharge. Both terms live on the NON-APPEALABLE
list, so an ask that legitimately said "stop forging a suppression" floored to tier 2 with no
appeal path, naming a word about neither the press nor money. DIVE-2273's own push gate hit
exactly this and escaped only because the match landed in the TITLE, which DIVE-2224 answer A
exempts. The same word in an ask has no exemption.

THE PRESCRIBED FIX WOULD HAVE FAILED OPEN ON MONEY, and this is why the change is not where
the ticket put it. `\b` asserts a word/non-word transition and `$` is not a word character, so
`\b\$[0-9]` never matches: writing a leading `\b` onto each term — the ticket's measured
proposal, correct on every term it tested — makes "approve $500 for ads" and "wire €900 to the
vendor" stop flooring ALTOGETHER. That trades a false positive for a false NEGATIVE on the one
class with no escape path. Measured, not reasoned: the mutation is kept as a graded arm, and a
per-term-`\b` build reds 5 arms of the new harness while leaving the false-positive and
inflection arms green — the shape that would have let it merge.

WHAT LANDED. A leading boundary `(^|[^[:alnum:]_])` applied at the MATCH SITE
(`_gate_tier2_floor_hit`, `_gate_tier2_floor_term`) rather than written into the term list.
Two consequences beyond the ticket: a non-word term can sit behind it, so the money class keeps
firing; and it anchors the regex a sealed `constitution.yaml` supplies, which REPLACES the
shipped default wholesale — anchoring the default alone would have left the defect live in
exactly the path where the policy is authoritative, and every org's own terms would still be
substring matchers. LEADING only, deliberately: the tail stays open so inflections keep
matching (revoked, truncated, charges, pressing). Containment at the START of a longer word
(pressure, deleterious) still fires and is the accepted cost of keeping those.

ALSO RECORDED, not changed: `_GATE_FLOOR_NONAPPEALABLE_RX` is documentation of record, not a
matcher — one definition, zero uses. The non-appealable decision is reached by SUBTRACTION
(strip the appealable terms, re-test the full floor), so the boundary fix is what actually stops
an appeal being refused in the name of a `press` the ask never contained. The invariant that
subtraction depends on — no appealable term may be a substring of a non-appealable one, or
stripping the former erases the latter — is now asserted by a test instead of left to review.

`tests/gate_floor_word_boundary_unit.sh`: 32 arms, both halves graded on purpose so a later
"fix" for the false positives cannot quietly break the true ones.

## Unreleased — fix(tasks): the production task board refuses a write from a sourced-library caller, so a harness cannot leak fixture rows onto it (DIVE-2249)

On 2026-07-27 a run of `tests/gate_verifier_route_unit.sh` appended six fixture rows to the
LIVE board — DIVE-501 through DIVE-506, `created_by=dev`, empty bodies, all inside a
four-second window. They were not inert: `5dive trace DIVE-503` shows two real gate
deliveries and a human-facing gate that agent-main then had to withdraw by hand.

REPRODUCED, not inferred. Inside a private mount namespace with `/var/lib/5dive` bind-mounted
onto a decoy copy of the board, the current harness leaks nothing (0 rows, 9/9 pass). Remove
its single `STATE_DIR` line and the same six idents land with the same `created_by`,
`verifier` and `maker_agent` values, and nothing refuses them. So the isolation works when
present, it is one line, and its absence is silent.

`db`, `dbfmt` and `tasks_db_init` now refuse a non-READ statement whose active store resolves
to the production board unless the process entered through the real CLI entrypoint (`main`
sets a marker). Reads are untouched; an isolated store is untouched. The refusal is loud —
exit 10 on stderr, and the process stops there, so a fenced harness goes RED rather than
passing having asserted nothing.

THE FENCE IS NARROW, NOT WEAK. It covers what enters through `main()`; it cannot see a
foreign client opening the .db directly, which the dashboard API does. Knowing which of those
two a guard is tells you when to trust it — a weak guard should be strengthened or distrusted,
a narrow one trusted inside its scope and supplemented outside it. This sentence is here
rather than only in the residue note below because the note is read once and the name is read
forever, and "store fence" on its own will be read as "the board is protected from stray
writes", which is not a claim it makes.

The discriminator is ENTRYPOINT, not an opt-out env var. Every legitimate prod write comes
from the built bundle, whose last line is `main "$@"`, and `build.sh` is the only non-test
file in the repo that sources this library — so "sourced the library, then aimed a write at
the prod path" is a mistake by construction. A harness that sets nothing is fenced, including
harnesses nobody has written yet. An opt-out is a thing you have to remember, and a forgotten
one fails silently INTO prod, which is the defect being removed (same reasoning as DIVE-1968
and DIVE-2010).

This is the fourth instance of one class. Gate-notify (DIVE-1500), the human DM relay
(DIVE-1506) and audit_log (DIVE-2010) were each fenced in turn, and all three are OUTBOUND
rails. The tasks table is the store those rails read FROM, so it is the one that most needed
a fence and the only one that had none.

TWO CORRECTIONS THE CORPUS FORCED, neither of which the fence's own unit test could see.
The first draft resolved "is this prod" through `FIVEDIVE_PROD_TASKS_DB` — the obvious choice,
and wrong: 23 harnesses already export it pointing at their own throwaway store, which is how
they open the DIVE-1506 human-send allowlist. That fence would have refused 23 correctly-
isolated suites and protected the real board from nothing, while its unit test stayed green.
Found by running all 223 harnesses against a bind-mounted decoy board. The prod path is now
hardcoded and unconditional; `FIVEDIVE_FENCE_EXTRA_STORE` only ADDS to the fenced set, so the
override cannot become an escape. The second: the SQL check was a verb blocklist, which let
`ATTACH DATABASE` through under differential test. It is now a read allowlist — everything
unrecognised counts as a write, so the failure mode is a refused read rather than an admitted
one. A change to shared plumbing is graded by the corpus, not by the arm you wrote for it.

RESIDUE, named rather than implied: this fences the shell library's writers. It does NOT
fence a process that opens the .db with its own sqlite3 or node client — the dashboard API
reads the board that way. Closing that needs file-level permissions, not a function guard.
## Unreleased — fix(heartbeat): the dispatcher claims the task it nudges, so the whole stuck-work recovery layer stops reading a dead field (DIVE-2244)

A fleet-stall alarm fired on a fleet that was not stalled. Root-causing it found something more
expensive than the alarm — and re-measuring at implementation time corrected the diagnosis.

The only writer of `tasks.status='in_progress'` and `started_at` was an instruction. The `/goal`
nudge text says "claim it with `5dive task start DIVE-N`", and a rule an agent must remember at
the moment of action is not a control (DIVE-2146). Compliance is partial and erratic: of tasks
closed per day, the share that ever had `started_at` set ran 23% (14 of 61, 2026-07-28), 51% (35
of 68, 07-27), 60% (50 of 83, 07-26).

That corrects the filing ticket, which reported 0 of 24 and "0 tasks with `started_at` in 48h".
Its six named tasks really are NULL, but the aggregate does not hold — 48 rows were claimed in
that same window, and the board carries in-progress rows right now. `in_progress == 0` is a
transient, not the permanent condition the ticket diagnosed, and that changes which half of this
change does which job.

The costly half is silent, and the claim fixes it outright. The same field is what the entire
stuck-work recovery layer keys on: the deterministic hard cap on the `/goal` loop, the runaway
reaper, the orphan reclaim for a task whose claiming session is gone, the unwedge rules, and the
tick's own "already in_progress, skip" busy guard. At 23–60% coverage, most in-flight work was
invisible to all five. A genuinely runaway or orphaned task in that majority had no recovery
path at all and would present as a permanently-`todo` row nobody notices. The heartbeat already
knows exactly which task it woke an agent for, so it now stamps `status='in_progress'` +
`started_at` at the moment of the nudge — taking coverage of dispatcher-driven work to 100% by
construction.

The alarm half is smaller than the ticket claimed. `in_progress` was genuinely 0 at 08:15Z on
2026-07-28 — a real quiet moment, not a dead field. Claiming raises the floor but does not by
itself make the stall predicate sound; the probe-conclusiveness change below is what addresses
the reported firing.

The claim is narrow by construction. It runs only inside the wake-success branch, so a tick that
wakes nobody claims nothing; it matches `WHERE status='todo' AND kind='standard'`, so it never
stomps a row something else already moved and never starts a recurring template (which would
silently retire it, DIVE-2055/2059); and `started_at` is COALESCEd, so an agent that does run
`task start` afterwards is a no-op rather than a re-clock that would restart the reaper budget.
It confirms from the row rather than from sqlite's exit code, and says so in the log when a
claim does not land instead of logging one it never made.

Two consequences worth stating rather than discovering later. First, the busy guard is now live:
an agent with a claimed task is not re-nudged, and a task it abandons is requeued by the
existing reclaim rules (orphan-by-restart immediately, idle-stall at 20m, hard cap at the
budget) rather than by a second nudge. Second, the starvation counter now detects a different
mechanism for the same conclusion — it used to mean "nudged N times and never left todo", and
now means "claimed and reclaimed N times" — which only works because the claim is stamped after
`_hb_mark_run`, whose prune keys on "still todo".

The second half — separable in the ticket, load-bearing in fact. The same alarm asserted a
fleet-wide claim while stating in the same sentence that it could not measure part of its
population ("5 UNMEASURABLE (pane uncapturable) — this alert did not prove those idle").
Since `in_progress == 0` turns out to be a real (if brief) reading, this unmeasured probe is the
part of the predicate that actually turned a quiet moment into a stall claim. That honesty is
kept and is now reflected in the headline: an
unmeasured probe downgrades `🛑 fleet-stall` to `❓ possible fleet-stall (UNPROVEN)` and asks the
question instead of asserting the finding. Deliberately a language change and not a firing
change — requiring a conclusive probe to fire would fail open exactly when panes are
uncapturable, which is when the fleet is most likely to be genuinely wedged.

## Unreleased — fix(task): a failed open-instance read no longer forges a `last_skipped_at` suppression that never happened (DIVE-2273)

The recurring materializer decided whether an instance was already open with

    open=$(db "SELECT COUNT(*) ... " 2>/dev/null || echo 1)

so a DB read that FAILED was counted as "an instance exists" and the template was skipped.
The fallback was not careless: somebody chose "on error, do not spawn a duplicate", which is
correct if the work is fungible. It is the dedup's own premise, restated in the error path
where nobody re-argued it.

DIVE-2237 made it worse in a way that only shows up one layer down. The skip branch now
stamps `last_skipped_at`, so a transient read failure WRITES A SUPPRESSION THAT NEVER
HAPPENED. The reading table DIVE-2237 shipped defines "stale `last_fired` + recent
`last_skipped`" as suppressed, a human must close the blocker — and after this path there is
no blocker to close, while `blocked_by` correctly renders `-` because none exists. The
instrument reported a cause it had not observed, and the human sent to close nothing learns
to distrust the column.

A failed read and a non-zero count are now different states. The read is checked for both a
non-zero exit and a non-numeric result (rc 0 with empty output collapsed into `1` the same
way via `${open:-1}`), and on either the tick stamps NOTHING and logs the sqlite error
itself, which `2>/dev/null` used to swallow. The fire decision is deliberately unchanged: an
unreadable count still skips, because not spawning stays the conservative outcome while
every template is dedup'd. Whether a spawn-class template should FIRE on an unreadable count
belongs with `--on-overlap` (DIVE-2270 / DIVE-2272), and that ticket now has a place to put
it: the failure must never reach the bound comparison, because the sentinel `1` is
conservative against a boolean test and PERMISSIVE against a bound of 3, and the bound is
spawn's safety valve computed from the very read it backstops.
## Unreleased — fix(council): the veto principal is redacted where it is GENERATED, not per-file (DIVE-2278)

`council roster`, the `council init` summary and the veto-exercise line printed the veto
principal verbatim. Seeded as `tg:<user_id>` — which is what a live install does — that put a
real Telegram user id into every freshly generated council artifact, and council output is
quoted verbatim into transcripts and posts. Redacting one transcript was the wrong fix: the
generator keeps emitting the id into the NEXT artifact, and that is the one nobody re-checks,
because "we already fixed the PII".

Human-readable output now routes the principal through a display filter. `human:<agent>` passes
through unchanged (already a name); a numeric id reverse-resolves to the paired agent's name when
it can, otherwise renders as the opaque handle `tg:#<8 hex>` — digested with host-local salt
(`/etc/machine-id`, else the hostname), because a ~10-digit id under an UNSALTED digest is
enumerable end-to-end and would be a redaction in appearance only. With no salt available it
prints `tg:#redacted` rather than a digest that cannot be defended. The `init` summary no longer
prints the RESOLVED recipient at all.

Nothing that needs the id loses it: genesis `.veto.resolved`, the `--json` rail, `veto-pings.jsonl`
and the delivery call are untouched. This is a display filter, not a data change, and no sealed
canonical bytes change.

`council init --veto=<digits>` now also warns: the principal string is copied into the SEALED
genesis/lineage/receipt bytes, which are immutable and publishable, and no display filter can
reach them afterwards. `--veto=human:<agent>` reaches the same recipient with only a name in the
seal.

## Unreleased — feat(task): a gate can DECLARE that it needs a human, and stop being answered by whoever is grading the ticket (DIVE-2241)

A gate filed on a task that carries a maker→verifier loop routes to the VERIFIER by kind
(DIVE-1495), and that routing reads the task, never the ask. So "may I spend this" and "may
I have a new token" landed on whichever agent happened to be grading the ticket. Three
instances in 36 hours across three agents.

`5dive task need` now takes `--needs=<capability>`. Exactly three names — `human_tap`
(a person's call: brand, strategy, irreversible), `spend_authority` (billing, paid
accounts) and `secret_provision` (a new token or credential) — resolve to the paired human.
A gate that declares one is tier 2, is never handed to a lead or a verifier, and cannot be
agent-cleared or TTL-auto-applied. Anything else changes nothing at all.

DECLARED, never inferred. The tier-2 keyword floor already guesses from the ask's wording;
this is its sibling with the epistemics reversed — the filer states what the ask consumes,
and because a statement outranks a guess, a declaration also survives the eng-ship,
curation, internal-ops and floor-appeal downgrades that classify on an ask's shape.

The three names are CONSTANTS in the shipped source, not rows in a table. This was
originally sequenced behind a capability registry; that registry is a mirror of
`/etc/sudoers.d` keyed on an agent account, so it can express `delegated_push` and can never
express a human at all. A registry derived from a permission system answers who may RUN a
command, never who may DECIDE a question. And a routing table on a host where every agent
holds NOPASSWD:ALL is an authority the beneficiary can grant itself in one command, so
there is deliberately no write path for these — not a guarded one, none.

It never refuses. An unrecognised or misspelt capability warns and falls through to today's
routing, because a router that hard-fails on an unknown name converts a mis-declared gate
into a stuck one. The declaration is recorded verbatim on the gate (`needs_capability`) and
audited at file time, including when it resolved to nothing.

Agent-held capabilities (`gh_push`, `root`, `delegated_push`) are explicitly NOT routable
this way yet — they need a different source, not a longer wait.

## Unreleased — fix(council): the founder veto has never been exercisable — the hold window had already closed on all six offers ever sent (DIVE-2257)

lodar forwarded two veto offers on 2026-07-28 and asked "why two? why no details?". Both
questions had answers and both were defects. Measured against
`${STATE_DIR}/council/veto-pings.jsonl`, comparing each ping's `ts` to the `executeAfter` its
own message advertised: `-15m`, `-45m`, `0s`, `-1s`, `-1s`, `-1s`. Six for six. The message
says "Execution holds until <T>. Tap VETO to block it" with T already in the PAST at the moment
of sending, so the founder veto is not a slow control or a racy one — it has never once been
exercisable. Four fixes, each with its own graded leg in the new
`tests/council_veto_window_unit.sh` (23, offline + root-free, so it gates on every runner
rather than self-skipping like the veto e2e):

- **The hold is now measured from when the offer is MADE.** `executeAfter` was
  `$stamped + veto_hold`, where `$stamped` is taken BEFORE the convene runs. A real five-seat
  deliberation takes 30-60 minutes, so a 900s hold was already spent by the time the receipt
  sealed and the ping fired — exactly the `-15m` / `-45m` on the 07-21 and 07-22 offers.
- **The invariant, asserted at write time:** no veto-offer may be written whose `executeAfter`
  is `<=` its own `ts`. `_council_veto_ping` refuses at the single write+send choke point — no
  ledger row, no delivery on either leg, one auditable `veto-offer-refused` row instead. An
  empty or unparseable `executeAfter` is likewise refused (fail-closed). Graded by replaying all
  six recorded offers: each one's signed ts→executeAfter offset re-based onto the write moment,
  all six refused, a genuine +900s window still written AND delivered, and a mutant with the
  window check neutered re-sending all six.
- **Ad-hoc panels can no longer reach the founder.** The offer was minted on `genesis_exists`
  alone — the mere PRESENCE of a sealed genesis file — so both 07-28 offers came from ad-hoc
  TEST convenes (`--seats=alpha,beta,gamma`, every vote the identical string "fine by me") and
  still landed in lodar's real DM. That is the DIVE-1506 class again. The new pure
  `_council_veto_offer_eligible` mirrors `cli.mjs`'s own `primaryCouncil` predicate, so a convene
  that is not running the genesis-sealed roster is structurally incapable of offering the veto.
- **A veto offer now names its SUBJECT, and is not made without one.** A receipt carries
  `stampedAt/sealedDigest/council/question/disposition/verdict/canonical` — no subject, no task
  id, no convened-by. "ship it?" WAS the whole payload; the Telegram message was not truncating
  context, none was ever captured. The subject now rides both delivery legs and the ledger row,
  and the primary council convening with nothing to name refuses the offer and records
  `veto-offer-omitted`.
- **Ad-hoc receipts no longer become case law.** Today's canonical cited the two 07-26 ad-hoc
  runs as followed precedent, so demo receipts were seeding the chain real convenes cite. The
  precedent pool now admits only receipts sealed by a named (non-ad-hoc) bench.

Both omission and refusal are RECORDED, never printed: `council convene --json` is consumed by
callers that capture `2>&1`, so a warn on stderr corrupts the envelope (caught by
`council_capture_e2e.sh` during this build). Regenerated `cmd_council.sh` via gen_cmd.

## Unreleased — fix(task): a recurring template that the scheduler SKIPPED now says so, instead of reading exactly like one it never reached (DIVE-2237)

The materializer's skip-if-open dedup is right for a chore: don't pile up dailies when the
assignee is behind. Two properties made it dangerous for anything that reports on the
present. The skip is unbounded — one unclosed instance stops the template firing forever,
not for a day — and `last_fired_at` moves only on a successful INSERT, so a suppressed
template and a template the scheduler never reached produce the SAME reading on
`task ls --recurring`. The only trace was `_hb_log`, which nothing surfaces.

Measured 2026-07-28: the nightly recap (DIVE-176) missed a whole day, and per the wiki note
`recap-lateness-delays-gate-aging` that recap is the only thing that surfaces human-gate
AGE. So the failure mode is not a missed chore — it is an alarm switching itself off, with
the suppressed artifact being the one that would have reported it. Four gates sat 3-5 days
unread. Four other templates were skipped the same night.

The dedup is UNCHANGED and still fires exactly when it did. What changed is that a skip is
now on the record: a new `last_skipped_at` column stamped on every tick the template was due
and deliberately suppressed. Read together the two columns separate the cases that used to
look identical — recent `last_skipped_at` with a stale `last_fired_at` means suppressed and
a human must close the blocker; both stale means the scheduler is not reaching the template
at all. `task ls --recurring` gains a `last_skipped` column and a `blocked_by` column naming
the open instance doing the blocking, derived from the same predicate the materializer
dedups on, so the listing cannot tell a different story than the scheduler. `--json` carries
both for the dashboard.

Whether skip-if-open is the right POLICY for templates whose output is a reading of the
present (recap, version loop, scoreboards) as opposed to fungible chores (disk reclaim) is a
separate call and deliberately not made here: Tuesday's recap is not satisfied by
Wednesday's run, but changing the dedup is not needed to make a skip visible, and the two
should not ride together.

## Unreleased — fix(ask): a reply fence whose markers sit INLINE is now harvested, so a grok seat stops reading as a silent abstain (DIVE-2216)

`agent ask` returned nothing from a grok seat that had answered correctly. Reproduced
live on the released 0.16.32, twice, on the demo box's `creative` seat:

    $ 5dive agent ask creative "Reply with exactly: ALIVE-2216"
    error: no idle reply from 'creative' within 120s (msg_id=1f18a833) — the reply
    fence was OPENED but never completed …

    (the same pane, verbatim)
         <5dive-r:1f18a833> ALIVE-2216 </5dive-r:1f18a833>               3:08 AM

The fence was complete and the answer was between its markers. The extractor accepted
a marker only when it was **alone on its line**, and grok compresses whitespace: the
opening marker is followed by the answer, so no block ever opened. For the prose shape
(closer pushed onto the end of the last line) the block was rejected outright as an
echoed instruction. Every grok seat in the fleet was affected on every fenced ask,
and a council ballot from one auto-abstained without a visible reason (DIVE-1739),
quietly lowering the effective roster — the failure class DIVE-1901 exists to remove.

The exact-line rule is not wrong, it is just the wrong discriminator. It is kept as
the first pass; when it finds nothing, an inline pair is now accepted **only if the
text between the two markers is non-empty**. The echoed instruction carries them
ADJACENT by construction (`<5dive-r:ID></5dive-r:ID>`, how the hint is written), so
its between-text is empty however the composer wraps it — including the wrap that
defeated DIVE-1901 iteration 1, which is pinned as a test. Content is judged by the
same shape rule the strict matcher uses (a TUI draws punctuation and box glyphs,
never words), so a gutter glyph beside the closing marker does not read as an answer.
An unclosed fence still returns nothing, so the rail keeps polling.

Graded on three verbatim `capture-pane` dumps from the live seat: 8 of 11 assertions
are red on the shipped extractor and green after, while the 4 that stay green on both
trees are the strict-path and anti-echo ones — the guarantees the change must not buy
its fix with.
5 of 5 mutants killed on the committed tree. Verified end to end against that same
seat, back to back:

    installed 0.16.32 : rc=11 after 120s, nothing returned  (the seat had answered)
    this build        : rc=0 in seconds, "FIXED-2216"

KNOWN LIMIT, pinned as a test rather than left to be found. When grok WRAPS its reply
at the pane width, the TUI paints its right-margin clock on that first visual row,
physically between the markers, so `3:21 AM` comes back inside the answer. Removing it
would mean recognising a right-margin clock — a per-harness chrome signature, which is
what DIVE-1901 refused to grow. The answer itself is intact and a ballot line survives,
so the silent abstain is gone; a caller doing an exact string compare against a wrapped
grok reply should expect it.
## Unreleased — fix(heartbeat): an UNMEASURABLE tier no longer disables the privilege-escalation-by-queue guard (DIVE-2213)

Second instance of the DIVE-2210 shape, at a **decision** site rather than a display
one. DIVE-1065 refuses to auto-drive a higher-tier agent from a lower-tier creator's
task. It read both tiers as `jq ... '.agents[$n].isolation // empty' 2>/dev/null`,
ranked an empty result `0`, and then skipped itself whenever either rank was `0` — so
a lookup that never happened did not hold the task, it **disabled the check**, and the
heartbeat auto-ran the work.

The ticket framed the fix as a binary: hold everything unmeasured (fail closed, may
stall the fleet) or wake with a loud log (fail open, no longer silent). It is a false
binary, and rank-0 is what disguised it. Two populations shared that bucket and they
want opposite policies:

- **measured, no tier** — the creator is not a registered agent (a human, an external
  filer). The majority of the board. Falling through is DIVE-1065's intent, not a
  failure mode; holding here would stall every human-filed task fleet-wide.
- **not measured** — registry absent/unreadable/unparsable, jq errored, or a
  *registered* agent whose `isolation` is missing or malformed. No basis to rank
  either side.

Only the second holds now. A healthy registry never produces it, so this cannot stall
the fleet in steady state, and every hold names its own cause in the tick log.

Measured by extracting the guard block **verbatim** from both this tree and
`origin/main` and driving the same nine causes through each
(`tests/heartbeat_tier_guard_unmeasured_unit.sh`):

    distinct decisions across 9 causes: OLD=2  NEW=3
    OLD: WAKE WAKE WAKE WAKE WAKE WAKE WAKE HOLD:escalation WAKE
    NEW: WAKE HOLD HOLD HOLD HOLD HOLD HOLD HOLD:escalation WAKE

The pre-fix block auto-ran on **6 of 6** unmeasured causes while still holding the one
real escalation — i.e. it looked like a working guard.

`agent_tier()` + `tier_unmeasured()` (`src/lib/registry.sh`) draw the line.
They are deliberately **not** `envelope_tier()`, which reports `unknown:unregistered`
for both populations on purpose (a wire format has no decision to make);
`envelope_tier()` is asserted byte-identical to `origin/main` so DIVE-2210's shipped
wire format does not move.

**Reachability, stated rather than overclaimed:** pre-fix, a whole-registry failure
could not reach this guard at all — the wake loop enumerates agents from the same
`$reg` blob, so a failed read yielded zero agents. Reachable pre-fix were the three
that leave the registry loadable: a registered-but-untiered creator, a malformed tier,
and a jq failure. The other three become reachable *after* this change, because
`agent_tier()` re-reads at decision time and so also catches a registry that dies
mid-tick.

Third instance, display-only: `task show`'s `created_by_tier` line was printed only
when the lookup returned non-empty, so on failure the line vanished and a reader could
not tell "no tier" from "not measured". It is now always printed, in three
distinguishable states. This changes `task show`'s human output shape for every task;
checked first — `origin/main` across 5dive-cli / api / app / plugins / mcp has no
consumer of that line other than the site emitting it, and the machine path is
`--json`, which never carried it.

## Unreleased — fix(a2a): the envelope's tier= field is now always stamped, with a reason when it cannot be measured (DIVE-2210)

`tier=` is the ONE unforgeable field in `[5dive-msg from=X id=Y tier=Z]`. `from=` is
caller-supplied (`--from=`) and only format-validated, so `tier=` is the field that
actually catches a cross-tier peer. Every stamping site wrote it as
`[[ -n "$t" ]] && header+=" tier=$t"` over a lookup whose stderr went to `/dev/null`.

Measured against the shipped 0.16.33 bundle by extracting its own `registry_read` and
`cmd_send` stamp verbatim: four different outcomes render **one identical envelope**.

    [control ] real sudo caller, good registry : [5dive-msg from=community id=deadbeef tier=admin]
    [cause 1 ] no sudo caller (--from=)        : [5dive-msg from=community id=deadbeef]
    [cause 2 ] registry missing/unreadable     : [5dive-msg from=community id=deadbeef]
    [cause 3 ] registry truncated (jq fails)   : [5dive-msg from=community id=deadbeef]
    [cause 4 ] genuinely untiered sender       : [5dive-msg from=community id=deadbeef]
    distinct envelopes across 4 causes: 1

So a receiver could not tell *not measured* from *measured, nothing there*. The
forgeable field survives; the unforgeable one disappears without a trace. Cause 1 is
the sharp edge: `--from=community` with no sudo caller produced a clean, plausible
envelope attributed to community and carrying no tier at all.

- New `envelope_tier()` **never returns empty**. A tier it cannot establish is stamped
  `unknown:<reason>` — `no-caller`, `no-registry`, `registry-unreadable`,
  `registry-unparsable`, `lookup-failed`, `unregistered`, `malformed-tier`. The four
  causes above stop colliding.
- New `registry_read_checked()` separates "the read failed" from "the fleet is empty".
  Plain `registry_read()` manufactures `{"agents":{}}` for both, which is what let a
  failed read render as a clean absence.
- A tier value that is not a bare token is refused (`unknown:malformed-tier`) rather
  than pasted into a space-delimited header, where it could forge extra fields.
- All three envelope builders now append `tier=` **unconditionally**. `agent ask`'s
  direct-inject path carried no tier at all — it was never added when DIVE-1064
  stamped `send` and `_deliver`.

Reading the new output: absence of `tier=` now means "sent by a build older than
0.16.35", not "this sender has no tier".

NOT changed here, and deliberately named rather than folded in: the same
swallow-and-omit idiom appears at two non-envelope sites — `cmd_heartbeat.sh`'s
privilege-escalation-by-queue guard (a *decision*, and it fails open: an unmeasured
tier ranks 0, and the guard is skipped entirely when either rank is 0) and
`task show`'s `created_by_tier` display line. Both are filed separately; the first
changes fleet-wide auto-run behaviour and needs its own verification.

## Unreleased — feat(digest): a 30-day window, with the aggregates it does NOT scope named out loud (DIVE-1921)

`digest` offered only `--7d`, so `proof scorecard` (specified as `[--7d|--30d]` in DIVE-1914)
shipped 7d-only and refused `--30d` outright. The value is not the flag: a 7-day window is why
the scorecard's median recovery time rested on ONE episode and its precedent acceptance on n=2.
On the live store the 30d window takes those to 2 episodes and the verifier first-pass rate to
n=335 graded.

Widening is not uniform, so each aggregate was classified before it moved:

- **Sums** (`done`, `zeroHuman.*`, `autoCleared`, `stuck.episodes`) and **rates**
  (`precedentPrefill.acceptanceRate`, `stuck.mttuSec`) scale with the window, as intended.
- **Point readings** (`usage`, `loops`, `health`, `inProgress`, `blocked`, `stuck.openStuck`,
  `autonomy.uptimeDays`, the objectives' `current`/`inflight`) do NOT. `usage` is the collector's
  own rolling 5h/7d read and `loops` is every loop ever, so under a "last 30 days" header they
  read as 30 days of tokens. They are now named in a `pointInTime` map in the JSON and captioned
  in the text.
- **`window.label` was a `>=` ladder** (`"7 days" if window >= 604800`), so any window wider than
  a week rendered under a "last 7 days" header. It is now derived from the window.
- **`autonomy.priorWindowComplete`** is new. The trend compares against the preceding window, so
  a 30d reading reaches 60 days back. The live store does not go that far, which rendered as
  `↑595 vs 0 prior 30 days` — growth from zero, on a span that simply has no data. The flag makes
  the text say so.

`proof scorecard --30d` is unblocked and its window now moves as one unit: the digest sub-call,
all nine SQL spans and the token read derive from a single mapping, because a site left at 7 days
would not render as a wrong window but as a plausible rate whose numerator and denominator were
measured over different spans.
## Unreleased — fix(heartbeat/task): a verifier who filed a human gate has ACTED, and neither verb may resolve that gate by side effect (DIVE-2196)

The stall-sweep nagged a verifier who had already reviewed the work and escalated a policy
question to a human. It selects delivered maker->verifier rows on `status NOT IN
('done','cancelled') AND handoff_ack_at IS NULL`, and a row BLOCKED on an unanswered gate
satisfies both: `blocked` is not a closed status, and filing a gate stamped no ACK, so
"reviewed it and escalated" was byte-identical to "never opened it". Fired live on DIVE-2146.

The remedy it prescribed was the harm. On a maker->verifier task the verifier's ACK *is* the
close, so "run `task start` then `task done`/`task reject`" asked them to resolve a pending
human gate as a side effect of an ordinary acknowledgement, in whatever direction the verb
happened to point. DIVE-2146's gate asked lodar to choose between leaving the ticket open and
closing it as delivered; the nag pushed one of those options on a schedule.

- **The sweep skips a row blocked on an unanswered gate.** The wait there is on a human, not on
  the verifier. An ANSWERED gate does not exempt: the wait is back on the verifier, and that row
  is still surfaced.
- **Filing a gate on a row delivered to you stamps `handoff_ack_at`.** Same receiver rule as
  DIVE-1378's `task start` ACK: the real actor only (never `--from`), only while they hold the
  row as its assigned verifier. The record now says what happened.
- **`task reject` refuses over an explicit tier-2 gate.** It auto-answers the gate with
  `need_answered_by='auto:reject'`, a non-human provenance the tier-2 floor exists to forbid and
  that `task answer` refuses outright, reached around by raw SQL. `task done` was already
  refused (DIVE-555). Scoped to an agent actor and to an EXPLICIT tier: a human caller is the
  party the gate is waiting on, and an untiered legacy row keeps DIVE-1495's supersede, so the
  CNCL-9 re-nag fix is untouched.
- **`task verify --cmd` no longer auto-closes over an open gate either.** It closes by raw
  `UPDATE`, so it never saw DIVE-555 — one `task verify --cmd=true` closed a task out from under
  an unanswered human gate and the question then vanished from every open-gate view, which all
  require an open status. That is DIVE-2067's lesson on this axis: the refusal on `task done`
  names other verbs, and the named verb carried no equivalent check. The verify VERDICT is still
  recorded; only the close waits, and `--no-done` is unaffected.
- **The refusal prints a reachable exit, per caller.** A guard that forecloses the FAIL verdict
  with nothing but "wait for the human" converts a wrong-but-moving state into a correct-but-stuck
  one, and gets routed around. If you filed the gate you can retire it yourself
  (`task need --withdraw`, archived to `gate_history` as a withdrawal rather than an answer put in
  a human's mouth) and then reject. If someone else filed it you cannot retire their ask, but your
  grade need not wait on it: `task set-body --append` records the verdict now and the reject lands
  when the gate clears. Both paths are executed in the tests, not just quoted in the message.
- `tests/verifier_gate_ack_unit.sh` grades all three by mutation. The first fixture was VACUOUS:
  with the ACK stamp in place, deleting the sweep's exclusion left the suite green, because
  `handoff_ack_at IS NULL` was doing the skipping. Two fixes for one symptom, one standing in
  for the other. The arm now runs on a live-gate/no-ACK row, which is DIVE-2146's shape today
  and the shape of every gate-blocked row already on the board.

## Unreleased — fix(gate): a gate escalates from the agent that FILED it, not from whoever created the task (DIVE-1945)

`task gate-escalate` derived the gate's filer as `COALESCE(created_by, assignee)`. Those agree
only when the filer also created the task. When one agent files a gate on another's task the
privileged re-send therefore started the escalation walk on the CREATOR's branch of the org
chart, and the alert read "filed by <creator> (no channel of its own)" about an agent that may
well have one. It is the bug DIVE-1927 fixed on the `task need` path via the `TASK_GATE_FILER`
env pin, surviving in the sibling path: `gate-escalate` is a separate privileged process, so
that env var cannot reach it and the filer has to come off the row.

- **`tasks.gate_filed_by`** records the filer of record, stamped by `task need` from the acting
  agent, read back by `gate-escalate`, and cleared by `task need --withdraw` with the rest of the
  gate provenance. Legacy gates have no stamp and fall back to `created_by`, so nothing in flight
  changes behaviour.
- **The heartbeat T1 re-nag lane moves too.** It resolves the reviewer FROM the filer's org
  position, which is the same whose-ask-is-this question. The T2 lane deliberately stays on
  `created_by`: it batches by the channel OWNER, where `created_by` is the right key.
- `tests/gate_filer_of_record_unit.sh` grades it on a two-branch org fixture (dev3 -> qa ->
  olivia, main -> olivia) so the correct and the buggy reading deliver to DIFFERENT agents; the
  legacy no-stamp row is the non-vacuity control.

## Unreleased — feat(comms): the terse rule now bounds HOW OFTEN you send, and covers agent-to-agent (DIVE-2191)

DIVE-1613 ships a terse-comms fragment into every claude agent at create. Measured against one
day of main's own traffic, it has two holes. It governs SHAPE, not VOLUME — main followed all six
shape rules 94 times in a day. And it is scoped to human chat, while agent-to-agent was 84
messages / 32,823 words: 2.2x the word volume of Telegram, on a channel with no rule at all. Every
a2a word is output tokens for the sender AND input tokens for the receiving model, so it is the
larger bill by more than 2.2x — and it is the bill the customer pays.

- **A send gate for human chat.** A NEW message — the one that pushes to their phone — is for
  finished / blocked-on-them / your own error. Everything else edits the message already on screen
  or goes to the task board. Work-in-progress is not a message. Phrased to compose with the
  telegram fragment's edit-for-progress rule rather than contradict it.
- **A fixed a2a shape:** RESULT / EVIDENCE / BLOCKER / NEXT, empty fields dropped. Fixed fields
  cannot ramble and the receiving model can parse them. Today's internal messages were 390-word
  essays carrying maybe 60 words of decision.
- **The verification rails are untouched, and now explicitly carved out**: this cuts the narration,
  not the checking. Sending work to another agent to verify, and answering as the verifier, is the
  work — the fragment says so in the same breath, so no agent reads "send less" as "verify less".

## Unreleased — feat(task): the tier-2 floor says WHY it fired, and a design decision can appeal it on the record instead of by rewording (DIVE-2089)

The T2 category floor reads SUBJECT MATTER as risk and picks the gate's audience from it. dev3
filed a tier-1 sizing gate — "should an agent's right to act derive from the credentials it holds,
or from a declared clearance level?" — and it was forced hard-human because the ask contains
"credentials" and "privileged". The gate discusses credential handling as a design question and
performs no credential operation. Talking about credentials is not handling credentials.

Two things made that worse than a mis-tier. It was **silent** — dev3 only found out by re-reading
their own filed gate, so an agent that files and moves on leaves a design question in the founder's
inbox indefinitely. And the workaround was to **re-file with neutral wording**, which works, teaches
the fleet to launder vocabulary to reach the right audience, and leaves no trace of having been
done.

- **The floor now names the term that fired.** `[tier forced to 2 — T2 category floor: matched
  'credential']` on the result, plus a stderr warning at file time. For a `decision` gate it also
  states the sanctioned appeal, and says not to reword the ask — the laundering path is now the one
  the tool argues against, instead of the only one it leaves open.
- **`--discusses="<why>"`** appeals a floor that fired on subject matter. It is a declaration, not
  another guesser: there is no phrasing that reliably separates "discussing X" from "doing X", so
  the filer states it, on the record. Unlike a reworded ask it is attributable, written into the
  gate the reviewer reads, and audited whether it applies or is refused.
- Four guards, and the declaration is not trusted on its own: `--type=decision` only (approval /
  manual / secret / access declare an action by construction); only when the floor actually
  over-fired; never for money, outbound customer comms, or irreversible infra/access, however it is
  framed; and it downgrades only to a **lead-routed tier 1**, never to tier 0 and never to the
  filer. An explicit `--tier=2` still vetoes it, and every refusal is loud.

Deliberately not a sixth keyword class. DIVE-2099's design note is explicit that inferring this from
more vocabulary reproduces the bug with the polarity reversed, where a false negative routes a real
secret gate away from the human.

**No existing gate changes tier.** Nothing moves unless a filer passes the new flag, which discharges
the DIVE-2146 precondition by construction rather than by enumeration. Measured while checking it:
the DIVE-2146 self-restart gate never tripped the floor at all — it reached the human because it was
re-filed with an explicit `--tier=2`. Kept as a live assertion, so if the floor is ever widened to
catch it, that test goes red first.

The matched term also rides the `--json` payload as `floor_term` (null when nothing floored). An
agent filing with `--json` previously got `tier_floored: true` and no way to learn which word did
it, which leaves the machine reader in exactly the state this change exists to fix.

`tests/gate_floor_declared_discussion_unit.sh` — 45 assertions, every arm exercised on the ask axis
and on the TITLE axis (DIVE-1957: a suite that varies only the ask tests the axis a filer can
already reword, and passes vacuously).

## 0.16.33 — fix(push): the author check refuses when it cannot bound the range, instead of grading the whole history (DIVE-2161)

Reported by dev2, who pushed a one-commit branch that was correctly authored and got back
"author check FAILED ... the range is UNBOUNDED" followed by hundreds of old commits listed
as author violations. Every one of them was a phantom.

`5dive push` bounds its author scan by fetching the target repo's main and taking a
merge-base. It discarded that fetch's exit status and its stderr, so when the fetch failed
the scan silently widened the range to the branch's ENTIRE history and reported every
pre-policy commit in it as a violation. "I cannot determine which commits this branch adds"
and "your branch has hundreds of bad-author commits" are different facts, and the tool
printed the second whenever the first was true.

The bound is now treated as a measurement that can be unavailable:

- A fresh fetch bounds the scan authoritatively, as before.
- A fetch that succeeds but finds no common ancestor is a real finding — the branch shares
  nothing with that main, so the whole branch genuinely is new to it, and the message now
  says that rather than blaming an unreachable remote.
- If the fetch fails, a cached `refs/remotes/origin/main` is used instead and the output
  says the bound may be stale, naming why the fresh one was unavailable.
- With no bound at all, root's authoritative pass REFUSES and names what is missing and how
  to restore it. It prints no commit list, because there is no honest list to print.
- The agent-side pre-check SKIPS with the reason instead of refusing: a delegated pusher has
  no GitHub credential by design, so no bound is a normal state there. Root still enforces.

The dry-run's author line now reports which bound the verdict rests on, so a scan that was
skipped or fell back to a cached ref no longer prints a flat "ok".

Failed fetches also get a named cause — no credential, an unwritable `.git/` (a root-owned
`FETCH_HEAD` left by an earlier root-run fetch, which is what dev2 hit), unreachable remote,
or git's own last line rather than a paraphrase of it.

Covered by mutation arms in `tests/push_unit.sh`: re-widening the range brings the phantom
list back, dropping the cached fallback re-breaks the reported case, and removing the
pre-flight skip hard-fails a credential-less push. A harness that only exercises the
resolvable path would pass forever while this defect stood.

## 0.16.32 — fix(agent): `agent rm` no longer leaves the home dir for a recycled uid to inherit (DIVE-2138, gh#222)

Reported by A-MO7SEN (gh#222), his fifth confirmed find.

`agent rm` deleted the user but left `/home/agent-<name>` on disk, and `adduser` RECYCLES
freed uids. So the next agent created inherited a removed agent's uid and, with it,
ownership of that agent's home — `auth.json`, `credentials.toml` and channel `.env` files
included. On his box four live agents each owned a dead agent's home. Not a privilege
escalation, but nothing about `agent rm` suggests it leaves that behind.

The same leftover also broke re-creating a previously-used name, and broke it in the worst
order: `adduser` only WARNS on an existing home, so create sailed past it, registered the
agent in `agents.json`, attached it to the team bot, and only then died on the first write
into a directory it did not own — leaving a half-created agent in the registry.

Both halves are fixed as one teardown-completeness pass:

- **`agent rm` quarantines the home** to `/home/.5dive-reaped/<name>-<ts>`, root-owned
  `0700`. Quarantine, not delete: an agent home can hold work the operator still wants, and
  teardown is not the moment to make that call irreversibly. `--purge-home` deletes instead,
  for the operator who has already decided. Either way a recycled uid inherits a number and
  nothing else. The disposition is in the JSON receipt, so a remove that could NOT move the
  home aside is visible to a scripted caller and not only to a `warn` nobody reads.
- **`agent create` refuses up front** when `/home/agent-<name>` exists and is not owned by
  the user the create would make. The check sits next to the name-conflict check, before any
  mutation — the point of the bug is where the old failure landed, not that it failed. The
  message names the path AND the owning uid, because on the reported box the owner did not
  resolve to a name at all (uid 1006, no such user).

His third suggestion — a uid-allocation map so a recycled uid cannot inherit stale state —
is not implemented and is not needed for this: with the home gone from its path, there is no
stale state left for the recycled uid to be handed. Same incomplete-teardown class as
DIVE-1609 (the `agents_org` orphan), which is why it is one pass.

Regression: `tests/agent_home_teardown_unit.sh` (17 assertions), including the guard that
keeps the recursive `chown`/`rm -rf` off any path that is not this agent's own conventional
home, and off a symlink at that path.

## Unreleased — fix(proof): the daily publisher no longer dies on its own log, and a successful tick finally says so (DIVE-2044)

The public zero-human badge stopped publishing for 26 hours and every signal said the
job was running. The publisher logic was never the problem.

**The cron line was `… 5dive proof tick >> /var/log/5dive-proof.log 2>&1`.** The log
had been re-chowned to a user the cron could not write as, so the shell failed to open
the redirect and **died before `5dive` was ever executed**. cron still logged the CMD
line every night, so `journalctl` showed a healthy job for a publisher that had not run
once. Proven, not inferred: appending to that file as the cron's user returned
`Permission denied` before the ownership fix and succeeded after.

The redirect is now **gone from the generated cron line**. `proof tick --log=<path>`
hands the path to the tick, which writes its record **after** the publish and falls back
to journald (`journalctl -t 5dive-proof`), then stderr, when the file is unwritable. An
unwritable log now costs a log line, never a publish — the work must not sit downstream
of its own observability. `proof status` detects a pre-fix cron line and rewrites it in
place (with a loud warning when it lacks the rights); an install-time permission check
cannot cover a permission that changes months later.

**A successful tick used to print nothing at all.** The log's entire content across the
outage was one *skip* line, so "published fine" and "never ran" produced identical logs.
Every run now leaves one stamped line naming its outcome — `PUBLISHED` (with the stamp
it recorded), `no-op — already published`, or `FAILED rc=N` — with the publisher's own
output indented beneath it. The DIVE-2051 identity refusal stays non-zero and is named
as such.

The staleness monitor read `raw.githubusercontent.com`, which is CDN-cached and was
still serving the previous day's stamp minutes after the real publish landed (the
DIVE-2042 window again). Its verdict now comes from the GitHub API ref, with raw kept
as a labelled fallback and its disagreement written to the log rather than silently
resolved in the CDN's favour.

## Unreleased — fix(agent): typed sends REFUSE a credential/login pane, so an inter-agent message can no longer become the agent's API key (DIVE-2137, gh#214)

Reported by A-MO7SEN (gh#214), his fourth confirmed find.

`agent send`/`ask` checked that the target pane was ready to receive keystrokes but never
what the pane WAS. An agent that booted unauthenticated parks on its login menu, where codex
draws the same composer glyph it draws in chat — so every readiness marker matched, the
message was typed into the API-key field and submitted, and the message body became the
agent's stored credential. Silent in both directions: the caller got `delivered`, and the
agent went on authenticated with a garbage secret.

Typed sends now fingerprint the pane first and FAIL CLOSED, returning a hard error naming
the cause instead of typing. The guard sits on the single inject choke point
(`inject_and_submit`) that `send`, `ask` and `_deliver` all funnel through, plus the
heartbeat's `_hb_send_line` — a fourth site with the same blind spot, reached on an
autonomous tick with nobody watching. `agent auth`'s deliberate login-code inject is
explicitly left unguarded, and that boundary is asserted in the tests.

Fingerprints are read verbatim out of the shipped codex and claude binaries rather than
written from assumption, and the login-menu tier requires a co-occurring PAIR of menu rows:
a single-substring match over the whole pane refuses ordinary traffic, since agents discuss
credentials constantly (measured on live panes, not supposed). Screens we could not sample
are declared as uncovered in the test file rather than guessed at.

The trigger is fixed too. The credential seed in `5dive-agent-start` selected its source on
mere EXISTENCE, so a box whose canonical profile was absent fell back to a 0600 root-owned
legacy path that a standard-isolation agent cannot read; both arms of the read then failed
and the only record was a `warn:` line in a log nobody reads. The seed now selects on
READABILITY, distinguishes a missing source from a present-but-unreadable one (a perms
fault, not a missing login), and leaves a breadcrumb the send-side refusal reads back so the
failure is named at the moment it bites rather than at boot.

Also fixes the seed unit test itself, which ran the shipped blocks in an environment where
their own helpers were undefined — a mutation to the failure path left it green.
## Unreleased — fix(agent): the sudo-grant measurement can finally see a PEER, via one privileged read (DIVE-2135)

DIVE-2079 and DIVE-2088 (below) replaced a stored label with a measurement. The measurement
was caller-scoped: `/etc/sudoers.d` is `0700 root`, so a non-root caller could read only its
own drop-in and every PEER came back `unknown`. Measured on this host: `agent info <peer>` as
another agent, and as `claude` — the account the dashboard's exec tunnel runs as — both
printed `unknown`. That is honest, and strictly better than the false `admin` it replaced,
but the problem those tickets exist to solve was only un-lied-about, not solved: a fleet
survey of nothing but `unknown` is also the shape a reader takes for a broken column.

`sudo_grant_lines` now has a last-resort privileged read. Where the direct read is refused it
asks `sudo -n` to do it, so a caller that holds real sudo (root, and `claude`) gets a real
class for a peer. A caller whose sudo is scoped to one binary — every agent this CLI
provisions today — is still refused, and still reports `unknown`. That difference is the
feature working, not a shortfall: the answer is the caller's own capability, honestly stated.

The refusal path is the part under test. A denied, unavailable, or truncated privileged read
reports `unknown` — never the stored label, and never a measured `none`. Absence and denial
stay distinguishable (DIVE-2120).

`agent list` performs ONE batched privileged read for the whole fleet instead of one exec per
row. `agent info` keeps the per-row read; it resolves a single agent. Sharing the measurement
does not oblige sharing the call pattern: 16 agents on this host means a per-row fallback
would write 16 auth-log rows every time anyone runs the survey, and the predictable end state
of the noisiest writer in the audit log is that someone silences it. A batch that only half
succeeds is discarded whole, so rows it could not cover never inherit rows it could.

New harness `tests/agent_sudo_fallback_unit.sh` (44 assertions), stubbed at the single
privileged-exec seam so it grades this code rather than the sudo policy of whoever runs it.

## Unreleased — fix(agent): `agent list` carries the measured sudo grant too, so the SURVEY surface stops reading as authoritative (DIVE-2088)

DIVE-2079 (below) fixed `agent info`, the per-agent drill-down. `agent list` was outside
that ticket's scope and kept emitting `isolation` — the same unmeasured stored label — with
nothing beside it. That left the honest command as the one you run once you already suspect
a problem, and the dishonest one as the command that would have told you to suspect it: a
fleet survey rendered `root-all`, `cli-root` and `cli-scoped` agents identically.

`agent list` now measures each agent with the same `agent_sudo_grant` DIVE-2079 introduced
(deliberately the same instrument, not a cheaper proxy under a friendlier name) and reports
it in `--json` under the same `sudo` object shape `info` uses, so one schema serves both
readers. The table gains a `SUDO` column carrying the measured class plus a marker — `!`
when the enforced grant contradicts the stored label, `+` when unrecognised sudoers entries
sit alongside a recognised grant — with the explanation left to `agent info`. A grant that
could not be measured from where the command ran prints `unknown` and says so in a legend;
it never falls back to the label. Only a root caller can measure a peer, so a non-root
caller now honestly sees `unknown` for everyone but itself. No existing field changed.
(DIVE-2135, above, later widened that last point: a non-root caller holding real sudo can
measure a peer through a privileged read. A caller scoped to one binary still cannot.)

## 0.16.20 — four merges that landed at 0.16.19 and could never have reached a box (2026-07-26)

Version assignment, not a feature. `0.16.19` was already published when #218, #219, #220 and
#221 merged, and the no-bump-in-a-PR rule assigns the version **at merge, by merge order** — but
nobody performed the assignment. So four merges sat on main claiming a version that already
described a *different* bundle.

That is the exact DIVE-2065 incident: the shared-checkout updater is **version-triggered, not
content-hash triggered**, so every box already on 0.16.19 would have kept its old binary forever
and silently never received any of this. `version-uniqueness` caught it on the push to main and
turned main red, which is the job working.

What this version actually carries:

- **DIVE-2112** — `task reject` could reopen a closed task, destroy the verifier's ACK, and file
  the write under a verifier who never made it. Attribution now names the real actor, the maker
  cannot reject its own delivery, a graded task is not reopened by anyone but its grader, and a
  prior result is preserved rather than replaced.
- **DIVE-2072** — a repo-tracked hook protects only branches that contain it, so a guard added to
  main is silently absent on every branch cut before it. A missing hook cannot announce its own
  absence, so the detection lives in CI at PR time, where the remedy is still a rebase.
- **DIVE-2101** — the DIVE-1830 merge-gate demanded a merged PR the delegated-push path can never
  produce, making it unsatisfiable rather than strict. Branch-tip ancestry is now accepted
  alongside the merged-PR search, with an attribution arm so a zero-commit branch cannot close a
  task by being trivially an ancestor.
- **DIVE-2072 follow-up** — the rule-2 assertion graded string interpolation rather than message
  distinctness, and stayed green under a mutation that folded both messages into one template.

No tag and no GitHub release: releases are batched, not cut per patch.

## 0.16.19 — fix(gate): audit the gate answer at the WRITE — a `decision` answer was stored with no audit event behind it (DIVE-2090) (2026-07-26)

Reported three times in one day, from three directions, and each report reached for a more
exotic mechanism than the one actually there. The measured signature was a stored, signed,
nonce-bearing gate answer with nothing in the audit log to attribute it to — which is exactly
the property DIVE-756 exists to provide.

`cmd_task_answer` emitted `task answer gate` rows from its **pre-checks only**: the
approval/secret/manual/access human-evidence block, and the tier-2 provenance-floor refusal.
Neither fires for a `decision` gate below tier 2. So the answer UPDATE — which stamps
`need_answer`, `need_answered_at`, `need_answered_by`, `need_answered_uid` and the DIVE-756
closure signature — ran with **no audit call anywhere near it**. On the live board: **at least
78** answered `decision` gates, not one of them auditable — measured 2026-07-26 17:16 UTC as
`need_type='decision' AND need_answered_at IS NOT NULL AND need_answered_by NOT LIKE 'auto:%'`
(127 across all gate types). That count drifts upward with every gate the fleet answers, so it
is a lower bound at a moment, not a fixed fact; the finding is that it is greater than zero and
that `decision` is our most common gate type.

The divergence ran **both ways**, which is why the fix is a row at the write rather than a
louder pre-check. The pre-check row is logged *before* the write and records that a CHECK
passed, so an approval that clears the evidence block and then trips the tier-2 floor — or
either `--value` usage `fail` — leaves an `ok` row behind with no answer stored at all.

Fixed by emitting one row immediately after the UPDATE, for every `need_type`, reporting the
provenance **as stored**. The write-site row is discriminated by `answered_by=`, a field no
pre-check site carries, so "an answer was written" and "a check passed" are now separable in
the log. Fenced on store identity like its siblings (DIVE-2054/2010) so a fixture store cannot
mint real-looking gate rows, and `|| true` so a log that cannot be written never fails an
answer that is already durable. The answer value is never logged.

## 0.16.18 — fix(agent): an unmeasurable sudo grant no longer renders as the genuine class "custom" (DIVE-2098) (2026-07-26)

`isolation_implied_by_grant` ended in a catch-all `*) printf 'custom'`. **`custom` is a real
member of that vocabulary**, so the *absence of a measurement* rendered as a confident privilege
claim. Measured live on the control plane, same caller, peer row `agent-main`: implied isolation
read `custom` where the truth is legacy root-all — wrong by two steps, and wrong in the
reassuring direction.

Guarded at both layers: the helper maps `unknown` and any unrecognised class to `unknown`, and
the `agent info` projection emits **null** rather than a string, because every other member of
that field's vocabulary is a definite class.

Why DIVE-2079's suite stayed green through this: **the test re-implemented the `diverges`
predicate rather than driving the real projection — and a copy of one field cannot catch a bug
in the field beside it.** The new harness drives the actual `cmd_info` projection over a fixture
state dir as a non-root caller: 4 graded failures on pristine main, 37/37 after, and mutation-
graded per layer so reverting either guard alone is still caught by the other.

## 0.16.17 — fix(loop): a collided loop_id killed the panel's own INSERT, and the harness poller then hid it (DIVE-2083) (2026-07-26)

The red main on `73752da` was **two defects in one chain**, and each was separately dismissed
as "not the cause" before the original job log settled it.

`_loop_new_id` minted handles from a one-second epoch plus 15 bits of `$RANDOM`, under a
`TEXT PRIMARY KEY`. T8's panel drew a handle T7's fan-out had taken seconds earlier, so the
**panel's own INSERT died** — the row never landed, `wait_new_run` had nothing to count, the
empty handle sent the kill to `loop_id=''`, and the panel polled a row that does not exist
until its `--wait` deadline. Collision was the trigger; the poller was the amplifier.

Fixed all three layers: a collision-proof `_loop_new_id` (nanoseconds + `BASHPID` + 32 bits
from urandom), a poller that fails loudly instead of returning an empty handle, and a new
`haltReason` field (`complete|killed|ceiling|timeout`). That last one exposed a fourth defect:
**the ceiling test had never once exercised the ceiling** — the product collapsed ceiling and
timeout onto the same `escalated` status, so the assertion passed on a timeout every run.

## 0.16.16 — fix(proof): hoist the self-bundle resolver to one implementation; proof scorecard and digest were grading the INSTALLED bundle (DIVE-2080) (2026-07-26)

Third instance of the `command -v` primitive, one call deeper than the previous fix reached.
DIVE-2061 fixed `selfcheck` probe 7 to resolve the bundle under test — then
`cmd_proof_scorecard` re-resolved `command -v 5dive || $0` and shelled `digest` into the
**installed** bundle. On every agent box, the metric rows probe 7 graded came from a different
artifact than the one under test. The same line sat in proof badges and in `cmd_digest`'s own
sources.

Hoisted to one implementation, `five_self_bundle` in the new `src/lib/self.sh`. Scorecard,
badges and digest's three sources use it and fail loudly when self is unresolvable.
`_digest_tick` deliberately keeps `command -v`, with the rationale recorded at the site: root
sudo-re-execs `digest --send` as another unix user, where the installed CLI is the correct
answer and a worktree bundle may be unreadable to `agent-<name>`. Per-site judgement, not a
blanket substitution.

## 0.16.15 — fix(heartbeat): a /goal dispatched onto a verifier-loop task could only be satisfied by bypassing the verifier (DIVE-2063) (2026-07-26)

The heartbeat's `/goal` nudge accepts three terminal states: `done`, `cancelled`, or
blocked-with-a-gate. A task carrying a maker→verifier loop reaches none of them by the
maker's own hand — a correct `task done` **delivers** it (status stays `todo`, the task
moves to the verifier, `handoff: delivered (awaiting verifier ACK)`). That is the rail
working as designed, and it is the one outcome the goal refuses, so the maker's session
kept re-firing "not done yet" with nothing productive left to do but wait on a peer's
independent session. Four instances across three agents in one morning.

The failure mode that matters is not the wasted turns: the only actions that WOULD have
satisfied the goal were the fail-open ones (a second `task done`, or dropping the
verifier). A guard whose only satisfiable path is dishonest eventually gets satisfied
dishonestly.

The nudge now names delivery as a second terminal state — but only for a genuine loop.
The clause is keyed on the loop spec, not on status text: it is emitted only when a
`verifier` exists, is someone other than the woken agent, and the agent currently owns
the task; and the state it tells the agent to look for is the `handoff:` line that
`task show` prints only once `task done` has actually recorded the handoff. Writing a
result and walking away does not produce it. An agent woken to *grade* gets no clause —
for the verifier, the terminal close really is theirs.

## 0.16.14 — fix(agent): `agent info` reports the ENFORCED sudo grant beside the stored isolation label (DIVE-2079) (2026-07-26)

`isolation` in the registry is a stored label, and nothing kept it honest. The DIVE-1002
v1->v2 migration stamped `isolation: "admin"` on every pre-existing agent without reading
its sudoers file, and `create_agent_user` is the only writer of a drop-in — so a legacy
agent holding `(ALL) NOPASSWD: ALL` and a modern one holding the CLI-scoped grant both
printed `isolation: admin`. Measured on poke-two 2026-07-26, that was six agents with full
root and four with the scoped grant, all reading identically. Two agents reasoned about
their own privilege from that field and got it wrong in opposite directions.

`agent info` now measures the grant (`sudo -l` where permitted, else the managed drop-in)
and classifies it as `root-all` / `cli-root` / `cli-scoped` / `none` / `custom`, reporting
runas breadth separately — every grant this CLI writes is `(root)`-only, so the ability to
`sudo -u claude ...` is what actually separates the two `admin` populations. When the label
and the grant disagree, `info` says so and names the enforced answer as the one to trust.
An unmeasurable grant reports `unknown`, never a guess. JSON gains a `sudo` object and
`isolationLabelled`; no existing field changed.

Also states outright in the `write_admin_sudoers` comment that `/usr/local/bin/5dive *` is
NOT equivalent to `NOPASSWD: ALL` the way `systemd-run *` is, and what the no-runas-target
grant does and does not withhold — the aside that produced the misreading is now the point.

## 0.16.13 — fix(types): an omitted TYPE_* key degrades as documented instead of crashing under `set -u` (DIVE-2076) (2026-07-26)

Second of the two defects A-MO7SEN reported in #196 while registering a new agent type. A
bare `${TYPE_CHANNELS[$type]}` read under `set -u` made a type registered without that key
hard-crash `agent types` with an unbound-variable error naming the *array* rather than the
type — an error message that points at our internals instead of the missing key. Seven
readers fixed (the ticket named five); a `:-0` default now routes an omitted key into the
existing "type X does not support channels" path.

The sweep found a live instance rather than a future-type hypothetical: `cmd_auth.sh` read
`TYPE_API_VAR` / `TYPE_API_FILE` bare one line above a graceful `fail` written for exactly
the absent case, which even names hermes and openclaw. Both maps are sparse by design and
their comments claimed `cmd_auth_set` "already fails gracefully when a type isn't in this
map" — under `set -u` execution never reached that line, so 4 of 8 types (hermes, openclaw,
antigravity, pi) crashed on `auth set-key` instead of getting the message. **The comment
described behaviour the code did not have.**

## 0.16.12 — fix(install): TYPE_INSTALL for claude/antigravity/grok was gated on `command -v`, so a stray binary already on PATH suppressed the install forever (DIVE-2075) (2026-07-26)

Reported externally by A-MO7SEN as issue #196. The install recipes for `claude`,
`antigravity` and `grok` were each guarded by `command -v <tool> >/dev/null ||`, which asks
"is something by this name on PATH?" — not "is the thing we manage installed?". An unrelated
npm-global `claude` on PATH therefore satisfied the guard, the install never ran, and
`TYPE_BIN` was never created. The failure is permanent and silent: nothing errors, the tool
simply never appears where the product expects it.

The guards now key off the same `TYPE_BIN[...]` paths the verify step reads, so the gate and
the verification agree by construction rather than by coincidence. The one surviving
`command -v` inside `TYPE_INSTALL` is antigravity's trailing where-did-it-land fallback,
which is the correct use. The `cmd_auth.sh` reversal keeps an explicit `*_BIN` override
winning.

Same primitive as DIVE-2061 earlier the same day: **`command -v` answers a question about
PATH, and every use of it as a proxy for "our artifact exists" is a defect waiting for an
unrelated binary to shadow it.**

## 0.16.11 — fix(task): `task need` warns at file time when a decision gate lands on a branch-bound task (DIVE-2074) (2026-07-26)

A `--type=decision` gate only authorizes `push` when it is answered by that task's OWN
routed reviewer. A lead clearing it on someone else's behalf does not satisfy the push
guard (DIVE-2073) — the gate reads as answered and the push still refuses, which is a
confusing pair of states to debug after the fact.

`task need` now warns at file time when a decision gate is filed against a branch-bound
task, and points at `--type=approval` as the verb that actually unblocks a delegated push.
Also documents the `bundle-drift` / `version-bump-guard` split in CONTRIBUTING: the former
asserts `bundle == build(src)` and is version-independent, so a failing drift check is
never asking for a version bump.

## 0.16.10 — fix(update): `update --check` fetched only the bundle, so it had nothing to cross-check and read a stale cache generation as up-to-date (DIVE-2042) (2026-07-26)

`5dive update --check` printed `OK — CLI 0.15.34 is up to date` twice, several minutes
apart, while main was already publishing 0.15.35. It was not wrong about its own
arithmetic — it was answering a question it could not answer.

**The window.** raw.githubusercontent serves the bundle and its `.sha256` as two
independent cache objects, so for minutes after every push to main it can hand back a
stale bundle beside a fresh checksum. DIVE-1977 fixed this on the install path by
pinning; the same window has since been seen on the contents API too, so treat it as a
property of GitHub's read paths rather than of `raw/main`. The window itself is cache
physics and is not a defect.

**The defect** is what the checker did with it. `update --check` fetched only the
bundle — it never fetched the checksum at all, so it had nothing to cross-check
against. It read `FIVE_VERSION` off the stale generation, found it equal to the local
version and rendered a confident green. It could say up-to-date or behind, and a checker
that can only say yes or no says yes when it does not know. That matters past this host:
the window opens on every push to main, and main HEAD is what customer boxes self-update
from, so every ship had a period where a box asking "am I current?" was told yes and was
wrong. Transient, which is exactly what made it easy to dismiss.

Note the severity ordering against its two siblings. When the install guard hits this
split it REFUSES, loudly, and someone goes and looks. This one SUCCEEDS and hands back a
plausible wrong number, in the direction most likely to suppress the response — which is
why the most benign-looking of the three was the expensive one.

**Now three states: up-to-date / behind / INDETERMINATE.** Both reads go through one
`_published_cli_probe`, which applies two defences in order. It PINS — `git ls-remote`
rides the git transport, not the raw CDN, so it has no split-generation window; main is
resolved to one immutable sha and both objects are fetched from `raw/<sha>/`, where they
cannot disagree. Unresolvable falls back to `/main` rather than failing shut. And it
VERIFIES — the bundle we were actually served is hashed against the `.sha256` we were
actually served, which is the only propagation signal available on the unpinned path.
A disagreement is reported as indeterminate with a NON-ZERO exit, so an unattended
caller branches on status alone and never reads a green it was not given. The message
branches on whether the accusation is justifiable (DIVE-1977's rule): pinned names the
sha, unpinned says cache generations and to retry.

`supervisor`'s `cliStale` probe carried the identical defect and now shares the probe:
anything short of a consistent read leaves staleness `unknown` rather than minting a
`behind=false` for a box it did not measure. It already owned an `unknown` vocabulary
for a missing nightly log and still resolved this read confidently — a component that
has the right word and does not reach for it is harder to spot than one that lacks it.
`update --check --json` gains `source`, naming the ref the answer came from, so a
surprising number can be re-fetched at the exact identity that produced it.
`behind`/`stale` are unchanged and are now only ever emitted on the consistent path.

`tests/update_check_propagation_unit.sh` extracts the probe verbatim between its fence
markers and runs the shipped bytes against stubbed `git`/`curl` on a minimal PATH with
the REAL `sha256sum` — no network. It replays the incident byte for byte, and grades the
three render states as a set: the "no green here" assertions are only meaningful because
two positive controls prove the same harness can reach a green and a behind. The first
cut of the harness passed those negatives vacuously, on a command that had crashed for
want of `date` — a negative assertion is satisfied by absence, and a crash produces
perfect absence. Negative control (verification disabled) reds 8 of 17.


## 0.16.9 — fix(gate): a gate-delivery row could say `user=unknown` while asserting a confirmed send (DIVE-2073) (2026-07-26)

Maker dev3. `audit_log` now records `user=root` for *no invoking user by design* and reserves `unknown` for a genuine non-root resolution failure (behind an `_audit_is_root` seam, since `$EUID` is readonly). The delivery row additionally carries `via=<channel-owner-agent>` and `path=<file-time|renag|privileged-resend>`, with `TASK_CH_AGENT` cleared on a miss so an error row cannot borrow a stale owner.

Root cause was measured, not inferred, and it corrected the guess in the ticket: these rows land at `:NN:02` — the root heartbeat re-nag, which has no `SUDO_USER` and no `USER` — not the privileged re-send. Confirmed across the whole audit log: unknown-actor rows cluster at seconds :00–:04 (3/165/128/17/3) while actor-resolved delivery rows scatter with no dominant second. Instrumenting the guessed path would have left the actual producer emitting `unknown` on every run while the ticket closed green.

Surfaced by marketing from real DIVE-2050 rows. `via=` retroactively answers the question that left DIVE-1927's residual 2 unprovable: which bot delivered `message_id=691` could only be inferred from per-bot message-id spaces, and is now on the row.

## 0.16.8 — docs(selfcheck): the --full duration figure, with its conditions (DIVE-2039 follow-up) (2026-07-26)

`--full`'s documented runtime has been wrong twice, in opposite directions, and both
times for the same reason: a number published without its conditions.

- **~70min** was extrapolated from a per-harness rate sampled while a mutation e2e and
  CI polling were competing for the same box — 7x too high.
- **~10min** was a real measurement (10m21s, 164 harnesses, from a frozen bundle) but
  it was taken **with `--assume-clean`** and labelled "on an idle control plane" when
  the box carries 17 agent homes and its load was never recorded. main measured
  **21:44 bare** on the same box — which AGREES with it: bare runs each harness twice,
  and 21:44 is almost exactly double 10:21. The mode was the entire difference, and
  someone budgeting a CI timeout off "~10 minutes" then running bare would be killed at
  the ceiling and read it as a hang — the exact failure `selfcheck` exists to remove.

A duration is not a property of the code; it is a property of (mode, machine, load).
`--help` now separates the two things that were being conflated:

- **MEASURED**, mode stated on every row — `--assume-clean` 164/10m21s and 168/10m37s
  (3.79s per harness both times), bare 164/21m44s (7.95s). They agree, and the
  arithmetic is the check: bare runs each harness twice, so ~2x. Two `--assume-clean`
  runs four harnesses apart giving the identical per-harness cost is what makes it a
  rate rather than an anecdote.
- **BUDGET** — 30min with `--assume-clean`, 60min bare, own CI timeout, never
  interactive. Explicitly *not* a measurement: every observed run is well under it,
  because the failure it prevents is a timeout kill being read as a hang.

The earlier text called the fast figure a FLOOR, which read as a measurement sitting
below several faster observed runs. Also adds `--allow=` and `--assume-clean` to the
synopsis line, which listed neither.

No code path changes.

## 0.16.7 — re-land DIVE-2058 with real isolation; usage_collect now REFUSES to read production transcripts from a fixture run (DIVE-2069) (2026-07-26)

Re-lands dev2's TOP TASKS dispatch cross-check (DIVE-2058, backed out in 0.16.6 for
reddening main) with the isolation defect that made it uid-dependent fixed at the root.

**The bug under the bug.** `usage_collect` resolves an agent's transcript root via
`home_of()`, which honours the `USAGE_HOME_ROOT` seam and otherwise falls back to
`pwd.getpwnam("agent-"+name)`. The harness seeded fixtures under `$HOME`, so the two
agreed only when it ran AS an `agent-*` user. Where that broke it did not fail — it fell
back to the REAL agent homes and scored partial marks off the fleet's live transcripts
(721 files under `/home/agent-dev` alone). Read-only, so nothing was corrupted, but
"this harness passes" was partly a statement about production data, and that is
unfalsifiable from inside the harness: a real transcript tree looks exactly like a
well-seeded one.

**Three named assertions were passing on production data**, and this is the concrete
form of the finding rather than the hypothetical one. `dispatched` is a three-state —
`false` means "pins were seen this pass and none was yours", `null` means "no pins seen
at all, cannot say". The only `/goal` pin the fixtures seeded before the first read sits
three days OUTSIDE the reporting window, so in a genuinely isolated tree `have_signal` is
false and DIVE-90001 comes back `null`. The `dispatched=false` assertion and its two
downstream rendering assertions were satisfiable only because the real homes supplied
in-window pins. The harness now seeds its own in-window pin, so they mean something.

**Fail closed, fenced on STORE IDENTITY.** `home_of()` now refuses the real-home fallback
when the registry is not the production one, naming the remedy. Fenced on store identity
rather than a test marker deliberately: NONE of the three harnesses calling `usage_collect`
sets `FIVEDIVE_TEST`, so a marker-keyed guard would never have fired — including on the
harness that had the bug. An opt-in fence is a fence you have to remember; store identity
needs no env at all, so a harness that sets nothing is fenced by construction, including
ones nobody has written yet (DIVE-1968's lesson, same shape). Production is unaffected:
it reads the prod registry, so the fallback behaves exactly as before.

Verified: the harness is now byte-identical in behaviour whoever runs it — 9/9 as
`agent-dev` and 9/9 under a foreign `$HOME`, where it previously scored 6/2 by reading
real homes. Guard proven by mutation: a fixture registry with no seam exits 1 with the
refusal. `usage_coverage_unit` 11/11, `usage_presenter_coverage_unit` 26/26,
`digest_autonomy` 8/8, `digest_mttu` 9/9, and `5dive usage` on the live box unchanged.

## 0.16.6 — revert: back out 0.16.5's usage dispatch cross-check (DIVE-2058) — its harness reads real fleet transcripts and reddened main (2026-07-26)

Reverting my own merge, not dev2's analysis. `tests/usage_dispatch_flag_unit.sh` seeded fixtures under the real `$HOME` while `home_of()` resolves `pwd.getpwnam("agent-"+name)` with a synthetic `/home/agent-<name>` fallback. Those agree only where the running user IS an `agent-*` account. On CI (`runner`) they never meet: `probe_readable` reports `(readable, "nothing recorded")`, `.tasks` returns `[]`, and every assertion fails on an empty value.

Worse than the CI failure, found by dev while sizing the fix: with the seam unset and `$HOME` wrong, the fallback resolves to REAL agent homes — `/home/agent-dev/.claude/projects` holds 721 live transcript files — so the harness was scoring partial marks off the fleet's production transcripts. It never writes, so nothing was contaminated, but "this harness passes" was partly a statement about real fleet data rather than about its fixtures, and that is unfalsifiable from inside the harness. DIVE-1506's shape aimed at usage data.

I merged 0.16.5 by pushing DIRECTLY to main, so no CI ran before it landed; a local 9/9 was the only check, and that green was honest on a box where the hidden precondition held. Reverted rather than patched under a clock: exporting the existing `USAGE_HOME_ROOT` seam alone measures 1 passed / 7 failed (CI's exact signature, since it points at an empty tree), so the harness needs seam + fixture relocation + a fail-closed guard that refuses when the seam is unset instead of falling back to real homes. The attribution fix is sound and re-lands with that harness.

## 0.16.4 — chore(release): the DIVE-2059 follow-up (E_CONFLICT for start-on-recurring-template) shipped in a commit that reused 0.16.3 (2026-07-26)

Process fix, not a code change. c97a4f9 and 2472df2 both carried FIVE_VERSION 0.16.3 with DIFFERENT bundles, because the version bump intended for the follow-up failed silently on a permissions error while the push succeeded. This entry gives the follow-up its own version so no two bundles claim one.

## 0.16.3 — fix(task): `task start` on a recurring TEMPLATE silently killed the driver, post-DIVE-2055 (DIVE-2059) (2026-07-26)

DIVE-2055 made the materializer's fire predicate require `status='todo'`, which is what
finally made `cancel`/`block`/`park` real stop levers on a template. It also created a new
failure mode: `_task_status_cmd` had no `kind='recurring'` guard, so `task start
<template-ident>` set `status='in_progress'` — a status the materializer never fires on —
with no error and no output. The template just stopped firing, and since `task ls
--recurring` now also defaults to the live predicate, the stopped template vanished from
the default listing too; only `--recurring --all` still showed it.

- `_task_status_cmd` now refuses `start` when the target row is `kind='recurring'`,
  naming the real stop levers (`cancel`/`block`/`park`) in the refusal. `cancel`/`block`/
  `park` on a template are untouched — those are the DIVE-2055 stop levers and remain the
  only meaningful way to retire one.
- New `tests/task_start_recurring_guard_unit.sh` (7/7): start-on-template is refused with
  status/schedule intact, cancel/block on a template still work, start on an ordinary task
  is unchanged. Full `tests/task_*_unit.sh` and `tests/heartbeat_*_unit.sh` suites re-run
  clean (the pre-existing `task_deliver_merge_gate_unit.sh` Tb/Tc failure is unrelated —
  reproduces identically on `origin/main` before this change).

## 0.16.2 — fix(selfcheck): harness-verdicts reported PASS having probed ZERO harnesses (DIVE-2061) (2026-07-26)

Found by main dogfooding the freshly-rolled 0.16.0 on the live control plane, minutes
after DIVE-2039 merged. Same binary, only the cwd differing:

    cwd = a 0.16.0 checkout  -> "... — 3 wired"  verdict: pass
    cwd = a stale worktree   -> "... — 0 wired"  verdict: pass   <-- nothing measured

`0 wired, no failures` was read as "no failures found, therefore pass". It means
**nothing was measured** — zero coverage folding into green, which is precisely the
NOT-REACHED-is-a-third-state rule this verb exists to enforce, broken inside it. It also
weakened the union: `tests/meta/selfcheck-union.sh` asserts every probe is REACHED
somewhere, so a probe passing on zero coverage satisfied the union while proving nothing.

Two fixes:

- **Zero probed is never a pass.** An empty corpus is `not-reached (empty-corpus)` —
  environmental, nothing to measure. A POPULATED corpus that yielded zero is `error`,
  which exits non-zero and, critically, is **not** counted as REACHED by the union. It
  is deliberately `error` and not `fail`: the rail is not broken, the MEASUREMENT was
  misdirected, and `fail` would falsely accuse the harnesses of being unwired.
- **The corpus is named, and so is how it was chosen.** Resolution walks up from cwd and
  this host carries ~10 `5dive-cli-wt-*` worktrees at assorted versions, so an operator
  silently got a verdict about a tree they were not thinking about. Both
  `harness-verdicts` and `bundle-integrity` (same resolver, same hazard) now print
  `[corpus <path> (N harnesses, how)]`, the same self-evidence probe 7 gained from
  `[graded <path>]`.

The durable lesson is about coverage, not this bug: **mutation coverage is
per-DIMENSION.** `harness-verdicts` was one of the four mutation-covered probes and still
had a hole, because every existing mutation varied the HARNESS and none varied the
CORPUS — they always ran with a good one present. "This probe is mutation-covered" is not
a property of the probe; it is a property of (probe, input). `tests/selfcheck_mutation_e2e.sh`
now varies the corpus too, reads the sample list from the bundle under test rather than
restating it, and asserts its own mutation actually removed something.

## 0.16.1 — fix(audit): fence the remaining `cmd_task.sh`/`cmd_heartbeat.sh` audit_log sites on TASKS_DB store identity (DIVE-2054) (2026-07-26)

- **Follow-up to DIVE-2010**: 21 more task-store-driven `audit_log` call sites (merge-gate
  overrides, `task precedent`/`task routing` toggles, gate-tier2-pin escalation, `task need`
  auto-clears/lead-route, `task gate-escalate`, `gate-proof verify`, `task answer lead-clear`/
  `gate`, `task reclaim`, and the 4 `cmd_heartbeat.sh` gate-ttl/shipped-flag sites) now route
  through `_task_store_audit_log`, so a fixture `TASKS_DB` can no longer write a fixture-ident
  row into the real fleet audit log from any of them.
- **5 sites were deliberately left unfenced**, each with an in-code reason: `task need withdraw`
  (`asserted_from=`), `task clear-recs` and `task inbox send` (carry `chat`/`chat_proof=
  $channel_proof`), `task answer escalate-to-human`, and `gate-proof mint` (carries no
  TASKS_DB-derived data at all). Fencing these would trade a contamination bug for an
  evidence-suppression bug — the same fail-open family DIVE-1968 exists to prevent.
- **New regression lock**: `tests/audit_task_store_classification_unit.sh` fails if a future
  `audit_log` call in either file has neither marker — forcing classification instead of a
  silent default either way.
- Two `cmd_heartbeat.sh` suites that stubbed `audit_log` as a shell function (defeating any
  internal fence) gained explicit on-store/off-store proof cases so the fence on those sites
  is actually exercised, not just inert.
- **Verified by mutation, and the mutation itself needed correcting** (dev3): run literally,
  reverting each fence reported 0 of ~21 sites leaking — a FALSE NEGATIVE on 14 of 17 live
  sites, because the suites exercising them stub `audit_log` as a shell function, so
  unfencing routes the call into the stub rather than the log being diffed. Measuring the
  fence's own ALLOWED/WITHHELD decision instead (immune to downstream stubbing) proved 119
  withheld calls across 12 distinct sites. Residual stated, not rounded away: 5 sites are
  reached only on-store (open side proven, closed side not) and 3 (`gate-proof verify`,
  `task need t0-auto`, `task reclaim`) are reached by no suite at all and remain unmeasured.

## 0.16.0 — `5dive selfcheck`: prove the rails ACTED, not that they reported (DIVE-2039) (2026-07-26)

Opens v0.16 "Fails loud" (epic DIVE-2038). Every check we owned graded a rail on
what it REPORTED. This one grades it on what it CHANGED — the 24h that produced
0.15.8..0.15.30 had one dominant defect: a rail that reported success and changed
nothing (DIVE-2003 harness exit 0 with a stranded verdict, DIVE-1989 nine audit
sub-events gated on `$EUID`, DIVE-1968 gates filed and pinged recording nothing,
DIVE-1991 a snapshot exiting 0 having saved nothing, DIVE-1977 a bundle and its
checksum from two cache generations, DIVE-1929 a partial read rendered as a number).
None of them was catchable by running the rail and reading its output.

`5dive selfcheck [--json] [--only=] [--full] [--strict] [--allow=] [--report=]
[--label=] [--list]` runs each critical rail FOR REAL in an isolated
STATE_DIR/TASKS_DB/AUDIT_LOG and asserts the effect: a filed gate leaves a delivery
row carrying the channel it reached (both the silent-path `error` row + rc 3 and the
confirmed-send `ok` backfill); an audit row lands for an action, or a blocked append
leaves a drop marker; every harness's exit status is wired to its own verdict
(mutation, not a green run); the tracked bundle, its checksum and `src/` all agree;
committed crontab snapshots match the live crontabs and a save-nothing run exits
non-zero; and every scorecard row either says NO DATA and names what was missed or
carries a number and declares its coverage.

**NOT-REACHED is a first-class third verdict**, never folded into pass, and one with
no reason exits non-zero. Because a reasoned skip is correctly not a failure in any
single run, `--report=` + `tests/meta/selfcheck-union.sh` assert the invariant that
does survive: every probe is REACHED in at least one environment. CI now runs
selfcheck in three environments (pristine, installed-host, installed-root) and unions
them — `audit-root` and `audit-nonroot` are separate probes precisely because
DIVE-1989 stayed invisible for as long as the audit log was measured from one side.

Proven by MUTATION, not by a green run (`tests/selfcheck_mutation_e2e.sh`): **all seven**
probes are broken for real in a throwaway copy of the tree, selfcheck is required to go
red AND to name the breakage, then restored and required to go green. "It passed" is not
evidence for a prover of this defect class; "it failed when I broke it" is.

Review by main found two defects in the first cut, both of which the mutation coverage
now pins:

- **`scorecard-honesty` was blind.** It resolved the binary to grade as
  `command -v 5dive || $0`, and `command -v` wins wherever 5dive is installed — every
  agent's box. So a mutated bundle graded the healthy INSTALLED CLI: `./5dive proof
  scorecard` printed `0.42` for all seven metrics, including dimensions with no data
  source at all, while `./5dive selfcheck` reported ok and claimed "6 degraded to NO
  DATA". It graded a different artifact than the one it lives in and could not tell.
  Invisible in CI, where nothing is installed and `$0` won. Now resolved
  running-bundle-first, every candidate verified to BE a 5dive bundle, and the pass
  message names the artifact it graded.
- **`--full` ran >15 minutes writing zero bytes** and was indistinguishable from a hang.
  The duration is inherent (every harness, twice) and is now documented with an
  `--assume-clean` fast path, but the silence was its own defect:
  `tests/meta/harness-verdict-probe.sh` buffered every line into arrays and printed at
  the end, so `5dive selfcheck --full` inherited it. Both now stream per-harness
  progress to **stderr** — stdout stays clean for `--json` and the report, which is
  asserted.

## 0.15.41 — fix(task): no CLI lever stopped a recurring template — cancel/block/park all left it firing, and `task ls --recurring` disagreed with the scheduler (DIVE-2055) (2026-07-26)

- **the materializer's fire query keyed on `kind='recurring' AND schedule IS NOT NULL` alone — no status check.** A template moved to `cancelled`, `blocked` (via `task block` or `task park`, which both write status='blocked'), or `done` kept firing on its cron forever; none of the three CLI verbs that look like a stop lever actually stopped anything. Proven live on DIVE-1447: cancelled on 2026-07-25, it fired again the next morning and spawned an 8th void instance.
- **`_hb_materialize_recurring` now requires `status='todo'` too.** Since a template only ever leaves `todo` via cancel/block/park (or an errant `done`), this one-predicate fix makes all three verbs real stop levers with no new verb needed — cancel-stops-firing falls out of it rather than needing its own special case.
- **`task ls --recurring` now defaults to the SAME live predicate as the materializer** (`schedule IS NOT NULL AND status='todo'`), so the listing can't tell a different story than the scheduler. Previously a stopped template still listed with a blank schedule and its last (pre-stop) `last_fired_at`, reading as a driver that had fired recently. `--recurring --all` lifts the filter for an audit view of every template regardless of status, now also showing the `status` column.
- Verified: `tests/heartbeat_materialize_recurring_unit.sh` (new, 10/10) — one template per status (todo/cancelled/blocked/done) against a throwaway tasks.db; only `todo` fires or stamps `last_fired_at`, and the two `task ls --recurring` views partition correctly. Confirmed the test fails (7/10) against the pre-fix query. Full `tests/heartbeat_*_unit.sh` and `tests/task_*_unit.sh` suites re-run clean, no regressions.

## 0.15.40 — fix(proof): a customer box had NO git identity guard, and the badge publisher stamped whatever it found into PUBLIC commits (DIVE-2051) (2026-07-26)

- **the gap was that nothing in this CLI ever SET a git identity, anywhere.** Our own history is clean by convention, not by guard: this control-plane host carries a deliberate global identity, so nothing was ever left for an agent to invent. A customer box has no such convention. Git refuses to commit without an identity, which puts an agent one step from resolving one itself — and the most available value is the operator's personal email, because Claude Code injects it into every agent's system prompt by default with no opt-out ([anthropics/claude-code#81138](https://github.com/anthropics/claude-code/issues/81138), where it bit a user upstream by overwriting their repo's anonymized commit email with their personal one). Reproduced on our own fleet by two agents independently.
- **not hypothetical downstream: `proof publish` authors PUBLIC commits with whatever identity it finds, on a daily cron.** The evidence that the value really is ambient rather than pinned is our own status branch, which carries commits under two different author identities from the same publisher, decided by which user the cron happened to run as. On a customer box that ambient value is a personal address, published to a public repo, daily.
- **`proof publish` now REFUSES rather than guesses.** Resolution order is `ZH_GIT_NAME`/`ZH_GIT_EMAIL` > the identity pinned by `proof on --as-name= --as-email=` (new, persisted in `proof.json`) > the publishing user's `git config --global`. If none resolves, the publish refuses with its own exit class (`E_VALIDATION`, distinct from the generic failure so the cron log can tell "this box is misconfigured until someone acts" apart from "the network flaked tonight"), names all three ways to fix it, and publishes nothing. `--dry-run` refuses too, on purpose: a dry run that skips the check is how a box first learns it is misconfigured at 02:00 from cron.
- **the refusal has its OWN exit code (4), and the idempotent no-op keeps 3.** Caught in review by main: the first cut surfaced both as 3 at the verb boundary, and those are semantic opposites — "everything is fine and already done" vs "your config is broken and I refused". The caller that cannot tell them apart is the one that matters: `_proof_tick` maps 3 to success, so a box that lost its identity would refuse every night while the cron reported a healthy run — the same silent-stop as DIVE-2044 that morning (26 hours of no publishes reading as business as usual), reintroduced through a different door. The verb's exit contract (0 published / 3 no-op / 4 refused / other failure) is now written at the top of `cmd_proof.sh` and in `proof --help`, and both codes are asserted in the unit harness — including that the tick maps 3 to success and does NOT do the same to 4 — so they cannot converge again.
- **a HALF identity refuses as well.** Given a name and no email, git fills the gap with a synthesized `user@hostname` — the same guess in a different costume.
- **the authored identity is now passed through `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, not just repo config.** Config is the weaker source: an exported `GIT_AUTHOR_EMAIL` in the publishing shell overrides it, so a box that had pinned an identity could still have committed as whatever the environment carried.
- **provisioning no longer leaves it to inference:** `agent create` seeds each agent user a synthetic `agent-<name>@agents.noreply.5dive.ai` identity. Deliberately NON-CLOBBERING — an identity the operator already set always wins, on a fresh create and on a re-run — and a repo with an author policy of its own can still override it per-checkout.
- **`proof status` states the resolved identity and WHICH of the three sources it came from**, so an unset identity is visible before the cron finds it rather than after. It resolves as the CRON user, not the caller, since those are rarely the same account.
- **a false alarm was caught in this change's own status line and fixed before shipping.** Reading another user's `~/.gitconfig` needs root, and the first cut reported that failure as "identity UNSET — publish will REFUSE" — on a box that publishes fine. It now reports `not checked` and names the command that can check, because a confident claim about a check that never ran is the same defect as a false green, pointed the other way. Locked by a test.
- **the push author-gate now hands the seeded identity an instruction instead of a wall.** A new agent committing in a repo with an author policy will be rejected by `_push_author_scan` — the correct shape (a visible reject beats an invented identity), but the mitigation must not live as tribal knowledge. When the offending commits carry the synthetic `@agents.noreply.5dive.ai` address, the refusal now says so, names it as deliberate, and prints the repo-local `git config user.name/user.email` fix built from the configured author at runtime.
- **what this does NOT do, stated so the entry is not an overclaim.** It does not stop the harness from putting the operator's address in an agent's prompt (not ours to fix, and no opt-out exists), and it does not retroactively rewrite any identity already in a repo's history. It removes the path by which that injected value becomes the *operative* identity of a box.
- **Tests:** new `proof_identity_guard_unit.sh` (22/0) — refusal with nothing configured, under `--dry-run`, and on a half identity; the full precedence chain with the source named; a resolved identity passing the guard; the unchecked-vs-unset distinction; and the root cross-user path driven with stubbed `id`/`runuser` rather than left asserted by nobody. The harness pins `HOME`/`GIT_CONFIG_GLOBAL` to a temp dir so the runner's own git identity cannot make the refusal case pass for the wrong reason — this asserts a NEGATIVE, and an ambient identity would hide the failure. It also degrades to GRADED failures rather than an unbound-variable crash when run against a pre-fix tree (6/16 there, 22/0 here): main's review point, that a crash proves only "this file cannot run in that tree" while graded failures prove the assertions detect the defect. New `agent_git_identity_unit.sh` (7/0) — seeded when absent, never clobbered when present, idempotent on re-provision, half completed.

## 0.15.39 — fix(gate): a lead-routed gate emitted ZERO delivery telemetry and never reached the DIVE-1968 delivery assertion (DIVE-2011) (2026-07-26)

- **The DIVE-1968 delivery assertion did not cover the rail most builder gates take.**
  The lead-route branch of `task need` sent its handoff inline and `return`ed before
  `task_need_notify` was ever called, so "no gate exits without a delivery verdict"
  was true of the human ping ONLY. A routed gate wrote **no gate-delivery row at
  all** — not ok, not error — leaving the entire routed population invisible to the
  one dataset anyone consults to judge whether gates reach anyone. Measured instance:
  DIVE-1989's approval gate was filed and lead-cleared inside the post-assertion
  window and `gate-notify.log` holds nothing for it.
- **The routed send's exit status was structurally unobservable** — backgrounded
  subshell, both streams to `/dev/null`, `|| true` outside it — so `routed to X`
  printed whether or not X existed, was running, or had a live pane to inject into.
- Fixed by dispatch, not duplication: `task_need_notify` now routes to a second
  deliverer (`_task_need_route_deliver`) when `TASK_GATE_ROUTE_TO` is set, so both
  rails share ONE assertion. A parallel assertion would be a second thing to go
  inert, which is the failure mode being fixed.
- The send stays detached, because `5dive agent send` waits up to 45s for the
  receiver's input prompt and a busy-but-healthy peer burns that whole budget — a
  synchronous send would stall the filer on the common case, and a `timeout`-
  truncated one would kill the child *during* the readiness wait, before the inject,
  turning a delivered handoff into a lost one. Instead the child logs the terminal
  verdict itself and publishes its rc **after** the row lands, and the parent polls
  that rc for 3s: every fast-failure shape (unknown agent, dead tmux session, denied
  sudo, no CLI on PATH) is decided well inside that window, while a peer that is
  merely mid-turn finishes in the background.
- The printed claim never exceeds what was observed: `delivered` prints the plain
  routed line, a confirmed failure prints `HANDOFF NOT DELIVERED` plus a loud warn
  and names `5dive task answer <ident>`, and an unfinished send says
  `delivery not yet confirmed`. In-flight is reported as in-flight and **not** as an
  error — manufacturing error rows for healthy busy peers is the opposite-direction
  bias of the mis-measurement DIVE-1968 was filed on. JSON gains
  `delivery` + `notified`.
- The gate itself always stands: a failed *ping* is not a failed *filing*.
  `routed_reviewer` persists and `gate_pinged_at` stays NULL, so the heartbeat's T1
  re-nag (which already resolves recipients through `routed_reviewer`) escalates it
  within 15 minutes.
- `tests/gate_route_delivery_unit.sh` (new, 28 assertions) drives the failing send as
  well as the succeeding one — only the success shape was ever exercised before.
- **Harness change worth reading, not just noting:** four existing routing harnesses
  stubbed `task_need_notify` itself. Now that the wrapper is the shared entry point,
  that stub would fire the `HUMAN_PINGED` sentinel on a *routed* gate — reporting a
  human ping that never happened — and would suppress the route send those harnesses
  assert on. The sentinel moved one layer down to `_task_need_notify_deliver`, where
  it means what its name says. No assertion was weakened; all four are green
  unchanged otherwise.
- `_task_gate_delivery_log` takes an optional next-step clause: its failure warn
  used to say "trying a visible group fallback" unconditionally, which is true only
  of the Bot API path.

## 0.15.38 — fix(task): a maker's SECOND `task done` closed its own delivered task ungraded (DIVE-2007) (2026-07-26)

- **the delivered state was not durable against its own maker.** The maker→verifier routing test is positional — `verifier != assignee` means "hand off" — and delivery flips `assignee` TO the verifier. So the second `task done` from the SAME maker satisfied `verifier == assignee`, read as "the verifier's own close", and fell through to a real close: DIVE-1988 went `status=done` with iteration 1 still open and the verifier never grading. Corroborated from the other side the same hour (DIVE-2002, main), so the bypass is reachable, obvious under pressure, and was the path of least resistance.
- **the guard now keys on the ACTOR, not on who the row is assigned to.** While a loop is live and delivered (`maker_agent` recorded, `verifier == assignee`), only the verifier may close it; anyone else — the maker, or a third party — is refused with `E_CONFLICT`, audited to `policy_refusals` as `done-over-delivered-loop`. Position was never the question a close needs answered: *who is calling* is.
- **refused rather than re-delivered at iteration+1.** The alternative in the report would let a wrong `done` silently burn the `max_iterations` budget and escalate a loop that nobody rejected.
- **the refusal names the route that was missing.** There is still no `task note`/`task comment`/`task set-result` verb, and wanting to AMEND a delivered result is exactly what walked dev onto the closing verb — so the message says to send the correction to the verifier rather than re-run `done`, and names the three real exits (`task reject` by the verifier, `task verify --cmd=` for an evidence-backed close, `task cancel` to abandon). The missing verb is deliberately NOT fixed here (DIVE-1920 family) but it is the reason this footgun got pulled.
- **the adjacent maker-reachable close is left ALONE, on purpose:** `task verify --cmd=` still auto-closes for any caller, including the maker. That is the path DIVE-2002 took deliberately (real acceptance test + negative control) and this ticket's own body treats it as the honest alternative, so gating it too is a call for the verifier to make, not a silent widening here. main's ruling on it, recorded here so it is not re-litigated: verify stays open, because gating it would remove the only zero-human unblock for a STALLED AGENT verifier, and closing that path escalates every stuck loop to a human — a worse failure than the bypass this ticket fixes. A visibility mark on a maker's own verify-close (stamp the record + audit the self-verified close) is the right follow-up and is deliberately NOT shipped here, to keep a delivered diff from widening (main's call). `policy_refusals` is the WRONG sink for it and was ruled out: a self-verified close is PERMITTED, so recording it there would inflate the very honesty metric DIVE-1922 built that table to serve. The correct sink is `audit_log`, which already attributes agent actions and which `5dive trace` already renders per-ident — so the mark surfaces exactly where someone reading that task's history is looking. An earlier draft of this entry claimed no non-refusal sink existed; that was wrong (it surveyed only task-DB tables and missed `audit_log`, whose agent-caller path DIVE-1989 fixed via the DIVE-1268 privileged fallback — verified here: agent-dev and agent-main rows are both in the live log). Corrected rather than left standing.
- **what the guard does NOT stop, stated so the entry is not an overclaim.** It keys on `task_actor()` with no argument, whose last fallback reads `$USER` — an ordinary env var. So `USER=agent-<verifier> 5dive task done` still gets through when not under sudo. That is a DELIBERATE impersonation, not the accident this ticket is about (a maker reaching for the only verb in range to amend a result), and the accidental path is fully closed. Corroborating against `_gate_authenticated_actor` (DIVE-2004's kernel-identity resolver) was written and then REVERTED rather than shipped: it is unforgeable precisely because env cannot override it, which also means this env-impersonating harness cannot exercise its ALLOW side — every case would have refused the verifier's own legitimate close. A check whose allow-path cannot be verified, on the CLOSE verb, deadlocks every live loop on the box if it is wrong. Left for a follow-up that can test it with real uids.
- **Tests:** new `task_done_delivered_guard_unit.sh` (20/0) — first `done` delivers; the maker's second is refused with the row unmoved (`status`, `assignee`, `done_at`, `iteration` AND the delivered result text all untouched), audited, and the message names both the verifier and the amend route; the verifier's own close still works before and after ACK; a third party is refused; plain no-verifier tasks, an undelivered task the verifier already assigns, and the maker's `cancel` are all untouched. Verified NON-VACUOUS against `origin/main` via `git archive` (9 of 20 fail pre-fix, including the third party closing it outright).
- **CI caught a shadowing bug that every dev box hid, and the guard is narrowed because of it.** `task_actor()`'s last resort is the sentinel `cli` — "this invocation could not be attributed" (non-agent user, root cron, CI). The first cut refused that too, so on the CI runner (`$USER=runner`) this guard fired AHEAD of the DIVE-1830 merge-gate: an unmerged-delivery close was refused citing DIVE-2007 when the real problem was the unmerged PR, and a MERGED delivery was refused outright (`task_deliver_merge_gate_unit` Tb/Tc). Two costs — the reader is sent after the wrong rule, and a legitimate non-agent close is blocked by a rail aimed at something else. `cli` is now EXEMPT: the threat model is a MAKER, a resolvable agent, closing its own work, and DIVE-1988's maker resolved to `dev` and is still caught. An unattributable caller is a different question and not this ticket's to answer. This was green on two full local suite runs and red in CI, because `$USER` on a dev box resolves to an agent and on a runner does not — local green is not CI green, and the fix is locked by T9/T10 (the exempt actor is NOT refused and leaves no refusal row; a resolvable maker still is, so the exemption did not widen into a bypass).
- **one existing case changed meaning and was rewritten, not re-run:** `task_verifier_rail_unit.sh` T10e asserted "the re-pointed grader's own `task done` closes the task" while impersonating nobody — it passed on POSITION. It is now maker-first (refused, T10e) then carol-as-carol (closes, T10f), so it can no longer pass without an actor. 23/0. Also confirmed the obvious sibling bypass is already shut: T10d shows `task verifier` refuses re-pointing a review at its own maker.

## 0.15.37 — fix(task): fence audit_log on TASKS_DB store identity (DIVE-2010) (2026-07-26)

`cmd_task_need`'s "unnotified" audit row was gated on `$EUID -eq 0` instead of
store identity — the exact anti-pattern DIVE-1989 removed elsewhere — and
DIVE-1989's own regression grep (`tests/audit_nonroot_unit.sh`) never caught it
because the code split the pattern across a `\` line continuation, evading a
single-line grep for a full release. Measured leak: 6 real rows in the fleet
audit log with fixture idents (`DIVE-1..4`) from a 41-suite test run. Fixed by
dropping the `$EUID` condition and routing through a new `_task_store_audit_log`
wrapper that reuses DIVE-1968's `_task_human_send_allowed` store-identity fence
(withholding announced once, never silently); hardened the regression grep to
join line continuations before matching. Re-sweeping `tests/task_*unit.sh` and
`tests/gate_*unit.sh` surfaced 2 more live leaks at the same shape (`task
set-body`, `task.merge-gate-unverified`) — fixed the same way. Full
`task_*`/`gate_*`/`heartbeat_*` unit sweep after all fixes: 0 failures, 0 bytes
appended to the real audit log. See
`community/wiki/audit-log-store-fence-task-need-unnotified-dive2010.md`. ~13
other unconditional task-store `audit_log` call sites remain unfenced but
unmeasured; tracked separately as DIVE-2045.

## 0.15.36 — fix(task): GATE_PROOF_KEY/ENFORCE (and OPERATOR_STORE) were bound at SOURCE time, so an isolated STATE_DIR did not actually isolate them (DIVE-1950) (2026-07-26)

Systemic follow-up to DIVE-1919. `tasks_db.sh` derived `GATE_PROOF_KEY`/`GATE_PROOF_ENFORCE` from `$STATE_DIR` once, at source time. Every isolated unit harness sources the libs FIRST and re-points `STATE_DIR` at a throwaway temp dir AFTER — so those two stayed frozen on the pre-isolation default (`/var/lib/5dive` in production) for the harness's entire run. `_gate_proof_enforced()` then read the LIVE host's enforcement sentinel and `_gate_proof_ensure_key`/`_gate_closure_sign` read/wrote the LIVE key, from inside a test that believed it was isolated. That is exactly how `task_park_gate_guard_unit.sh` failed under DIVE-1919: a harness whose control path answers a gate with `--human` died `E_AUTH_REQUIRED` against a control-plane box (enforcement flipped on 2026-07-24) and passed against a clean CI runner. DIVE-1919 fixed that one harness by binding the two paths explicitly — the same two lines 8 sibling gate harnesses already carried — but roughly 53 harnesses re-point `STATE_DIR` after sourcing WITHOUT that binding and were latently exposed the moment any of them touched a gate path.

- Replaced the source-time assignments with lazy getters (`_gate_proof_key_file`, `_gate_proof_enforce_file`) resolved at call time off the CURRENT `$STATE_DIR`; updated every read/write site in `tasks_db.sh` and `cmd_task.sh`. An explicit `GATE_PROOF_KEY`/`GATE_PROOF_ENFORCE` env override — what the 8 already-fixed harnesses set directly — still wins, since the getters only supply the default when the var is unset.
- Audited `src/lib/agent_setup.sh`'s `OPERATOR_STORE` for the same shape, as DIVE-1950 asked. It is NOT a no-op: most harnesses that source `agent_setup.sh` re-point `STATE_DIR` the same way, so `_operator_record`/`_operator_ids` had the identical live-file leak, just never caught because no test yet exercised them in isolation. Fixed with the same lazy-getter treatment (`_operator_store_file`).
- `tests/gate_proof_lazy_resolve_unit.sh` (8 assertions) pins the actual isolation bug rather than just re-running the harnesses that already worked around it: it sources with one `STATE_DIR`, re-points to a second one WITHOUT any explicit `GATE_PROOF_*`/`OPERATOR_STORE` override (the ~53-harness shape), and asserts the getters resolve under the NEW dir, an enforcement sentinel left in the OLD dir does not leak in, one dropped in the NEW dir is read correctly, an explicit override still wins, and `_operator_record`/`_operator_ids` write/read only under the NEW dir. Verified this test fails (6/8) against the pre-fix code and passes clean (8/8) after.
- Re-ran the full gate/task/heartbeat/goal suite plus the 8 harnesses that already carried explicit bindings — all green, no regressions from routing every read through a function call instead of a bare variable.

## 0.15.35 — docs(task): correct the `_task_gate_delivery_log` comment — the real shape is org-unreadable, not absent-from-org (DIVE-2006) (2026-07-26)

Comment-only change, no behavior moves. The comment's "CORRECTION" paragraph (added
for DIVE-1968/PR #170) retired the wrong "absent-from-org, 13 of 28" number but left
no positive statement of what the real population or shape IS. DIVE-1988 re-derived
the gate-delivery population from the full 1330-row union: 112 in-window rows on 85
tasks — 11 error, 101 ok, 9 of the 11 later also `ok`. `absent-from-org` is zero
instances; the real shape is **org-unreadable** (every agent's `access.json` is
0600, unreadable to a peer). That shape has two distinct causes needing different
fixes — the comment now keeps them separate: the filer itself has no channel
(quinn, dev2, dev3 — seed a channel) vs. the filer's chain holds one nobody in that
context may read (`main` -> `olivia` — pass the FILER name into a root-privileged
probe). See `community/wiki/gate-delivery-telemetry-decontamination-dive1968.md`
(DIVE-1988) for the full derivation.

## 0.15.34 — feat(task): `task set-body` — no verb could edit a task body after filing (DIVE-1920) (2026-07-26)

`--body` was add-time only; the only remaining route to fix or extend a body afterward was a direct sqlite `UPDATE` on the shared `tasks.db`, which a scoped-sudo maker can't do and an admin correctly declines to do unilaterally. Hit three times in one night: a vague CONSIDER note that had to be respecified as a whole new task instead of rewritten in place, and two findings relayed over `agent send` instead of landing in the ticket they belonged to — the exact appending-is-not-compiling failure the wiki already names. For recurring TEMPLATES the cost is worse: a template filed with an empty body (DIVE-176) carries its instructions only in whoever remembers them.

- `5dive task set-body <id|DIVE-N> <text...> [--append]` — default OVERWRITES the whole body (the add-time behavior, now available after the fact); `--append` tacks the text on with a blank-line separator instead, since appending a finding to an existing body is the common case and a full overwrite invites clobbering someone else's context.
- Works on recurring templates the same as worked tasks — the DIVE-176 case.
- Refused on a closed (`done`/`cancelled`) task, the same "can't retro-edit a closed task" guard `task verifier` already enforces; the remedy is `task reject` to reopen first.
- `tests/task_set_body_unit.sh` (9 assertions) pins overwrite, append-onto-existing, append-onto-empty, the template case, the closed-task refusal (and that a refused write leaves the body untouched), and the bare-usage error.
- audit: `set-body` calls `audit_log` UNCONDITIONALLY (task, actor, mode `replaced`/`appended`, prior body
  length) — visibility only, no new permission check. It is NOT gated on `EUID==0`, and neither is
  `cmd_task_reject`'s own call: a root-only audit line is a no-op for the main non-root use case, which is
  exactly the anti-pattern DIVE-1989 removed from nine call sites fleet-wide in 0.15.26. A body carries the
  spec a task is graded against, so a silently rewritable one is a last-write-wins gap; `prior_len` is what
  makes a destructive overwrite distinguishable from an append after the fact.

## 0.15.33

- **`agent auth start` no longer wedges forever on a first-run onboarding TUI.**
  `pending_url` was indistinguishable from "still waiting on the IdP", so an
  antigravity session that never reached device auth — agy opens a colour-scheme
  picker and a Terms-of-Service + data-use consent screen on a profile with no
  prior login, and waits for keystrokes nobody sends — looked identical to normal
  progress and the operator waited indefinitely. `auth poll` now bounds the wait
  (`FIVE_AUTH_URL_TIMEOUT`, default 300s — measured, not guessed: agy 1.1.7 on a
  pristine HOME paints its login menu at T+2s and its OAuth URL at T+4s, so this is
  ~75x the healthy path) and fails LOUD with the last screen of
  the pane in `.paneTail` plus a hint when it recognises an onboarding wizard.
  The consent screen is deliberately NOT auto-advanced — a machine must not accept
  terms on a person's behalf — and a test canary fails if that changes (DIVE-1884).
- **`agent auth reap` — abandoned login processes are cleaned up.** Nothing used to
  reap auth sessions: an abandoned attempt left the login CLI resident indefinitely
  and its session dir behind forever. Two stages — non-terminal sessions past
  `--max-age` (default 1800s) are torn down and marked expired with a reason;
  terminal sessions past `--ttl` (default 86400s) have their dir removed. `auth
  start` sweeps first, so a box self-heals without a cron entry, and `auth cancel`
  now kills the tmux SERVER and the PTY child rather than just the session
  (exact pids only, never a process-group kill) (DIVE-1884).
- docs: `--help` notes that each auth session's login TUI lives on a PRIVATE tmux
  socket, so a plain `tmux ls` shows nothing, plus the attach command (DIVE-1884).

## 0.15.30

- **CORRECTION to the 0.15.27 entry.** That entry (and its commit message) stated it
  "records the deliberate ref-resolution coverage gap in the format-contract test".
  It did not: the scripted edit was a guarded no-op, so the note reached no artifact
  while both records claimed it had. The note is now actually in
  `tests/heartbeat_gate_shipped_unit.sh` case 10. The commit-message half of that
  false claim is immutable and is left standing rather than rewriting shared history
  (DIVE-2014).
- tests: assert field 3 is the COMMITTER date (`%ct`), not the author date (`%at`) —
  salvaged from the superseded PR #181. With `%at`, a commit authored long ago but
  merged AFTER the ask reads as predating it and is wrongly skipped, which is a
  silence of the exact class the DIVE-2001 guard exists to prevent. Our squash-merge
  flow makes the two coincide, so this was protected by intent and not by evidence;
  a rebase-merge would separate them. Negative control: swapping `%ct`→`%at` reds
  this assertion and exits 1 (it passed silently before).

## 0.15.29 — fix(push/gate): a DECISION gate cleared by its own routed reviewer could never authorize a delegated push (DIVE-2004) (2026-07-25)

- **the refusal blamed the reviewer who had cleared it.** `_push_gate_check` accepts `human:*` or `lead:*`, but `lead:` is minted in exactly one place (`cmd_task_answer`) and only for `approval|manual|access`. A `--type=decision` gate answered by its own designated `routed_reviewer` is therefore stamped a bare `main`, push refuses it, and the message read *"cleared by unauthorized provenance main — delegated push requires a human or a lead-clear (its designated routed reviewer)"* when the designated routed reviewer was exactly who cleared it. Two allowlists written in two places are one contract; when the consumer refuses a state only the producer can mint, the error blames the actor. Same wrong-cause shape as DIVE-1970.
- **the two candidate causes were both wrong, and both were settled by measurement.** Not the acting uid at push time — `_push_gate_check` reads only DB columns and never consults `id -un`/`$SUDO_UID`, so `sudo -u claude 5dive push` cannot move its verdict. Not the wrong reviewer — the live row had `routed_reviewer=main` AND `need_answered_by=main`, with a control from the same actor minutes earlier (DIVE-1956) stamped `lead:main`. The real uid dependency was at ANSWER time, the opposite end of the pipeline from where it was assumed.
- **push now asks the predicate it actually needs** — *was this authorized by the party it was routed to* — expressed as ONE rule at the consumer: `human:*` OR `lead:*` OR (`decision` AND answered by this gate's own `routed_reviewer`). Deliberately **not** widening `decision` into the lead-clearable set: DIVE-1243 keeping `access` out is evidence that set is CURATED, and the failure mode if wrong is leads clearing human-only things. Deliberately **not** forcing push-for-review to file as `approval` either — DIVE-1959's gate offered "cherry-pick | re-file after #16", genuinely a choice and correctly a decision.
- **the new acceptance is corroborated, because `gby == reviewer` alone is caller-writable.** `task answer --from=<reviewer>` writes `need_answered_by` verbatim, so the claim is checked against the stored `need_answered_uid` (DIVE-756 stamps the real pre-sudo invoker, and no flag sets it). Uid maps to a different agent, or to no agent at all → refused, and the message says which.
- **the more urgent half: `_lead_clear` authenticated on `$(id -un)` alone**, so even on an `approval` gate a lead clearing via `sudo`/root silently lost the `lead:` stamp. `_gate_authenticated_actor` now resolves the kernel-enforced identity — the real process user, or `$SUDO_UID` **only at EUID 0** (DIVE-1413: below root it is a plain env var, which is why DIVE-950 dropped the forgeable `--proof`). It **fails closed**: unidentified is never trusted, because the cost of a false empty is re-filing a gate and the cost of a false identity is a self-authorized push. Not resolvable from `task_actor` — that returns `--from` verbatim, which is the whole bug.
- **every refusal now names the stamp REQUIRED and the one FOUND**, instead of sending the reader off to audit a reviewer who did clear it.
- **and it is LOUD at file time.** The old refusal text documented `--type=approval` for push-for-review, so a filer with real options to offer could not follow the documented path — the tool advertised a route its own semantics punish. `task need` now warns at filing when an ask is push-for-review shaped AND `decision` AND unrouted, the one shape push cannot attribute to anybody. Narrow on purpose: the routed branch returns early, so reaching the warning IS unrouted, and a warning that fired on ordinary decisions would be wallpaper (DIVE-1955).
- **Tests:** `push_unit` +9 (reviewer-cleared decision passes; the `--from` spoof where the uid maps elsewhere is refused *naming the mismatch*; uid resolving to nobody fails closed; a non-reviewer decision is refused naming what was required; an `approval` with bare reviewer provenance is still refused, so the carve-out stays decision-only; and the real `_gate_agent_for_uid` maps a REAL non-agent uid (0/root) and an unassigned uid to EMPTY, since a non-empty leak there is one string-compare from authorizing) = **65/0**. `gate_ship_routing_unit` +3 (unrouted eng-ship decision warns; the SAME ask routed does NOT; a non-eng-ship unrouted decision does NOT) = **62/0**.

## 0.15.28

- tests: actually ship the `heartbeat_gate_shipped_unit.sh` exit-code fix (DIVE-2003).
  0.15.27's entry described this fix but the code did not contain it: during mutation
  testing a `git checkout -- tests/...` (intended to undo a mutation) reverted the
  unstaged fix, and the reverted file was then committed. The post-merge check —
  "harness exits 0 on a green run" — cannot distinguish fixed from broken, which is
  the same class of non-discriminating observation this whole ticket is about.
  Verified here by MUTATION, the only check that can tell them apart: with the guard
  deleted the harness now exits 1 (it exited 0 on 0.15.27 and 0.15.26).

## 0.15.27

- tests: `heartbeat_gate_shipped_unit.sh` exited 0 unconditionally (DIVE-2003,
  olivia's reject). Moving the tally `printf` to the end left `[[ "$FAIL" -eq 0 ]]`
  stranded mid-file, so the harness's status became the printf's constant 0 — and
  CI (`for t in tests/*.sh`) and `5dive task verify --cmd` BOTH grade on `$?`, so
  every future regression in the sweep would have passed green. The verdict is now
  the last command. Re-ran all four guard mutations grading on `$?`: previously all
  four exited 0, now all four exit 1. Also documents why the drift branch writes an
  audit row while the routine legacy-gate branch does not, and records the
  deliberate ref-resolution coverage gap in the format-contract test.

## 0.15.26 — fix(audit): the audit log recorded privileged operations, not agent actions (DIVE-1989) (2026-07-25)

- **the log we treat as ground truth systematically omitted every non-root agent action.** Nine `task` / `task need` sub-events were emitted as `[[ $EUID -eq 0 ]] && audit_log ... || true`. Measured side by side on a live box before the fix: `5dive task precedent off` run as `agent-dev` produced **zero** rows, and the byte-identical command under `sudo` produced one. `task precedent`, `task routing`, `task need withdraw`, `task need t0-auto`, `task need precedent-auto`, `task need lead-route` and `task reject gate-supersede` carry no dispatcher-level row of their own, so for those verbs the gated line was the **only** record that could exist.
- **the gate was honest and obsolete at the same time.** It skipped a write that really would `EACCES` on the 640 root:claude log — but DIVE-1268 gave `_emit_audit_line` a privileged, append-only `_audit_append` fallback months ago, which re-stamps the caller server-side so a non-root agent lands its row without loosening the file to a tamperable 660. The nine gates simply predate that fallback and never got removed. Every other one of the ~20 `audit_log` call sites is already unconditional.
- **so "absent from the audit log" did not mean "did not happen"** — the same absent-vs-forbidden conflation as DIVE-1927, one layer down and aimed at our own evidence base. DIVE-1988 had just finished naming the audit log as the fallback ground truth that the `tasks` table cannot provide, because `need_asked_at` is last-write-wins.
- **the second hole: a lost row left no trace anywhere.** Both append paths ended in a bare `|| true`, so a failed write evaporated. DIVE-1988 could not decide whether three DIVE-1801 error rows were dropped by the privileged fallback or were fixture-ident reuse, and no amount of re-reading the audit log could ever settle it — a drop is precisely the event the log cannot record. A failed append now writes a marker to `notify/audit-drops.log` carrying the lost row **verbatim**, so the gap is observable at the one place it was invisible. The marker goes to the 2770 `notify/` sibling and not to the audit log, because the whole premise is that this caller could not write the audit log; and it is explicitly `chmod g+w` on the **file** (DIVE-1888), or the first agent to drop a row would own the only writable handle and every other agent's drop would itself be a silent drop.
- **audit is still best-effort and still never speaks to the caller.** A full disk must not block a rescue `agent rm`. The marker is for the reader of the log, not the actor.
- **the rows written before this release keep the gap baked in, so `5dive trace` now says so.** `trace` is where an audit slice gets read as provenance, so that is where the caveat belongs — it prints that rows predating 0.15.26 omit non-root agent actions and that absence is not evidence, and it surfaces a per-ident drop count (`audit_drops` in `--json`) when markers exist. Documenting the limitation was mandatory regardless of the code fix, and a wiki page nobody opens mid-investigation is not documenting it.
- **removing the gates does not contaminate the fixture suites — verified by measurement, and the check found a PRE-EXISTING leak.** Worth measuring because the pre-fix gates were incidentally acting as a *contamination fence* for non-root test runs: a suite driving `task precedent` as an agent wrote nothing precisely because of the defect, so removing it could have turned 30 green suites into 30 writers of fixture rows into the fleet's audit log (the DIVE-1968 shape, re-run). It did not — seven suites exercising all nine changed sites added **zero** rows. But the full 41-suite run added **7**, and reading them is the finding: six are `task need unnotified` on fixture idents `DIVE-1`..`DIVE-4`, a call site that was **already unconditional before this change**, so it is pre-existing leakage the gates never fenced rather than a regression here. `audit_log` has no store fence at all — DIVE-1968 fenced `_task_gate_delivery_log` on store identity and the general path never got the same treatment, which is why the pending-gate **window** filter and not ident-existence remains the only valid decontamination filter. Filed as the follow-up; not widened into this diff.
- **`tests/audit_nonroot_unit.sh` holds both halves, hermetically** — isolated `AUDIT_LOG`, stubbed `sudo`, no root, no network. Seven assertions: the fallback receives the exact line, a failed fallback leaves a marker with its payload and reason, a delivered row leaves none, a non-JSON line yields no marker rather than a corrupt one, the marker is group-writable, **no `audit_log` call anywhere in `src/` is re-gated on `$EUID`** (the regression, as a grep), and a suite guard proving the run appended nothing to the fleet's real log. It **skips loudly rather than passing** when run as root, because `-w` is always true for uid 0 and the branch under test would be unreachable. Carries a negative control: reverting either half reds it 3/7.

## 0.15.25

- heartbeat: the ship-flag epoch guard no longer fails open SILENTLY (DIVE-2003).
  A drift in `_hb_repo_grep_ident`'s `--format` made the predates-ask comparison
  skip with no `_hb_log` line and no audit row, so a format drift and a DELETED
  guard produced the identical 8/2 test signature. Fail-open stays (withholding a
  legitimate flag is its own silence) but now logs `epoch UNPARSEABLE` plus a
  `degraded` audit row, and is kept distinct from the routine legacy-gate case of
  a missing `need_asked_at`. Adds a hermetic format-contract assertion that runs
  the REAL lookup against a throwaway `git init` repo, so the `%h %ct %s` field
  index can no longer drift unseen. `_c_epoch`/`_asked` are now `local`.

## 0.15.24 — fix(install): pin the bundle and its checksum to ONE commit sha — raw's cache race read as a tampered mirror (DIVE-1977) (2026-07-25)

- **a routine cache race accused us of shipping a tampered mirror.** `install.sh` fetched the bundle from `raw.githubusercontent.com/<org>/5dive/main/5dive` and validated it against `.../main/5dive.sha256`. Those are two *independent* CDN objects with independent cache generations, so for a window after every release raw can serve the **previous bundle next to the new checksum** — measured live minutes after 0.15.11 merged: bundle `FIVE_VERSION="0.15.10"`, sha256 the 0.15.11 hash. A clean clone at `main` was internally consistent the whole time; the divergence was entirely CDN-side, which is why "check the repo" proved nothing.
- **the fleet self-updates from `main` on a 04:00 cron**, so the window opened after *every* release, unattended, and the failure the operator woke to was `refusing to install (corrupt download or tampered mirror)`. The guard was right to refuse. It was wrong about why.
- **staleness is fine; INCONSISTENCY is not.** The fix resolves `main` to one immutable commit sha **once**, then fetches every managed asset from `raw/<sha>/`. If the resolver hands back a slightly older sha, both objects come from that one tree and the box installs the previous release for a few minutes — a non-event. A bundle from one generation checked against a checksum from another is unfixable at the client and renders as an attack. **The checksum guard is not weakened by one byte**; the race is removed underneath it.
- **resolution degrades, never bricks.** `git ls-remote` first (exact, no API rate limit), then the commits **atom feed** (unauthenticated, and not against the 60/hr `api.github.com` budget a NAT'd fleet would share), then the API. All three verified to return the same live sha. `GH_SHA=<sha>` pins directly for CI and rollbacks. If *nothing* resolves, the install proceeds from `/main` as before rather than failing shut — and only that path can still hit the race.
- **so the mismatch message now names the cause it can justify.** Pinned, both objects came from one immutable tree and a mismatch really is corrupt bytes or a tampered mirror — it says so, and names the sha. Unpinned, it says the two objects came from a mutable ref and may be **two CDN cache generations (a stale mirror right after a release)**, and to retry. It no longer collapses a cache skew into a security alarm.
- **an explicit `REPO` is never re-pinned** — the offline install-smoke bundle (`file:///opt/5dive-bundle`) and enterprise mirrors keep their own identity, and the code declines to *claim* a pin it can't vouch for.
- **`tests/install_pin_sha_unit.sh` holds it, hermetically**: the pin-resolution block is extracted **verbatim** from `install.sh` and run under its real `set -euo pipefail` against stubbed `git`/`curl`, so the harness asserts the shipped code with zero network. Ten assertions cover each resolver rung, the no-pin fallback, the `REPO`/`GH_SHA` overrides, that no fetch of the bundle or its sha256 reintroduces a hardcoded `/main`, and that the mismatch stays fatal. Carries a **negative control** — reverting the pin to `/main` reds it 2/10.

## 0.15.22 — fix(help): `--help` executed the commands quoted in its own help text (DIVE-2005) (2026-07-25)

- **rendering the help RAN it.** `_task_usage` is a `cat <<USAGE` heredoc with an **unquoted delimiter**, and its body quotes command names in backticks for readability. Bash performs command substitution on an unquoted heredoc body, so `5dive task --help` executed nine of them: `npm ci` (in whatever directory the caller was standing in), plus `5dive push`, `5dive usage`, `5dive gate-proof` and `5dive gate-proof enforce on`. The operator saw an npm failure dump and a usage error from an unrelated verb before the help they asked for. Same shape in `5dive --help` itself (`5dive hire --help`, `5dive push`, `doctor`) and `5dive pack --help`.
- **this is the worst possible verb to have a side effect on.** `--help` is what a confused operator runs, what a new user runs, what our own error paths print, and it runs with an arbitrary cwd. It is also the one command we tell people is safe.
- **the delimiter is NOT quoted, deliberately** — the first line prints `${STATE_DIR}/tasks/tasks.db`, and `<<'USAGE'` would render the literal variable name. So the fix keeps parameter expansion and kills command substitution by **converting the backticked names to plain single quotes** rather than escaping them: an escaped backtick is a booby trap for the next person to edit the block, and 37 of the 124 heredocs in `src/` have an unquoted delimiter.
- **swept the shape, and the SWEEP is the finding.** Of those 37, exactly **three** carried a live substitution — `cmd_task.sh`, `main.sh`, `cmd_pack.sh`. One more (`cmd_init.sh`'s `$(gh_org)`) is deliberate interpolation and is allowlisted by site. Three others (`cmd_proof.sh`, `cmd_goal.sh`, `lib/agent_setup.sh`) already escape their backticks correctly, so a naive "unquoted delimiter" grep would have churned working code; and `$(( x * (1 << attempts) ))` is an arithmetic shift that a naive grep reports as a heredoc. The distinction between *has an unquoted delimiter* and *actually substitutes* is the whole guard.
- **`tests/heredoc_substitution_unit.sh` holds it, two ways.** A static scan (escape-aware, arithmetic-aware, allowlisted by `file:delimiter`) plus a **behavioural** check that renders the usage blocks with tripwire executables named after every command the help text quotes and fails if any of them runs. The scan carries a **negative control** — a planted violation it must report — because a guard that cannot fail is not a guard. Verified red on the pre-fix tree: 3 of 9 assertions fail, including the tripwire.

## 0.15.21 — fix(push): the target repo is resolved from the WORK TREE, not defaulted to the CLI repo (DIVE-1970) (2026-07-25)

- **`5dive push` picked the CLI repo no matter which tree you were standing in.** `repo="${repo:-$_PUSH_DEFAULT_REPO}"` ran *before* the work tree was resolved, and the resolved tree was then never consulted — so the command knew which repository it was in and still targeted `5dive-ai/5dive`. Precedence is now `--repo=<url>` > **this work tree's own `origin`** > the built-in constant, and the constant is reached only when the tree has no github.com `origin` to read.
- **the cost was not the wasted push, it was the WRONG CAUSE.** With the target wrong, the author scan cannot reach that repo's `main`, silently widens its range to every commit reachable from the branch, and refuses with a list of ~18 commits belonging to a history the branch has nothing to do with. That reads as "my branch is dirty / my commits are bad" on a branch that is one correctly-authored commit ahead of its own origin, and the maker goes off rewriting authorship to satisfy it.
- **so the refusal now names the repo it checked against, and how wide it looked.** `author check FAILED against <owner/repo> (target resolved from <--repo | this work tree's origin | the built-in default>) — scanned <range>`, where an unreachable `main` is stated as **UNBOUNDED, not "your new commits"**. A wrong-repo run is self-diagnosing instead of accusatory. This changes the message only: no verdict flips, and the pre-existing full-range false-reject against squash-merge noreply authors (DIVE-1794) is deliberately untouched here.
- **`--dry-run` says where the target came from.** It already printed the target repo — the only tell — but a bare `5dive-ai/5dive` looks equally right whether it was resolved from the tree or merely defaulted to, which is why the dry run did not catch this. The prose and the JSON (`repoSource`) both carry the provenance now. An explicit `--repo` that disagrees with the tree's origin still wins and now **warns**; a tree with no github `origin` falls back and **says so** rather than defaulting in silence.
- **swept the other caller of the same constant rather than fixing one site** (the DIVE-1955 instruction). `_PUSH_DEFAULT_REPO` has exactly two readers: this one, and `_gate_repo_slugs`, where it is one entry in a *list* of known repos — a legitimate use fixed by DIVE-1955 already. `cmd_proof` reads its repo from the caller, never from the constant. No third instance of the shape.
## 0.15.20 — fix(heartbeat): the ship-flag fired on merges that PREDATED the open ask (DIVE-2001) (2026-07-25)

- **a merge older than the gate cannot be evidence the gate is satisfied.** `_hb_gate_shipped_sweep` matched any commit referencing the ident and flagged the owner *"likely shipped, verify and close"* regardless of when it landed. On DIVE-1968 it cited a commit merged ~2h **before** the gate was even filed. On a ticket that lands in pieces — 1968 has five criteria across three PRs — that nudge points the right way for the wrong reason, arrives with the authority of an automatic check, and agrees with what the assignee already wants to do. DIVE-1968 exists *because* DIVE-1927 was closed on a proof that did not cover the open failure, so a mechanism manufacturing exactly that pressure was aimed at our worst-performing habit. Found by dev.
- **it does NOT stamp `shipped_flag_at` when it skips.** The gate stays eligible, so a genuinely later merge still flags on a subsequent tick — suppressing the nudge must not also suppress the real one.
- **an unknown commit timestamp fails OPEN** (flags as before) rather than silently withholding. Withholding a legitimate flag is a silence, and silence is the failure mode this whole class is about.
- asserted in **both directions plus a negative control**: a commit predating the ask neither stamps nor pings, and the *same* fixture with a commit after the ask still flags and pings — without that control, both assertions pass just as happily on a sweep that has stopped flagging anything at all. Mutation-tested: disabling the guard turns exactly the two pre-ask assertions red.

## 0.15.19 — fix(task): a gate could be filed, report as pinged, and leave NO record that anyone was reached (DIVE-1968) (2026-07-25)

- **the gate rail now refuses to exit without a delivery verdict.** Every branch of `task_need_notify` was written to record one — an `ok` row, an `error` row, or a privileged re-send whose child records it. The defect was what happened when none of them ran: measured on the control plane, **5 of 9 real gates filed after the DIVE-1927 fix recorded NEITHER an `ok` nor an `error` row.** They returned success and left no trace in the only dataset anyone consults to judge whether the rail works. A logged failure is a bug report; silence is indistinguishable from success, which is how this class survived a live end-to-end verification.
- **the verdict follows the delivery state, and the two holes are deliberately not collapsed.** *Delivered but unrecorded* (the send was confirmed, only the bookkeeping is missing) **backfills an `ok` row** and keeps rc 0 — marked as backfilled, so it is never passed off as a first-hand receipt. *Neither delivered nor recorded* synthesises the `error` row, warns loudly at the filer, and downgrades a bare rc 0 to **rc 3 — FILED, NOT NOTIFIED**. rc 3 is an existing handled contract: the row stands, it is answerable on the dashboard, `gate_pinged_at` stays NULL, and the re-nag sweep escalates it. That last part matters more than the log line — an unrecorded delivery used to also claim the ping, which suppressed the one mechanism that would have rescued it.
- **collapsing them would have traded a missing row for a WRONG one.** The first cut asserted on the row alone and turned two **pre-existing** tests red (`gate_channelless_escalation`, `gate_filer_own_channel`). They were right: both drive a stubbed send that reports delivered, i.e. the delivered-but-unrecorded shape, and the first cut was manufacturing `error` rows for gates that had reached their human — re-contaminating the dataset with the opposite bias, on the very ticket about a mis-measured one. Both pass **unchanged** here; the code was fixed, not the tests.
- **it is a wrapper, not four patched exits.** The invariant is "no exit from this function without a verdict", and a wrapper holds it for the four exits that exist today *and* for whichever get added later — which is the actual failure mode, since none of today's exits was written intending to be silent. The counter counts delivery-log **calls**, not writes, so it reaches the same answer on a fenced fixture store as on production; it resets per gate, because a leaked counter would make the assertion quietly inert — the same fail-open shape as the unfenced log it sits next to.
- **corrected the numbers this ticket's own fence comment cited.** It said the true post-DIVE-1927 production population was "28 rows on 2 tasks", derived from an *ident-exists-in-the-prod-store* filter. That filter is insufficient, because **fixtures reuse real idents**. The sound discriminator is the **pending-gate window** — a row is a real delivery attempt only if `need_asked_at <= ts < need_answered_at`, since the notify path will not re-fire an answered gate and `gate-escalate` refuses anything not pending. Under it, the genuine post-fix production population is **zero**, and "the largest real shape is absent-from-org" was a test fixture talking. The fence is right; only those numbers were wrong.

## 0.15.18 — feat(doctor,task): a full disk now reports AS ITSELF, and a task close reclaims its worktree's `node_modules` (DIVE-1967) (2026-07-25)

- **`doctor` reports free space, because a full disk never announces itself.** The control plane hit 100% of 75G on 2026-07-25 (DIVE-1966) and nobody was paged. It surfaced as unrelated-looking mid-task failures: an agent's memory write dying with `ENOSPC` mid-edit, a shell losing stdout because the harness could not write its temp dir. Both read as "that tool is broken", so the wrong thing gets debugged. `doctor --category=host` now emits one check per distinct filesystem behind `/`, the workdir, the state dir and `/var`, warning under 10 GiB free and erroring under 3 GiB. The floors are **absolute, not percentages**: `ENOSPC` is caused by bytes, and 3% free is fine on a 2TB box and fatal on a 20G one. A `df` that cannot be read reports **warn/UNKNOWN**, never `ok`.
- **a `task done`/`task cancel` deletes that task's worktree `node_modules`, and nothing else.** The cause is structural: worktree-per-task with a full `npm install` per worktree and no teardown at close. 194 worktrees exist on this box; `app-wt-*/node_modules` alone was ~7.7GB at ~988MB each, most belonging to tasks already closed. Teardown belongs at the close, which is the moment the artifact provably stops being needed. `--keep-worktree` opts a single close out; `FIVEDIVE_NO_WT_RECLAIM=1` is the fleet-wide off ramp.
- **only the half that is data-loss-free BY CONSTRUCTION is automated.** `node_modules` inside a worktree is gitignored, `npm ci`-regenerable output, and **no commit or branch can live there** — removing it is structurally safe, not merely low-risk. The worktree **DIRECTORY** may hold unpushed commits, so nothing here ever deletes one: `task reclaim` reports a per-worktree prune verdict and pruning stays a human call, per the refusal discipline in DIVE-1869/1955.
- **the prune verdict fails CLOSED.** `wt_unpushed` returns a *reason* for every case it cannot read — not a git worktree, no upstream, unreadable HEAD, `git` absent — because "I could not look" must never render as "nothing there". That is the same defect the DIVE-1869 family is about; on the live box it correctly refuses 5 of 8 reclaimed worktrees, naming the unpushed branch in each.
- **the number in a worktree name is matched anchored, and a live task vetoes the sweep.** The number must be introduced by a `wt-`/`dive-` marker and terminated by a non-digit, so closing DIVE-196 cannot reach `app-wt-1960`. A candidate must also carry `.git` as a **FILE** — the marker git uses for a worktree, where a primary clone has a directory — which is what keeps the reclaim off the real repos sitting in the same parent. `task reclaim --all` skips any worktree whose task is `in_progress` or `blocked`, and since a worktree name carries a per-project counter and not an ident, **any** project's live task with that number vetoes it.
- **a cross-owner worktree is reported, not silently skipped.** Reclaim runs with the caller's own rights (no new privileged surface); a worktree owned by another agent fails the `rm` and is counted as `not_writable` with the `sudo` command to finish the job. A silent skip would read as "there was nothing to reclaim" — the same empty-output-is-not-an-empty-answer trap, in a disk sweep.
- **the escape hatches carry negative controls, and every skip is NAMED on the acting path** (Marcus, review). `--keep-worktree` and `FIVEDIVE_NO_WT_RECLAIM=1` are what an operator reaches for when this misbehaves at 3am, so each is asserted twice: once that the hatch suppresses the reclaim, and once that the *same* fixture and the *same* close **without** the hatch does reclaim — otherwise a hatch assertion passes just as happily when the reclaim is broken outright. And the sweep now prints one `skip <worktree> — task DIVE-N is <status> (live)` line on the acting path, not only inside `--dry-run` JSON: a reclaim that silently declines to act is indistinguishable from one that found nothing to do, and the difference only surfaces when the disk fills again.
- **the reclaim is DEFAULT-ON, deliberately.** An opt-in cleanup is a cleanup somebody has to remember, and the disk filled precisely because nobody remembered; an opt-in would reproduce the original failure with better ergonomics. What makes default-on defensible is the envelope above — `node_modules` only, the directory never deleted, the prune verdict failing closed — not the absence of risk.
- **`tests/worktree_reclaim_unit.sh`** asserts mostly what must SURVIVE a reclaim: the prefix-sharing sibling worktree, the primary clone in the same parent, the live task's worktree, and the closed task's own directory plus its tracked files. Verified end-to-end on the live host: `doctor` warns at 8.2G free, and `task reclaim --all --dry-run` sweeps 194 worktrees in 11s, skipping 7 as live.

## 0.15.17 — fix(task): three gate carve-outs silently overrode an explicit `--tier=2` hard-human pin, routing brand/money calls to an agent (DIVE-1957) (2026-07-25)

- **`cmd_task_need` resolved the tier correctly and then three later carve-outs threw it away.** `tier_arg` exists precisely so the code can tell "the caller pinned hard-human" from "this is only the type default", and eng-ship (DIVE-1359), content-curation (DIVE-1381) and internal-ops (DIVE-1480) all re-tiered to 1 and lead-routed without ever reading it. A brand call on a public page, filed `--type=decision --tier=2`, recorded as **tier 1** and routed to an agent who could clear it. All three now veto on `tier_arg == 2`; overriding the **type default** for a builder ship-gate is the point of the eng-ship class and is unchanged.
- **the pin also skipped the floor that would have caught it.** The T2 category floor only runs `if tier != 2`, so an explicitly pinned gate never sets `tier_floored` — which is why curation, whose own re-test is gated on that flag, downgraded an ask carrying `brand` even though `brand` is a floor term. The pin made the gate *less* protected than filing nothing, and the advice in circulation ("pin `--tier=2`") was therefore the exact wrong remedy.
- **the classifier reads the ask AND the task title, so the filer could not reword their way out.** A gate filed on a task titled `LAND the X branch: settle MERGE order` was downgraded by construction no matter how the ask was worded — and engineering tasks are titled with land / merge / ship / roll. The stated workaround (reword the ask) does nothing; the real one was to file the gate on a differently-named task.
- **`access` is the same shape and is closed by a backstop.** DIVE-1243 routes an `access` gate to the lead regardless of tier, so a pinned one still reached an agent. `_routable` is now cleared outright when `tier_arg == 2`, so the DIVE-1145 promise — *never route a tier-2 gate, floored OR explicitly pinned* — holds by construction rather than per-branch.
- **the escalation is audited, not just warned about.** `task.gate-tier2-pin-escalated` records filer/lead/type every time a `--tier=2` pin sends an eng-ship-shaped gate past the lead to the human. The warn corrects the next filer; the row is how we find out whether the habit is real — the standing remedy for this bug WAS "pin `--tier=2`", so every agent carrying that advice may now escalate routine ship gates. Audit the branch that declines to act, not only the one that acts (Marcus, DIVE-1957 review).
- **a builder who pinned by habit now gets told why.** An eng-ship-shaped gate with an explicit `--tier=2` warns that the pin kept it off the lead's desk and pings the human instead, so the DIVE-1359 anti-pattern (builders hard-human-gating routine ship calls) stays visible instead of merely re-opening.
- **`tests/gate_tier2_explicit_pin_unit.sh`** varies the **TITLE** as well as the ask — every veto case appears twice, once with the keyword in the ask and once with a neutral ask and the keyword only in the title. A suite that varied only the ask would have passed on the unfixed code, since the title axis was never exercised. Mutation-checked against `origin/main`'s `cmd_task.sh`: **8 of 15 red before the fix, 17/17 after** (15 at the time of the mutation check, plus the two audit-row cases), and the un-pinned counterpart of each class is asserted to still downgrade so the suite cannot be satisfied by disabling a carve-out.
- **two assertions in `gate_ship_routing_unit.sh` changed meaning and are called out rather than quietly edited.** DIVE-30 and DIVE-38 (the DIVE-1605 gerund regression) both filed `--type=approval --tier=2` and asserted the downgrade. `approval` already **defaults** to tier 2, so both now file with no `--tier` flag: same leak, same coverage, minus the pin the fix deliberately honours.

## 0.15.16 — fix(models): the OpenRouter opus slug was a tier behind its sonnet sibling (DIVE-1897) (2026-07-25)

- **the opus tier had not been bumped when sonnet was.** `CLAUDE_PROVIDER_OPUS_MODEL[openrouter]` was `anthropic/claude-opus-4.8` while `CLAUDE_PROVIDER_SONNET_MODEL[openrouter]` was already `anthropic/claude-sonnet-5`. Both slugs **resolve**, so this was never a 404 — one tier had simply been left behind. Now `anthropic/claude-opus-5`, verified present in the live `openrouter.ai/api/v1/models` list.
- **the most useful result was a NON-change.** `anthropic/claude-haiku-4.5` is current: there is **no** `claude-haiku-5` on OpenRouter, so pattern-bumping haiku to match the opus and sonnet moves would have produced a 404. That is exactly the inference DIVE-1897 was split out of DIVE-1883 to prevent — these are vendor-registry slugs on someone else's namespace and must be checked against the provider, never derived from the first-party ids (OpenRouter uses dots, `anthropic/claude-opus-4.8`; the Claude Code ids use dashes, `claude-opus-4-8`).
- **`openrouter/auto` does resolve.** The header comment says it does not; that is true only for the anthropic-skin path. It is a real listed model, and hermes/openclaw consume it through OpenAI-format clients, so both entries are correct as-is.
- **provenance is now dated.** The header said *verified against openrouter.ai 2026-07-10* — 15 days stale — and now carries the verification date plus what was actually checked, so the next reader reads freshness instead of inferring it.
- **not verified, deliberately untouched:** the hermes and openclaw in-tree catalogs are not installed on the control-plane host, and the z.ai / deepseek / moonshot model lists 401 without keys. One suspicion is filed as DIVE-1987 rather than acted on: openclaw's `anthropic/claude-sonnet-4-5` uses **dashes** and that exact string is absent from OpenRouter's namespace while the dotted form exists — changing it on an OpenRouter lookup would repeat the very inference error above, one layer over.

*(0.15.15 was never released — the number was claimed by an in-flight PR that rebased to 0.15.17, so there is no 0.15.15 section by design.)*

## 0.15.14 — fix(test): the telemetry fence's OWN test wrote into production telemetry (DIVE-1968, partial) (2026-07-25)

- **the fence's positive case reached the hardcoded production log.** `tests/gate_telemetry_fence_unit.sh` case 3 asserts that a row on the *production* store is still written — and to get there it declared its throwaway store to be prod (`FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"`) **and unset `FIVEDIVE_GATE_NOTIFY_LOG`**. With the store counted as prod and no override, `logf` falls back to `/var/log/5dive/notify/gate-notify.log`, so the test that proves the fence works wrote into the exact dataset the fence exists to protect — under the real ident `DIVE-1956`, with detail `real production failure`, a string built to be indistinguishable from a genuine failure. Two such rows landed from a routine suite run on 2026-07-25 (16:09:58, 16:12:10), and the same string accounts for DIVE-1956's earlier rows that day. The override IS honoured on the prod store — store identity decides whether a row is telemetry at all, the path only decides where it goes — so keeping it pointed at the harness's own file preserves every assertion the case actually makes (the audit call fired; no "telemetry withheld") while writing nothing to the fleet log. Ident and detail are now unmistakably fixture-shaped: a row that reads like a real failure is a trap for whoever greps that log next, wherever it lands.
- **a suite-level guard, because "we read the cases carefully" is not a mechanism.** The suite now records the production log's length before any case runs and, at the end, scans ONLY the bytes this run appended. Scanning the whole file would fail forever on a historical leak — including the ones this fix exists to stop — leaving the suite permanently red for everyone and teaching people to ignore it; a guard that cannot go green is not a guard. It keys on detail strings unique to this suite rather than on a byte count, because the fleet writes to that file concurrently and a size comparison would flake on other agents' real rows.
- **the guard nearly shipped vacuous, which is the finding underneath the finding.** Rows are written through `printf %q`, so every space in a detail comes back backslash-escaped (`fixture:\ on-store\ row`) and a plain `grep` for the prose never matches — the guard would have passed on every run while catching nothing. Both the positive assertion and the guard now go through ONE matcher that normalises the escaping, and case 3 is what proves that matcher fires on a real row. Verified by forcing the scan window to the whole file, where a row leaked during this fix's own mutation testing sits: the guard fails and names it.

## 0.15.13 — fix(task): the gate rail never tried the FILER'S OWN channel, so a top-of-org filer with a working channel reported "no paired channel for filer X or anyone above it" (DIVE-1968, partial) (2026-07-25)

- **`task_need_notify` now resolves the filer's own channel BY NAME before anything else.** `_task_owner_channel` resolves the **caller** — `auto_sender_from_sudo` reads `$SUDO_USER` and only when it is `agent-*`, else `$USER` on the same condition — and never the gate row's filer. So it is a structural no-op in exactly the two contexts that matter: the root re-nag sweep and the privileged re-send both run with no `agent-*` identity, the name resolves EMPTY, and `_task_agent_channel ""` returns 1 immediately. The chain then walks strictly UP from the filer, so a **top-of-org filer** (`reports_to=''`) comes back empty and the gate reports unreachable while its channel sits right there, readable by the very root context that gave up on it.
- **a peer-driven send resolved the CALLING agent's channel and alerted the WRONG HUMAN while reporting success.** This is the worst of the three shapes and strictly worse than reaching nobody: a miss is eventually noticed, a misdelivery looks like a delivery. On a box where every agent shares one chat the blast radius is small; on a customer box with more than one paired human it is a gate landing on the wrong person's phone, recorded as delivered.
- **this answers the review caveat rather than papering over it.** The instruction on the rail fix was to find out why `_task_owner_channel` did not fire for the measured top-of-org filer *before* prepending the filer to the chain, on the reasoning that prepending blind would hide a second bug. It could never have fired: the own-channel probe is caller-scoped, and that IS the second bug.
- **the escalation chain is deliberately unchanged.** `_task_chain_paired` still cannot see a filer whose channel exists but is unreadable from here, so the "nobody up the chain is paired" branch can still be reached by a top-of-org filer under a non-root caller. Emitting the filer from `_task_escalation_chain` fixes that too but changes what every caller of `_task_chain_channel` gets back, so it lands as its own change rather than riding this one.
- **`tests/gate_filer_own_channel_unit.sh`** drives the REAL `_task_owner_channel` under a root environment. The existing `gate_channelless_escalation_unit.sh` stubs it as `_task_owner_channel() { _task_agent_channel "${FILER_SELF:-}"; }` — i.e. it models the probe as **filer-scoped**, the exact property production violates — so 25 assertions passed on top of the bug. The new cases assert the precondition first (the caller-scoped probe really does resolve nobody here), so they cannot quietly stop exercising the gap. Mutation-checked: disabling the by-name probe turns 5 of 9 red, including the spurious `no paired channel` row that is the production symptom.
- **correction to the 0.15.12 notes above.** They state the post-DIVE-1927 production population is "28 rows on 2 tasks" and that `absent-from-org` is "the largest real shape". Both rest on an ident-existence filter, and fixtures reuse idents that exist in the production store. The filter that holds is the **pending-gate window** — a row is a real delivery attempt only if `need_asked_at <= ts < need_answered_at`, because the notify path will not re-fire an answered gate. Under it, that post-fix set is `DIVE-1` (19 rows, the task never held a gate at all), `STEER-1` (26 rows, all six days after its answer, and it is named in two fixtures) and `DIVE-1956` (6 rows, never held a gate). **Genuine post-fix production error rows: zero** — DIVE-1927 did hold. Non-vacuously: 9 real gates were filed after it shipped, 7 answered, 0 error rows. Across the whole log the real residual is 11 rows on 11 tasks, one per task at filing time, and **9 of the 11 recorded an `ok` minutes to an hour later at re-nag timestamps** — so the defect is delivery LATENCY, not loss, and the "largest real shape" was the `alice` fixture population (`alice` is not a fleet agent; it appears in six test files).

## 0.15.12 — fix(task): gate telemetry was written from a hardcoded prod path by every task store, so the only dataset anyone reads was a mixture (DIVE-1968, partial) (2026-07-25)

DIVE-1968 was filed on "194 undelivered gate rows across 13 tasks since DIVE-1927 shipped". Decontaminated, the real post-1927 production population is **28 rows on 2 tasks**. This change does not fix the gate rail — it makes the rail's own record trustworthy enough to fix from. The rail fix follows separately, and the ticket stays open until the remaining rows are explained.

- **the telemetry is fenced on STORE IDENTITY.** `_task_gate_delivery_log` wrote to a hardcoded `/var/log/5dive/notify/gate-notify.log` and called `audit_log` regardless of which task store the process was driving. A unit harness points `TASKS_DB` at a throwaway store whose `agents_org` is **empty**; an empty org table yields an empty escalation chain for **every** filer; so each fixture gate emitted a real-looking `no paired channel for filer X or anyone above it` row into production telemetry. Of 36 distinct idents in the error rows, **17 existed only in fixture stores**. The fence is the DIVE-1506 positive allowlist (`_task_human_send_allowed`), with DIVE-1500's `FIVEDIVE_NOTIFY_DRYRUN` honoured as a secondary quarantine signal. **Store identity is primary precisely because it needs no environment variable** — a harness that sets nothing is fenced by construction, including harnesses nobody has written yet. An opt-in fence is a fence you have to remember, and "four harnesses set it, the rest do not" is the defect being removed; you do not fix an opt-out failure with a different opt-in. An explicit `FIVEDIVE_GATE_NOTIFY_LOG` still captures locally — the safe case — but can never confer production status on an off-store run, and the withholding is announced once per process rather than silently dropping rows.
- **the contamination cut both ways, which is the part worth remembering.** It inflated the apparent blast radius *and* hid the real residual inside it. It also manufactured the control that made the wrong diagnosis look decisive: *"13 tasks hold 194 error rows and not one ever recorded an ok, while the ok rows belong to 6 disjoint tasks"* reads as proof of a broken rail, but **a fixture ident can never record an `ok`, because it was never a real gate**. Zero overlap was evidence of two populations in one file. A control is only as good as the population it is drawn from.
- **`task gate-escalate` records the real rc.** The audit row hardcoded `1`, so `rc=2` — a channel *was* resolved and the Bot API send merely went unconfirmed — was indistinguishable from a genuine no-recipient failure, while the message asserted the second reading either way. The rc is now recorded and the two cases say different things (`UNVERIFIED, not refused`).
- **the privileged re-send keeps the child's reason.** It ran under `>/dev/null 2>&1`, so the parent could only ever report `privileged re-send FAILED`; an entire diagnosis round went into deciding whether `sudo` had refused the invocation or `gate-escalate` had returned non-zero for its own reason — a distinction the child prints and we discarded. stdout stays discarded (it is the ok/JSON envelope); stderr rides the warn and the delivery row.
- **the three empty-chain causes are now distinguished in the detail** (`shape=absent-from-org|top-of-org|no-chain|org-unreadable`). One message covered a filer with no `agents_org` row at all (the largest real shape), a genuine top-of-org filer (1 row of 28), and a filer with a valid manager whose chain still came back empty. A failed read reports `org-unreadable` rather than being silently rendered as an empty org.
- **`cmd_task_gate_escalate` now roots-checks through the `_gate_is_root` seam** instead of reading `$EUID` inline. `$EUID` is readonly in bash, so the inline test made the verb unreachable from a unit harness — which is how the hardcoded audit code survived from DIVE-1927 to now. A check nobody can exercise is a check nobody can trust.

## 0.15.11 — fix(task): the merge-gate could not tell a PR the task DELIVERED from a PR it REPORTS ON (DIVE-1965) (2026-07-25)

The gate's subject was "a PR mentioned in the result/body", and that predicate cannot distinguish *"I shipped this"* from *"I am writing about this"*. Review, triage, audit, hygiene and coordination closes cite other tasks' pull requests as a matter of course.

- **why this is urgent now rather than whenever.** Today the confusion is cosmetic: an off-repo bare `#N` silently fails to resolve, so a cited PR produces a wrong `UNVERIFIED` sentence (DIVE-1962) and nothing worse. The moment a bare `#N` is searched in the repo it actually lives in (DIVE-1963), a cited **OPEN** PR resolves and lands on the REFUSAL path (`done-with-open-pr-in-result`), not the marker path. `lodar/5dive-api#10`, `#17` and `lodar/5dive-frontend#16` are all open right now — so DIVE-1955's own close would not have been mis-stamped, it would have been **refused**. Every close that merely mentions another task's open PR becomes unclosable without `--force-merge-gate`, on exactly the task class that cross-references the most. DIVE-1963 is structurally blocked on this.
- **delivery now comes from a structured, intentional signal — never from "a number appeared in the text".** The two strongest bindings already win and never reach the prose scan: a `delivery_ref` and a `Branch:` line both route to the declared gate. What is left for prose has to be a deliberate claim, so the **default is CITED**: a `Delivered:` / `Delivery:` line (the structured escape, sibling of the DIVE-1462 `Branch:` and DIVE-1955 `Repo:` lines) binds everything it names, and otherwise a shipping verb must sit **adjacent** to the reference — "merged as PR #6", "landed in #13", "PR #6 was merged". Anchored adjacency, not "the word merged occurs somewhere in the close"; negations (`not merged yet`, `unmerged`) are rejected explicitly.
- **a cited PR is not judged at all** — not resolved, not refused, and not stamped. It is another task's delivery, so there is no question here for the gate to answer *or decline*: an `UNVERIFIED` marker on a citation would put the scare-mark back on every audit and triage close, which is the wallpaper failure DIVE-1955 spent a review pass deleting. This is the **third state**, after *"I looked and could not tell"* and *"there was nothing to look at"*: **"I am talking about something I did not ship."**
- **the failure modes are deliberately asymmetric, and the cheap one is announced.** Reading a citation as a delivery re-creates the fleet-wide close blocker; reading a delivery as a citation costs coverage on one narrow shape — no `delivery_ref`, no `Branch:`, no open PR naming the ident (the mandatory auto-detect scan is untouched and still fires), and prose that names its own merged PR with no shipping verb near it. That slip is never silent: the close warns which references were set aside, names both escapes (`task deliver --pr=`, or say "merged as PR #N"), and writes a `task.merge-gate-reported-on` audit row. Citations are also skipped **before** the 5-reference cap, so five cited PRs cannot crowd the real delivery out of the budget.
- **the invariant Marcus asked for before the code existed, now a pinned test:** a close whose result names its own merged+green delivery *and* cites two unrelated OPEN PRs closes cleanly — unrefused **and** unstamped. `tests/task_merge_gate_delivered_vs_cited_unit.sh` (28 assertions) pins it alongside the symmetric pairs that keep DIVE-1922's coverage: the same OPEN, merged-RED, unresolvable and ambiguous references still refuse or still stamp when they are *claimed as the delivery*. Three DIVE-1935 prose-safety fixtures were re-phrased to assert a delivery, because as written they would have started passing for the wrong reason and stopped covering the branches they exist for.

## 0.15.10 — fix(task): the merge-gate was structurally SINGLE-REPO, and off-repo it was WRONG rather than blind (DIVE-1955) (2026-07-25)

DIVE-1935 made the merge-gate live for the whole fleet — for one repo. `_PUSH_DEFAULT_REPO` is a readonly constant pinned to `5dive-ai/5dive` and every binding resolved against it, so `lodar/5dive-api` (== prod) and `lodar/5dive-frontend` had **zero** coverage. Marcus's DIVE-1911 hygiene sweep found five tasks at `status=done` with genuinely unmerged work in those two repos, hours after DIVE-1935 closed.

- **the repo now travels with the binding instead of being supplied later by a constant.** A `delivery_ref` URL and a full pull URL in prose already carry their own owner/repo and are resolved there. A `Branch:` line or a bare `PR #N` can declare one with a `Repo: <owner>/<repo>` body line, the sibling of the DIVE-1462 `Branch:` line. The reference extractor emits `<slug>|<number>` rather than a naked number, and a URL beats the same number appearing bare in the same text.
- **a bare `#N` is never resolved against a default slug again.** This was the sharper half of the defect: off-repo the gate was not blind, it was **wrong**. An api task whose result said `PR #6` was judged against the CLI repo's unrelated #6 — a confident verdict about the wrong pull request, which can refuse a legitimate close or bless a bad one. Resolution is now: the number exists in exactly one known repo → that repo (the common case, so DIVE-1935 coverage does not regress); in two or more → break the tie only on **evidence** (exactly one of them names the ident in its title or head branch); otherwise **`ambiguous`** — a loud warn plus a `task.merge-gate-ambiguous` audit row that blocks nothing and blesses nothing. Admitting we cannot tell which PR the maker meant beats inventing one.
- **the mandatory auto-detect scan and the `Branch:` search sweep every repo.** The `Branch:` path was fail-CLOSED against the CLI repo only, so a legitimately landed api task was permanently unclosable; it now searches the declared repo, or all of them, and passes if the branch merged in any. A repo whose listing fails no longer counts as scanned — the close reports `partial-repo-scan-N-of-M` and is audited UNVERIFIED, because partial coverage announced as a clean sweep is this ticket's own defect one level up.
- **a bare `delivery_ref` is refused outright** (`done-with-ambiguous-delivery-ref`). The declared path is fail-closed and must not invent a repo either. No live task carries one — all seven `delivery_ref`s are URLs, checked 2026-07-25 — so this keeps the shape from being introduced silently rather than fixing an outage.
- **an unverified close is stamped on the DURABLE RECORD, not just stderr** (review, Marcus). `ambiguous`, `partial-repo-scan-N-of-M`, a dead ref parser, an unresolvable reference and unreadable checks on a confirmed merge are all non-verdicts, and until now each existed only as a warn that scrolls away and an audit row in a different artifact than the one anyone reads. The task row said `done` with no finding — precisely the clean verdict the gate declined to make. A `[merge-gate: UNVERIFIED — <reason>]` marker is now appended to the result (appended, never substituting the maker's text). Same rule as DIVE-1869: a check that could not reach its answer must not render as one. Blocking nothing is fine; blessing by silence is not.
- **...but only when there WAS something to verify** (second review pass, Marcus; CI caught the first cut). The marker fires when the gate looked and could not tell — an ambiguous or unresolvable reference, a partial scan, unreadable checks, no token *while a PR was named*. It does **not** fire when the close named no PR, no branch and no delivery: `unverified` is the wrong word for a research, comms or decision task, because nothing was pending verification. The first cut stamped those too, which would have put a merge-gate warning on the majority of fleet closes within a day — wallpaper, and wallpaper destroys the exact property the marker was added to buy. It is the same cries-wolf failure as the merged-red one, and it surfaced as a real red test (`task_core_unit` closes a task with result `all good` and no PR anywhere) rather than as an argument. The two states are kept as an explicit named branch (`_gate_text_names_a_ref`) rather than implied by a missing condition, because *"I looked and could not tell" is not "there was nothing to look at"* and the next reader will otherwise collapse them. That predicate is deliberately grep-free — bash `[[ =~ ]]` only — since one of its callers is the case where the real extractor cannot run. The no-PR-at-all escape (the DIVE-1690 shape) stays the `merge-audit` sweep's job, where someone is deliberately looking.
- **the check verdict is the LATEST RUN PER CHECK NAME, not any failure in the rollup** (review, Marcus). `statusCheckRollup` carries every run on the head commit, so a check that failed and was then re-run green still contributed its stale FAILURE and the gate called the PR red. Verified against real timestamps on `lodar/5dive-api#13`: smoke-gate FAILED 11:49:41, SUCCEEDED 12:41:15, merged 12:42:06 — it went green and then merged, so its merged-red finding was a **false positive** and is withdrawn. Runs are grouped by name (or status context), sorted by their own timestamp, and only the last of each is judged; a green check still cannot launder a different red one. A merged-red table that cries wolf gets ignored, at which point it is worth less than no table.
- **`task merge-audit` sweeps all three repos** (`FIVE_GATE_REPOS`, so a fourth repo is config and not a patch), reports the repo per row and counts `ambiguous` separately. Its previous answer — "0 OPEN, 0 merged-red across the newest 250 closes" — was true for the CLI repo and was not licensed across the product. Re-run: **5 real findings** the single-repo sweep could not see — api #17 and frontend #16 OPEN, api #12 merged RED (cited by two tasks), CLI #25 closed-unmerged (ignored by the gate by design). It also stops reporting DIVE-1874/1875 as `CLOSED` on a `#25` that is a 5dive-api number colliding with an old CLI one — the benign half of the same bug, previously excused by a footnote that only covered `unverified` and not a state that happened to resolve.
- **the sweep still cannot see a task that names no PR at all.** DIVE-1690 closed with unmerged frontend work and no PR anywhere; nothing in its record to resolve, so the audit finds nothing. That is a bound of this tool, stated rather than left to be discovered — the weekly branch-hygiene digest is what covers it.
- `tests/task_merge_gate_multirepo_unit.sh` (18 assertions) pins all of the above; the DIVE-1935 harness's gh stub is now repo-aware, because a stub that answers every `--repo` identically makes every bare number look like a three-way collision.

## 0.15.9 — fix(council): a convene that could not REACH its seats recorded a unanimous abstention (DIVE-1869) (2026-07-25)

Found on the 2026-07-24 flagship demo. `5dive council convene` run without the privileged delivery grant failed on EVERY seat instantly (`sudo: a password is required`), recorded each failure as a plain ABSTAIN, and produced a normal-looking `Inquorate: 0 of 6 seats voted` verdict plus a receipt. A permissions outage and a legitimate unanimous abstention rendered identically — the governance engine's worst possible failure mode, because the output of a broken rail is indistinguishable from a decision the council actually made.

- **a seat we never reached is no longer a seat that abstained.** `dispatchSeatVote` already tagged its capture failures (DIVE-1901), but `normalizeSeatVote` DROPPED the tag on the way into the tally — so the distinction existed for one function call and then died, surviving only as prose inside a rationale string nothing reads. `abstainKind` + `capture` now ride the vote row through normalization, the tally, the verdict and the emitted JSON.
- **the same hole existed on the DEFAULT rail, untagged.** The demo hit the `--ask-rail` escape hatch, but the CNCL-18 ballot rail folded its own delivery failures (`task add` refused, a human seat with no bound chat) into identical plain abstains. Fixing only the reported path would have left the default one broken. Both are tagged now, as is a dispatch adapter that throws.
- **a convene with NOTHING but delivery failures refuses instead of sealing.** When the run is inquorate AND every single non-vote is a capture failure, `deliveryFailure` is set and the CLI exits non-zero naming each unreached seat and the first underlying error — no verdict, no receipt, nothing sealed. Deliberately narrow: one genuine abstention or one real vote means we DID hear the council, and that run still seals. A real unanimous abstention is a decision and is unaffected.
- **the ask rail refuses BEFORE dispatching.** It delivers through the root-scoped `5dive agent _deliver` grant, so a caller without it cannot reach any seat and the whole convene is doomed at the first ballot. Pre-flight probes the actual capability (`sudo -n -l`, never prompts, fail-closed) rather than pattern-matching an agent tier, so a full-trust caller, a scoped OSS agent and root each resolve correctly with no tier list to maintain.
- **the capture tag is on the DURABLE record, and it is SEALED.** Review catch (Marcus): a distinction that exists only during the run leaves a later reader of a receipt back to guessing, and the fix decays to a runtime-only guard. `canonicalTranscript` now emits a **conditional** `unreached: <seat>:<kind>,…` line — present only when a seat was actually unreached, so a healthy convene (and every pre-DIVE-1869 receipt) seals byte-identically, and stripping the tags CHANGES the bytes. The verdict's `captureFailed`/`captureFailedSeats` also ride the persisted receipt JSON. Order-stable, so dispatch completion order cannot perturb the seal.
- **the refusal leaves an audit row, not just loud stderr.** Same review catch, same reasoning as the DIVE-1935 merge-gate fail-open: the branch that declines to act is precisely the one that must be auditable — and a refused convene seals NOTHING by design, so without a row the attempt leaves no trace at all. `cli.mjs` drops the refusal detail in a sink the bash layer turns into one `council convene / error / refused=delivery-failure` row naming the unreached seats, the kinds and the ratio. Split into a named function so the row's shape is tested against an isolated `AUDIT_LOG`, plus a structural assertion that the failure path calls it. **Writing it surfaced a live instance of this ticket's own bug:** the first cut passed `--refused=…` style args, and `audit_log` builds its row with `jq -cn … --args`, which REJECTS a positional starting with `--` — the jq call fails, `|| return 0` swallows it, and NO ROW is emitted. A silent-empty audit path, caught only because the test asserted the row's content rather than that the code ran.
- **a healthy convene seals byte-identically.** `canonicalTranscript` seals seat/vote/rationale plus the new CONDITIONAL `unreached:` line, so a receipt with no capture failure — and every pre-DIVE-1869 receipt — verifies exactly as before. Pinned by an assertion rather than asserted in a comment, in both directions: identical when clean, DIFFERENT when a seat was unreached.
- **`sudo 5dive council ...` no longer dies on "needs node on PATH".** Root's non-login PATH has no nvm, and council is sudo-gated by design (it seals root-owned records), so this bit every sudo-gated council op — with an error naming neither where node is nor how to fix it. `ensure_node_on_path` locates it; `require_node` fails with two copy-pasteable remediations. The nvm pick is version-ordered (`sort -V`), because a plain glob is lexicographic and would take v9.9.9 over v10.0.0 — the trap DIVE-1882 hit on the codex v24 alias.
- **the same bare check was in four other places** (`cmd_constitution.sh` x3, `cmd_memory.sh`, two best-effort `cmd_heartbeat.sh` sites) and all now route through the shared locator. Fixing only council would have left the identical dead end one command over.
- **48 new assertions across a unit harness and an e2e**, both wired into `tests/council_unit.sh` so they GATE in CI. The e2e drives the BUILT binary (the CNCL-26 blind spot) with a stub fleet and a stub `sudo`, so the refusal, the non-refusal of a healthy convene, and the pre-flight's both-directions behaviour are deterministic on any runner. Two assertions in the first draft were vacuous — a both-branches-pass on node discovery and a `$`-anchored `case` glob that can never match — and were replaced with outcome assertions; the node leg had silently never run the binary at all (`env -i` left no `bash` on PATH). Full council suite green: **648 assertions, 0 failures**, and the full `tests/*.sh` directory passes. Two tests (`init_ux_unit.sh`, `loop_grade_unit.sh`) each failed once across four full-directory runs and pass 5/5 in isolation on this branch AND on clean `origin/main` — a different test each time, including a run that excluded this ticket's own e2e, so the flake is ambient to the suite and not introduced here. CI is green end to end (7/7).

## 0.15.8 — fix(task): the mandatory merge-gate was inert for the whole agent fleet, and a PR named in prose bound nothing (DIVE-1935) (2026-07-25)

DIVE-1922 reached `status=done` while its delivery PR was OPEN, unmerged and RED on its own new unit test. Both declared bindings were empty, so DIVE-1830 had nothing to bind to — and DIVE-1835's MANDATORY auto-detect, written for exactly that hole, did not fire either.

- **the gate was inert for every agent on the box, and had been since it shipped.** `_gate_gh_token` only tried the host's gh-authed `claude` account when `id -un == root`. Agents close tasks as THEMSELVES (plain `5dive task done`, no sudo) and no `agent-*` account is gh-authed, so resolution returned empty, `gh pr list` errored, `|| echo ""` swallowed it, and the fail-OPEN gate read "no token" as "no open PR". Reproduced as `agent-dev` before touching anything: the query the gate runs prints `gh auth login` to stderr and nothing to stdout. The fallback now runs for non-root callers too, AFTER the caller's own login (a caller's own credential must win over borrowing another account's).
- **an empty token was being counted as a scan that ran.** Separate from the resolution bug: even with the token fixed, the code ran the query and read an empty result as clean. No token now short-circuits to the unverified branch — the inference "gh said nothing, so the repo is clean" is the entire defect and it is gone, not narrowed.
- **fail-open stays, but is no longer SILENT.** A gh outage must never stall the fleet, so the repo-wide scan still lets the close through — and now says `merge-gate could not query GitHub (no-gh-token|gh-absent|query-failed)`, names the reason, and writes a `task.merge-gate-unverified` audit row. This is the ticket's own theme: DIVE-1922's deliverable was instrumentation whose absence rendered identically to its healthy state, and a gate that reports "no hit" for an outage and for a clean repo is the same shape.
- **the PR the maker TYPES is a binding.** DIVE-1922's own done result said "Merged as PR #156" in prose. `--result` and the body are now parsed for PR references and an OPEN one refuses the close. Narrow on purpose: OPEN only (a "superseded by PR #150" mention of an abandoned PR must never make a task unclosable, per DIVE-1835), and an unresolvable ref is a loud note rather than a block, so an offline box stays closable.
- **a bare `#N` is deliberately NOT a PR reference — the retrospective sweep proved it.** The first cut matched any `#N`; run against the real board it read "arms-length payer #4" and a column number "#25" as PRs. Requiring the word PR (or a full pull url) keeps the DIVE-1922 shape and drops the prose collisions. Bare numbers are resolved against the CLI repo only, and both the refusal and the unverified note now NAME that repo, so a cross-repo `PR #N` (api/app numbers collide with old CLI ones) is diagnosable instead of mysterious.
- **MERGED is not GREEN.** #156 was red, not merely unmerged, and a red PR can still be merged by bypass — landing work whose own test says it does not do what the result claims. A positive check failure now refuses; pending/absent checks are a note, not a block, so a check-less or slow repo never stalls. `--force-merge-gate` escapes it (a flaky post-merge run must not make a landed task permanently unclosable) and is audited.
- **new `5dive task merge-audit`** answers the question the ticket asked rather than assuming: read-only sweep of DONE tasks whose own record names a PR that never merged. Across the newest 250 closes: **0 OPEN and 0 merged-red** — 2 CLOSED and 16 unverified, all cross-repo api/app references. DIVE-1922 was the only genuine instance. It refuses to run without a resolvable token, because a sweep that reports every PR as `unverified` is not an audit.
- **a sibling suite was borrowing a REAL credential.** With the resolver fixed, `task_merge_gate_gh_resolve_unit.sh` reached the host's actual gh login (real `sudo` resets PATH past the stub) and printed a live oauth token into its own argv log — while its empty-token fail-safe assertions passed on a token the fleet does not have. Both harnesses now stub `sudo` fail-closed for the whole run.
- **the parser itself was the one unguarded silent-empty path** (caught in review by Marcus). The first cut built both patterns on `grep -oP`, so the whole text-binding gate depended on a PCRE-enabled grep: with `-P` unavailable both greps fail, `|| true` swallows it, refs come back empty and the gate silently does nothing — the exact shape fixed in the token resolver and in `_gate_pr_state`, left sitting one layer down. The PCRE dependency is now **deleted** rather than probed for (POSIX ERE only), plus a canary self-test so "no refs found" is provably not "parser cannot run".
- **the ERE rewrite is pinned by named fixtures, not by reasoning.** Dropping PCRE gave up `\K`, the lookbehind and the lookahead in one move — the machinery keeping "payer #4" out. Positives (`Merged as PR #156`, a full pull url, `PRs 156`, `pull request #156`) and negatives (`payer #4`, column `#25`, a digitless heading, a 7+ digit id, a number glued to alnum) are each their own assertion, so a future edit names which case died. The glued-to-alnum negative earned its keep immediately: it caught `PR 12ab` resolving as PR 12 — a false positive present in the **original PCRE version too**, since `(?![0-9])` excluded only a following digit. The ERE version is strictly tighter than what it replaced.
- **the two red-merge causes needed two slugs, and CI caught that they had one** (`tests/policy_refusals_unit.sh`, red on the first push). One site fires on the PR bound as `delivery_ref`, the other on a PR merely NAMED in the result/body; sharing `done-after-red-merge` made them indistinguishable in `policy_refusals` — the very series DIVE-1922 was about. A record that preserves *that* something happened but not *what* is a smaller instance of the defect this ticket is against. Split to `done-after-red-merge` / `done-after-named-red-merge`, mirroring the existing `done-before-pr-merged` / `done-before-named-pr-merged` pair, with the rationale recorded at the site so it does not get tidied back. **What caught it is worth noting: a STRUCTURAL assertion about the shape of the instrumentation, written about no particular refusal.** Next time such a test looks like ceremony, this is the counterexample. A companion semantic assertion now pins that the RIGHT site differs, so uniqueness cannot be satisfied by renaming the wrong one.
- **29 new assertions**, and the FULL suite directory is green: **143/143**. Rebased onto `f5d54b6` (DIVE-1919), which fixes `tests/task_park_gate_guard_unit.sh` — the earlier note that it failed on clean `origin/main` was true against `18ad69c` and is now stale, so this branch carries no known-failing suite. Also a process correction: the first pass was verified with a `tests/task_*.sh tests/gate_*.sh` glob, which `policy_refusals_unit.sh` matches neither — **a narrowed test selection is a narrowed claim**, and the full directory is now what gets run. Rebased onto `f5d54b6` (DIVE-1919), where `tests/task_park_gate_guard_unit.sh` is fixed — the earlier note that it failed on clean `origin/main` was true against `18ad69c` and is now stale. **28 of 28 task+gate suites green, zero failures.** `tests/task_park_gate_guard_unit.sh` fails identically on clean `origin/main` (rc=6) and is untouched by this change.

## 0.15.7 — fix(task): `task need --json` emitted ZERO BYTES for the common case (DIVE-1930) (2026-07-25)

`5dive task need --json` returned nothing at all — not a smaller object, not an error, zero bytes — for any gate filed without a matching precedent, which is the overwhelming majority of them. Measured on the rolled 0.15.6 binary.

- **one field killed the whole envelope.** `precedent_ref:(($pr|select(length>0))|tonumber? // null)`: with no precedent `$pr` is empty, `select` yields **empty**, and because the `// null` bound to `tonumber?` instead of to the whole expression, `empty | (tonumber? // null)` stayed empty and propagated OUT of the object constructor. jq does not build a smaller object in that situation; it builds nothing.
- **the discriminator is where `// null` BINDS, not whether a pipe follows `select`.** `(($x|select(length>0)) // null)` is safe and `(($x|select(length>0)|tonumber?) // null)` is safe — both enclose the empty. Only `(($x|select(length>0))|tonumber? // null)` leaves it uncaught. `map(select(...))` and `[ ... | select(...) ]` are comprehensions and never at risk. The fix is one closing paren.
- **it was a ONE-line point fix, not a 19-site sweep.** The ticket was scoped from grep hits on `select(length>0)`; enumerating the 23 sites in `src/` by GUARD SHAPE instead found six safe `// null` forms, comprehensions, two streaming into `jq -cs` where empty correctly yields `[]`, one `map(select(...))|length` false positive, and exactly one defect. Editing the other eighteen would have been eighteen chances to introduce the bug being removed.
- **the only case that worked was the rare one, which is why it survived.** A gate WITH a precedent rendered fine. Its regression test asserts both directions, so "fix" by deleting the field fails too — and against the pre-fix line 5 of 6 assertions fail, the sole pass being that rare path.
- **a shape guard grep** rejects the dangerous binding coming back.
- **the goal path could never have caught it**: it captured the envelope into a `gate_json` it never read. A capture that is never inspected reads at review time like a checked result and is not one. Now discarded explicitly, matching the objective path, so the exit status is visibly the only thing that call is trusted for.

## 0.15.6 — fix(gate): a gate filed by a channel-less agent reached NOBODY, and `task need` said OK (DIVE-1927) (2026-07-25)

`dev3` (CHANNELS=none) filed a manual gate correctly. It pinged no one. The board showed `blocked`, the filer was told the gate was filed, and the only reason anyone found out is that dev3 messaged its lead out of band. Measured, not inferred: every gate from an agent WITH a channel had `gate_pinged_at` stamped within a second; the one from the agent WITHOUT a channel had it NULL.

- **the escalation code already existed and had never once fired.** DIVE-1243 added an org-lead fallback for exactly this, and it probed the lead's channel by READABILITY (`-r access.json`). Every agent's channel dir is `0700` and its `access.json` `0600`, so a sibling agent can NEVER read a peer's pairing state. Permission-denied was indistinguishable from unpaired, so the fallback read the whole fleet as unpaired, logged "no lead channel either", and returned **0**. A feature that cannot succeed on any real box, sitting green for months.
- **paired-ness is now probed separately from readability.** `_task_agent_paired` answers "does this agent have a channel at all" from the group-readable connector token plus a bare `-d` on the channel dir (the parent `.../channels` is `0755`, so the probe works from any uid). That distinction is the whole fix: *unreachable* must fail loudly, *reachable-but-unreadable* must be delivered by someone who can read it.
- **the walk goes UP the whole org chart, not one hop.** `_gate_route_reviewer` stopped at the first manager plus the coordinator; if that one manager is also unpaired the ask died there. `_task_escalation_chain` walks `reports_to` upward (depth-capped, cycle-guarded) and the alert NAMES the original filer, because it arrives on the manager's bot and would otherwise read as the manager's own gate.
- **reachable-but-unreadable is delivered by a privileged re-send.** New root-only `task gate-escalate <ident>` re-sends an already-filed, still-pending gate; agents reach it through their existing NOPASSWD sudo entry (hardcoded to `/usr/local/bin/5dive` — sudoers grants that exact path, so a `command -v` result would be refused for a reason unrelated to the channel). The raw human nonce crosses on **stdin**, never argv.
- **an unnotified gate is FILED and MARKED, never refused — and the first cut of this got it wrong.** The original fix refused to file when nobody in the chain was paired, on the principle that a gate nobody can answer should not be recorded as filed. The principle is right and the precondition was wrong: it equated "no paired Telegram channel" with "no human can answer", when the dashboard **Needs you** card, `task inbox` and `task answer` are answering surfaces that need no channel at all. CI went red (nothing is ever paired there), and with it `5dive goal`'s plan gate, `tests/gate_parity_smoke.sh` — which asserts precisely this contract, *"gate filed CLI-only with no Telegram present"* — and every solo OSS, fresh-install or headless box. A second cut tried to scope the refusal to deployments that have channels configured; that still broke the parity smoke, because whether some OTHER agent on the box is paired says nothing about whether THIS gate can be answered. **Every attempt to define "nowhere to land" mis-fired in an environment we did not control, which is the signal that the condition does not exist.** So the gate always files; what must never happen — an unnotified gate reading identically to a notified one — is handled by marking it instead: `notified:false` in the JSON, an `UNNOTIFIED` note on the result line, a logged delivery error, `gate_pinged_at` left NULL, and the 15-minute re-nag re-driving it until it lands. Losing a gate is worse than delaying one.
- **the heartbeat re-nag had the same hole and the same fix.** An unpaired recipient meant "retry next heartbeat" forever, which for a channel-less filer can never become true. It now escalates up the chain (that sweep runs as root, so every `access.json` is readable). A gate with NO delivery receipt is also retried at **15 minutes** instead of waiting the full hour.
- **verified live, not by reading the notify function.** Filed as `agent-dev3` against the real board: the unprivileged leg failed loudly and rolled the gate back; the privileged leg delivered to the paired human with a confirmed Bot API receipt (`result=ok … message_id=…`) and stamped `gate_pinged_at`.
- **the pairing probe itself is three-valued, because a boolean put the conflation back one layer over** (found by main reviewing the PR). `_task_agent_paired` read the connector env with a bare `-r`, so an existing-but-unreadable token would have read as *unpaired*. Inert today (those files are `0640 root:claude` and every agent is in group `claude`), but **converting a silent degradation into a hard refusal raises the cost of every latent probe upstream of it**: before this change an unreadable probe cost a delayed gate, with fail-closed `task need` it costs a REFUSED gate on a healthy chain. Now `0` paired / `1` **provably** not paired / `2` undetermined, and only a provable `1` licenses refusing; `2` escalates to a sender that can actually see. The failure text distinguishes them as well — "nobody is paired" is only claimable when every agent up the chain was provably unpaired, otherwise what we know is that the hand-off failed. Its negative control is root-proof: the fixture points `CONNECTORS_DIR` at a regular **file**, since a `chmod 000` fixture proves nothing in a root CI run.
- **the first cut of this fix shipped the same bug one layer down** — `_task_chain_channel` was called in `$(…)`, so the `TASK_CH_*` it resolved died in the subshell and the "escalated" send went out with an empty token to an empty access file, still returning 0. Caught by the live run, not the suite; the suite now records the channel state AS OF THE SEND and greps for the call-site shape. `task gate-escalate` likewise asserts the CONFIRMED receipt rather than a resolved channel.

## 0.15.5 — fix(usage/cost/digest): coverage was collected and then dropped on the floor by every presenter but one (DIVE-1937) (2026-07-25)

0.15.3 taught `usage_collect` to report what it could READ, and taught exactly one consumer — `proof scorecard`'s tokens row — to respect it. The field then rode in the JSON on every collect while the verbs people actually run to check burn kept printing the same confident tables. **A collected-but-unrendered field is not a fix, it is a fix that has not shipped** (the shape that left DIVE-1908's `TODAY_LABEL` sitting unused).

- **`5dive usage` and `5dive cost` now print coverage BEFORE the numbers it qualifies.** A partial read is declared (`⚠ PARTIAL READ — 11 of 13 agent transcript sets readable from here. This is NOT the fleet:`), names the blind spots with their reasons, and says what would fix it. A complete read prints nothing new — coverage that shows up when everything is fine is noise, and noise is how a real warning gets skipped.
- **An UNLABELLED total counts as partial.** Same rule as the scorecard row: a collector that reports no coverage cannot be told apart from one that reported a short read.
- **`5dive usage <agent>` no longer answers "no usage for agent X" about an agent it was not allowed to look at.** That sentence reads as "X was idle"; it now fails with the reason and `this is NOT 'no usage', it is no visibility`. An agent whose rows exist but whose files were partly denied gets its own total marked a **FLOOR**.
- **`5dive cost` gives an unreadable agent a ROW, not a zero.** Before, a blind spot either vanished (no budget set) or sat there as `● 0 tok — ok`, which is the one sentence the read cannot support. It now renders `? gamma ? … UNREADABLE — burn unknown`.
- **`usage budget check` no longer PASSES an agent it never read.** `// 0` turned a blind spot into a confident zero, and a confident zero clears a budget: the check reported `0 soft, 0 at ceiling` for agents it had not looked at. Those are now `unknown` (cached `burn: null`, not `0`) and counted in the output. A **partial** burn is still a floor, so an agent already over its cap still fires — only the unearned "ok" verdict changes.
- **The digest's silence was the worst of the three, because its fallback ERASED the failure.** `usage` is root-only, so every non-root digest fell through `|| echo '{"data":{"agents":[],"tasks":[]}}'` to an empty agent list that renders exactly like a quiet fleet — and then the health line went on to print `💚 Fleet healthy — heartbeats fresh, no rate-limit pressure`, a claim about every agent, on the strength of a source it had never read. The fallback now carries `complete:false`, the standup states `🔒 Token burn UNKNOWN — … Unknown is not zero.` or `🔒 Token burn PARTIAL — 1 of 3 …`, and the healthy line degrades to `rate-limit pressure UNVERIFIED`. `--json` gains `usageCoverage` and `health.hotCoverage`.
- **The guard runs at ANY uid and fails on the pre-fix build: 23 of 26 assertions.** The defect is caller-dependent but the test is not — `tests/usage_presenter_coverage_unit.sh` drives the REAL verbs (`usage_render_board`, `usage_render_agent`, `cmd_cost`, `cmd_usage_budget_check`, the digest's embedded python) with only the collector stubbed, so root and an unprivileged agent run identical assertions. The 3 that pass pre-fix are the deliberate regression guards: a complete read must stay quiet, and a floor that already crosses a cap must still fire. It also asserts the digest's **shell** fallback directly — that failure lived in a bash string, and a python-level test structurally cannot see it (the DIVE-1914 wrong-layer lesson). Two assertions were rewritten after the first negative-control run showed them passing vacuously.
## 0.15.4 — feat(proof): policy-blocked attempts now has a source (DIVE-1922) (2026-07-25)

- **new `policy_refusals` table + `policy_refuse()` primitive** — the capture path behind `proof scorecard`'s `policy-blocked action attempts`, which shipped in 0.15.0 as an explicit NO DATA marker because nothing recorded it. We recorded gates that were ASKED and ANSWERED; we never recorded an attempt a policy REFUSED before it got that far. The metric now renders a real count instead of a marker.
- **the count never ships without its coverage.** `policy-blocked action attempts  N  (across 7 instrumented policy sites)`. A bare `0` here would read as "we never get blocked" — the same failure the NO DATA marker existed to prevent — and an *uninstrumented* refusal site is invisible to the count, so the reader has to be told the denominator. The site count is **derived from the shipped bundle**, never hand-maintained: a hand-kept constant drifts and then lies about exactly the thing that keeps a 0 honest.
- **`policy_refuse` is deliberately NOT used for validation errors.** A bad flag or missing arg is the caller getting the invocation wrong, not policy blocking an action; counting those would inflate the number into meaninglessness. An under-counted metric that reports its own coverage is honest, an inflated one is not. Seven genuine policy sites are instrumented (done-over-open-gate, the three merge gates, bare-block, park-over-open-gate, gate-withdraw-auth), each with a stable slug rather than the message text so rewording a refusal never breaks the series.
- **fix caught while building: the migration was unreachable on every existing box.** The first version nested the `policy_refusals` DDL inside the `supervisor_events` existence guard, so it only ran on stores that *lacked* `supervisor_events` — i.e. never on any real store. The table would never have been created and the metric would have read NO DATA forever, which is indistinguishable from "no refusals recorded yet": a silent no-op wearing the costume of a working feature. Guard on the table you are creating. Now has its own guard, verified against a store that already has `supervisor_events`.
- **REOPENED and fixed: the suite was green locally and RED in CI, and the local green meant nothing.** The migration case drove `tasks_db_init` by shelling the bundle at a bare `TASKS_DB` with `>/dev/null 2>&1 || true`. That swallowed the driver's exit code *and* depended on the ambient host store: on a developer box the migration ran as a side effect of init before `task ls` died on an unrelated `no such column: status`, so the assertion passed while the command it depended on was failing; on a clean runner init refuses outright and nothing migrates. The case now calls `tasks_db_init` directly on a throwaway `STATE_DIR` (the isolation override the sibling store suites use) and **fails loudly if the driver itself errors**. A test that needs the host to already be in the right state is not testing the code.
- **a skipped assertion no longer counts as a pass.** The behaviour-preservation comparison — the only thing standing between "telemetry was added" and "telemetry silently changed three exit codes" — reported `ok  origin/main unavailable — skipped` when it could not resolve `origin/main`. It now attempts a shallow fetch and, failing that, records a FAILURE. Counting a skip as a pass is how a suite reports green while its load-bearing assertion never ran.
- **the NO DATA marker no longer misdescribes what it measured.** The site count is derived from the `5dive` resolved on PATH — deliberately, since refusals are recorded by whatever CLI the box actually runs — but the marker said "this 5dive build has no instrumented policy sites", which is false whenever you run a build tree against an older installed CLI. It now names the path it inspected. A marker whose stated reason is wrong is its own small lie, in the one metric that exists to argue against those.
- **fix caught while testing: instrumenting a site silently changed its exit code.** `policy_refuse` hardcoded `E_CONFLICT`, which altered three sites' contracts (`E_USAGE`→`E_CONFLICT` twice, `E_AUTH_REQUIRED`→`E_CONFLICT` once). Adding telemetry must never change what a caller sees. The exit code is now a parameter, every site carries the code it had on `origin/main`, and a test compares against `origin/main` so this cannot recur. No existing test caught it — `task_park_gate_guard_unit.sh` fails for an unrelated environmental reason on this host and never reached the assertion, which is why "the suite is as green as main" is not the same as "my change is covered".
- **fix caught while testing: the metric could kill the whole verb, silently.** Under `set -euo pipefail`, the `grep` that derives the instrumented-site count exits 1 when it matches nothing, `pipefail` propagates it and `set -e` ends the verb — printing nothing and exiting 1. It greps the resolved `5dive` on PATH, so this fired on any box whose installed bundle predates DIVE-1922: the scorecard would have died silently everywhere until the new version rolled. A silent exit is the exact failure this verb exists to argue against.
- **the two no-data reasons are distinguished.** "No `policy_refusals` table in this store" and "this build has no instrumented sites" are different causes with different fixes; a marker whose stated reason is wrong is its own small lie.
- **recording is best-effort and can never prevent the refusal.** If the write fails the action is still blocked — a policy that stops working when its telemetry breaks is a worse failure than a missing row.

## 0.15.3 — fix(proof): the tokens row rendered a PARTIAL read as a complete number (DIVE-1929) (2026-07-25)

`proof scorecard`'s "tokens per accepted outcome" silently depended on WHO ran it. Same box, same window, three callers, three confident numbers with no marker between them: root **4,670,188**/outcome, `agent-olivia` **220,391** (4.7% of the truth, **21x** low), `agent-dev3` **46,253**. Found grading INST-7 on the shipped 0.15.0 binary.

- **the degrade was assumed BINARY, and the middle state is the dangerous one.** DIVE-1914 handled readable vs unreadable, and unreadable renders an honest `NO DATA`. But a caller who can read *some* transcripts is neither, and PARTIALLY readable is the only state that emits a number that is **wrong rather than absent** — on the one row whose source was substituted after the spec's named source (`digest.usage`) turned out empty.
- **an unreadable agent was indistinguishable from an idle one.** Every read failure in `usage_collect` hit a bare `continue`: the agent fell out of the result and its tokens out of the sum, leaving no trace. Worse, `os.path.exists()` answers **False** for a path under a mode-700 home, so "missing" could not be trusted to mean missing either — the collector could not tell "this agent did no work" from "I am not allowed to look".
- **the denominator made it arithmetic, not just thin.** `shipped` is always company-wide, so a one-agent numerator over an all-agents denominator is not a slice of the ratio — it is a different quantity wearing its label.
- **`usage_collect` now reports its own coverage**: sets READ against sets that EXIST, each unreadable agent NAMED with a reason (`transcript dir not readable by this user (needs root)`, `some transcript files unreadable: Permission denied`). Readability is PROBED — only a confirmable `ENOENT` counts as "nothing recorded here"; every other `OSError` means blind, and says so. The probe checks the transcript dir **before** the home, because a mode-700 home commonly sits over a reachable transcript dir and probing the home first would file a readable agent as a blind spot and drop its real tokens out of `5dive usage`.
- **the row applies the DIVE-1922 rule: a number never ships without its coverage.** At full coverage it renders and CARRIES it (`… ; 13 of 13 agent transcript sets readable`). Any partial read degrades to `NO DATA — only 1 of 13 agent transcript sets readable from here …`. An **unlabelled** total (an older collector reporting no coverage) counts as partial, because trusting one is how this shipped.
- **the guard is a negative control that cannot pass on the broken build, at any uid.** A test that runs only as root never sees this bug — root reads everything. So the primary case makes a transcript set unreadable in a way that defeats root too (a regular file where the directory belongs → `ENOTDIR`), and the production `EACCES` path runs additionally whenever the suite is not root. Verified against pre-fix `cmd_usage.sh` / `cmd_proof.sh`: **11/11** and **5/5** of the new assertions fail there.

## 0.15.2 — fix(agent ask): fence-only capture — the scraping fallback IS the fabrication path (DIVE-1901 iteration 2) (2026-07-25)

0.15.1 fixed the short-ask case and then failed live on a long one: a 2811-char ask to an antigravity seat returned `Gemini 3.6 Flash · high` — the TUI footer — at rc=0, while the seat had answered correctly with a well-formed fence sitting in the pane.

- **the fallback is not a safety net, it is the fabrication path, so it is now OFF by default.** Every bad reply this ticket has caught came from pane scraping and none from the fence: 0.14.7 returned the token *plus* the footer on antigravity and *pure box-drawing* on opencode; 0.15.1 returned the footer. A scrape cannot tell "furniture that happened to hold still" from "an answer" — at the instant it looks they are the same thing, text on a screen that is not changing. A fence can: an unclosed fence is unambiguously not finished. `ask` now returns the fenced reply or **nothing**, and nothing becomes a timeout that names what it saw (fence opened but never closed / delivered but never fenced / marker never seen, which is a delivery failure, not a capture one).
- **`--allow-unfenced` restores scraping for a seat that cannot follow the instruction, and is REFUSED on a council ask.** "Everyone just sets the flag" is how this fix would decay, so the governance path rejects it in validation rather than by convention. A ballot may never fall back to a rail that can return furniture as a vote; such a seat records as `abstainKind=capture-failed`.
- **marker lines are matched by SHAPE, not by a glyph list.** The first draft used a hardcoded list, and a pane whose bullet was not in it (`◆`) fell straight through to the fallback — a per-harness signature smuggled into the one function whose entire purpose was not having one. Caught by its own test.
- **`FIVE_ASK_DEBUG_DIR` persists what the extractor actually saw** — baseline, accumulated transcript, returned slice — on both the success and timeout paths. The original failure could not be reproduced from a pane dumped minutes later, because an alt-screen TUI redraws in place and the frame was already gone.
- **CORRECTION to the 0.15.1 notes, which are published and wrong on this point.** They state that a full-screen TUI has no scrollback and that `capture-pane -S` is therefore inert. That was measured on claude and codex panes and **overstated as a universal**: `-S -200` on a live antigravity pane returns 100 non-blank lines, 50 unique, including real history. Scrollback availability is **per-harness**. The rail now asks for `-S` (free where it works) *and* accumulates frames (needed where it does not).
- **this release makes the failing case pass; it is NOT a diagnosis of it.** The original failure was never reproduced offline — three real renders from the failing seat replay through 0.15.1 correctly, and a sweep of all 201 windows of that scrollback produced zero furniture returns. What carries this fix is a structural argument, not a repro: fabrications came from the fallback, the fallback is off, so that frame is unreturnable whatever it was. A green run here should not be read as the mechanism having been understood.
- tests: `ask_cmd_wiring_unit.sh` (4) drives `cmd_ask` itself, both dispatch branches, under `set -u` — the previous suites tested only the pure helpers, and that gap shipped an unbound-variable crash on the exact branch this iteration exists to fix; reintroducing the defect reproduces the original error at the original line. `ask_capture_live_replay.sh` (5) replays real pane renders from the failing seat, including the mid-write frame, and states in its header that it does not reproduce the live failure. `ask_capture_unit.sh` (9) unchanged, now behind `--allow-unfenced`.

## 0.15.1 — fix(agent ask): the seat answers and the rail returns nothing — or returns the pane's own furniture (DIVE-1901) (2026-07-25)

`5dive agent ask` could not capture a reply from a full-screen TUI seat. The agent answered — a pane scrape proved it — and the rail returned empty, or timed out. A `council convene` dispatches ballots over this rail and folds an uncaptured reply into a plain **ABSTAIN**, so a seat that voted read as a seat that declined to. On a governance engine that is the worst available failure: the receipt seals, looks clean, and misreports what the council decided.

- **the root cause is not agy/opencode-specific — it is the ALTERNATE SCREEN.** A full-screen TUI has no scrollback, so `capture-pane -S -2000` returns the same ~24 visible lines as no `-S` at all. The rail reported a 2000-line window and delivered a screenful, with no signal it had been clamped. Measured across every claude agent on the box (`alt=1`, `-S -5000` = 24 lines) against a codex control (`alt=0`, `-S` genuinely widens). claude was never exempt, only lucky.
- **two failure modes, anti-correlated by message length, and THERE WAS NO LOUD ONE.** Long message → the `id=<msg_id>` echo scrolls off and the marker is unrecoverable, so the rail either times out with "no idle reply" while the seat has answered, **or exits 0 carrying stabilised furniture** — measured on a live antigravity seat, where a 2811-char ask returned blank lines and `? for shortcuts` at rc=0. Short message → the marker is still on screen and the slice is non-empty but is nothing but static TUI chrome, unchanged for `--idle-secs` → the footer comes back **as the reply**, in 9s, before the seat typed a character. So a long council ballot can seal a clean-looking chrome abstain exactly like a short one. An earlier draft of these notes said the long mode at least fails loudly on ballots; that was **false**, and "the dangerous mode is at least noisy" is precisely the belief that makes a partial fix look sufficient.
- **replies are now FENCED.** `ask` asks the seat to wrap its answer in `<5dive-r:id>…</5dive-r:id>` markers and returns what is between them. Whatever the harness draws around it is outside the fence by construction, so there is no per-TUI signature list to maintain and no heuristic to get wrong.
- **the fallback window is still hardened**, for a seat that ignores the format: the visible pane is accumulated frame-by-frame so the marker survives scroll-off, the question echo is consumed against the sent message *in order* (so "reply with exactly this: X" still returns the seat's X), and the pane's own furniture is subtracted using the pane as it looked immediately **before** injection — with a normalised compare, because footer counters move (`used 43% of your weekly limit` → `44%`).
- **`agent ask --json` returned an EMPTY DOCUMENT on every successful ask.** `reply_to_chat:($rc|select(length>0))` yields jq's `empty` when the value is empty, and `empty` propagates out of the enclosing object construction: jq printed nothing and exited 0. `council convene` does `JSON.parse(stdout)` on that, throws, and catches straight into an abstain — a second, independent cause of the same symptom, firing even when the capture was perfect.
- **a capture failure is no longer indistinguishable from an abstention.** A convene still tallies an unheard seat as an abstain (we cannot count it aye or nay), but the vote now carries `abstainKind: capture-failed | capture-empty | unparsed` and a rationale that says **CAPTURE FAILED (not an abstention)**. An empty reply is tagged too, instead of arriving as "no COUNCIL-VOTE line".
- **the tests assert the returned STRING by equality**, plus that no chrome substring (`weekly limit`, `bypass permissions`, `shift+tab`, `esc to interrupt`) ever rides along. Non-emptiness is exactly what mode B satisfies, so an exit-code or non-empty assertion would have passed on the bug — which is how this stayed invisible.

## 0.15.0 — feat(proof): `5dive proof scorecard` — multi-dimensional autonomy metrics by risk tier (DIVE-1914) (2026-07-25)

Headline capability of the v0.15 "Proof you can trust" minor. Local and read-only, like `proof status`. The badge (1 − asks/shipped) stays the **headline** number; the scorecard exists so a single score is not the only score, and therefore not worth gaming.

- **new `5dive proof scorecard [--json] [--7d] [--by=tier|class]`.** Five sourced metrics: human interruptions per accepted outcome, verifier first-pass rate, median recovery time, precedent acceptance rate, and tokens per accepted outcome.
- **every rendered number is backed by a source PROVEN to exist before the metric shipped.** A metric with no source renders `0.0%` and reads as *"we never get blocked"* — a confident zero on the honesty instrument itself. `policy-blocked action attempts` and `autonomous rollback rate` therefore render an explicit **NO DATA** marker naming the task that would build the source (DIVE-1922, DIVE-1923), never a number. The unit test's assertions are mostly negative: given empty sources, no number may appear — a happy-path-only test would pass on exactly the build this prevents.
- **the spec's cost source did not exist, and ground-truthing caught it.** `cost per accepted outcome — digest.usage + done count` was specified after confirming digest *exposed* a `usage` key, without checking whether it *contained* anything. It is `[]` on every window. Empty is not thin, it is absent, and it would have shipped as a confident 0.
- **the row is NAMED `tokens per accepted outcome`, not `cost` with a footnote.** A label is a footnote; the row name is the claim, and a reader scanning a scorecard reads names. The output then states as a **fact** that no money figure exists here because the work runs on a subscription plan — which tells the reader *why*, not merely that something is missing. This restates the standing stance already in `cmd_usage.sh`: subscription inference has no per-token price, so a `$` column would be fiction.
- **tier coverage sits NEXT TO the tier breakdown.** `tier` is NULL on 73% of shipped work, so a bare 0/1/2 breakdown reads as the shape of the whole while describing a quarter of it. The output leads with `tier known for 27% of shipped work (110 of 408)` and gives untiered its own visible bucket. The coverage number is the most actionable thing on the row: it says our own tiering discipline is the gap, not the metric.
- **sample sizes ride ON the number**, not in a footnote — `594s (n=1 episode)`, `50% (n=2)`. A bare rate off n=2 is not a rate.
- **`--by=class` computes what it claims** (caught by olivia on review). It was validated as a legal value and then never used — grouping was always by tier, so `--by=class` emitted `"by": "class"` beside a breakdown of tier data. Output asserting what the code never computed is precisely the class this verb exists to prevent. `--by` now selects the grouping expression and the coverage definition, and the dimension label ships *inside* the breakdown object so the header and the rows cannot describe different things. Class is `project_key + priority` per the spec, ground-truthed as non-empty on all 408 shipped tasks (100% coverage, against tier's 27%).
- **the guard for that defect sits at the SHELL layer, because a renderer-level guard was vacuous.** The first version asserted on the python renderer — which is handed its rows by the harness and so groups whatever it is given. Reintroducing the defect did not fail it. The assertion now extracts the real `case "$by"` block from the shipped source, evaluates both branches and requires they produce *different* SQL; an inert flag value makes them identical, which is exactly how this hid. Verified by negative control: the reintroduced defect fails two assertions.
- **`--30d` is refused with a pointer, not silently accepted.** `digest` supports only `--7d`; offering a 30-day window here would be a window the verb cannot compute (expansion tracked as DIVE-1921).
- **`--json` reads the global `JSON_MODE`.** `main.sh` strips `--json` before dispatch, so a local `--json)` case would have been dead code that silently rendered text.
- **digest is passed by FILE, not environment** — the DIVE-1864 `E2BIG` trap one verb along; a live digest exceeds `MAX_ARG_STRLEN` and failed with a bare "Argument list too long".
- Numbers come verbatim from `digest` / `tasks.db` / `usage_collect`. There is deliberately **no flag that adjusts one** — same no-edit path as `proof publish`. Nothing is published: extending `zero-human.json` or `badge.json` with any of this is a brand act needing a lodar gate.

## 0.14.15 — proof: the badge stays minimal; an independent watcher marks it stale (DIVE-1924) (2026-07-25)

- **the badge message is the number alone again — `zero-human 85.9%`, no date.** 0.14.14 appended the ISO date because `badge.json` carried none and therefore rendered a stale number as CURRENT for as long as the publisher stayed dead. lodar's call, and he is right: the date is visual noise on the one asset whose whole value is being instantly readable. The honesty requirement does not have to live in the message.
- **new `.github/workflows/badge-staleness.yml` — an hourly watcher that rewrites `badge.json` to `stale — last published <date>` once the newest publish is older than 26h.** The next successful publish overwrites it back, so there is exactly one writer of the healthy state and no repair path to get wrong.
- **why a watcher may do what the publisher may not.** A dead publisher cannot mark itself dead — that is why there is still no publisher-set `stale` flag and no self-set colour. The workflow is not the publisher: it runs on GitHub, not on the box, so it survives exactly the failures that take the publisher down (host dead, cron never fired, credential expired, state dir unwritable — the DIVE-1888 case that sat broken for two weeks). It is also the one guarantee the DIVE-1896 host monitor cannot make, because that monitor shares a host with the thing it watches. The two are complements: the host monitor pages US fast, this one protects the READER.
- **it fails loud and never guesses.** A missing or unparseable `zero-human.json` exits non-zero and writes NOTHING — an unreadable artifact is not a stale one, and writing "stale" on a read failure would be inventing a fact, which is the defect this badge exists to avoid. Hourly cadence is deliberate per DIVE-1909: detection latency is the SCHEDULE, not the threshold.
- **the DIVE-1908 agreement property survives, moved to the fields that still carry a date.** `zero-human.json`'s `date` must be the day part of its own `generatedAtUtc`, byte-identical, no parsing — one clock read feeds both. Deleting the badge's date must not silently delete the property that made the dates trustworthy, and the watcher reads exactly those fields.
- test: `tests/proof_publish_unit.sh` 21/21 — the badge message is pinned to the bare number so anything appended fails, plus the moved agreement assertion and a guard that `generatedAtUtc` really had a time part, so that check cannot pass vacuously.


## 0.14.14 — fix(proof): the zero-human badge now carries its own date (DIVE-1908) (2026-07-25)

- **fix: the badge rendered a stale number as CURRENT, indefinitely.** `badge.json` was `{schemaVersion, label, message: "85.9%", color}` — **no date**. The README renders exactly that shields endpoint and introduces it as "the claim, measured", while the date existed only in `zero-human.json`, which no README reader ever fetches. The badge message now carries the datapoint's own day: `85.9% · 2026-07-25`.
- **the standing design claim was false.** The docs said "on any error nothing publishes and the badge date stops moving — a stale date IS the alarm (self-evident staleness, no watcher daemon)". That was a designer's assumption about an artifact which did not carry the signal. There was no self-evident staleness and there never was; a dead publisher was invisible to every public viewer for as long as it stayed dead. This is our own defect class aimed at the honesty instrument itself.
- **it also revalues DIVE-1896.** That staleness monitor was framed as a watcher backing up a self-evident public signal. There was no such signal, so the monitor was — and until this change remained — the *only* staleness detection that existed, public or internal.
- **a DATE, never an AGE — the principle behind the two calls above.** A date is a *fact the artifact carries*; an age (`2d ago`) is an *assertion that decays* the moment it stops being rewritten. A dead publisher frozen at `0d ago` would be actively lying, where a frozen date is merely stale and the reader can see it for themselves. That is the same reason there is no publisher-set "stale" flag: a dead publisher cannot mark itself dead, so freshness must be readable from the last value the publisher *wrote*, never from a status it would have to keep updating while broken.
- **the date is on BOTH message branches, deliberately.** A zero-shipped week (`0 shipped, 1 ask`) is exactly when a reader most wants to know how old the number is, so the date must never be the thing that drops out when the reading gets unusual.
- **no publisher-set "stale" flag.** A dead publisher cannot mark itself dead — that is the same trap one layer down. Freshness is readable from the last value the publisher wrote, never from a status it would have to keep updating while broken.
- **full ISO date, not a `Jul 25` label.** This artifact's entire job is making staleness visible to a reader who has none of our instrumentation, and a month-day label is unambiguous only inside a 12-month window — a known-wrong reading on the one artifact that exists in order not to be wrong. Pointing at the internal hourly staleness monitor as mitigation would be the very move that produced this bug: "a stale date IS the alarm" was internal reasoning about an external artifact.
- **the badge date is the SAME STRING as `zero-human.json`'s `date`**, not a reformatting of it, so the two artifacts agree by being identical rather than by surviving a transformation that could drift. The test asserts that agreement verbatim instead of merely asserting a date is present.
- **one clock read, and `today` is DERIVED from it.** `_proof_build` computed the day with its own `date -u +%F` alongside a separate `date -u +%FT%TZ` — two independent computations that merely happened to agree, which is exactly what drifts, and which can genuinely disagree across a midnight boundary. `today` is now `${now_iso%%T*}`, so `badge.json`'s date, `zero-human.json`'s `date` and its `generatedAtUtc` describe the same instant structurally. The equality the test asserts is therefore *wiring*, not a formatting convention.
- **removed the dead `TODAY_LABEL` plumbing.** It was computed (`date -u '+%b %-d'`) and exported into the builder for years and read by *nothing* — which is a large part of how the missing badge date stayed invisible. The badge reads `$today` directly now, so the label is dead again and is deleted rather than left implying a consumer that does not exist.
- `badge.json` is serialized with `ensure_ascii=False` so the separator stays a real character instead of a `\u00b7` escape — shields parses either, but the file is also read by humans checking whether the badge is stale, which is the entire point of it. `badge.json` is shields-internal per the API contract (`zero-human.json` + `history.jsonl` are the additive-only public contract), so no consumer breaks.

## 0.14.13 — fix(auth): close the two silent gaps main flagged on the DIVE-1900 review (DIVE-1915) (2026-07-25)

- **fix: a PRESENT-but-stale local token was still a silent failure.** DIVE-1900's loud error only fired when the local credential was missing or empty, so an agent holding an old token alongside a *newer, unreadable* profile token re-seeded nothing and said nothing — and no amount of re-authing would ever reach it. That is the same shape DIVE-1900 exists to kill, one case narrower. The post-seed assertion is now a single shared `assert_cred_seeded` used by both antigravity and openclaw, and it covers it.
- **UNREADABLE and ABSENT are no longer collapsed into one message.** They are different faults with different fixes — absence is "go log in", unreadability is "the credential is fine, the perms are not". An untraversable profile dir counts as *may be present*: unknown fails toward the alarm, never toward a false all-clear, because on this code path the expensive mistake is a false all-clear.
- **the dir walk's dependency is now named in the source and asserted in the test.** `normalize_profile_seed_perms` walks up to but not including the profile root, so correctness rests on the store root and each profile root being group-traversable — a mode it never sets and never checks. It stays that way deliberately: widening a directory this function did not create is a bigger decision than fixing a credential's mode, and both roots are ours to keep correct at creation time (`profile_type_dir` creates them 2750). The test now asserts the **whole path chain** from the credential up to the store root, so this fails loudly if either root is ever created or tightened to `0700` instead of quietly un-fixing every seed beneath it.

## 0.14.12 — fix(auth): a SUCCESSFUL antigravity/openclaw login never reached the agent (DIVE-1900) (2026-07-25)

- **fix: the credential seed in `5dive-agent-start` was `sudo`-only for antigravity and openclaw, so a valid token stayed in the auth profile and never arrived in the agent's home.** Every probe in both blocks (`test -e`, `test -nt`, `cat`) went through `sudo -n`. Standard-isolation agents get no NOPASSWD sudoers rule, so the very first `sudo -n test -e` failed, the whole branch was skipped, and **nothing was printed**. Both blocks now try a plain read first and keep `sudo -n` only as the fallback for a not-yet-normalized `0600` file — the same fix codex/grok got in DIVE-1188 and hermes got in DIVE-1394, never applied to these two.
- **why it cost days to find: it presents as an EXPIRED credential.** With no token to refresh, the agent falls back to exchanging a one-time auth code and dies with `invalid_grant "Malformed auth code"` — which reads as a stale login, so the fix looks like "re-tap the OAuth". Meanwhile the auth profile holds a valid token, `5dive agent list` reports ACTIVE and the seat row says enabled, so **every status surface agrees and every one of them is wrong**. The auth succeeded at the profile layer and never reached the layer that runs.
- **fix: `normalize_profile_seed_perms` covered codex and grok only** — it now covers hermes, openclaw and antigravity too, and **also opens the directories**, not just the file mode. The `HOME`-redirect types (grok/openclaw/antigravity) let the vendor CLI create its own dot-dirs under the profile and those land `0700 owner=claude`; a group-readable file under an untraversable directory is still unreadable, so fixing the mode alone was never enough. The dir walk is bounded to inside the profile root and cannot widen anything above it.
- **fix: `5dive agent restart` now re-normalizes the bound profile's seed perms before the unit comes back up.** Restart is the documented "make a fresh login take effect" step, but the boot-time seed runs as `agent-<name>` and cannot `chmod` anything in the profile — so restart re-seeded nothing, every time, silently. `agent restart` runs as root, which is the only place this can be fixed.
- **fix: the same sudo-only gate silently skipped openclaw's model-defaults sync**, leaving the gateway on the global `openai/gpt-5.5` default and rejecting every message with "Missing API key for OpenAI" while the profile itself looked correctly configured.
- **new: the failure is now LOUD.** When a credential exists upstream but is unreadable, the agent prints an explicit error naming the misleading downstream symptom (`Malformed auth code`) and saying plainly that this is a seeding/permission fault, not an expired token.
- **new regression tests.** `tests/agent_start_cred_seed_unit.sh` runs the real seed blocks extracted from the shipped script with `sudo` stubbed to always fail — exactly what a standard agent sees — and asserts the credential still arrives, that a rotated token re-seeds on restart, and that an unreadable-but-present credential is announced rather than skipped. A guard assertion fails the build if any seed block goes back to gating solely on `sudo -n test -e`.

## 0.14.11 — fix(proof): proof.json was frozen; every write failed and every command still returned 0 (DIVE-1888) (2026-07-25)

- **fix: no write to `${STATE_DIR}/proof.json` had landed in two weeks, through TWO independent silent failures.** The `lastPublished` stamp sat behind a `[ -w "$(dirname "$f")" ] || [ -w "$f" ]` guard that, when false, skipped the write entirely — no error, no log line, nothing; a guard meant to be defensive instead erased the evidence. The other four write sites were unguarded, so their redirection error escaped (`/var/lib/5dive/proof.json.tmp: Permission denied`, one line per publish, sitting in the publisher's own log for days) and were then `|| true`'d straight back to exit 0. Root cause was a permission: the state dir is root-owned with no group write while the publisher runs as a non-root user, so `proof.json` still described the publisher that was deleted under DIVE-1865.
- **new `_proof_pref_write`** replaces all five hand-rolled `jq … > "$f.tmp" && mv … || true` sites. It persists atomically (tmp+rename) when the state DIR is writable and falls back to truncate-in-place when only the FILE is — so a locked-down state dir keeps working, and granting group-write on the single `proof.json` is enough. `chown/chmod --reference` carries the existing owner and mode onto the replacement, so a root-run write can no longer strip the group-write bit the non-root publisher depends on.
- **fix: a publish that cannot record that it ran no longer reports success.** The `lastPublished` stamp is unguarded and FATAL — staleness monitoring reads exactly that field, so a publisher that silently forgets it ran is worse than one that crashes. `proof tick` no longer sends stderr to `/dev/null`, or every loud message would die in the cron driver.
- **fix: freeing the tick's stderr did not make it audible, so the exit code carries the signal now.** Dropping the `2>&1` only moved the message into `/var/log/5dive-proof.log` — which is `root:root` on this box, so a non-root tick cannot open it, and the cron line's redirect is evaluated **as `${user}` before `/usr/local/bin/5dive` ever runs**: the command would die on the redirect, before publishing, with cron mail as the only signal. `_proof_tick` no longer `|| true`s its result (exit 3, already-published, still maps to success), and `_proof_install_cron` now **proves its log destination** while it still has root — creating it, chowning it to the cron user, and warning loudly if it cannot. Same shape as the DIVE-1896 monitor failure: a destination nobody checked. Caught by main on review.
- **`proof tick` has no live caller** on the 5dive box — its only caller was the cron removed under DIVE-1865, and the real publisher invokes `proof publish` directly. Said plainly in the source so DIVE-1889 does not re-wire against a dead path.
- **fix: `proof status` no longer implies "never published" when it means "cannot persist".** Those two states printed identically. It now prints the unwritable path explicitly, and `--json` gains `stateWritable`.
- **fix: `proof on --user=<u>` used to LOOK like it worked when `<u>` could not write the state.** It runs as root, so the config persisted fine and said nothing — anyone repointing the publisher without fixing perms first would believe they succeeded. It now checks writability AS the configured user and prints the exact remediation.
- **feat: the published payload identifies its own publisher.** `zero-human.json` and every append-only `history.jsonl` row now carry `publishedBy: {host, user}`; `proof.json` gains `lastPublishedBy`. A `cliVersion` DATES an artifact, it does not IDENTIFY its author — reading it as identity is what sent the DIVE-1865 publisher hunt to a machine that did not exist. Additive-only, per the `zero-human.json` API contract.
- test: `tests/proof_state_persist_unit.sh` — both write mechanisms, the loud non-zero failure when neither is available, mode preservation across a rewrite, the `proof status` warning and `stateWritable` flag, source-level guards that the `[ -w ]` skip and the `|| true` swallow cannot come back, and the `publishedBy` stamp (present when known, omitted when not).

## 0.14.10 — task: the verifier-rail auto-skip is now LOUD, and reversible (DIVE-1880) (2026-07-25)

- **fix(task): `task add --priority=low` silently declined the DIVE-969 verifier rail.** Low priority (and a bodyless chore title) auto-skips the verifier-by-default posture — correct behaviour, but the add line printed *nothing* to say so, while medium+ prints a positive "verifier-graded by default → <grader>" notice. A filer could not tell a railed task from an unrailed one without inspecting the row afterwards, so a task meant to be graded closed outright on the maker's own `task done`. Hit live on DIVE-1877. The add line now announces the decline — `· NOT verifier-graded (low priority) — 'task done' will close it outright; attach a grader with: 5dive task verifier <ident> <agent>` — and `--json` carries `verifySkipped` + `verifySkipReason`. Reasons are `low priority` / `bodyless chore title`. **No behaviour change to the skip itself** — auto-skipping real chores stays right; doing it silently was the defect. `--no-verify` stays quiet (an explicit opt-out is already visible).
- **feat(task): `5dive task verifier <id|DIVE-N> <agent> [--accept=<criteria>] [--max-iters=<n>]`** attaches the maker→verifier rail to an **already-filed** task. `--verifier` only ever existed on `task add`, so a mis-filed task could never be railed — the only remedy was cancel-and-re-file, which loses the thread. It derives acceptance criteria when the task has none, clears the INST-2 `verify_unavailable` flag, and from then on `task done` **hands off to the grader instead of closing**. Guards: refuses a closed task (points at `task reject`, the real remedy there), a recurring template, and making a task's own assignee its grader (writer != grader, DIVE-474). Deliberately **one-way** — there is no detach flag, since quietly removing a control is the failure class this fixes; opting out stays an add-time decision (`--no-verify`).
- **The DELIVERED / awaiting-verifier middle state is handled explicitly.** A maker's `task done` re-queues the row as `status='todo'` with `assignee=<the verifier>` and `maker_agent=<the maker>`, so mid-review the *assignee is the outgoing grader, not the maker*. Running `task verifier` there **re-points the review and moves the task to the new grader** (delivery clock re-stamped so the DIVE-1416 stall sweep times the new review; `maker_agent` and `iteration` untouched), the writer!=grader guard compares against `maker_agent` so handing the review back to the maker is still refused, and naming the grader who already holds it is an idempotent no-op on the handoff rather than an error.
- Note for filers: an explicit `--verifier=<agent>` **already forces the rail ON at any priority** (it short-circuits the auto-skip and is stored verbatim) — now covered by a test so it can't regress. The auto-skip is a default, not a ceiling.
- test: `tests/task_verifier_rail_unit.sh` (22 assertions, isolated temp `STATE_DIR`, no root/network) — skip announced in text + JSON with reason, low priority still genuinely unrailed, medium still engages, `--verifier` forces it on at low, chore-title reason, `--no-verify` quiet, retro-attach + derived criteria, `task done` routing to the verifier after a retro-attach, `--accept` override, all four guards, and the mid-review re-point (queue moves, ACK cleared, maker preserved, idempotent same-grader call, maker-as-grader refused, and the new grader's own `done` closing it). `task_core_unit`, `gate_verifier_route_unit`, `loop_verify_unit`, `task_deliver_merge_gate_unit`, `task_merge_gate_autodetect_unit` all green.

## 0.14.9 — models: one source of truth for Claude model ids, + fable (DIVE-1883) (2026-07-25)

- **fix: every hardcoded Claude model id was stale, and they disagreed with each other.** `cmd_compose.sh` mapped `opus -> claude-opus-4-8` / `sonnet -> claude-sonnet-4-6`, `agent_setup.sh` defaulted the create-path pin to `claude-opus-4-8`, and the telegram plugin's `MODEL_ALIASES` mapped `opus -> claude-opus-4-7` — a whole version behind the CLI. So `/model opus` over Telegram and `5dive compose` gave you two different models, and every newly created agent was pinned to 4.8 at birth. `claude-opus-5` appeared nowhere in `src/`.
- **new `src/lib/models.sh` is the single source of truth.** `model_latest()` maps `opus | sonnet | fable | haiku` to the current full id; `resolve_model_alias()` resolves an alias and passes anything else (a full id, a BYO `vendor/model` slug, empty) through untouched. Both CLI call sites now resolve through it. A model release is a one-line change in that file and nowhere else.
- **feat: `fable` is selectable.** The compose/create alias map only knew opus/sonnet/haiku, so `fable` could not be picked by alias at all. Current ids: opus `claude-opus-5`, sonnet `claude-sonnet-5`, fable `claude-fable-5`, haiku `claude-haiku-4-5-20251001`.
- **feat: `5dive models [--json]`** prints the alias -> id map. The telegram plugin reads `5dive models --json` at boot and merges the result into `MODEL_ALIASES` (baked defaults remain the fallback for upstream/non-5dive hosts), so the picker can no longer drift from the CLI.
- **DIVE-506 behaviour is preserved deliberately.** The create path still writes a FULL RESOLVED id, never a bare alias — CC >= 2.1.181 runs a startup migration (migrationVersion 13) that strips `model: "opus"` from a FRESH config dir, stranding a new agent on the default model. It is now resolved from the catalogue instead of a baked constant. The asymmetry with the nightly heal in 5dive-api `scripts/update.sh` (which writes the BARE alias to EXISTING agents, safe because their config dir is not fresh, so they float forward) is unchanged and documented in `models.sh`.
- **out of scope, flagged:** the third-party BYO/OpenRouter catalogues in `header.sh` (`CLAUDE_PROVIDER_*_MODEL`, `HERMES_PROVIDER_MODEL`, `OPENCLAW_PROVIDER_MODEL`) are vendor slugs on a different registry, not first-party ids, and were left untouched — `[openrouter]="anthropic/claude-opus-4.8"` looks stale next to its already-current sonnet entry, but the replacement slug needs verifying against openrouter.ai before it is changed.
- test: `tests/model_aliases_unit.sh` — alias resolution incl. fable, pass-through for full ids / BYO slugs / empty, every family mapped, `models_json` shape, a DIVE-506 guard that no resolved pin is a bare alias, a **drift guard** that no `.sh` outside `models.sh` re-inlines a `claude-*` id, and a bundle check that `./build.sh` was re-run.

## 0.14.8 — fix(agent-start): codex resolved through an nvm alias that nvm never creates (DIVE-1882) (2026-07-25)

- **fix: every codex agent on a freshly provisioned box crash-looped forever.** `5dive-agent-start` hardcoded `BIN="/home/claude/.nvm/versions/node/v24/bin/codex"` — a literal `v24`. nvm only ever creates **versioned** dirs (`v24.18.0`); there is no bare `v24`. So on any box without a hand-made symlink the path never resolved, agent-start exited 3, and `Restart=on-failure` bounced the unit every ~3s indefinitely (one box was found at **9563 restarts**, roughly a full day of wasted CPU, logging `binary not installed: /home/claude/.nvm/versions/node/v24/bin/codex`). Installing codex did **not** fix it: `npm install -g` lands the binary under the real version dir, and the unit kept looking at the alias. The reason this was never caught is that the control-plane host carries a **manually created** `v24 -> v24.16.0` symlink from 2026-05-27 — the only machine where the path resolved.
- **codex now resolves the same way `TYPE_BIN[codex]` does** (the DIVE-1329 fix, which only ever reached the CLI, not the boot script): the stable `~/.local/bin/codex` link written by `5dive agent install codex`, then `nvm which 24` when the shell has nvm, then the newest on-disk `v24.*`. A miss now names both search paths and points at `5dive agent install codex --upgrade` instead of failing with a single bogus path.
- **the version glob picks the NEWEST runtime, not the first one.** The shared `newest_node24_bin` helper sorts with `sort -V`, because `v24.18.0` sorts *before* `v24.9.0` lexicographically — the plain glob loop `resolve_openclaw_node` already used would have selected the older Node as soon as a box held two v24 minors. On the control-plane host the resolver now returns `v24.18.0/bin/codex`; the old alias pointed at the stale `v24.16.0` copy.
- **fix(systemd): a permanent boot failure no longer retries forever.** `5dive-agent@.service` gains `RestartPreventExitStatus=2 3` — agent-start exits 2 for an unknown `AGENT_TYPE` and 3 for "binary/plugin not installed", neither of which heals by retrying — plus a `StartLimitIntervalSec=120` / `StartLimitBurst=10` backstop in `[Unit]` for permanent failures the exit code does not name. systemd's default limit (5 starts / 10s) could never trip here because `RestartSec=3` already spaces starts ~3s apart, which is exactly why the loop above ran unbounded. Transient failures (crash, OOM, network) still get the normal `on-failure` restart. Clear a tripped unit with `systemctl reset-failed 5dive-agent@<name>`.
- test: `tests/codex_bin_resolution_unit.sh` — static guard that no bare-`v24` path returns to the boot script and that the unit carries both restart guards, plus a behavioural pass that drives `resolve_codex` against a sandboxed nvm tree (absent codex fails cleanly; `v24.18.0` wins over `v24.9.0`; the `~/.local/bin` link wins over both).

## 0.14.7 — fix(proof): publish no longer dies on a >128KB digest blob (DIVE-1864) (2026-07-24)

- **fix(proof): `proof publish` silently failed once the ledger grew large.** `_proof_build` passed the full `5dive digest --json --7d` output to its honesty-core python step through the `WEEK_JSON` environment variable. As the lifetime ledger grew (~374 shipped actions), that blob reached ~136KB and crossed the Linux per-argument kernel limit `MAX_ARG_STRLEN` (32 pages = 131072 bytes), so the python exec died with `E2BIG` ("Argument list too long", rc=126) and **nothing published** — the daily 09:00 cron hit the same wall, leaving `proof status` stuck on `last published: never`. This blocked the (approved) first public fire of the zero-human badge.
- **The digest JSON now flows to python via temp files** (`DAY_JSON_FILE`/`WEEK_JSON_FILE`) written under the builder's work dir (outside the status-branch checkout, so `git add -A` never commits them). The numbers are still read verbatim with no edit path; the builder falls back to the inline `DAY_JSON`/`WEEK_JSON` env vars when no `*_FILE` is set, so the honesty unit harness and shim callers are unchanged.
- test: `tests/proof_publish_unit.sh` gains Case 6 — a ~200KB day blob (which would `E2BIG` as an env string) is driven through the `*_FILE` path and asserted to build verbatim (6 shipped / 0 asks → `100%`). Existing cases (fresh publish, same-day no-op, pluralization, cumulative sums, DIVE-1552 rolling-7 window) still green.

## 0.14.6 — heartbeat: DIVE-1858 Phase 1 Stage 2 — live auto-sleep for cold agents (2026-07-24)

- **feat(heartbeat): a `wake_mode=cold` agent that goes idle with NO open work is now auto-slept (`systemctl stop`) after an idle threshold, then woken again by the next trigger.** This completes the reactive wake<->sleep loop: the WAKE half already shipped in Stage 1 (`_hb_wake` starts a stopped unit for a due todo, budget-gated), so Stage 2 adds only the SLEEP half — a new `_hb_autosleep_sweep` pass in `heartbeat tick`. It arms an idle timer on the first idle+no-work tick and stops the unit once idle has persisted past `--sleep-after` minutes (default 15, env `HEARTBEAT_SLEEP_AFTER_MIN`, per-agent override). Every guard is additive: **always_on agents are never considered** (default — zero behaviour change), sleep fires **only on a confirmed idle reading** (busy/blocked/unknown pane disarms the timer) with **no open assigned task** (fail-closed — a db error reports "has work" and never sleeps a live agent).
- **safety (olivia condition 3):** protected agents (`main` + `marketing`, extend via `HEARTBEAT_WAKE_PROTECTED`) are never slept even if mis-flagged `cold`. **(condition 2):** the dispatcher (the tick itself) stays always-on and self-monitored via the shipped DIVE-1434 poller-liveness canary, so a slept agent with a later trigger is always woken by a subsequent tick. **(condition 4):** still ZERO billing surface — cost-per-wake stays display-only.
- **feat: `5dive heartbeat wake-mode <name> [--sleep-after=<min>]`** sets the per-agent idle-before-sleep threshold; the read view + `set` confirmation now surface it. The tick summary gains `slept` / `sleepArmed` counters (text + JSON).
- test: `tests/heartbeat_wake_sleep_unit.sh` (13 assertions, isolated registry + stubbed systemctl/idle/db, no root/systemd) — arm-then-fire past threshold, hold before it, disarm on work / busy / blocked pane, always_on untouched, protected never slept, stopped-unit clears a stale timer, per-agent override, and fail-closed `has_work`. Full heartbeat suite green.
- **HELD for lead review:** the live fleet smoke is `scripts/wake-sleep-smoke.sh` — **dry-run by default** (touches nothing without `--run`), refuses protected agents, and runs only on a disposable non-critical test agent. Per main's Stage-2 hard rule it must be reviewed before it runs live.

## 0.14.5 — council: interactive `council init` wizard (DIVE-1861) (2026-07-24)

- **feat(council): `sudo 5dive council init` run bare (or with only some flags) in a terminal now launches an interactive wizard**, mirroring `5dive init` / `5dive company`. It prompts for seats + chair + per-seat lenses, the pass threshold (`majority | all | 2/3 | custom N or a/b`), the founder-veto principal (validated live via the same resolver init uses, so an unresolvable one is caught before any write), and whether to seal the default v0 constitution or a custom `constitution.yaml` already on disk — then shows a review and confirm before sealing. The wizard only assembles the existing `--seats/--threshold/--veto` flags and hands them to the SAME one-time seal path (genesis sealed on the root gate-proof rail + hash-chained lineage); there is no second seal code path.
- **no regression to the flag form:** passing all of `--seats/--threshold/--veto` (or adding `--yes`) still seals non-interactively with zero prompts, and a non-TTY invocation with missing essentials falls through to the same fail messages as before. `distinct from convene` — `init` seats the council once; `convene` runs a deliberation. Reuses the dependency-free `_init_*` UI helpers from `cmd_init.sh` (arrow-key/numbered picks, NO_COLOR + dumb-terminal fallbacks).
- test: `tests/council_init_wizard_unit.sh` (13 assertions — flag assembly for chair/lenses, custom fraction threshold, tg + human veto, `--force` pass-through, pre-seeded defaults, cancel-writes-nothing, missing-custom-constitution abort) plus a real PTY-driven end-to-end seal; council contract (64), constitution-init (23), roster/lineage (31), and record (5) suites green.

## 0.14.4 — heartbeat: opt-in wake-on-alert wake_mode + wake-budget guardrail (DIVE-1858 Phase 1, Stage 1) (2026-07-24)

- **feat(heartbeat): per-agent opt-in `wake_mode` (`always_on` | `cold`) + a wakes/day budget cap, via `5dive heartbeat wake-mode <name> [always_on|cold] [--cap=<n>]`.** Stage 1 of DIVE-1858 (Phase 1 of the on-demand/serverless-agents parent DIVE-1856, greenlit by olivia; staged landing plan approved by main). The always-on dispatcher is the existing `heartbeat tick` (already self-monitored via the DIVE-1434 poller-liveness canary); Stage 1 teaches it to respect an opt-in flag plus a wake-budget so a chatty trigger can't thrash a `cold` agent into repeated cold-start wakes. `wake-mode` with no args after the name is a lock-free read (mode + cap + used + cost-per-wake); a write takes root + the registry lock.
- **guardrail (olivia condition 1): wake-budget cap/day + cost-per-wake visibility, IN Phase 1.** A `cold` agent that has spent today's cap (default 24, env `HEARTBEAT_WAKE_CAP`, or per-agent `--cap`) is skipped in the tick (`budget-skipped` counter) and its wake is not fired; the day counter rolls over automatically. Cost-per-wake is surfaced as a display estimate only.
- **safety (olivia condition 3): `main` + `marketing` are pinned always-on and refuse `wake_mode=cold`** (extend the protected set via `HEARTBEAT_WAKE_PROTECTED`). No customer-facing/critical agent can go cold without explicit opt-in; `always_on` (the default for every existing agent) is wholly unaffected — every new gate is additive and defaults to current behaviour when no wake config exists.
- **ZERO billing surface (olivia condition 4):** cost-per-wake is display-only; pay-per-wake billing is firewalled to a future lodar-only SPEND gate (Phase 2). **NO live auto-sleep here (olivia condition 2 firewall):** the reactive auto-sleep smoke is Stage 2, HELD for main's pre-run lead review and to run on a disposable non-critical test agent only.
- test: `tests/heartbeat_wake_dispatch_unit.sh` (16 assertions, isolated registry + stubbed lock/chown, no root/network) — default mode, cold seeds default cap, `--cap` override, protected-agent refusal, budget under/at/over cap, new-day reset, always_on/un-capped never budgeted, inc counts + rolls over. Full heartbeat suite green.

## 0.14.3 — constitution: `schema_version` support + canonical-policy digest (DIVE-1702) (2026-07-24)

- **feat(council): constitution.yaml is now versioned — an optional top-level `schema_version: 1` is parsed, allowlisted, and surfaced.** The parser rejects unknown top-level keys (fail-closed), so `schema_version` needed explicit support. It is OPTIONAL and defaults to the current version (`CONSTITUTION_SCHEMA_VERSION = 1`) when absent, so every existing file stays valid; it must be a positive integer, and a document declaring a version NEWER than the CLI understands is rejected fail-closed (an out-of-date agent never enforces a schema it cannot fully parse). `loadConstitution`/`normalizeConstitution` now carry `schemaVersion`, and `council constitution` surfaces it.
- **feat(council): every constitution load now reports two digests — a SOURCE digest and a canonical-POLICY digest.** `sourceDigest` (= the existing `digestConstitution`, sha256 of raw bytes; the sealed-drift realm — cosmetic edits DO churn it, which drift wants) is joined by a new `policyDigest`: sha256 over the NORMALIZED policy via `canonicalPolicyJSON` (sorted keys), so comment-only, key-reorder, or whitespace edits leave it unchanged. An audit can now tell a cosmetic edit (source changed, policy unchanged) from a real policy change. `policyDigest` accepts a normalized object or raw frontmatter; the derived `hardGateRegex` is excluded (pure function of `hardGates`). Purely additive — the sealed-digest/drift path (bash `sha256sum` of raw bytes) is untouched. Covered by `tests/council_constitution_unit.mjs` (+17 = 41/0); council contract/engine/amend/gate suites green.

## 0.14.2 — agent first boot: gate the first claude launch on creds so the auth_required/exit-6 flash never surfaces (DIVE-1769) (2026-07-24)

- **fix(agent-start): `5dive-agent-start` now waits (bounded) for a new claude agent's credential to be wired before the first launch, then re-exports the auth files into the environment.** systemd reads the unit's `EnvironmentFile=`s (`anthropic.env`, then the profile `%i-auth.env` last-wins) exactly once, at activation; on a brand-new agent's first boot provisioning can write the OAuth token AFTER the unit started, so claude execed unauthenticated and the owner's first sight of the agent was an alarming *"Sign-in to Claude Code expired / auth_required / exit 6"* (self-healed only on the follow-up restart). The claude branch now polls this agent's primary auth file (the profile combined.env when a profile is bound, else `anthropic.env`) for a non-empty `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`, up to `CLAUDE_AUTH_WAIT_SECS` (default 45s), then re-exports both files in the unit's ordering (shared default first, profile override last) so a profiled agent keeps its own account; systemd will not re-read them, so a token that lands post-activation is otherwise invisible to the exec'd claude. On timeout it launches anyway (no worse than the pre-fix self-heal). Found in the lodar wizard dogfood (agent claude-cole). DIVE-1769.

## 0.14.1 — managed-settings self-heal: existing boxes reconcile the channel allowlist without a per-box install.sh rerun (DIVE-1843) (2026-07-24)

- **fix(doctor): `5dive doctor --fix` now self-heals `/etc/claude-code/managed-settings.json` in place.** DIVE-1816 taught `install.sh` to reconcile the channel allowlist (add both 5dive fork channels + `channelsEnabled:true`), but an existing box only healed when a human reran install.sh per box — `doctor` merely WARNED "rerun install.sh". So personal-account boxes provisioned before the dashboard channel shipped kept silently dropping dashboard-chat pings (agent looks alive but never replies on `/dashboard/chat`). The doctor channels check now auto-reconciles under `--fix` (bare `doctor` stays a read-only preview), so a box repairs itself with one box-local command — no install.sh rerun, no SSH. The nightly `5dive self-update` already reconciles via `install.sh --upgrade` → `refresh_managed_files`, so auto-updating boxes heal on their next run; the `doctor --fix` path covers self-hosted boxes that opt out of the nightly cron.
- **refactor:** extracted the exact idempotent merge into a reusable `reconcile_managed_settings()` helper (`src/lib/agent_setup.sh`) — ensures `channelsEnabled:true` + both 5dive fork channels, never clobbering operator or upstream/official entries, mode-preserving, jq/JSON-guarded (never bricks a hand-managed file). Signals via exit code: 0=changed, 3=already-current, 1=can't reconcile.
- **note (second gate):** confirmed dashboard-chat delivery is gated by TWO independent things — (1) the box-level managed-settings allowlist (fixed here; this is what bit claude-leaf), and (2) the per-agent `enabledPlugins` in `~/.claude/settings.json`, which `agent create` only sets to include `dashboard@5dive-plugins` when the agent was created WITH the dashboard channel. A box created without that channel is a separate, narrower case (safe auto-enable needs the agent to actually have the dashboard channel provisioned) — left as a follow-up rather than blind-enabling a channel an agent was never set up for.
- test: `tests/managed_settings_selfheal_unit.sh` (13 assertions) drives the shipped helper through the exact claude-leaf stale shape — heals `channelsEnabled` + adds `dashboard@5dive-plugins`, preserves operator/upstream entries, idempotent (exit 3 on re-run), and leaves a missing/invalid file untouched (exit 1) — plus locks the `doctor --fix` DOCTOR_REPAIR wiring.

## 0.14.0 — autonomy ledger + `5dive proof` badge with a gated public publish (OSS-38, OSS-39) (2026-07-23)

- **feat(proof): `5dive proof status` shows this company's autonomy badge — `1 − asks/shipped` over the lifetime ledger, materialized from EXISTING task data (OSS-38), no new capture path.** A shipped action is a done standard task; it counts as an "ask" only if it carried a gate a HUMAN answered — the DIVE-1117 provenance rail (`need_answered_by LIKE 'human:%'`) or a human-tap nonce (`human_nonce_hash`). A lead/agent clearance does not count. Note `need_answered_uid` alone does NOT mark a human (DIVE-756 captures that uid on every sudo'd answer as tamper-evidence), so keying the metric off it would over-count asks and understate autonomy; the ledger uses the human-provenance signal instead. `proof status` is read-only and local — no clone, no network — and `--json` carries the full `autonomy` object.
- **feat(proof): load-bearing publish guardrail (OSS-39).** Emitting the badge is a public brand/comms act, so the FIRST `proof publish` files an approval `task need` to lodar and BLOCKS — no badge goes live without a human tap. Only a human-answered approve flips the stored `publishApproved` flag and lets publishing proceed; a pending gate keeps blocking without re-filing, and a decline blocks. `proof on/off` toggle the daily publisher autonomously; `proof publish --dry-run` previews locally without the gate (it pushes nothing).
- test: `tests/proof_ledger_unit.sh` (badge math, 8 assertions) and `tests/proof_publish_gate_unit.sh` (the gate fires to lodar and blocks until a human approve, 13 assertions).

## 0.13.29 — done=merged is now MANDATORY: auto-detect merge-gate closes the DIVE-1830 opt-in slip-through (DIVE-1835) (2026-07-23)

- **feat(task): a second, MANDATORY merge-gate on `task done` that auto-detects code bound to the ident without the maker self-declaring a binding.** DIVE-1830's gate only fired when a task carried a `delivery_ref` (`task deliver --pr=`) or a `Branch:` line — an audit found 8 code-tasks closed with NEITHER, so they slipped straight through. The new gate runs ONLY when no binding was declared: it lists open PRs and blocks the close if one names the ident in its **title or head-branch** (never the PR body — a "follow-up to DIVE-N" mention would false-block; OPEN-only, so an abandoned/closed-unmerged PR never makes the task unclosable). Unlike the declared path (fail-CLOSED), this auto-detect path is **fail-OPEN by design**: it runs on every no-binding close (research/docs/heartbeat included, which simply don't match), so a `gh` outage/timeout(5s)/absence must never block the whole fleet from closing anything — the weekly branch-hygiene digest (#139, DIVE-1833) catches any unmerged slip left behind. New `task done --force-merge-gate` is the audited manual escape (written to the tamper-evident audit log with the overridden PR #). The ident is matched at **word boundaries** (case-insensitive), not as a bare substring, so DIVE-202 is never false-blocked by an open PR naming DIVE-2021/DIVE-2029, and a lowercase branch (`dive-202-fix`) still matches the uppercase ident. New `tests/task_merge_gate_autodetect_unit.sh` (11 assertions, stubbed `gh`); the sibling DIVE-1830 harness's `gh` stub now models the auto-detect `pr list --state open` call so its zero-regression case isn't false-blocked. Design approved by main (option A) — fail-open + strict word-boundary title/branch match + required override.

## 0.13.28 — merge-gate resolves gh robustly so a plain `sudo task done` works (DIVE-1834) (2026-07-23)

- **fix(task): the DIVE-1830 merge-gate now resolves gh's token and repo explicitly, fixing two false-block variants that could refuse a legitimately-merged close.** `task done` normally runs under sudo (EUID 0, no gh login) and the acting agent may itself be non-gh-authed, so running `gh` in that caller env returned `state=unknown` and the gate false-BLOCKED a merged PR (hit closing DIVE-1833). Separately, the branch-path query ran `gh pr list --head <b>` with no `--repo`, so it was CWD-dependent and errored from a non-repo dir. Both paths now (1) resolve a token via a new `_gate_gh_token` helper — env token, else the real `SUDO_USER`'s `gh auth token`, else the host's gh-authed `claude` user, else the caller's own login — and (2) the branch path passes `--repo` (the delegated-push default `5dive-ai/5dive` via `_push_repo_slug`). Direction stays fail-safe: an unresolved token yields unknown → false-BLOCK, never a false-CLOSE. New `tests/task_merge_gate_gh_resolve_unit.sh`.

## 0.13.26 — done means merged-to-main: opt-in `task deliver` + merge-gate (DIVE-1830) (2026-07-23)

- **feat(task): a new `task deliver <id> --pr=<url>` verb + an opt-in merge-gate so `task done` can't close delivered code before its PR is actually merged.** A maker records the delivering PR with `task deliver` (stored on new `delivery_ref`/`delivered_at` columns) and hands the task to its verifier by reusing the existing DIVE-477 in-review handoff — no new status. `task done` then refuses to close while the delivered work isn't merged to main: if a `delivery_ref` is set it must be a MERGED PR (`gh pr view --json state,mergedAt`); else if the task body carries the existing `Branch: <name>` delegated-push binding (DIVE-1462) it requires a merged PR for that head (`gh pr list --head <b> --state merged`). The gate fires ONLY when one of those bindings is present, so ordinary no-code closes are untouched (opt-in → zero regression). It sits after verifier-routing and the DIVE-555 pending-gate check, so only a real close reaches it; a task with no verifier records the delivery but stays in_progress for a verifier to close post-merge (done ≠ delivered). New `tests/task_deliver_merge_gate_unit.sh` (11 assertions, stubbed `gh`). Scope-2 (hygiene-flagging stale delivered PRs/branches in branch-hygiene.yml) is a follow-up.

## 0.13.25 — pi agents get their provider corner badge (Z.ai/etc) like hermes/openclaw (DIVE-1821) (2026-07-23)

- **fix(account): resolve and surface a pi profile's active provider so the dashboard can draw its corner badge.** pi is multi-provider BYO but showed no provider sub-badge in the agents list/detail (a pi agent on a Z.ai key looked provider-less, while openclaw/hermes badged correctly). Two CLI gaps: (1) `account_signin_detail`'s `pi` case fell into the `*)` catch-all, leaving `provider=null` — pi has no active-provider marker of its own (no auth.json/config), so it's now inferred by reverse-mapping the `*_API_KEY` var present in the resolved env (the profile's `combined.env`, else the shared `pi.env` connector) back to its provider id via `PI_PROVIDER_VAR` (`ZAI_API_KEY`→`zai`, etc.). Resolution is scoped to a single file so the shared connector's keys never leak a badge onto an unrelated profile; ties prefer the agent's pinned `defaultProvider` (settings.json) when the name resolves to a live agent, else a deterministic sorted first-match. (2) `account_types_authed` never surfaced `pi` at all (it's intentionally absent from `TYPE_API_VAR` as a multi-provider type), so `account list` emitted no `pi` signins entry and the badge could never light — it now lists `pi` when `combined.env` carries any `PI_PROVIDER_VAR` key. New `tests/pi_signin_badge_unit.sh` (12 assertions). Dashboard follow: `agents/[id]` detail page adds `pi` to `BADGE_CONNECTORS` (the list page is already generic).

## 0.13.24 — hermes BYO key no longer leaks on argv during auth add (DIVE-1818) (2026-07-23)

- **fix(create): pass the hermes BYO key on stdin only, never on argv.** `_apply_byo_hermes` piped the key on stdin *and* passed it a second time as `--api-key "$api_key"` on the `hermes auth add` command line. argv is world-visible via `/proc/<pid>/cmdline` and `ps`, so a co-located process could scrape the BYO secret during the brief auth-add window (low sev on a single-tenant box, but a real secret-in-argv exposure on the exact BYO-credential path). `hermes auth add`'s `--api-key` is optional — when omitted it reads the key from a secure `getpass` prompt that falls back to reading stdin when there's no tty (verified against hermes v0.19.0: the piped key lands in `~/.hermes/auth.json` with no `--api-key` argv). Dropped the `--api-key "$api_key"` value; the existing `printf '%s' "$api_key" |` pipe already feeds it. The moonshot path (env-var, no `auth add`) was already argv-safe.

## 0.13.23 — openclaw+z.ai auth works with a GLM Coding-Plan key (DIVE-1826) (2026-07-23)

- **fix(create): pin the z.ai Coding Plan endpoint for openclaw BYO — the openclaw sibling of the DIVE-1819 hermes fix, but a different endpoint.** Creating an openclaw agent with a z.ai (GLM) BYO key failed to auth even with a correct GLM Coding-Plan key. Unlike hermes/pi — which speak z.ai's **anthropic-wire** endpoint (`api.z.ai/api/anthropic`, pinned via `HERMES_PROVIDER_URL`/`CLAUDE_PROVIDER_BASEURL`) — openclaw's z.ai provider speaks z.ai's **OpenAI-compatible** `/paas/v4` surface, which has four endpoint families (`zai-global`, `zai-cn`, `zai-coding-global`, `zai-coding-cn`). openclaw's `zai-api-key` auto-detect probes the **general** endpoints before the Coding Plan ones, and `_apply_byo_openclaw` writes a bare `{provider:zai}` auth profile that never runs that probe — so a GLM Coding-Plan key (which authorizes the *coding* surface) landed on the general endpoint and 401'd. New `OPENCLAW_PROVIDER_URL` override table pins z.ai to the openai-compat coding endpoint `https://api.z.ai/api/coding/paas/v4`; `_apply_byo_openclaw` now writes it to `models.providers.zai.baseUrl` (a `mode:merge` overlay on openclaw's built-in catalog, the openclaw parallel to hermes' `model.base_url`). The two override tables are deliberately **not** shared — pinning the anthropic URL would break openclaw's openai-completions wire format. Also surfaces the same create-time GLM Coding-Plan key-type note hermes got (a standard prepaid key may 401 on the coding endpoint), so an auth failure reads as key-type, not a broken config. New `tests/openclaw_zai_baseurl_unit.sh` (9 assertions).

## 0.13.22 — hermes/openclaw are API-key only: drop stale device-code OAuth offers (DIVE-1807) (2026-07-23)

- **fix(auth): hermes/openclaw no longer offer the removed OpenAI /codex/device OAuth in new-auth surfaces.** Both are API-key only now (their "Sign in with OpenAI" consumer-OAuth was dropped as ToS-gray + inference-block prone — DIVE-1391/1390), but the CLI still listed them as device-code types. `agent auth start` (the non-TTY/dashboard path) now rejects hermes/openclaw with a message pointing at `auth set --api-key --provider=<id>`, and `5dive init` for openclaw goes straight to the BYO provider+key flow (mirroring hermes) instead of offering "Sign in with OpenAI". The TTY `auth login` handoff is deliberately left intact so grandfathered OAuth agents can still re-auth (DIVE-1391 grandfathering). Companion `scripts/test-vm.sh pair-test` change drops hermes/openclaw from its default+allowed types (they'd prompt OAuth for a path that no longer exists).

## 0.13.21 — hermes+z.ai auth works with a correct key (DIVE-1819) (2026-07-23)

- **fix(create): pin the verified z.ai anthropic endpoint for hermes BYO instead of unconditionally unsetting `model.base_url`.** Creating a hermes agent with a z.ai (GLM) BYO key failed with `Provider authentication failed` even though the key was correct. `_apply_byo_hermes` unconditionally ran `hermes config set model.base_url ""` (to clear a stale openai-codex oauth value) and relied on hermes' provider catalog to resolve z.ai — but that catalog resolves an endpoint the GLM Coding-Plan key won't auth against. New `HERMES_PROVIDER_URL` override table pins z.ai to `https://api.z.ai/api/anthropic` (the same anthropic-wire endpoint `pi` and the claude anthropic-skin already use, `CLAUDE_PROVIDER_BASEURL[zai]`); `_apply_byo_hermes` now SETS `model.base_url` to the override when one exists and keeps the unset only as the fallback for providers without a known-good URL (preserving the stale-value guard). `_apply_byo_openclaw` had no parallel unset, so it was left unchanged. Also surfaces a create-time note that z.ai's anthropic route wants a **GLM Coding-Plan** key (a standard prepaid API key may 401 there) so an auth failure reads as key-type, not a broken config. New `tests/hermes_zai_baseurl_unit.sh` (7 assertions).

## 0.13.20 — dashboard-chat pings reach personal-account agents (DIVE-1816) (2026-07-23)

- **fix(channels): allowlist `dashboard@5dive-plugins` in managed-settings, and reconcile existing boxes.** Claude Code's channel allowlist (`/etc/claude-code/managed-settings.json` → `allowedChannelPlugins`) listed `telegram@5dive-plugins` but never `dashboard@5dive-plugins`. Because any custom allowlist makes Claude ignore its default ledger, the dashboard channel was treated as unapproved and inbound dashboard-chat pings were **silently dropped before reaching the agent** (personal/self-hosted boxes: the local file IS the self-approve allowlist; team boxes are governed by the org's remote managed-settings, which override the local file — documented in the FAQ). `install.sh` now (1) ships `dashboard@5dive-plugins` in the template, and (2) **reconciles an existing file in place**: idempotently sets `channelsEnabled:true` and merges in any missing 5dive fork channels (telegram + dashboard) without clobbering operator or upstream entries, so already-provisioned boxes heal on the next install/update run (no SSH needed). Skips safely when jq is absent or the file isn't valid JSON. `5dive doctor` now also flags a missing `dashboard@5dive-plugins`. New `tests/managed_settings_reconcile_unit.sh` (10 assertions).

## 0.13.19 — standard agents can self-restart: /model + /restart fixed (DIVE-1813) (2026-07-23)

- **fix(sudoers): standard-isolation (customer) agents can now restart their own service, so `/model` and `/restart` work.** On a standard-isolation box the scoped sudoers (`render_standard_sudoers`) granted only the a2a `_deliver`/`_capture` + `_audit_append` primitives — it did NOT grant any service restart. But the telegram plugins' `/restart` and `/model` shell out to `sudo 5dive agent restart <name>` (or a raw `sudo systemd-run`), neither of which is in the scoped allowlist, so on every customer box those failed with `Failed to restart: sudo: a password is required`. Admin agents (whole-CLI grant) were unaffected. New hardened primitive **`5dive agent _self_restart`**: it takes NO arguments, derives the target unit ENTIRELY from `SUDO_USER` (so an agent can restart ONLY its own `5dive-agent@<self>.service`, never a peer), and fires the deferred `systemd-run` restart internally as root with a fixed name-only command (no caller injection) so the agent needs no raw `systemd-run`/`systemctl` grant. `render_standard_sudoers` grants exactly `NOPASSWD: /usr/local/bin/5dive agent _self_restart` — exact path, no args, no wildcard (sudo-rs safe). Upholds the standing invariant that no `sudo 5dive` subcommand execs agent-controlled input as root (DIVE-756/916/950/1413). 8 new assertions in `tests/agent_isolation_unit.sh` (44/44 green).

## 0.13.18 — antigravity auth: no false-ok before first-run onboarding finalizes (DIVE-1803) (2026-07-23)

- **fix(auth): `auth poll antigravity` no longer reports `state=ok` before the profile is usable.** After the Google OAuth code is submitted, `agy` blocks in its post-login first-run onboarding (colour theme / model / `[Next]`) inside the TUI, and the `antigravity-oauth-token` blob isn't finalized until that completes. The old poll declared `ok` on the sentinel's bare mtime bump and killed the session mid-onboarding, stranding the profile with an empty/absent token (`auth status` → `needs_login`). The poll now (1) only reaches `ok` once the token file is **non-empty and mtime-stable across two polls**, (2) drives onboarding forward by sending Enter while an onboarding screen is up (marker-gated so it never disturbs the login-method menu or the code-entry prompt), and (3) bounds the wait with a 240s finalize deadline that fails honestly instead of reporting a false ok.
- **fix(auth): `auth_creds_present` now recognizes profile-scoped bare-file credentials.** Its plain-file check compared `path == key`, but with a profile `path` is swapped to the profile-scoped path while `key` kept the default path — so every no-`:jsonkey` sentinel (codex/hermes/openclaw/antigravity/grok) mis-routed into the jq branch, and antigravity's bare-blob token returned `needs_login` even when valid. Detection is now colon-based (absence of `:jsonkey` ⇒ present-and-non-empty on the resolved path). New `tests/antigravity_auth_finalize_unit.sh` (5 assertions).

## 0.13.17 — PII denylist scanner as a CI gate (DIVE-1774) (2026-07-23)

- feat(ci): `pii-guard` GitHub Action + `scripts/pii-scan.sh` — a HARD RULE gate that scans every PR (title, body, commit messages, added diff lines) and the release notes (`CHANGELOG.md`) against a hashed denylist (`.github/pii-denylist.txt`). A denylist hit fails the check and blocks merge/release. The denylist stores only SHA-256 hashes, never plaintext, so no real identifier is committed to this public repo; exact-hash matching keeps false positives at zero. Candidate tokens = emails plus 7-15 digit runs (raw and phone-separator-stripped).
- docs(claude): new repo `CLAUDE.md` author rule — never put real user ids/emails/phones in public artifacts; use placeholders. Enforced by `pii-guard`.

## 0.13.16 — welcome DM: surface an open-your-bot nudge when the paired chat never opened the bot (DIVE-1768) (2026-07-22)

- **fix(pairing): `send_welcome_message` no longer swallows Telegram's 403 for an unreachable bot.** `curl` exits 0 on an HTTP 403, so the old `-o /dev/null … || warn` silently dropped the "bot can't initiate conversation with a user" / "chat not found" case — an owner auto-paired into `access.json` (CoS-create or operator auto-pair) who had never opened the bot got allowlisted with no welcome and no signal at all. The send now reads the JSON body: on the unreachable-bot case it names the bot via `getMe`, prints an actionable `ACTION: open Telegram, find @<bot>, press Start` nudge, and returns 3; a real send returns 0; any other API error returns 1. Both `cmd_pair` paths and the CoS-create path flag the pending state — `agent pair --json` now emits `welcomePending:true` + a `nudge` string (dashboard-readable) and the CLI warns loudly. New `tests/welcome_403_nudge_unit.sh` (10 assertions). DIVE-1768.

## 0.13.15 — cmd_pair: resolve a single channel below the DIVE-1762 guard (DIVE-1767) (2026-07-22)

- **fix(agent pair): `cmd_pair` now resolves ONE pairable channel (telegram precedence, else discord) for token env/var, the access.json path, and the auto-pair state dir, instead of exact-matching the whole `$channels` string.** DIVE-1762 (be0708d, 0.13.13) fixed the channel *guard* to accept a comma-separated list, but the code below it still assumed a single channel: `case "$channels" in telegram)…discord)` never matched `telegram,dashboard` (the default claude combo the fix targeted), so `token_var` stayed unset and pairing died with `token_var: unbound variable` then `no bot token for agent … telegram,dashboard.token`; the access/state paths likewise pointed at a bogus `channels/telegram,dashboard/` dir. Now a `pair_channel` computed with the same `",telegram,"`/`",discord,"` membership idiom drives token resolution, the access path, the state dir, the wait/INTRO copy, and the config-set hint. Welcome delivery (telegram-membership) and the JSON `channels` echo are unchanged. Covered by `tests/dive1767_regression_unit.sh` (18 assertions, verified to fail with `token_var: unbound` when reverted). The DIVE-1762 "verified pairs telegram,dashboard" claim was not true end-to-end; found via DIVE-1765 regression tests (PR #120).

## 0.13.14 — report claude BYO provider for the /dashboard/agents sub-badge (DIVE-1763) (2026-07-22)

- **fix(account): `account_signin_detail` reports the resolved provider for a BYO-claude agent** so `account list --json` emits `signins.claude.provider=<byo id>` and the `/dashboard/agents` provider sub-badge (frontend b9f05d97) renders. New `claude)` case reverse-maps the profile's stored `ANTHROPIC_BASE_URL` (combined.env) against `CLAUDE_PROVIDER_BASEURL` (deepseek/moonshot/openrouter/zai); a plain Anthropic subscription has no base url → provider null → no badge (correct). DIVE-1763, authored by dev (PR #119), folded into this release.

## 0.13.13 — fix(agent pair): accept comma-separated channels so telegram+dashboard agents pair (DIVE-1762) (2026-07-22)

- **fix(agent pair): `cmd_pair`'s channel guard now matches channel-list *membership* instead of the whole string, so an agent with `channels=telegram,dashboard` can be paired.** Regression from DIVE-856 (comma-separable channels): `cmd_pair` alone still used an exact-match `case "$channels" in telegram|discord)` while its five sibling `telegram-*` subcommands already used the `",$channels," == *",telegram,"*` membership idiom. Because new claude creates include the `dashboard` channel by default, any create where the user also picked telegram produced `channels=telegram,dashboard` and failed pairing with `pairing only applies to telegram or discord` (exit 3). Now guards with `[[ ",$channels," != *",telegram,"* && ",$channels," != *",discord,"* ]]`, matching the siblings exactly. Found by lodar stress-testing the dashboard agent-create wizard.

## 0.13.12 — constitution loader: legacy 5dive.md fallback + one-time rename (DIVE-1686) (2026-07-22)

- **fix(council): `_council_constitution_path` now falls back to a legacy `${STATE_DIR}/5dive.md` and does a one-time byte-preserving rename to the canonical `constitution.yaml`.** Belt-and-suspenders for the DIVE-1676 rename: a box that ratified its constitution BEFORE the rename holds it at `5dive.md`; a post-rename build would otherwise look only for `constitution.yaml`, miss it, and (with a digest sealed in the chain) fail-closed on drift or, unsealed, silently revert to built-in defaults. The path fn now migrates the legacy file once (`mv -n`, so the sealed-digest drift check still matches — a rename preserves bytes), and if the rename can't happen (e.g. a non-root reader on root-owned `STATE_DIR`) returns the legacy path IN PLACE so the loader never silently reverts. An explicit `FIVEDIVE_CONSTITUTION_FILE` override is honored verbatim (no migration). Every reader (`constitution show`, drift/verify, convene, `council init` seed) resolves through this one chokepoint, so all benefit. Covered by `tests/constitution_legacy_migration_e2e.sh` (legacy read+rename, byte-preservation, sealed-digest-survives-rename → no drift, no-silent-revert fallback, fresh-box no-op). Ref DIVE-1676; requested by main at gate approval.

## 0.13.11 — builder ship handoffs: nudge --type=approval/manual eng-ship gates to --type=decision (DIVE-1738) (2026-07-22)

- **feat(gate): a builder filing an engineering ship/deploy handoff as `--type=approval` or `--type=manual` now gets a stderr nudge steering to `--type=decision`.** Recurring friction: builders filed ship/deploy handoff gates (DIVE-1697/1704/1695) as `approval`/`manual`, which are HUMAN-ONLY unless routed — `decision` is lead-clearable by TYPE (tier-1, no human_nonce, no routing dependency), which is what a builder→lead ship handoff wants. When a gate hits the eng-ship classifier (`_gate_eng_ship_hit`), did NOT trip the true-human floor, and a lead sits above the filer (`_gate_route_reviewer` non-empty ⇒ a builder, not the lead re-escalating), `cmd_task_need` emits `warn: this looks like an engineering ship/deploy handoff filed as --type=<type>. Prefer --type=decision …`. The nudge is **advisory-only** — stderr, non-fatal, JSON stdout untouched — and does NOT change routing or tiering: the DIVE-1359 eng-ship downgrade (decision/approval → lead-routed tier-1) is intact, the true-human floor still wins first, and `manual` (which the downgrade excludes) is unchanged in behavior but now surfaces the nudge (pref-OFF a manual ship gate still pings the human, so the steer matters most there). Covered by `tests/gate_ship_routing_unit.sh` (+5 = 59/0: builder approval nudged + routing unchanged, builder manual nudged, lead's own gate NOT nudged, non-eng-ship approval NOT nudged, floored money eng-ship NOT nudged/stays human); sibling gate suites green (approval-routing 9, tier2-floor 9, internal-ops 23, heartbeat-shipped 7).

## 0.13.10 — objective planner: async self-heal materialize so late diffs stop getting orphaned (DIVE-1737) (2026-07-22)

- **fix(objective): a planner loop that finishes AFTER its `--wait` window now materializes instead of silently vanishing.** Root cause: `objective replan` invoked the planner via `loop spawn --wait=150` but the real planner run takes far longer (observed ~30–70 min), so `cmd_loop_spawn` timed out → `escalated` and `_objective_invoke_planner` hard-failed with `E_TIMEOUT` **before** recording a cycle, filing a gate, or materializing — the diff the planner produced minutes later was orphaned (objective originated-open stayed 0; a human backfilled the task by hand each cycle: funnel cycles 4/5, DIVE-1617/1711). Fix (design A): on a non-`done` planner loop, replan now records an **`awaiting_planner`** cycle stamped with the backing loop + task ids (new additive `objective_cycles.planner_loop_id`/`planner_task_id` columns) instead of failing; a new heartbeat sweep `_hb_objective_reconcile` pulls the late diff once the planner task closes and re-drives the **existing** `objective replan --diff` path (validate → gate/materialize), reusing the same cycle number (no double-count). The 150s block-poll + `OBJ_PLANNER_WAIT_DEFAULT` are unchanged. A late close that isn't a diff JSON (a prose ACK) or a killed/cancelled planner task is marked `planner_failed` and surfaced to the coordinator for manual `replan --diff` — never guessed-at, never silently stuck. Also fixes a latent bug where `_objective_invoke_planner`'s stamps (incl. `tokensSpent`) were lost to a command-substitution subshell. Covered by `tests/objective_reconcile_unit.sh` (7: awaiting-recording with correct stamps, reconcile-materialize at same cycle, prose→failed, in-progress→pending idempotent, cancelled→failed); objective_replan_unit 24, schema_sync 8 in sync, all objective suites green.

## 0.13.9 — `5dive constitution set --json`: browser-callable structured-field write (the dashboard EDIT contract) (DIVE-1751) (2026-07-22)

- **feat(constitution): new `echo '{…}' | sudo 5dive constitution set --json` reads a STRUCTURED-field JSON patch from STDIN, merges it into the current constitution, and seals it — the browser-callable WRITE the dashboard guardrails EDIT surface (DIVE-1750) drives.** DIVE-1743 shipped `set --file=<yaml>`, a correct and secure write path, but not a contract the dashboard can drive without authoring governance YAML in-browser (forbidden — DIVE-1700 fraction-bug class). `set --json` closes that: it reads a whitelisted patch of the SOLO-editable guardrail fields (`hard_gates` per-class regex, `ship.require_ci`, `comms.public_requires_human`) from STDIN, MERGES it into the CURRENT constitution (untouched classes/sections are preserved — merge, not replace), then re-serializes the YAML and re-validates it through the SAME `loadConstitution` normalizer as `show` (ONE parser, fail-closed) — all colocated in the CLI, so the browser never authors governance YAML. It then seals via the EXACT SAME routing as `set --file=`: seat count from the SEALED genesis decides solo direct-seal (single-principal, no convene) vs org council-amend, so the state-based solo-vs-org seal boundary is unchanged. On a solo seal it emits EXACTLY ONE envelope — the `constitution show --json` view (the sealed digest + guardrails, read back through the one parser) — which the dashboard consumes directly. **The governance keys (`council` / `quorum` / `veto` / `thresholds`) are UNREACHABLE via this path — a patch touching them is refused (fail-closed) — so a browser can never weaken the vote thresholds or founder veto; those change only through a `council amend` constitutional motion.** A real MULTI-seat council returns the machine amend-route and NEVER clobbers (the server-side backstop to the dashboard's `seatCount>1` read-only gate). Runs root over the exec tunnel (sudo, 64KB stdin). Honors DIVE-1695 (sealed digest = authority; a later hand-edit drifts + fails closed), DIVE-1700 (no browser YAML), DIVE-1731. Covered by `tests/constitution_set_json_e2e.sh` (33, against the built binary under root: solo first-seal + single-envelope guarantee, merge-preserves-untouched-classes re-seal, `council verify` green, governance-key + malformed-patch refusals leaving the lineage untouched, empty-patch no-op save, and the org amend-route no-clobber); all council suites green (contract 64, engine unit 30, show 29, set 20, init 23), bundle-drift clean. Regenerated `cmd_council.sh` via gen_cmd.

## 0.13.8 — `5dive constitution init`: seed the default guardrails WITHOUT a Council (DIVE-1701) (2026-07-22)

- **feat(constitution): new `sudo 5dive constitution init` decouples guardrail-seeding from Council init — single-agent-first-class.** A solo user who never wants the multi-agent Council can now seed AND edit the machine-enforced guardrails with zero Council. `init` writes the full default `constitution.yaml` with the GUARDRAILS a solo user edits ordered FIRST (`hard_gates` / `ship` / `comms`), then the Council governance keys (`council` / `quorum` / `veto` / thresholds) LAST, clearly demarcated and commented as OPTIONAL and DORMANT (they take effect only after `5dive council init`). It creates NO council genesis/lineage — the file is left UNSEALED so the user edits it, then `constitution edit`/`set` direct-seals it. ONE schema for both `constitution init` (unsealed seed) and `council init` (sealed genesis): `renderConstitutionV0()` now emits the guardrails-first layout for both, and it still round-trips byte-for-byte to the built-in defaults (key order is cosmetic to the parser), so fewer governance-parser bugs. Anti-clobber guard: `init` HARD-refuses to overwrite a Council-SEALED constitution (routes to `council amend` / `constitution edit`, `--force` cannot override) and refuses an existing UNSEALED file unless `--force`. v0.15 enforcement reading `hard_gates` independent of any Council is out of scope for this seed. Covered by `tests/constitution_init_e2e.sh` (23, against the built binary: guardrails-before-council ordering, no genesis/lineage created, `show` reads it valid+unsealed, `--force` re-seed, and the sealed-constitution HARD refusal); all council suites green (engine 195, show 29, set 20, amend 17), bundle-drift clean.

## 0.13.7 — `5dive constitution set` / `edit` WRITE path: solo direct-seal + org council-amend (DIVE-1743) (2026-07-22)

- **feat(constitution): new `sudo 5dive constitution set --file=<constitution.yaml>` (and `edit`) seals a proposed constitution through the SANCTIONED flow.** Phase-2 WRITE half of the CLI seam that unblocks the dashboard guardrails edit surface (DIVE-1732, EDIT half); the READ half was DIVE-1742. It validates the proposed doc via the SAME engine normalizer as `show` (one parser, gates on the payload `valid` flag — `loadConstitution` always exits 0 — and fails closed on a bad file before any write), then routes by mode: a real MULTI-seat council routes to a constitutional amendment via `council amend` (2/3 + full quorum + founder veto; sealed on pass, untouched on non-pass); a SOLO context (no genesis, or a single-principal genesis) DIRECT-seals via a single-principal `council init` — NO convene, no quorum / DIVE-1739 liveness (no seats to poll) — reusing the exact council lineage + ROOT-seal machinery so DIVE-1695 drift detection and `council verify` work identically. `--principal` names the solo authority the first time (default `human:<you>`); re-seals inherit it and pass `--force` to chain a fresh digest. `edit` opens `$EDITOR` on the current constitution (or the v0 default) then seals the edited bytes through the same routing, no-op on no change. Root-owned write (COUNCIL_DIR + constitution.yaml), so sudo-gated (inherited from init/amend). Covered by `tests/constitution_set_e2e.sh` (20, against the built binary under root: solo first-seal + re-seal, sealed-digest + `show` reflection, `council verify` green, invalid-file refusal, DIVE-1695 drift fail-closed, and the org routing decision); all council suites green (show 29, amend 17, engine 195), bundle-drift clean.

## 0.13.6 — `5dive constitution show --json` read verb: the CLI seam the dashboard consumes instead of parsing constitution.yaml in-browser (DIVE-1742) (2026-07-22)

- **feat(constitution): new top-level `5dive constitution show --json` composes ONE envelope of the enforced constitution so clients never parse `constitution.yaml` themselves.** Phase-1 READ half of the CLI seam that unblocks the dashboard guardrails + amendments surface (DIVE-1732); the WRITE/seal path is DIVE-1743. The envelope carries `hard_gates` (per-class ERE + a default-vs-custom source flag) with the shipped defaults, `ship`/`comms`, `thresholds`, `veto`, `sealedDigest` (null when unsealed — the dashboard's edit-vs-readonly switch), `liveDigest`, `genesisExists` (a council can exist with an unsealed constitution, so this is the robust edit-vs-readonly signal), `drifted` + `driftReason` (DIVE-1695 sealed-digest authority: the sealed chain is the authority, a drifted hand-edit fails closed), a `council verify` passthrough, and amendment receipts parsed from the sealed lineage. The engine `loadConstitution` is the single shared parser (honors DIVE-1731 no-in-browser-mutation + the DIVE-1700 YAML bug class). Composition only: node parses the constitution + lineage, bash supplies the root-sealed digests + chain-verify; read-only, no root. New `cmd_constitution.sh` + a `constitution-show` `cli.mjs` verb + `main.sh` case. Covered by `tests/constitution_show_e2e.sh` (29, against the built binary: defaults/custom/sealed/drift); all council suites green, bundle-drift clean.

## 0.13.5 — Full-quorum convene reliability: seat-liveness pre-check + mid-window retry-nudge (DIVE-1739) (2026-07-22)

- **fix(council): a full-quorum (constitutional) convene now liveness-checks its roster BEFORE dispatch and refuses to launch a doomed vote.** A constitutional motion needs every seat to cast (6/6); a deadline-stamped ballot to an asleep/deaf agent seat auto-abstains, and since abstains do not count toward an `all`-seats quorum, a SINGLE dozing seat made 6/6 structurally unreachable (the DIVE-1696 blocker). `cmdConvene` now derives whether the motion class requires full quorum (`quorum: all` / `requireQuorum`) and, if so, runs `preflightLiveness(seats)`: it reads seat health from `agent list --json`, exempts human seats (they vote by Telegram tap, not by being an awake agent), and if any agent seat reads asleep/deaf/health-unknown it NUDGES that seat to wake and REFUSES to dispatch — emitting a `liveness-escalated` verdict (recommendation `escalate`, no ballots minted) with a brief naming the unreachable seats, rather than dispatching a convene that would inquorate-escalate anyway. Health-read failure fails CLOSED (refuse, never gamble). An absent seat DELAYS a motion, never silently passes or blocks it — legitimacy (every seat actually weighed in) is preserved, never a proxy, never abstain-as-present.
- **fix(council): full-quorum ballots get a longer default deadline (15m → 1h) plus one best-effort mid-window retry-nudge.** With no explicit `--deadline`/`--timeout`, a full-quorum convene now defaults its ballot window to 1h (a slow-but-alive seat needs room to rouse and cast before the deadline abstains it out of an all-seats quorum); explicit operator flags still win. Halfway through the window an un-voted seat gets a single pane nudge reminding it to close its ballot with a `COUNCIL-VOTE` line. The nudge is injectable and never load-bearing — a nudge that cannot land just means the seat is not roused early; the deadline/abstain path is unchanged. Non-full-quorum ballots are untouched.
- Covered by `tests/council_liveness_unit.mjs` (18) + `tests/council_liveness_e2e.sh` (6, against a freshly built binary); all council suites green, bundle-drift clean. Health source + nudge are dependency-injected so the whole gate is unit-testable offline with no real `agent list`/`agent send`. Regenerated `cmd_council.sh` via gen_cmd. (Part 4 v0 constitution seal deferred to DIVE-1740.)

## 0.13.4 — The human-gate floor reads the SEALED constitution, fails closed on drift (DIVE-1695) (2026-07-22)

- **fix(gate): `_gate_tier2_floor_hit` now trusts the on-disk `constitution.yaml` hard_gates ONLY when it matches the digest sealed in the council lineage.** v0.14 enforcement, bounded slice (constitution audit 2026-07-22, olivia-approved scope A). Before this, the tier-2 human-gate floor loaded `hard_gates` from any present `constitution.yaml` without checking the sealed digest — so an unsanctioned edit that DELETED a hard class (e.g. dropping `spend|billing` to let an agent's own money gate auto-clear) was enforced verbatim, even though `council verify`/`convene` would reject the same file as drift. The gate path now consults the sealed chain (the authority; the file is forgeable, the chain is not): a drifted or tampered file is never trusted and the gate fails closed to the shipped tier-2 defaults with a loud warning, the exact verdict `council verify` reaches. No sealed digest yet (pre-constitution org) leaves CNCL-14 behavior unchanged. Adds a node-free `_council_constitution_drifted` (mirrors `engine.mjs` `constitutionDriftCheck`, same sha256 realm) so the hot path stays in-process. Ship/comms-as-execution-rules and structured capability gating are deferred to v0.15 per scope. Covered by 8 new assertions in `tests/constitution_gate_floor_unit.sh` (19/19): in-sync trusts the file, a post-seal class-deletion still floors billing via the shipped default and its on-disk classes are ignored, missing-file-under-seal is drift, empty-seal is not. Regenerated `cmd_council.sh` via gen_cmd.

## 0.13.3 — `task set-branch` + `task add --branch` for delegated-push binding (DIVE-1697) (2026-07-22)

- **feat(task): `5dive task set-branch <id> <branch>` and `5dive task add --branch=<name>`** let a maker task declare its DIVE-1462 delegated-push branch binding without an admin sqlite edit. Delegated push (`5dive push`, DIVE-1376/1462) refuses unless the task body carries a `Branch: <name>` line, but a body was only writable at `task add` — so any maker task filed without one hit a wall (scoped-sudo makers can't touch `tasks.db`; it took an admin DB edit, as on DIVE-1683). `set-branch` upserts the line (idempotent — re-binding replaces, never duplicates); `--branch` seeds it at creation. Both write exactly what `cmd_push.sh`'s own `_push_branch_from_body` parser reads, and reject whitespace/junk names (push parses the branch as one `\S+` token). Covered by `tests/task_set_branch_unit.sh` (8 assertions: write↔read against the real push parser, idempotency, body preservation, invalid-name + missing-arg rejections); `task_core_unit` regression green.

## 0.13.2 — Constitution thresholds accept exact fractions (DIVE-1700) (2026-07-22)

- **fix(council): the enforced constitution parser now accepts EXACT `a/b` fractions in the object threshold form (`rule: fraction`, `value: 2/3`), not just floats.** `normalizeConstitution` previously ran `Number(value.value)` on the object form, so `value: '2/3'` threw `invalid threshold fraction: 2/3` and authors were forced to a hand-typed decimal. A truncated decimal is a real governance bug: `ceil(0.667 * 6) = 5` where true 2/3 gives 4, so a 6-seat council's demote/expel/constitutional class would silently need 5/6 instead of the intended 4/6. The scalar form (`demote: 2/3`) already parsed fractions via `thresholdSpec`; that logic is now factored into a shared `fractionValue` helper and applied to the object `value` branch too, so both spellings yield exact 2/3. Range guardrails are unchanged (`2/0`, `3/2` (>1), `abc` still rejected fail-closed). Regenerated `cmd_council.sh` via gen_cmd; `council_constitution_unit` covers the fix (exact 2/3 → 4/6, naive 0.667 → 5/6, scalar parity, garbage rejection). Flagged by the 2026-07-22 constitution audit.

## 0.13.1 — Press-continue-when-headroom for stale usage-limit dialogs (DIVE-1677) (2026-07-22)

- **Prefer resuming in place over a hard restart (DIVE-1677, builds on DIVE-1666).** When the heartbeat finds a session frozen on the Claude Code usage-limit dialog AND a healthy peer on the same pooled account proves headroom (no real limit to reset), it now presses continue and resumes the SAME session — dismiss the "Stop and wait" menu with `1`, then type `continue`, mirroring the telegram resume-after-reset keystrokes — instead of a `systemctl restart`. Context and conversation are preserved. Only after `HEARTBEAT_USAGE_PRESS_MAX` (default 2) consecutive press-continue attempts fail to unstick it (re-checked each tick) does it fall back to the v1 hard restart. The no-headroom path is unchanged: restart-once-to-test-the-5h-window, then surface a capacity/billing check to the fleet coordinator. Unit-covered in `heartbeat_usage_heal_unit.sh` (27/27).

## 0.13.0 - Autonomy you can audit (2026-07-22)

The institutional layer lands: when an agent (or a whole fleet) runs your company, you can now trace what it did, see what was not independently checked, and watch governance mature, without reading a transcript. This epoch rolls up 0.11.21 to 0.13.0.

- **Headline: `5dive trace <ID>` (INST-1).** A read-only causal timeline from goal to ship for any task, gate, or ship: who decided what, which verifier graded it, where a human tapped. The audit trail that makes hands-off operation legible instead of a black box.
- **The quiet honesty signal (INST-2).** Non-trivial tasks are verifier-graded by default; when no independent grader exists (solo org, or the only candidate is the maker), the posture used to silently no-op and the "verifier-graded" claim went quietly false. It now records that and surfaces a whisper-quiet `unverified` tag (softened per DIVE-1673 so single-agent users, a first-class default, are informed, never nagged). Honest about the gap, without shaming solo use.
- **Council governance maturation.** The roster now derives from the sealed lineage log so it cannot diverge from the record (DIVE-1664); scheduled convenes ship as a product (`council schedule`, CNCL-23); veto-offer notifications carry the full motion plus tally (DIVE-1644); round-1 votes survive a silent rebuttal (CNCL-25); and the constitution is pure-data `constitution.yaml`, parsed whole-file (DIVE-1676).
- **Fleet self-heal.** Heartbeat now classifies a session frozen on the usage-limit dialog and self-heals it (restart when a healthy peer proves account headroom, else surface loudly) instead of deferring forever (DIVE-1666).
- **Token efficiency (footnote, DIVE-1612).** Leaner `--json` drops null keys to cut fleet burn (DIVE-1610); every new agent gets terse-by-default operational comms (DIVE-1613).
- **Also:** `agent rm` cascades to the org chart and clears the failed unit (DIVE-1609); the eng-ship gate matcher catches inflected verb forms (DIVE-1605); decision-gate options render in full in heartbeat reminders (DIVE-1602); sha/bundle-drift hardening in the build.

## 0.12.17 — Rename the company constitution 5dive.md → constitution.yaml (pure YAML) (DIVE-1676) (2026-07-22)

- refactor(council): the CNCL-14/15 constitution file was `5dive.md` (Markdown + a `---` YAML-frontmatter block), but the product-name filename was misleading (it is literally `5dive.md` for every org) and the CLI only ever parsed the frontmatter as YAML. Switched to `${STATE_DIR}/constitution.yaml`, parsed as a pure-YAML document: the loader (`_council_constitution_path` + `FIVEDIVE_CONSTITUTION_FILE` default) reads `constitution.yaml`, and `parseConstitutionFrontmatter` no longer requires/strips the `---` fence — it parses the whole file (human rationale now lives in `#` comments, still digest-covered, never parsed as policy). `renderConstitutionV0` emits pure YAML with a `#`-comment header (no fences, no Markdown body). Done now, before any genesis is sealed, so nothing on disk depends on the old name. Every CNCL-14/15 invariant preserved: byte-identical default parity on render→parse→normalize (verified against the pre-change baseline), malformed→atomic fallback to shipped defaults, live tally/quorum/veto/hard-gate wiring, and fail-closed drift/verify. Updated docs/constitution.md, the council test fixtures (amend/veto/constitution/gate-floor/engine units) to pure YAML, and generated `cmd_council.sh` via gen_cmd. Full council suite green.

## 0.12.16 — Soften the INST-2 'unverified' label so it whispers, not nags solo users (DIVE-1673) (2026-07-22)

- fix(cli): the INST-2 no-independent-verifier flag shipped too LOUD for single-agent users — a `⚠ Unverified: no independent verifier available (solo org — maker would grade itself; the verifier-by-default posture no-opped)` on every non-trivial `task add` and in `task show`. Single-agent is a first-class default; the flag must not shame solo use. `task add` output now emits a quiet lowercase ` · unverified` tag (no glyph, no parenthetical lecture), and `task show` keeps the honest explanation but de-glyphed/lowercased (`unverified: no independent verifier available (solo org, no distinct grader)`). The honesty is preserved (still flags no-independent-verifier, still only while the mark stands and no verifier is assigned) — it just whispers. `task ls --json` was already a bare `verify_unavailable` flag (unchanged). task_core_unit 35/0, schema_sync 8/0, bash -n clean. Dashboard amber→neutral pill (app task-row.tsx) tracked as the remaining app-side half.

## 0.12.15 — Heartbeat self-heals a session frozen on the Claude Code usage-limit dialog (DIVE-1666) (2026-07-22)

- fix(cli): the heartbeat treated an open usage/spend-limit dialog like any other in-progress dialog and DEFERRED it every tick (the "defer-not-reclaim" rule that correctly protects a real permission/plan dialog). A usage-limit dialog can never self-clear, so the session stayed frozen permanently even after the account's 5h window rolled back to headroom — the root cause of the 2026-07-21 ~4h fleet stall (0 in_progress, 0 loops, stranded todos). The tick now CLASSIFIES the open dialog: `_hb_pane_is_usage_limit` matches the usage/spend-limit signature (header + "limit to reset" / "Upgrade your plan" action line, requiring both so a lone action phrase can't false-positive), and a match is treated as a reclaimable frozen session — `systemctl restart` clears the stale dialog (agents are fresh:true, no context lost) once a healthy peer on the same account proves headroom. Real permission/plan dialogs keep the defer-not-reclaim behavior. Heals are throttled and counted; if a session stays frozen post-restart with no healthy peer on the account, that's surfaced LOUDLY to main as a genuine capacity/billing call for lodar rather than a silent defer. Connects to DIVE-1416 (fleet-stall self-heal) and DIVE-1486 (idle-stranded defer). heartbeat_usage_heal 16/0, heartbeat_active_defer 17/0, bash -n clean.

## 0.12.14 — Surface "Unverified: no independent verifier available" on task output + dashboard (INST-2) (2026-07-22)

- feat(cli): when a non-trivial standard task would be verifier-graded by default (DIVE-969/989) but no distinct grader exists (solo org, or the only candidate IS the maker), the posture silently no-opped and the "verifier-graded by default" claim went quietly false. `task add` now records a new nullable `tasks.verify_unavailable` flag in that exact else-branch, and `task show` + `task ls --json` + the add output surface `⚠ Unverified: no independent verifier available` while the mark stands AND `verifier IS NULL AND status NOT IN ('done','cancelled')` — a later-assigned grader clears it implicitly. Distinct from `--no-verify` (deliberate opt-out) and trivial chores. Additive + idempotent migration: new NULL-backfilled column added to the CREATE TABLE and the `_tasks_db_migrate` additive-column loop (ALTERs only when absent). Same integrity-invariant spirit as the council founder-excluded badge. task_core_unit 35/0, schema_sync 8/0.

## 0.12.13 — Trim decorative comments from the council JS to lift the bash-native repo-language stat (DIVE-1661) (2026-07-22)

- chore(council): condensed redundant/decorative comments in `src/council/engine.mjs` and `src/council/cli.mjs` (and their embedded copies in `src/cmd_council.sh`) — banner dividers, restated-what-the-next-line-does prose, and verbose repetition folded into tighter single-pass notes, including the DIVE-1664 roster/lineage rationale comment. Comment-only: every load-bearing WHY (rig-quorum, replay-protection, sign-at-source, the `carryForwardVotes` rationale, fail-closed notes, the roster-vs-lineage divergence fix) is preserved in substance. No code lines changed (verified: stripping `//` comments from old vs. new content, at the current `main` base including INST-1/DIVE-1664/DIVE-1644, diffs to zero across all three files). GitHub's Linguist counts comment lines toward JS, so fewer JS comment lines shifts the repo's language breakdown further toward bash, matching the "bash-native / single-binary" claim (INST-3).

## 0.12.12 — Council `roster` derives from the sealed lineage, can't diverge from `log` (DIVE-1664) (2026-07-21)

- fix(council): `5dive council roster` read the current seats from the EDITABLE `council` registry bench (`reg.council.genesis`), while `council log`/`lineage`/`promote`/`demote` all trust the ROOT-SEALED lineage. The two were independent sources and could diverge: on the live box `roster` died `the Council has no genesis roster — seed it first` (the bench had lost its genesis marker) while `log` correctly showed the sealed lineage — genesis seats `olivia,main,codex,marketing,creative` plus the approved promotion of `dev`. Roster now DERIVES from the sealed lineage: `_council_roster` reads the seats/threshold/seededAt off the latest lineage record that carries a roster (genesis or a motion; veto entries carry none and are skipped) — the SAME source of truth `promote`/`demote` mutate — and passes them to `cli.mjs roster` via `--seats-json/--threshold-json/--seeded-at`. The registry bench remains only a fallback for an uninitialized/ad-hoc council with no lineage. So the roster VIEW and the lineage can no longer disagree about membership (seats, threshold, chair are all read from the sealed record). This unblocks sourcing any PUBLIC surface (the `/council` page, DIVE-1663) from council membership. Covered by `council_roster_lineage_e2e.sh` (roster tracks the lineage across genesis → promote → demote); no change to the tamper-evident seal, chain, or `verify`.

## 0.12.11 — `5dive trace <ID>`: causal timeline goal → ship, read-only (INST-1) (2026-07-21)

- feat(cli): `5dive trace <id|DIVE-N> [--json] [--no-audit]` reconstructs the causal story of one unit of work from data that ALREADY exists — no new tables, lock, schema, audit line, or external SaaS (same read-only posture as `usage`/`digest`/`memory`). It reads the transition columns every task row carries (created/started/handoff/review/gate-answered/ship-detected/done), the origin the work descends from (project + standing goal, parent chain, originating objective/cycle, the loop it ran inside), the human-gate provenance (`need_answered_by LIKE 'human:%'` = a verified-human touchpoint per DIVE-394), and best-effort tamper-evident audit-log lines that reference the ident. It ends on a verdict that reads the zero-human proof off the gate provenance: `zero-human — goal to done with 0 human touchpoints`, or `human-in-the-loop — N human gate(s) required`, or an in-progress/blocked-on-pending-gate line. This IS the zero-human proof story compiled into one command. Verified on the live board across in-progress (INST-1), done/zero-human (DIVE-1659), and human-gated (DIVE-1612) tasks; bad id → rc=4 + `{ok:false,error}` envelope; `--json` envelope valid; `--no-audit` suppresses the audit refs. Known v2 nit: the audit-ref match is a substring grep on the ident.

## 0.12.10 — Council veto-offer notification carries the motion + tally (no blind veto) (DIVE-1644) (2026-07-21)

- fix(council): the founder veto-offer notification named only the sealed receipt digest + hold deadline — never WHAT carried. lodar received `Council veto offer — a pass sealed (SkvOrhDULOgE…). Execution holds until <ts>. Tap VETO…` and was asked to veto a sealed pass BLIND (the pass was "promote dev to a council seat", but the message never said so). The offer now leads with the decision/motion text (`.question`), the vote tally (`carried A/T approve (R reject, E escalate)`, T = seats voting), and any dissent, then the receipt handle + deadline — so the human can make an informed veto call from the notification alone. Sourced from the sealed verdict at the convene site and threaded through BOTH delivery legs: the structured button rail (`_tg_veto_offer`, DIVE-1546 — the raw nonce still travels ONLY in the tap button's callback_data, never in the enriched text) and the `_tg_send` chat fallback, via a shared `_council_veto_offer_header` helper. A base offer with no sourced motion degrades gracefully to the prior receipt line (no regression). `council_veto_e2e.sh` gains assertions that the structured offer carries the motion text + tally.

## 0.12.9 — `council schedule` run artifacts move per-user so a non-root cron can fire (CNCL-23) (2026-07-21)

- fix(council): the `council schedule run` runner wrote its per-run envelope + log + err under `${STATE_DIR}/council/schedule-runs` — but that dir is root-owned (`sudo council init` seeds it), and the runner fires from a NON-root cron (e.g. `agent-main`), which cannot write there. So a migrated scheduled convene would have failed to record its run. Run artifacts now default to `${FIVEDIVE_SCHED_RUNS:-$HOME/.5dive/council-schedule-runs}` (per-user, writable — matching the `${CREW_HOME:-$HOME/.5dive/...}` convention in `cmd_crew.sh`), decoupled from the config dir. The schedule CONFIG stays root-owned (`schedules.json`, sudo-gated — still closes the rig-quorum vector); only operational run output is per-user. `council_schedule_e2e.sh` gains a decoupling proof: run artifacts land in the per-user path, none under the config dir, and the runner still fires with a NON-writable config dir (the exact prod repro). Prereq for the Finding-3 fix (migrating the standup/strategy ops convenes onto `council schedule`).

## 0.12.8 — Council rebuttal round carries round-1 votes forward (CNCL-25 / red-team Finding 4) (2026-07-21)

- fix(council): in adversarial mode the final tally was taken wholesale from the rebuttal (round 2), so a seat that cast a substantive vote in the blind round 1 but did NOT re-cast in round 2 (timeout / no reply → abstain) LOST its vote. Partial participation therefore collapsed the tally to `cast=0` even when seats genuinely engaged — the 2026-07-20 strategy convene recorded INQUORATE with a live approve/reject split ERASED because all six seats timed out the tight round-2 window (a seat had to vote twice inside two consecutive windows for its vote to survive). `runCouncil` now MERGES round 2 over round 1 (`carryForwardVotes`): a substantive round-2 vote wins (a genuine post-debate revision), but rebuttal SILENCE carries the seat's substantive round-1 vote forward ("position unchanged"), marked in the rationale so the sealed receipt shows exactly what was carried. `round1Votes` + `rebuttalVotes` stay recorded raw alongside the merged `votes`, so the full two-round record remains auditable. A convene where every seat re-casts is byte-identical to before. This directly improves quorum reliability under the account-throttle regime where seats can't all wake to re-vote. Unit + integration coverage added to `council_dispatch_unit.mjs` (pure-merge cases + an all-silent-rebuttal repro).

## 0.12.7 — Scheduled convenes as a product: `council schedule` (CNCL-23) (2026-07-21)

- feat(council): `5dive council schedule add|ls|show|rm|run` productizes the standup/strategy v0 ops scripts (CNCL-21/22) into an OSS-able surface. `add` binds a NAMED convene template (question + bench + mode + class + action cap + ballot deadline + optional `--context-cmd`) to a cron expression and installs an idempotent, marker-tagged crontab line (rides the existing cron rail — NO daemon; `--no-cron` just saves config + prints the line). The question template embeds `{{date}}`/`{{context}}`; the context command's bounded stdout fills `{{context}}` at each fire. `run <name>` is the deterministic runner cron invokes: it gathers context, convenes on the DEFAULT ballot rail (no pane-scrape, per CNCL-18 — convene seals its own receipt into the lineage), then files up to `--max-actions` `ACTION:` items from seat rationales as `--from=council` board tasks citing the sealedDigest. An inquorate/failed run is a CNCL-18 signal, never fatal. Config lives in `schedules.json`; `schedule add|rm` write the root-owned council dir (sudo). cli.mjs owns the CRUD + template render (pure, unit-tested via `council_cli_contract.mjs`); bash owns the crontab wiring + runner, gated end-to-end on the BUILT binary by the new `council_schedule_e2e.sh` (routing, `--no-cron` line emit, ACTION parsing + maxActions cap, inquorate→files-nothing, `--dry`).

## 0.12.6 — Terse-by-default operational comms for every new claude agent (DIVE-1613) (2026-07-21)

- feat(agent-create): a persona/pack "be concise" line reads as craft voice and does NOT enforce terse *operational* chat — don (VP Marketing) had "short sentences" in his craft voice yet was verbose reporting in chat, and lodar had to re-instruct him. New `operational-comms-CLAUDE.md` fragment ships a separate, universal rule (lead with the answer, a few lines, no preamble, explicitly "NOT your craft voice") appended to EVERY claude agent's `$HOME/.claude/CLAUDE.md` at create — mirroring the `model-tiering-CLAUDE.md` universal-append in `preseed_claude_agent`. Wired in `install.sh` + `docker/Dockerfile` staging. Character packs inherit it at provision time, so pack `CLAUDE.md` files stay craft-voice only (no per-pack edits, no drift).

## 0.12.5 — Lean `--json`: drop null keys from `dbfmt` output to cut fleet token burn (DIVE-1610) (2026-07-21)

- perf(cli): every task/objective/goal/loop/council `--json` path routes through one helper, `dbfmt -json`, which emitted all ~58 columns per row including the ~70% that are null on a typical task (41/58 on `task show --json`). That bloat is injected into agent context on every heartbeat/objective/task tick, fleet-wide. `dbfmt` now strips null-valued keys on the `-json` path only (`-box`/`-line` untouched). Omitting a null key is a no-op for jq/JS consumers (a missing key reads back as null), so keys stay stable — lean, not a rename. Measured on the live board: `task show --json` 851→644 tok (58→17 keys); `task ls --json` (the top emitter) 10,541→8,306 tok, −2,235 per call. jq is already a hard CLI dependency.

## 0.12.4 — `agent rm` cascades to the org chart + clears the failed unit (DIVE-1609) (2026-07-21)

- fix(agent): `5dive agent rm <name>` now fully removes an agent in one command. The `agents_org` DELETE previously lived ONLY in `5dive org rm`, so every `agent rm` orphaned the removed agent's org-chart row (it kept showing under its manager) and left the templated `5dive-agent@<name>.service` stuck in `failed` after `disable --now` (repro 2026-07-21: `agent rm agy` left agy in the org chart + a failed unit). `cmd_rm` now also runs `DELETE FROM agents_org WHERE name=<n>` (idempotent; `ON DELETE SET NULL` reparents any direct reports) and `systemctl reset-failed` on the unit. Regression added in `agent_rm_org_cascade_unit.sh`.

## 0.12.3 — Eng-ship gate matcher catches inflected verb forms (landing/pushing/shipping) (DIVE-1605) (2026-07-21)

- fix(task): a builder's ship-approval gate leaked to the paired human (DIVE-1602 repro: "Approve landing the verified fix and pushing to origin" filed by dev landed on lodar's phone). The eng-ship classifier (DIVE-1359) only matched imperative forms ("land the", "ship it", "push to origin"), so the gerunds "landing"/"pushing to origin" missed it, no downgrade fired, and the gate stayed tier-2 hard-human instead of routing lead-clearable to the org lead. `_GATE_ENG_SHIP_RX` now also matches `merg(e|es|ed|ing)`, `ship(ping|ped)`, `land(ing|ed)`/`land this`, and `push(es|ed|ing)? to <target>`, all word-anchored so "leadership"/"relationship"/"landscape"/"ship A or B?" do not false-positive. Regression added to `gate_ship_routing_unit.sh` (DIVE-38).

## 0.12.2 — Gate reminders render decision options in full, never mid-truncate (DIVE-1602) (2026-07-21)

- fix(heartbeat): a decision gate embeds its choices ("A = …", "B = …") in the ask body, but the stale-gate reminder (90 char), org escalation (90 char), and re-nag batch (240 char) all hard-truncated the ask, so a longer ask dropped a whole option mid-word and rendered a gate that hid one of its own choices (repro: MOB-2, "B = enroll now…" chopped off). Each of the four reminder SQL sites now renders the ask in full when `need_options` is set (option-less gates keep their courtesy cap); the Telegram send is still bounded by clampList. Pairs with the plugin-side /inbox + /task deep-link fix in 5dive-plugins.

## 0.12.1 — Standup convene: --timeout honored on ballot path + clean seal cleanup (CNCL-29) (2026-07-21)

- fix(council): the DEFAULT ballot vote path (`dispatchBallotVote`) now derives its deadline from `--ballot-deadline`, then `--deadline`, then `--timeout` (via `firstFlagValue`), so the operator-facing `--timeout` actually bounds a convene and seals a clean verdict on expiry. Previously `--timeout` was consumed ONLY on the ask-rail path; the ballot path ignored it and ran to a hidden 900s default (standup's `--timeout=300` was dead, convene ran ~15m then sealed). The ask-rail path is unchanged.
- fix(council): on a deadline miss the shared `collect` loop now auto-cancels the still-open ballot task it minted (spent == an abstain) so orphan `todo` ballots stop lingering past their deadline and re-triggering fleet-stall alerts every standup (e.g. DIVE-1579). Best-effort + race-safe: a tap at the wire or an already-closed task leaves the abstain verdict untouched.
- fix(council): the CNCL-19 precedent pool now stages its temp file via `mktemp` in `${TMPDIR:-/tmp}` instead of the root-owned `${COUNCIL_DIR}`, restoring case-law parity for non-root/cron convenes that previously hit EPERM and silently ran with no precedents. Fixed in both `src/council/cmd_council.template.sh` and the regenerated `src/cmd_council.sh`.

## 0.12.0 — First-contact control-plane welcome + terminal teaser (DIVE-1571) (2026-07-20)

- feat(welcome): the first-contact DM an agent sends the moment it pairs now LEADS with the approved (lodar, 2026-07-20) control-plane pitch for **admin-isolation** agents: "hey, i'm {name}, your agent, and i'm not alone. through 5dive i can spin up a whole team, stand up a company, run a council, or turn a goal into a plan. tell me what you're building, or say 'show me what you can do'." Enriches `send_welcome_message` (`cmd_agent_pairing.sh`), the existing one-shot on-pair delivery point, so it fires exactly ONCE.
- gate: the pitch is emitted ONLY when the agent's `AGENT_ISOLATION` (read from `${ENV_DIR}/<name>.env`) is `admin` — only admin agents can actually run `company`/`agent create`/`council`/`goal`. A standard/sandboxed agent keeps the plain per-type welcome so it never claims powers it lacks. The fallback is FAIL-SAFE: an unreadable/missing isolation defaults to `standard` (plain welcome), never admin, so a mis-seeded/edge agent can never over-claim to the user. Type-neutral (all admin types get it).
- feat(init): `5dive init` Step 8 gains a curated control-plane teaser (`task add` / `company` / `council convene` / `market` / `--help`) as the OSS self-hoster's terminal-side secondary, mirroring the DM. (Demoted DIVE-1561 content.)
- note: no skill change — the `5dive-cli` skill already primes agents to ACT on chat requests; the welcome just OFFERS what the skill already enables. Public copy is em-dash-free per the house rule.

## 0.11.36 — Re-embed the council engine into cmd_council.sh (fix red CI) (DIVE-1569) (2026-07-20)

- fix(council): regenerate `src/cmd_council.sh` so its embedded `COUNCIL_ENGINE_MJS` heredoc byte-matches the canonical `src/council/engine.mjs`. DIVE-1563 (c19920fa) added the human-as-seat schema (`seatIsHuman`/`resolveSeatChat`/`humanSeatFields`) to `engine.mjs` but never re-ran `node src/council/gen_cmd.mjs`, so the committed bundle carried a stale engine. This is the sole, deterministic cause of the red `unit-tests` job — `council_cli_contract.mjs`'s "engine embed matches canonical" + "gen_cmd reproducible" checks failed on every run (bundle-drift.yml stayed green because the committed `5dive` was self-consistent with the stale `cmd_council.sh`).
- note: NOT env-sensitivity/flakiness — the earlier triage (DIVE-1569 body) mis-attributed the redness to claude-group/sudo-dependent harnesses; the CI log shows only `council_cli_contract.mjs` failing, deterministically. Two lower-priority observations recorded on the task: `pi_channel_wiring_unit.sh`'s "reject dir w/o server.ts" leaks an on-box `pi_plugin_dir` fallback path (fails on-box only, PASSES on the bare runner), and `task_cascade_unblock_unit.sh` has a rare ~1/16 flake (not reproduced in ~14 runs, passed in the failing CI run) — neither reds CI.

## 0.11.35 — Expose the resolved org coordinator as a read-only verb (DIVE-1568) (2026-07-20)

- feat(task): new `5dive task coordinator [--json]` prints the resolved org coordinator — a thin read-only wrapper over the existing `_task_resolve_coordinator` (DIVE-333): the sole `role='coordinator'`, else the lone org root, else empty (ambiguous multi-root / no org). JSON form emits `{ok:true,data:{coordinator:"<name>"}}` (empty string when unresolved).
- why: the DIVE-1503/1558 pinned needs-you banner reconciles in EVERY paired agent's DM, so the founder got the same open-gate reminder pinned across N DMs. The telegram plugin now gates its banner reconcile on this verb so exactly ONE agent (the coordinator) fronts the pin; empty/ambiguous resolves to "nobody pins" (fail-quiet). Generalizes to customer boxes automatically.

## 0.11.34 — Default a2a return-channel convention for codex agents (DIVE-1535) (2026-07-20)

- feat(agent-create): every new **codex** agent is now seeded with the a2a return-channel convention in its standing instructions (`~/.codex/AGENTS.md`) at create time. A headless codex worker (`channels=none`, e.g. andy) prints its deliverable only to its own tmux pane, `agent send` is one-way, and `agent ask` can't reliably capture a codex TUI — so the worker must PUSH its result back with `5dive agent send <from> "<result+path>"` when done. DIVE-1410 proved this end-to-end but only ever hand-wrote it into andy's file, so every other codex worker booted with no return channel. Follow-up to the reliability half in DIVE-1528 (#73).
- note: **non-destructive** — an existing (curated) `~/.codex/AGENTS.md` is never overwritten, so a hand-tuned file survives. The content is generated by a pure `_codex_return_channel_doc` (name-interpolated) split from the filesystem/ownership plumbing so it's unit-testable.
- test: `codex_return_channel_unit.sh` (10 checks) covers name interpolation, the convention body, fresh-seed creation, and the non-destructive guard.

## 0.11.32 — Objective/goal planner: tolerate `id` where the schema wants `local_id` (DIVE-1551) (2026-07-20)

- fix(objective): a `create`-bearing replan cycle no longer crashes with `every task needs a non-empty local_id`. `loop spawn --schema` is prompt guidance, not a hard-enforced structured-output contract, so a live planner routinely emits the create key as `id` instead of the schema's `local_id`. New `_objective_normalize_diff` coerces `create[].id → local_id` (only when `local_id` is absent/blank) before validate/apply, on both the fresh-plan path and the `--from-gate` recovery path (so pre-fix gates that stored `id` still apply). A diff already carrying `local_id`, or invalid JSON, is returned byte-untouched so validation still emits its own precise error.
- fix(goal): the same `id → local_id` coercion is applied to `goal add` task plans in `_goal_finish_with_plan` (extending the existing DIVE-1349 field-alias normalization), so `goal add` has symmetric tolerance.
- fix(prompt): both the objective-replan and goal-decomposition planner contracts now name the field explicitly — a plan-local id "in a field named exactly `local_id` … NOT `id`" — to reduce the drift at the source.
- test: `objective_replan_unit.sh` and `goal_add_unit.sh` each add a regression asserting a `create`/task keyed `id` is coerced and materializes instead of failing validation.

## 0.11.31 — Delegated push-for-review gate: lead-clearable tier-1, and the push guard accepts the lead clear (DIVE-1555) (2026-07-20)

- fix(task): a delegated push-for-review (`5dive push` / DIVE-1376) now files as a lead-routed **tier-1** gate the org lead can clear, instead of a tier-2 human-only approval that lands in the paired human's DM. The eng-ship classifier (`_GATE_ENG_SHIP_RX`) recognizes push-for-review asks (`delegated push`, `push for review`, `push ... branch/for review/for PR`, `5dive push`); a feature-branch push-for-review is no longer missed just because it isn't a `push to main`. The true-human floor (money / secrets / destructive) still wins first, so "push the pricing change" stays tier-2.
- fix(push): `_push_gate_check` now authorizes ANY lead-clear provenance (`need_answered_by = lead:*`), not only one whose `routed_reviewer` STILL equals the clearer. `lead:X` is stamped ONLY by the sanctioned lead-clear path (caller was `agent-X` AND X was the routed reviewer at clear time), so it already means "the designated lead cleared it" — and it is part of the signed gate closure that `_push_do` re-verifies, so a raw DB edit forging it fails the signature check. This fixes the `unauthorized provenance` refusal on a correctly lead-cleared push whose routing was later mutated (e.g. a re-route, or the DIVE-1437 T2-escalation NULLing `routed_reviewer`). The `--can-push` capability grant remains the human-gated step; a per-push-for-review never re-pings the human.
- test(push): `tests/push_review_gate_unit.sh` — a push-for-review ask files tier-1 with `routed_reviewer` set; the lead clear stamps `lead:<lead>`; `_push_gate_check` authorizes `lead:*` and still refuses a bare-agent (`main`) or auto (`auto:*`) provenance; and a money-tainted push ask still floors to tier-2.

## 0.11.30 — Council founder-veto TAP: authenticated one-tap veto, nonce only in the button, never printed to chat (DIVE-1494 #2 rail B) (2026-07-20)

- feat(council): `_council_veto_ping` delivers the founder-veto offer over a STRUCTURED seam and the raw one-time nonce is NEVER interpolated into chat text (rail B — the "never printed" guarantee lives at the council source). Previously the delivery leg printed the nonce inline ("Tap to VETO (nonce ...)"), conflicting with the DIVE-1494 requirement that the nonce travel only inside a tap button's `callback_data`.
- feat(council): new `_tg_veto_offer` renders the offer as a telegram message + a 🛑 VETO tap button whose `callback_data` (`veto:<receiptPrefix>:<nonce>`) is the ONLY place the raw nonce travels, delivered founder-chat-only via the existing `_mirror_send` rail (which honors `FIVEDIVE_NOTIFY_DRYRUN`). With no telegram rail the offer simply lapses and execution proceeds after the hold (fail-safe).
- feat(council): `council veto exercise --receipt` now resolves a UNIQUE receipt PREFIX (fail-closed on miss/ambiguity), because a full base64url sealed digest (43) + a 32-char nonce would exceed Telegram's 64-byte `callback_data` cap so the button carries a 12-char prefix. After resolving, it RE-ANCHORS to the found receipt's FULL sealedDigest, so the re-seal hardening (main-gate amendment 2) compares against the true digest and is byte-for-byte unchanged. A full digest is a prefix of itself, so exact-match callers are unaffected. Receipts stay digest-only.
- test(council): `council_veto_e2e.sh` (now 27 assertions) — structured-offer capture via the double-gated `COUNCIL_MOCK`+`COUNCIL_VETO_OFFER_SINK` seam; a source-pin that no `_tg_send` chat-text leg interpolates the raw nonce; prefix round-trip (exercise via a 12-char prefix flips pass→blocked), ambiguous-prefix + unknown-prefix both refused + audited; and `_tg_veto_offer` rendering asserts the button carries `veto:<12prefix>:<nonce>` while the message text carries NO nonce and targets the resolved founder chat.

## 0.11.29 — Council ⇄ Telegram: read-only convene notice + tally (DIVE-1494 feature 1) (2026-07-20)

- feat(council): `council convene` now emits an opt-in, read-only NOTICE of the outcome — disposition (rec, tally aA/rR/eE, conf), the question, and the sealed receipt handle — over the same guarded-optional `_tg_send` seam the founder-veto leg already uses (the telegram plugin provides `_tg_send`; council never hard-depends on it). Opt-in via `COUNCIL_NOTIFY=<chat>`; silent when unset or when the plugin has not installed the seam. This is the first of the DIVE-1494 council/telegram v1 features (convene notice + tally); the founder-veto tap and receipt/lineage view land separately. The notice carries NO nonce and no tap — it is distinct from the founder veto ping and is read-only by construction.
- test(council): `tests/council_notify_e2e.sh` (wired into `council_unit.sh`) asserts the notice fires with the disposition + `aA/rR/eE` tally + receipt reference, carries no raw nonce / 32-hex bearer token (read-only safety), and stays silent when `COUNCIL_NOTIFY` is unset. Offline via the double-gated `COUNCIL_MOCK` + `COUNCIL_NOTIFY_SINK` capture seam (mirrors the veto `COUNCIL_VETO_NONCE_SINK`), so PRODUCTION never writes the sink.

## 0.11.28 — Council seat track record: score votes against real task outcomes, feed promote/demote with data (CNCL-17) (2026-07-20)

- feat(council): new `5dive council record` — scores each seat's sealed votes against the REAL outcome of the task each convene decided (the receipt `subject`): a dissent (reject/escalate) is credited VINDICATED when the task went bad, an approve is credited when it landed good. Outcome is read from the decided task's terminal status (done → good, cancelled → bad; undecided tasks are never scored). Surfaces per-seat calibration so promote/demote votes run on data, not vibes.
- feat(council): decided per lodar's A1 gate — seat votes are DERIVED by PARSING the existing sealed canonical `vote <seat>:` lines rather than persisting a new structured array into the seal, so the tamper-evident receipt format is untouched and historical receipts stay scoreable. A new `subject` task-ident field is stamped on receipts going forward (gate-clear convenes pass it automatically); historical receipts fall back to the first ident parsed from the question. `council roster` can optionally fold each seat's track record.
- test(council): +13 engine unit tests (ident parse, canonical-vote parse, single-vote scoring incl vindicated dissent, aggregate calibration + sort, pending-skip, empty-safety) and a new `council_record_e2e.sh` that seeds a done + a cancelled + an open task and asserts the scorer credits/vindicates/skips correctly. Depends on the CNCL-11 receipt hash-chain + log.

## 0.11.27 — Council roster preserves the chair flag onto the persisted bench (CNCL-27) (2026-07-20)

- fix(council): `genesisToBench()` mapped each genesis seat to `{id, lens}` only, dropping the per-seat `chair` flag before it reached the persisted `council` bench. As a result `council roster` (JSON + text badge) and the dashboard Council panel — both of which render the chair badge from `roster.seats[].chair` — could never show a chair on ANY genesis-seeded box; the chair survived only inside the sealed genesis convene-log record. Now preserves `chair` the same way `buildGenesisRecord`/`buildMotionRecord` already do (`...(s.chair ? { chair: true } : {})`).
- test(council): engine unit asserts `genesisToBench` carries `chair` onto the bench (and non-chair seats stay flag-free); the roster/lineage e2e asserts the seeded `main:chair` shows up in both the roster JSON and the text `(chair)` badge, so the drop gates in CI.


## 0.11.26 — Reliable inter-agent sends to codex agents: detect the codex composer marker (DIVE-1528) (2026-07-20)

- fix(agent): `agent send`/`ask`/`_deliver` to a codex agent (e.g. andy) no longer times out 45s and prints the false "input prompt not detected — best-effort (may be lost)" warning. The send-path readiness probe (`wait_agent_input_ready`) only matched claude's `❯` and antigravity's footer; codex's composer marker `›` (U+203A) was in `_hb_idle_marker` (DIVE-1211) — whose own comment says it "Mirrors wait_agent_input_ready" — but had never been added to the send path, so every send to an idle codex agent fell through to the lossy best-effort branch. Added `›`, so codex is detected immediately and `inject_and_submit` confirms delivery like any other TUI.
- refactor(agent): the readiness marker set now lives in one pure, tmux-free predicate (`_agent_pane_input_ready`) so it can be unit-tested and a future TUI's marker is added in exactly one place.
- test(agent): `heartbeat_idle_marker_unit.sh` now asserts the send-path readiness set is a SUPERSET of the `_hb_idle_marker` idle table (every idle marker must also read input-ready), so the codex-style drift that caused this bug can never regress silently. A blank/booting pane and a mid-generation codex pane correctly read NOT-ready.
- Note: the reported secondary symptom — a headless codex worker (`channels=none`) having no return channel except manually running `agent send` — is tracked separately; this change closes the reliability/false-loss half.

## 0.11.24 — Council case law: convene pre-loads relevant past receipts, verdicts cite the precedents they follow or depart from (CNCL-19) (2026-07-20)

- feat(council): at `council convene`, the bash layer projects the SEALED convene receipt log into a precedent pool and hands it to the engine, which deterministically selects the top-k prior decisions relevant to the question (keyword overlap over question+brief; ties break toward the more recent), injects them into every seat ballot as fenced PRECEDENT (case law — HISTORY, clearly separated so the blind first round stays blind to CURRENT-round takes, never another seat's live vote), and requires the verdict to CITE which precedents it followed vs departed from.
- feat(council): the followed/departed citation rides on the verdict (`precedents` + `precedentCitation`) and is sealed INSIDE the receipt via a CONDITIONAL `precedent:` canonical line (digest-sorted) — so a citation cannot be quietly rewritten, and a no-precedent convene (plus every pre-CNCL-19 receipt) seals byte-identically. Retrieval is key-free + clock-free (works on the fleet dispatch path with no chair LLM).
- test(council): +new engine unit coverage (retrieval scoring/tie-break/self-guard, followed-vs-departed citation, blind-round invariant with precedent injected, conditional seal line back-compat); on-box mock e2e confirms a second related convene cites the first and seals the citation. Depends on the CNCL-11 receipt hash-chain + log.

## 0.11.23 — Fail-closed fixture-send guard: a task DB that is not prod can never DM a paired human (DIVE-1506) (2026-07-20)

- fix(task): a gate alert (`task need` → `task_need_notify`) or an `/inbox --send` digest now reaches the paired human ONLY from the canonical prod task DB. New fail-closed chokepoint in `_task_send_owner` (+ a clear refusal on `task inbox --send`) keyed to a POSITIVE prod-DB allowlist (`FIVEDIVE_PROD_TASKS_DB`, default `/var/lib/5dive/tasks/tasks.db`), not a fixture blocklist — a rotted blocklist is exactly how the DIVE-1500 guard missed these two legs and let `council_gate_e2e`'s `task need` DM fixture gates (dive1-4) to the paired human. Explicit `COUNCIL_MOCK`/`FIVEDIVE_NO_HUMAN_SEND`/`FIVEDIVE_E2E`/`FIVEDIVE_TEST` also force-refuse (belt-and-suspenders for harnesses that don't repoint `TASKS_DB`).
- test(task): new `task_fixture_send_guard_unit.sh` proves a fixture DB cannot reach a paired human on either leg AND that the prod DB still sends (CI globs `tests/*.sh`). Send-exercising harnesses now declare their isolated DB as prod via `FIVEDIVE_PROD_TASKS_DB`.
- Follow-up (separate plugin PATCH lane): startup age-gate + dead-letter quarantine for stale `relay-in` files, so a pre-restart backlog is never replayed (defense-in-depth; the fixture→human leak class is already closed here).

- feat(council): `5dive council amend --file=<new 5dive.md>` rewrites the constitution ONLY via a constitutional-class motion (2/3 + full quorum + founder veto). On a pass the new constitution's digest is hash-chained into the lineage and the on-disk `5dive.md` is swapped; a non-pass leaves it untouched. An invalid proposed constitution is refused before any convene (CNCL-15).
- feat(council): `council init` now seeds a v0 `5dive.md` (the human-readable projection of the built-in defaults) and seals its digest into the genesis record — the drift baseline.
- feat(council): `council verify` adds a constitution-integrity check — the live `5dive.md` must match the digest sealed in the newest genesis/amendment record. A missing or hand-edited file is drift; verify FAILS CLOSED. Authority is the sealed chain, not the forgeable file.
- feat(council): a primary-council `convene` under a drifted constitution ESCALATES instead of enforcing forged governance. Drift is recoverable by restoring the sealed file (or amending the sanctioned way).

## 0.11.21 — The Council: non-blocking ballots via the task queue (CNCL-18) (2026-07-20)

- feat(council): `5dive council convene` now delivers each seat's ballot as a DEADLINE-STAMPED TASK in that seat's queue instead of injecting it into the seat's live session over a blocking `agent ask` pane-scrape. The seat surfaces and works the ballot at its next heartbeat boundary (a ballot is just a normal assigned task, so no heartbeat change), casts its vote by closing the task with a COUNCIL-VOTE line in the result, and the convener COLLECTS by polling `task show` until the task closes with a result or the deadline elapses. A missed deadline, an unreadable result, or an unparseable vote all resolve to an abstain. This removes the coordinated quiet window the old rail needed and stops mid-work seats timing out to abstain. Liveness/abstain, quorum, and blind-first-round semantics are unchanged (they live in the engine; the redesign touches the dispatch adapter only).
- feat(council): new flags `--ballot-deadline=<secs>` (default 900, i.e. 15m; `--deadline` is accepted as an alias) and `--ballot-poll=<secs>` (default 5) tune the collection window. The old pane-scrape survives as an ESCAPE HATCH via `--ask-rail` or `COUNCIL_ASK_RAIL=1`. `COUNCIL_MOCK` (offline mock) and `--standalone`/`COUNCIL_STANDALONE` (single-key model seam) are unchanged; the fail-closed seat pre-flight still runs on the ballot path.
- test(council): `council_dispatch_unit.mjs` covers the ballot adapter's pure logic (result parses to a vote, deadline-miss abstains, unparseable result abstains, blind round-1 body embeds no other seat's vote) with injected exec/clock seams (no real timers). New `council_ballot_e2e.sh` drives the BUILT `5dive` binary proving the ballot selector is the default and reachable through `cmd_council()` (ad-hoc panel + fake fleet, no root/live fleet), and that `--ask-rail`/`COUNCIL_ASK_RAIL` keep the agent-ask escape hatch. Both wired into `council_unit.sh`.

## 0.11.20 — Fail closed on invalid constitution POSIX ERE (CNCL-28) (2026-07-20)

- fix(gates): compile-probe constitution `hard_gates` with Bash before using the combined POSIX ERE. A pattern rejected by Bash now emits a warning and atomically falls back to the shipped tier-2 floor instead of letting `[[ =~ ]]` return 2 and silently fail open (CNCL-28).

## 0.11.19 — Constitution loader: governance policy from `5dive.md` (CNCL-14) (2026-07-19)

- feat(council): load the ratified constitution-as-data frontmatter from `${STATE_DIR}/5dive.md`: roster/bench pointer, per-class thresholds, quorum, veto principal(s) + hold/post-hoc windows, hard-gate classes, and ship/comms policy. Council convenes pass the loaded threshold matrix into the deterministic tally; primary-bench selection and veto windows/principal consume the same normalized document.
- feat(gates): the task tier-2 floor now compiles `hard_gates` from the loaded constitution instead of treating `_GATE_T2_FLOOR_RX` as organization law. A constitution can add/remove `brand` (or any other class) without patching source; missing or malformed files atomically fall back to the exact shipped regex/policy/windows, never partially apply. When no constitution file exists, the gate-filing hot path retains the original in-process Bash regex and never starts Node or materializes the council runtime.
- docs/tests: document the v0 YAML-frontmatter shape and CNCL-15 integrity boundary. Loader unit tests prove default byte parity, live tally/quorum wiring, malformed fallback, roster/veto/soft-policy parsing, and brand-present versus brand-absent tiering.

## 0.11.18 — The Council: route `sign-vote`/`verify-votes` through the bash dispatcher (CNCL-26) (2026-07-19)

- fix(council): `5dive council sign-vote` / `5dive council verify-votes` now reach the mjs verbs through `cmd_council()`'s allowlist — they were fully tested + routed in `cli.mjs` but UNREACHABLE from the shell (the bash dispatcher never routed them, so `5dive council sign-vote` died E_USAGE). Since a SEAT signs at source from its OWN harness — the shell IS the product surface — the CNCL-10 co-signed-vote flow was dead on the surface it ships on. The passthrough preserves the `COUNCIL-SIG:` line / JSON-row stdout contract and the non-zero exit code (a seat harness gates on it) verbatim; no sudo/seal/lineage write (these verbs are pure). Also added to `council --help`.
- test(council): `council_bashroute_e2e.sh` drives the BUILT `5dive` binary end-to-end (throwaway build via `BUILD_OUT`), closing the CI blind spot where every prior council test drove `node cli.mjs` directly. Wired into `council_unit.sh`.

## 0.11.17 — Delegated push accepts signed verifier ship gates (DIVE-1496) (2026-07-19)

- fix(push): let a builder land an approved feature branch without a lodar transport handoff when the task's ship gate was cleared by its designated routed reviewer. The root-only push path verifies the persisted HMAC closure and accepts only `human:*` or the exact `lead:<routed_reviewer>` provenance; auto-clears, bare/unrelated agent answers, unsigned rows, tampered closures, and direct `_push_do` attempts all fail closed. Protected `main`/`master`, task-to-branch binding, configured author enforcement, repo-scoped short-lived GitHub App credentials, and no-token-to-agent guarantees are unchanged.
- docs/tests: document the reviewer-cleared ship path and cover signed human/reviewer success plus auto, provenance-mismatch, unsigned, and tampered-record refusals.
- fix(gates): include the accepted DIVE-1495 prerequisite that was absent from the assigned CNCL-11 base: a decision/approval gate a maker files on a maker→verifier loop routes to the loop's verifier agent, not the paired human. Routing remains subordinate to the true-human tier-2 floor, never self-routes a verifier-filed gate, and `task reject` supersedes any open gate made moot by the bounce.

## 0.11.16 — The Council: governance surface — roster/log/verify + promote/demote motions with recusal, constitutional auto-class, hash-chained lineage (CNCL-11) (2026-07-19)

- `5dive council roster` — live seats + pass threshold/quorum + founder-veto holder + sealed lineage head.
- `5dive council log [--limit=N]` — the append-only record of past sealed verdicts (genesis + motions + vetoes).
- `5dive council verify [<receipt>]` — whole-lineage tamper check: the prevDigest hash-chain AND a per-record ROOT re-seal; fails closed on an edited/dropped/reordered record.
- `sudo 5dive council {promote|demote|expel} --subject=<seat>` — a membership MOTION run as a convened Council vote: the subject RECUSES, the class is auto-derived IN CODE (promote = simple majority, demote/expel = 2/3, a governance-param change forced constitutional), and on a PASS the roster is mutated + a root-sealed motion record is hash-chained onto the lineage (the deciding convene receipt is linked). Seal-first so a failed seal never splits roster from lineage.
- Engine: `classifyMotion` (constitutional auto-class, un-downgradable), `recusalFor`, `tallyVotes` recusal, `buildMotionRecord`/`canonicalMotion`, `verifyLineageChain`. Engine unit 134/134, +25-check roster/lineage e2e wired into `council_unit.sh`.

- fix(notify): SAFETY — `FIVEDIVE_NOTIFY_DRYRUN=1` (any non-`0` value) short-circuits `_mirror_send`, the single Bot API POST that every owner/gate/mirror notify funnels through: the would-be payload (never the token) is logged to stderr and to `FIVEDIVE_NOTIFY_DRYRUN_LOG` when set, and a synthetic ok receipt keeps downstream delivery-receipt/stamping logic exercisable. Closes the 2026-07-19 incident class where a DIVE-1489 render test posted fixture gate alerts to the owner's REAL DM via the live connector token — a harness with a fixture DB is now physically unable to reach a paired human, including on the paths its stubs miss (DIVE-1500).
- feat(notify): `FIVEDIVE_CONNECTOR_DIR` env-honor on `CONNECTORS_DIR` (same fixture-override class as STATE_DIR/TASKS_DIR/TASKS_DB) so a harness can point channel resolution at fixture configs. The `$TELEGRAM_BOT_TOKEN` process-env fallback in `_task_agent_channel` remains, which is exactly why the dry-run guard above is the physical layer, not this.
- test: `notify_dryrun_unit.sh` (12 assertions) exercises the REAL `_mirror_send` under a curl trap — no POST attempted under dry-run, token never logged, gate_pinged_at still stamps, and with the guard off the trap catches the real POST attempt, proving the test non-vacuous.

## 0.11.14 — task inbox --send: owner digest with working tier-2 tap buttons (DIVE-1499) (2026-07-19)

- feat(tasks): `5dive task inbox --send [--channel-proof=<chat>]` — root-side, on-demand DM of the pending-gate inbox as ONE message with WORKING tap buttons for every gate type, including approval/secret/manual: fresh per-gate DIVE-916 nonces are minted in-process, embedded only in Telegram callback_data, and the stored hash rotates only after a confirmed send. The human-proof nonce is deliberately NOT added to `task inbox --json` — agent-readable output would make the human-proof agent-forgeable, re-opening the hole DIVE-950 closed. The telegram plugin's /inbox flow should shell this verb (passing the requesting chat as --channel-proof) instead of composing tier-2 buttons itself (unblocks DIVE-1489).

- fix(council): resolve council seat PERSONA ids to real REGISTRY agents before dispatch — persona `theo` is the `marketing` agent and `lilbro` is `creative`, so the old code that passed `seat.id` verbatim to `5dive agent ask` recorded both default seats as silent ABSTAINs on every live convene (a 5-seat council degraded to 3 votes cast). Seats now carry an explicit `agent` field (built-ins) plus a persona→agent alias map, and convene FAILS CLOSED with a loud pre-flight error if any seat resolves to no known registry agent, instead of degrading silently (CNCL-16).

- fix(gates): remove pure brand/strategy asks from the CLI's tier-2 human-gate floor so they remain tier-1 and org-lead-clearable; money, public/customer communications, secrets, and destructive/irreversible asks continue to floor to tier 2. The goal planner's separate `brand` risk taxonomy is unchanged (DIVE-1492).

## 0.11.13 — The Council: shipped seed rosters genericized to role archetypes (CNCL-20) (2026-07-19)

- fix(council): the SHIPPED defaults `DEFAULT_COUNCIL` + `STANDING_COUNCILS` (ship/brand/security) now seed role ARCHETYPES (eng-lead, brand, builder, strategy, contrarian, reviewer, red-team) instead of 5dive-internal persona names — OSS installs get self-explanatory seats to map onto their own agents via the CNCL-16 fail-closed pre-flight. Genesis-seeded registries (live hosts) are untouched: these defaults only matter pre-genesis / for ad-hoc benches. CNCL-16 legacy persona aliases retained.

## 0.11.12 — The Council: per-seat Ed25519 co-signed votes (CNCL-10 core) (2026-07-19)

- feat(council): SECURITY — per-seat Ed25519 co-signing engine. Every seat holds its own keypair and SIGNS its vote AT SOURCE; the convener holds no other seat's private key, so it can neither forge a vote nor edit one without breaking the signature. The signed preimage binds the CONVENE ID + QUESTION DIGEST, so a seat's signed vote from one convene fails verification in any other (replay-proof). Closes the CNCL-6 gap where the root seal proved only that the convener recorded the bytes, not that each seat cast its own vote. Rebuilt on current origin/main atop the merged CNCL-9 veto (nonce-binding sealed into the canonical, 0.11.8) — additive co-sign region, no overlap with the veto seal.
- feat(council): `5dive council sign-vote` — the sign-at-source primitive a seat runs inside its OWN harness (reads its 0600 owner-only key via `--key-file`, emits the `COUNCIL-SIG:` line). `5dive council verify-votes` — the per-seat half of `council verify`: re-checks every co-signed vote against the roster pubkeys + revocation, bound to this convene; a revoked (demoted) seat's vote is rejected even with a cryptographically valid signature. Exits non-zero on any unsigned/forged/replayed/revoked vote.
- test(council): `council_cosign_unit.mjs` (26 assertions, bound to the shipped engine) proves forge/edit/replay/revoked all fail and the honest path verifies green; `council_cosign_e2e.sh` (6 assertions) exercises the real CLI over on-disk keys and audits 0600 owner-only perms. Both wired into CI via `council_unit.sh`.
- note: the on-disk key LIFECYCLE (issue at init/promote, revoke at demote, roster pubkey write, revocation logged in lineage) + the live dispatch sign-at-source integration (seatPrompt instruction + convener verify during a real convene) are the next slice, staged for main's gate to steer. Honest-scope deferral, same discipline as CNCL-7/8/9.

## 0.11.10 — The Council: gate-rot wiring — clear tier-1 gates, rot-triage stale tier-2 (CNCL-12) (2026-07-19)

- feat(council): `5dive council gate-clear <task|DIVE-N>` routes an OPEN tier-1 gate to the council. The escalate-only guardrail runs first — a tier>=2 gate or a human-only type (secret/approval/manual/access) is NEVER self-cleared; it is bumped to a human with a one-paragraph brief. A genuine tier-1 gate is convened (default: the primary Council) and the sealed verdict either CLEARS it (`task answer` with the recommendation, provenance-stamped `[council]`) or escalates it with the brief. `--dry-run` prints the planned action without touching the gate.
- feat(council): `5dive council rot-triage [<task|DIVE-N> | --all] [--older-than-hours=48]` rot-triages stale tier-2 gates — a tier-2 gate UNANSWERED 48h+ is convened ONLY to re-brief it sharper for the human (the brief may propose a rescope or a park+wake). It NEVER clears a tier-2 gate: the fail-closed rule lives in the pure mapper (`triageVerdictToAction` has no `task answer` branch, not even for an `approve` verdict) AND a belt-and-suspenders `grep` refusal in the orchestrator. `--dry-run` lists the stale gates without convening.
- feat(heartbeat): the rot-triage scan is wired into the heartbeat (`_hb_council_rot_sweep`), DEFAULT OFF behind `COUNCIL_ROT_TRIAGE=on` + a seeded genesis, throttled once/6h fleet-wide. Kept off by default because a live convene injects into seat sessions — it stays gated on an explicit opt-in until the CNCL-7 live-dispatch window.
- feat(council): pure `council gate-map` verb (side-effect-free) exposes the guardrail + verdict→action + triage mapping; bash owns every side effect (task show/answer/need/escalate + the sealed convene), so the auditable decision core stays unit-testable offline.
- test(council): +6 engine assertions (triage never clears — even on an `approve` verdict — re-files a sharper tier-2 ask, preserves options) and a new `council_gate_e2e.sh` (12/12) driving the real bundle end-to-end over an isolated STATE_DIR + TASKS_DB: leg A a tier-1 gate is CLEARED with a sealed receipt, leg B a tier-2 gate escalates (guardrail) and is never cleared, leg C a synthetic 48h-old tier-2 gate is re-briefed and never cleared, plus a dry-run no-op. Council suite green: 85 engine / 40 contract (no drift) / 41 dispatch / 16 veto e2e / 12 gate e2e. HONEST SCOPE: the LIVE tier-1 clear against real seats stays deferred to main's CNCL-7 window — a real convene currently returns 0 parseable votes (seats reply in TUI text, not a machine vote line), so the live-clear leg is proven only under COUNCIL_MOCK. Same honest-scope deferral as CNCL-7/9/10.

## 0.11.9 — The Council: veto window-expiry boundary is inclusive (CNCL-9 CI-race fix) (2026-07-19)

- fix(council): the founder-veto posthoc window-expiry check refused an exercise only when `now > stamped_at + posthoc` (strict `>`). With a zero (or already-past) `COUNCIL_VETO_POSTHOC_SECS` and an exercise landing in the SAME wall-clock second the receipt was sealed, `now == stamped_at` so the strict comparison was false and the expired exercise was NOT refused — a sub-second timing race that passed locally (>1s gap masked it) but failed on fast CI runners (`council_veto_e2e.sh` 13/16). The boundary is now inclusive (`now >= stamped_at + posthoc`): a 0s window is expired the instant it is reached, so the leg is deterministic regardless of scheduling. Correct-by-construction for real windows too — the 48h deadline is simply now inclusive at its exact edge. Hold-tier and valid-posthoc paths are unaffected. Same fix applied to both the canonical `cmd_council.template.sh` and the shipped `cmd_council.sh` bundle. Council suite green twice back-to-back (`council_veto_e2e.sh` 16/16 ×2).

## 0.11.8 — The Council: seal the veto nonce-binding (CNCL-9 amendment) (2026-07-19)

- fix(council): SECURITY — the founder-veto EXERCISE authenticated + derived its tier from `.vetoNonceDigest`, `.executeAfter` and `.stampedAt` read out of the UNSEALED receipt wrapper, which sit OUTSIDE the sealed `canonicalTranscript`. The exercise-time re-seal check only re-signs `.canonical`, so an edit swapping `.vetoNonceDigest` to `sha256(attacker-nonce)` left `.canonical` untouched, re-sealed to the same digest, and let an attacker exercise the veto with a chosen nonce (truthful tamper-evidence gap; not a live non-root exploit — receipts are root-owned, the enforce key is root-only). FIX: the nonce digest + executeAfter are now FOLDED INTO the canonical (`augmentCanonicalVetoBinding`, appended before sealing so they are covered by the same HMAC), and exercise reads them back from the VERIFIED canonical (`parseCanonicalVetoBinding` via `council read-binding`), never from the raw wrapper. Any edit to either field now changes `.canonical` and breaks the re-seal (fail-closed, refused + logged). A base receipt with no veto offer stays byte-identical.
- test(council): +7 engine assertions (`augmentCanonicalVetoBinding`/`parseCanonicalVetoBinding` round-trip, append-not-interleave, fail-closed on no binding, digest-edit changes the sealed bytes) and a live e2e case — swapping the wrapper `.vetoNonceDigest` to `sha256(attacker-nonce)` and presenting that nonce is now refused because exercise reads the digest from the sealed canonical. Council suite green: 80 engine / 40 contract (no drift) / 41 dispatch / 16 veto e2e.

## 0.11.7 — The Council: authenticated founder veto, non-blocking two-tier (CNCL-9) (2026-07-19)

- fix(council): SECURITY — `convene` now REFUSES `--veto-by`/`--veto-reason` (exit 9, logged). Pre-CNCL-9 those plain CLI strings flipped the verdict inline, so any agent could forge lodar's veto into a signed receipt. A veto can no longer be asserted from a string; it is only ever OFFERED to the genesis principal and EXERCISED by an authenticated tap. The refusal now writes a durable `veto-audit.jsonl` line (root 0600) so "refused + logged" is a real, testable artifact.
- fix(council): SECURITY — the one-time nonce is no longer stored in plaintext. The receipt (fleet-readable audit artifact) carries only `vetoNonceDigest = sha256(nonce)`; exercise hashes the presented nonce and compares. The raw nonce leaves the process solely via the founder delivery leg, and `veto-pings.jsonl` is locked root 0600 (digest-only). Closes the group-readable bearer-token leak that re-opened the forge class.
- fix(council): DEFECT — the exercised-veto lineage entry now hash-chains to the LINEAGE head (prevDigest = last entry's digest, seq = last+1) instead of the receipt digest with seq=-1, so `council lineage verify` stays GREEN after a veto. The veto→verdict link is preserved inside the signed record (origDigest).
- feat(council): non-blocking veto OFFER — on a primary-council PASS the sealed receipt records the offer to the genesis-resolved principal and stamps `executeAfter = sealedAt + veto_hold`; the disposition stays `pass` (nobody waits synchronously — the ACTION waits, enforced downstream by CNCL-12). A founder ping fires at seal. Silence past the hold window = auto-proceed (the default, do-nothing path).
- feat(council): two-tier authenticated EXERCISE via `5dive council veto exercise --receipt=<digest> --nonce=<tap nonce> [--tier=hold|posthoc]`. Exercise first re-seals the receipt canonical on the gate-proof rail and refuses a receipt that does not re-seal to its stored digest (tamper hardening). `hold` (within the window) flips the pass to BLOCKED before execution, `posthoc` (until `veto_posthoc`/48h) flips it and flags `unwindRequired`. Beyond the post-hoc window the pass is final (fail-closed).
- feat(council): the exercised veto is a NEW root-sealed record hash-chained to the original verdict digest (kind=`veto` in the lineage) — the original convene receipt is never re-sealed or mutated. Both the offer and (if it happened) the exercise ride inside the signed bytes, so neither can be stripped.
- feat(council): veto durations are a config seam (`COUNCIL_VETO_HOLD_SECS`=900, `COUNCIL_VETO_POSTHOC_SECS`=172800 defaults) that CNCL-13/14 redirects to the `5dive.md` constitution — no hardcoded magic numbers. Hard-gate classes are unchanged (pre-escalate to a human before execution, never auto-proceed).
- test(council): committed bash e2e (`tests/council_veto_e2e.sh`, wired into `council_unit.sh`) drives the real `5dive council {init,convene,veto exercise,lineage verify}` bundle — nonce-mismatch refused+logged, window-expiry refused, a real tap flipping pass→blocked in a sealed record, lineage-verify GREEN after veto, digest-only receipt, 0600 pings, forged `--veto-by` refused+logged, tampered-canonical refused. Self-skips green when it can't seal (no root/sudo).
- note(council): executor-wait ENFORCEMENT (every consumer refuses to act before `executeAfter`) is CNCL-12 scope; until it lands the interim policy is operator-held. The real tap-confirmed e2e over a LIVE genesis + tier-2 tap rail runs after `council init` is human-seeded.

## 0.11.6 — gate delivery receipts + 1h/24h batched re-nags (DIVE-1490) (2026-07-19)

- fix(gates): gate alerts now treat Telegram's structured Bot API acknowledgement as the delivery receipt instead of treating a best-effort curl as success. A confirmed send stamps `gate_pinged_at` and records the returned `message_id`; a rejected or empty response emits a loud warning and durable delivery event, leaves the receipt unset for retry, and falls back to an allowed group topic so the alert remains visible.
- fix(heartbeat): unanswered gates receive a first button-bearing re-nag after 1 hour and subsequent re-nags every 24 hours, batching all due gates for each resolved recipient into one message with per-gate tap rows. Tier-2 gates use the filing agent's paired-human channel, tier-1 gates retain org-lead routing, failed sends do not advance the throttle or rotate human nonces, and the existing 72-hour/7-day backlog reminder remains receipt-throttled without a migration.
- test(gates): add isolated kill coverage for a bad DM target → loud failure + recorded, button-bearing group fallback, plus cadence coverage proving no pre-1h ping, two due gates → one batch with working decision/approval buttons, 24h re-fire, tier-1 lead routing, and failure-state idempotence.

## 0.11.5 — The Council: human-seeded genesis roster, `council init` (CNCL-8) (2026-07-19)

- feat(council): new sudo-gated, one-time `5dive council init --seats=<a:chair,b,c> --threshold=<majority|all|N|a/b> --veto=<principal>` seeds the primary `council` bench from a human-supplied roster, sealing an immutable genesis record on the root gate-proof rail and hash-chaining it into `${STATE_DIR}/council/lineage.jsonl`. Enforces the governance invariant that an agent must not bootstrap its own council's membership (the write path is root-owned; a non-sudo init is refused).
- feat(council): the veto holder is stored as a RESOLVABLE principal — `human:<agent>` resolves to that agent's paired human Telegram id (via its `access.json` allowFrom), or `tg:<id>` literal; init REJECTS an unknown/unresolvable principal (fail-closed) so the genesis record always carries a real veto recipient.
- feat(council): the primary council is special in exactly one way — raw `bench add/rm` against it is refused (exit 7) and points to the promote/demote motion path, so `sudo bench rm council` cannot bypass the governance layer. Membership changes only via motions (machinery lands in a later wave).
- feat(council): `convene` of the primary council fails closed (exit 8) until it has been human-seeded; an ad-hoc `--seats` panel or an alternate bench (ship/brand/security) is unaffected. After init, the primary convene uses the human-seeded roster, never the hardcoded default.
- feat(council): `council init --force` re-seeds and the re-seed is logged as the next hash-chained lineage entry (prevDigest links back to the prior genesis). `council lineage verify|ls` re-seals each record, compares digests, and checks the chain — failing closed on any tamper or broken link.
- fix(council): fail-OPEN guard bug caught by the bash e2e — bash passes boolean flags as the strings `"0"`/`"1"` and JS `!"0"` is false, so `--genesis-exists=0` bypassed the convene/init guard; added `flagBool()` and hardened the CLI contract to pass `=0` explicitly for negatives.
- test(council): CLI contract 35/35 (init once/twice/`--force`, unresolvable-veto, raw-bench-council guard, convene fail-closed, chair/duplicate/threshold parsing); engine 57/57, dispatch 41/41. Full bash e2e (sudo-gate, `human:main`→tg resolution, root seal, hash-chained lineage verify + tamper-detect) all green. Stacked on cncl-7-dispatch. Motions / ed25519 co-signed votes / tiered founder-veto remain deferred to CNCL-9/10/11.

## 0.11.4 — The Council: `convene` dispatches to the REAL seated agents + liveness/quorum (CNCL-7) (2026-07-19)

- feat(council): re-wire `council convene` for fleet mode — it now DISPATCHES the question to the real seated agents instead of answering every seat from one shared model key. Each seat votes via its OWN harness over the `5dive agent ask` rail (blind first round: no seat sees another's take before its own vote is recorded), the existing deterministic counter tallies over the current roster, and the whole verdict path is now KEY-FREE (synthesis — confidence/dissent/human-brief — is computed deterministically from the votes, no chair LLM). The `COUNCIL_API_KEY` modelCall path survives only as the deferred shell-portable `--standalone` seam (`COUNCIL_STANDALONE=1`); `COUNCIL_MOCK=1` still runs both paths offline (no key, no network, no agent dispatch) for tests + smoke.
- feat(council): LIVENESS — a seat that times out (`agent ask` `E_TIMEOUT`), isn't running, or replies without a parseable `COUNCIL-VOTE: <approve|reject|escalate> :: <why>` line is a recorded ABSTAIN (rides INSIDE the signed receipt, never silently dropped). An abstainer stays in the roster denominator (`seatCount`) but not in the tally, so one dead agent makes passing HARDER, not easier — it can never turn a 3-of-5 into a 3-of-4.
- feat(council): QUORUM VALIDITY — a convene is only valid if votes cast reach the class quorum (majority of current seats; constitutional needs full quorum). Below quorum there is NO verdict: it auto-escalates with a one-paragraph human brief naming the shortfall and the abstaining seats. `adversarial` mode adds one rebuttal round that sees the round-1 votes, recorded separately (`round1Votes` + `rebuttalVotes` in the JSON envelope; the final tally is round 2). Tiered thresholds, promote/demote, and the authenticated founder veto remain deferred to CNCL-9/10/11.
- fix(council): the tamper-evident receipt now seals the ROUND-1 history in adversarial mode (sorted `round1 <seat>: <vote> :: <rationale>` lines in the canonical preimage), so a between-round seat flip cannot be misrepresented without failing verify — the deliberative record is the product, not only the final tally. A single-round (non-adversarial) receipt omits the round-1 block and stays byte-identical to CNCL-6 (main's CNCL-7 gate amendment).
- test(council): new `tests/council_dispatch_unit.mjs` (41 assertions — parse/blind-isolation/abstain/quorum-boundary/adversarial-separation/deterministic-synthesis) + CLI dispatch contract (real-agents default, `--standalone` seam). All three council harnesses are now gated in CI via `tests/council_unit.sh` (they previously ran locally only). Engine 57/57, CLI contract 19/19, dispatch 37/37. The live e2e (a real convene over 3+ seated agents) is run separately in a coordinated quiet window.

## 0.11.3 — internal-ops residual: refuse the carve-out when an external prod target is coordinated with the destructive verb (DIVE-1487) (2026-07-19)

- fix(gates): close three confirmed residual vectors the DIVE-1481 nearest-object strip still downgraded. When a destructive verb governs BOTH an internal object AND an external prod/customer object — a compound (`delete the board and the production database`), a coordination span, or a passive window the 20-char heuristic mis-reads (`wipe the board then delete the prod customer records`) — the active/passive strip carved the verb out as co-referent to the *nearest* (internal) object, so the prod-destructive residual no longer tripped the T2 floor and the gate downgraded from lodar to lead review. Fix: `_gate_internal_residual` now refuses to strip ANY destructive verb once an external target (`_GATE_EXTERNAL_TARGET_RX` = prod/production/customer(s)/user data/pii/live-*/user|customer records) is present anywhere in the ask — the verb survives, trips the floor, and the gate stays hard-human; a purely-internal co-referent `wipe the task board` still downgrades to a lead-routed tier-1 (no over-tighten). Also widened the floor's `drop table` → `drop[^.]{0,20}table` and added `truncate`, so a standalone `drop the customers table` trips the floor directly (independent adjacency gap noted in DIVE-1487). NOT a regression of DIVE-1481 (strictly stricter); this was the pre-existing compound-object residual 1481 flagged in-scope. Tests: `gate_internal_ops_floor_unit.sh` 23/23 (adds coordination, passive-over-reach, compound purge+drop, standalone drop-table, and a no-over-tighten guard). Sibling gate suites green.

## 0.11.2 — internal-ops floor carve-out now requires destructive/object co-reference (DIVE-1481) (2026-07-19)

- fix(gates): harden the DIVE-1480 internal-ops downgrade so a destructive term is carved out of the residual-floor test ONLY when it is CO-REFERENT (adjacent, within ~20 chars, active or passive voice) to an internal-ops object — the task board / tasks.db / backlog / an agent's own wip — not merely co-present in the ask. Closes the residual gap DIVE-1480 left: `Delete the production database as part of the board recovery` matched the internal-ops CLASS (`board recovery`) and, under the old blanket strip, had its `delete` removed everywhere, silently downgrading a PROD-destructive action from lodar to lead review. Now `delete` governs `production database` (an external object), so it survives the residual, trips the T2 floor, and the gate stays hard-human — while a genuinely co-referent `wipe the task board` still carves out and downgrades to a lead-routed tier-1. New `_GATE_INTERNAL_OBJECT_RX` + `_gate_internal_residual` (iterate-to-fixpoint so several verbs sharing one object all clear). Tests: `gate_internal_ops_floor_unit.sh` 16/16 (adds the prod-object-in-recovery-framing vector + a co-referent-still-downgrades guard).

## 0.11.1 — heartbeat self-heal no longer defers idle-stranded "active" sessions forever (DIVE-1486) (2026-07-19)

- fix(heartbeat): the no-clobber guard that defers a nudge on a confident `_hb_agent_idle` "active" (rc 1) reading — so the tick never `/clear`s an agent mid-turn — no longer defers an *attached-but-idle* session indefinitely. Surfaced by the 2026-07-19 07:16 UTC live fleet-stall: dev sat 45m+ with 3 todos while the tick logged `[dev] active (mid-turn/conversation) — defer nudge this tick` every pass AND the supervisor simultaneously called dev `idle-stranded — no active work`. The two session-state signals disagreed (a blinking cursor/spinner leaves the pane byte-unstable, or the native signal lags), so the self-heal deferred forever until a human ran `5dive agent send`. This is the DIVE-1416 gap#3 the stall detector itself cites (1416 was lost in the 04:20 board wipe; this re-files the specific fix). Reconciled via OUTPUT PROGRESS, not the active reading itself: each active-defer fingerprints the agent's pane (`_hb_pane_fingerprint`, md5 of `tmux capture-pane`) and `_hb_mark_active_defer` advances a per-agent counter (registry `.heartbeat.activeDefer={fp,n}`) ONLY while the fingerprint is unchanged (zero output); any streaming output — or an empty/uncapturable pane (fail-safe) — resets it to 1. Once it holds unchanged for `_HB_ACTIVE_DEFER_ESCALATE` (default 3, env `HEARTBEAT_ACTIVE_DEFER_ESCALATE`) consecutive deferred ticks with a dispatchable todo waiting, the tick stops deferring and force-nudges (falls through to the wake); the counter clears on the escalation and on every successful wake. A genuinely working agent streams output within a ~1–3h window (ticks are `everyMin` apart), so its fingerprint moves and it never reaches the ceiling; only rc 1 escalates (rc 3 blocked-on-prompt still just surfaces, so a pending permission prompt is never buried); the guard sits after the empty-queue `continue`, so escalation can only fire with a real todo waiting. Complements DIVE-1211 (non-claude always-active) and the STEER-1 dam-sweep. New `tests/heartbeat_active_defer_unit.sh` (17/17): frozen-pane climb to the ceiling, streaming-output reset, empty-fp fail-safe, clear/no-op, and per-agent independence.

## 0.11.0 — The Council: `5dive council` standalone deliberation CLI (CNCL-6) (2026-07-19)

- feat(council): new `5dive council` command — a standalone deliberation engine callable from any shell, not an agent-only Workflow launcher (settled by CNCL-1, option B). `council convene "<question>" [--seats=a,b,c] [--mode=quick|deliberate|adversarial] [--bench=<name>] [--class=<decisionClass>] [--threshold=<n>] [--veto-by=<who>]` runs a roster of named seats through independent opening takes → a vote round (with an adversarial rebuttal round in `adversarial` mode) → a deterministic tally over the CURRENT roster (nothing hardcodes 5 or 3 — per-class thresholds + a quorum-validity gate are config) → a narrative-only chair. Emits an auditable verdict object and a tamper-evident, root-signed receipt (canonicalized transcript with the founder veto + dissent INSIDE the signed bytes, sealed via the existing `gate-proof` HMAC rail so a standalone engine's verdict can't be quietly altered). The escalate-only guardrail from the gate-clear map is preserved: a hard-gate class (secret/approval/manual/access, or any tier≥2) always escalates to a human and never self-clears, failing closed on a missing tier.
- feat(council): persisted, editable registry of standing benches — `council bench ls|show|add|rm`. Built-ins ship for `council` (the 5-seat self-governed standing body), `ship`, `brand`, and `security`; `add`/`rm` mutate a per-host JSON registry under the state dir (privileged governance writes, gated behind sudo). Resolution is fail-closed: an unknown bench name errors (exit 3) rather than silently defaulting, and a built-in bench cannot be removed (exit 4).
- feat(council): model calls go through one A-with-seam adapter (`COUNCIL_API_KEY`, `COUNCIL_BASE_URL` for BYO/OpenRouter) so a provider swap needs zero engine changes; `COUNCIL_MOCK=1` runs a deterministic offline council (no key, no network) for tests + VM smoke. The engine ships as node modules embedded in the single bash bundle (materialized to a temp dir at call time, same pattern as `memory search`); a generator (`gen_cmd.mjs`) keeps the embedded copy byte-identical to the canonical `src/council/*.mjs` and `tests/council_cli_contract.mjs` guards the drift. Tests: engine unit 57/57, CLI+embed contract 16/16.

## 0.10.12 — tier-2 destructive floor no longer over-fires on internal-ops asks (DIVE-1480) (2026-07-19)

- fix(gates): the T2 category floor no longer forces an INTERNAL control-plane decision onto the paired human just because its ask NARRATES a destructive event. Surfaced by the 2026-07-19 board wipe: dev's STEER-1 "keep vs discard my work / rebuild the board" DECISION gate (the lead's call) matched the destructive floor terms (`destroyed`/`wiped`/`purge`) and was forced to hard-human tier-2, landing on lodar instead of Marcus. New internal-ops/recovery downgrade class (the fourth, mirroring eng-ship DIVE-1359 and content-curation DIVE-1381): a decision/approval about our own task board / an agent's uncommitted work / a wipe recovery is re-tested with only the INTERNAL-destructive terms stripped (`destroy|wipe|purge|delete|irreversible`) and, when a narrow internal-ops class matches AND nothing else in the residual trips the floor, is downgraded to a LEAD-routed tier-1 so the org lead clears it, not the human. Fires ONLY when the floor actually over-fired (`tier_floored==1`) and a reviewer exists (a lead filing it, or a non-floored decision, is untouched). Every genuinely-human category still wins: a prod/infra destructive ask (`drop table`, `teardown`, `revoke`, `dns`) keeps those terms in the residual and stays hard-human, as do money/secret/publish/brand — the floor's trust model (never filer-lowerable) is unchanged; the narrow class is the safety gate. New `tests/gate_internal_ops_floor_unit.sh` (12/12): the repro routes to the lead with no human ping, plus prod-drop-table / revoke-residual / money-residual / lead-filed / non-floored / plain-destructive all stay put.

## 0.10.11 — tasks-db silent-recreate guard: alarm + auto-restore (DIVE-1479) (2026-07-19)

- fix(tasks-db): `tasks_db_init` no longer silently recreates an EMPTY board when the `tasks` table is missing on a board that existed before — the exact trap behind the 2026-07-19 04:20 wipe (something unlinked `tasks.db`, a routine reader re-initialised it blank, and everyone proceeded). A durable sentinel (`tasks/.board-initialized`, group-writable so any agent stamps it and it survives a bare `rm tasks.db`) records that the board was initialised at least once; a backup snapshot in `tasks-backups/` counts as the same proof. When the table is absent but that proof exists, init now LOUDLY alarms (stderr + a durable `tasks-backups/RESTORE-INCIDENTS.log`) and **auto-restores** from the newest `5dive-tasks-backup.sh` snapshot (which only ever captures a non-empty board), verifying row-count and clearing stale WAL/SHM before swapping the file in under a `flock` so concurrent inits never double-restore. If there is nothing to restore it FAILS loudly (`E_GENERIC`) rather than proceeding on a blank board — loud failure/auto-heal beats silent data loss. A genuinely fresh box (no sentinel, no snapshot) still creates a new schema and stamps the sentinel; a pre-existing board backfills the sentinel on its next init. New `tests/tasks_db_restore_guard_unit.sh` (13/13): fresh-create, sentinel backfill, wipe-with-backup restore, wipe-without-backup loud fail, and idempotency.

## 0.10.10 — task-db isolation + wake status-guard (DIVE-1475) (2026-07-19)

- fix(heartbeat): `_hb_wake` refuses to inject a /goal for a task that isn't actionable — a nonexistent, done, or cancelled id (or a non-numeric id) is a logged no-op instead of a bogus goal dropped into a live agent pane. The tick's picker only ever hands it a live todo so legit wakes are unaffected; this hardens the direct `heartbeat wake-task` verb (and any looping/buggy caller) that the 2026-07-19 incident showed spamming DIVE-1/DIVE-7/DIVE-22 ghost goals. New tests/heartbeat_wake_guard_unit.sh (5/5).
- fix(state): `STATE_DIR`/`TASKS_DIR`/`TASKS_DB` now honor an environment override (`${VAR:-default}`) instead of unconditionally reopening the live store. A test (or forked `sudo -E` subprocess) can set an isolated temp path that STICKS through library sourcing — closing the isolation-failure class behind BOTH the /goal spam (loop tests forking wake-task into live panes) and the board wipe (a test resolving TASKS_DB to the live file, then a routine reader re-initialising it empty). Prod is byte-identical with the vars unset.

## 0.10.9 — openclaw headless node24 runtime (DIVE-1328) (2026-07-19)

- fix(openclaw): fresh agents resolve a supported Node 24 runtime explicitly (stable `~/.local/bin/node` link + direct node invocation for OpenClaw's `#!/usr/bin/env node` launcher at create-time model setup and at runtime in `5dive-agent-start`), and channel-less agents use an idempotent `config set gateway.mode local` headless bootstrap instead of blocking in the interactive `openclaw configure` wizard. The managed install/upgrade path installs `openclaw@latest` directly into the active Node 24 npm prefix (`nvm use 24` + `npm install -g`) rather than the upstream `openclaw.ai/install.sh` wrapper, which re-selects nvm's default Node and can attempt a privileged NodeSource upgrade that fails in the non-interactive `sudo -u claude` installer; `FORCE_INSTALL` (set by `--upgrade`) always refreshes that Node 24 global, and node/openclaw links then point at the same active tree with a fail-closed final `-x` check. Verified on a fresh Ubuntu 24.04 smoke: install --upgrade + node link + create + runtime stability + a live `agent ask` round-trip (DIVE-1328).

## 0.10.8 — BYO model on claude create + init Enter-drain (2026-07-19)

- fix(agent): `agent create --type=claude --provider=openrouter --model=<slug>` now preserves the explicit model in the new agent's `settings.json` instead of overwriting it with `claude-opus-4-8`; the existing auth-profile tier mappings remain intact (DIVE-1327).
- fix(init): a typed numeric menu shortcut in the `5dive init` wizard no longer leaks its terminating Enter into the next prompt (DIVE-1398, surfaced by DIVE-1368 QA on fresh Ubuntu 24.04 over `ssh -tt`). `_init_pick`'s interactive branch reads one keystroke at a time (`read -s -n1`); a fast shortcut like `2⏎` selected the option but the trailing Enter stayed buffered and was consumed by the FOLLOWING prompt — so picking OpenRouter for a pi/opencode agent then read the stray newline as an empty model submission and aborted with `openrouter needs a model (none given)`. Fix: after a `[1-9]` shortcut selection, drain a single already-buffered line (`read -s -t 0.05`) so the Enter cannot cross into the next prompt. New `tests/init_pick_drain_unit.sh` drives the real interactive PTY branch (DIVE-1398).

## 0.10.7 — builder-scoped push grant + branch-bound gates (2026-07-18)

- fix(push): a cleared ship gate now binds to the task's OWN declared branch. `_push_do` (and the `5dive push` pre-flight) refuse any branch that isn't the one the cited task declares via a `Branch: <name>` line in its body — so a granted agent can no longer cite one task's cleared gate to fast-forward an unrelated feature branch. A task with a cleared gate but no declared branch is refused (the gate has nothing to bind to). Authoritative in the root-only `_push_do`, mirrored as a friendly pre-flight in `cmd_push`. (DIVE-1462 / STEER-4)
- change(agent create): the delegated-push grant is now BUILDER-SCOPED, not given to every standard agent. New `agent create --can-push` flag grants a standard (builder) agent the exact-path `_push_do` NOPASSWD line; without it a standard agent gets only the a2a/audit grants (a QA or art-director standard agent can't ship). Admin agents already reach `_push_do` through their broad sudo (the flag is a no-op there); it is refused for `--isolation=sandboxed`. The capability is persisted as `AGENT_CAN_PUSH` and the sudoers renderer (`render_standard_sudoers`) is now pure + unit-tested. Supersedes 0.10.6's "standard agents created via `agent create` get the grant" behavior. (DIVE-1462 / STEER-4)

## 0.10.6 — hardened delegated push + BYO GitHub App + fleet grant (2026-07-18)

- feat(push): `5dive push` now performs the privileged work ATOMICALLY inside a single root-only helper (`_push_do`) — gate re-verify, author scan, token mint, and the one-branch push all happen as root, so the agent process NEVER holds a token it could exfil and reuse (DIVE-1460). The installation token is minted SCOPED to just the target repo (`repositories:[<repo>]` + `permissions:{contents:write}`), dropping a captured token's blast radius from the whole org install to one repo. The helper reads its params over STDIN (never argv), so the fleet NOPASSWD grant is an exact command path (`/usr/local/bin/5dive _push_do`, no trailing-`*`) — identical under classic sudo and sudo-rs. Agent-supplied branch/url/repo-path are validated against flag/refspec/traversal injection before reaching git. Standard agents created via `agent create` get the grant so `5dive push` works fleet-wide. (DIVE-1376/1460)
- feat(push): delegated push is now a documented bring-your-own-GitHub-App feature — README section + `docs/delegated-push.md` walkthrough (create App, install on ship repos, drop the credential, wire the grant, first push) + a new root-only `5dive push setup` scaffold/doctor that provisions `/etc/5dive/connectors/github-app.{pem,env}` and checks the key/env/grant (never takes a secret on argv). Commit-author enforcement is now config-only: it enforces `GITHUB_APP_COMMIT_AUTHOR` from `github-app.env` and is skipped entirely when unset (no committer identity is baked into the source). (DIVE-1461)

## 0.10.5 — delegated push behind a gated `5dive push` verb (2026-07-18)

- feat(push): `5dive push <id|DIVE-N> [--branch=<b>] [--dry-run]` — one gated bot identity that pushes ONLY the task's branch, ONLY after its ship gate has cleared, with a fail-closed `author=lodar` pre-push scan so the Vercel team check stays green. Transport auth is a control-plane GitHub App installation token (short-lived ~1h, minted on demand by the root-only `_push_mint_token` helper over NOPASSWD sudo, never persisted, never handed to the agent) — decoupled from commit authorship. Refuses protected branches (main/master/HEAD), missing/open/rejected gates, and any commit not authored by lodar. Fully audited via the `push` dispatch. Bobby gripe #1 (DIVE-1376).

## 0.10.4 — company-view fields on objective ls (2026-07-18)

- feat(objective): `objective ls --json` now carries the company-view fields the dashboard reads: `planner`, `review` (re-plan cadence cron), `max_new_per_cycle`, and `verified_total` — originated tasks a distinct verifier accepted across all cycles, the same integrity predicate as `objective status` (DIVE-1441), never the planner's self-report (DIVE-1452).

## 0.10.3 — park can't destroy an open gate (2026-07-18)

- fix(task): `task park` now REFUSES to park a task that has an open, unanswered human gate. Park and a gate share `status='blocked'` plus the `need_*` columns, so park's UPDATE was NULLing a live gate's fields — silently destroying it (no answer, no audit row), after which the heartbeat wake unparked it to `todo` as if a human had cleared it. The task is already blocked on the human, so no park is needed; resolve the gate first, then park (DIVE-1453). Regression harness: `tests/task_park_gate_guard_unit.sh`.

## 0.10.2 — company onboarding wizard (2026-07-18)

- feat(company): `5dive company` — an onboarding wizard that stands up a self-steering company in a few guided steps: a project namespace, one objective (the number you steer, bound to a read-only metric), a planner, and a re-plan cadence, with an optional first goal. Pure sugar shipped LAST per the v0.10 plan: a thin macro over `project add` + `objective add` + `goal add` (no new state or engine). Run it bare for the prompt-driven wizard, or pass flags + `--yes` for a scripted stand-up (OSS-34).

## 0.10.1 — objective status truth surface (2026-07-18)

- fix(task): a T2-floor-refused ROUTED approval/manual gate now ESCALATES to the human with a tap button (fresh nonce, lead un-routed, ping re-armed) instead of dead-ending between an un-clearable lead and a button-less human — the DIVE-1429 stall class (DIVE-1437).
- fix(objective): `objective status` now reports `verified_total` (cumulative distinct-verifier-accepted originated closes) alongside per-cycle `verified_this_cycle`, so a steady cycle honestly reads 0-this-cycle without hiding prior real progress. The per-cycle field keeps its anti-Goodhart reset (DIVE-1441).

## 0.10.0 — self-steering company loops (2026-07-18)

The fleet now steers itself against a real business metric: objectives with measured readings (the planner never runs the metric), schema-validated plan diffs, distinct-verifier acceptance, explicit preflight + stop-conditions (never a silent stall), one read-only status surface, and human gates on the phone. Tag was gated on dogfooding this end-to-end against our own funnel metric: a live planner cycle originated real published work, and a founder test signup proved attribution live while the metric refused to count it — the company cannot fake its own progress (OSS-31, OSS-35).

- feat(heartbeat): transport-liveness canary — the heartbeat tick now alarms the coordinator when a paired claude agent's Telegram poller is DEAD (DIVE-1434).

- feat(heartbeat/supervisor): fleet-stall self-heal, gaps #2 and #3 (DIVE-1416; gap #1 is DIVE-1415's cascade-unblock fix above). DOGFOOD INCIDENT 2026-07-17: the fleet sat ~100% idle ~3h while actionable v0.10 work was stranded, and NOTHING self-corrected or alarmed — supervisor read "15 healthy / 0 stuck" because "idle while work is stranded" wasn't a signal it modeled at all; a human had to notice. **Gap#2 — maker→verifier deliveries never sit invisible:** `_task_route_to_verifier` now stamps a dedicated `handoff_delivered_at` (reset fresh on every re-delivery after a reject/bounce-back — `updated_at` can't do this, any row touch bumps it); the new `_hb_stall_sweep`'s pass (a) flags any delivery still unacknowledged (`handoff_ack_at` NULL) past `HEARTBEAT_VERIFY_STALE_MIN` (default 60m) and pings BOTH the verifier and main, throttled once per delivery via `handoff_stale_pinged_at`. **Gap#3 core — fleet-idle-while-actionable-work-is-open alarm:** pass (b) tracks, in `task_prefs`, how long the fleet has had zero `in_progress` tasks and zero running loops while at least one todo task or fleet-actionable human gate sits open; once that's persisted past `HEARTBEAT_STALL_MIN_MINUTES` (default 30m, the design's "K min") it alarms main — re-alarming on the same cadence while it holds (never silent), clearing the moment the fleet is busy again. A gate only counts as stranded when it's tier<=1 (an agent can clear it) or was never surfaced to the human at all (`need_asked_at` AND `gate_pinged_at` both NULL) — a PINGED tier-2 gate genuinely awaiting the human (e.g. overnight) is parked, not stranded, and must not re-alarm main every cycle (review amendment: the same idle-night alert-fatigue class already killed once). **Gap#3 canary — pinger liveness:** pass (c) is a DELIBERATELY independent re-check of whether the gate-ping TTL reminder batch (DIVE-1434: it silently stopped writing `gate_pinged_at` fleet-wide and nothing noticed for days) is actually still alive — eligible-for-ping gates existing while `MAX(gate_pinged_at)` hasn't advanced fleet-wide in over an hour trips it. **Supervisor "idle+stranded" class:** the per-agent classify chain in `cmd_supervisor.sh` is factored out into a pure `_sup_classify` (mirrors the existing `_sup_act_plan` pattern — directly unit-testable, no systemctl/tmux/pgrep stubbing needed) and gains a new `stalled`/`idle-stranded` class: an agent with NO active work (no in_progress, no running loop) but an old todo task (`SUPERVISOR_T_STRANDED_MIN`, default 45m) still sitting assigned to it, previously indistinguishable from legitimate idle. Observe-only, same posture as slow/drift/update-pending — never feeds the P2 act ladder. Additive schema: `tasks.handoff_delivered_at` + `handoff_stale_pinged_at`. +23 cases in `tests/heartbeat_stall_sweep_unit.sh`, +15 in `tests/supervisor_classify_unit.sh`.
- fix(task-engine): completing a blocker via a NON-`task done` terminal close now cascade-unblocks its dependents too (DIVE-1415). DIVE-1355 wired `_task_cascade_unblock` only into `_task_status_cmd` (the `done`/`cancel` verbs), so a task closed through any OTHER terminal path left its dependents stuck `blocked` behind a satisfied edge — the stall that froze OSS-32/OSS-33 behind OSS-27 for ~3h overnight (OSS-27 closed via `task verify` PASS, so the cascade never ran). Added the cascade to the three missed close paths: `task verify` auto-done (the OSS-27 path), a manual-gate answer that closes the task done, and a loop RUN / loop GATE-step terminal close (cross-DAG dependents the loop-advance never touches). The heartbeat `_hb_blocked_sweep` safety-net still repairs pre-existing rot; this makes the EVENT cascade fire on every terminal close so stranded work never waits for a sweep. Same guardrails inherited (never a parked task, never an unanswered human need-gate). +4 unit cases in `tests/task_cascade_unblock_unit.sh` (T9/T9b/T9c/T10), 16/0 total.
- feat(objective): `5dive objective status <name>` (+ `--json`) renders a read-only v0.10 dashboard over a running self-steering objective loop: target, current, trend, signed gap (per direction), current cycle + outcome, active roles (open originated-task assignees + planner), verified-this-cycle, spend vs ceiling/budget, and next gate or an explicit stop-reason (never a silent blank). Integrity boundary: it never runs the metric-cmd and never originates or mutates, and 'verified this cycle' counts ONLY originated tasks a distinct verifier accepted (status=done), never the planner cycle's self-reported outcome (the anti-Goodhart point, the company cannot fake its own progress). Reuses the existing `_objective_trend` / `dbfmt` / dispatch; `tests/objective_status_unit.sh` 14/0, siblings unchanged (objective_unit 13/0, objective_replan_unit 23/0). MVP item 7 of the v0.10 self-steering line (OSS-31/OSS-32).
- feat(init): `5dive init` for `--type=openclaw` now offers a BYO provider + API-key path, not just the OpenAI /codex/device oauth (DIVE-1390). openclaw defaulted to the device-code sign-in, which dead-ends when the OpenAI account is blocked for inference — with no escape hatch, even though the dashboard already offered BYO. openclaw now gets its own auth branch (split out of the `openclaw|antigravity|grok` oauth-only lump): an `_init_pick` between "Sign in with OpenAI" (unchanged device-code flow) and "Bring your own provider", where BYO picks a provider from the `OPENCLAW_PROVIDER_ID` catalog (openrouter/anthropic/openai/google/deepseek/moonshot/qwen/minimax/huggingface/zai — `nous` omitted, no native id) + key and writes it via the existing `agent auth set openclaw --api-key=- --provider=<id>` → `_apply_byo_openclaw` path (no new capability, init parity only).
- fix(task-engine): a persona/character-pack QUEUE-READINESS approval on our early-stage content surfaces (OpenAgent / character-packs / the daily persona drip) is no longer floored to a hard-human gate on the word 'publish' — it is downgraded to a lead-routed tier-1 and routed to the org lead, the mirror of the DIVE-1359 eng-ship class (DIVE-1381, surfaced by DIVE-1366). The T2 category floor matches 'publish' in the ask/title and forced these curation approvals hard-human (unclearable by the lead, since tier-2 is human-only), even though ship-gating classes OpenAgent/character-packs as early-stage = safe to push, no approval gate to the paired human. New `_gate_content_curation_hit` classifier (persona / character-pack / openagent / promote-queue / drip-queue / curat* / skill-set / gallery-pack) plus a residual-floor re-test: the carve-out fires ONLY when the sole reason the floor tripped was a content-publish-LATER term (`_GATE_CONTENT_PUBLISH_RX` = publish / public post / announce / launch post — the actual publish happens downstream via the drip, not now). The true-human floor still WINS for a genuine publish-NOW / brand / press / customer-comms (newsletter/blast) / money / secret / destructive ask (re-tested with only the publish-later terms stripped), a lead's own curation gate is exempt (no distinct reviewer), and a non-curation 'publish' ask still floors. Routing is intrinsic to the kind, so it bypasses the OFF-by-default `gate_builder_routing` pref. +9 unit cases (`gate_ship_routing_unit` 43/0).
- feat(objective): loop PREFLIGHT + explicit STOP-CONDITIONS (OSS-33, OSS-31 MVP items 4 & 5) — the guards that make a self-steering objective safe to leave running unattended. **Preflight** refuses to `resume`/drive an objective whose planner ROLE cannot do the work, always with a machine reason + a human detail (never a silent no-op start): `role_unassigned` (no planner and no org coordinator), `role_unreachable` (planner not in a populated org chart), `missing_verifier` (the planner is the only agent in the org, so nothing it builds could ever be graded by a distinct verifier), `over_budget` (spent ≥ budget), `role_asleep` (planner unit desiredState=stopped), and `role_unauthenticated` (planner has no auth profile or rotation account) — the last two best-effort from the agent registry, degrading to a pass when it is unreadable. Preflight is deliberately CONSERVATIVE: a bare box with no org chart and no configured planner is "not yet org-wired" (single-operator/manual), so it PASSES with an advisory and never false-fails. `5dive objective resume <name> --force` (and `objective replan --force`) bypass a refusal for a deliberate human. **Stop-conditions** add the two reasons OSS-27 did not cover, so the autonomous loop never spins silently: a still-pending approval gate from a prior cycle (a Tier-2 hard gate awaiting a human, or a Tier-1 checkpoint awaiting a lead/precedent clear) → `gate_pending` (the loop WAITS instead of stacking a fresh proposal on one not yet approved), and metric flat/adverse across the last N cycles → `no_progress` (the objective is PAUSED — a genuine terminal state so the heartbeat stops respinning — with an explicit reason; `--no-progress-limit=N`, default 3, 0=off). All guards run on the AUTONOMOUS path only (a live planner is about to be invoked); a manual `--diff`/`--from-gate` remains an operator override. Each guard appends an `objective_cycles` audit row with its outcome. No schema change. Stacks on OSS-27 (`objective replan`); the `0.10.0` tag stays gated on the full v0.10 line (status surface, `company` sugar, dogfood-green on our own funnel metric).

- fix(agent-create): validate a pi `--model` against pi's live registry so a stale or misspelled slug fails create loudly instead of pinning a dead default (DIVE-1402, pi twin of DIVE-1395). `pi_apply_model_default` merged any `--model` into the agent's `settings.json` `defaultModel` blindly; a slug pi's registry does not carry (e.g. `google/gemini-2.0-flash-lite-001`, which pi lacks — it carries `google/gemini-2.5-flash-lite`) left the fresh agent booting without the intended model. New `pi_validate_model_or_fail` enumerates pi's catalog (`pi --list-models` with the provider key injected, a no-completion metadata read, filtered to the provider column with pi's leading `~` alias marker stripped) and rejects an absent slug with the closest same-provider matches. Fail-OPEN: a missing key, an offline `pi --list-models`, or an empty listing skips the check so create is never blocked on a transient; a `:<thinking>` suffix is compared on the slug alone. New `pi_catalog` + `pi_validate_model_or_fail` helpers (`PI_BIN`-overridable for tests); +7 `pi_auth_provider_unit` cases (26/0), verified end-to-end against the real 270-model openrouter catalog (QA slug rejected with suggestions, `gemini-2.5-flash-lite` accepted).
- fix(agent): a fresh pi agent created against a gateway provider no longer boots to "No models available" (DIVE-1396, re-file of DIVE-1385). `agent create --type=pi --provider=openrouter --api-key=…` writes the provider's key (`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, …) into the single pi connector `/etc/5dive/connectors/pi.env` (`TYPE_API_FILE[pi]=pi.env`), but the systemd template `5dive-agent@.service` loaded the anthropic/openai/gemini connectors and never `pi.env`, so the key never reached the pi process — pi's model registry found no authenticated provider, `getAvailable()` returned 0, and the TUI booted to "No models available" with no runnable model. A regression from DIVE-1200 (the pi connector was introduced but the unit template was not updated); opencode escaped it because `TYPE_API_FILE[opencode]=openai.env`, which the unit already loads. Fix: add `EnvironmentFile=-/etc/5dive/connectors/pi.env` (optional `-` form, so a box with no pi.env still boots cleanly) plus a `pi_auth_provider_unit` assertion that keeps the unit's connector line and `TYPE_API_FILE[pi]` in lockstep (19/0). Proven empirically with pi 0.80.6: no key → the exact "No models available", key present → 270 openrouter models; the invalid-slug path emits a different diagnostic ("No models match pattern"), confirming the reported symptom is env propagation, not the model slug.
- fix(agent-create): validate an opencode `--model` against opencode's live catalog so a stale or misspelled slug fails create loudly instead of silently degrading the agent (DIVE-1395, re-file of DIVE-1384). Root cause: opencode ignores a pinned model it cannot resolve and falls back to an unrelated default (often an image model), which then answers a real tool-using task with "No endpoints found that support tool use." The reported case pinned `openrouter/google/gemini-2.0-flash-lite-001`, a slug absent from opencode's models.dev catalog (it carries `gemini-2.5-flash-lite` etc.), so the fresh agent booted onto "Nano Banana Pro" and could not run tools. `opencode_apply_model_default` now enumerates the authenticated provider's catalog (`opencode models` with the api-key injected, a metadata read that charges no completion) and rejects an absent slug with the closest same-provider matches. It is fail-OPEN: a missing key, an unreachable catalog, or an empty listing skips the check so a models.dev outage or catalog lag never blocks create. New `opencode_catalog` + `opencode_validate_model_or_fail` helpers (`OPENCODE_BIN`-overridable for tests); +5 cases in `opencode_openrouter_unit` (17/0), verified end-to-end against the real catalog (QA slug rejected, `gemini-2.5-flash-lite` accepted).
- fix(agent): fresh `--type=hermes` agents no longer boot unconfigured onto the Nous "hermes setup" wizard after a BYO provider create (DIVE-1394). Two defects compounded: (1) the boot-time seed in `5dive-agent-start` read the shared/profile `config.yaml`+`auth.json` with **sudo-only** `test`/`cmp`/`cat`, but standard-isolation agents have NO passwordless sudo — so for every default (non-admin) hermes agent the seed silently no-op'd and the agent started with no provider (this is the codex/grok DIVE-1188 failure that was never propagated to the hermes seed); and (2) on the no-profile path the shared `/home/claude/.hermes/{config.yaml,auth.json}` stayed mode 0600 owner=claude, unreadable by the group-member agent even once the seed tried a plain read. Fix: `seed_one` now tries a plain group read first and only falls back to `sudo -n` for a not-yet-normalized 0600 file on an admin agent (mirrors codex/grok), and `cmd_create` normalizes the shared no-profile seed source to 0640 g=claude (the profiled path was already normalized by `normalize_profile_seed_perms`). The installer-truthfulness half of the report (upstream Nous `install.sh` mis-reporting build-tool status / npm timeout) is upstream and out of scope for this fix.
- feat(task-engine): maker→verifier handoffs now expose a durable `delivered` → `reviewing` receipt (DIVE-1378). Routing work records `delivered`; only the assigned verifier's own `task start` emits the one ACK and timestamps `handoff_ack_at`, so message delivery or a third-party status change cannot masquerade as review running. `task ls --json`, `task show`, and `task loops` expose the state without adding a second full task FSM.

- feat(task-engine): `task start` runs a fail-loud preflight that surfaces identity/auth/repo gaps UP FRONT, before the agent burns a turn discovering them mid-task (DIVE-1375, Bobby gripe #3). Every check is best-effort and ADVISORY — it prints `warn: preflight:` heads-up lines to stderr and NEVER blocks the start (fail-open). Checks, from the caller's cwd: (1) assignee mismatch (the heartbeat only wakes the assignee, so a start by someone else is flagged as a possible mis-claim); (2) an unanswered human need-gate open on the task, which will make `task done` REFUSE to close it (DIVE-555) — better to learn before doing the work; (3) git dubious-ownership (git refuses the repo), the exact wall Marcus hit on DIVE-1356, handed the one-line `git config --global --add safe.directory` fix; (4) a DIRTY worktree (uncommitted paths a commit could sweep on a shared checkout); (5) unset `git user.email` that would trip the remote author check (Vercel team gate); and (6) an offline push-credential heuristic (SSH remote with no `~/.ssh` key, or HTTPS remote with no `gh auth`). Suppress with `task start --no-preflight`. No schema/DB change; no regression (task_core_unit 30/0).
- fix(task-engine): an eng ship/merge/diff/deploy approval filed by a non-lead builder is forced down from a hard-human (tier-2) gate to a lead-routed tier-1 and routed to the org lead, overriding even an explicit `--tier=2` (DIVE-1359). Builders were escalating eng ship approvals to the paired human (dev DIVE-1349/1314, codex DIVE-907) via a gate class that (a) pinged the human and (b) was unclearable by the lead since tier-2 is human-only by system rule. New `_gate_eng_ship_hit` classifier + downgrade block mirror the DIVE-1243 `access` class: the true-human floor (money/secrets/destructive/brand) is checked FIRST and always wins (a "ship the pricing change" gate stays human), and the routing is intrinsic to the kind so it bypasses the OFF-by-default `gate_builder_routing` pref (the fix is live under the default, not dormant behind a flag). A lead's own eng-ship gate is exempt. +6 unit cases (`gate_ship_routing_unit` 33/0).
- fix(goal/dashboard): make `goal add` async so the dashboard goals page never 502s, even when the planner agent is busy (DIVE-1349, follow-up to the v0.9.26 bounded-wait, which was insufficient — a busy planner still held the request ~155s past the gateway cap). The planner is a live agent turn whose latency we don't control, so decoupling it from the synchronous gateway-fronted request is the real fix. `goal add` now spawns the planner loop WITHOUT blocking and returns a job id immediately; `goal status <job>` polls `queued|running|done|failed` and runs the validate→materialize tail once the plan lands (idempotent, materialize-once via a stale-aware claim); `goal add --from-job=<job>` creates from the previewed plan (the plan JSON is too large for the tunnel's arg cap, so the job id is the handle). `--wait`/`--plan` stay synchronous for scripts. A busy planner no longer blocks the HTTP request: dry-run returned in ~8s vs the old 155s→502. The planner's `project.title/description` are normalized to `name/goal` so real (schema-drifting) planner output is no longer false-rejected. New additive `goal_jobs` table (present in both the fresh-init schema and the gated migration; `CREATE TABLE IF NOT EXISTS`). All guardrails are inherited from the sync path: `--from-job` routes through the same `_goal_finish_with_plan`, so a plan over the checkpoint OR carrying any Tier-2 task still files a human decision gate and materializes NOTHING — the gated build still requires `goal add --from-gate=<id>` after a human `approve` (`--from-job` is not a bypass). The dashboard app-side async wiring ships separately inside the DIVE-1367 goals-page redesign.
- feat(objective): `5dive objective replan <name>` — the outcome-loop re-plan cycle, the v0.10 headline atom (OSS-27, OSS-19 phase A2, DIVE-982 successor). The planner reads the objective's latest metric reading + trend + target gap + its own open originated tasks + last-cycle outcomes (all INJECTED — it never runs the metric) and emits a bounded, schema-validated DIFF `{create, reprioritize, cancel}` that deterministic code validates and applies. The anti-Goodhart spine is inherited WHOLESALE from `5dive goal`: create ops are wrapped into a goal-plan and run through `_goal_validate_plan` (max_new_per_cycle cap = reject-not-truncate, tier-lowering guard via the shared T2 classifier, DAG acyclicity/depth, assignability) then `_goal_materialize`; a T2 create ALWAYS gates at HARD tier 2 (never `--yes`-waived, applied only via `objective replan --from-gate=<id>` on a HUMAN 'approve', re-validated from scratch); every origination batch rides ONE count-checkpoint decision gate (phase-A default checkpoint 0 → any origination gates; `--yes` waives only the count check); and reprioritize/cancel are HARD-restricted to tasks THIS objective originated (`originated_by_objective`), so a planner can never touch a human or other-objective task. Stop-conditions are explicit and audited (never a silent stall): paused / target-reached / budget-exhausted each record a cycle with a clear reason and originate nothing. **Shadow-first run mode (OSS-35):** an objective carries `run_mode` (live|shadow, default live); `shadow` (set via `objective add --shadow` / `objective shadow <name>`, or the ad-hoc `replan --propose-only` flag) forces PROPOSE-ONLY — the ENTIRE diff, including own-task reprioritize/cancel that live mode applies within the objective's autonomy, rides ONE gate a human confirms, nothing auto-applies, and `--yes` cannot waive it. This is the fail-safe lever so the first self-steering dogfood run can go green without auto-executing against the live company. New schema: `tasks.originated_by_objective` + `originated_cycle` provenance columns, `objectives.run_mode`, and an append-only `objective_cycles` audit table (one row per cycle: reading, proposed/applied counts, gate anchor, tokens, outcome). Measurement (OSS-26) was the store; this is the loop. NOTE: this ships as 0.9.32 (incremental) — the `0.10.0` tag stays gated on the full v0.10 line (preflight, status surface, `company` sugar, dogfood-green on our own funnel metric) per the v0.10 vision.

- fix(goal/dashboard): the goals page no longer 502s on "Add goal" (DIVE-1349). `goal add` plans by spawning a loop task for a planner agent and block-polling it behind a single HTTP request; two defects made that request hang past the gateway timeout — the planner agent was never woken on spawn (it sat until its own heartbeat tick), and a bare `loop spawn --wait` defaulted to a 30-minute deadline. Now: (1) `cmd_loop_spawn` best-effort WAKES the assignee the moment a task is spawned (`_loop_wake_agent` → the same `_hb_wake` nudge the heartbeat uses, run directly when root else via `sudo -n 5dive heartbeat wake-task`; skipped for a busy agent or a bare type token, and never fatal); (2) the bare-`--wait` default is bounded to `LOOP_SPAWN_WAIT_DEFAULT` (120s) so a slow plan returns a clean timeout the caller renders, never a socket held to a 502; and (3) the goal planner asks for an explicit in-window `--wait=150` (`GOAL_PLANNER_WAIT_SECS`). Net: a woken planner returns its plan in-window; a genuinely slow plan yields a graceful error instead of a gateway 502.
- fix(task-engine): forbid bare reasonless/dateless blocks — every block must carry a revisit anchor (DIVE-1357, the prevention fast-follow to DIVE-1355). A task can only enter `blocked` via exactly one of three anchors, each with a built-in revisit: a dependency edge (`task block --by`, revisits via the DIVE-1355 cascade), a human need-gate (`task need`, revisits on answer), or a park (`task park`, revisits when the heartbeat passes its `wake_at`). `task park` now REQUIRES both `--reason` and `--wake` (a reasonless/dateless hold was the exact state that filled the block graveyard); a bare `task block <id>` with no `--by` is refused with an error enumerating the three anchored options, and `task block <id> --reason=<why> --wake=<when>` (no `--by`) routes through `task park`. New `_task_has_block_anchor` predicate is the single source of truth the block-producing verbs satisfy, and the `task block`/`task park` help now codifies the attempt-first norm (blocking is the exception you must justify). Net: the DIVE-1355 "blocked with no live reason" surface set is permanently empty because that state is unreachable via the CLI.
- fix(task-engine): completing a blocker now cascade-unblocks its dependents, so the fleet keeps moving without a manual `task unblock` (DIVE-1355 — the root cause of the 2026-07-16 idle night: OSS-26 finished but its dependent OSS-27 stayed `blocked` forever, so dev's heartbeats woke to zero dispatchable work and slept). On any `task done`/`task cancel` (and verify→done), `_task_cascade_unblock` drops the now-satisfied blocking edge and, when a dependent has no blocking edges left, flips it `blocked`→`todo` and pings its assignee — the same unblock-flip `task unblock`, the relay advance, and the park-wake sweep already use. GUARDRAIL: only dependency edges auto-clear — a dependent still holding an unanswered human need-gate or a park is left blocked (the satisfied edge is still dropped, so it releases correctly once the gate is answered / the park wakes). A new heartbeat pass `_hb_blocked_sweep` is belt-and-suspenders: (a) auto-recovers any task still `blocked` whose every blocking edge points to a done/cancelled task (repairs pre-existing rot + any live-cascade miss, pinging main), and (b) SURFACES to main — never auto-unblocks — tasks blocked with no live reason at all (no dependency edge, no human gate, no park: the manually-blocked-and-forgotten majority in tonight's audit), throttled to once/24h.
- feat(init): `5dive init --quiet` (alias `--demo`) hides the noisy install/`agent create`/pairing sub-processes behind a per-step spinner + a clean ✓/✗ line, redirecting their raw output to `/tmp/5dive-init-<ts>.log` and surfacing that path only on failure. The default stays verbose (full streaming) for debugging a broken first run. This suppresses the wizard leakage lodar flagged on the DIVE-1336 demo capture — garbled Claude Code installer progress, marketplace-refresh chatter, `==>` create logs, and the expected-pending self-check warnings — so a raw capture shows only wizard chrome + spinner + success screen. Also fixes the Python `datetime.datetime.utcnow()` DeprecationWarning that leaked from the marketplace pre-register step (now `datetime.now(timezone.utc)`), so it no longer surfaces even in verbose mode (DIVE-1352).
- fix(agent): `agent create --type=hermes|openclaw --provider=openrouter --api-key=… --model=<slug>` now honors the `--model` override instead of silently dropping it. `apply_byo_provider` only forwarded the operator model to the claude path, so `_apply_byo_hermes`/`_apply_byo_openclaw` always pinned their hardcoded catalog default (`openrouter/auto`); the slug was accepted and charset-validated, then thrown away. Both functions now take the override as arg 5 and prefer it over `HERMES_PROVIDER_MODEL`/`OPENCLAW_PROVIDER_MODEL` (applied on hermes' moonshot env-var AND general auth-add paths, and on openclaw). Backward-compatible: the auth re-login 4-arg call still resolves to the catalog default. This is what wires the dashboard's OpenRouter model picker (DIVE-1318) end-to-end for hermes/openclaw.
- feat(task): `5dive task clear-recs --channel-proof=<chat_id> [--only=<id|DIVE-N>]` bulk-applies the recommended answer to a paired human's pending agent-clearable gates in one shot — the "go with recs"/"approve DIVE-N" path. Only tier<2 gates that carry a `--recommend` and are not lead-routed are eligible; each clear reuses the single-gate `cmd_task_answer` path, so provenance, signature, and advance are byte-identical to a per-gate human tap. `--channel-proof` is a chat_id that must verify against the bot's `access.json` paired-human DMs (`_gate_channel_proof_ok`), and `cmd_task_answer` honors it as human evidence ONLY when the gate is tier<2 — a tier-2 hard gate always keeps its per-gate nonce tap and is refused/skipped. Unblocks DIVE-1334 `/inbox` bulk-clear (DIVE-1305, shipped via DIVE-1340).
- fix(agent): human-gate Telegram tap buttons that Telegram rejects are no longer lost silently. When a button-bearing gate ping (`task need` decision/approval/secret/manual) failed for a non-migration reason, `_mirror_post`'s DIVE-117 fallback re-sent the SAME text WITHOUT the keyboard and discarded the error response, so the human got a no-button text ping and we never learned why Telegram rejected the `reply_markup` (lodar's recurring DIVE-1320 no-button — systemic across every gate whose keyboard-send is rejected). The fallback now first logs the actual rejection (`error_code` + `description` + reply_markup byte-length + target chat/thread) to `/var/log/5dive/gate-notify.log` (stderr on CLI-only/OSS boxes) before the no-keyboard retry, so the real cause is finally observable and root-cause-able. Best-effort and non-fatal: it runs after the gate row already committed and never fails the caller (DIVE-1338).
- fix(agent): resolve the codex bin via a `~/.local/bin/codex` one-hop symlink instead of the hardcoded `/home/claude/.nvm/versions/node/v24/bin/codex`. When node upgrades (e.g. to v24.18.0) the `v24` nvm alias can lag and `npm i -g @openai/codex` lands the binary in the real version dir, so the hardcoded path went stale and `agent create --type=codex` reported codex not_installed / auth not_installed even though codex ran fine on PATH. The install recipe now symlinks the freshly-installed codex into `~/.local/bin` (resolved deterministically as `dirname $(nvm which 24)/codex`, same convention as grok/pi/opencode) and `TYPE_BIN[codex]` points there (DIVE-1329).

- fix(agent): `agent send`/`_deliver` now reliably submits to codex (and other non-claude) agents. `inject_and_submit` relied on Claude's `[Pasted text #N]` placeholder to know an Enter still needed re-sending; codex renders the paste inline with no such marker, so a single Enter fired 0.3s after the burst raced the paste-commit and was swallowed, leaving the message unsent and the agent silently deaf. Non-claude TUIs now settle, submit, then confirm the turn started (via `_hb_agent_idle`), re-sending a few times before giving up — mirroring the heartbeat fix (DIVE-1217). Enter and C-m are byte-identical CR to tmux, so the prior manual-C-m workaround was really the settle+confirm (DIVE-1325).
- feat(init): redesign the first-run wizard as a polished four-stage TTY onboarding flow with arrow-key menus, explicit Codex/Claude authentication choices, live-masked API-key and bot-token input, early agent-name validation, deterministic provider pickers, terminal-aware styling, a pre-create review/cancel checkpoint, and clearer completion guidance (DIVE-1326). `TERM=dumb` retains a numbered fallback and `NO_COLOR` disables styling.
- fix(agent-start): fresh `agent create --type=codex` without `--auth-profile` no longer boots silently deaf on a bogus `OPENAI_API_KEY` (401). The codex auth-seed now reads the stable canonical profile file (`/var/lib/5dive/auth-profiles/codex/codex/auth.json`) directly instead of the lazily-created `/home/claude/.codex/auth.json` symlink, so an agent booting before the symlink exists still seeds a valid chatgpt-oauth credential before codex first runs. It also re-seeds when codex has already written a bad `auth_mode=apikey` auth.json while a valid chatgpt source is available — closing the case where the old mtime-only check (and `config set auth-profile=codex` + restart) never corrected a once-deaf agent (DIVE-1322).

## 0.9.14

- fix(agent): `agent import <slug|pack> --type=<codex|pi|opencode|claude|…>` now honors the requested runtime instead of silently taking the pack's baked-in type, making a marketplace/persona hire harness-agnostic (DIVE-1317). Explicit `--type`/`--model`/`--effort` override the manifest for pack imports (they were previously consumed only in `--from-persona` mode), the resolved type is validated up front with a clear error, and `--from-persona` behavior is unchanged (still defaults to claude).

- feat(agent): `agent create --type=opencode --provider=openrouter --api-key=… --model=…` now stores the key as OpenCode's native `OPENROUTER_API_KEY` and pins the new agent's default as `openrouter/<model>` in its merge-safe `opencode.json` (DIVE-1206). This enables OpenRouter-hosted DeepSeek, GLM, Kimi, and Qwen models without an interactive `/connect` or `/models` step; the existing OpenAI provider and `agent auth set opencode` paths remain compatible.

## 0.9.13

- fix(audit): non-root agent-* CLI callers now record their mutating actions (task done/answer, agent send, …) in the tamper-evident audit log via a new hidden, append-only `5dive _audit_append` primitive over NOPASSWD sudo (DIVE-1268). The log is 640 root:claude, so a non-root agent can't write it directly; rather than loosen it to a group-writable 660 (which would let any group-claude agent rewrite/truncate past entries), `_emit_audit_line` routes the non-root append through the privileged primitive, which re-stamps `.user` from `SUDO_USER` (the payload can't spoof the actor), drops non-objects, and appends only — never execs caller input (upholds the write_admin_sudoers invariant). Standard agents get a single scoped `write_standard_sudoers` grant with no trailing wildcard; admin agents are covered by the existing whole-CLI grant. Also fixes a `Permission denied` stderr leak — `_emit_audit_line` gates on writability before the append, so a caller who can't write never triggers the failing-redirect diagnostic (which bash prints before `2>/dev/null` takes effect).

## 0.9.12

- fix(init): `5dive init` pi + openrouter now wires the provider and key through `agent create` instead of an early `auth set`, so the created agent boots with `defaultProvider=openrouter` and the key persisted to *its* connector (DIVE-1269). The wizard previously ran `5dive agent auth set pi --provider=…` before create, then created the agent with only `--model` — so `pi_apply_model_default` ran with an empty provider, leaving `~/.pi/agent/settings.json` `defaultProvider=""` and the key on the *default* connector (never the agent's). pi then errored "No API key found for the selected model". The pi provider+key now defer to create (mirroring the `agent create --provider/--api-key` path and the claude-BYO deferred path), so create runs both `pi_apply_provider_key` (persists the key) and `pi_apply_model_default` (sets provider + model). Key stays on stdin, never argv. `tests/init_pi_unit.sh` updated to assert the deferred-to-create wiring and reject any `auth set pi` regression.

- fix(install): the installer's `5dive.sha256` fetch is now fail-soft under `set -euo pipefail` (DIVE-1271). `refresh_managed_files` assigned `_want="$(curl … 5dive.sha256 | …)"` as a plain assignment; when the checksum is absent (the offline install-smoke bundle omits it) curl exits 37 and `pipefail`+`errexit` aborted the whole install at "Installing CLI binaries" — before the absent-checksum warn branch could treat it as non-fatal. A trailing `|| _want=""` restores the intended "absent checksum only warns" contract (the fetch, not the verify, was the abort). Regression from the DIVE-1261 checksum feature (0.9.7) that had reddened install-smoke on main since. `tests/install_checksum_unit.sh` now reproduces the offline no-sha256 case under the real installer flags (the prior grep-only assertion false-greened).

## 0.9.11

- fix(agent): a freshly-created pi agent now gets the full 5dive default skill set (find-skills, 5dive-cli, compile-knowledge, openagent), not just a stray openagent leaked from the shared project dir (DIVE-1265). pi had no skills-map entry, so its default-skill installs fell through to the claude-code default (`~/.claude/skills`), a directory pi's resource loader never scans (pi reads `~/.pi/agent/skills` and `~/.agents/skills`, plus the `<cwd>/.pi|.agents/skills` project dirs). pi is now a manual-install type like grok: `npx skills add --agent pi` lands skills in `~/.pi/skills` (also unread by pi), so pi is git-clone+cp'd into `.agents/skills` instead. Added `[pi]=pi` + `[pi]=".agents/skills"` and `pi` to `_skill_needs_manual_install`, so the create-path installer, the `5dive-refresh-skills.sh` backfill, `5dive agent skill add`, and `list/rm` all agree on `~/.agents/skills` — a verified pi read dir, matching the notify-user seed already written there.

## 0.9.10

- fix(agent): pre-seed pi's project-trust store at provision time so a freshly-created pi (telegram-relay) agent never blocks on pi's interactive "Trust project folder?" gate on first run (DIVE-1264). The headless systemd relay can't answer the prompt, so it hung before ever polling. `agent_setup` now writes `~/.pi/agent/trust.json` (`{"/home/claude/projects": true}`) during the pi telegram channel setup — pi's trust lookup walks parent dirs, so trusting the projects root covers every per-agent workdir beneath it, exactly mirroring the claude `.claude.json` hasTrustDialogAccepted pre-seed. Merge-safe and idempotent.

## 0.9.9

- fix(runtime): `5dive-agent-start` resolves `bun` via a fallback chain (/usr/local/bin -> ~claude/.bun/bin -> ~claude/.local/bin -> PATH) instead of a single hardcoded `~/.local/bin/bun`, at BOTH the opencode and pi telegram-bridge launch sites (DIVE-1263). install.sh dropped bun at ~/.bun/bin while ensure_bun_for_agent used /usr/local/bin, so on a fresh install.sh box the pi/opencode telegram bridge exit-3'd and systemd crash-looped (a restart counter of 132 in the wild; opencode+telegram was latently broken the same way). install.sh now installs bun to /usr/local/bin (BUN_INSTALL=/usr/local) to match, which also puts bun on PATH for codex/grok/agy hook commands. Smoke: test-vm.sh asserts the bridge unit stays active 6s post-create (the create-path smoke passed before the bridge ever booted).

## 0.9.8

- feat(init): when pi's provider is `openrouter` (a multi-model gateway), `5dive init` now prompts for the model to route to and pins it at create via `--model` (DIVE-1262). openrouter can't route without an explicit model, so the prompt is required (empty rejected); the value flows into the pi agent's `defaultModel` via the existing pi_apply_model_default path. Direct providers (anthropic/openai/etc.) are unaffected — they use pi's provider default.

## 0.9.7

- feat(install): supply-chain integrity check for the curl|bash installer (DIVE-1261). `build.sh` now publishes `5dive.sha256` alongside the bundle, and the installer fetches the bundle to a temp file, verifies it against the published checksum, then does a same-fs atomic swap into place. A checksum MISMATCH is fatal (corrupt download or tampered mirror); an absent/unfetchable checksum only WARNS so a box can't be bricked if the `.sha256` isn't published. Covers both the default install and `--upgrade` (both flow through `refresh_managed_files`). Integrity-check v1 — guards corruption + mirror tamper, not signing-strength (a future out-of-band-key signature would close the absent-checksum downgrade path). New unit `tests/install_checksum_unit.sh`.

## 0.9.6

- fix(install): `curl … | sudo bash -s -- --upgrade` now reports the resolved version — `5dive upgraded: <old> -> <new>` — instead of a bare "5dive upgraded.", read directly from the swapped-in bundle so it reflects what actually landed (DIVE-1260).

## 0.9.5

- feat(init): `5dive init` now prompts for the isolation tier (admin / standard / sandboxed), with a default that mirrors `agent create`'s resolution — pi -> sandboxed (extensions run arbitrary code), the first agent on a fresh box -> admin (bootstrap fleet manager), every other agent -> least-privilege standard — and forwards the choice as `--isolation`. Replaces the hardcoded pi-only sandboxed line. New unit `tests/init_isolation_picker_unit.sh`.

- fix(pi): `install_default_pi_extensions` derives the runtime bin dir from a ONE-hop symlink read instead of `readlink -f` (DIVE-1202/DIVE-1259). `readlink -f` fully dereferenced pi's two-hop symlink chain (`.local/bin/pi` -> `<npm global bin>/pi` -> `../lib/node_modules/<pkg>/cli.js`) into the package dir, which has no node/npm/pi, so `pi install` ran with a broken PATH and failed "pi: command not found" — which the fail-closed guard mislabeled as an npm-integrity mismatch, blocking EVERY pi agent-create (default `FIVE_PI_DEFAULT_EXTENSIONS=1`). One-hop resolution lands in the real `<npm global bin>` dir that holds node/npm/pi; `readlink -f` is kept only for the is-executable guard; a hard node/npm/pi presence assert now fails a future layout drift with an accurate message instead of a misleading integrity error. Uncovered by DIVE-1202's convergence smoke once the DIVE-1258 node24 fix let provisioning advance far enough to hit it.

## 0.9.4

- feat(init): `5dive init` now lists `pi` as agent type option 8 (DIVE-1255). Fixes the wizard's `^[1-7]$` choice regex, adds a provider picker (default `anthropic`) that reuses the multi-provider `PI_PROVIDER_VAR` map, marks pi telegram-capable, and creates the wizard's pi agent with `--isolation=sandboxed` by default (pi extensions run arbitrary code with the agent's permissions, so keep it off the shared claude-group workspace). New unit `tests/init_pi_unit.sh`.

- fix(init): the `opencode` init branch now prompts for a provider instead of hardcoding "paste OpenAI API key" (DIVE-1257). `5dive init -> opencode` lists the supported providers (`openai`/`openrouter`, default `openrouter`) and forwards the choice; `5dive agent auth set opencode --provider=<p>` resolves the key into that provider's native env var via the new `OPENCODE_PROVIDER_VAR` map (no `--provider` keeps the legacy OpenAI default for back-compat). New helper `opencode_provider_var` + unit `tests/opencode_init_provider_unit.sh`.

## 0.9.3

- fix(agent): `pi` install recipe provisions Node 24 with `nvm install 24` instead of `nvm use 24` (completes the DIVE-1254 sweep). On a fresh box `nvm use 24` fails with "version v24 is not yet installed", so `5dive agent create <name> --type=pi` aborted before installing pi — the identical bug fixed for `codex` in 0.9.2, present in the pi recipe added by DIVE-1199. `nvm install 24` provisions the pinned runtime and selects it so the `npm install -g @earendil-works/pi-coding-agent` lands in v24's bin dir. New unit `tests/pi_install_node24_unit.sh`. Audited all 8 install recipes: only `pi` remained (opencode/hermes/openclaw/antigravity/grok use curl installers, no nvm), so this closes out the node24 provisioning class.

## 0.9.2

- fix(init): `codex` install recipe provisions Node 24 with `nvm install 24` before installing Codex (DIVE-1254). `nvm use 24` failed on a fresh box where v24 wasn't yet installed, aborting `--type=codex` provisioning; `nvm install 24` provisions and selects it, forcing the `npm install -g @openai/codex@latest` into v24's bin dir even when the default alias drifted. New unit `tests/codex_install_node24_unit.sh`.

## 0.9.1

- fix(agent): durable Telegram pairing for owner-less fork agents (DIVE-1244). `codex`/`grok`/`antigravity` created with no `allowed_users` previously skipped seeding `access.json` entirely, leaving a block-everything file-absent state that silently dropped the operator's DMs (incl. gate alerts) until a manual file pair. The three installers now ALWAYS seed `access.json` (mirroring `opencode`/`pi`): with ids they allowlist them, without they default `dmPolicy=pairing` so the first DM yields a pairing code instead of a silent drop. Seeds remain append-only and never override an existing `dmPolicy`, so a manual pairing survives config-set re-provisioning. `pending` is now also seeded for schema parity with the bridges.

- feat(agent): audited default pi extensions with fail-closed integrity pinning (DIVE-1246). `install_default_pi_extensions` (agent_setup.sh, tail of pi channel setup) installs the two audited, version-pinned defaults (`pi-web-access@0.13.0`, `pi-mcp-adapter@2.11.0`) via `pi install`, verifies each against its recorded sha512 in the resolved `package-lock.json`, and FAILS CLOSED (`pi remove` + abort) on any mismatch. Never installs latest; keeps each package's safe defaults (browser-cookies / samplingAutoApprove / autoAuth / direct-tools off). Opt out with `FIVE_PI_DEFAULT_EXTENSIONS=0`. Per `community/wiki/pi-extension-default-policy.md`.

- feat(agent): post-create self-health check for new agents (DIVE-1197). Replaces the DIVE-1190 telegram-only pair hint with a generalized self-check at the tail of `cmd_create`: flags a freshly-created agent that looks up-and-running but is actually MUTE (unit inactive), DEAF (empty channel allowlist), BLIND (telegram getMe fails), ASLEEP (no heartbeat) or UNAUTHED (auth deferred), each with the exact one-tap fix command. Prints a single PASS line when clean; all to stderr so `--json` stdout stays a clean envelope.

- feat(agent): reachability/autonomy health in `agent list` (DIVE-1219). `cmd_list` emits `health:{deaf,asleep}` per agent so the dashboard can badge silently-broken agents: deaf = a telegram/discord channel with an empty allowlist (nobody paired), asleep = heartbeat not enabled. Computed CLI-side from the `/exec` passthrough (zero API change); mirrors the DIVE-1197 create-time self-check for the live fleet. Deaf-detection reads the 0600 `access.json` via `sudo -n cat` (the dashboard runs the CLI as `claude` through the exec tunnel, so a plain read EACCESed and false-flagged every paired agent — verifier iter-2); only a positive read of an empty `allowFrom` marks deaf, so unreadable/missing stays unknown and never false-flags a paired agent.

## 0.8.23

- security(agent): freeze grok provisioning behind a code-durable guard (DIVE-1222). Grok Build CLI (xAI) has a disclosed codebase-exfiltration issue with no client-side fix as of its v0.2.98 changelog, and xAI shipped only a revocable server-side mitigation; as a precaution `cmd_create` now refuses `--type=grok` pointing to DIVE-1221, which blocks every provisioning path (create, hire, pack import, clone). Unfreeze requires a VERIFIED xAI client-side patch + pinnable version, never the server-side toggle alone; an off-by-default `FIVE_GROK_UNFREEZE_VERIFIED=1` override exists solely for that moment. New unit `tests/grok_freeze_guard_unit.sh`.

## 0.8.22

- fix(heartbeat): runtime-aware nudge submit — codex/grok/agy/opencode ingest the ~1KB /goal nudge as a paste and swallowed the single Enter, leaving it unsubmitted so the agent never executed; for non-claude runtimes let the paste settle then submit, confirming the turn actually started (agent left idle) before giving up, retrying Enter otherwise; claude path untouched (DIVE-1217).

All notable changes to `5dive` are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

Unreleased changes accumulate at the top until they're cut into a tagged
release.

## [Unreleased]

### Added
- **`pi` is now the 8th first-class agent type (Pi by earendil-works) — DIVE-1196/1199/1200/1201.**
  Type registration in header.sh; multi-provider API-key auth (no OAuth) via `PI_PROVIDER_VAR` +
  `--provider/--api-key` on create (cmd_auth.sh, DIVE-1200); telegram channel wiring for pi's
  extension-based bridge (agent_setup.sh, 5dive-agent-start, DIVE-1201); install.sh stages
  telegram-pi. New units pi_auth_provider_unit.sh (18) + pi_channel_wiring_unit.sh (13). Bumps to 0.9.0.


### Fixed
- **`agent send`/`ask` a2a now works between scoped-sudo agents on OSS boxes
  (DIVE-1337).** The self-elevation gate keyed on `isolation == standard`, so an
  `admin`-tier sender (the bootstrap first agent on every fresh OSS box, sudo
  scoped to `/usr/local/bin/5dive *` with no `sudo -u`) fell through to the direct
  `sudo -u agent-X tmux` path, was denied, and the failure was mis-reported as
  "session not found". Replaced the tier check with a capability probe
  (`a2a_needs_scoped`): if the caller can't `sudo -u` the target, route through the
  `_deliver`/`_capture` grant. Managed-host agents (NOPASSWD:ALL) keep the direct
  path and its --from/--reply-to plumbing; every scoped OSS agent self-elevates.
  Smoke gains an `a2a-scoped` row (5dive-api test-vm.sh) that sends AS the scoped
  agent user. Bumps to 0.9.18.
- **Heartbeat idle-detection is now runtime-aware, so non-claude agents get
  nudged for board tasks (DIVE-1211).** `_hb_agent_idle`'s pane-scrape fallback
  hardcoded claude's `❯` composer glyph, which codex/grok/agy/opencode never
  render, so every non-claude agent read as "active" on every tick and its nudge
  was deferred forever, never picking up its board tasks. The at-rest check now
  resolves a per-runtime idle marker (`_hb_idle_marker`: claude `❯`, codex `›`,
  antigravity `? for shortcuts`; grok/opencode trust byte-stability alone until
  their idle glyph is verified live) as the guard that a byte-stable pane is
  genuinely parked at the composer and not frozen on a dialog. Verified live:
  idle codex + agy now read IDLE (were stuck "active"). New unit
  `tests/heartbeat_idle_marker_unit.sh` (14 assertions).
- **Builder ship-gates are now org-lead-clearable, closing the DIVE-1145 gap
  (DIVE-1182).** DIVE-1145 routed only `decision` gates to the org lead; a
  builder's actual ship-gate is filed as `approval` (or `manual`), so it stayed
  human-only and pinged lodar instead of Marcus. `task need` now routes
  `approval`/`manual` builder gates to the lead too (pref `gate_builder_routing`
  on), persisting `routed_reviewer` on the row. `task answer` grants exactly the
  designated `agent-<routed_reviewer>` an exception to the approval/manual
  human-only floor for that one routed gate, recorded as `lead:*` provenance (not
  `human:*`). `secret` is never routed (must be human-delivered), tier-2 and
  true-human-category (money/destructive/brand) gates still ping the human, and
  every un-routed approval/manual gate stays hard-human — the DIVE-391/515/516
  self-clear boundary is unchanged. New `routed_reviewer` column (base schema +
  migration backfill). Unit: `tests/gate_ship_routing_unit.sh` (27/27).

## [0.8.17] — 2026-07-14

### Fixed
- **codex `auth login` uses device-code auth on headless/remote (DIVE-1178).**
  `sudo 5dive agent auth login codex` (and `5dive init`) now runs
  `codex login --device-auth` instead of plain `codex login`, which started an
  interactive browser OAuth with a `localhost:1455` callback server. codex
  itself flags this ("On a remote or headless machine? Use codex login
  --device-auth instead."); `--device-auth` prints a URL + one-time code and the
  CLI polls OpenAI, so SSH/headless users can auth with no local browser. Same
  shape grok already uses and the dashboard device-code flow (`auth start`)
  already drove.

## [0.8.16] — 2026-07-12

### Added
- **`proof on --user=<name>` (OSS-30, gh 5dive#30).** The nightly proof-publisher
  cron now runs as `--user` (default `root`, back-compatible). The cron's
  effective user must own the box's git push credentials; on boxes where root
  holds none (creds live with a service user), `--user=<that user>` fixes the
  otherwise-silent 03:00 push failure. Persisted in `proof.json` and sticky
  across re-`on`; unknown users are rejected; `proof status` shows a non-root
  user. Surfaced during OSS-29 live verify.
- **Ship-gating gate routing (DIVE-1145).** Root-cause fix for builders
  over-filing decision gates straight to the human (DIVE-1127/1142). When a
  non-lead agent files a `decision` gate, `task need` now routes it to the org
  lead first (resolved from the org chart — `reports_to`, else the coordinator/
  root, never hardcoded) as an agent handoff, suppressing the human ping until
  the lead resolves or re-escalates (a gate filed by the lead resolves to no
  distinct reviewer, so it goes to the human — free re-escalation). Behind pref
  `gate_builder_routing` (default **off**, ship-safe). True-human categories are
  never routed: tier-2-floored decisions (money/destructive/brand) and every
  non-decision type (approval/manual/secret) keep pinging the human unchanged.
  Approval/manual routing is deferred — it needs the DIVE-1117 provenance floor
  to trust a designated reviewer. Unit-tested in `tests/gate_ship_routing_unit.sh`. Enable/disable/inspect with `5dive task routing on|off|status` (mirrors `task precedent`).

### Fixed
- **Ship-gating routing, verifier iter-2 fixes (DIVE-1145).** (1) The route
  guard now keys on the **effective** tier (`type==decision && tier != 2`)
  instead of `tier_floored==0`, closing a hole where an explicit
  `--type=decision --tier=2` gate that missed the keyword floor kept
  `tier_floored=0` and silently routed to the lead — overriding the hard-human
  `--tier=2` contract and suppressing the human ping. (2) The unit harness now
  stubs `5dive` with a shell function (shadows the real binary, inherited by the
  detached `( … & )` send subshell) recording sends to a file sentinel, so the
  suite has **zero** live side-effects on real hosts/CI (was firing phantom
  `5dive agent send main` pings). Added coverage for explicit-`--tier=2` and a
  no-stray-send assertion; `gate_ship_routing_unit` now 12/12.

## [0.8.15] — 2026-07-12

### Added
- **Gate-shipped sweep — ghost gates flagged when their fix merges (DIVE-1140).**
  Human gates (approval/decision/manual) don't auto-close when the underlying fix
  merges to main, so the overnight recap (DIVE-217/1138) surfaced 'ghost' gates on
  already-shipped work. A new heartbeat sweep (`_hb_gate_shipped_sweep`, wired into
  `cmd_heartbeat_tick` after the TTL sweep) scans each configured repo's
  `origin/main` for a commit referencing an OPEN gate's ident; on a hit it stamps
  `shipped_flag_at` and pings the gate owner "likely shipped — verify and close".
  **Flag-only for ALL tiers** (lodar decision 2026-07-12): a merge is not a human
  sign-off (DIVE-555) and a commit may only partially fix a gate, so it NEVER
  auto-answers or closes — a human still clears it. `shipped_flag_at` throttles to
  one flag per gate. Repo allow-list is configurable via
  `HEARTBEAT_GATE_SHIPPED_REPOS` (default `5dive-cli`); grep is on the local
  `origin/main` tracking ref (no fetch, credential-free). New additive column
  `tasks.shipped_flag_at`.

## [0.8.13] — 2026-07-12

### Added
- **Outcome-loop objectives — `5dive objective` (OSS-19 / OSS-26, phase A1, gh
  5dive#23).** A first-class primitive for a standing goal the company steers a
  single number toward: `objective add "<name>" --metric-cmd="<cmd>" --target=<n>
  [--direction=up|down] [--unit=%] [--review="<cron>"] [--planner=<a>]
  [--project=<key>] [--max-new-per-cycle=N] [--budget=<tok>] [--public]`, plus
  `ls`, `show`, `pause`, `resume`, `rm`, and `tick`. Storage is a new
  `objectives` table + append-only `objective_readings` (both additive, gated
  migrations, byte-identical schema copies per `schema_sync_unit`). The metric is
  a **read-only command contract** (stdout → one number) run ONLY by `objective
  tick` and the digest, **never by a planner** — the anti-Goodhart separation
  baked in from day one. A failed/non-numeric metric records `value=NULL, rc!=0`
  so a broken metric shows as a visible gap, never a silent skip. `5dive digest`
  (text + `--json`) gains an `objectives` block — `{name, current, target,
  direction, unit, trend, gap, inflight, originatedThisCycle}` — deriving `trend`
  from the window baseline the same way `_window_counts` derives ship/ask deltas.
  This build is **measurement only**: NO origination and NO planner cycle (that
  is the blocked successor build); `cmd_proof.sh` is untouched (no-flag-edits
  invariant), so `--public` is stored for a later proof-feed passthrough. Covered
  by a new `objective_unit` (13/13).

## [0.8.12] — 2026-07-12

### Changed
- **Loop token `--ceiling` is now a hard stop, not advisory (OSS-24, gh
  5dive#17).** Driver loops (`loop map`/`until-dry`/`verify`/`grade`) already
  halted on breach — their foreground driver re-checks `spent >= ceiling` before
  each round. The gap was the fire-and-forget `loop spawn`: with no driver, a
  ceiling breach was caught by the heartbeat sweep but only marked `loop_runs`
  escalated + filed an escalate-with-proof gate — the agent kept burning tokens
  on the still-`in_progress` child task. The sweep now also **parks the loop's
  live child task(s)** (`blocked` + `parked_at` + `park_reason`, pending-gate
  fields cleared, same shape as `task park`; never touches
  done/cancelled/already-parked work), so the spend actually stops. This mirrors
  the cost-budget hard stop, scoped to the loop rather than the whole agent.
  Unblocks OSS-18 L2 budget widening (a budget that cannot halt must not be
  widened). Covered by an extended `loop_ceiling_enforce_unit` (now asserts the
  child task is parked on breach).

## [0.8.11] — 2026-07-12

### Changed
- **Supervisor self-heal now covers every runtime (OSS-23, gh 5dive#16).** The
  P2 recovery ladder (nudge → resume → rotate) no longer hard-escalates
  non-`claude` agents: `codex`, `grok`, `opencode`, and `antigravity` get the
  same auto-recovery on a session-alive-but-wedged cause (`no-progress`,
  `loop-stuck`). It always could — every rung is a generic op on the
  `agent-<name>` tmux session + registry (line injection via `_hb_send_line`, a
  modal-clearing Escape, same-type account rotation self-gated on
  `rotation.enabled`), with no claude-specific assumption; the old runtime gate
  was a DIVE-857 caution, not a technical limit. Restart-class causes
  (`service-dead`/`tmux-dead`/`poller-dead`) still escalate for every runtime
  (rung 4 = P3). Prereq for the OSS-18 autonomy ledger, whose self-heal-recovery
  signal would otherwise be claude-biased. Unit matrix in
  `tests/supervisor_unit.sh` extended to codex/grok/opencode/antigravity.
  Live-fleet validation of each runtime's actual resume behavior is main's
  verify-time last-mile.

## [0.8.10] — 2026-07-12

### Added
- **ID/age-verification tripwire in the fleet supervisor (DIVE-1127, ToS-hedge A2).**
  Per the Jul-11 hedge memo (D4 trigger 1), `5dive supervisor --tick` now flags
  any `claude` session whose live tmux pane shows an ID/age-verification
  challenge and alerts `main` + `lodar` SAME-DAY, tagging the account, so the
  response (flip that account to the OpenRouter-Claude profile, A1 runbook) can
  run same-day. Detection is PANE-scoped by design, not the JSONL transcript,
  so an agent merely discussing verification (e.g. this task's own chatter)
  never self-trips; the signature is anchored to a challenge directed at the
  user ("verify your identity/age", "government-issued ID"), env-overridable via
  `SUPERVISOR_VERIFY_PAT`. New classification `verify-challenge` (wins first —
  it explains any concurrent stall and is not a wedge the P2 nudge/resume/rotate
  ladder can clear, so it gets a dedicated alert path). Alerts dedup one per
  account per `SUPERVISOR_ALERT_WINDOW_H` (24h) and are audited as
  `supervisor_events` `event='alert'`. Unit-tested in
  `tests/verify_tripwire_unit.sh` (signature true/false positives incl. the task
  title trap, env override, dedup window). The `lodar` leg DMs the human through
  main's paired Telegram channel (`_task_agent_channel main` +
  `_task_send_owner`), best-effort. Live root `--tick` cron wiring +
  real-signature validation remain main's verify-time last-mile.

## [0.8.9] — 2026-07-12

### Changed
- **zero-human badge message is percent-only.** `proof publish` now renders
  `89.9%` instead of `89.9% (99)` — the shipped-count parenthetical read as
  noise on the badge (lodar call, 2026-07-12). The sample size still ships in
  `zero-human.json` (`week.shipped`) and `docs/zero-human.md` says where to
  look. Zero-ship weeks still render `0 shipped, N asks` (no honest bare `%`
  exists for an empty sample). Unit tests + methodology doc updated.

## [0.8.8] — 2026-07-11

### Added
- **`5dive proof` — publish your own zero-human badge (OSS-17, gh 5dive#21).**
  Generalizes the internal `scripts/publish-zero-human.sh` into a first-class
  verb so any self-hosted box publishes its own proof to its own repo's status
  branch, same methodology (`docs/zero-human.md`). `proof publish [--dry-run]
  [--repo] [--branch]` computes badge.json/zero-human.json/history.jsonl from
  `5dive digest --json` VERBATIM (no flag edits a number, by design), idempotent
  per day (a same-day re-run exits 3). `proof on --repo=<url> [--branch=status]
  [--at=HH]` saves config (`${STATE_DIR}/proof.json`) + installs an idempotent
  root cron (`/etc/cron.d/5dive-proof`); `proof off` removes the cron (config
  kept); `proof status` reports config, last-published date, and staleness.
  First publish prints the copy-paste README badge markdown pointing at the
  user's OWN status branch. `scripts/publish-zero-human.sh` is now a thin
  back-compat shim calling the verb (existing crons keep working; ZH_REPO/
  ZH_BRANCH/ZH_GIT_NAME/ZH_GIT_EMAIL still honored). Push auth is the box's
  ambient git credentials — the verb never stores tokens. Unit-tested in
  `tests/proof_publish_unit.sh`. Our own box's cron migration is held for
  verify-time with main (DIVE-1115 pause).

## [0.8.7] — 2026-07-11

### Fixed
- **Tier-2 gates now refuse a non-human answer regardless of need_type
  (DIVE-1117, companion to DIVE-1115 / defense in depth).** The human-only and
  gate-proof evidence blocks in `task answer` keyed on need_type
  (approval/secret/manual), so a `decision` gate FLOORED to tier 2 by the T2
  category heuristic (e.g. OSS-16/OSS-25, keyword-floored by "secrets") slipped
  past and accepted a bare-agent answer (`need_answered_by=main`) even with
  `gate-proof enforce` ON. Added a tier-2 provenance floor: under enforcement,
  `task answer` on any tier-2 gate refuses a non-human answer (an answer is
  human-sourced only when a trusted path passed `--human`, recorded `human:*`).
  The floor is provenance-only, not evidence-based: a tier-2 `decision` gate
  mints no per-gate nonce and its Telegram tap runs as `SUDO_UID=agent`, so
  demanding evidence would reject a real human decision tap (DIVE-525). Every
  trusted human path (Telegram tap, dashboard/API exec) passes `--human`, so a
  genuine human answer is never blocked. No downgrade path from the answer side:
  an over-fired T2 waits for a human by design. New unit suite
  `tests/gate_tier2_floor_unit.sh` (9 cases). Residual follow-up: the sudo→`--human`
  human:* forge on a tier-2 *decision* (no nonce evidence layer), and the
  phrasing-sensitive T2 heuristic should key on structured category, not ask-text
  keywords.

## [0.8.6] — 2026-07-11

### Added
- **Tier-1 gates auto-clear from proven human precedent (OSS-21).** Behind a new
  fleet pref `5dive task precedent on|off` (default **OFF**). When ON, at gate
  file-time — AFTER tier resolution and the T2 category floor, both unchanged — a
  gate that resolves to **tier 1** clears itself if the ask matches proven human
  precedent: EXACT `ask_shape` + same `need_type`, at least **2 distinct** prior
  gates answered by a **human** (`need_answered_by LIKE 'human:%'`) with the
  **identical** answer within 90d, **zero** contradicting human answers on that
  shape in 90d, precedent tier ≥ 1. The clear uses the same immediate direct-write
  path as tier-0/auto:ttl (never the human-answer path, so **no nonce is minted**),
  stamps provenance `auto:precedent` and `precedent_ref` = the most-recent
  qualifying gate, and surfaces in the digest's Auto-cleared section with its
  citation. Hard exclusions: **secret** gates and **T2** never auto-clear;
  `auto:*`-answered gates never seed a precedent (no compounding); a decision whose
  consensus answer isn't a current option falls through to the human. `5dive
  doctor` gains a `policy` check that flags when the switch is ON. Default OFF
  everywhere pending the OSS-16 policy decision.

## [0.8.5] — 2026-07-11

### Added
- **Fuzzy precedent prefill for repeat human gates (OSS-20).** Hand-written gate
  asks almost never collide EXACTLY, so the exact-shape precedent match prefilled
  ~0 gates in practice. `task need` now falls back to a token-set Jaccard >= 0.8
  match on `ask_shape` when the exact lookup misses — "the same question,
  paraphrased" — and prefills the blank recommend + cites the precedent. Fuzzy
  hits are advisory-ONLY: they never mutate the gate tier and are never eligible
  for auto-clear (that stays exact-match). Each prefill records a `precedent_kind`
  (`exact`|`fuzzy`); the digest's `precedentPrefill` now splits its acceptance
  rate by kind so the two match qualities are comparable (promotion reads exact
  only). Stays strictly inside the DIVE-916 invariant (no tier mutation, clear
  path untouched).
- **`5dive fire` — synonym for removing an agent.** `5dive fire <name>` and
  `5dive agent fire <name>` are aliases for `5dive agent rm <name>` (fire an
  agent from the team). Same guarded teardown path; purely additive.

## [0.8.3] — 2026-07-10

### Added
- **Custom providers in the `5dive init` wizard for Claude.** The claude auth
  step now offers a third option — "Custom provider" — to run Claude Code
  against a BYO Anthropic-compatible endpoint (OpenRouter, z.ai, DeepSeek,
  Moonshot), mirroring the provider picker hermes already had. It prompts for
  the provider + API key and wires `--provider`/`--auth-profile` at create
  time, so a BYO-provider Claude agent no longer needs hand-crafted
  `agent create` flags.

## [0.8.2] — 2026-07-10

### Fixed
- **Listener-only fixes now self-deploy on update (DIVE-1095).** The shared
  team-bot listener runs from a materialized `/opt/5dive/team-bot-listener.ts`
  that was rewritten ONLY by `team-bot shared`, so a listener-only fix (e.g.
  DIVE-1093's `callback_query`/`tna:` tap handling) shipped in the binary but
  stayed dormant on auto-updating boxes until an operator re-ran that command.
  New idempotent `5dive agent team-bot refresh-listener` re-materializes the TS
  from the current bundle and restarts the service (guarded on the unit file →
  no-op where there is no shared team-bot); `self-update` and the nightly
  `5dive-host-updates.sh` both call it after installing the fresh binary.

## [0.8.1] — 2026-07-10

### Added
- **`agent create --model=<slug>` picks the model on BYO claude providers
  (DIVE-1103).** Overrides the primary (opus+sonnet) tiers with any slug the
  provider serves — OpenRouter translates every family (`openai/*`, `google/*`,
  `z-ai/*`, `deepseek/*`, `meta-llama/*`) in Anthropic wire format, and the
  Chinese providers serve their own. The background/fast HAIKU slot stays on the
  catalogue's caching-capable default so background turns stay cheap. Complements
  the already-shipped `agent config set model=<slug>` (switch a running agent,
  persists to `settings.json`) and Claude Code's built-in in-session
  `/model <slug>`; the README documents all three.

## [0.8.0] - 2026-07-10

### Added
- **OpenRouter is now a first-class BYO provider for the CLAUDE (Claude Code) runtime (DIVE-1100).**
  OpenRouter ships a native Anthropic-skin endpoint (`https://openrouter.ai/api`,
  Claude Code appends `/v1/messages`), so the harness talks to it directly with no
  translation proxy. `5dive agent create --type=claude --provider=openrouter
  --api-key=- --auth-profile=<p>` now wires `ANTHROPIC_BASE_URL` +
  `ANTHROPIC_AUTH_TOKEN` (the `sk-or-` key) into the profile's `combined.env` via
  the existing `_apply_byo_claude` path. Because the Anthropic-skin endpoint only
  serves Anthropic first-party models (Claude Code is built around Anthropic
  request semantics, so `openrouter/auto` does NOT work here), the per-tier
  defaults pin concrete `anthropic/*` slugs (`claude-opus-4.8` / `claude-sonnet-5`
  / `claude-haiku-4.5`); operators can override in the model picker. Dashboard
  new-agent wizard now offers OpenRouter for claude-type agents (DIVE-1101).

### Fixed
- **Approval taps now clear gates in shared team-bot mode (DIVE-1093, GH #13 part 3).**
  DIVE-1087 made every per-agent bridge `TELEGRAM_SEND_ONLY` so the single
  `5dive-team-bot-listener` is the sole `getUpdates` consumer — but the listener
  subscribed only to `['message','managed_bot']` and handled only `u.message`, so
  the inline `tna:` approval-button taps were fetched by nobody and human gates
  (`task need --type=approval|secret|manual`) stayed unanswerable from Telegram in
  team-bot mode (the reporter's headline symptom). The listener now subscribes to
  `callback_query` and answers the gate itself: it re-reads the LIVE gate (never
  trusts the tapped payload), resolves the token via the same matrix as
  `plugins/telegram/tna.ts`, then runs `5dive task answer`. As a root daemon its
  `SUDO_UID` is non-agent (satisfies the DIVE-916/950 hard-gate human-evidence
  check) and it also forwards the per-gate `--human-proof` nonce when the tap
  carried one. Fully fail-soft: any stale/deleted task or CLI error just acks the
  tap so Telegram clears the spinner.
- **Shared team-bot members no longer fight the listener over getUpdates (DIVE-1087).**
  With `5dive agent team-bot shared` + poll-fork agents (codex/grok/opencode/agy),
  every per-agent bridge long-polled `getUpdates` in addition to the single
  `5dive-team-bot-listener`. Telegram allows one consumer per token, so N agents +
  the listener 409'd each other and inline approval-button callbacks were silently
  lost (unanswerable `task need --type=approval` gates). `team-bot shared` sets
  `TELEGRAM_SEND_ONLY=1` in the connector env, but codex/grok/opencode/agy spawn
  their MCP bridge with a minimal env and read their own `channels/telegram/.env`,
  which the flag never reached. `5dive-agent-start` now propagates
  `TELEGRAM_SEND_ONLY` into each bridge's `.env` on every boot (and removes it when
  toggled off), and the bridges honor it by structurally skipping the poll loop
  (`acquireSlot`/`bot.start` never run) while keeping the MCP send tools live — so
  the shared listener is the sole poller and approval taps survive.
- **`5dive agent create` (admin isolation) now works on Ubuntu 26.04 (DIVE-1088).**
  sudo-rs (`visudo-rs`, the default sudo on Ubuntu 26.04) rejects wildcards
  *inside* a command argument, so the admin sudoers' `systemctl <verb>
  5dive-agent@*` / `5dive-*.service` lines failed validation and aborted the
  default first-agent (admin) create with no partial install — the error was
  `wildcards are not allowed in command arguments`. `--isolation=standard` was
  unaffected because its grants use a bare trailing `*` (any-args), which
  sudo-rs accepts. Fix: dropped the raw `systemctl` lines (redundant — an admin
  already holds the whole `5dive` CLI as root, which runs `systemctl`
  internally, plus `5dive agent restart|start|stop`) and added a hardened,
  5dive-unit-only `5dive agent _svc <start|stop|restart> <unit>` primitive as
  the scoped replacement for manual service lifecycle. The admin sudoers now
  uses only sudo-rs-valid bare-`*` forms and its privilege scope shrinks.
- **Sandboxed isolation now works for claude agents (DIVE-1033).** Sandboxed
  agents aren't in the `claude` group, so `/home/claude` (0750) — where the
  shared runtime (`claude`, node/nvm) lives — was unreachable, failing both the
  channel-plugin install and `5dive-agent-start` with "Permission denied".
  `create_agent_user` now grants the sandboxed agent a traverse-only ACL
  (`setfacl -m u:agent-<name>:--x /home/claude`): it can exec the binaries by
  known path but cannot list or read claude's home (secrets stay behind their
  own 0600/0700 perms). Cleaned up in `delete_agent_user`. The proper fix
  (relocating the runtime out of `/home/claude`) is tracked as DIVE-1034.
- **Inter-agent delivery no longer silently drops messages (`set -u`
  self-reference).** `inject_and_submit` declared
  `local name="$1" payload="$2" user="agent-${name}" …`, self-referencing `name`
  in the same `local` statement. Under global `set -euo pipefail`, bash aborts the
  function at the declaration before the `tmux send-keys` inject runs, so
  `agent send`/`ask`/`_deliver` never delivered anything — every standard-
  isolation agent on a host was affected. Split the declaration so `name` binds
  first (mirroring `wait_agent_input_ready`). The same latent antipattern was
  fixed in `_team_bot_write_sendonly_env` and `_pack_memory_dir`. Reported by
  agent-triniti.

## [0.7.24] - 2026-07-06

### Added
- **Crash-loop detection in the supervised restart loop (DIVE-1029).** The
  respawn loop that keeps an agent alive now distinguishes a genuine
  usage-limit park (claude ran healthy, then exited) from a crash-loop (claude
  dying within seconds, repeatedly, e.g. the stale plugin-marketplace git
  remote after the org rename that crash-looped 19/21 agents). New
  `hooks/run-loop.sh` helper, wired in by `5dive-agent-start`: on a crash-loop
  it backs off exponentially (2s to 300s) instead of hammering a 2s respawn,
  surfaces the REAL error once (exit code plus the last pane output carrying
  claude's actual stderr) to the paired chats instead of a misleading usage
  banner, and drops a crash-loop flag. `stop-failure-telegram.sh` and
  `resume-after-reset.sh` read that flag to SUPPRESS the false "Usage limit
  reset, agent resumed" banner while the agent is actually just dying. A
  healthy run (>=45s) clears the flag and sends a single "recovered" note.
  Falls back to the original inline loop on boxes that predate the helper.
  Builds on DIVE-902 (DM dedup + single-winner resume-lock).

## [0.7.13] - 2026-07-05

### Changed

- DIVE-1013: **`hire --from-market` now gates before provisioning.** It used to
  resolve the pack, print the DIVE-995 "this pack will run X" disclosure, then
  create a real teammate IMMEDIATELY, so a docs/blog reader or an agent copying
  an example could stand one up unintentionally. Now:
  - `--dry-run` resolves the pack and prints the disclosure but creates NOTHING
    (read-only, runs outside the registry lock — no root, like `agent inspect`).
  - In a TTY it prints the disclosure and requires an interactive `y/N` confirm.
  - Non-interactively it requires an explicit `--yes`, else it aborts after
    showing the disclosure. The resolve/disclosure output is unchanged.

## [0.7.12] - 2026-07-04

### Security

- DIVE-1011: **reject symlink/hardlink members on pack import + inspect**
  (defense-in-depth follow-up to 0.7.11). DIVE-1010's guard refuses `..` and
  absolute member *names*, but a symlink is a distinct escape a name-check
  can't cover: a pack ships a symlink `link -> /etc` (name passes) then a member
  `link/file` (name passes), and on extraction tar follows the on-disk link to
  write outside the mktemp stage. `_pack_safe_extract` now inspects member
  *types* via `tar -tvzf` and refuses any pack shipping a link member — 5dive
  packs never contain links. Modern GNU tar has its own symlink-replacement
  guard, so this is hardening, not an open hole. New symlink-member fixture in
  `pack_disclosure_unit.sh` (30/30).

## [0.7.11] - 2026-07-04

### Security

- DIVE-1010: **harden pack import/inspect against tar path-traversal (zip-slip).**
  A local `.tar.gz` import (`agent import <file>`) bypasses registry signing
  entirely, so a crafted pack with `..` or absolute-path members could have tar
  write files OUTSIDE the mktemp stage. `cmd_import` and `cmd_inspect` now route
  extraction through a shared `_pack_safe_extract` guard that lists members first
  and refuses the pack (with a clear validation error) if any member is absolute
  or contains a `..` path component, extracting nothing. Follow-up to DIVE-995.

## [0.7.10] - 2026-07-04

### Changed

- DIVE-1006: **quiet dangling-link noise for intentional forward-refs.** Follow-up
  to DIVE-991. The memory rules bless a `[[name]]` with no file yet as an
  intentional forward-reference (marks something to write later), but the doctor's
  dangling-link check warned on every one — heavy linkers got a noisy report
  (Marcus: 55/55 warned). `_memory_scan_json` now only warns when the target slug
  is a close edit-distance match to an existing file (a likely typo'd/broken link)
  and names the suspected target ("did you mean [[beta]]?"); links with no near
  match go quiet as intended forward-refs. Actionable typo-suspects stay `warn`;
  intentional stubs no longer pollute the report.

## [0.7.9] - 2026-07-04

### Added

- DIVE-1009: **pack trust layer — close the plugin-hook gap.** Follow-up to
  DIVE-995, from the ship-gate security review. Two holes let a pack still auto-run
  shell on the new agent's tool events despite deny-by-default:
  - Plugin-carried hooks were disclosed by name but never recursed or stripped. A
    bundled plugin registering its OWN shell-on-tool-event slipped `--allow-hooks`
    and installed by default (an incomplete control is worse than none). `agent
    inspect`/`import` disclosure now recurses plugin-carried hooks (`pluginHooks`)
    and `import` scrubs any `.hooks` nested in the plugins block unless
    `--allow-hooks` — same deny-by-default as top-level hooks.
  - Strip now fires on any NON-EMPTY `.hooks` (not just when a `.command` field is
    present), so a future CC hook type that executes without `.command` can't slip
    both the disclosure and the gate. `tests/pack_disclosure_unit.sh` extended
    (23 assertions).

## [0.7.8] - 2026-07-04

### Added

- DIVE-995: **pack trust layer** — the install-time "this pack runs X"
  disclosure and the safety precondition before running any third-party pack.
  New read-only `5dive agent inspect <pack|slug>` unpacks a pack and reports its
  executable surface: hooks (arbitrary shell that auto-runs on the new agent's
  tool events — the agentjacking surface), skills/plugins added, whether it
  re-renders the system prompt, seeds recall memory, or adopts a bundled signing
  key. `agent import` now **prints the same disclosure before recreating** and
  is **deny-by-default on hooks**: a pack's hooks are STRIPPED on import unless
  the importer passes `--allow-hooks`. Import result envelope gains `hooks`
  (`none|stripped(N)|allowed(N)`) and a full `disclosure` object. Covers OSS-6
  item 5's mandatory install disclosure; identity/receipts (item 4) + install
  counts + a PUBLIC marketplace remain split (lodar brand/security decision).

## [0.7.7] - 2026-07-04

### Added

- DIVE-992: the heartbeat tick prompt now injects **memory recall** and a
  **compile nudge** from the shared `_hb_wake` seam. Recall: each `/goal` nudge
  cites the top-k memory/wiki hits most relevant to the task's title+body (BM25
  over the target agent's own store + shared wiki) so the agent starts warm and
  can expand a hit with `5dive memory search`. Compile: if the task looks
  research/knowledge-shaped, the nudge gains a "compile before you close" line
  (karpathy method) — making compile a runtime behavior, not just a convention.
  Both are best-effort and flattened to a single line; a failure never blocks the
  nudge. Covered by tests/heartbeat_recall_compile_unit.sh.

## [0.7.6] - 2026-07-04

### Added

- DIVE-981: `5dive project show` now renders the task_deps dependency
  graph — tasks grouped into topological layers (L0, L1, …) with inline blockers
  and a marked critical path (the longest end-to-end chain). `--json` gains a
  `data.graph` block (nodes with layer/critical/blockers, edge count, layer
  count, and the reconstructed `critical_path`) so a plan can be audited at a
  glance. Covered by tests/project_show_graph_unit.sh.

## [0.7.5] - 2026-07-04

### Added

- DIVE-973: stuck-lane analytics in the daily digest — MTTU
  (mean-time-to-unstick). Sourced from the supervisor_events transition trail
  (which folds in loop_runs.stuck onsets as cause=loop-stuck): each stuck
  episode is a transition into classification=stuck paired with the next
  transition out of it; MTTU is the mean of those durations for episodes that
  recovered in the window. `digest --json` gains a `stuck` block
  (mttuSec/episodes/openStuck/byCause); the text digest adds an "Unstick" line
  plus a still-stuck callout. Same spirit as the zero-human KPI, zero agent
  tokens.

## [0.7.4] - 2026-07-04

### Added

- DIVE-993: `5dive hire <role> --from-market` — one command from the
  open market to an employed teammate. Resolves <role> against the character-pack
  registry (rarity + completeness-tiered pick), provisions from that persona via
  the `agent import` slug path, and slots the new hire into the org chart under
  the pack's role. `--as=<name>` picks the local name (defaults to the slug);
  `--role`/`--title` override the org placement; other flags pass through to
  `agent import`.

## [0.7.3] - 2026-07-04

### Added

- DIVE-991: memory hygiene. New `5dive memory doctor` and a `memory`
  category in `5dive doctor` run a hygiene pass over per-agent memory stores +
  the shared wiki: index drift (MEMORY.md/index.md vs files on disk — missing
  targets are errors, unindexed files warnings), dangling `[[wiki-links]]`,
  stale source refs (a cited `path/file.ts` / `file:line` no longer in the
  codebase — only checked when a code-root is available, so no false alarms on
  customer boxes), and near-duplicate memories (token overlap). `5dive doctor`
  rolls findings up to one row per store; `5dive memory doctor --json` gives the
  itemized list. Pure scanner shared by both, unit-tested in
  tests/memory_doctor_unit.sh.

## [0.7.2] - 2026-07-04

### Added

- DIVE-990: memory-as-onboarding. `agent create --inherit-memory=<scope>`
  seeds a new hire's recall store from shared team knowledge so it boots knowing
  the company instead of cold-starting. Scope is a comma-list of sources — `wiki`
  (the shared team wiki), a sibling `<agent-name>` (its SHAREABLE facts only —
  reference/project, never private user/feedback, same deny-by-default L1 scoping
  as `agent export`), or `all`/`team` (wiki + every sibling). Copies land in the
  agent's own store with a regenerated MEMORY.md index, so `5dive memory search`
  returns team context from the first minute.

## [0.7.1] - 2026-07-04

### Added

- DIVE-989: verifier-by-default now walks a chain of DISTINCT graders
  (project lead, coordinator, maker's manager, org root, technical deputy) and
  takes the first that differs from the maker, so the default no longer silently
  no-ops in the common maker==coordinator case (a lone-root CEO owning all
  unassigned work). Adds _task_resolve_org_root + _task_resolve_deputy.

## [0.7.0] - 2026-07-04

### Added

- Goal decomposition GA: the `5dive goal` line graduates — decompose an
  outcome into a validated task DAG that materializes ONLY on a human-approved
  checkpoint (DIVE-984 planner + DIVE-985 approve->materialize). Version milestone;
  the capability shipped incrementally across 0.6.19-0.6.28.

## [0.6.28] - 2026-07-04

### Added

- DIVE-985: `5dive goal add --from-gate=<id>` completes the approve->materialize
  loop for a gated plan. `--yes` waives ONLY the count checkpoint, so a plan
  carrying a Tier-2 task could be proposed + gated but never built. `--from-gate`
  recovers the plan from the anchor task's body, requires that a HUMAN answered
  the gate `approve` (DIVE-916 human-origin rule: `need_answered_by` must be
  `human:*`, never an agent/TTL clear), re-validates the plan from scratch
  (caps/tier/DAG), then materializes it. It is the only path that materializes a
  Tier-2 plan, is idempotent (refuses to re-build an already-materialized goal),
  and rejects a non-goal or unanswered/non-approve gate. A Tier-2-carrying plan
  now also files its checkpoint gate at HARD tier 2 (was a plain tier-1 decision),
  so it can no longer be 48h-auto-applied or agent-cleared.

## [0.6.27] - 2026-07-04

### Added

- OSS-14: weekly autonomy report. `5dive digest` (esp. `--7d`) gains a one-glance
  "🦾 Autonomy — ran N days without needing you · shipped X · asked you Y×" line
  plus an `autonomy` JSON block (uptimeDays = days since the last human-blocking
  stall, shipped/asked for the window, priorShipped/priorAsked for the trend, and
  currentlyBlocked). Deterministic, rides the existing digest python, zero agent
  tokens — the marketing-flagship framing of the OSS-10 zero-human numbers.

## [0.6.26] - 2026-07-04

### Security

- DIVE-1002: least-privilege agent isolation. New agents now default to
  `standard` isolation (zero sudo) instead of `admin` — a compromised or
  prompt-injected worker can no longer reach root. Bootstrap convenience: the
  FIRST agent on a fresh box (empty registry) is auto-granted `admin`, but the
  resolved tier is recorded EXPLICITLY in the registry (never re-derived from
  create-order); an explicit `--isolation` always wins. The `admin` tier is now
  SCOPED to a `visudo`-validated allowlist — the `5dive` CLI plus non-paging
  `systemctl start|stop|restart` of `5dive-agent@*` / `5dive-*.service` — and no
  longer grants blanket `ALL=(ALL) NOPASSWD: ALL`. The three indirect root
  escapes (`systemd-run *`, `journalctl *`, `systemctl status *` pager `!sh`) are
  excluded; a new `5dive agent restart <name> --defer` runs the deferred
  systemd-run internally (fixed command) so admins never need a raw grant, and
  `5dive crew` now refuses EUID 0 (it execs agent-authored venv Python). Registry
  schema v1->v2 stamps existing field-less agents as explicit `isolation:admin`
  so no live admin is silently downgraded (their sudoers files are untouched; the
  scoped allowlist applies to new admins/fresh boxes). New
  `tests/agent_isolation_unit.sh` (15/15).

## [0.6.24] - 2026-07-04

### Added

- OSS-12: gate SLA escalation — an unanswered T2 gate walks the org chart
  instead of stalling on one recipient. Once a gate ages past
  `_HB_GATE_ESCALATE_DAYS` (env `HEARTBEAT_GATE_ESCALATE_DAYS`, default 5), the
  weekly stale-gate batch in `_hb_gate_ttl_sweep` also CCs the filing agent's
  org-chart parent (`agents_org.reports_to`), so the gate escalates up a level.
  Reuses `gate_pinged_at` + the heartbeat tick as the driver; NEVER auto-answers
  a T2 gate (escalation changes who is pinged, not what clears). New
  `tests/heartbeat_gate_escalate_unit.sh` (5/5).

## [0.6.23] - 2026-07-04

### Added

- DIVE-979: dependency-aware heartbeat scheduling. The per-agent wake now picks
  the next task through `_hb_pick_task`, which (a) SKIPS any todo whose
  `task_deps` still has an open blocker (a `blocked_by` task not yet
  done/cancelled) so no unstartable work is ever handed out, and (b) within a
  priority tier PREFERS the critical path — the todo whose downstream dependent
  chain is longest, via a depth-capped recursive CTE over `task_deps`. Priority
  stays the primary key; critical-path depth is the tiebreaker, then id. The
  urgent/high early-wake probe is likewise gated on being blocker-free. New
  `tests/heartbeat_pick_unit.sh` (7/7) covers the dep graph end to end.

## [0.6.22] - 2026-07-04

### Added

- DIVE-972: enforceable per-loop token ceilings. `task loop start`/`loop spawn`
  now honor a per-loop token budget — a running loop that reaches its ceiling is
  stopped and flagged instead of burning unbounded tokens, and the daily digest
  surfaces each loop's burn against its ceiling so overspend is visible. Closes
  the "runaway loop" gap flagged on the budget-enforcement track.

### Fixed

- Pre-existing shellcheck SC1072/SC1073 in `cmd_supervisor.sh` (a DIVE-971
  artifact) cleaned up to keep the lint gate green.

## [0.6.21] - 2026-07-04

### Added

- DIVE-971: multi-runtime supervisor signals — closes the three supervision
  TODO(P2)s in `cmd_supervisor.sh`. (1) The telegram-poller liveness probe now
  covers codex/grok/antigravity/opencode via a per-type argv pattern
  (`_SUP_POLLER_PAT`), not just claude — each type's bridge dir (`telegram-<x>`)
  is a stable pgrep match. (2) The last-activity/progress age now reads each
  runtime's own transcript root (`_sup_activity_epoch`: codex
  `~/.codex/sessions/rollout-*.jsonl`, grok `~/.grok/sessions`, opencode
  `~/.local/share/opencode/storage`, antigravity
  `~/.gemini/antigravity-cli/brain/**/transcript*.jsonl`), so non-claude agents
  can be classified stuck/no-progress instead of forever-unknown. (3) New
  `drift` classification (cause `goal-drift`): a claude agent with an active
  `/goal` targeting a still-`todo` DIVE task while it progresses elsewhere —
  a STRUCTURAL check (task-id vs status), not a semantic heuristic. All three
  keep the false-negative bias (missing/ambiguous signal => never stuck), and
  `drift` is observe-only — guarded out of the P2 act ladder so no rung, not
  even escalate, can fire on it (no false-stuck regressions on claude agents).

## [0.6.20] - 2026-07-04

### Added

- DIVE-969: verifier-by-default posture (Karpathy autonomy slider). `task add`
  now engages maker->grader verification BY DEFAULT for non-trivial standard
  tasks: it derives acceptance criteria from the title and assigns a grader
  distinct from the maker (project lead, else org coordinator), reusing the
  DIVE-476/477 loop so a plain `task done` hands off to grade instead of closing.
  Trivial chores (bodyless mechanical titles like typo/bump/docs), low-priority
  tasks, recurring templates, and solo orgs with no distinct grader are left
  frictionless. `--no-verify` is the explicit opt-out; `FIVE_VERIFY_DEFAULT=0` is
  a fleet kill-switch. Add output carries `verifyDefaulted` + `verifier`.

## [0.6.19] - 2026-07-04

### Added

- DIVE-984: `5dive goal add "<outcome>"` — goal decomposition v1 (OSS-2). A
  planner agent (via `loop spawn --wait --schema`) turns an outcome into a
  materialized task graph: tasks + `task_deps` edges + assignees under a project.
  Guardrails: hard task/depth cap (reject, never truncate), no tier-lowering
  (reuses the Tier-2 category-floor classifier), a one-gate human checkpoint over
  the count threshold or any Tier-2 task, and `--dry-run` that creates nothing.

## [0.6.18] - 2026-07-04

### Added

- DIVE-976: decision-memory precedent prefill (OSS-11) — when a new gate matches
  a prior ANSWERED gate (same need_type, exact normalized ask-shape, precedent
  tier >= new tier, within 90 days), prefill a BLANK recommendation with the prior
  answer and cite it (Telegram ping + `task show`/inbox). Pure advisory: never
  mutates tier or the clear path, fill-blank-only never overrides a filer rec, and
  a decision precedent must be one of this gate's options — the DIVE-916 invariant
  holds by construction. Adds `ask_shape`/`precedent_ref` columns + an
  acceptance-rate digest line.

## [0.6.15] - 2026-07-04

### Added

- DIVE-968: implement `5dive loop status --handle=<loopId>` — the read-only
  single-loop drilldown that complements the fleet-wide `task loops` board.
  Reports topology/stage/iteration/tokens-vs-ceiling/status plus each backing
  task's live state and a derived `stuck` signal (stored supervisor flag, or a
  running loop at/over ceiling, or with no heartbeat for the stall window).
  Pure read (never spawns/mutates/block-waits), JSON in / JSON out. Retires the
  last `_loop_todo` WIP stub, so no "not yet implemented" verb ships.

## [0.6.11] - 2026-07-04

_Gate-hardening line 0.6.9-0.6.11, merged as `dive-916-931-gate-nonce`._

### Security

- DIVE-916: **close the `sudo`→`--human` gate-forge** with a per-gate HUMAN nonce.
  `task need` now mints a 16-byte nonce for every hard human gate
  (approval/secret/manual), stores only its SHA-256 (`human_nonce_hash`), and
  embeds the RAW nonce solely in the Telegram tap `callback_data` the CLI composes
  as root — the agent's LLM never sees it. `task answer` clears such a gate as
  human iff it presents ONE of two equivalent evidence forms: a matching
  `--human-proof=<nonce>` (the plugin-tap path, whose SUDO_UID is the spawning
  agent) or a non-agent `SUDO_UID` (a claude/root login and the DIVE-931
  secret-drop write, which runs `SUDO_UID=claude`). A bare
  `sudo 5dive task answer --human` from an agent session (SUDO_UID=agent-\*, no
  nonce) is rejected. `manual` joins approval/secret as an enforced human gate.
  Ships **dormant** (audit-only) behind `gate-proof enforce`; flip on once the
  plugin `--human-proof` injection is confirmed live fleet-wide. Scope: this
  closes the realistic/injection-risk forge (an agent one-liner), not the broad
  `sudo su - claude` path (a separate sudo-hardening track). Folds into the
  DIVE-931 secret-drop chain: the drop write clears via the non-agent-SUDO_UID
  form, no nonce-threading needed.

- DIVE-950: **drop the forgeable `--proof` evidence form** (DIVE-916 hardening).
  The DIVE-519 `--proof` token was agent-forgeable — `5dive gate-proof` mint is
  `require_root` only, so any agent could `sudo`-mint a valid token and self-clear
  a gate (the easy one-sudo forge). The `gate-proof <id> <type>` mint subcommand is
  removed (returns a loud, audited error); `task answer` no longer counts `--proof`
  as evidence (the flag is parsed-but-ignored so an in-flight caller mid-deploy
  does not break). Gates clear via the per-gate `--human-proof` nonce or a
  non-agent `SUDO_UID`. Honest scope: this closes the silent one-liner self-clear
  AND the easy sudo-mint forge; it is NOT airtight against a determined agent with
  root `sudo` (instrument-its-own-nonce / `sudo -u claude` / `sudo su - claude`) —
  that is the separate sudo-reduction track. `gate-proof sign`/`verify`/`enforce`
  are unchanged.

### Changed

- DIVE-909: a standalone (non-loop) **manual** human-gate answered `done` now
  closes the task as **done** instead of flipping it back to `todo`. Previously
  completed work parked behind a manual gate had no honest close — the agent
  can't `task done` (blocked by its own pending gate, DIVE-555) and the only
  agent-allowed escape was `task cancel`, which mislabels finished work as
  cancelled (DIVE-524). The already-shipped `✅ Done` Telegram tap
  (`tna:<id>:done` → `task answer --value=done`) now lands on this path and
  closes cleanly across every runtime — no plugin/fork change needed. A
  non-`done` answer still clears the gate → `todo` (the resume path), and loop
  GATE steps are exempt (their manual answer still drives the relay advance).

## [0.6.6] - 2026-07-03

### Changed

- DIVE-906 (create-path token hygiene, part 2 of DIVE-888): `agent create`
  now accepts `--telegram-token=-` and `--discord-token=-`, reading the bot
  token from stdin (same `-` sentinel as `--api-key=-` / `config set
  *.token=-`) so it never lands in argv (and thus never in `ps`). The exec
  tunnel exposes a single stdin channel, so at most one `=-` sentinel is
  allowed per create — a BYO `--api-key=-` combined with a channel
  `--token=-` is rejected up front with a clear usage error rather than
  blocking on a second `cat`. The dashboard new-agent wizard pipes the pasted
  bot token on stdin when no BYO key is present (BYO key keeps stdin when both
  are supplied; the channel token then stays inline as the documented
  residual).

## [0.6.5] - 2026-07-02

### Fixed

- DIVE-901: `agent install antigravity` no longer flakes with "agy still
  missing" when the binary resolves outside `~/.local/bin` (PATH drift /
  image pre-seed): the recipe's gate (`command -v agy`) and the success guard
  (`-x TYPE_BIN`) disagreed, so the recipe no-op'd in 0s and the guard failed
  even though agy works — the same class as grok's opportunistic-symlink gap.
  The recipe now ensures the TYPE_BIN symlink itself, and the install guard
  gives any type's binary a 10s grace for async/late-rename installer drops.

## [0.6.4] - 2026-07-02

### Added

- DIVE-899: every claude agent's per-agent CLAUDE.md now carries the
  self-gated model-tiering default (Fable-as-orchestrator + explicit
  per-subagent model choice: sonnet for mechanical work, opus for
  judgment-heavy work, haiku never). The fragment's first line scopes it to
  Fable sessions, so it is inert on every other model. New
  `model-tiering-CLAUDE.md` shipped to $LIB_DIR by install.sh; appended (not
  copied) after the telegram fragment so both survive. From the DIVE-881
  sniff-test verdict.

## [0.6.3] - 2026-07-02

### Added

- DIVE-897 (DIVE-726 Phase 1b): the memory write/compile path + search scoping.
  `5dive memory add --name --description [--type] [--store=mine|wiki] [--tags]
  [--force]` (body on stdin) writes a frontmatter-stamped memory file with
  provenance (compiled_by/compiled_at), appends the store's index line, and
  refuses token/key-shaped content (tripwire; --force never bypasses it).
  `memory search` gains `--store=all|mine|wiki` + `--agent=<name>` scoping.
  Cross-agent read DECISION: per-agent stores stay per-user 0600 —
  fleet-searchable knowledge is PUBLISHED to the shared wiki via
  `memory add --store=wiki` (deny-by-default, the DIVE-481 distillation-gate
  posture); `--agent` therefore resolves for root only. Cached inverted index
  deferred until stores outgrow a few thousand chunks; embeddings stay Phase 1c.

## [0.6.2] - 2026-07-02

### Fixed

- DIVE-894: gate alerts no longer dead-end on a box with no dashboard. The
  secret/manual CTA lines and any button-less decision/approval alert now carry
  the copy-pasteable on-box fallback (`sudo 5dive task answer <id> ...`, run as
  a human login — claude/root clears approval/secret gates on the human path).
  Companion telegram-plugin 0.5.10 change: a failed gate tap replies with the
  same on-box line instead of "open the dashboard" (lodar hit this live on
  DIVE-790, CLI-only box).

## [0.6.1] - 2026-07-02

### Added

- DIVE-726 Phase 1a: `5dive memory search "<query>"` — queryable team memory
  read-path. BM25-ranked snippets from the agent's markdown memory stores (+ the
  shared wiki when present), section-chunked for provenance and capped at a token
  ceiling. Lexical-first (no embeddings, no new dependency, nothing leaves the
  box); read-only.

## [0.6.0] - 2026-07-02

### Added

- DIVE-891: risk-tiered human gates + TTL (adopted design DIVE-861). `task
  need` takes `--tier=0|1|2`: tier 0 auto-applies the recommendation
  immediately (no ping — the daily digest's new "Auto-cleared gates" section
  is the record); tier 1 pings normally but a new heartbeat sweep applies the
  recommendation after 48h unanswered (provenance `auto:ttl`, closure signed,
  owning agent pinged); tier 2 (the default for approval/secret/manual) never
  auto-applies — stale tier-2 gates instead batch into ONE reminder per
  paired chat after 72h, re-pinged weekly, with manual asks grouped as a
  single "15 minutes" block. Money, public-comms, secret, destructive and
  brand asks are floored to tier 2 in the CLI regardless of the flag; secret
  gates are always tier 2. Loop gate steps and legacy (pre-tier) gates are
  never auto-applied. `task park` gains `--wake=<ts|+Nd|+Nh>` — the same
  sweep auto-unparks the task back to todo when the time passes, so
  "revisit later" stops sitting in the human inbox. New additive tasks.db
  columns: `tier`, `need_asked_at`, `gate_pinged_at`, `wake_at`.

## [0.5.9] - 2026-07-02

### Added

- DIVE-880: bot tokens can now be passed on stdin instead of argv, so they
  never land in `/proc/<pid>/cmdline`, shelld's audit log, or server access
  logs. `agent telegram-getme --token=-` and `agent telegram-discover
  --token=-` read the token from stdin, and `agent config <name> set
  telegram.token=-` / `discord.token=-` do the same — the sentinel `-` form
  `cos set --token=-` and `auth set --api-key=-` already used. The dashboard's
  AddChannelPanel and connect wizard switch to this form via the exec tunnel's
  `stdin` field. Only one `=-` key can be read per invocation (stdin is
  consumed once).

## [0.5.8] - 2026-07-02

### Added

- DIVE-860: `task loop ls` surfaces the latest grade scorecard per builder
  loop run. JSON rows gain `scorecard_json` (raw card string, `''` when
  ungraded — same contract as the `task loops` runs board), joined from
  `loop_runs` by the card's `target` ident; the text board gains a `score`
  column (`84/100` style). Feeds the dashboard Loops tab score chips.

## [0.5.5] - 2026-07-02

### Added

- DIVE-856: claude agents are chat-capable in the web dashboard by default.
  `agent create` folds the token-free `dashboard` channel into every claude
  create on managed boxes (unset `--channels` becomes `dashboard`, explicit
  lists get `,dashboard` appended; `--channels=none` stays the opt-out).
  `agent config <name> set channels=` is now fully comma-list aware and
  dispatches the dashboard plugin install — the backend for the dashboard's
  one-tap "Enable chat" on existing agents.

### Fixed

- Channel lists (DIVE-841) broke several exact-match consumers: a
  `telegram,dashboard` agent lost `AGENT_CHANNEL_MARKETPLACE` (telegram
  plugin resolved against the wrong marketplace → dead channel), was wrongly
  counted as a team-bot relay candidate despite its personal bot, skipped the
  CoS welcome DM / autoPaired flag, and didn't get its plugins preseeded into
  `enabledPlugins`. All channel checks now use the `channel_in_list` helper,
  and the team-bot shared attach preserves a dashboard channel instead of
  clobbering `channels` to bare `telegram`.

## [0.4.10] - 2026-06-28

### Security

- Gate-proof enforcement is now ON by default fleet-wide (DIVE-758, drop 2). The
  install + `--upgrade` paths flip `gate-proof enforce on`, so once a box adopts
  the tamper-evidence build an UNPROVEN agent-path answer to an approval/secret
  gate is rejected. Human taps (`--human`, the Telegram path) always clear and the
  dashboard doesn't answer gates, so live answering is unaffected — this only
  stops an agent self-clearing a human gate. Idempotent + best-effort (never
  blocks install). Toggle off per-box with `5dive gate-proof enforce off`.

## [0.4.9] - 2026-06-28

### Security

- Gate closures are now tamper-evident (DIVE-756). `tasks.db` is group-writable,
  so any claude-group agent could `sqlite3 UPDATE` a human gate answered —
  bypassing the CLI, gate-proof, and all attribution — and the close was logged
  as a spoofable `SUDO_USER`. `task answer` now stamps the real pre-sudo invoker
  (`need_answered_uid` = `$SUDO_UID`) and an HMAC over the closure facts
  (`need_answer_sig`, signed with the root-only gate-proof key). New
  `5dive gate-proof verify <id>` recomputes it and reports `signed`/`valid`: a
  raw-sqlite bypass shows `signed=absent`; tampering with an answer afterward
  shows `valid=false`. Detective half — enforcement (reject on missing/invalid
  sig) is a later flip; this ships additive with no behaviour change.

### Fixed

- Pinned/managed default skills now actually reach **existing** agents
  (DIVE-698). `5dive-refresh-skills.sh` previously skipped any skill already
  present, so a re-pinned skill (e.g. the `openagent` v0.27 pin) only landed on
  brand-new agents while existing boxes kept the stale copy. The refresh now
  **force re-pulls** every skill in `DEFAULT_SKILLS` to its current pinned
  version. Backed by a new `--force` flag on `5dive agent skill <name> add`,
  which drops the existing skill dir before re-installing so the npx path
  upgrades instead of no-op'ing on an already-present directory.

  **Release flow:** to push a re-pinned default skill to the whole fleet, bump
  the pin in `<org>/skills`, then either wait for the daily update cron (which
  runs `5dive-refresh-skills.sh` via `install.sh --upgrade`) or force it now with
  `sudo 5dive-refresh-skills.sh` (all agents) / `sudo 5dive-refresh-skills.sh <name>`.

### Added

- **SessionStart resume-context hook** (DIVE-726 Phase 0, the v0.5 "memory moat"
  floor). After a service restart / crash / rotation a fresh `claude` session
  booted with no idea what the previous one was doing. The new
  `sessionstart-resume-context.sh` hook injects, on every boot, the agent's
  in-flight `in_progress` task(s) — read straight from the durable task queue, so
  the thread is recovered even on an **abrupt** crash, not just a graceful stop —
  plus the head of the latest carryover note. Output is **bounded** (a few
  in-flight task lines + a carryover pointer/head), so per-turn cost stays flat
  regardless of how many tasks/carryovers exist: retrieval, not injection. Wired
  into `agent_setup.sh` for every channel (no plugin defines SessionStart, so no
  double-fire) and shipped to `$LIB_DIR` by `install.sh`'s hook loop. Existing
  agents are backfilled into their `settings.json` by a one-shot pass.

- `5dive agent import --from-persona=<file.persona.yaml>` (DIVE-658 #2, Mark) —
  provision a **live agent from an OpenAgent persona**. The persona carries
  identity (name, role, look, voice, behavior); runtime config comes from flags
  (`--type` default claude, `--isolation`, `--model`, `--effort`, `--channels`,
  …). The CLI synthesizes a v1 character pack from the persona — a generated
  CLAUDE.md identity doc, the portrait fetched from `face.ref` as the avatar, and
  a manifest seeding `find-skills`/`5dive-cli`/`compile-knowledge`/`openagent` —
  then runs the normal import flow. Turns the openagent skill's self-**author**
  into self-**provision**: an agent can mint a persona and stand up a teammate
  from it. Structural gate mirrors the v0.1 schema's required fields.
- Fleet rollout of the `openagent` self-author skill (DIVE-658, Mark). Every
  agent-create path now seeds `openagent` (from `<org>/skills`) alongside
  `find-skills`, `5dive-cli`, and `compile-knowledge`, so new agents can author
  + validate their own OpenAgent persona out of the box. Covers all five types
  (claude, codex, grok, antigravity, opencode). Existing boxes are backfilled by
  `5dive-refresh-skills.sh` on the daily update cron (runs as the agent user,
  post-first-boot, idempotent — skips agents that have never booted to dodge the
  missing-`~/.claude` gotcha).

## [0.4.2] — 2026-06-23

### Changed

- `5dive digest` auto-delivery is now **opt-in, off by default** (DIVE-544, Mark).
  The per-box cron runs hourly but `digest tick` is gated on a per-box pref that
  defaults OFF — nothing is sent until a customer enables it. New
  `5dive digest on [--at=<0-23>] | off | status` writes that pref (stored in the
  state dir; `install.sh` seeds it off and never clobbers it, so the choice +
  custom hour survive CLI updates). `status --json` → `{enabled,hour,lastSent}`.
  Backs the telegram `/digest` command (DIVE-624). Each trial sends at most once
  per day, at the configured hour, box-local.

## [0.4.1] — 2026-06-23

### Added

- `5dive digest` (DIVE-544 Tier 1) — deterministic per-fleet standup digest built
  from data every fleet already has: the task queue (shipped in the last 24h /
  in-progress / open human gates), `usage` (token burn + share-of-limit), and
  heartbeat health. Zero agent reasoning, zero tokens; works on every fleet incl.
  a solo-agent box and never depends on a CEO/coordinator agent. `--json` for
  machines, `--7d` to widen the window. `--send` delivers it to the paired
  Telegram chat (same owner-channel path as the gate alerts). `5dive digest tick`
  is the cron driver, installed by `install.sh` as `/etc/cron.d/5dive-digest`
  (daily 07:00 box-local) so every customer fleet auto-receives its overnight
  recap.

## [0.4.0] — 2026-06-23

Headlined by `5dive loop` — agent-native multi-agent orchestration. Cuts the
accumulated 0.2.x–0.3.x rolling-fleet changes (point versions noted inline)
into a tagged release; the major bump marks loop as the new orchestration line.

### Added

- `5dive loop` — agent-native multi-agent orchestration (0.3.34, LOOP-7). Six
  machine verbs over the existing fleet primitives, all honoring a per-loop
  token `--ceiling` (self-halt + escalate-with-proof, never a surprise bill):
  `spawn` (the atom — backing task + heartbeat), `verify` (maker→verifier
  wrapper, DIVE-474), `panel` (N diverse-lens graders + quorum vote, cost-dial
  default N=3/quorum=2), `map` (index-aligned fan-out, null-on-fail, bounded
  concurrency), `until-dry` (K-empty-round discovery with seen-set dedup),
  `collect` (barrier gather). Plus the human control window: `task loops` now
  shows a live `loop_runs` board with `--runs`/`--watch`/`--kill <loopId>`
  (deferred-safe; read-only otherwise), and `usage loops` rolls up token spend
  per topology / per loop. New additive `loop_runs` table. 59 unit tests across
  tests/loop_*_unit.sh.
- `5dive hire <name> [--type=claude] [--role=… --title=…]` (0.3.33, DIVE-603) —
  ergonomic alias for `agent create` so demos/docs can say "hire a CTO" and have
  the real command match the story. Thin sugar: defaults `--type=claude`,
  forwards every other flag straight to `agent create` (inherits the full create
  surface), and peels off `--role`/`--title` to apply via `org set` once the
  agent exists. `agent create` stays canonical.

### Fixed

- `agent config <name> set telegram.allowed-users=<csv>` now actually writes the
  allowlist when set on its own (0.3.32). The dispatch that seeds `access.json`
  (`install_channel_for_agent` → `seed_telegram_access_allowlist`) was gated
  behind a token rotation or a `channels=telegram` change in the same call, so a
  standalone allowlist update validated, reported success in `applied_keys`, and
  silently no-op'd — leaving the file unchanged (e.g. a second id never landed).
  The guard now also fires when `telegram.allowed-users` is present, falling back
  to the stored connector token. Seeding remains additive (appends ids); use
  `agent telegram-access set` to remove an id or rewrite the list wholesale.

- Loop human-gates are now actually human-enforced (0.3.31, DIVE-560). A loop
  `gate:approval` step fired as `--type=decision` (purely to get the
  Approve/Do-better buttons), but a decision gate is agent-clearable — an agent
  could self-answer it (`need_answered_by=<agent>`), silently undercutting the
  public "you get the final say at the gate" claim. The gate now fires as
  `--type=approval`, which is human-enforced (the DIVE-394/519 agent-uid block +
  gate-proof); the standard Approve/Deny buttons cover it with no plugin change
  (a "denied" tap drives the loop's bounce-back-and-redo). Belt-and-suspenders:
  a loop approval gate only advances on a `need_answered_by=human:*` answer, so
  even an audited `sudo` clear can't progress the relay. Also fixed the
  bounce-match vocabulary — the approval reject value `denied` does not contain
  the substring `deny`, so without this a human's DENY would have wrongly
  advanced the loop.
- Heartbeat nudged the wrong task id (0.3.30). The wake `/goal` and every
  heartbeat log built the `DIVE-N` from a task's raw `id` column, but with the
  projects primitive (DIVE-484) the global row id and the per-project display
  number diverge as soon as a non-default project consumes ids — e.g. the 10
  `POST-*` rows pushed row 570's display ident down to `DIVE-560`. The agent was
  then told to complete a phantom `DIVE-570` it could never find/claim, so the
  nudge re-fired every tick and the starvation WARN fired. New `_hb_ident`
  resolves the true display ident from the row id; the numeric id stays the DB
  and registry key. Nudge text, the stale-task reaper logs, the materializer
  logs, and the tick wake/nudge/starve logs all now name tasks by their real
  ident.

### Added

- `5dive task escalate <id>` (DIVE-449): "flag for attention" — bumps the task's
  priority up one tier (capped at urgent), stamps `escalated_at`/`escalated_by`
  for audit, and best-effort pings both the owning agent and the paired human.
  Backs the new Escalate button on the Telegram `/task_<id>` detail view. Does
  not file a human gate (`task need`) or reassign (`task assign`).

## [0.1.88] — 2026-06-12

### Added

- Org-rename migration for EXISTING agents (follow-up to 0.1.87, gap caught
  by dev): each agent's persisted marketplace state — the source URL in
  `known_marketplaces.json` and the marketplace clone's git origin remote —
  still pointed at `5dive-com`. `5dive-refresh-plugins.sh` now rewrites both
  to the live org (same probe + `GH_ORG` override) at the top of each agent's
  refresh, before `plugin marketplace update` runs. No-op until the rename
  lands; idempotent after.

## [0.1.87] — 2026-06-12

GitHub org rename prep: `5dive-com` → `5dive-ai`.

### Changed

- All GitHub fetch sites (self-update, installer `REPO`, plugin/skill
  tarballs, marketplace registration, doc links) now resolve the org at
  runtime via a new `gh_org()` helper: probe `5dive-ai` once per process,
  fall back to `5dive-com`, `GH_ORG` env overrides. Installs and updates
  work identically on either side of the rename, so the old org can be
  parked immediately after renaming with no redirect window to squat.
- install.sh header now documents the canonical `install.5dive.com` alias
  instead of a raw GitHub URL.

## [0.1.84] — 2026-06-11

Catch-up release covering 0.1.78 → 0.1.84.

### Fixed

- `5dive init` / `agent create` no longer dies on a fresh OSS host with
  "bun not on PATH" (DIVE-265). install.sh deliberately never installs bun,
  and managed boxes get it from provisioning — so the first telegram agent on
  a clean self-hosted box hit a hard fail and pointed at `doctor --repair`.
  All five channel-plugin prechecks (claude/codex/grok/antigravity/opencode)
  now self-heal: when the agent user can't see bun, the CLI installs it
  system-wide (`BUN_INSTALL=/usr/local`, root-owned, visible to every agent
  user with no PATH wiring) and only fails if that install itself fails.
  Caught by lodar testing `5dive init` pre-HN, 2026-06-11.

- `agent config set channels=telegram` (and `channels=discord`) now stages the
  channel plugin synchronously before the deferred restart (DIVE-250). A bare
  `channels=<plugin>` with the token already on disk used to skip the install
  dispatch entirely, so the restarted session could boot with
  `--channels plugin:…` but no staged plugin — no channel tool, and the agent
  improvises (raw Bot-API curl, seen live on the demo box 2026-06-10). The
  dispatch now runs on every channel attach (the install helpers are
  idempotent), and a fail-closed gate refuses the restart with a clear error
  if the claude plugin cache dir is still missing after a short poll.

- `agent list` / `agent info` no longer abort when an agent's per-type runtime
  config is absent. The DIVE-211 model/effort enrichment reads each agent's
  config via `resolve_agent_model`/`resolve_agent_effort`; for `antigravity`
  those `jq` against `~/.gemini/antigravity-cli/settings.json`, which a
  `--defer-auth` agy agent does not have until its first boot writes it. The
  resolvers returned non-zero, and the unguarded `model=$(…)` assignment tripped
  the bundle's `set -e`, killing the command mid-build → empty output. Callers
  (and the smoke harness) read that as "agent not in registry" even though the
  agent was registered fine. The resolvers are now exit-0 on a missing/unreadable
  config (their documented best-effort contract), with `|| true` belt-and-
  suspenders at the call sites (DIVE-230).

### Added

- `agent list --json` now carries each agent's `model` and `effort` (DIVE-211),
  read the same best-effort way `agent info` already resolves them (empty →
  `null`; effort is claude-only). Lets the dashboard render a per-row model
  badge + model/effort picker without an N×`agent info` fan-out.

- Shared team bot quality-of-life across the span: `team-bot discover` finds
  the group id itself (DIVE-247, 0.1.81); new agents auto-attach to the shared
  team bot with their own forum topic, `--no-team-bot` opts out (DIVE-248,
  0.1.82, incl. the never-booted-agent fix); task-board `jq: Argument list too
  long` fix on big boards (DIVE-222, 0.1.79); task gate alerts follow the
  conversation to the last human chat (DIVE-259).

## [0.1.68] — 2026-06-07

### Added

- `task need --recommend="<option>"` (DIVE-148): the filing agent's advised
  choice. The human alert now leads with `✅ Recommended: <X>` before the ask,
  ⭐-marks that option in the numbered list, and sorts/⭐-prefixes its tap button
  first — so the owner sees the advised answer first instead of hunting for it.
  For a `decision` it must match one of `--options`; for `approval` it's free
  text (approved/denied); rejected for secret/manual. Button `callback_data`
  keeps the ORIGINAL option index, so the display reorder never renumbers the
  `tna:` payload. New additive `recommend` column; surfaced in `task show` +
  `task inbox`. The heartbeat nudge + notify-user skill now tell agents to keep
  the ask to one crisp question (detail in the body) and always pass a
  recommendation.

### Changed

- `task done`/`cancel` `--notify` ping shows only the result's FIRST line
  (`${result%%$'\n'*}`); the full result still lives on the record (`task show`).
  Keeps the owner's phone ping to a glanceable one-liner. (DIVE-150 follow-up)

## [0.1.67] — 2026-06-07

### Changed

- Heartbeat idle/blocked detection now uses the native `claude agents --json`
  signal (CC ≥2.1.162) instead of only scraping the tmux pane (DIVE-132).
  `_hb_agent_idle` consults `claude agents --json` first — matching the agent's
  inner-claude PID so dispatched background sub-agents are ignored — and reads
  that session's `status`: `idle` → idle, `busy` → working, `waiting` →
  **blocked** (with the `waitingFor` reason: permission prompt / worker request /
  sandbox request / dialog / input needed). This is more reliable than the
  byte-identical-pane heuristic and, crucially, distinguishes an agent **blocked
  on a prompt** (which should be surfaced/unblocked, not reclaimed) from one
  genuinely working from one idle. The pane-scrape remains as the fallback for
  non-claude CLIs (codex/grok/agy/opencode) and whenever the native signal is
  unavailable (claude not running, binary missing, no matching session). The
  no-clobber gate in the tick now defers on a blocked reading too and logs a WARN
  surfacing the block reason, so a wedged permission prompt is visible in the
  heartbeat log rather than silently deferred. New exit code `3` (blocked) and
  `_HB_IDLE_REASON` carry the distinction; idle-stall reclaim still fires only on
  a confident idle (rc 0), so a blocked agent is never reclaimed.

## [0.1.66] — 2026-06-07

### Added

- Recurring tasks step 2 (DIVE-138): the heartbeat tick now **materializes** due
  recurring templates into standard todos. A new `_cron_matches` evaluator
  (supports `*`, ints, lists, ranges, `*/n`, `a-b/n`, the day-of-month/day-of-week
  OR-rule, and Sunday as both 0 and 7) runs a materializer pass at the top of the
  tick — before the wake loop, and failure-isolated so it can never abort the
  wake — that clones each due template into a `kind='standard'` todo (copying
  title/body/priority/assignee/created_by). New columns `from_template_id`
  (instance → template link, used for the **skip-if-open** dedup so dailies don't
  pile up) and `fresh` (per-template clean-session pref, default on for recurring
  templates via `task add --recurring`, with `--fresh`/`--no-fresh` to override).
  The materialized instance carries `fresh` and the heartbeat `/clear`s before
  working it regardless of the agent-level fresh setting. A `last_fired_at` guard
  prevents a double-fire when two ticks land in the same matching minute.
  - **v1 limitation:** no catch-up for missed ticks — if the host is down over a
    scheduled minute (or the schedule is finer than the ~5m tick interval), that
    occurrence is skipped, not backfilled. Fine for coarse (daily/hourly) jobs.

## [0.1.65] — 2026-06-07

### Fixed

- `5dive agent send` / `agent ask` no longer silently drop large multi-line
  payloads. A big `send-keys -l` is absorbed by the TUI as a bracketed paste
  (`❯ [Pasted text #N]`) and a single trailing Enter raced into / was swallowed
  by the paste, so the turn never started and the message vanished — intermittent
  and size-correlated. New `inject_and_submit()` helper types the body, pauses so
  the paste commits, sends Enter, then confirms the pane left the unsent-paste
  state, retrying Enter up to 5x; if still unsubmitted it warns (`step`) instead
  of falsely reporting success. Both `send` and `ask` route through it.
  Live-proven on a throwaway agent (50-line paste submitted first Enter). (DIVE-147)

## [0.1.64] — 2026-06-07

### Changed

- `rotation set` now stamps `.rotation.lastSet` (`{by, at, fromEnabled,
  toEnabled}`) onto the registry, and `rotation get` surfaces it in both
  `--json` (a `lastSet` field) and human output (`last set: <to> (was <from>)
  by <who> at <ts>`). Writer precedence matches the audit log
  (`FIVEDIVE_AUDIT_USER` → `SUDO_USER` → `USER`). A concurrent-toggle war is now
  diagnosable from live state, not just the audit log. Legacy registries with no
  `lastSet` read back as empty, no error. (DIVE-126)

### Fixed

- `_mirror_send` Telegram posts are now time-bounded (`--connect-timeout 5
  --max-time 10`) so a hung or slow Telegram API can't wedge the foreground
  callers that run it after a DB write has already committed (`task need`
  notify, inter-agent outbound mirror). (DIVE-115)

## [0.1.63] — 2026-06-07

### Changed

- "Needs you" Telegram message drops the footer entirely (was the
  `5dive task answer <id> --value=…` CLI hint, then a dashboard pointer). Both
  were noise in a message the *user* receives: tap buttons cover
  decision/approval, and button-less gates (secret/manual) still surface on the
  dashboard "Needs you" card. The message is now just the header, the ask, and
  (for decisions) the numbered options + buttons.

## [0.1.62] — 2026-06-07

### Fixed

- "Needs you" Telegram message was hard to read and its tap buttons cropped.
  Now: the message separates header / ask / options / footer with blank lines
  (a long `ask` no longer renders as a wall), options are listed one per line
  and numbered to match the buttons, and the tap buttons use an adaptive layout
  — greedily packed up to a ~24-char width budget (max 3 per row) so short
  options share a row while a long label breaks onto its own full-width row
  instead of being truncated. Button index → `tna:` payload is unchanged, so
  the plugin's tap-to-answer handler still resolves correctly.

## [0.1.61] — 2026-06-07

### Added

- Recurring tasks, step 1 (data model + create path). Tasks gain a `kind`
  column (`'standard'` default | `'recurring'`) plus `schedule` (a 5-field cron
  expression) and `last_fired_at`. A `kind='recurring'` row is a **template**,
  not work: it's excluded from `task ls`, the heartbeat TODO count + wake, and
  the human inbox, so it's never picked up directly.
  - `task add --recurring="<cron>"` (alias `--schedule=`) creates a template;
    the cron expression is shape-validated and `--recurring` + `--parent` is
    rejected.
  - `task ls --recurring` lists templates with their schedule + last-fired.
  - Migration is additive (existing rows backfill to `'standard'`), zero risk.
  - Not yet wired: the materializer that clones a template into a todo on
    schedule (step 2) and dashboard CRUD (step 3).

## [0.1.60] — 2026-06-07

### Fixed

- `heartbeat tick` **never woke an agent**. `_hb_reclaim` printed its
  `reclaimed cancelled` counts with no trailing newline, so the caller's
  `read -r ... < <(_hb_reclaim ...)` returned non-zero (EOF before delimiter)
  and, under `set -euo pipefail`, aborted the whole tick right after the first
  enrolled agent's reclaim step — before any wake could happen. Tell-tale: every
  tick logged `checked 0` (the summary only printed when *no* agents were
  enrolled, so the loop body never ran) and a manual `heartbeat tick` exited 1
  with no output. Fixed by emitting the newline and guarding the caller `read`.
- `heartbeat`: `--no-fresh` was silently ignored. Both the `ls` display and the
  tick's wake path read `.heartbeat.fresh // true`, and in jq `false // true`
  evaluates to `true` (the `//` operator treats `false` like `null`), so a
  stored `fresh=false` was coerced back to fresh-on (the agent still got
  `/clear`). Now read with an explicit `has("fresh")` check.

### Added

- `task done` / `task cancel` accept `--notify`: DM the paired human a one-line
  `✅ [DIVE-N] done: <result>` / `⚠️ [DIVE-N] cancelled: <result>` summary,
  reusing the same best-effort Telegram poster as `task need`. The heartbeat
  nudge passes `--notify` so autonomous queue work surfaces a finish line
  without streaming full progress.
- `heartbeat` nudge now routes a task that needs a human decision/approval/
  secret/manual step to `task need` (files a "needs you" gate that pings the
  owner) instead of silently cancelling it; cancel is reserved for genuinely
  irrelevant/impossible tasks. The `/goal` terminal condition accepts a
  blocked-with-gate task as satisfied.

## [0.1.59] — 2026-06-06

### Changed

- `heartbeat tick`: an agent is no longer wedged for hours by a single stuck
  `in_progress` task. The old reaper only force-cancelled after `everyMin × 3`;
  the tick now unwedges via three escalating rules — (a) **orphan-by-restart →
  todo**: if the agent's live claude process started *after* the task did, the
  session that claimed it is gone (rotation/restart/crash/context-reset), so the
  task is reclaimed instantly; (b) **idle-stall → todo**: same process, but the
  task has sat past a 20m grace and the agent is idle now (claimed then walked
  away); (c) **hard cap → cancel**: the existing runaway backstop. (a)/(b)
  reclaim (work still needs doing); only (c) cancels. New `reclaimed` counter.
- `heartbeat tick`: **no-clobber wake gate** — never `/clear`+nudge an agent
  that's mid-turn or in a live conversation (the busy-guard only saw an open
  *task*, not interactive/working state). Uses a dumb, CLI-agnostic idle probe
  (pane byte-identical across a short sample + input prompt present). New
  `active` skipped counter.
- `heartbeat tick`: **wake-on-enqueue** — an `urgent`/`high` task that lands
  since the agent's last wake triggers an early wake on the next tick instead of
  waiting out the full cadence (still gated by busy/spread/idle).

## [0.1.58] — 2026-06-06

### Changed

- `heartbeat tick`: spread agents that share an Anthropic account so they never
  start together. Two same-account agents waking on one tick burst the shared
  account and trip a 429; the tick now requires an even slice of the cadence
  between same-account wakes (`gap = everyMin / agents-on-account`, e.g. 2 agents
  @ 60m → 30m apart, 3 → 20m) and self-heals as agents join. The account's last
  wake is derived from existing `lastRunAt` values plus an in-tick guard (no new
  state); deferred agents stay due and slide later until they clear the gap, so
  phases converge to even spacing on their own. Single-account agents and agents
  with no `authProfile` are never deferred. The tick also now processes
  oldest-waiting agents first so a fresher sibling can't starve an older one of
  the shared slot. Surfaced as `spread` in the tick's skipped counters.

## [0.1.55] — 2026-06-06

### Added

- **Tap-to-answer inline buttons on the `task need` ping** (DIVE-117, Part 1).
  The DIVE-105 Telegram alert now carries Telegram inline buttons for the
  finite-option gates — a decision's `--options` (one button each) and an
  approval (Approve / Deny) — so the human answers with a tap. callback_data is
  `tna:<numericId>:<idx|approved|denied>` (numeric id + option index, under
  Telegram's 64-byte cap; the value is re-resolved from the DB on tap, never
  trusted from the payload). **Gated to `type=claude`** agents — only the claude
  telegram plugin (0.4.59+) has the `tna:` callback handler today; codex / grok
  / antigravity keep the plain text ping until their handlers land (DIVE-118).
  Free-text / secret / manual gates are unchanged (nothing to button).
  `_mirror_send`/`_mirror_post` gain an optional `reply_markup` arg.

## [0.1.54] — 2026-06-06

### Added

- **Instant Telegram ping on `5dive task need`** (DIVE-105, the Human Task
  Inbox notifier). The moment an agent files a human gate, the paired human
  gets one DM — `🙋 [DIVE-N] needs you: <ask>` (with an `Options:` line for a
  decision), leading with the dashboard CTA and a `task answer` tail for
  power-use — so a gate doesn't sit unseen until someone opens the dashboard.
  Fires from the single `task need` chokepoint (no cron) and reuses the
  existing Telegram send path (`_mirror_post`). Targets the human DM allowlist
  (`allowFrom`), falling back to the agent's bound forum topic when no DM is
  paired, so the ask is never silently lost. Fully best-effort and self-gating
  in the shape of `mirror_interagent_outbound`: a missing token / access.json
  or a dead Telegram call returns 0 and never blocks or fails the gate write.
  The daily "still waiting" digest + >48h nudge are deferred to v1.1 (they need
  a per-box cron).

### Added

- **Human Task Inbox — `5dive task need` / `task inbox` / `task answer`**
  (DIVE-103, the CLI data layer behind the dashboard inbox feature DIVE-102).
  `task need <id> --type=decision|secret|approval|manual --ask="…" [--options=A|B]`
  parks a task on a human (status `blocked`; assignee set to the gating agent
  as owner-of-record). `task inbox` lists the still-pending gates,
  priority-ordered. `task answer <id> [--value=…]` records the answer,
  recomputes status (back to `todo` only if no task-blocker edges remain — the
  human gate and `block` edges share the `blocked` status), and best-effort
  pings the owning agent to resume via the existing agent-send path. Five
  additive, NULL-default columns on `tasks` (`need_type`, `ask`, `need_options`,
  `need_answer`, `need_answered_at`), surfaced in the `task ls` / `inbox` /
  `show` `--json` shape for the app to mirror. A `secret` gate never stores its
  value in the group-readable db (records only that it was provided; the agent
  loads the key out-of-band), and the resume ping never embeds the answer
  (avoids the group-chat outbound mirror leak).

## [0.1.52] — 2026-06-05

### Added

- **`5dive agent config <name> set effort=<low|medium|high|xhigh|max>`** —
  closes the parity gap with `set model=`. Reasoning effort is claude-only
  (writes `effortLevel` into the agent's `settings.json`, the same key the
  telegram plugin's `/effort` writes), validated against the five levels, and
  errors clearly for non-claude types. Applied via the existing deferred
  ~1s restart, like the model setter. `xhigh`/`max` are Opus-tier (Sonnet caps
  at `high`) — not gated by model here, matching the plugin picker.
- **`5dive agent info` now surfaces effort** — `effortLevel` is read alongside
  the model (`resolve_agent_effort`); rendered as `model · effort <level>` in
  text and as a new `effort` field (null when unset / non-claude) in `--json`.

## [0.1.51] — 2026-06-04

### Changed

- Agent welcome message: dropped em-dashes, reads the real configured model, and
  no longer prints a raw "default" placeholder.

## [0.1.50] — 2026-06-04

### Fixed

- **Account rotation silently failed to switch accounts** (also hit team
  accounts that repeatedly trip a usage/spend limit). `agent rotation rotate`
  builds the candidate list with `jq` using only `--argjson` args and no input;
  the call was missing `-n`, so when invoked from the StopFailure hook (empty
  stdin) jq processed zero inputs and returned an empty string. That empty
  string then crashed the next jq (`--argjson c ""` → "invalid JSON text"),
  aborting the rotate *after* it had already written the leaving account's
  cooldown. Net effect: the agent cooled the account it was on but never moved
  off it, so it sat parked on the limited account until a human re-logged in.
  Fixed by adding `-n` (`jq -c` → `jq -cn`). Rotation now reaches Tier-1/2/3
  selection as designed.

## [0.1.42] — 2026-06-02

### Fixed
- Rotation auto-resume now reliably **replies** on the new account. The fix in
  0.1.41 made the resume prompt parse, but it was still injected as a startup
  positional — which claude processes ~200ms *before* its telegram MCP server
  finishes connecting. That first turn's tool list therefore lacked the reply
  tool, so the resumed agent reported "MCP disconnected" and went silent
  (verified: prompt queued at T+0.147s, MCP connected at T+0.343s). Fix:
  `5dive-agent-start` no longer passes the prompt as an arg. It launches a bare
  `claude --resume <id>` and a deferred watcher types the prompt into the
  session only after claude's input prompt is ready + a short MCP-settle buffer
  — so the turn has the reply tool. Bare resume (manual `/resume`, no line-2
  prompt) is unchanged. Pairs with telegram plugin 0.4.51, which broadened the
  prompt to `continue and reply to the latest message`.

## [0.1.41] — 2026-06-02

### Fixed
- Account-rotation auto-continue now actually resumes the in-flight turn on the
  new account. `5dive-agent-start` seeded the resume prompt as a bare trailing
  positional (`claude --resume <id> … --channels plugin:telegram@… continue`),
  but `--channels` is a **variadic** flag — it swallowed `continue` as a second
  channel name, claude rejected it (`entries must be tagged`) and exited code 1,
  and the supervisor loop respawned a plain, idle, context-less claude. The new
  account then sat at the prompt until the user re-pinged. Fix: separate the
  prompt from the args with a literal `--` so option parsing ends before the
  positional turn (`claude --resume <id> … --channels … -- continue`). Manual
  `/resume` (no line-2 prompt) was unaffected and stays unchanged.

## [0.1.34] — 2026-06-01

### Added
- `5dive update --check` — read-only version probe (no root, no mutation):
  compares the installed CLI to the published release and reads the last
  managed nightly soft-update result, reporting `{current, latest, behind,
  stale, lastUpdateOk, lastUpdateAt}`. `stale` is true only when the box is
  behind **and** the auto-update isn't closing the gap (failed, never ran on
  record, or overdue past ~36h) — so it doesn't flag a box that's merely a
  release behind with a healthy nightly that'll catch up. Powers the dashboard
  maintenance "your CLI is out of date — update now" banner.

## [0.1.33] — 2026-06-01

### Added
- `5dive self-update` (alias `5dive update`) — on-demand upgrade for
  self-hosted boxes that have no scheduler of their own. Fetches `install.sh`
  and runs `--upgrade` (refreshes the CLI, `5dive-agent-start`, hooks, skills,
  the systemd template, and plugins via `5dive-refresh-plugins.sh`), then
  restarts every running agent so the refreshed plugins/CLIs actually load — a
  live agent keeps its old plugin in memory until it restarts, the usual cause
  of "plugin still shows the old version" after an upgrade. Root-only; `--json`
  reports which agents restarted. Managed boxes keep their nightly scheduler;
  running it there is a harmless, idempotent no-op beyond the restart.

## [0.1.31] — 2026-05-31

### Added
- `5dive agent skill --all list [--json]` — bulk variant that lists installed
  skills for every registry agent in a single invocation, looping serially.
  The dashboard's agents page previously rendered "Installed" pills by firing
  one `agent skill <name> list` exec per agent at once; each spawns a sudo+npx
  process, so on swap-bound boxes the concurrent fan-out saturated shelld, the
  control-plane fetch timed out, and the dashboard 502'd (the account-switch
  modal shares that exec path). The bulk command collapses N concurrent execs
  into one serial loop the box can absorb. `--all` only supports `list`; add/rm
  stay per-agent so a mutation's blast radius is always a single named agent.
  Per-agent extraction refactored into a shared `_skill_list_json` helper so the
  single and bulk paths derive the list identically; best-effort per agent (a
  failure yields an empty list, never aborts the loop).

## [0.1.26] — 2026-05-30

### Added
- `5dive agent config <name> set model=<id>` — uniform model switch that writes
  the selected model into the per-type runtime config the CLI loads, applied on
  the existing deferred restart. The symmetric write side of `agent info`'s
  `model` read, so each fork's `/model` can shell out to one CLI path instead of
  writing its own runtime config. Type-aware: codex/grok edit `config.toml`
  preamble-safely (replace an existing top-level `model =` or prepend above the
  first `[table]`, never binding the key to a section or duplicating it);
  claude/antigravity merge-write the `.model` key in `settings.json` preserving
  all other keys. Atomic (tmp + rename), existing owner/mode preserved, and
  refuses to create a missing config (so it can't drop other settings or
  suppress codex's first-run baseline). Not cached in the registry — `agent
  info` reads the live file, so a model changed via the native CLI stays
  authoritative.

## [0.1.25] — 2026-05-30

### Added
- `5dive agent info <name> [--json]` — single-agent detail that resolves the
  coding-CLI version and the selected model alongside the registry identity +
  live systemd state. The version comes from the type's `TYPE_BIN` binary
  (`--version`), the model from the per-type runtime config the CLI actually
  loads (codex/grok `config.toml`, claude/antigravity `settings.json`). Both are
  best-effort and surface as `null`/`—` when the runtime doesn't persist one
  (e.g. grok/antigravity default to the CLI's built-in pick). JSON fields:
  `cliName`, `cliVersion`, `model`. This lets each fork's `/status` read one
  uniform source instead of shelling every runtime's config itself (the binaries
  aren't on the agent user's PATH, and each type stores its model differently).

## [0.1.24] — 2026-05-30

### Added
- First-class **antigravity** (agy, Google's Gemini CLI) Telegram support
  (`TYPE_CHANNELS[antigravity]=1`). antigravity was already a first-class type
  everywhere else; this flips on the Telegram channel path — provisioning,
  cred-seed into `~/.gemini/channels/telegram/`, global `~/.gemini/config/`
  mcp_config + hooks wiring at boot, connector token + inter-agent mirror, and
  pairing / telegram-access — mirroring the grok path. All four agent types
  (claude, codex, grok, antigravity) now reach Telegram with full MCP tools +
  pairing.

## [0.1.23] — 2026-05-29

### Changed
- Post-pairing welcome DM is now per agent type. Previously every type got the
  Claude welcome — codex/grok bots greeted the user as "Claude agent" and
  advertised a model/effort (read from claude's `settings.local.json`) + voice
  that don't apply to them. Now `send_welcome_message` takes the agent type
  (threaded from `pair`) and branches: claude keeps its model/effort + voice
  line; codex/grok say "Codex agent (OpenAI Codex)" / "Grok agent (xAI Grok)"
  and drop the Claude-specific lines. Copy also refreshed across all three.

## [0.1.22] — 2026-05-29

### Changed
- Telegram access/pairing commands now work for **codex** and **grok** agents,
  not just claude (DIVE-4). All three share the same access.json schema
  (`{dmPolicy, allowFrom, groups}`) and path layout
  (`~/.<type>/channels/telegram/access.json`), so the fix is per-type path
  resolution rather than new logic. Affected commands:
  - `agent telegram-access get`/`set` — resolve the path by agent type via a
    new `_tg_access_state_dir` helper.
  - `agent pair` — code-roundtrip pairing now accepts codex/grok (path resolved
    as `~/.<type>/channels/<channel>/access.json`); openclaw/hermes stay
    token-only.
  - `agent telegram-pending-ignore` and `agent telegram-resolve-handle` — accept
    codex/grok instead of hard-failing "only applies to claude agents".
  - Inter-agent group mirror (`mirror_interagent_outbound`) resolves the sending
    agent's access.json by type, so codex/grok agents mirror to the group too.
  Previously all of these hard-failed for non-claude agents, forcing manual
  access.json edits to manage codex/grok bot allowlists.

## [0.1.21] — 2026-05-29

### Changed
- heartbeat: the wake nudge now issues a Claude Code `/goal` scoped to one
  concrete task id (the agent's highest-priority todo) instead of freeform
  prose. The agent loops turns until that task shows `done`/`cancelled` on the
  board, so it can no longer "do the work but forget to update status" and get
  re-nudged into the same task every tick.

### Added
- heartbeat: deterministic stale-`in_progress` reaper. Every tick (not gated by
  `everyMin`), any task left `in_progress` longer than `everyMin * 3` minutes
  (floored at 45m) is force-closed — `/goal clear` to stop a runaway loop, then
  auto-`cancel` with a result noting the timeout. This is the real hard cap:
  `/goal`'s own "stop after N turns" is model-judged and was observed to
  overrun, so cron enforces termination. No schema change (uses `started_at`).

### Note
- Rolls up the previously-unreleased 0.1.20 work (grok `~/.local/bin/grok`
  symlink fix) and the `agent list` heartbeat-cadence display.

## [0.1.15] — 2026-05-28

### Fixed

- antigravity agents now get the same `find-skills` + `5dive-cli` default
  skill inheritance every other type gets. Previously preseed only ran for
  `claude`, and the channel-installer seed steps (which cover codex/grok)
  don't route antigravity at all, so antigravity agents booted with an
  empty skills dir.
- `SKILLS_INSTALL_DIR[antigravity]` corrected from `.gemini/antigravity-cli/skills`
  (a guess based on agy's state dir layout) to `.agents/skills` (verified by
  grepping the `agy` binary for `{workspace}/.agents/skills/{skill_name}/SKILL.md`).
  The upstream `npx skills add --agent antigravity` fallback path already
  matched this — header comment was the only thing out of sync.

New `preseed_antigravity_agent` in `agent_setup.sh`, dispatched alongside
`preseed_claude_agent` in `cmd_create`.

## [0.1.14] — 2026-05-28

### Fixed

- `install_channel_for_codex_agent` now seeds `notify-user/SKILL.md` into
  `~/.agents/skills/notify-user/` and installs `find-skills` + `5dive-cli`
  via `npx skills add --agent codex`. Mirrors the grok 0.1.13 block — same
  class of bug (telegram-channel agent boots with no comms-loop skill,
  goes silent on first DM). Surfaced when `draft-codex` had an empty
  `.agents/skills/` despite being a codex+telegram agent. Unlike grok,
  codex is in the upstream `npx skills` registry, so the default skills
  go through the normal path rather than the manual-install fallback.

## [0.1.13] — 2026-05-28

### Fixed

- Three `grok` provisioning gaps surfaced by a live smoke test:
  - `5dive-agent-start` now seeds `/home/agent-<name>/.grok/auth.json` from
    `/home/claude/.grok/auth.json` (or `$PROFILE_STATE_DIR/.grok/auth.json`
    under a bound profile) at every boot. Previously the auth-gate in
    `cmd_create` passed because the type-level shared credential satisfied
    it, but the agent's own `~/.grok/auth.json` was never populated — so
    grok couldn't actually talk to xAI on first launch. Mirrors the codex
    seed block; mtime-gated so host-side `5dive auth login grok`
    re-rotations propagate on the next agent restart.
  - `install_channel_for_grok_agent` now copies `notify-user/SKILL.md` into
    `~/.grok/skills/notify-user/` for `--channels=telegram` agents, so the
    comms loop self-starts on the first DM (no manual nudge needed).
    Mirrors the claude-side seed in `preseed_claude_agent`.
  - Default skills `find-skills` + `5dive-cli` now install for grok agents
    too. Upstream `npx skills add` rejects `--agent grok` with "Invalid
    agents: grok", so a new manual-install fallback (`git clone --depth=1`
    + `cp -r`) in `install_default_skill_for_agent` and `cmd_skill_add`
    handles types upstream doesn't recognize. `_skill_needs_manual_install`
    is the single switch — add new types there when upstream rejects them.

## [0.1.12] — 2026-05-28

### Fixed

- `agent create codex` (and `agent install codex`) on hosts where a stray
  `codex` binary lives outside `/home/claude/.nvm/versions/node/v24/bin/`
  (e.g. `/usr/bin/codex` from apt, or under a non-v24 nvm major after
  `nvm install N` drifted the default alias). The previous recipe
  short-circuited on `command -v codex`, so npm install never ran and
  `cmd_install` then reported "install reported success but bin missing".
  Recipe now checks the exact `TYPE_BIN[codex]` path and forces
  `nvm use 24` before `npm install -g @openai/codex` so the bin always
  lands where downstream services expect it.

## [0.1.11] — 2026-05-28

### Added

- `grok --channels=telegram`. New `install_channel_for_grok_agent` writes
  the bot token + access.json into `~/.grok/channels/telegram/`, and
  `5dive-agent-start` now wires the telegram-grok MCP server +
  Stop/PreToolUse/Notification hooks into `~/.grok/config.toml` (absolute
  paths — `${GROK_PLUGIN_ROOT}` isn't documented for MCP command/args in
  grok 0.1.x, so we expand at boot). Mirrors the codex provisioning
  pattern (0.1.8) end-to-end. The launcher's existing `--always-approve`
  flag auto-trusts MCP/hook commands, so no separate trust-bypass step is
  needed.
- `install.sh` stages the telegram-grok plugin into
  `/usr/local/lib/5dive/telegram-grok` for customer VMs (same shape as
  the codex staging shipped in 0.1.9 — `5dive-agent-start`'s plugin
  resolver checks that path first).

## [0.1.10] — 2026-05-28

### Fixed

- `5dive-agent-start` now launches `grok` with `--always-approve` so tool
  executions (web fetch, shell, etc.) auto-approve instead of parking the
  agent on an interactive permission dialog. Without it, a single
  `reuters.com` fetch could stall a grok agent for 30+ minutes, blocking
  all inter-agent traffic until a human toggled yolo mode in the TUI.

## [0.1.9] — 2026-05-27

### Added

- `install.sh` now stages the **telegram-codex plugin** into
  `/usr/local/lib/5dive/telegram-codex` — a whole-subdir tarball from
  `5dive-com/5dive-plugins` plus `bun install --production` of its runtime deps
  (grammy). This is what makes codex `--channels=telegram` (shipped in 0.1.8)
  work on customer VMs and not just hosts with a `5dive-plugins` checkout:
  codex has no plugin marketplace, so its MCP server + lifecycle hooks run from
  this one shared copy, and `5dive-agent-start` already resolves
  `/usr/local/lib/5dive/telegram-codex` ahead of the dev checkout. `server.ts`
  resolves each agent's own state dir from `$HOME`, so a single staged copy
  serves every codex agent. Staging lives in `refresh_managed_files`, so the
  daily `update.sh` → `install.sh --upgrade` cron stages/refreshes it on
  existing VMs too (no separate update.sh change needed). Override the source
  with `CODEX_PLUGIN_TARBALL`; fail-soft (warns, doesn't abort the install) if
  the fetch or `bun install` fails.

## [0.1.8] — 2026-05-27

### Added

- **codex agents now support `--channels=telegram`.** `5dive agent create
  --type=codex --channels=telegram --telegram-token=…
  [--telegram-allowed-users=…]` wires the full telegram-codex bridge the same
  one-flag way claude does: it writes the bot token to
  `~/.codex/channels/telegram/.env`, seeds `access.json` from the allowlist,
  and at first boot appends the `[mcp_servers.telegram]` block plus the
  `Stop` / `PreToolUse` / `Notification` / `PermissionRequest` lifecycle hooks
  to the agent's `config.toml`. codex's first-run "Hooks need review" TUI
  prompt is auto-accepted once on first boot — codex then persists the trust to
  `[hooks.state]` so restarts never re-prompt. (codex's
  `--dangerously-bypass-hook-trust` flag only suppresses the gate for
  non-interactive `codex exec`, not the TUI, so it isn't used.) The plugin is a
  single shared checkout — resolved from `$TELEGRAM_CODEX_PLUGIN_DIR`,
  `/usr/local/lib/5dive/telegram-codex`, or the `5dive-plugins` checkout, in
  that order — and `server.ts` resolves each agent's own state dir from `$HOME`,
  so one copy serves every codex agent. telegram only; no discord build for
  codex yet. Note: customer VMs need the telegram-codex plugin deployed to
  `/usr/local/lib/5dive/telegram-codex` (install.sh staging is a follow-up); on
  the control-plane host the `5dive-plugins` checkout satisfies the resolver.

### Added

- `install.sh` now stages the **5dive-cli skill** under
  `/usr/local/lib/5dive/skills/5dive-cli/` (whole-directory: `SKILL.md` plus
  `references/`). Pulled via tarball from `5dive-com/skills`, mirroring how
  notify-user is staged. Pairs with the 5dive-api update.sh change that
  refreshes every agent's installed copy from this stage on the daily 03:00
  cron — so docs improvements (e.g. the new `task`/`org` reference sections)
  reach existing agents instead of being frozen at agent-create time.

### Fixed

- `5dive-agent-start` now dispatches `grok` and `antigravity`, fixing a
  crash-loop regression (`unknown AGENT_TYPE: grok|antigravity`). Both types
  were already first-class everywhere else in the CLI (`TYPE_BIN`, installer,
  auth, `agent create`), but the systemd launcher's case statement never got
  the matching branches — so `agent create --type=grok` succeeded, then the
  unit exited 2 on every spawn, racking up thousands of restarts. The
  per-type credential scrub also covers them now (same posture as
  hermes/openclaw — OAuth-via-file, no provider env vars).

### Added

- Inter-agent mirror can post into a forum topic: when the group entry in
  `access.json` carries a `message_thread_id`, mirrored `agent send`/`ask`
  traffic lands in that thread (e.g. a dedicated "#5dive" topic) instead of
  the supergroup's General channel.

### Fixed

- Inter-agent mirror now survives a group→supergroup migration. Upgrading a
  paired group to a supergroup (also how it gains forum topics) changes its
  chat id, and Telegram rejects sends to the old id with
  `migrate_to_chat_id`. The mirror now follows that, rewrites the stored group
  id in `access.json` (preserving owner/mode + the thread id), and retries —
  instead of silently posting nothing.

## [0.1.7] — 2026-05-27

### Added

- `5dive task` — a host-shared, sqlite-backed task queue any agent can use
  without sudo (store at `/var/lib/5dive/tasks/tasks.db`, in a group-writable
  `2770` subdir so writes need no root, unlike the root-only registry).
  Subcommands add/ls/show/assign/start/done/cancel/block/unblock/rm, with
  DIVE-N identifiers, subtasks (`--parent`), blocks-edges, a priority-ordered
  board view, and `--json` on every subcommand.
- `5dive org` — agent org chart over the same store: set/tree/show/ls/rm,
  with a `reports_to` subordination edge, reporting-cycle prevention, and a
  recursive-CTE tree view.
- `install.sh` + `5dive doctor` now install / verify `sqlite3`, required by
  the new task + org store.
- `install.sh` now installs the `5dive-hermes-perms.{path,service}` systemd
  units alongside the agent template. Hermes regresses
  `/home/claude/.hermes` to 0700 on every auth.json/config.yaml write,
  blocking `agent-<name>` users (in the `claude` group) from traversing
  to `venv/bin/hermes`. The path-unit watches the dir and the oneshot
  chmods it back to 0775. These units used to live only in the
  5dive-managed-cloud installer; moving them into OSS removes the last
  drift point between the customer-VM provisioner and the OSS source.
- `install.sh` now also pre-creates `/var/lib/5dive/agents.json` at mode
  640 root:claude (was lazy-created on first `5dive agent create`) and
  sets setgid 2750 on the state dirs so any file the root-only CLI
  writes inherits the `claude` group, letting `agent-<name>` users read
  their own per-agent env files.
- `5dive doctor` gained a `channels` category that verifies
  `/etc/claude-code/managed-settings.json` carries `channelsEnabled: true`
  + a `telegram@5dive-plugins` entry, and reads each agent's latest
  telegram-plugin MCP log to confirm whether claude's channel
  subscription is `registered` vs `skipped`. A `skipped` result is
  flagged as a likely Anthropic Teams org override and points the
  operator at the README setup snippet.
- `5dive init` prints a Teams-org heads-up after the Telegram pairing
  step pointing at `sudo 5dive doctor --category=channels` and the
  Anthropic Console setup snippet.

### Fixed

- `5dive-agent-start` no longer rewrites a codex agent's `config.toml` on
  every start. The required keys (approval policy, sandbox mode, project
  trust) are now written only when the file is missing, so `[mcp_servers.*]`
  entries added via `codex mcp add` survive agent restarts.

## [0.1.6] — 2026-05-25

### Changed

- `preseed_claude_agent` no longer wires the standalone StopFailure hook
  (`/usr/local/lib/5dive/stop-failure-telegram.sh`) into new fork
  (`telegram@5dive-plugins`) agents' `settings.json`. Plugin v0.4.4
  bundles the same hook via `hooks.json`, so preseeding the standalone
  copy would double-fire on every rate-limit (two DMs, two
  `resume-after-reset.sh` forks both pressing "1" on claude's
  Stop-and-wait menu). The standalone file stays installed by
  `scripts/install/agent-cli.sh` + `scripts/update.sh` for backward
  compatibility — agents on upstream `telegram@claude-plugins-official`
  still reference it. New upstream agents are unaffected by this
  change (channels=telegram defaults to the fork anyway since v0.1.5).

### Notes

- Companion change in `5dive-api/scripts/update.sh` strips the
  standalone StopFailure entry from existing fork agents' settings.json
  on the next 03:00 UTC customer-VM update cron — same shape as the
  existing `on_upstream_telegram()`-gated backfills, just inverted.

### Changed

- New `telegram` agents now preseed on the `telegram@5dive-plugins` fork
  instead of upstream `claude-plugins-official`. The fork bundles
  PreToolUse / Stop / PostToolUse hooks via `hooks.json` and ships
  richer slash commands (`/model`, `/effort`, `/agents`, `/status`,
  silence-watchdog). `agent_setup.sh` preseeds
  `enabledPlugins → telegram@5dive-plugins`, adds the fork repo to
  `extraKnownMarketplaces` alongside upstream, drops the duplicate
  hook entries (plugin owns them now), and writes
  `AGENT_CHANNEL_MARKETPLACE=5dive-plugins` into the agent env file so
  `5dive-agent-start` builds the right `--channels` arg.
  `install.sh` now also writes `/etc/claude-code/managed-settings.json`
  on first install so the channel-plugin allowlist permits both
  marketplaces (idempotent — preserves an operator-customized file).
  Existing telegram agents are unaffected; they stay on upstream until
  a 5dive-api `update.sh` pass migrates them.

### Fixed

- `stop-failure-telegram` now parses the rate-limit reset time from
  the StopFailure transcript instead of scraping the tmux pane.
  When claude shows the "Stop and wait" menu the pane switches to
  the alt screen and the "resets Xpm (TZ)" line is no longer visible
  to `tmux capture-pane`, so the fallback DM "Usage limit hit —
  waiting for reset." fired without the time-left tail and the
  resume-after-reset helper got no epoch. Transcript parse reads the
  structured rate-limit message claude logs
  (`isApiErrorMessage=true`, text containing "resets Xpm (TZ)") —
  authoritative and immune to tmux screen state. Pane scrape kept as
  last resort. Supersedes the 0.5s pre-capture sleep workaround.
- Plugin install pins the explicit `https://` URL for the marketplace
  `add` step. `claude plugin marketplace add owner/repo` resolves the
  GitHub shorthand to `git@github.com:owner/repo` (SSH) on some
  claude versions, which fails for `agent-<name>` users on customer
  VMs with no SSH key (`ERR_STREAM_PREMATURE_CLOSE` during clone).
  Affects both the new-agent install path and `update.sh` migration.

## [0.1.4] — 2026-05-23

### Fixed

- `antigravity` auth sentinel path. The scaffold's first ship guessed
  `~/.gemini/antigravity-cli/credentials.json` but agy 1.0.1 actually
  writes the token blob at `~/.gemini/antigravity-cli/antigravity-oauth-token`
  (no `.json` extension). The cmd_auth_poll mtime-check never noticed the
  successful OAuth landing and reported `error: antigravity exited without
  writing ...`. Confirmed empirically via the live-VM pair-test. Patches
  TYPE_AUTH + profile_type_auth_path + the comment block in cmd_auth_poll.
- Usage-limit Telegram pings narrowed to the calling chat. When an agent
  is paired with multiple chats (personal DM + team group), hitting the
  Claude usage limit was fanning the "Usage limit hit — resumes in …"
  alert (and its later "agent resumed" follow-up) to every chat in
  `access.json`. `stop-failure-telegram.sh` now scans the StopFailure
  payload's transcript for the most-recent telegram inbound and pings
  only that chat — same idiom `stop-telegram-reply-check.sh` already
  uses. Falls back to the full access.json list when no inbound is
  found (autonomous/cron-triggered sessions) so the alert isn't
  silenced.

### Added

- `grok` agent type. xAI's CLI. Binary lands at `~/.local/bin/grok`
  (symlinked from `~/.grok/bin/grok`); state under `~/.grok/`. OAuth uses
  the xAI device-auth flow (`grok login --device-auth` → URL
  `accounts.x.ai/oauth2/device` + a 4-dash-4 user code like `XJ9P-ZW8T`;
  CLI polls the endpoint itself and writes `~/.grok/auth.json`). Same UX
  shape as codex's device-auth — no callback paste. Also supports BYO API
  key via `XAI_API_KEY`. Run flag: `--permission-mode bypassPermissions`.
  Installer drops a competing `agent` symlink alongside `grok`; the
  TYPE_INSTALL recipe removes it post-install so future tooling isn't
  shadowed.

- `antigravity` agent type. Google's native-Go successor to gemini-cli.
  Installer lands `agy` at `~/.local/bin/agy` (no Node/nvm dependency).
  Run flag: `--dangerously-skip-permissions` (mirrors the claude family
  default). OAuth uses Google's consumer flow with redirect to
  `antigravity.google/oauth-callback` — UX is identical to the deleted
  gemini flow (URL displayed, waits 30s for either an OAuth callback OR
  a pasted authorization code). Wired into the device-code flow alongside
  claude/codex/hermes/openclaw. State dir is `~/.gemini/antigravity-cli/`
  — the binary identifies as `product=antigravity` but reuses Google's
  `~/.gemini` parent directory.

### Removed

- `gemini` agent type. Google's Gemini CLI is being sunsetted by Google in
  favor of Antigravity. Drops the `[gemini]` entries from all `TYPE_*` and
  `SKILLS_*` lookup tables, the `gemini` branch in the init wizard,
  `extract_gemini_url`, the gemini paperclip-seed case, the
  `GEMINI_SANDBOX` / `GEMINI_CLI_TRUST_WORKSPACE` overrides in the
  paperclipai drop-in, and the `gemini.env` connector path. Hermes /
  openclaw routing to Google's Gemini-2.0-flash model via a BYO API key
  is unchanged — that's a model id in Google's provider catalog, not a
  5dive agent type.

## [0.1.3] — 2026-05-22

### Changed

- Inter-agent group mirror moved to the sender side. `5dive agent send`
  (and `agent ask`) now posts `@<receiver>\n<body>` to the **sender's**
  group via the **sender's** bot, so both halves of an exchange show up
  under the correct identity. The previous receiver-side hooks
  (`userprompt-mirror-inter-agent.sh`, `stop-mirror-inter-agent.sh`) are
  retired as no-ops — they posted via the receiver's bot, so
  `marketing → main` showed up under `main`'s identity, and the reply
  hook double-posted (once as the payload, once as transcript
  narration). Files stay on disk so existing agents' `settings.json`
  don't error; new agents wire only the sender-side path.
- `stop-telegram-reply-check.sh` now decides at the **turn level**, not
  per text block. If the agent called `reply` or `edit_message` anywhere
  in the turn, all auto-relay is suppressed — every loose transcript
  block (preamble, progress, end-of-turn summary) is narration, not a
  missed answer. Eliminates the trailing `(auto-relay) ...` duplicates
  that landed in the user's DM right after the real reply.
- StopFailure Telegram alerts include the upstream API error string
  (e.g. "API Error: 529 Overloaded") pulled from the claude pane
  capture, instead of just naming the high-level `server_error` reason.
- Per-agent Telegram guidance moved out of the shared
  `projects-CLAUDE.md`. Telegram-paired claude agents now get a
  dedicated `telegram-agent-CLAUDE.md` dropped at
  `$HOME/.claude/CLAUDE.md` during agent setup, alongside the
  `notify-user` skill. Non-Telegram agents (codex on single-agent hosts,
  for instance) no longer carry the reply mandate or the bot
  references that didn't apply to them. `projects-CLAUDE.md` is trimmed
  to host-wide invariants only.
- Both `projects-CLAUDE.md` and `telegram-agent-CLAUDE.md` tightened —
  smaller token footprint on every agent's session prompt.

### Removed

- `posttool-telegram-relay.sh` retired as a no-op. The mid-turn relay's
  premise (loose mid-turn text = message the user should see) was
  wrong; preambles and progress narration are transcript text too and
  were getting curled to the user as noise. The legitimate "talked to
  the transcript instead of replying" miss is now caught by the
  turn-level Stop hook above.
- `SECURITY.md` removed. Security-reporting instructions inlined into
  the README, with `CONTRIBUTING.md` pointing at GitHub's private
  advisory page directly. Removes the "Security" community pill so the
  README/Contributing/License row stops overflowing on mobile.

### Fixed

- `install-smoke` CI workflow now ships `telegram-agent-CLAUDE.md` in
  the bundle. Without this, `install.sh`'s new curl for that file hit
  a missing source and bailed (curl exit 37).

### Documentation

- README: "How it works" clarifies that agents share CLI binaries and
  subscriptions, with a diagram showing two claude agents alongside one
  codex.
- `hooks/README.md` surfaces the three Telegram-plugin deadlocks in
  the table.
- README prose stripped of em-dashes (kept in the agent-type table
  where they mark n/a entries).

## [0.1.2] — 2026-05-20

### Added

- `5dive init` first-run wizard now includes a Telegram channel picker
  with auto-discovery — the wizard probes the bot's recent updates and
  offers detected chats as one-tap choices instead of asking the user
  to paste a chat id.
- `5dive agent send` / `5dive agent ask` accept `--reply-to-chat` and
  `--reply-to-msg`, so an agent can thread its inter-agent message into
  a specific Telegram conversation rather than picking the first paired
  chat blindly.
- `5dive telegram-pending-ignore` and `5dive telegram-resolve-handle` —
  CLI shortcuts the dashboard and the channel pairing flow lean on.
  `resolve-handle` accepts numeric chat ids and group titles in
  addition to `@usernames`.
- Default-on UI install: the local web dashboard install path is gone
  from OSS (see "Changed" below), but the underlying `--no-ui` flag was
  flipped to default-on for the install bits that remain.
- Ship `projects-CLAUDE.md`: `install.sh` drops a slim project-level
  `CLAUDE.md` at `/home/claude/projects/CLAUDE.md` (only if absent),
  symlinked as `AGENTS.md`. Gives every newly-spawned agent baseline
  guidance for switching its own model/effort, the Telegram reply
  mandate for paired agents, and the inter-agent messaging primitives.
- `hooks/README.md` documents the four (now six, after this release's
  inter-agent mirror split) hook scripts and their failure modes.
- README badges for CI status, latest release, and license.
- README — split the "have your agent install it" section into a
  same-machine prompt and a laptop-agent-installs-onto-remote-VM
  prompt; both end with the agent installing the `5dive-cli` skill
  so the user can keep managing 5dive through the same agent.
- README — `codex → hermes` image-to-animation example.
- README OG social-preview image.

### Changed

- Repo renamed `5dive-com/5dive-cli` → `5dive-com/5dive`. The
  short-url installer (`curl install.5dive.com | sudo bash`) keeps
  working unchanged; only direct `raw.githubusercontent.com` URLs in
  third-party docs need updating.
- Local web dashboard removed from OSS. The managed dashboard at
  5dive.com continues to ship for cloud customers; self-hosted users
  drive 5dive entirely from the CLI. Dropping the bundled Next.js app
  cuts the install footprint and removes a long tail of port-conflict
  / reverse-proxy questions.
- `install.sh --upgrade --no-ui` tolerated as a deprecated no-op (was
  previously rejected after the dashboard removal made the flag
  meaningless).
- README rewrite: tighter Quickstart, "Why 5dive" reframed around the
  three isolation tiers (Docker / systemd-user / dedicated-VM), "How
  it works" promoted above the fold, hero demo served via GitHub
  assets / jsDelivr so the inline `<video>` gets the right mp4 mime.

### Fixed

- `5dive auth login claude` now captures the token from
  `claude setup-token`'s TTY login flow (the upstream CLI started
  printing to its own /dev/tty, bypassing the redirected stdout we
  were grepping). Caught by `pair-test` against a fresh Hetzner box.
- UI new-agent flow: full OAuth state machine + Discord token handling
  + error recovery. The previous version assumed every OAuth attempt
  succeeded on the first poll and got stuck on the loading spinner
  when the upstream URL took two ticks to land.
- `init` ASCII logo spelled out 5DIVE properly; opencode reframed as
  BYO-provider (it ships with free models but the wizard implied you
  had to sign in).
- `src/header.sh` prepends `/usr/sbin` to PATH so `adduser`,
  `usermod`, `userdel` always resolve — first-agent-create was failing
  inside systemd-spawned shells where /usr/sbin wasn't on PATH.
- Hooks reliability pass surfaced by live use:
  - `stop-telegram-reply-check.sh` catches trailing assistant text
    that lands after a successful telegram tool call (the agent
    sometimes appends a sign-off the user never sees).
  - Inter-agent mirror split: the old sender-side `PreToolUse` mirror
    couldn't see heredoc-built command bodies. Replaced with a
    receiver-side `UserPromptSubmit` hook
    (`userprompt-mirror-inter-agent.sh`) plus a `Stop` reply mirror
    (`stop-mirror-inter-agent.sh`).
  - Rate-limit-resume text unified between the immediate ping and the
    detached `resume-after-reset.sh`; the auto-press-1 helper moved
    into the detached helper so it survives session teardown.
  - `pretool-telegram-question.sh` typographic-quote bug fixed (the
    template literal was getting smart-quoted somewhere in the
    pipeline and the deny message rendered with U+201C/U+201D).
  - Three follow-up fixes against the inter-agent mirror after first
    live use against `agent-marketing`.

[Unreleased]: https://github.com/5dive-ai/5dive/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.2

## [0.1.1] — 2026-05-16

### Fixed

- `install.sh` now installs `unzip`. The bun installer (`curl … | bash`)
  requires it, and on a clean ubuntu:22.04 it isn't preinstalled — the
  one-liner install was failing silently mid-script. Caught by the new
  install-smoke CI job on its first run.

### Added

- README — copy-paste prompt block for users who'd rather have their
  existing AI agent run the install (instead of pasting the curl line
  themselves).

## [0.1.0] — 2026-05-16

First public release.

### CLI

- `5dive agent` — create, list, send to, ask, watch, stop, delete agents.
- `5dive auth` — set / login / status / clear, with profile sharing across
  agents via `5dive account`.
- `5dive skill` — install + remove agent skills (incl. the bundled
  `notify-user` skill).
- `5dive compose` — declare an agent team in a YAML file and stand it up.
- `5dive doctor` — health check across systemd units, agent state, and
  per-type install status.
- `5dive init` — interactive first-run wizard for picking agent types,
  channels, and registering an initial agent.
- `5dive watch` — follow agent activity in the terminal.
- `5dive uninstall` (and `install.sh --uninstall`) — clean removal.
- `5dive --version` / `-v` sourced from a single `FIVE_VERSION` constant.
- Agent-to-agent messaging: every agent can `send` / `ask` any other agent
  on the same host.

### Installer

- One-liner installer (`curl install.5dive.com | sudo bash`).
- Sets up nvm + Node for the agent runtimes that need it.
- Idempotent: re-running won't touch your registry, auth profiles, or
  agents.
- `install.sh --upgrade` — refresh CLI binaries, systemd unit, and hooks
  only (skips apt/nvm).
- Runs `5dive doctor` automatically after install.

### Telegram

- Stop hook auto-relays missed replies for telegram-paired agents.
- `notify-user` skill for sending progress updates from agents.

### Docker

- Demo container under `docker/` for tire-kickers — runs without needing
  systemd or root on the host.

### Docs

- README — quickstart, auth model, agent-to-agent example, securing-your-server,
  telemetry policy, reverse-proxy recipe.
- Offline / air-gapped install recipe.
- Pointer for non-systemd / non-root users at the Docker path.
- SECURITY.md — private vulnerability reporting via GitHub advisories.
- CONTRIBUTING.md — dev setup, scope guardrails, bundle rule, PR expectations.
- Issue + PR templates.

### CI

- `bundle-drift` workflow — fails any push where the committed `5dive`
  bundle disagrees with `./build.sh` output from `src/`.

[0.1.1]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.1
[0.1.0]: https://github.com/5dive-ai/5dive/releases/tag/v0.1.0
