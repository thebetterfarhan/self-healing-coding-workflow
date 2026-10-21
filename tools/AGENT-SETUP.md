# Agent setup — workflow reference

How the three coding CLIs on this machine are wired. Read this before changing
any of their config, so the three stay coherent.

The whole configuration - the policy, the docs, `workflows/`, `workflow/`,
`tools/` and the published HTML - lives in a git repository at the workspace
root. `tools/repair-config.ps1` validates every tracked file, restores a broken
one from the last good commit and records the validated state; it is the first
step of the nightly job. The project repositories in the same folder are
ignored. See `WORKFLOW-USAGE.md` for the operator view.

## Start here

`tools/status.ps1` is the one-screen health check: install state, the nightly
job and its last result, drift per layer, backend health, and spend. The shell
alias is `workflow-status` (short form `wf-status`).

In BlindPilot, describe the task normally. You do not need to choose an agent,
model, or Superpowers skill first. In a new PowerShell window, change to
the repository and run one command:

```powershell
work 'Fix the broken focus return after Back'
```

`work` announces its route in one line, then runs the task. Superpowers guides
the selected agent through applicable workflows. Use `work '<task>' -Preview` only when you want to inspect
the route. The rest of this document is reference material.

For automatic follow-up turns on one task, run the separate Python 3.11+ CLI
runner from a PowerShell terminal:

```powershell
python tools/auto-next.py --backend codex --workdir C:\path\to\repo "Fix the broken focus return after Back"
```

Choose `codex`, `opencode`, or `commandcode` explicitly. The runner reads
`workflows/workflow.toml` `[continuation].max_turns`, keeps the returned CLI
session, and continues only after the final `AUTO_NEXT_STATUS: CONTINUE` line.
`DONE`, `BLOCKED`, missing status, errors, and the turn cap stop it. It does not
start another ticket or change backend permissions, model, or reasoning effort.
It is separate from interactive BlindPilot turns. Inner check:
`python -m unittest tools/test_auto_next.py`.

It launches the npm shims (`codex.cmd` 0.163.0, `commandcode.cmd`,
`opencode.exe`) rather than the bare names: PATH also holds extensionless node
shims that cannot be launched directly, and a bare `codex` would find the
desktop copy (0.162.x) with the broken Windows sandbox helper.

## Cross-CLI handoffs

Codex, OpenCode, and CommandCode load the same `agent_interop` MCP server from
`tools/agent-interop/server.mjs`, with their own CLI name as its argument. The
server exposes `agent_route_preview`, `agent_handoff_start`, and
`agent_handoff_status`. Give it the target CLI, task, working directory,
complexity (`auto`, `quick`, `standard`, or `deep`), and mode (`read` or `edit`).
It selects the target model and reasoning effort through `agent-task.ps1`.
Start returns a job ID; poll status for the result. This keeps nested CLI runs
out of the parent turn's synchronous call.

An edit handoff creates a detached Git worktree from `HEAD` and leaves it for
the caller to inspect and integrate. Uncommitted and ignored files from the
source checkout are absent. Read handoffs run in the supplied directory.
OpenCode read handoffs use the `interop_read` agent, which permits only file
reading, search, and LSP inspection; it denies shell, edits, subagents, and
MCP tools even though normal OpenCode sessions retain their existing permissions.
OpenCode edit handoffs use `interop_edit`, which allows worktree edits and
commands while setting `external_directory`, subagent, and MCP permissions to
deny. This is a CLI permission boundary, not an OS sandbox for shell commands.
The bridge rejects same-CLI and recursive handoffs, runs at most two jobs per
MCP server process, and ends a running job after 30 minutes. Closing the MCP
server stops its active jobs; job IDs exist only for that server session. Its
worktree is isolation from the source checkout, not an operating-system
sandbox; review the result before integration. Direct `work` inside BlindPilot
remains unsupported.

Inner check: `npm test --prefix tools/agent-interop`. Gate: that check plus
`sync-agent-instructions.ps1 -Check`, `codex mcp list`, `opencode mcp list`,
and `cmd mcp list` from a new shell. Restart existing CLI sessions to load
their new MCP settings.

## Tools and where their config lives

| Tool | Global instructions | Settings |
| --- | --- | --- |
| Codex | `~/.codex/AGENTS.md` | `~/.codex/config.toml` |
| OpenCode | `~/.config/opencode/AGENTS.md` | `~/.config/opencode/opencode.jsonc` |
| CommandCode | `~/.commandcode/AGENTS.md` | `~/.commandcode/settings.json` |

Project-level `AGENTS.md` files live in each repository and add to — never
duplicate — the global policy.

## Keeping something private out of a bundle

`tools/package.ps1` refuses to build a bundle that contains a private key, a
token, a machine path, a generated taste block, or anything in the built-in
leak patterns. Personal patterns — your own addresses, anything else you would
not want published — go in `tools/leak-patterns.local.json`, which is
git-ignored and never shipped:

```json
{
  "patterns": [
    { "name": "user email", "pattern": "me@example\\.com" }
  ]
}
```

Write the pattern there, not into `package.ps1`. A pattern in the script ships
in every bundle anyone downloads, which is the opposite of what the guard is
for.

A string that is public and may be written down goes in
`tools/leak-allow.local.json`, which is git-ignored and never shipped either.
The YouTube web-client key is the one that comes up: a thousand projects
quote it, and quoting it is not leaking it.

```json
{
  "allow": [
    "the exact string, copied from where it is public"
  ]
}
```

Write the value itself into that file, not into this document: the file is
git-ignored, and this one is not. A tracked file that quotes the string
trips the scan on the runner, where the list does not exist.

## Scaffolding a project

The global policy says to write the inner loop and the gate into the project's
AGENTS.md so the next session does not rediscover the trap.
`tools/init-project.ps1` does the mechanical half of that.

```powershell
tools/init-project.ps1 -Repo C:\path\to\repo
tools/init-project.ps1 -Repo C:\path\to\repo -Check
```

It detects the ecosystem from the build manifest, treats a CI workflow as the
authority for the gate, and writes an `AGENTS.md` in the house format
(`## Inner loop` and `## Gate`). Commands it cannot verify are marked as
proposed. It never overwrites an existing AGENTS.md without `-Force`.

**PowerShell parsing trap.** A bare `Has 'x' -or Has 'y'` is parsed as ONE call
to `Has` with the arguments `('x', '-or', 'Has', 'y')` - the operator is never
applied. Every call in a condition must be wrapped in parentheses. This broke a
real detection chain before it was caught.

## One command to route a task

The canonical PowerShell profile exposes `work` as the short name for
`agent-task`. From the repository, examples are:

```powershell
work 'Fix the broken focus return after Back'
work 'Find the setting that controls focus return' -Preview
work 'Review the release candidate' -Complexity deep -ReadOnly
work 'Fix the small typo' -Agent commandcode -Complexity standard
```

The command announces the selected CLI backend, model, effort, and mode in one line.
`-Preview` shows the full route (with an estimated cost) without contacting a
model. Selection has two layers, both in `tools/agent-route.ps1`:

1. **Capability tier** — a text heuristic on the task string: short lookups and
   small text/label edits are `quick`; anything matching
   security/accessibility/migration/release/refactor/etc. is `deep`; the rest is
   `standard`.
2. **Model within the tier** — for Command Code, the **cheapest eligible model**
   is chosen from `tools/model-prices.json`, so a price change or a new deal is
   picked up without editing code. Candidates per tier are a capability
   shortlist (a human judgement); only the price ranking is automatic.

Cost is blended over a typical request (~800 input, ~160 output, ~50K cache
read), so **cache-read price dominates** — as it does in a real long session.
DeepSeek's peak/off-peak window (Mon–Fri 01–04 & 06–10 UTC) is applied when in
effect, and plan-restricted models are filtered out (this account is Go-tier, so
`gpt-6.1-sol`/`gpt-6-astra`/Claude/Gemini are skipped). Free models are included
by default; `-NoFree` excludes them, `-Static` uses the hand-picked table, and a
model whose upstream may train on your prompts is always excluded. Effort is
derived per model from the catalog, because several cheap models accept no effort
at all.

Auto backend choice uses recent outcomes and backend health, so quick and read-only
tasks do not always go to Command Code. The tier then selects a model for that
backend. `-Preview` shows the current choice; `-WorkDir` selects another directory.

Regenerate prices after a CLI upgrade or a pricing change (it reads the CLI's own
bundled catalog, which matches the pricing page):

```powershell
~/Documents/Codex/tools/refresh-model-prices.ps1
```

**Fallback order.** If the chosen agent fails with an infrastructure signature
(usage/rate limit, plan restriction, auth, `403`/`MODEL_NOT_IN_PLAN`, unreachable,
missing binary), the router first retries the same backend once on a free model
(`tools/free-models.json`; disable with `-NoFreeFallback`), then re-runs the same
task once with another CLI, using that backend's tier model (disable the
cross-backend step with `-NoFallback`). If every step fails it throws and reports
the log paths. An explicit `-Model`/`-Effort` applies only to the primary agent,
never a fallback.

**Usage and budget.** Command Code credits are **not readable headlessly** — the
docs say the plan cannot be read from disk and `/usage` is interactive-only. Read
the live number with `/usage` in a session, or at https://commandcode.ai/usage.
The router still reacts to usage: when a run hits the 5-hour limit, its reset
time is recorded in `agent-usage.json` and **paid Command Code models are withheld
until it passes** (a free model is selected, and the task reroutes to another
backend only if no free model fits). Codex subscription usage is **not**
readable headlessly either. `tools/agent-usage.ps1` prints all
of this: Command Code/OpenCode cooldown state, OpenCode spend from its local
DB (`-Json`), and `-ClearCooldown`. `-Refresh` is a no-op; live Command Code
numbers come from `/usage` or the usage page.

**Free-vs-paid rule.** The `quick` tier takes the cheapest eligible model, which
may be a free one; `standard` and `deep` take the cheapest eligible paid model.
A free model is otherwise used only as a fallback when no paid model is available
(the usage window has closed, the model is plan-restricted, or the run was
rejected), and never from an upstream that may train on your prompts. The order is
paid -> free on the same backend -> another backend. Regenerate the free list
after a CLI upgrade with `tools/refresh-free-models.ps1` (writes
`tools/free-models.json` from each CLI's own catalog).

Normal Command Code edits open its interactive terminal. The MCP bridge uses
`-Headless`, which runs Command Code with `--accept-edits -p`; commands still
follow its permission rules and may be denied. Codex bridge tasks explicitly
use `read-only` or `workspace-write` sandbox mode, while normal edits inherit
the configured sandbox. Both CLIs can exit successfully after reporting that
an attempted write failed, so verify the requested result and Git diff.

The script is `~/Documents/Codex/tools/agent-task.ps1`. If the profile is not
loaded yet, invoke that path directly. Use `reload` in an existing PowerShell
window after a profile change. Backends are `codex`, `commandcode`, and
`opencode` (`-Agent opencode` runs `opencode run`, paid model by default with the
same free-model fallback).

## Agents (the roster)

The static roster is **scout** (read-only research/locate), **builder** (sole
writer), **verifier** (read-only review + checks), and **debugger** (root-cause a
failure, then the smallest fix). `work` routes one CLI task; it does not launch a
named roster agent. The main agent dispatches named roles separately when the
task calls for them. The chain stops after verification, before a commit unless
the user explicitly requested one.

For a meaningful change, record the builder's **actual backend and resolved
model**, including any fallback. Before dispatching the verifier, compare model
families, not just CLI names, and pass those builder details to the verifier.
A DeepSeek builder on OpenCode or Command Code can use the Codex Terra verifier;
a Codex Sol builder can use the OpenCode DeepSeek verifier or Codex Terra. Check
the actual verifier model after dispatch too. If a different family is
unavailable, report that review gap rather than claiming cross-model review.

An agent may **call on another agent or CLI when the task required it** — a
read-only agent that needs a writer, a writer that needs independent
verification, or a backend that has hit its usage limit or lacks a capability
handing the task to Codex, CommandCode, or OpenCode, and the reverse. A hand-off
stays in scope, states its reason, and never recurses past what the task needs.

`~/Documents/Codex/workflows/agents.toml` is the single source of truth. Render it
to each CLI's native form:

```powershell
~/Documents/Codex/tools/sync-agents.ps1          # write ~/.codex/agents/*.toml + ~/.config/opencode/agents/*.md + ~/.commandcode/agents/*.md
~/Documents/Codex/tools/sync-agents.ps1 -Check   # report drift, exit 2 if any
```

CommandCode loads subagents from `~/.commandcode/agents/` as Markdown files,
reached through its built-in `agent` tool (which a headless `-p` turn keeps, so
the BlindPilot Command Code tab can delegate to the roster). A read-only roster
agent renders with `tools: read_file, read_directory, grep, glob, shell_command`
and `disallowedTools: edit_file, write_file`: CommandCode has no per-command
shell allow-list, so a write through `shell_command` is the residual risk.
CommandCode also reads the roster section of the global `AGENTS.md`. Edit
`agents.toml` and re-render — never hand-edit the rendered files.
Codex custom agent files inherit the parent sandbox and approval settings;
their read-only instructions do not create a read-only sandbox.

## Superpowers in the routed agents

`agent-task` selects a CLI backend and model, then that agent follows its own skills
and the shared `AGENTS.md`.

**Installed and active in all three CLIs (as of 2026-10-19).**

Superpowers 6.4.2 (obra/superpowers, MIT) lives in the canonical skill set, so
`tools/sync-skills.ps1` pushes it to every CLI:

```
~/.agents/skills/                 <- canonical, 86 skills (71 + 15 Superpowers)
~/.codex/skills/                  <- rendered
~/.config/opencode/skills/        <- rendered
~/.commandcode/skills/            <- rendered
```

The 15 skills: brainstorming, diagnosing-superpowers, dispatching-parallel-agents,
executing-plans, finishing-a-development-branch, receiving-code-review,
requesting-code-review, subagent-driven-development, systematic-debugging,
test-driven-development, using-git-worktrees, using-superpowers,
verification-before-completion, writing-plans, writing-skills.

**Why the canonical set and not the Codex plugin.** The plugin copy is still cached at
`~/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/`, but it is not
registered in `config.toml` — no `[plugins."superpowers@openai-curated-remote"]`
block and no `[marketplaces.openai-curated-remote"]` block — so it never loads.
Putting the skills in `~/.agents/skills` instead reaches all three CLIs from one
source, survives plugin-cache pruning, and needs no `config.toml` edit.

**Command Code bootstrap.** `~/.commandcode/hooks/superpowers-bootstrap.mjs` is
registered as a `SessionStart` hook. It reads
`~/.commandcode/skills/using-superpowers/SKILL.md`, strips the YAML frontmatter and
injects the instructions as session context. It no-ops safely when the skill is
missing, so it can stay registered unconditionally.

## Running without Superpowers or RTK

Neither is a dependency of the workflow engine. Grepping every script in
`tools/*.ps1` returns **zero** references to `rtk` or `superpowers`.

### What keeps working

Everything mechanical, because it is plain PowerShell plus the CLIs themselves:

| Component | Needs | Without the optional tool |
| --- | --- | --- |
| Nightly self-repair (10 steps, snapshot + rollback) | PowerShell, the CLIs, git | unchanged |
| Router and `work` (`agent-task.ps1`, `agent-route.ps1`) | PowerShell, model catalogs | unchanged |
| Agent roster (scout / builder / verifier / debugger) | `workflows/agents.toml` + `sync-agents.ps1` | unchanged |
| Worktrees, release gate, guard hook, all sync scripts | PowerShell, git | unchanged |
| Skill distribution (`sync-skills.ps1`) | `~/.agents/skills` | unchanged |
| Memory and taste pipeline | rollout summaries | unchanged |

### What degrades

**Superpowers.** The four task cues in the global `AGENTS.md` name Superpowers
skills (`design:` → brainstorming, `fix:` → systematic-debugging, `execute:` →
executing-plans / subagent-driven-development, `review:` → requesting-code-review /
verification-before-completion). With the plugin absent those skills cannot load.

The cues still work, because the workflow each one describes is written out in
prose in the global `AGENTS.md`: reproduce before editing, rank hypotheses, fix the
root cause, add a focused regression check, delegate with disjoint file ownership,
separate code review from tests actually run. Quality drops from *guided* to
*informed*, not to *broken*. Nothing in the repair engine notices.

To drop Superpowers cleanly, remove the 15 skill folders from `~/.agents/skills/`
and re-run `tools/sync-skills.ps1` (it prunes what is no longer canonical), then
delete the "Superpowers task cues" section from the global `AGENTS.md` - otherwise
it advertises four skills that cannot load. The Command Code bootstrap hook
no-ops on its own when the skill is gone.

**RTK.** The global `AGENTS.md` says "run commands through `rtk`". That is an
instruction, not a dependency. The fallback clause was added on 2026-10-19:

> On this Windows setup, run commands through `rtk` **when it is on PATH**; if
> `rtk <cmd>` fails with "program not found", run the command directly. Skip rtk
> for shell builtins (`echo`, `cd`, `set`) and for output a later step parses.

So with rtk absent the agent has a written way to recover instead of guessing.

### Installing on a new machine

`tools/setup.ps1` does the whole thing in one command:

```powershell
cd ~/Documents/Codex/tools
powershell -NoProfile -ExecutionPolicy Bypass -File ./setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ./setup.ps1 -Check   # dry run
```

It installs, idempotently: the PowerShell profile loader, the global
`AGENTS.md` from `workflow/AGENTS.template.md`, the starter taste, the agent
roster, the skill set, the guard hook, the Command Code permission rules, the
model catalogs, the nightly scheduled task, and finally the smoke checks.

`-Check` reports what it would do and writes nothing (every sync script is
called with its own `-Check`). It exits 2 when anything is missing.

**What setup.ps1 deliberately does not install:**

- **Audio (Claudio) hooks.** A hook pointing at a missing binary fails on every
  lifecycle event, so audio stays an opt-in add-on. The installed `hooks.json`
  and `settings.json` contain **zero** Claudio references.
- **Anything needing administrator rights, a license, or credentials.**
- **Vendor agent tooling.** The workflow is self-contained.

**Portability rules for the scripts.** No script may contain a hardcoded user
path. Every path is derived from `$env:USERPROFILE`, `$PSScriptRoot`, or a
parameter. `tools/verify.ps1` fails the run if a hardcoded path reappears, so
the guarantee cannot rot.

| Script | Derives its paths from |
| --- | --- |
| `sync-agents.ps1` | `$env:USERPROFILE` |
| `sync-agent-instructions.ps1` | `$env:USERPROFILE` |
| `sync-skills.ps1`, `sync-taste.ps1` | `$HOME` / `$PSScriptRoot` |
| `profile.ps1` | `$PSScriptRoot` (it is dot-sourced, so this is the tools dir) |
| `agent-task.ps1`, `new-worktree.ps1` | `$PSScriptRoot` and its parent (the workspace root) |
| `self-repair.ps1` | `$PSScriptRoot` and `$env:USERPROFILE` |

**The distributable payload** lives in `workflow/`:

| File | Purpose |
| --- | --- |
| `AGENTS.template.md` | The global policy, with the generated taste block removed. A frozen snapshot of the canonical file, refreshed with `setup.ps1 -RefreshTemplate`. |
| `taste-starter/taste.md` | The baseline preferences a new user starts with. Installed only when the user has no taste file yet. |
| `commandcode-settings.template.json` | The permission rules. No audio hooks. `__WORKSPACE__` is substituted at install time. |
| `commandcode-hooks/superpowers-bootstrap.mjs` | The Command Code SessionStart hook that injects the Superpowers entry point. Uses `homedir()`, so it is portable. |

Optional extras: install rtk (`cargo install rtk`), and copy the Superpowers
skill folders into `~/.agents/skills/` then run `tools/sync-skills.ps1`.

## One canonical instruction file

All three global `AGENTS.md` files are byte-identical. Edit the canonical one
(`~/.codex/AGENTS.md`) and propagate:

```powershell
~/Documents/Codex/tools/sync-agent-instructions.ps1        # push canonical to the other two
~/Documents/Codex/tools/sync-agent-instructions.ps1 -Check # report drift, exit 2 if any
```

Do not hand-edit two copies — that is how they diverged before.

## RTK (Rust Token Killer)

`rtk` (~/.cargo/bin/rtk.exe, v1.0.1) condenses command output to save tokens.
It is an **executable proxy**, not a shell wrapper:

- Safe: `rtk git status`, `rtk cargo test`, `rtk npm run build` — real binaries.
- **Not** safe for shell builtins (`echo`, `cd`, `set`, `dir` on some shells):
  they are not on PATH, so RTK fails with `[rtk: program not found]`.
- **Not** safe when a later step parses the output: condensed text can be
  misread by a pipe, regex, or capture.
- `rtk proxy <cmd>` runs one command unfiltered — but in v1.0.1 it does **not**
  rescue a builtin either: `rtk proxy echo hi` fails the same way as
  `rtk echo hi`, because the builtin still has to be resolved on PATH.
  `RTK_DISABLED=1` skips RTK.

RTK is optional. See "Running without Superpowers or RTK" below.

## Approval and sandbox reality

The global policy asks for approval before commits, pushes, releases, and
destructive actions. The runtimes do **not fully** enforce it:

- Codex: `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`,
  network on (`~/.codex/config.toml`).
- CommandCode: `defaultMode = "yolo"` with the permission rules restored
  (2026-10-19). `~/.commandcode/settings.json` carries 33 `allow`, 33 `ask`
  and 9 `deny` entries again, plus `additionalDirectories` and the lifecycle
  hooks. The rules were briefly dropped entirely; they are back.
  `defaultMode` stays `"yolo"` on purpose: plain `git` is not in the allow
  list, so under `"default"` every git command would ask. Explicit ask and deny
  rules survive yolo/bypass mode, so the protections still bite.
- OpenCode v1: global `permission` allows every tool, including Bash and
  `external_directory`. Read-only roster agents keep `edit: deny` but no longer
  add a Bash `ask` rule, so only the edit block can stop them.

The deny rules cover only those matching commands; the rest of the policy is
required agent behavior. State plainly when approval was assumed.

## Feedback loop (the rule that bit us)

Keep two speeds: a fast inner loop (one config, filtered to the change) and the
full gate, run once before done and in CI — never as the inner loop. Full detail
is the `## Feedback loop` section of the global `AGENTS.md`.

## config.toml is app-managed

Codex rewrites `~/.codex/config.toml`. Hand edits (e.g. pruning stale
`[projects.*]` trust entries) are safe only while Codex is closed, and may be
rewritten on next launch. Back it up first:
`config.toml.trustclean-<timestamp>` holds the last pre-clean copy.

## Taste (learned preferences)

Command Code learns preferences into `.commandcode/taste/` -- global at
`~/.commandcode/taste/`, per project at `<project>/.commandcode/taste/`. No other agent
reads that location, so `tools/sync-taste.ps1` renders it into a generated, delimited
`TASTE:BEGIN`/`TASTE:END` block and injects it where each agent looks:

- global: `~/.codex/AGENTS.md` (canonical; `sync-agent-instructions.ps1` then copies it to
  `~/.config/opencode/AGENTS.md` and `~/.commandcode/AGENTS.md`), `~/.claude/CLAUDE.md`,
  `~/.gemini/GEMINI.md`.
- per project: `<project>/AGENTS.md`, run with `-Project <dir>`.

The block is generated -- edit the taste files (or let Command Code learn), never the block.
Re-running is idempotent; `-Check` reports drift and exits 2.

```powershell
~/Documents/Codex/tools/sync-taste.ps1                   # global -> all agents
~/Documents/Codex/tools/sync-taste.ps1 -Check
~/Documents/Codex/tools/sync-taste.ps1 -Project <dir>    # one project
```

The shell profile runs the global sync at most once a day and exposes `taste-sync` on demand.

## BlindPilot (the screen-reader GUI front-end)

BlindPilot (`serrebidev/BlindPilot`) is not another CLI to route to — it is a wxPython window
over the same CLIs, one per tab, in Bypass permissions mode. It drives Command Code as
`command-code -p --output-format json …` with **one process per turn**, resumed by session id.

**The boundary that bit us.** `work`/`agent-task` is a *terminal launcher that starts another
CLI*. Inside a BlindPilot turn it nests CLIs; even a headless nested turn can outlive
BlindPilot's one-shot process. Dev servers are long-running by design.
Any of those leaves the turn's one-shot `-p` process without a final `result` frame, so
BlindPilot's worker kills it and says **"Command Code stopped before the turn completed (exit
code 1)."** — that string is BlindPilot's (`commandcode_worker.py::_finish()`), meaning the
process exited with a code outside its documented set and no `result` arrived; the real cause is
in the stderr tail it appends after it.

So: **never run `work`/`agent-task` or a dev server/watcher inside a BlindPilot turn.**
Run those from a normal PowerShell window. BlindPilot and `work` are two entry points that
replace each other, they do not compose.

**Per-project model/effort without the router.** BlindPilot's *Profiles* are Chat-mode only
("Chat mode starts on this profile"; the Chat menu works only when the Mode box is Chat) — there
is no per-project agent profile. A tab carries its own Backend + Model/Effort + Permission Mode.
For any tier, set the tab's Backend, Model, and Effort from the current
`work '<task>' -Preview` route.

Read the route with `work '<task>' -Preview` — it prints backend, model and effort
without contacting a model — then set the tab from it (Ctrl+Shift+E). A direct
Command Code tab currently defaults to `poolside/laguna-s-2.1-free` from
`~/.commandcode/config.json`; no reasoning effort is pinned for that model.
BlindPilot's picker reads the `model` and `reasoningEffort` keys. Backups:
`config.json.bak-<timestamp>`.

**Permissions under bypass.** A Bypass/headless run *stops* the moment a `permissions.ask` rule
matches (measured: `stopReason: permission_denied`, exit 0 - a partial answer, not a crash), so
ask rules are what end an unattended turn early.

The rule set is restored (2026-10-19): 33 `allow`, 33 `ask`, 9 `deny` entries.

- **`deny` (9 entries)** - the destructive git operations only, each in plain, `rtk` and
  `rtk proxy` form: `git push --force`, `git reset --hard`, `git clean`.
- **`ask` (33 entries)** - the VCS history and remote group (`git push`, `merge`, `rebase`,
  `branch -D`, `remote add|remove|set-url`, `gh pr create`, each in three forms) plus the
  system/admin ops (`setx`, `reg add`, `reg delete`, `netsh`, `bcdedit`, `sc config`,
  `dism`, `Set-ExecutionPolicy`, `winget --scope machine`, `choco install`, `choco upgrade`).
  An earlier version of this file called the system ops `deny`; they are `ask`.

So an unattended turn stops on a push or a system-op instead of performing it, and the
destructive git operations are refused outright.

USEFUL LATER: the bare `"powershell"` allow grants the whole PowerShell tool with no argument
constraint, so it can carry a denied op (`powershell -Command "Set-ExecutionPolicy …"`) past the
deny rules. It is load-bearing for this workflow (adb, `$`-heavy commands, file edits), so it was
left alone; tighten it only after a decision on which PowerShell verbs must stay reachable.

