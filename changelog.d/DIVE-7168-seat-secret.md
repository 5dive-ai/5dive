## Unreleased — feat(secret): an agent seat saves an API key it made, never replacing one it did not save (DIVE-7168)

The browser seat now makes the accounts and API keys a team needs (lodar, 10-28: "from now all
browser does any job - human not needed"). It could not keep one: `secret write` is root, and a
standard seat's grant holds neither it nor the root CLI. On the Dropshipping rerun box Clicker
made a CJ key and the lead had to read it off the page a second time.

- **`5dive secret write <KEY> --connector=tools` works from a standard seat, with no sudo.** It
  crosses one exact sudoers line, `_seat_secret` (no args, no wildcard): the key name and value
  go on stdin, the seat is derived from `SUDO_UID`. Only the shared tools store, under the same
  reserved-name rule as a root write (a credential name; never `ANTHROPIC_API_KEY`, `PATH` and
  the like). One line only, never printed.
- **It cannot swap anyone's key for its own.** A new name is saved; a name already saved is
  replaced only by the seat that saved it. One the owner saved, or another seat saved, is refused.
  `tools.writers` (root 600, beside `tools.sh`) records who saved each key, and an owner's write
  makes the key the owner's again.
- **A seat's save is not a person's drop:** it never marks a secret gate provided. `--task`, any
  connector but `tools`, and a seat without the grant keep today's root-only path.
- A new seat gets the grant at `agent create`; an existing standard seat at the next install or self-update (`agent _reconcile_sudoers`, which adds it because the classifier knows the line).

`tests/seat_secret_write_unit.sh` 26/26; `agent_rights_unit` 72/72, `agent_list_batch_unit` 14/14,
`agent_sudo_grant_unit` 40/40, `self_account_rail_unit` 42/42, `secret_tools_connector_unit` 79/79.
