## Unreleased — feat(task): change when a recurring task fires, without re-creating it

`5dive task set-schedule <task> "<cron>"` changes the 5-field schedule of an existing recurring
task. It keeps the task's number, history, time zone and last run; before this, the only way was
to add a new recurring task and remove the old one. The new time is live on the next tick. A run
the old schedule still owed (held back by the pacing floor) is dropped, so it does not fire late
on the new clock. `--json` answers `{ident, schedule, schedule_tz, prior, changed}`.
