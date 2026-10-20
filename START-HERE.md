# START HERE

You have just installed a self-healing coding workflow. This page is the
shortest path from "installed" to "useful". Read it once, then delete it.

**Author:** Farhan Khan ([@thebetterfarhan](https://github.com/thebetterfarhan))

If you prefer to read rather than run, the full reference is
`SELF-HEALING-WORKFLOW.md` (also `html/self-healing-workflow.html`).

---

## 1. What you actually installed

One folder, `~/Documents/Codex`, holding:

| Piece | What it does |
| --- | --- |
| **A policy file** (`~/.codex/AGENTS.md`) | The rules every agent follows: how to work, what needs approval, how to verify, how to report. Copied byte-identical into Codex, OpenCode and Command Code. |
| **A router** (`work`) | One command that reads your request, decides how hard it is, picks the cheapest capable model, and runs it. Falls back to a free model, then to another CLI, if a backend fails. |
| **Four agents** | scout (finds code), builder (the only one that writes), verifier (reviews and runs checks), debugger (finds the root cause). |
| **A nightly repair job** | At 03:00 it re-syncs everything, refreshes the model catalogs, distils the day's sessions into memory, and rolls back anything that fails. |
| **A guard hook** | Refuses patches that touch signing keys or commit secret-shaped text. |
| **Worktrees, a release gate, and HTML docs** | Isolation for risky work, a pre-push check, and this documentation published for a screen reader. |

You do not need to configure any of it. It is already wired.

---

## 2. The one command

Open a **new** PowerShell window (the profile loads at start), change to your
project, and run:

```powershell
work 'Find the setting that controls focus return'
```

That single line reads the request, picks a backend and model, and runs it.
Add `-Preview` first if you want to see the route without spending anything:

```powershell
work 'Find the setting that controls focus return' -Preview
```

It prints the backend, model, effort and mode. Nothing runs until you confirm
the choice is sane.

**Useful variants**

| Command | When |
| --- | --- |
| `work '<task>' -Complexity deep` | Security, migration, refactor, release — anything high-stakes. |
| `work '<task>' -ReadOnly` | Investigation only. The agent cannot write. |
| `work '<task>' -N 2` | You are not sure which approach is right. Two attempts run in parallel, in separate worktrees, and you pick. |
| `wt -Repo <name> -Name <task>` | Start a task in its own worktree, so a risky change cannot touch your working copy. |
| `workflow-status` | Is the workflow healthy? One screen: install, nightly job, drift, backends, spend. |

---

## 3. Point it at your project

The workflow needs to know how to build and test *your* repository. Scaffolding
that is one command:

```powershell
cd ~/your-project
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/init-project.ps1 -Repo .
```

It detects the build system, reads the CI workflow when there is one, and
writes an `AGENTS.md` with an **inner loop** and a **completion gate** in the
format used across this workspace.

**Run the two commands it proposes once, correct anything that is wrong, and
delete the note it leaves.** After that the agent knows what "the fast check"
and "the gate" mean in your repo, and never has to guess. Without it, the
agent tries plausible commands and burns turns finding out which ones work.

It never overwrites an existing `AGENTS.md` without `-Force`.

## 4. Three things to try first

**One — a lookup.** `work 'Where is the retry logic for failed uploads?'`
Cheapest tier, fastest model, no edits.

**Two — a small fix.** `work 'Fix the off-by-one in the pagination loop'`
It reproduces, edits, and leaves the change uncommitted for you to review.

**Three — the cues.** The policy supports four optional cue phrases. They are
plain English, not commands:

| You type | It uses |
| --- | --- |
| `design: add a dark mode toggle` | brainstorming — agrees the behaviour before writing code. |
| `fix: the toolbar disappears when I resize` | systematic debugging — reproduces first, then finds the root cause. |
| `execute: the plan in PLAN.md` | plan execution — delegates independent parts in parallel. |
| `review: the last commit` | code review, then verification — separates reading the diff from running the checks. |

They work whether or not the extra skills are installed; the workflow each one
describes is written out in the policy file either way.

---

## 5. Make it yours (the part most people skip)

The workflow ships with a **baseline** of preferences at
`~/.commandcode/taste/taste.md`. It is a starting point, not your taste.
Nothing in it is a rule — it is what the agent assumes about you until you
correct it.

Open it and delete anything that does not apply. Then add what you notice you
want, one bullet per line:

```markdown
- Prefers test names that describe the behaviour, not the implementation. Confidence: 0.9
```

`Confidence` is how sure you are: `0.5` means "assumed, correct me", `0.9`
means "I have said this repeatedly".

Two ways to add preferences:

- **By hand.** Edit the file. The next session picks it up.
- **By asking.** Say *"remember that I always want the changelog updated"* and
  the agent records it.

Either way it applies to **all three agents**, because the file is rendered into
each one's instruction file. The nightly job re-renders it automatically.

If you never touch it, everything still works. The baseline is deliberately
small, and the policy file carries the weight.

---

## 6. What happens while you sleep

At 03:00 a scheduled job runs eleven steps:

```
sync-taste              learned preferences -> every agent's instructions
sync-agents             the roster -> each CLI's agent format
sync-agent-instructions one policy file -> all three CLIs
sync-skills             the skill set -> all three CLIs
refresh-free-models     which models are free right now
memory-curate           today's sessions -> structured notes
memory-consolidate      new notes -> long-term memory
tier-adapt              how hard tasks get classified
taste-promote           repeated preferences -> candidates for you to approve
credit-check            which backends are alive
verify                  do all the scripts still work
```

Every step is snapshotted and hashed before it runs. If one fails, that step is
rolled back and the rest continue. You will find the log at
`tools/self-repair.log`.

---

## 7. Optional extras — all of them are optional

| Extra | Without it |
| --- | --- |
| **rtk** (token-saving command wrapper) | Commands run normally. The policy tells the agent to fall back to the plain command when rtk is not on PATH. |
| **Superpowers skills** | The four cues still work as prose instructions. The skills add guided workflows on top. |
| **Audio feedback** | No sound. Nothing else changes — audio hooks are never installed by default, because a hook pointing at a missing binary fails on every event. |
| **The guard hook** | Included by default. It needs only PowerShell. |
| **The nightly job** | Included by default. Turn it off with `Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:$false`. |

---

## 8. Where things are

| Path | What |
| --- | --- |
| `~/Documents/Codex/html/index.html` | This documentation, published for a screen reader. |
| `~/Documents/Codex/SELF-HEALING-WORKFLOW.md` | The complete reference, basics to advanced. |
| `~/Documents/Codex/WORKFLOW-USAGE.md` | The operator quick reference. |
| `~/Documents/Codex/tools/` | Every script. Read them; they are plain PowerShell with a header comment explaining what each does. |
| `~/Documents/Codex/tools/self-repair.log` | What the nightly job did. |
| `~/.codex/AGENTS.md` | The policy. **Never edit the copies** — edit this one, then run `tools/sync-agent-instructions.ps1`. |
| `~/.commandcode/taste/taste.md` | Your preferences. |
| `~/Documents/Codex/tools/HANDOVER.md` | Current state and next action. |

---

## 9. When something goes wrong

| Symptom | Do this |
| --- | --- |
| `work` is not recognised | Open a new PowerShell window, or run `reload`. |
| The agents ignore a preference you set | `~/Documents/Codex/tools/sync-taste.ps1` |
| The three CLIs disagree | `~/Documents/Codex/tools/sync-agent-instructions.ps1` |
| The nightly job stopped | `~/Documents/Codex/tools/self-repair.log`, then `tools/self-repair-failures.log` for the detail |
| You want to see what a change would do | `tools/setup.ps1 -Check` - reports, writes nothing |
| You want to know if anything is broken | `workflow-status` - one screen, exit 0 means healthy |
| You want to undo the install | `tools/setup.ps1` never overwrites what you already have. To remove the scheduled task: `Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:$false` |

---

## 10. If you are giving this to someone else

Do **not** ship this folder as-is — it holds worktrees, project repositories,
build artifacts, per-machine backups, logs and live state.

Ship a bundle instead:

```powershell
cd ~/Documents/Codex/tools
powershell -NoProfile -ExecutionPolicy Bypass -File ./package.ps1
```

That writes `~/Documents/Codex/workflow-kit.zip`: the policy, the docs, the
canonical config, the install payload, every script, the canonical skill set and
the published HTML — and nothing machine-specific. `BUNDLE-MANIFEST.txt` inside
lists exactly what shipped.

On their machine:

```powershell
# 1. Unzip anywhere, e.g. ~/Documents/Codex
# 2. Install
cd ~/Documents/Codex/workflow-kit/tools
powershell -NoProfile -ExecutionPolicy Bypass -File ./setup.ps1
```

`setup.ps1` is idempotent: it installs only what is missing, backs up anything
it would replace, and never overwrites your files without saying so. Add
`-Check` to see what it would do first.

It needs **PowerShell 5.1** (any Windows 10/11) and **git**. The coding CLIs
themselves are optional — the workflow degrades gracefully if one is missing.
Claudio, rtk and the vendor agent tooling are all optional and are never
installed by default.
