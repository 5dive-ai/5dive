## Unreleased — fix(task): every scheduled job heals itself by default: a failed run is tried again, and two empty runs tell the owner it may be broken

A run of a scheduled job that fails (cancelled after it started) is now tried once more, about 15
minutes later, before anyone hears about it. Both tries count toward the 3-in-a-row pause, so a job
that keeps failing still pauses and sends its one message. A job's run that ran and found nothing for
the owner closes with `5dive task done <run> --empty`; two in a row, on a job that messages its owner,
send the owner one line from that agent's bot: "<job> found nothing twice in a row. It may be
broken." `task ls --recurring --json` carries `found_nothing: {runs, told, since}` and `healing`.
`5dive task loop heal <job> on|off [--owner=yes|no|auto]` switches it per job. Jobs that message
their owner also get self-improving once a week (`task loop improve <job> weekly|off`): one AI turn
reads the week's runs and makes at most one change, which may only merge or drop a line. A healthy
run makes no AI call.
