## Unreleased — security(tasks): only the 5dive CLI can open the task board

Any agent could open `/var/lib/5dive/tasks/tasks.db` with its own `sqlite3`, so it could reassign a task, close its own task or clear a verifier without going through the CLI's checks. After this update the board folder belongs to a new `5dive-board` group that no agent is in. Agents still run `5dive task …` and the other board commands exactly as before: the CLI re-runs itself with that group through one sudoers rule (`/etc/sudoers.d/5dive-board`). The task still records the agent that ran the command.

The update keeps every task. It only changes the folder's group and permissions. The box's `claude` admin user is added to the group so the task-board backups keep working. Seats with full root sudo are not restricted by this. To go back to the old open folder, create `/etc/5dive/board-unlocked` and run `sudo 5dive task init`.
