# Workflow configuration

## Same-task continuation
- `continuation.max_turns` caps a separate `tools/auto-next.py` CLI run (currently 5 turns).
- Launch with one explicit task and backend; it resumes that task's returned session ID only when the final reply ends `AUTO_NEXT_STATUS: CONTINUE`.
- `DONE`, `BLOCKED`, missing status/session, CLI failure, or the turn cap stops the run. It never selects another ticket. Backend permissions and model selection stay with that CLI.

## Working style
- Make the smallest change that completes the request; keep unrelated work out of scope.

## Dependencies
- Handle dependency warnings on sight. When a deprecation, outdated, audit, or lockfile warning appears during work, fix it, even outside the named component, and report the file and reason.

## Agents
- Static roster: scout (read-only research/locate), builder (sole writer), verifier (read-only review + checks), debugger (root-cause a failure, then smallest fix).
- The main agent dispatches and selects by the task's complexity and hardness (the tier heuristic: quick / standard / deep), then the cheapest eligible model for that tier.
- An agent may call on another agent or CLI when the work genuinely requires it — a read-only agent needing a writer, a writer needing independent verification, or a backend at its usage limit or lacking a capability handing the task to Codex, CommandCode, or OpenCode, and vice versa. A hand-off stays in scope, states its reason, and never recurses past what the task needs.
- The chain runs autonomously up to a commit and then stops.
- Source of truth: `workflows/agents.toml`. Render with `tools/sync-agents.ps1` to Codex (`~/.codex/agents/`), OpenCode (`~/.config/opencode/agents/`), and CommandCode (`~/.commandcode/agents/`). CommandCode also reads the roster section of the global `AGENTS.md`.

## Models
- Paid normally, per task tier (`tools/agent-route.ps1`). The `quick` tier may take a free model on price.
- When no paid model is available (usage window, plan restriction, auth), select a free model instead of failing: paid -> free on the same backend -> another backend.
- Free list: `tools/free-models.json`, regenerated with `tools/refresh-free-models.ps1`.
