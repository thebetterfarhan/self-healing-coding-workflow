# Workflow Usage Guide

**Author:** Farhan Khan ([@thebetterfarhan](https://github.com/thebetterfarhan))

How to drive this Codex / OpenCode / CommandCode setup day to day. The
authoritative rules live in the global `~/.codex/AGENTS.md` and each project's
`AGENTS.md`; this file is the operator's quick reference.

The whole documentation set is also published as self-contained HTML in
`html/` — open `html/index.html` in a browser. Regenerate with
`node tools/docgen/convert-docs.mjs`.

## Health check

`tools/status.ps1` (also `workflow-status` in the shell) prints one screen: what is
installed, whether the layers agree, the nightly job and its last result,
drift in each synced layer, backend health, and spend. Exit 0 means healthy.

## Cue vocabulary

Type the cue as the first word of a request so the matching skill or agent runs:

- `design: <goal>` — agree on behavior before a large change (skill:
  brainstorming).
- `fix: <symptom and reproduction>` — diagnose to root cause, then add a
  regression test (skill: systematic-debugging).
- `execute: <approved plan>` — implement, delegating independent tasks to
  writers with disjoint file ownership (skills: executing-plans or
  subagent-driven-development).
- `review: <change>` — read-only review of a diff or branch that runs the
  checks, not just reading (skills: requesting-code-review plus
  verification-before-completion).

## The loop

1. Pick a typed task with a cue (above).
2. Small, low-risk change: stay in the current checkout. Risky or parallel
   work: make a worktree (below).
3. After each edit the agent runs the project's **inner loop** (fast check); at
   commit time it runs the **gate**. Both commands live in the project's
   `AGENTS.md`.
4. The agent stops before commit. Merge, push, PR, and release need your
   explicit approval.

## Public release

The kit is published at
**https://github.com/thebetterfarhan/self-healing-coding-workflow** (MIT,
public). The release asset is the same bundle `tools/package.ps1` builds, with
the canonical skill set left out - the skill set is not ours to redistribute,
and the workflow runs without it.

`tools/package.ps1 -NoSkills` builds exactly that public bundle; without the
switch it also bundles `~/.agents/skills` for local use.

## Change something

One source per thing. Edit the source, run one command, done. The copies are
generated - never edit them.

| What you want to change | Edit this one file | What the nightly does with it |
| --- | --- | --- |
| The rules every agent follows | `~/.codex/AGENTS.md` | copies it to the OpenCode and Command Code copies, and the taste block into the Claude and Gemini ones |
| Your own preferences | `~/.commandcode/taste/taste.md` | renders them into the taste block of every instruction file |
| The agent roster (scout, builder, ...) | `~/Documents/Codex/workflows/agents.toml` | renders each agent into all three CLIs |
| A skill | `~/.agents/skills/<name>/` | copies it into all three CLIs |
| Routing, models, the turn cap | `~/Documents/Codex/workflows/workflow.toml` | the tools read it directly |
| The engine (the scripts) | `~/Documents/Codex/tools/` | the nightly runs them |
| The documentation | `~/Documents/Codex/*.md` | `node tools/docgen/convert-docs.mjs` rebuilds `html/` |

After editing, one command applies and records everything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/self-repair.ps1
```

It syncs every layer, refreshes the model catalogs, restores a broken file
from the configuration repository, and commits the change. The nightly runs the
same thing at 03:00, so editing and waiting also works.

Publishing is a separate, occasional step: `tools/package.ps1 -NoSkills` builds
the public bundle with the current policy, scripts and docs - and without the
skills.

## The configuration repo

`~/Documents/Codex` is a git repository holding the workflow configuration
only: the policy, the docs, `workflows/`, `workflow/`, `tools/` and the
published HTML. The project repositories in the same folder are ignored - each
keeps its own history, and there is no remote, so nothing is ever pushed.

The nightly job validates every tracked file and restores a broken one from the
last good commit, then records the validated state:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/repair-config.ps1 -Check
```

`-Check` writes nothing: it reports the broken file and exits 1. Without it the
script also restores and commits. The broken copy is kept next to the file as
`<name>.broken-<stamp>`. `tools/verify.ps1` runs the same check as part of the
gate, and `tools/status.ps1` shows the repository state on its one screen.

## Automatic continuation

`tools/auto-next.py` keeps one explicit task going on one backend until it says
it is finished:

```powershell
python tools/auto-next.py --backend codex --workdir C:\path\to\repo "Fix the broken focus return after Back"
```

The backend is `codex`, `opencode`, or `commandcode`. The runner sends another
turn only when the reply ends `AUTO_NEXT_STATUS: CONTINUE`, and it resumes the
session id the first turn returned - never a different ticket. `DONE`,
`BLOCKED`, a missing marker, a missing session id, a CLI failure, or the turn
cap stops the run. Exit 0 means done, 2 means blocked or capped, 1 means it
stopped on an error. The cap is `continuation.max_turns` in
`workflows/workflow.toml` (5 today). Model, reasoning effort, and permissions
stay with the CLI you pick. It launches the npm shims, so `codex` is the 0.163.0
shim and not the desktop copy. Inner check:
`python -m unittest tools/test_auto_next.py`.

## Worktrees (one per task)

```
wt -Repo tv-launcher -Name fix-focus -Base master
```

Creates `<workspace>\.worktrees\<repo>-<name>`, branches from `-Base`, and
copies the repo's gitignored local files. A repo declares those files in
`.worktreeinclude` (gitignore-style, one pattern per line); without it a
built-in Android/env list is used. Add `-Preview` to see the plan first.

Rules:

- Cap 2–3 in flight; review capacity is the limit, not compute.
- Give each worktree its own dev-server ports and scratch database.
- Put the worktree name in the first message: "work only in this worktree."
- Clean up when merged: `git worktree remove --force <path>`, then
  `git branch -D <name>`.

## Distribution of work

- One writer per file. Parallel agents may read freely; only one may edit a
  given file.
- One helper unless the work truly separates (disjoint files, no shared state).
- Give each agent a precise question, file ownership, constraints, acceptance
  criteria, and the exact test command.
- For an audit, use the read-only `review` agent. For locating code, use
  `scout`.

## Project instruction files

- Each active repo keeps its own `AGENTS.md` with the build/test/run commands
  (inner loop and gate) and its accessibility rules. That file is the source of
  truth for commands.
- Keep instruction files lean (target under ~150 lines); move long, rarely used
  procedures into skills that load on demand.

## ADHD-friendly rituals

These externalize functions that are unreliable, not teach discipline.

- **Session start:** "Read recent git history and `HANDOVER.md`; tell me status
  and the next three steps."
- **Session end:** "Summarize what changed and write it to `HANDOVER.md`."
- **Small steps:** "Break this into 5-minute subtasks that each give a sense of
  completion." Each finished step is momentum.
- **TDD as a stop signal:** red-green-refactor makes "done" explicit.
- **Commit at every boundary** with a message written to future-you, e.g.
  `WIP: extracting UserService; next: write tests`. Named stashes are context
  bookmarks.
- **`PARKING_LOT.md`:** new ideas go in the file, never straight into code.
- **Working blocks:** 90/20 ultradian blocks with a flexible wrap-up, not rigid
  25-minute timers, which break hyperfocus.
- **Body doubling:** FocusMate, or "describe what I should be doing right now as
  if you were sitting next to me."

## Local-only commits

`nuviotv` `dev` carries local commits (`gradle.properties` + cache flags, `nuvio.localAbi`, `.worktreeinclude`, `ACCESSIBILITY_HANDOVER.md`). They are deliberately **not for upstream**. Never push `dev` there; check drift with `git log --oneline origin/dev..dev`.

## Release gate

Before any push of a release, run one command per repo:

```powershell
.\Documents\Codex\tools\release-gate.ps1 -Repo <path> -GateCommands <gate from the repo's AGENTS.md>
```

It fails fast on: dirty tree, unpushed/untracked commits (`-AllowUnpushed`
for local-only releases), tracked secret-shaped lines, gate commands with
non-zero exit, and with `-Apk <apk>` it verifies the signer (apksigner from
Android build-tools 36.0.0). `-DryRun` lists the steps without running them.
Evidence is numbered PASS/FAIL per step.

## Lessons (`LESSONS.md`)

Each repo keeps a top-level `LESSONS.md` (create on first lesson, it's fine
untracked). One dated entry per failure mode: what broke, the detection
signal, the prevention rule. Session start reads it with the handover; before
a large refactor, re-read it. Records are appended, never pruned.

## Best-of-N for hard tasks

For a deep-tier task where the first attempt is likely wrong, ask for
"best-of-2": `agent-task.ps1 -N 2` clones the task into two isolated
worktree sandboxes (`wt`-style, so files never collide), runs both attempts in
parallel, then shows both reports and the diff summary for you to pick
manually.

## Guard hook (applies while Codex runs)

`~/.codex/hooks.json` installs `tools/guard-hook.ps1` as a PreToolUse gate:
Codex `apply_patch` calls touching `*.keystore`, `*.jks`, `keystore.properties`,
`local.properties`, `*.pem`, `*.key`, `.env*` — or adding secret-shaped
lines — are denied with a reason. Every PreToolUse event runs Claudio first,
then guard-hook (which only denies); Stop/SessionStart and the other lifecycle
events stay with Claudio. Back
up `hooks.json` before editing; the script has an assert self-test
(`guard-hook.ps1 -SelfTest`).

## Skill sync

`~/.agents/skills` is the canonical skill set (71 skills; edit skills there).
`tools/sync-skills.ps1 -Check` lists pending diffs and exits 2 when any are
pending; running it applies a
one-way push to `~/.codex/skills`, `~/.config/opencode/skills`,
`~/.commandcode/skills`. Dest-only skills are pruned (a skill you move out of
`.agents` disappears from the CLIs too; `-NoPrune` skips that). `.system`
never ships.

## Daily self-repair

Runs daily at 03:00 as scheduled task `CodexWorkflowSelfHeal`: syncs
taste/agents/instructions, refreshes the free-model list, runs the memory
pipeline, tier adapt, taste promote, credit check, and `verify.ps1` (details
in the `self-repair.ps1` header). Log: `tools\self-repair.log`. Disable with
`Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:$false`.

Before each step, it snapshots managed live state under `tools\self-repair-backups`.
On failure, it restores that state and records details in
`tools\self-repair-failures.log`. It keeps the five latest runs; timestamped
`AGENTS.md.bak-*` safety backups are pruned to the 5 latest by
`sync-agent-instructions.ps1`.

## Model-cost visibility

`agent-usage.ps1 -Json` carries OpenCode's recorded
spend straight from opencode.db: total/24h/7d assistant-request cost and the
top models by cost. `-Refresh` is a no-op (cooldowns self-update from run
results); codex subscription numbers are not readable headlessly.
(Assistant messages on free or subscription models record
cost exactly 0, so a 0 in a window means the traffic was free-tier.)

## Codex backend (since 2026-10-18)

- `credit-check.ps1` no longer marks codex unhealthy - the old 365-day
  subscription lockout is gone; health comes from real run results (30-min
  flags set/cleared by `agent-task.ps1`).
- `work` runs codex through the npm shim
  (`%LOCALAPPDATA%\BlindPilot\npm\codex.cmd`, 0.163.0), not desktop
  `codex.exe`: desktop 0.162.x ships the broken Windows sandbox helper
  (openai/codex#51634 — read-only exec dies with `setup refresh had errors`).
  If 0.163 ever regresses on read-only, pin with
  `npm install -g --prefix %LOCALAPPDATA%\BlindPilot\npm @openai/codex@0.160.0`.
- The Codex desktop app's own sandboxed sessions stay broken until OpenAI
  ships an updated helper; the CLI workflow is unaffected.

## Out of credits

The chain heals itself: primary backend → same backend on a free model → every
remaining backend, each retried on a free model. A provider credit error counts
as a failure even when the CLI exits 0 (Command Code v1.84.0 exits 0 after
`Insufficient credits for Command Code.`), so the chain keeps going instead of
reporting a task that never ran. A backend whose paid model died on credits is
held unhealthy and marked paid-exhausted, so the next run starts on a free
model. Codex's `try again at 5:11 AM` is parsed and the backend is held for up
to an hour (its printed reset time is not reliable). Details:
`SELF-HEALING-WORKFLOW.md` §10 and §12.

## After changing configuration

Restart the tool after editing its config. `~/.codex/config.toml`,
`~/.codex/rules/*.rules`, and hook state load at session start; a running Codex
may rewrite `config.toml`, so verify a hand edit after the next start.
