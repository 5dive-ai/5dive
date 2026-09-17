## Unreleased — fix(task): `task verifier` no longer runs its own SQL comment (task-verifier-sql-comment-backticks)

Every successful `5dive task verifier <id> <agent>` printed
`/usr/local/bin/5dive: line N: task: command not found` on stderr. `cmd_task_verifier`
builds its UPDATE as a **double-quoted bash string**, and two of the SQL `--` comment lines
inside it quoted a command name in markdown backticks. Backticks in a double-quoted string
are command substitution, so bash ran `task add --verify` — a binary that does not exist,
the verb is `5dive task` — before sqlite3 ever saw the statement, and spliced the empty
result into the comment.

The row was written correctly and the exit status was 0, which is why it lived this long:
every signal a caller reads said the verb worked, and the only evidence was a line on
stderr that looked like it came from something else. On a box that greps agent logs for
`command not found` it is a standing false positive on a healthy verb.

The fix is the two lines: `'single quotes'` instead of backticks. Nothing else changes —
the comment is inert to sqlite either way. A repo-wide scan for the same shape (a backticked
`--` comment sitting in a live double-quoted string, rather than in the `<<'SQL'` heredocs
`src/lib/tasks_db.sh` uses) found no other site.

`tests/task_verifier_sql_comment_backticks_unit.sh` runs the verb and asserts stderr carries
no bash diagnostic, then rebuilds `cmd_task_verifier` from the working tree **with the
backticks put back** and asserts the diagnostic reappears — a clean arm alone would stay
green against an empty stderr it never captured. The mutant arm also pins rc 0 and a correct
`verifier` column under the defect, which is the property that hid it.
