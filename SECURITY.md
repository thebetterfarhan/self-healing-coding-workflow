# Security policy

## What this kit touches

The workflow installs things on your machine. It is worth being explicit about
what, so you can decide what to allow:

| It writes to | What it puts there |
| --- | --- |
| `~/.codex/AGENTS.md` | The global policy. The same bytes are copied to `~/.config/opencode/AGENTS.md` and `~/.commandcode/AGENTS.md`. |
| `~/.codex/config.toml` | Nothing by default. The packer and the leak guard read it. |
| `~/.codex/hooks.json` | A `PreToolUse` hook that runs `tools/guard-hook.ps1`. |
| `~/.codex/agents/`, `~/.config/opencode/agents/`, `~/.commandcode/agents/` | One file per roster agent, rendered from `workflows/agents.toml`. |
| `~/.agents/skills/` | The canonical skill set, when the bundle ships it. The public release does not. |
| Your PowerShell profile | One loader line that sources `tools/profile.ps1`. |
| A scheduled task | `CodexWorkflowSelfHeal`, at 03:00, unless you pass `-SkipTask`. |
| A git repository | `~/Documents/Codex/.git` - the configuration repository, holding the configuration only. It has no remote. |

Every script that writes any of these has a `-Check` mode that reports what it
would do and writes nothing.

## What the guard hook blocks

`tools/guard-hook.ps1` runs before every patch. It denies a patch that

- touches a file matching a protected pattern - `*.keystore`, `*.jks`,
  `keystore.properties`, `local.properties`, `*.pem`, `*.key`, `.env*`; or
- adds a line that looks like key material - a private key header, an AWS key
  id, a GitHub token or PAT, an Anthropic key, a Slack token, a Google API key.

It is silent unless it denies something. It has a self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/guard-hook.ps1 -SelfTest
```

## What the packer refuses to ship

`tools/package.ps1` refuses to build a bundle that contains a private key, a
token, a machine path, a generated taste block, or anything matching your
personal leak patterns in `tools/leak-patterns.local.json` (git-ignored, never
packaged). It removes the staging folder and exits non-zero.

## Reporting a problem

Open a GitHub issue on this repository. If the problem is a vulnerability that
would let the kit execute something it should not - a guard that can be
bypassed, a hook that runs an untrusted command, a packer that can be made to
ship a secret - say so in the issue title and describe the steps to reproduce
it. There is no private disclosure channel configured; if that matters to you,
open a public issue without a working exploit and ask for a way to continue
privately.

## What is deliberately not protected

- The kit is not sandboxed. It runs with your privileges, in your shell, on
  your machine. Read `tools/setup.ps1 -Check` before you install it.
- The trust checks are checks, not proofs. A secret that does not look like a
  secret will ship.
- The `work` router sends your request text to whichever backend it picks.
  That is the point, but it means your request leaves the machine.
