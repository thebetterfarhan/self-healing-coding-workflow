# The Self-Healing / Self-Repairing Workflow — Complete Guide

**Author:** Farhan Khan ([@thebetterfarhan](https://github.com/thebetterfarhan))
**Audience:** you, six months from now, with no memory of how any of this works.
**Scope:** everything from "what is this thing" to "how do I add a repair step of my own."
**Read time:** ~25 minutes. Skip to the section you need; the table of contents is clickable.

> **Also published as HTML:** `html/self-healing-workflow.html` — self-contained, with a sidebar contents pane, dark/light theme and print styles. Regenerate from this file with `node tools/docgen/convert-docs.mjs`.

---

## Table of contents

**Part 0 — The 5-minute version**
1. [What "self-healing" actually means here](#01-what-self-healing-actually-means-here)
2. [The one picture](#02-the-one-picture)
3. [The three commands you will actually use](#03-the-three-commands-you-will-actually-use)

**Part 1 — Basics**
4. [The four layers](#1-the-four-layers)
5. [Where every file lives](#2-where-every-file-lives)
6. [The nightly repair run](#3-the-nightly-repair-run)

**Part 2 - The configuration repo and the eleven repair steps**
7. [The configuration repository](#31-the-configuration-repository)
8. [Step overview table](#4-step-overview-table)
9. [Steps 1–3: the instruction layer](#5-steps-1-to-3-the-instruction-layer)
10. [Steps 4–6: the catalog and memory layer](#6-steps-4-to-8-the-skills-catalog-and-memory-layer)
11. [Steps 7–10: the routing and health layer](#7-steps-9-to-11-the-routing-and-health-layer)

**Part 3 — The safety machinery**
12. [Snapshot, hash, manifest, rollback](#8-snapshot-hash-manifest-rollback)
13. [What is protected and what is not](#9-what-is-protected-and-what-is-not)

**Part 4 — Runtime self-healing**
14. [Backend health and cooldown](#10-runtime-1-backend-health-and-cooldown)
15. [Route feedback and model demotion](#11-runtime-2-route-feedback-and-model-demotion)
16. [The fallback chain](#12-runtime-3-the-fallback-chain)
17. [Adaptive tiers](#13-runtime-4-adaptive-tiers)
18. [Price-aware selection](#14-runtime-5-price-aware-selection)

**Part 5 — The learning loop**
19. [Memory: summaries to notes to MEMORY.md](#15-the-memory-loop)
20. [Taste: learned preferences to agent instructions](#16-the-taste-loop)

**Part 6 — Manual operations**
21. [Complete command cheat sheet](#17-complete-command-cheat-sheet)
22. [How to run the repair by hand](#18-how-to-run-the-repair-by-hand)

**Part 7 — Troubleshooting**
23. [Symptom → cause → fix](#19-symptom-cause-fix)
24. [Reading the logs](#20-reading-the-logs)
25. [Manual rollback](#21-manual-rollback)

**Part 8 — Advanced**
26. [Adding a repair step](#22-adding-a-repair-step)
27. [Changing the agent roster](#23-changing-the-agent-roster)
28. [Changing the schedule](#24-changing-the-schedule)
29. [The guard hook](#25-the-guard-hook)
30. [Worktree isolation](#26-worktree-isolation)
31. [The release gate](#27-the-release-gate)
32. [Cross-CLI handoff](#28-cross-cli-handoff)

**Part 9 — Known limits and drift**
33. [Things that are weaker than they look](#29-things-that-are-weaker-than-they-look)
34. [Drift found and fixed](#30-drift-found-and-fixed)

**Part 10 — Reference**
35. [Exit codes](#31-exit-codes)
36. [Glossary](#32-glossary)
37. [The five things to remember](#the-five-things-to-remember)

---

# Part 0 — The 5-minute version

## 0.1 What "self-healing" actually means here

You have three AI coding CLIs on this machine — **Codex**, **Command Code**, and **OpenCode**. They are separate programs. Each one has its own instruction file, its own agent definitions, its own model catalog. If you edit one, the others don't know. If a model gets retired upstream, a route that worked yesterday 404s today. If a file gets truncated, the CLI silently misbehaves.

Left alone, this configuration **rots**. Definitions drift apart, catalogs go stale, backups pile up, a retired model keeps getting selected for a week.

This system is the answer to that. It has two halves:

| Half | When it runs | What it fixes |
|---|---|---|
| **Self-repair** (the nightly job) | 03:00, unattended | The *configuration* rots: instruction files diverge, agent files drift, catalogs go stale, memory stops consolidating, thresholds stop adapting. |
| **Self-healing** (at run time) | Every time you dispatch a task | The *environment* rots: a backend is rate-limited, a model is retired, credits ran out. The router reroutes instead of failing. |

Both halves share one idea: **every change is snapshotted and hashed before it happens, and rolled back automatically if it goes wrong.** Nothing here can silently corrupt your setup.

A third, smaller piece is the **guard hook**: a deny-list in front of Codex that refuses to let a patch touch your keystores or commit secret-shaped text.

## 0.2 The one picture

```
   YOUR TASKS
       │
       │  work '<task>'          ← one command, routes and runs
       ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  ROUTER  (tools/agent-route.ps1 + tools/agent-task.ps1)    │
 │                                                             │
 │  1. classify task  → quick / standard / deep                │
 │  2. pick backend   → codex / commandcode / opencode         │
 │  3. pick model     → cheapest eligible, plan-filtered      │
 │  4. run it                                             ┐    │
 │  5. failed? free model → other backend → give up     │    │
 │  6. record outcome  → health flags, feedback, tiers   │    │
 └──────────────────────────────────────────────────────────┼────┘
                                                            │
   ┌────────────────────────┐   ┌─────────────────────────┼───┐
   ▼                        ▼   ▼                         │   │
┌────────┐            ┌─────────┐                    ┌───────▼───────┐
│ Codex  │            │Command  │                    │  MEMORY +     │
│        │            │ Code    │                    │  TASTE        │
│AGENTS.md│            │AGENTS.md│                    │  (learning)   │
│agents/ │            │agents/  │                    └───────────────┘
│config  │            │settings │                           │
└────────┘            └─────────┘                    ┌──────▼───────┐
                                                     │ NIGHTLY JOB  │
   ┌─────────────┐   ┌──────────────┐                │ self-repair  │
   │ OpenCode    │   │ ~/.agents/   │                │  03:00       │
   │ AGENTS.md   │   │  skills/     │                │ 11 steps     │
   │ agents/     │   │ (canonical)  │                │ snapshot +   │
   └─────────────┘   └──────────────┘                │ rollback     │
                                                     └──────────────┘
```

Read the arrows as: **the nightly job regenerates the inputs; the router consumes them at task time.**

## 0.3 The three commands you will actually use

```powershell
# 1. Run a task. The router picks everything and runs it.
work 'Fix the broken focus return after Back'

# 2. See what the router WOULD pick, without spending anything.
work 'Fix the broken focus return after Back' -Preview

# 3. Run the whole nightly repair right now, by hand.
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/self-repair.ps1
```

That is genuinely it for day-to-day use. Everything else in this document is for
when something breaks or you want to change something.

---

# Part 1 — Basics

## 1. The four layers

Your whole setup is four stacked layers. Each layer has **one canonical source** and **N copies** that are regenerated from it. Self-repair is the thing that keeps the copies equal to the source.

### Layer 1 — Instructions ("what should the agent do?")

| Canonical source | Copies it renders to |
|---|---|
| `~/.codex/AGENTS.md` | `~/.config/opencode/AGENTS.md`, `~/.commandcode/AGENTS.md` |
| `~/.commandcode/taste/` | a generated `TASTE:BEGIN`/`TASTE:END` block inside each `AGENTS.md` |
| `~/.agents/skills/` | `~/.codex/skills/`, `~/.config/opencode/skills/`, `~/.commandcode/skills/` |
| `workflows/agents.toml` | `~/.codex/agents/*.toml`, `~/.config/opencode/agents/*.md`, `~/.commandcode/agents/*.md` |

**Never hand-edit a copy.** Edit the canonical file, then run the sync script. This is the single most important rule in this document. Two hand-edited copies are how they diverged in the first place.

### Layer 2 — Routing ("which model should run this?")

`tools/agent-route.ps1` holds the tier table, the price picker, the health flags, and the cooldown logic. `tools/agent-task.ps1` executes it. Data files it reads:

- `tools/model-prices.json` — the price catalog, regenerated from the CLI's own catalog
- `tools/free-models.json` — the free-model fallback list, regenerated daily
- `tools/agent-backend-health.json` — live health flags (empty = all healthy)
- `tools/agent-usage.json` — cooldown state (empty = no cooldown)
- `tools/agent-tier-thresholds.json` — adaptive tier thresholds
- `tools/agent-route-feedback.jsonl` — append-only record of every attempt

### Layer 3 — Learning ("what did we learn?")

`~/.codex/memories/` holds rollout summaries. Two scripts distill them into notes and then into `MEMORY.md`. A third script scans notes for repeated preferences and proposes taste entries.

### Layer 4 — Safety ("what must never happen?")

- `tools/guard-hook.ps1` — deny-list for secret-bearing patches
- `tools/release-gate.ps1` — pre-push check: clean tree, no unpushed commits, no secrets, gate commands pass
- `tools/self-repair.ps1`'s own snapshot/rollback — every nightly change is reversible
- `tools/new-worktree.ps1` — isolation, so a broken attempt cannot damage your checkout

---

## 2. Where every file lives

### The workspace: `~/Documents/Codex/`

```
Documents/Codex/
├── AGENTS.md                  Workspace-level instructions (adds to global)
├── AGENTS-compat.md           Compatibility notes — read before compat work
├── WORKFLOW-USAGE.md          The operator's quick reference (terse)
├── SELF-HEALING-WORKFLOW.md   ← THIS FILE
├── WORKFLOW-AUDIT-*.md        Periodic audits of this configuration
├── .gitignore                 What the configuration repo tracks, and what it ignores
├── .git/                      ★ THE CONFIGURATION REPOSITORY — history = recovery points
│
├── workflows/                 THE CANONICAL CONFIG
│   ├── agents.toml            Single source of truth for the agent roster
│   ├── workflow.toml          Machine-readable workflow settings
│   └── workflow.md            Human-readable workflow settings
│
└── tools/                     THE ENGINE
    ├── self-repair.ps1        ★ The nightly job — runs everything below
    ├── self-repair.log        One line per step per run
    ├── self-repair-failures.log   Full output of failed steps
    ├── self-repair-backups/   Snapshots, newest 5 runs kept
    │
    ├── repair-config.ps1      Validates the configuration repo, restores what is broken
    ├── config_check.py        Reports Python/TOML/JSON files that do not parse
    │
    ├── sync-taste.ps1           Layer 1: learned preferences → AGENTS.md files
    ├── sync-agents.ps1          Layer 1: agents.toml → each CLI's agent format
    ├── sync-agent-instructions.ps1  Layer 1: canonical AGENTS.md → copies
    ├── sync-skills.ps1          Layer 1: ~/.agents/skills → each CLI
    │
    ├── refresh-free-models.ps1  Layer 2: free-model catalog
    ├── refresh-model-prices.ps1 Layer 2: price catalog
    ├── agent-route.ps1          Layer 2: the router (dot-source this)
    ├── agent-task.ps1           Layer 2: the runner (`work`)
    ├── agent-usage.ps1          Layer 2: usage/spend reporting
    ├── credit-check.ps1         Layer 2: backend health probe
    │
    ├── memory-curate.ps1        Layer 3: rollout summaries → notes
    ├── memory-consolidate.ps1   Layer 3: notes → MEMORY.md
    ├── taste-promote.ps1        Layer 3: notes → taste candidates
    │
    ├── tier-adapt.ps1           Layer 4: adaptive thresholds
    ├── verify.ps1               Layer 4: smoke checks
    ├── guard-hook.ps1           Layer 4: secret deny-list
    ├── release-gate.ps1         Layer 4: pre-push gate
    ├── new-worktree.ps1         Layer 4: task isolation
    └── profile.ps1              The PowerShell profile (defines `work`, `wt`)
```

### The user directories

```
~/.codex/                    Codex home
├── AGENTS.md                ★ CANONICAL global instructions
├── AGENTS.md.bak-*          Timestamped safety backups (pruned to 5)
├── config.toml              Codex settings (APP-MANAGED — see §29)
├── hooks.json               Lifecycle hook wiring
├── agents/                  Rendered agent definitions (generated)
├── skills/                  Rendered skills (generated)
├── rules/                   Approval rules
└── memories/                Layer 3
    ├── MEMORY.md            ★ Consolidated long-term memory
    ├── rollout_summaries/   Raw session summaries (71 files)
    └── extensions/ad_hoc/notes/  Distilled notes

~/.config/opencode/         OpenCode home
├── AGENTS.md                Copy of canonical
├── agents/                  Rendered agent definitions (generated)
└── skills/                  Rendered skills (generated)

~/.commandcode/             Command Code home
├── AGENTS.md                Copy of canonical
├── agents/                  Rendered agent definitions (generated)
├── skills/                  Rendered skills (generated)
├── taste/                   ★ CANONICAL learned preferences
└── settings.json            Permissions (deny/ask rules)

~/.agents/skills/           ★ CANONICAL skill set
~/.claude/CLAUDE.md         Claude Code — receives the taste block
~/.gemini/GEMINI.md         Gemini CLI — receives the taste block
```

### The state files (all under `tools/`)

| File | Written by | Meaning |
|---|---|---|
| `agent-backend-health.json` | `credit-check.ps1`, `agent-task.ps1` | Per-backend unhealthy flags, 30-minute TTL |
| `agent-usage.json` | `agent-task.ps1` | Cooldown state (5-hour window reset time) |
| `agent-tier-thresholds.json` | `tier-adapt.ps1` | `maxQuickLength`, `quickSuccessRate`, `sampleCount` |
| `agent-route-feedback.jsonl` | `agent-task.ps1` | Append-only attempt log (drives demotion) |
| `agent-tier-outcomes.jsonl` | `agent-task.ps1` | Append-only per-tier outcome log |
| `free-models.json` | `refresh-free-models.ps1` | Free fallback catalog, per backend |
| `model-prices.json` | `refresh-model-prices.ps1` | Full price catalog |
| `taste-candidates.md` | `taste-promote.ps1` | Proposed taste entries for review |

---

## 3. The nightly repair run

### When it runs

| Property | Value |
|---|---|
| Task name | `CodexWorkflowSelfHeal` |
| Schedule | Daily at **03:00** local time |
| Runs as | your user account, **Limited** (not elevated), **Interactive** (only while signed in) |
| Action | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "...\tools\self-repair.ps1"` |
| Missed run | `StartWhenAvailable = True` → runs at next available time after sign-in |
| Overlap | `MultipleInstances = IgnoreNew` → a second trigger while one runs is skipped |
| Time limit | 30 minutes (`PT30M`) |
| On battery | Allowed (does not stop) |
| Wakes machine | No |

> **Practical consequence:** because the task is `Interactive`, it will **not** run while you are signed out. If your machine is off at 03:00, the repair happens the next time you sign in — that is the intended behavior, not a fault.

### What one run looks like

```
2026-10-20 13:21:23 repair-config                config healthy: 75 tracked file(s), committed 5 change(s)
2026-10-20 13:21:25 sync-taste                   canonical hash: E512CC4FCA018D73EB400F58CD7397DD
2026-10-20 13:21:26 sync-agents                  roster: 4 agents -> ...\.codex\agents, ...\.config\opencode\agents, ...\.commandcode\agents
2026-10-20 13:21:27 sync-agent-instructions      canonical hash: E512CC4FCA018D73EB400F58CD7397DD
2026-10-20 13:21:31 sync-skills                  sync-skills: done
2026-10-20 13:21:46 refresh-free-models          wrote ...\free-models.json : commandcode=3 opencode=10
2026-10-20 13:21:52 memory-curate                curated 1 rollout summary(ies) -> ...\notes
2026-10-20 13:21:54 memory-consolidate           consolidated 6 novel learning(s) across 1 topic(s)
2026-10-20 13:21:55 tier-adapt                   tier-adapt: quick success=100% (3 samples), maxQuickLength=180, changed=False
2026-10-20 13:21:57 taste-promote                wrote 2 repeated taste candidate(s) to ...\taste-candidates.md
2026-10-20 13:22:04 credit-check                 Backend health file: ...\agent-backend-health.json
2026-10-20 13:22:08 verify                       verify OK
2026-10-20 13:22:08 self-repair                  run complete ok=12 failed=0
```

### The five rules of the run

1. **Each step is independent.** One failure never stops the others. A broken `refresh-free-models` cannot prevent `verify` from running.
2. **Each step is guarded by its own snapshot.** Before a step runs, every file or directory it will write is copied and hashed.
3. **A failure rolls back that step only.** The rest of the run's work stays.
4. **The script always exits.** Exit `0` if every step passed, exit `1` if any failed or rolled back.
5. **The log is trimmed.** `self-repair.log` keeps the last 400 lines (max 500). `self-repair-failures.log` keeps the last 200 (max 250).

### Verify it is alive

```powershell
Get-ScheduledTask -TaskName CodexWorkflowSelfHeal | Select TaskName, State
Get-ScheduledTaskInfo -TaskName CodexWorkflowSelfHeal | Format-List LastRunTime, LastTaskResult, NextRunTime
```

`LastTaskResult: 0` means the last run passed everything.

### 3.1 The configuration repository

The workspace itself is a git repository, and it holds **the workflow configuration
only**: the policy, the docs, the canonical config in `workflows/`, the install
payload in `workflow/`, the scripts in `tools/` and the published HTML. The
project repositories in the same folder are ignored — each one keeps its own
history. `.gitignore` is the boundary.

That makes the configuration recoverable. `tools/repair-config.ps1` is the first
step of the nightly run:

| Phase | What it does |
|---|---|
| Validate | Every tracked file is parsed by its type: PowerShell parse, Python syntax, TOML parse, JSON parse, `node --check`. A missing file counts as broken. |
| Restore | A broken file is copied aside as `<name>.broken-<stamp>` and restored from the last good commit. If the commit is broken too, the step fails and says so. |
| Record | The validated files are committed, so the next run has something to restore from. |

```
2026-10-20 13:21:23 repair-config                config healthy: 75 tracked file(s), committed 5 change(s)
```

The commit is local only — there is no remote, so nothing is pushed and nothing
leaves the machine. New files are not picked up automatically; add them with
`git add` when you create them.

```powershell
~/Documents/Codex/tools/repair-config.ps1 -Check   # validate only, write nothing
~/Documents/Codex/tools/repair-config.ps1          # validate, restore, commit
```

---

# Part 2 - The configuration repo and the eleven repair steps, one by one

## 4. Step overview table

| # | Step | Reads | Writes | Heals |
|---|---|---|---|---|
| 0 | `repair-config` | the configuration repo | the configuration repo (git commit) | A broken config file that nothing else could restore |
| 1 | `sync-taste` | `~/.commandcode/taste/` | `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md` (+ propagates to OpenCode/CommandCode) | Learned preferences not reaching other agents |
| 2 | `sync-agents` | `workflows/agents.toml` | `~/.codex/agents/`, `~/.config/opencode/agents/`, `~/.commandcode/agents/` | Agent definitions diverging from the roster |
| 3 | `sync-agent-instructions` | `~/.codex/AGENTS.md` | `~/.config/opencode/AGENTS.md`, `~/.commandcode/AGENTS.md` | Instruction files drifting apart |
| 4 | `sync-skills` | `~/.agents/skills/` | `~/.codex/skills/`, `~/.config/opencode/skills/`, `~/.commandcode/skills/` | A skill edited or added in one CLI only |
| 5 | `refresh-free-models` | CLI catalogs | `tools/free-models.json` | Retired free models still being offered |
| 6 | `memory-curate` | `~/.codex/memories/rollout_summaries/` | `~/.codex/memories/extensions/ad_hoc/notes/` | Raw summaries never becoming structured notes |
| 7 | `memory-consolidate` | notes + `MEMORY.md` | `MEMORY.md`, `.consolidated` | Notes never merging into long-term memory |
| 8 | `tier-adapt` | `agent-tier-outcomes.jsonl` | `tools/agent-tier-thresholds.json` | Tier thresholds frozen at their defaults |
| 9 | `taste-promote` | notes | `tools/taste-candidates.md` | Repeated preferences never becoming taste |
| 10 | `credit-check` | live backends | `tools/agent-backend-health.json` | Dead backends still being selected |
| 11 | `verify` | all tools | *(nothing — read-only)* | Broken scripts shipping undetected |

---

## 5. Steps 1 to 3: the instruction layer

### Step 1 — `sync-taste`

**The problem it solves.** Command Code learns your preferences into `~/.commandcode/taste/`. No other agent reads that folder. So a preference Command Code learned ("always fix same-pattern bugs in sibling files") is invisible to Codex, OpenCode, Claude, and Gemini.

**The fix.** Render the taste files into a fenced, generated block and inject it where each agent actually looks:

```
<!-- TASTE:BEGIN - generated by tools/sync-taste.ps1; edit .commandcode/taste/ instead -->
...learned preferences, one bullet per line, with a confidence score...
<!-- TASTE:END -->
```

**Key properties**

- **Idempotent.** Re-running produces a byte-identical file. The script finds the existing block with a regex and replaces it in place.
- **The block is generated.** Edit `~/.commandcode/taste/taste.md`, never the block. A hand-edit inside the block is destroyed on the next run.
- **UTF-8 without BOM**, LF-preserving, so the file hash stays stable.
- **`-Check` mode** reports `DRIFT <path>` / `ok <path>` and exits `2` if anything drifted.
- **Per-project mode:** `sync-taste.ps1 -Project <dir>` renders `<dir>/.commandcode/taste/` into `<dir>/AGENTS.md`.

**What it writes in the nightly run:** `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`. It then calls `sync-agent-instructions.ps1` itself to propagate the canonical file to OpenCode and Command Code.

**Manual use**

```powershell
~/Documents/Codex/tools/sync-taste.ps1            # apply
~/Documents/Codex/tools/sync-taste.ps1 -Check     # report drift, exit 2 if any
~/Documents/Codex/tools/sync-taste.ps1 -Project C:\path\to\repo
taste-sync                                       # profile shortcut, same thing
```

> The PowerShell profile runs the global taste sync **at most once per day**, triggered by a stamp file at `~/.commandcode/.taste-sync-stamp`. So the taste block can be up to 24 hours stale after Command Code learns something new.

---

### Step 2 — `sync-agents`

**The problem it solves.** Three CLIs, three agent-file formats, one roster. Hand-maintaining all three means they drift.

**The fix.** `workflows/agents.toml` is the single source of truth. This script renders it into each CLI's native format:

| CLI | Output format | Location |
|---|---|---|
| Codex | TOML | `~/.codex/agents/<name>.toml` |
| OpenCode | Markdown + YAML frontmatter | `~/.config/opencode/agents/<name>.md` |
| CommandCode | Markdown + YAML frontmatter | `~/.commandcode/agents/<name>.md` |

**How read-only is enforced:**

- **Codex** — `sandbox_mode = "read-only"` is set in the agent TOML. (But: Codex custom agents inherit the *parent* sandbox, so the agent's own read-only *instructions* do not create a read-only sandbox on their own.)
- **OpenCode** — frontmatter `permission: edit: deny`. This blocks the edit tool but **not** Bash.
- **CommandCode** — `tools: read_file, read_directory, grep, glob, shell_command` and `disallowedTools: edit_file, write_file`. `shell_command` stays because read-only agents need `rg` and `git`; the residual risk is a write routed through the shell.

**Superseded cleanup.** Seven legacy agent files (the old Codex `accessibility_explorer`/`implementer`/`reviewer`/`tester` set, and the OpenCode `cavecrew-*` set) are **renamed**, not deleted, to `<name>.superseded-<timestamp>`. Renaming a roster entry therefore cleans up after itself.

**`-Check` mode** prints `in sync` / `DRIFTED` / `STALE` per file and exits `2` if anything needs attention.

**Manual use**

```powershell
~/Documents/Codex/tools/sync-agents.ps1          # render to all three CLIs
~/Documents/Codex/tools/sync-agents.ps1 -Check   # report drift, exit 2 if any
```

---

### Step 3 — `sync-agent-instructions`

**The problem it solves.** Each CLI reads its own `AGENTS.md`. Edit one, the other two are now wrong.

**The fix.** `~/.codex/AGENTS.md` is canonical. This script copies it byte-for-byte to:

- `~/.config/opencode/AGENTS.md`
- `~/.commandcode/AGENTS.md`

Comparison is by **MD5 hash**. UTF-8 without BOM on write.

**Backup policy.** A timestamped `AGENTS.md.bak-<timestamp>` copy is taken **only when the target's content actually changes** — an already-in-sync target is left alone and produces no backup. After each run the script keeps the **5 latest** backups per target directory and prunes older copies, but only after confirming those 5 are non-empty. (Before 2026-10-19 it backed up unconditionally and never pruned; see §30.1.)

**`-Check` mode** prints the hash of each file and `DRIFTED` / `MISSING` / `in sync`, exit `2` if drifted.

**Manual use**

```powershell
~/Documents/Codex/tools/sync-agent-instructions.ps1
~/Documents/Codex/tools/sync-agent-instructions.ps1 -Check
```

> **Step order matters.** `sync-taste` (step 1) writes the canonical `~/.codex/AGENTS.md`, then propagates it. Step 3 runs the same propagation again. That is harmless — the script is idempotent — but it does mean the canonical file must be written *before* step 3, which is why the order is fixed in `self-repair.ps1`.

---

## 6. Steps 4 to 8: the skills, catalog and memory layer

### Step 4 - `sync-skills`

**The problem it solves.** `~/.agents/skills` is the canonical skill set. `tools/sync-skills.ps1` pushes it into `~/.codex/skills`, `~/.config/opencode/skills` and `~/.commandcode/skills`. Before 2026-10-19 nothing ran that push on a schedule, so a skill edited or added in one CLI stayed wrong in the other two until you ran the script by hand.

**The fix.** A nightly step that re-renders the canonical set into all three CLIs.

**Key properties**

- **Idempotent.** A skill is only copied when its `SKILL.md` content or its file count differs.
- **Runs with `-NoPrune`.** The nightly job never deletes a skill. `sync-skills.ps1` *can* prune a destination skill that is no longer in the canonical set, but that is a deletion, so it stays a manual, attended action.
- **No snapshot.** This is the one step with no entry in `$stepFiles`, and it is deliberate: the canonical set is never written by the step, the step is idempotent, and re-running it repairs a partial copy. The canonical set *is* the backup for this layer.
- **No plugin wiring needed.** Skills in the canonical set reach all three CLIs. The Codex plugin copy of Superpowers is cached but unregistered, and does not need to be.

**Output:** `sync-skills: done`

**Manual use**

```powershell
~/Documents/Codex/tools/sync-skills.ps1            # apply
~/Documents/Codex/tools/sync-skills.ps1 -Check     # drift report, exit 2 if pending
~/Documents/Codex/tools/sync-skills.ps1 -NoPrune   # apply without deleting dest-only skills
```

---

### Step 5 - `refresh-free-models`

**The problem it solves.** A free model gets retired upstream. Your fallback list still names it. The router picks it. It 404s. And this repeats daily until someone notices.

**The fix.** Never hand-maintain the free list. Read it from each CLI's own catalog:

| Backend | Source | Filter |
|---|---|---|
| Command Code | live `--list-models` output from the installed CLI | lines tagged with an uppercase `FREE` tag |
| OpenCode | `~/.cache/opencode/models.json`, provider `opencode` | `cost.input == 0` and `cost.output == 0` and `status != 'deprecated'` |

If the Command Code CLI is unavailable, it falls back to `tools/model-prices.json` entries with `free = true`.

**Ordering:** newest free model first, per backend (OpenCode sorts by `release_date` descending).

**Privacy guard:** any model whose upstream may train on your prompts is **always excluded** — currently `glyph-cluster:free`, matched as a substring so a provider prefix (`stealth/glyph-cluster:free`) is still caught.

**Staleness guard:** the router refuses to use a catalog older than **3 days** — a stale catalog is worse than none, because it still offers retired models. The nightly job keeps it fresh.

**Output shape**

```json
{
  "generatedAt": "2026-10-19T08:00:06Z",
  "commandcode": ["reflection/beam:free", "poolside/laguna-s-2.1-free", "stealth/cat-jam:free"],
  "opencode":    ["opencode/nemotron-3.5-super-vl-free", "..."]
}
```

**Manual use**

```powershell
~/Documents/Codex/tools/refresh-free-models.ps1
```

---

### Step 6 - `memory-curate`

**The problem it solves.** Codex only updates `MEMORY.md` when you explicitly ask. Raw rollout summaries pile up faster than curation happens, so most of what was learned never makes it into memory.

**The fix.** This script does the **mechanical half**, deterministically, with **no model calls** — so nothing can be hallucinated. Bullets are verbatim extractions.

**How it works**

1. Read every `*.md` in `~/.codex/memories/rollout_summaries/`, oldest first.
2. Skip anything already processed — tracked by `filename:MD5:v2` in `notes/.processed`.
3. Extract the `# Title`, the `Outcome:` line, the `thread_id` (for provenance), and the bullets under the two high-value sections:
   - `Failures and how to do differently:`
   - `Reusable knowledge:`
4. Write one note per summary to `notes/<timestamp>-<slug>.md`.
5. Record the key in `.processed`.

**The note format it produces**

```markdown
Proposed memory update distilled from rollout summary 20261019T030102-beluga-tv-log-anr.md
    (title: beluga-tv-log-anr-diagnosed-and-patched-with-automated-valid)
    (outcome: patched)

Rollout ids to cite:
3f9c1e2a-...

Learnings to consider adding:
- <verbatim bullet>
- <verbatim bullet>
```

**Output:** `curated 5 rollout summary(ies) -> ~/.codex/memories/extensions/ad_hoc/notes`

---

### Step 7 - `memory-consolidate`

**The problem it solves.** Step 5 creates notes, but nobody merges them into `MEMORY.md`. So notes accumulate and memory stays stale.

**The fix.** Also deterministic, no model calls.

**How it works**

1. Read every note that contains a `Learnings to consider adding:` section.
2. Skip notes already consolidated — tracked by `filename:MD5` in `notes/.consolidated`.
3. For each `- ` bullet: normalize (strip punctuation, lowercase, first 40 chars) and **skip it if that normalized key already appears anywhere in `MEMORY.md`**. That is the dedupe.
4. Group the surviving bullets by the note's title.
5. **Back up `MEMORY.md`** to `~/.codex/memories/backups/MEMORY.md.<timestamp>.bak`.
6. Append a dated section:

```markdown
# Consolidated learnings (auto, 2026-10-19)

## <topic>

- <bullet>
- <bullet>
```

7. Record the keys in `.consolidated`.

**Dedupe key detail:** the key is the first 40 normalized characters. A bullet that differs only in its tail will be considered a duplicate. That is intentional — it prevents near-identical lines from accumulating — but it means genuinely distinct learnings that share a 40-character prefix will be dropped.

**Output:** `consolidated 45 novel learning(s) across 5 topic(s)`

---

## 7. Steps 9 to 11: the routing and health layer

### Step 8 - `tier-adapt`

**The problem it solves.** The `quick` tier is chosen by a length + keyword heuristic. If quick tasks keep failing, the heuristic is too loose — and it will keep failing forever unless the threshold adapts.

**The fix.** Analyze recorded tier outcomes and tighten (or cautiously loosen) the quick threshold.

**The math**

```
quickSuccessRate = quickSuccesses / quickTotal
```

| Condition | Action |
|---|---|
| `quickSuccessRate < 0.70` **and** `quickTotal >= 5` | `maxQuickLength -= 20`, floor **80** |
| `quickSuccessRate > 0.90` **and** `quickTotal >= 20` | `maxQuickLength += 10`, ceiling **250** |
| fewer than 10 total records | no change, `only N samples, need 10+` |

**Deliberately conservative.** It only tightens when the data says quick is failing. It never touches the keyword lists — only the length.

**Output file**

```json
{ "maxQuickLength": 180, "quickSuccessRate": 1, "sampleCount": 23 }
```

**Output line:** `tier-adapt: quick success=100% (1 samples), maxQuickLength=180, changed=False`

> `changed=False` on most runs is normal and healthy. The system should mostly *observe*.

---

### Step 9 - `taste-promote`

**The problem it solves.** A preference that shows up twice in your notes is probably a real preference — but nothing notices.

**The fix.** Scan all note bullets, keep the ones that look preference-shaped, and propose the ones that appear **2+ times**.

**Preference-shaped patterns:** `always`, `prefer`, `never`, `instead of`, `use X over`, `do not`, `must`.

**Dedupe** is on the first 60 normalized characters. **Repeat counting** is done on the *raw* pre-dedupe list, keyed by the first five words after the dash — so the same learning recorded in two different note files still counts as a repeat.

**It never writes taste directly.** It writes `tools/taste-candidates.md` for a human (or the `taste` tool) to approve:

```markdown
# Taste candidates (auto-generated 2026-10-19)

Review these and apply via the `taste` tool if appropriate.
Total learning bullets scanned: 534
Preference-like candidates: 146
Repeated 2+ times (proposed below): 2

- - Do not treat automated tests, lint, release packaging, or ADB hierarchy inspection as proof of spoken accessibility ...
```

> Note the doubled `- -`. The script prefixes the bullet, and the extracted bullet already began with `- `. Cosmetic, but it means the file is not clean Markdown bullet syntax. Worth knowing before you paste from it.

**Current state:** 534 bullets scanned → 146 preference-like → 2 repeated. Both current candidates say the same thing in different words: *automated tests are not proof of accessibility*. That is exactly the behavior you want — the noise floor is high and the signal is real.

---

### Step 10 - `credit-check`

**The problem it solves.** Backends die. Credits run out. The router keeps picking a dead backend until every task fails.

**The fix.** Probe each backend and write health flags to `tools/agent-backend-health.json`.

| Backend | How it's checked | Result |
|---|---|---|
| **Codex** | **Not probed.** The old 365-day subscription lockout is gone. Health comes from *real run results* — `agent-task.ps1` sets/clears the flag on success or infrastructure failure. | `tracked by run results` |
| **Command Code** | Runs a tiny paid-model request: `Reply with exactly: OK`, 90s timeout. If the output matches `insufficient credits` → paid exhausted for 120 minutes. Exit code 0 → paid available, flag cleared. | `paid available` / `paid credits exhausted -> free models only` / `probe timeout` |
| **OpenCode** | Reads its local SQLite DB (`~/.local/share/opencode/opencode.db`) for assistant-message cost in the last 24h. Needs `sqlite3` on PATH; skipped gracefully if absent. | `12 requests, $0.0431 in 24h` |

**Cooldown skip:** if Command Code is already in a 5-hour cooldown, the probe is skipped entirely (`cooldown active -> probe skipped`) — probing would burn a free model for no information.

---

### Step 11 - `verify`

**The problem it solves.** A typo in any script means that script silently stops working. Every step above would then fail forever, and you would only find out when you needed the thing.

**The fix.** Three smoke checks. Exit `0` = all good, exit `1` = something is broken.

**Check 1 — Parse every `.ps1` in `tools/`.**
Uses the PowerShell AST parser (`[System.Management.Automation.Language.Parser]::ParseFile`) and reports every syntax error. Catches broken scripts before they are needed.

**Check 2 — Load the router and exercise it.**
Dot-sources `agent-route.ps1` (which must define functions without *doing* work on load), then calls `Get-RoutePenalties`, `Select-CheapModel -Tier quick`, and `Get-BackendRanking`. Asserts a model was returned. Output looks like:

```
route smoke OK: quick=deepseek/deepseek-v4-flash
backend ranking: codex > commandcode > opencode
```

**Check 3 — Codex shim drift.**
Verifies the npm shim at `%LOCALAPPDATA%\BlindPilot\npm\codex.cmd` exists and responds to `--version`, and that any prefix copy of `codex.cmd` reports the **same version**. This matters because `agent-task.ps1` uses the npm copy; a stale prefix copy is what a bare `codex` may resolve to. The desktop `codex.exe` 0.162.x ships a broken Windows sandbox helper (openai/codex#51634 — read-only exec dies with `setup refresh had errors`), which is why only the npm shim is used.

**Output:** `verify OK`

---

# Part 3 — The safety machinery

## 8. Snapshot, hash, manifest, rollback

This is the part that makes unattended repair safe. Read it once and you will trust the system.

### The sequence, per step

```
   ┌─ BEFORE ────────────────────────────────────────────┐
   │ 1. Read the step's file list from $stepFiles        │
   │ 2. For each file:                                   │
   │      a. Compute a SHA256 over the whole tree        │
   │         (path + is-directory + hash, sorted, JSON)  │
   │      b. Copy it to backups\<run>\<step>\<NN>\        │
   │      c. Re-hash the COPY                           │
   │      d. If copy hash != source hash → THROW          │
   │         "snapshot incomplete"                       │
   │      e. Write the hash to <NN>.sha256               │
   │ 3. Write manifest.txt (entry dir, existed?, target) │
   │ 4. Write manifest.sha256 (hash of the manifest)     │
   └──────────────────────────────────────────────────────┘
              │
              ▼  run the step
              │
   ┌─ AFTER ─────────────────────────────────────────────┐
   │ exit 0 → keep going, log the last output line       │
   │ exit != 0 →                                           │
   │      1. Append full output to self-repair-failures.log│
   │      2. Restore-Files:                               │
   │         a. Re-hash manifest.txt, compare to          │
   │            manifest.sha256 → mismatch = THROW        │
   │         b. Check entry count matches expected        │
   │         c. Check each entry path/existed-flag/target │
   │            matches the expected list                 │
   │         d. Re-hash each snapshot, compare to its     │
   │            .sha256 → mismatch = THROW                │
   │         e. Only now: write the snapshots back        │
   │      3. Log "ROLLED BACK"                            │
   └──────────────────────────────────────────────────────┘
```

### Why it is trustworthy

- **The snapshot is verified at copy time.** A truncated or partial copy is detected immediately and the step never runs.
- **The manifest is verified at restore time.** If someone edited the manifest, the restore aborts instead of restoring garbage.
- **The restore re-verifies every snapshot hash before writing anything.** A corrupted snapshot aborts the whole restore rather than writing a corrupted file.
- **Files the step created are removed.** If the target did not exist before the step, the rollback **deletes** it. This is the `exists = False` branch.
- **The whole restore is all-or-nothing.** Validation completes before the first write.

### The file map it uses

This is the contract between the step and the safety system. **If you add a step that writes a file, you MUST add that file to `$stepFiles` - otherwise it will not be rolled back.**

The one exception is `sync-skills`: its canonical source (`~/.agents/skills/`) is never written by the step, the step is idempotent, and re-running it repairs a partial copy - so the canonical set *is* its backup.

```powershell
$stepFiles = @{
    'sync-taste'              = @(
        ~/.codex/AGENTS.md, ~/.config/opencode/AGENTS.md,
        ~/.commandcode/AGENTS.md, ~/.claude/CLAUDE.md, ~/.gemini/GEMINI.md )
    'sync-agents'             = @(
        ~/.codex/agents, ~/.config/opencode/agents, ~/.commandcode/agents )
    'sync-agent-instructions' = @(
        ~/.config/opencode/AGENTS.md, ~/.commandcode/AGENTS.md )
    'refresh-free-models'     = @( tools/free-models.json )
    'memory-curate'           = @( ~/.codex/memories/extensions/ad_hoc/notes )
    'memory-consolidate'      = @(
        ~/.codex/memories/MEMORY.md,
        ~/.codex/memories/extensions/ad_hoc/notes/.consolidated )
    'tier-adapt'              = @( tools/agent-tier-thresholds.json )
    'taste-promote'           = @( tools/taste-candidates.md )
    'credit-check'            = @( tools/agent-backend-health.json )
    # 'sync-skills' is deliberately absent: its canonical source is never
    # written by the step and re-running it repairs a partial copy. See step 4.
}
```

`verify` is deliberately absent — it writes nothing.

### Retention

- **5 latest runs** kept under `tools/self-repair-backups/`.
- Pruning happens **before and after** the run, so a run that crashes mid-way still leaves the previous 5 intact.
- `AGENTS.md.bak-*` safety backups from `sync-agent-instructions.ps1` are **pruned to the 5 latest** by that script — see §30.

---

## 9. What is protected and what is not

### Protected by snapshot + rollback

Everything in `$stepFiles` above. If any of those steps corrupts its output, the run rolls it back.

`sync-skills` is the one exception, and it is deliberate: its source of truth
(`~/.agents/skills/`) is never written by the step, the step is idempotent, and
re-running it repairs a partial copy - so the canonical set *is* the backup for
that layer. The step also runs with `-NoPrune`, so it never deletes a skill
unattended; pruning stays a manual, attended action.

### Protected by the configuration repository

Everything the repository tracks: the policy, the docs, `workflows/`, `workflow/`,
`tools/` and the published HTML. A file that no longer parses is restored from
the last good commit by `repair-config.ps1` (see §3.1), and the broken copy is
kept next to it. The repository is local — there is no remote.

### Protected by the guard hook

See §25. Secret-shaped patches and patches touching signing keys are denied outright.

### Protected by the release gate

See §27. Clean tree, upstream parity, secret scan, gate commands, optional APK signer check.

### NOT protected

| Thing | Why it isn't | Mitigation |
|---|---|---|
| `~/.codex/config.toml` | Codex rewrites it itself; hand edits may be reverted | Back it up before editing; close Codex first |
| `~/.commandcode/settings.json` | Not in the nightly job's scope | Back up before editing |
| `~/.codex/hooks.json` | Not in the nightly job's scope | Back up before editing |
| `~/.agents/skills/` | Canonical; the sync only pushes *out* of it | It's the source — edits there are intentional |
| `tools/agent-route.ps1`, `agent-task.ps1` | Engine code, not managed state | Version-controlled in the configuration repo (see §3.1) |
| Your project repos | Out of scope entirely | Worktrees + release gate |

---

# Part 4 — Runtime self-healing

The nightly job fixes the configuration. **Runtime self-healing** fixes the environment, live, during a task.

## 10. Runtime 1: backend health and cooldown

### Health flags (30-minute TTL)

`tools/agent-backend-health.json` records a backend as unhealthy for **30 minutes**.

| Backend | Set unhealthy when | Cleared when |
|---|---|---|
| Codex | a run exits with an infrastructure signature | a run succeeds |
| Command Code | a run fails with an infrastructure signature, or the free-model retry fails | a run succeeds |
| OpenCode | a run fails with an infrastructure signature | a run succeeds |

`Test-BackendHealthy` is consulted by `Get-BackendRanking` and `Get-AutoBackend`. A dead backend is skipped **before** a task is dispatched, so you usually never see the failure at all.

### A credit error is a failure even when the CLI exits 0

Command Code v1.84.0 aborts a run with `Insufficient credits for Command Code.` and **exits 0**. Trusting the exit code alone made the router report a success that never ran the task, and the chain stopped there.

`Test-CreditFailure` (`tools/agent-route.ps1`) therefore reads the **tail** of a run's output and treats these provider phrases as a failure:

```
Insufficient credits for Command Code | insufficient credits to make this request | hit your usage limit
```

Only the last 1500 characters are read, so a long transcript that mentions credits in passing is not misread as a provider failure. `tools/verify.ps1` check 5 keeps this honest.

### Cooldown (5-hour window)

`tools/agent-usage.json` records the reset time of a Command Code 5-hour usage window.

When the window is exhausted:
- **Paid Command Code models are withheld** until the reset time passes.
- A **free** model is selected instead.
- Only if no free model fits does the task reroute to another backend.

OpenCode has its own cooldown flag, checked the same way.

Codex has no separate cooldown store. When its subscription runs out, the message says when it resets (`try again at 5:11 AM`); the router parses that and holds the backend unhealthy, so the router skips it instead of burning a failed run on every task. The printed time is not reliable — on 2026-10-20 Codex said `try again at 5:11 AM` and worked 35 minutes later — so the hold is capped at **one hour**.

### Reporting

```powershell
~/Documents/Codex/tools/agent-usage.ps1            # human-readable
~/Documents/Codex/tools/agent-usage.ps1 -Json      # machine-readable
~/Documents/Codex/tools/agent-usage.ps1 -ClearCooldown
```

`-Refresh` is a documented no-op — cooldowns self-update from real run results.

> Command Code and Codex subscription usage are **not readable headlessly**. Read the live number with `/usage` inside a Command Code session, or at https://commandcode.ai/usage.

---

## 11. Runtime 2: route feedback and model demotion

**The problem.** A free model gets retired. The catalog refresh hasn't happened yet. The router picks it. It 404s. Every task for the next day fails the same way — a repeated accident instead of a rule.

**The fix.** Every attempt is recorded to `tools/agent-route-feedback.jsonl`:

```json
{"time":"2026-10-19T14:22:01","backend":"commandcode","model":"reflection/beam:free","tier":"quick","exitCode":1,"infraFailure":"404 model not found"}
```

**The rule.** A model that collects **2 or more infrastructure failures within 7 days** is **demoted** — skipped by `Select-FreeModel` and by the price picker.

**The forgiveness rule.** A single **success** clears the model's failure record entirely. So a flaky day never permanently demotes a good model. The window is 7 days; older records are ignored.

```
model X:  fail, fail        → demoted
model X:  fail, fail, pass  → cleared, eligible again
```

This is what turns "the catalog is stale" into "the router learned", without waiting for a refresh cycle.

---

## 12. Runtime 3: the fallback chain

When a run fails with an **infrastructure signature**, the router falls back in a fixed order.

### What counts as an infrastructure failure

The matcher is a case-insensitive regex covering:

```
usage limit | rate limit | quota | insufficient credits | too many requests
429 | 401 | 403 | MODEL_NOT_IN_PLAN
no longer available | model not available | no longer supported
not signed in | unauthorized | forbidden
ECONNREFUSED | ETIMEDOUT | ENOTFOUND | EAI_AGAIN
unexpected server error | cannot find the file | is not recognized
requires a TTY | TTY terminal | interactive mode
npm codex shim missing | helper_unknown_error | setup refresh had errors
```

A **task-level** failure (the model said "I can't do that") is **not** an infrastructure failure. It is not retried.

A **provider credit/limit error** counts as a failure whatever the exit code says — see §10.

### The chain

```
  primary run
      │  fails with infra signature
      ▼
  retry SAME backend on a FREE model          (disable: -NoFreeFallback)
      │  fails
      ▼
  for each remaining backend, in health-aware order:
      run that backend's tier model
          │  fails with infra signature
          ▼
      retry THAT backend on a FREE model
          │  fails
          ▼
      next backend
      ▼
  throw, and report every log path
```

### Rules

- An explicit `-Model` / `-Effort` applies **only to the primary agent**, never to a fallback.
- The fallback backends come from `Get-BackendRanking` (health-aware), not hardcoded. Unhealthy backends are skipped; if every backend is unhealthy, each is tried anyway.
- Every attempt — primary, free, alternate — is recorded via `Add-RouteOutcome`, so all of them feed the demotion logic.
- A backend whose paid model died on credits is marked **paid exhausted** (120 min) and **unhealthy** (30 min), so the next run starts on a free model instead of repeating the failure.

### Also in this layer

**No-TTY guard.** Command Code's interactive mode needs a TTY. If output is redirected and the task is not `quick` and not `-ReadOnly`, the router switches to OpenCode (or Codex) instead of failing.

**Read-only inference.** If a `quick` task matches the lookup pattern (`explain`, `find`, `show`, `where`, `what`, …), `-ReadOnly` is turned on automatically, which selects a read-only agent and a read-only sandbox.

---

## 13. Runtime 4: adaptive tiers

Every task is classified into one of three tiers. The classification has two layers.

### Layer A — the keyword heuristic

```
DEEP  if the task text matches:
       security | auth(entication|orization) | permission | privacy
     | accessibility | screen.?reader | migration | architecture
     | release | deploy | payment | data.?loss
     | race.?condition | concurren | multi.?agent | multiple repos
     | cross.?repo | refactor

QUICK if (length <= maxQuickLength) AND
       ( matches lookup pattern   : ^\s*(explain|summari[sz]e|find|locate|list|show|
                                     what|where|check|how|why|which|who|whose|is|are|
                                     does|do|did|can|could|will|would|should|may|might)\b
       OR matches small-edit pattern: ^\s*(fix|change|rename|update|remove|add)\b
                                     .*\b(typo|label|wording|text|string|comment|
                                          one file|single file|small)\b )

STANDARD  everything else
```

### Layer B — the adaptive length threshold

`maxQuickLength` comes from `tools/agent-tier-thresholds.json` (default **180**), and is adjusted by `tier-adapt.ps1` as described in §7. So "quick" means *short AND simple AND recently successful*.

### The tier table

| Tier | Command Code | Codex | OpenCode |
|---|---|---|---|
| `quick` | `deepseek/deepseek-v4-flash` | `gpt-6-luna` | `opencode/deepseek-v4.1-flash-free` |
| `standard` | `deepseek/deepseek-v4-pro` | `gpt-6.1-sol` | `opencode/deepseek-v4.1-flash` |
| `deep` | `deepseek/deepseek-v4-pro` (effort `max`) | `gpt-6-astra` | `opencode/deepseek-v4-pro` |

**This is the static fallback.** In practice the *price picker* chooses within the tier — see §14.

### Overriding

```powershell
work '<task>' -Complexity deep      # force a tier
work '<task>' -Agent commandcode    # force a backend
work '<task>' -ReadOnly             # force read-only
```

---

## 14. Runtime 5: price-aware selection

For the Command Code backend, the model is **not** hardcoded. It is the cheapest *eligible* model from a curated candidate list.

### Two separate judgments

1. **Capability** — the candidate shortlist per tier is a **human judgment**, made once and hand-maintained.
2. **Price** — the *only* automatic decision. Among eligible candidates, the cheapest wins.

### The candidate shortlists

```powershell
quick    = poolside/laguna-s-2.1-free, stealth/cat-jam:free,
           meta/muse-spark-1.3-contributor, xiaomi/mimo-v2.5,
           qwen/qwen3.7-flash, qwen/qwen3.8-flash,
           deepseek/deepseek-v4-flash, deepseek/deepseek-v4.1-flash,
           z-ai/glm-5.3-flash

standard = deepseek/deepseek-v4-pro, minimaxai/minimax-m3,
           moonshotai/kimi-k2.7-code, zai-org/glm-5.3, xai/grok-4.5

deep     = moonshotai/kimi-k3, qwen/qwen3.8-max, zai-org/glm-5.3,
           minimaxai/minimax-m3, xai/grok-4.5, deepseek/deepseek-v4-pro
```

### The cost model

Cost is **blended over a typical request**, not per-token:

```powershell
$CostProfile = @{ Input = 800; Output = 160; CacheRead = 50000 }
```

**Cache reads dominate** — 50,000 cached tokens against 800 fresh input tokens. This is deliberate: in a real long session, every turn re-reads the context, so cache-read price is what actually determines cost. A model that is cheap per input token but expensive per cache-read token can lose on blended cost, which is correct.

### The eligibility filters

A candidate is skipped if it:

- **is not in your plan** — this account is Go-tier, so `gpt-6.1-sol`, `gpt-6-astra`, Claude, and Gemini are all filtered out. Plan rank: `go=1 < goat=2 < pro=3 < max=4`.
- **may train on your prompts** — always excluded, regardless of price.
- **is demoted** — 2+ infra failures in 7 days.
- **is excluded by flags** — `-NoFree` removes free models; `-Static` bypasses the price picker entirely and uses the hand-picked table.
- **is in a DeepSeek peak window at a bad price** — the peak/off-peak window (Mon–Fri 01–04 and 06–10 UTC) is applied when in effect.

### Effort is derived per model

Effort is **not** assumed. It comes from the catalog, because several cheap models accept no reasoning effort at all (their column reads `—`). Setting effort on such a model fails.

### Free vs paid rule

| Tier | Free allowed? |
|---|---|
| `quick` | **Yes** — the cheapest eligible model may well be free |
| `standard`, `deep` | **No** — cheapest eligible **paid** model |
| *fallback* | Yes, when no paid model is available |

Free is never selected from an upstream that may train on your prompts.

### Inspect without spending

```powershell
work '<task>' -Preview
```

Prints the backend, model, effort, mode, and an estimated cost. It contacts no model.

---

# Part 5 — The learning loop

## 15. The memory loop

```
   Codex session
        │
        ▼
  rollout_summaries/*.md          ← raw, one per session
        │
        │  memory-curate.ps1  (verbatim extraction, no model)
        ▼
  notes/<timestamp>-<slug>.md     ← structured, one per summary
        │
        │  memory-consolidate.ps1  (dedupe against MEMORY.md, no model)
        ▼
  MEMORY.md                       ← consolidated, appended under dated sections
        │
        │  (you read this at session start)
        ▼
  better next session
```

**Why no model calls?** Because a deterministic script cannot hallucinate. Every bullet in `MEMORY.md` came from a real session summary, verbatim. A model-written curator could invent a plausible-sounding lesson that never happened.

**The two index files** live in `notes/`:

| File | Written by | Purpose |
|---|---|---|
| `.processed` | `memory-curate.ps1` | `filename:MD5:v2` of summaries already curated |
| `.consolidated` | `memory-consolidate.ps1` | `filename:MD5` of notes already merged |

Both are append-only. Delete them and the corresponding work is redone from scratch (and the bullets will be deduped against `MEMORY.md` anyway, so it is safe).

**`MEMORY.md` is backed up** before every append to `~/.codex/memories/backups/MEMORY.md.<timestamp>.bak`.

### Reading memory

```powershell
Get-Content ~/.codex/memories/MEMORY.md -Tail 40
Get-ChildItem ~/.codex/memories/extensions/ad_hoc/notes/*.md | Measure-Object
```

---

## 16. The taste loop

```
   You work with Command Code
        │
        ▼
  ~/.commandcode/taste/taste.md     ← learned preferences + confidence scores
        │
        │  sync-taste.ps1
        ▼
  TASTE:BEGIN ... TASTE:END block   ← injected into each agent's AGENTS.md
        │
        ▼
  Codex / OpenCode / CommandCode / Claude / Gemini all behave consistently
        │
        │  taste-promote.ps1 scans notes for repeats
        ▼
  tools/taste-candidates.md         ← proposals, human-approve via `taste`
```

### The taste file format

`~/.commandcode/taste/taste.md` holds markdown with a confidence score per entry. The current file is ~5.5 KB and has 7 timestamped backups alongside it (`taste.md.pre-*.bak`), so you can see how preferences accumulated.

### Approving candidates

`tools/taste-candidates.md` is a **proposal file**. Nothing auto-applies it. To promote a candidate:

1. Read `tools/taste-candidates.md`.
2. Move the wording you like into `~/.commandcode/taste/taste.md` (or use Command Code's `taste` tool to record the preference).
3. Run `sync-taste.ps1` to propagate.

The loop closes: notes → candidates → taste → agent instructions → better behavior → better notes.

---

# Part 6 — Manual operations

## 17. Complete command cheat sheet

### The everyday commands

```powershell
work '<task>'                          # route and run a task
work '<task>' -Preview                 # show the route, spend nothing
work '<task>' -Complexity deep         # force a tier
work '<task>' -Agent commandcode       # force a backend
work '<task>' -ReadOnly                # read-only agent + sandbox
work '<task>' -N 2                     # best-of-2: two attempts in parallel worktrees
work '<task>' -WorkDir C:\path         # run in a different directory

wt -Repo tv-launcher -Name fix-focus -Base master   # new worktree for a task
wt -Repo tv-launcher -Name spike -Preview            # show the plan first

reload                                # re-source the PowerShell profile
workflow-status                       # one-screen health check (exit 0 = healthy)
```

### The repair commands

```powershell
# Everything (what the nightly job runs)
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/self-repair.ps1

# Individual steps
~/Documents/Codex/tools/sync-taste.ps1
~/Documents/Codex/tools/sync-agents.ps1
~/Documents/Codex/tools/sync-agent-instructions.ps1
~/Documents/Codex/tools/sync-skills.ps1
~/Documents/Codex/tools/refresh-free-models.ps1
~/Documents/Codex/tools/refresh-model-prices.ps1
~/Documents/Codex/tools/memory-curate.ps1
~/Documents/Codex/tools/memory-consolidate.ps1
~/Documents/Codex/tools/tier-adapt.ps1
~/Documents/Codex/tools/taste-promote.ps1
~/Documents/Codex/tools/credit-check.ps1
~/Documents/Codex/tools/verify.ps1
```

### The drift-check commands

All of these print what *would* change, change nothing, and exit `2` if drift exists:

```powershell
~/Documents/Codex/tools/sync-taste.ps1 -Check
~/Documents/Codex/tools/sync-agents.ps1 -Check
~/Documents/Codex/tools/sync-agent-instructions.ps1 -Check
~/Documents/Codex/tools/sync-skills.ps1 -Check
```

### The skills command

```powershell
~/Documents/Codex/tools/sync-skills.ps1            # push ~/.agents/skills to all three CLIs
~/Documents/Codex/tools/sync-skills.ps1 -Check     # drift report
~/Documents/Codex/tools/sync-skills.ps1 -NoPrune   # apply without deleting dest-only skills
```

`.system` is never shipped. A skill you *move out* of `~/.agents/skills` is **pruned** from all three destinations — that is the point of a canonical source, but it deletes files, so use `-NoPrune` if you are unsure.

### The release gate

```powershell
~/Documents/Codex/tools/release-gate.ps1 -Repo C:\path\to\repo `
    -GateCommands "uv run ruff check src tests"

~/Documents/Codex/tools/release-gate.ps1 -Repo C:\path\to\repo -DryRun
~/Documents/Codex/tools/release-gate.ps1 -Repo C:\path\to\repo -AllowUnpushed
~/Documents/Codex/tools/release-gate.ps1 -Repo C:\path\to\repo -Apk C:\path\app.apk
```

### The guard hook self-test

```powershell
~/Documents/Codex/tools/guard-hook.ps1 -SelfTest
# self-test: 5/5 pass (protected path denied, secret denied, clean allowed, Bash untouched, deny carries path)
```

---

## 18. How to run the repair by hand

### The full run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/self-repair.ps1
```

Watch the log:

```powershell
Get-Content ~/Documents/Codex/tools/self-repair.log -Tail 15
```

Check the exit code:

```powershell
$LASTEXITCODE
```

`0` = everything passed. `1` = at least one step failed or rolled back.

### One step at a time

Each step is a standalone script that prints `ok` / `updated` / `DRIFT` and exits `0` on success. Run the one you are interested in:

```powershell
~/Documents/Codex/tools/verify.ps1
~/Documents/Codex/tools/sync-agents.ps1 -Check
```

### A safe dry run

The engine has no built-in `-DryRun`. To see what *would* change without changing anything, use the `-Check` flags on the individual sync scripts. For the nightly job itself, the closest safe equivalent is:

```powershell
# Confirm every layer is currently in sync, without writing.
~/Documents/Codex/tools/sync-taste.ps1 -Check
~/Documents/Codex/tools/sync-agents.ps1 -Check
~/Documents/Codex/tools/sync-agent-instructions.ps1 -Check
~/Documents/Codex/tools/sync-skills.ps1 -Check
~/Documents/Codex/tools/verify.ps1
```

---

# Part 7 — Troubleshooting

## 19. Symptom, cause, fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent ignores a preference you taught it | The taste block is stale | `sync-taste.ps1` |
| OpenCode behaves differently from Codex | Instruction copies diverged | `sync-agent-instructions.ps1` |
| A roster agent is missing in one CLI | Agent render drifted | `sync-agents.ps1` |
| An old agent file reappears | It is in the superseded list but was renamed back | `sync-agents.ps1` (it renames it again) |
| Tasks fail with "model not found" | Free catalog stale, or the model was retired | `refresh-free-models.ps1`; the demotion logic will also skip it |
| The same model is picked and keeps failing | It has 2+ infra failures — it should be demoted | Check `agent-route-feedback.jsonl`; a success clears it |
| Everything routes to OpenCode | Codex and Command Code both unhealthy | `agent-usage.ps1`; wait 30 min or `ClearCooldown` |
| `verify` fails with PARSE FAIL | A `.ps1` has a syntax error | The message names the file and line — fix it, re-run `verify.ps1` |
| `verify` fails with CODEX SHIM FAIL | The npm codex shim is missing or version-drifted | `npm install -g --prefix %LOCALAPPDATA%\BlindPilot\npm @openai/codex@0.163.0` |
| `verify` fails with ROUTE SMOKE FAIL | `agent-route.ps1` threw on load | Run it manually to see the real error |
| No taste block appears | No taste file exists yet | Learn a preference in Command Code; check `~/.commandcode/taste/taste.md` |
| `memory-consolidate` says "0 novel learning(s)" | Everything was already deduped, or there are no notes | Normal. Run `memory-curate.ps1` first |
| `tier-adapt` says "only N samples, need 10+" | Not enough recorded outcomes yet | Normal. It needs 10+ tier outcomes |
| The nightly job did not run | You were signed out at 03:00, or the machine was off | It runs at next sign-in (`StartWhenAvailable`). Check `LastRunTime`. |
| A nightly step shows `ROLLED BACK` | That step failed; its changes were reverted | Read `self-repair-failures.log` for the full output |
| `sync-agent-instructions` creates a new `.bak` every run | Fixed 2026-10-19: it backs up only on an actual change | — |

---

## 20. Reading the logs

### `tools/self-repair.log`

One line per step per run:

```
2026-10-19 03:00:04 sync-taste                   canonical hash: DE8A9FF9A48E4C0C157042E589B21BCA
2026-10-19 03:01:07 memory-consolidate           consolidated 45 novel learning(s) across 5 topic(s)
2026-10-19 03:01:21 verify                       verify OK
```

Column 1: timestamp. Column 2: step name (padded to 28). Column 3: the **last output line** of that step.

**Status vocabulary**

| Pattern | Meaning |
|---|---|
| `ok` / `updated` / `in sync` | Step succeeded, nothing to do or a write happened |
| `FAILED (exit N): <last line>` | Step failed; details in the failures log; state rolled back |
| `ROLLED BACK` | The restore succeeded |
| `ROLLBACK FAILED: <msg>` | **The restore itself failed — the machine may now be in a mixed state. Act immediately.** |
| `BACKUP FAILED: <msg>` | The snapshot could not be taken; the step was **skipped**, not run. Nothing was changed. |
| `MISSING` | The step's script file does not exist |
| `run complete ok=11 failed=0` | The summary line for the whole run |

### `tools/self-repair-failures.log`

Full output of failed steps:

```
==== 20261019-030102 memory-consolidate exit=1 ====
<full stdout+stderr, truncated at 4000 chars>

```

### `tools/self-repair-backups/<runStamp>/<step>/`

```
20261019030002/
├── manifest.txt            ← entry dir, existed?, target path
├── manifest.sha256         ← integrity hash of the manifest
├── 01/
│   └── AGENTS.md           ← the snapshot
├── 01.sha256               ← integrity hash of the snapshot
├── 02/
└── 02.sha256
```

### Useful log queries

```powershell
# Failures in the last week
Get-Content ~/Documents/Codex/tools/self-repair.log |
  Where-Object { $_ -match 'FAILED|ROLLBACK' -and $_ -match '2026-10-1[3-9]' }

# How many runs passed fully
Get-Content ~/Documents/Codex/tools/self-repair.log |
  Where-Object { $_ -match 'run complete' } | Select-Object -Last 10
```

---

## 21. Manual rollback

If a step's `ROLLBACK FAILED` fired, or you want to undo a run by hand:

### Step 1 — find the run you want

```powershell
Get-ChildItem ~/Documents/Codex/tools/self-repair-backups -Directory |
  Sort-Object Name -Descending | Select-Object Name
```

### Step 2 — inspect the manifest

```powershell
$run = '20261019030002'
Get-Content "$HOME/Documents/Codex/tools/self-repair-backups/$run/memory-consolidate/manifest.txt"
```

Format is `entry_dir \t existed(True|False) \t target_path`.

### Step 3 — restore by hand

```powershell
$root = "$HOME/Documents/Codex/tools/self-repair-backups/$run/memory-consolidate"
Get-Content "$root/manifest.txt" | ForEach-Object {
    $entry, $exists, $target = $_ -split "`t", 3
    $src = Join-Path $entry (Split-Path -Leaf $target)
    if ($exists -eq 'True') {
        Copy-Item $src $target -Recurse -Force
        "restored $target"
    } else {
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        "removed (did not exist before) $target"
    }
}
```

**Verify the snapshot integrity first** if you care:

```powershell
Get-Content "$root/01.sha256"   # expected
(Get-FileHash "$root/01/MEMORY.md" -Algorithm SHA256).Hash   # actual
```

### Step 4 — check the other layers

```powershell
~/Documents/Codex/tools/sync-agent-instructions.ps1 -Check
~/Documents/Codex/tools/sync-agents.ps1 -Check
~/Documents/Codex/tools/sync-taste.ps1 -Check
```

---

# Part 8 — Advanced

## 22. Adding a repair step

This is the most useful thing you can learn to do here. The pattern is: **write the step as a standalone script, then register it in two places.**

### Step 1 — write the script

Requirements, so the engine can guard it:

- It must **exit `0` on success** and **non-zero on failure**. Use `exit 0` explicitly.
- It must be **idempotent** — running it twice must not change anything the second time. The nightly job runs it every day.
- It must print a **single useful final line**; that is what lands in the log.
- It must not depend on interactive input or a TTY.
- It must not write outside the paths you declare in `$stepFiles`.

A good template:

```powershell
#Requires -Version 5
<#
  my-check.ps1 — one-line description.

  Reads:  ...
  Writes: ...
  Exit 0 on success, 1 on failure.
#>
$ErrorActionPreference = 'Stop'

# ... work ...

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Output "PROBLEM: $p" }
    Write-Output "my-check: $($problems.Count) problem(s) found"
    exit 1
}
Write-Output 'my-check: OK'
exit 0
```

### Step 2 — register it in `$stepFiles` (if it writes anything)

Open `tools/self-repair.ps1` and add an entry to the `$stepFiles` hashtable:

```powershell
'my-check' = @(
    (Join-Path $env:USERPROFILE '.codex\memories\MEMORY.md'),
    (Join-Path $PSScriptRoot 'my-output.json')
)
```

**This entry is mandatory.** Without it, the step's writes are **not** rolled back on failure. The engine reads the file list from here when it snapshots and when it restores.

Two steps are deliberately absent from `$stepFiles`: `sync-skills` (its canonical
set is never written by the step, so it is its own backup) and `repair-config`
(the configuration repository is its own backup — see §3.1). A step that writes
a file *tracked by the configuration repository* is still covered by the repo,
but the snapshot still wins, because it restores the exact bytes the step found.

### Step 3 — register it in `$steps`

In the same file, add to the array:

```powershell
$steps = @(
    @{ Name = 'sync-taste';              Script = 'sync-taste.ps1' },
    ...
    @{ Name = 'my-check';                Script = 'my-check.ps1' }
)
```

### Step 4 — place it in the order you want

Order matters:

- Anything that reads `agents.toml` must come **after** `sync-agents` if it should see the rendered output.
- Anything that reads the canonical `AGENTS.md` must come **after** `sync-taste`.
- `verify` should stay **last** — it is the gate for the whole run.

### Step 5 — test it in isolation, then in the engine

```powershell
# In isolation
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/my-check.ps1
echo "exit=$LASTEXITCODE"

# Then run it twice to prove idempotency
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/my-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/my-check.ps1

# Then the full engine
powershell -NoProfile -ExecutionPolicy Bypass -File ~/Documents/Codex/tools/self-repair.ps1
echo "exit=$LASTEXITCODE"
```

### Step 6 — verify the rollback path

Temporarily make the step fail (exit 1) and confirm the engine rolls it back:

```powershell
Get-Content ~/Documents/Codex/tools/self-repair.log -Tail 15
# look for: my-check  FAILED (exit 1): ...  then  my-check  ROLLED BACK
```

Then **restore the step's script** and run the engine once more.

---

## 23. Changing the agent roster

### The roster

`workflows/agents.toml` is the single source of truth:

```toml
[roster]
codex_default_model = "gpt-6-luna"
codex_default_effort = "low"

[agents.scout]
description = "Read-only researcher and code locator. ..."
kind = "read-only"          # "read-only" | "writer"
codex_model = "gpt-6-luna"
codex_effort = "low"
opencode_model = "opencode/deepseek-v4.1-flash-free"
instructions = """
...multi-line text...
"""
```

### The four current agents

| Agent | Kind | Role | Codex model | OpenCode model |
|---|---|---|---|---|
| **scout** | read-only | Locate code, map subsystems, gather evidence. Returns `file:line` findings. | `gpt-6-luna` (low) | `opencode/deepseek-v4.1-flash-free` |
| **builder** | writer | The **sole writer**. Implements one bounded change. | `gpt-6-sol` (high) | `opencode/deepseek-v4-pro` |
| **verifier** | read-only | Reviews a diff, runs the project's checks. | `gpt-5.6-terra` (medium) | `opencode/deepseek-v4.1-flash` |
| **debugger** | writer | Reproduce → root cause → smallest fix → regression check. | `gpt-6-astra` (high) | `opencode/gpt-5.3-codex` |

### The rules the roster encodes

- **One writer per file.** Parallel agents may read freely; only one may edit a given file.
- **A read-only agent names the agent it needs** instead of editing.
- **The verifier checks model families, not CLI names.** "A different CLI alone does not prove a different family." If a cross-family reviewer is unavailable, it must **report the review gap** rather than claim cross-model review.
- **The debugger must reproduce first**, and must never silence a failure by weakening tests or adding retries without a cause.
- **The scout must distinguish observed behavior from inference**, and must never claim device verification from code inspection.

### Changing it

1. Edit `workflows/agents.toml`.
2. Render:
   ```powershell
   ~/Documents/Codex/tools/sync-agents.ps1
   ```
3. Verify:
   ```powershell
   ~/Documents/Codex/tools/sync-agents.ps1 -Check   # exit 0, no DRIFTED
   ~/Documents/Codex/tools/verify.ps1
   ```
4. Restart any running CLI sessions — they read their agent files at session start.

**Adding an agent** = add an `[agents.<name>]` block. **Renaming** = rename the block; the old rendered file is renamed to `.superseded-<timestamp>`, not deleted. **Removing** = delete the block; the old file is renamed aside.

### The TOML subset the parser understands

`sync-agents.ps1` uses its own minimal TOML reader, not a real TOML library. It handles:

- `[table]` and `[table.subtable]` headers
- `key = "string"` (with `\"` escapes)
- `key = """multi-line"""` (triple-quoted, no escapes)
- `# comments` (whole-line and trailing on unquoted values)
- Bare values (`true`, numbers) — kept as strings

**It does not handle** arrays, inline tables, single-quoted strings, or date literals. Do not use them in `agents.toml`.

---

## 24. Changing the schedule

```powershell
# See the current trigger
Get-ScheduledTask -TaskName CodexWorkflowSelfHeal | Select -Expand Triggers

# Change the time (e.g. to 04:30)
$action = (Get-ScheduledTask -TaskName CodexWorkflowSelfHeal).Actions
$trigger = New-ScheduledTaskTrigger -Daily -At 4:30AM
Set-ScheduledTask -TaskName CodexWorkflowSelfHeal -Trigger $trigger -Action $action

# Disable entirely (without deleting the definition)
Disable-ScheduledTask -TaskName CodexWorkflowSelfHeal

# Re-enable
Enable-ScheduledTask -TaskName CodexWorkflowSelfHeal

# Delete the task
Unregister-ScheduledTask CodexWorkflowSelfHeal -Confirm:$false
```

**After changing the trigger, run it once by hand** to confirm it still works:

```powershell
Start-ScheduledTask -TaskName CodexWorkflowSelfHeal
Start-Sleep -Seconds 60
Get-ScheduledTaskInfo -TaskName CodexWorkflowSelfHeal | Format-List LastRunTime, LastTaskResult
```

`LastTaskResult: 0` = success.

> The task runs `Limited` (not elevated) as your user, `Interactive` (only while signed in). If you want it to run whether or not you are signed in, you would need to change the principal to `S4U` or store a password — but that changes where the CLIs' credentials come from, so think before you do it.

---

## 25. The guard hook

### What it does

`~/.codex/hooks.json` wires `tools/guard-hook.ps1` as a **`PreToolUse`** hook. Codex pipes a JSON object on stdin; the hook inspects it and either stays silent (allow) or prints a deny decision.

**Every `PreToolUse` event runs Claudio first, then the guard hook.** The guard hook only ever denies. All other lifecycle events (`Stop`, `SessionStart`, `PostToolUse`, …) stay with Claudio.

### The two guards

**Guard 1 — protected paths.** Denies an `apply_patch` that touches:

```
*.keystore   *.jks   keystore.properties   local.properties   *.pem   *.key   .env*
```

**Guard 2 — secret scanning.** Denies an `apply_patch` whose **added** lines (lines starting with `+`, excluding `+++`) match:

```
-----BEGIN [A-Z ]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
sk-ant-[A-Za-z0-9-]{20,}
xox[bpoa]-[A-Za-z0-9-]{10,}
AIza[0-9A-Za-z_-]{35}
```

### The deny shape

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse",
 "permissionDecision":"deny","permissionDecisionReason":"..."}}
```

The exit code stays `0` even on deny — the decision travels in the JSON, per the Codex hooks contract.

### The reason text names the file and the pattern

```
Protected file 'app/keystore.properties' - guard-hook blocks patches matching
keystore\.properties$. Move secrets out of band or ask the user to make this
change by hand.
```

For secrets, only the first 60 characters of the offending line are echoed — enough to find it, not enough to leak it.

### Testing it

```powershell
~/Documents/Codex/tools/guard-hook.ps1 -SelfTest
# self-test: 5/5 pass (protected path denied, secret denied, clean allowed, Bash untouched, deny carries path)
```

The self-test feeds the hook four synthetic payloads (protected path, secret, clean patch, a `Bash` call) and asserts each outcome.

> **Scope limit:** the guard only covers `apply_patch`. A `Bash` command that writes a secret to a file is not caught by this hook. The `release-gate.ps1` secret scan (§27) covers the committed-file case.

---

## 26. Worktree isolation

### Why

A fresh worktree does not carry your repo's gitignored local files — and without them (SDK paths, signing config, `.env`) a build fails before it starts.

`new-worktree.ps1` fixes that by copying the files the repo declares in `.worktreeinclude`.

### Usage

```powershell
wt -Repo tv-launcher -Name fix-focus -Base master
wt -Repo tv-launcher -Name spike -Preview
```

Worktrees land in `<workspace>\.worktrees\<repo>-<name>` — never inside the repo, so they are never untracked files in your checkout.

### `.worktreeinclude`

Gitignore-style, one pattern per line, `#` for comments:

```
local.properties
keystore.properties
*.keystore
*.jks
.env
```

Without the file, the built-in default list is used:
`local.properties`, `keystore.properties`, `*.keystore`, `*.jks`, `.env`, `.env.*`.

**Supported patterns:** plain paths and simple globs. `!` negation and leading-`/` anchoring are **not** supported.

### The rules

- **Cap 2–3 in flight.** Review capacity is the limit, not compute.
- **Give each worktree its own dev-server ports and scratch database.**
- **Put the worktree name in the first message** when dispatching an agent: *"work only in this worktree."*
- **Clean up after merging:**
  ```powershell
  git worktree remove --force <path>
  git branch -D <name>
  ```

### Best-of-N

`agent-task.ps1 -N 2` runs the same task as **two independent attempts in two parallel worktrees**, then shows both reports and the diff summary for you to pick. Files never collide because each attempt has its own sandbox.

```powershell
work '<task>' -N 2
```

---

## 27. The release gate

One command before any push of a release.

```powershell
~/Documents/Codex/tools/release-gate.ps1 -Repo C:\path\to\repo `
    -GateCommands ".\gradlew.bat :app:testFullDebugUnitTest"
```

### The five steps, fail-fast, with numbered evidence

| # | Check | Fails when |
|---|---|---|
| 1 | **Clean working tree** | `git status --porcelain` is non-empty |
| 2 | **Unpushed commits** | There is no upstream branch, or HEAD is ahead of it |
| 3 | **Secret scan** | `git grep -I -n -E` finds a secret-shaped line in **tracked** files |
| 4 | **Gate commands** | Any `-GateCommands` command exits non-zero |
| 5 | **APK signer** (optional, `-Apk`) | `apksigner verify --print-certs` fails, or `apksigner` is not at the expected path |

Step 3 uses the **same patterns** as the guard hook — one definition of "secret-shaped", used in two places.

### Flags

| Flag | Effect |
|---|---|
| `-AllowUnpushed` | Skip step 2 (for local-only releases) |
| `-DryRun` | Print the step list without running anything |
| `-Apk <path>` | Add the signer check |

### Output shape

```
release-gate: ~/Documents/Codex/beluga
------------------------------------------------------------
[1] PASS clean working tree
[2] PASS unpushed commits check
[3] PASS secret scan (tracked content)
[4] PASS gate command
------------------------------------------------------------
release-gate PASS
```

On failure: `[3] FAIL secret scan (tracked content) : <detail>` and exit `1`.

---

## 28. Cross-CLI handoff

The `agent_interop` MCP server (`tools/agent-interop/server.mjs`) lets one CLI hand a task to another.

### How

```
preview  → agent_route_preview    (what would the target CLI pick?)
start    → agent_handoff_start     (returns a job ID)
poll    → agent_handoff_status    (returns the result)
```

Parameters: target CLI, task, working directory, complexity (`auto`/`quick`/`standard`/`deep`), mode (`read`/`edit`). Model and effort are selected through `agent-task.ps1`, so the target uses the same routing rules.

Starting returns a job ID; you poll for the result. This keeps nested CLI runs **out of the parent turn's synchronous call**.

### Rules

- **Same-CLI handoffs are rejected.** Recursive handoffs are rejected.
- **At most 2 jobs per MCP server process.**
- **A job ends after 30 minutes.**
- **Closing the MCP server stops its active jobs.** Job IDs exist only for that server session.
- **An edit handoff creates a detached worktree** from `HEAD` and leaves it for you to inspect and integrate. Uncommitted and ignored files from the source checkout are absent.
- **A read handoff runs in the supplied directory** (no worktree).

### OpenCode's dedicated handoff agents

| Agent | Allowed | Denied |
|---|---|---|
| `interop_read` | file reading, search, LSP inspection | shell, edits, subagents, MCP tools |
| `interop_edit` | worktree edits, commands | `external_directory`, subagents, MCP tools |

This is a **CLI permission boundary, not an OS sandbox.** Shell commands in `interop_edit` are not OS-isolated. The worktree gives isolation from the source checkout — review the result before integrating.

### Checks

```powershell
npm test --prefix tools/agent-interop                          # inner check
codex mcp list; opencode mcp list; cmd mcp list                 # gate
```

Restart existing CLI sessions to load new MCP settings.

---

# Part 9 — Known limits and drift

## 29. Things that are weaker than they look

### Approval policy is not enforced by the runtimes

The global policy asks for approval before commits, pushes, releases, and destructive actions. The runtimes **do not fully enforce it**:

| Runtime | Actual state |
|---|---|
| **Codex** | `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, network on |
| **CommandCode** | `defaultMode = "default"`, broad allow-list. Explicit ask and deny rules survive yolo/bypass mode, but the engine documents aggressive matching through some process wrappers |
| **OpenCode v1** | Global `permission` allows every tool, including Bash and `external_directory` |

**This means the approval rules in `AGENTS.md` are required agent *behavior*, not a technical control.** A model that ignores the rule can act. State plainly when approval was assumed.

### `config.toml` is app-managed

Codex rewrites `~/.codex/config.toml`. Hand edits are safe only while Codex is closed, and may be rewritten on the next launch. Back it up first.

### Read-only is not absolute

- **Codex agents inherit the parent sandbox.** An agent's own read-only *instructions* do not create a read-only sandbox.
- **OpenCode's `edit: deny` does not block Bash.**
- **CommandCode's `shell_command` stays enabled** for read-only agents (they need `rg` and `git`), so a shell write is the residual risk.

### The `powerShell` allow is broad

CommandCode's bare `"powershell"` allow grants the whole PowerShell tool with no argument constraint, so it can carry a denied operation past the deny rules. It is load-bearing (adb, `$`-heavy commands, file edits), so it was left alone. Tighten it only after deciding which PowerShell verbs must stay reachable.

### BlindPilot and `work` do not compose

`work`/`agent-task` is a **terminal launcher that starts another CLI**. Inside a BlindPilot turn that nests CLIs, and a nested turn can outlive BlindPilot's one-shot process. The result is the misleading message:

> "Command Code stopped before the turn completed (exit code 1)."

That string is BlindPilot's, not the model's. **Never run `work`/`agent-task` or a dev server inside a BlindPilot turn.** Run them from a normal PowerShell window. BlindPilot and `work` are two entry points that replace each other.

### Clis can exit 0 after a failed write

Both CLIs can exit successfully after reporting that an attempted write failed. **Always verify the requested result and the Git diff** — do not trust the exit code alone.

### Command Code credits are not readable headlessly

The docs say the plan cannot be read from disk and `/usage` is interactive-only. Read the live number with `/usage` in a session, or at https://commandcode.ai/usage.

### RTK is an executable proxy, not a shell wrapper

`rtk git status` is safe. `rtk echo hi` is **not** — builtins are not on PATH, so RTK fails with `program not found`. It is also unsafe when a later step parses the output, because condensed text can be misread by a pipe or regex. Use `rtk proxy <cmd>` to run one command unfiltered.

---

## 30. Drift found and fixed

Three issues were found while writing this guide. All three were fixed on 2026-10-19, and a fourth was found and fixed on 2026-10-20. They are recorded here so you know what changed and why.

### 30.1 `AGENTS.md.bak-*` files accumulated faster than they were pruned — FIXED

**Was:** 39 `AGENTS.md.bak-*` files in `~/.config/opencode/` and 39 in `~/.commandcode/`, growing by **two per nightly run**.

1. `sync-taste.ps1` calls `sync-agent-instructions.ps1` internally, which backed up both targets.
2. The standalone `sync-agent-instructions` step (step 3) ran the same script again, backing them up **again**.

The cause was that the backup `Copy-Item` ran **before** the "already in sync" check, so a run where nothing changed still produced two backup copies per target. Nothing pruned them — `Prune-Backups` in `self-repair.ps1` only prunes `self-repair-backups/`.

**Now:** `sync-agent-instructions.ps1` backs up **only when the content actually changes**, and prunes each target directory to the **5 latest** backups, after confirming those 5 are non-empty. Both directories now hold exactly 5.

### 30.2 `taste-promote` wrote malformed bullets — FIXED

**Was:** the script prefixed extracted bullets with `- `, but the extracted bullet already started with `- `. Result: `- - Do not treat automated tests...`.

**Now:** the bullet is written as-is, so the file reads `- Do not treat automated tests...`. Cosmetic either way — the file is a proposal list, not consumed programmatically — but it no longer breaks Markdown list syntax.

### 30.3 `sync-taste` and `sync-agent-instructions` overlap — LEFT AS IS

Step 1 already propagates the canonical file; step 3 repeats it. Harmless (idempotent), and it costs one extra script run per night. It was also the direct cause of 30.1, which is now fixed, so the overlap no longer has a cost beyond one script invocation. Leaving it also gives step 3 a second chance to propagate a canonical file that step 1 wrote. The order stays fixed in `self-repair.ps1`.

### 30.4 `agent-backend-health.json` and `agent-usage.json` are both empty

`{}` means **no flags set** — all backends healthy, no cooldown active. That is the healthy steady state, not a missing file.

### 30.5 The memory notes directory contained a duplicate batch — FIXED

**Was:** 135 note files for only **71 rollout summaries**. The `.processed` index held two key formats:

| Key format | Count |
|---|---|
| `filename:MD5` (v1) | 65 |
| `filename:MD5:v2` (current) | 70 |

The `v2` suffix existed because the key format had been changed once. Changing it meant every already-processed summary stopped matching its index entry and **was curated a second time**, producing a second batch of notes with the same slugs.

**Now:** `memory-curate.ps1` honours the legacy key as well as the current one, so bumping the key format again can never re-curate a summary. The 65 orphaned v1-era notes were removed — every one had an exact-slug v2 twin, contained **zero** extracted learnings ("No structured learnings found"), and was cited **zero** times in `MEMORY.md`. The notes directory now holds 70 files, one per curated summary.

**Why it was never a memory-quality problem:** `memory-consolidate.ps1` dedupes against `MEMORY.md` by normalized key before appending, so the duplicate notes never produced duplicated learnings. The cost was disk and clutter, not wrong memory.

### 30.6 The chain stopped at the first credit wall and reported success — FIXED

**Was (2026-10-20):** two `work` runs failed in a row — Codex ran out of subscription credits, the router fell back to Command Code, and Command Code answered `Insufficient credits for Command Code.` **with exit code 0**. The router read exit 0 as success: it cleared the backend's health flag, recorded a success in the route feedback, never marked the paid credits exhausted, never tried a free model, never tried the third backend, and printed `Done via fallback (Command Code)` for a task that never ran.

**Now:** `Test-CreditFailure` turns a provider credit/limit error into a failure whatever the exit code says (§10), and the chain now walks **every** remaining backend, retrying each on a free model before moving on (§12). The failing backend is marked unhealthy and paid-exhausted, so the next run starts on a free model. Codex's `try again at 5:11 AM` is parsed and the backend is held until then.

---

# Part 10 — Reference

## 31. Exit codes

| Script | 0 | 2 | 1 |
|---|---|---|---|
| `self-repair.ps1` | all steps passed | — | a step failed or rolled back |
| `verify.ps1` | all smoke checks passed | — | a smoke check failed |
| `sync-taste.ps1 -Check` | in sync | drift found | — |
| `sync-agents.ps1 -Check` | in sync | drift or stale files found | — |
| `sync-agent-instructions.ps1 -Check` | in sync | drift found | canonical missing |
| `sync-skills.ps1 -Check` | in sync | pending changes | — |
| `release-gate.ps1` | all checks passed | — | a check failed |
| `guard-hook.ps1 -SelfTest` | 5/5 pass | — | a self-test assertion failed |

**The `2` convention is consistent**: `-Check` means "report, don't change," and exit `2` means "there is work pending." Any CI wrapper can use that.

---

## 32. Glossary

| Term | Meaning |
|---|---|
| **Backend** | One of the three CLIs: `codex`, `commandcode`, `opencode` |
| **Tier** | The difficulty classification of a task: `quick`, `standard`, `deep` |
| **Route** | The full decision — backend + model + effort + mode |
| **Roster** | The four named agents: scout, builder, verifier, debugger |
| **Canonical** | The one file that is edited by hand; everything else is generated from it |
| **Render** | To generate a native-format copy from the canonical file |
| **Drift** | Two copies of the same thing that no longer match |
| **Snapshot** | A hash-verified copy of a file/dir taken before a step runs |
| **Rollback** | Restoring a snapshot after a step fails |
| **Manifest** | The list of what a snapshot contains, plus its own integrity hash |
| **Infra failure** | A failure caused by the environment (rate limit, auth, network), not by the task |
| **Demotion** | Temporarily skipping a model that has failed with infra errors |
| **Cooldown** | A window during which a backend's paid models are withheld |
| **Tier outcome** | A recorded attempt at a given tier, with its exit code |
| **Taste** | Preferences learned by Command Code from how you work |
| **Rollout summary** | The raw record of one Codex session |
| **Note** | A structured, one-per-rollout extraction of the learnings |
| **Inner loop** | The fast check you run after each edit |
| **Gate** | The full check you run before done, and in CI |
| **Worktree** | An isolated checkout of a repo on its own branch |
| **Best-of-N** | N parallel attempts of one task, each in its own worktree |
| **CLI permission boundary** | A rule enforced by the CLI's tool permissions, not by the OS |

---

## The five things to remember

1. **Edit the canonical file, never a copy.** Then run the sync script.
2. **The nightly job at 03:00 keeps the configuration from rotting.** It snapshots, hashes, and rolls back automatically.
3. **At run time, the router reroutes instead of failing.** Paid → free on the same backend → another backend.
4. **`-Preview` shows the route without spending anything.** Use it before any expensive task.
5. **The approval policy is behavior, not a control.** Say out loud when you assumed an approval.

---

*Documented against the live configuration on 2026-10-19. The nightly job last passed fully at 2026-10-19 03:01:21 (`verify OK`, exit 0), with `LastTaskResult: 0` and `NextRunTime: 2026-10-20 03:00`.*

*If this document and the configuration ever disagree, **the configuration wins** — but then fix this document in the same change.*
