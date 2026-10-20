<!--
  BASELINE TASTE - a starting point, not your taste.

  This file is seeded on install so the preference layer is never empty and
  never silent. Every entry below is a safe default that a new user is
  likely to want but has not yet stated. Replace the ones you disagree with,
  delete the ones that do not apply, and add your own as you work.

  The layer is per-user and lives at ~/.commandcode/taste/taste.md. It is
  rendered into every agent's AGENTS.md by tools/sync-taste.ps1, so a
  preference written here applies to Codex, OpenCode and Command Code alike.

  Format: one bullet per line, ending with a confidence value between 0 and 1.
  Low confidence means "assumed, correct me when wrong". High confidence means
  "I told the agent this repeatedly".
-->

# Taste

## Workflow

- Prefers the agent to try a change before explaining how it would work. Confidence: 0.5
- Prefers to be told which files were changed before being asked to review the result. Confidence: 0.5
- Prefers small, single-purpose changes that can be reviewed one at a time. Confidence: 0.5
- Prefers the agent to read the whole relevant file before editing it, not only the matching lines. Confidence: 0.5
- Prefers to be offered a concrete next step rather than being left to ask what to do next. Confidence: 0.5
- Prefers repeated, clear workflow preferences to be recorded in this file so they apply to every agent automatically. Confidence: 0.5

## Communication

- Prefers plain-language explanations of what changed, not a list of file names. Confidence: 0.5
- Prefers moderate detail: enough to act on, not a transcript of the work. Confidence: 0.5
- Prefers to be asked one question when a decision would change the outcome, rather than a menu of options. Confidence: 0.5
- Prefers to be told when a tool, model, or service was unavailable and what was used instead. Confidence: 0.5
- Prefers technical terms to be used as-is rather than explained every time. Confidence: 0.5
- Prefers progress updates only when a step takes unusually long, not after every step. Confidence: 0.5
- Prefers the remaining risk to be stated plainly rather than left to be inferred. Confidence: 0.5
