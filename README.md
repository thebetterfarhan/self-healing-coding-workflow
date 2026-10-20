# Self-Healing Coding Workflow

A self-healing, self-repairing workflow for Codex, OpenCode and Command Code.

**Author:** Farhan Khan ([@thebetterfarhan](https://github.com/thebetterfarhan))
**License:** MIT

## Install

`
# 1. Unzip anywhere, e.g. ~/Documents/Codex
# 2. Install
cd tools
powershell -NoProfile -ExecutionPolicy Bypass -File ./setup.ps1
`

\setup.ps1 -Check\ reports what it would do and writes nothing.

Open a new PowerShell window afterwards, then run:

`
work 'Find the setting that controls focus return' -Preview
`

Read \START-HERE.md\ next. It is the shortest path to "useful".

## Requirements

- Windows 10/11 with PowerShell 5.1 (any modern Windows).
- git.
- At least one coding CLI (Codex, OpenCode or Command Code). The workflow
  degrades gracefully if one is missing.

## Optional

- **rtk** - token-saving command wrapper. Without it, commands run normally.
- **Superpowers skills** - guided workflows for the four task cues. Without
  them, the cues still work as prose instructions.
- **Audio feedback** - never installed by default.

The canonical skill set is **not** bundled. The workflow works without it: the task cues run as prose instructions.

## What is in here

| Path | What |
| --- | --- |
| \START-HERE.md\ | Read this first. |
| \SELF-HEALING-WORKFLOW.md\ | The complete reference, basics to advanced. |
| \WORKFLOW-USAGE.md\ | Operator quick reference. |
| \workflows/\ | Canonical config: the agent roster. |
| \workflow/\ | Install payload: the policy template, the starter taste, the permission template. |
| \	ools/\ | Every script. Plain PowerShell with a header comment each. |
| \html/\ | This documentation, published for a screen reader. |
| \LICENSE\ | MIT. |

## Check it any time

\\\
workflow-status
\\\

One screen: install state, the nightly job and its last result, drift per
layer, backend health, and spend. Exit 0 means healthy.

## The one thing to edit

\~/.commandcode/taste/taste.md\ - your preferences. It ships with a baseline
that you correct once. The nightly job renders it into every agent's
instruction file, so one edit applies to all three.

## The configuration repository

The workspace is a git repository that holds the configuration only - the
policy, the docs, \workflows/\, \workflow/\, \	ools/\ and the HTML. The
project repositories in the same folder are ignored.

\	ools/repair-config.ps1\ is the first step of the nightly job: it validates
every tracked file, restores a broken one from the last good commit and
records the validated state. It creates the repository if it is missing, so a
fresh install heals itself from the first run. There is no remote - nothing is
pushed.


## The nightly job

At 03:00 a scheduled task re-syncs the configuration, refreshes the model
catalogs, distils the day's sessions into memory, and rolls back any step
that fails. Log: \	ools/self-repair.log\.

Turn it off:
\\\
Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:\False
\\\

## Rebuilding the HTML

\\\
cd tools/docgen
npm install
node convert-docs.mjs
node verify-html.mjs
\\\

Built with marked 18.1.1 (MIT).