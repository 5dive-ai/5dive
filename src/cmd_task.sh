
# -------- 5dive task — module loader --------
#
# DIVE-3278: `task` was a single 15,039-line src/cmd_task.sh — 19% of the source
# tree. It is now src/task/*.sh, one file per concern (see each file's header).
#
# This file is DEAD CODE IN THE BUNDLE and LOAD-BEARING IN THE SPLIT TREE — the
# same idiom src/lib/self.sh uses (build.sh's "Order matters" note; the wiki's
# command-v-answers-the-wrong-question rule 5). build.sh cats every src/task/*.sh
# ahead of this file, so by the time the bundle reaches these lines every guard
# below is already satisfied and nothing is sourced. In the split tree nothing has
# been cat'd, so `source` is what makes `. src/cmd_task.sh` still yield the whole
# of `task` — which is what ~60 tests under tests/ do, and why splitting the file
# did not need to touch a single one of them.
#
# Keep the src/task/*.sh order below identical to build.sh's: a handful of files
# open with top-level `readonly`/regex assignments that later files read.
# CONSEQUENCE, stated because it bit a test: sourcing this file a SECOND time is a
# no-op, because the guards below are satisfied by the first load. A harness that
# `unset -f`s a task function and re-sources to restore it must source the MODULE
# that defines it (src/task/<file>.sh), not this loader.
_task_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F cmd_task >/dev/null 2>&1 || . "$_task_src_dir/task/dispatch.sh"
declare -F _task_resolve_coordinator >/dev/null 2>&1 || . "$_task_src_dir/task/routing.sh"
declare -F cmd_task_add >/dev/null 2>&1 || . "$_task_src_dir/task/crud.sh"
declare -F _gate_tok_note >/dev/null 2>&1 || . "$_task_src_dir/task/gate_evidence.sh"
declare -F _task_guard_result_over_closed >/dev/null 2>&1 || . "$_task_src_dir/task/status.sh"
declare -F cmd_task_deliver >/dev/null 2>&1 || . "$_task_src_dir/task/delivery.sh"
declare -F cmd_task_loops >/dev/null 2>&1 || . "$_task_src_dir/task/loops.sh"
declare -F cmd_task_precedent >/dev/null 2>&1 || . "$_task_src_dir/task/need.sh"
declare -F _task_agent_channel >/dev/null 2>&1 || . "$_task_src_dir/task/notify.sh"
declare -F cmd_task_coordinator >/dev/null 2>&1 || . "$_task_src_dir/task/inbox.sh"
declare -F _loop_answer_is_bounce >/dev/null 2>&1 || . "$_task_src_dir/task/answer.sh"
unset _task_src_dir
