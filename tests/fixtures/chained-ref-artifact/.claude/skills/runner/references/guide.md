# Guide

When the task finishes, the command writes a marker at `.claude/operation-completed.flag` and a
local override at `.claude/runner.local.md`. Read those single-file artifacts to detect completion;
they are project-level runtime files, not links into another skill's tree.
