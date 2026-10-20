# Dev setup — machine-wide developer environment

How this Windows box's general dev environment is wired, and how to rebuild it.
For the coding-CLI (Codex/OpenCode/CommandCode) wiring see `AGENT-SETUP.md`.

## One entry point

```powershell
~/Documents/Codex/tools/dev-setup.ps1          # apply (idempotent)
~/Documents/Codex/tools/dev-setup.ps1 -Check   # report drift only, exit 2 if any
~/Documents/Codex/tools/dev-setup.ps1 -SkipTools
```

It applies the global git config + aliases, writes the global gitignore, wires
the PowerShell profile, installs the CLI tools via winget, and points git at
delta. Re-running is safe; unchanged items report `ok`.

## Files

| What | Where | Notes |
| --- | --- | --- |
| Canonical PowerShell profile | `~/Documents/Codex/tools/profile.ps1` | **Edit this one.** |
| `$PROFILE` loader | `~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1` (the exact path depends on where your Documents folder is redirected) | Two lines; sources the canonical file. |
| Global gitignore | `~/.gitignore_global` | `core.excludesfile` points here. |
| Setup script | `~/Documents/Codex/tools/dev-setup.ps1` | Rebuild/verify entry point. |

There is exactly one copy of profile logic — the loader exists so `$PROFILE`
stays in its expected location without duplicating config.

## Global git config (the opinionated bits)

- `pull.ff = only`, `pull.rebase = false` — no surprise merge commits from `pull`.
- `push.autoSetupRemote = true` — first `push` sets upstream; no `-u` needed.
- `rebase.autosquash` + `rebase.autostash` — `git rebase -i` reorders fixups and stashes dirty work.
- `rerere.enabled` — records conflict resolutions and replays them.
- `merge.conflictStyle = zdiff3`, `diff.algorithm = histogram`, `diff.colorMoved = zebra`.
- `core.longpaths = true` — avoids Windows MAX_PATH failures.
- Delta as pager: `core.pager`, `interactive.diffFilter`, `delta.*`.

Aliases: `st co cob br ci cm ca unstage undo last lg aliases wip who`
(see them with `git aliases`).

## CLI tools

| Tool | Purpose | Install id |
| --- | --- | --- |
| ripgrep `rg` | fast code search (aliased as `grep`) | `BurntSushi.ripgrep.MSVC` |
| fd | fast file find | `sharkdp.fd` |
| bat | `cat` with syntax highlighting | `sharkdp.bat` |
| fzf | fuzzy finder | `junegunn.fzf` |
| zoxide | frecency `cd` (`z`, then `z name`) | `ajeetdsouza.zoxide` |
| delta | readable git diffs (wired as pager) | `dandavison.delta` |
| just | command runner (Makefile alternative) | `Casey.Just` |

Install via winget; a **new shell** is required for PATH to apply.

## Profile behaviour

- Up/Down arrows: history **search**; Tab: menu completion.
- `mkcd`, `touch`, `which`, `reload`, `..`, `...`, `cd..`.
- `grep` → ripgrep; zoxide initialised if present; UTF-8 console output.
- Git-aware prompt showing the current branch (disable: `$GitPromptEnabled = $false`).
- Predictive IntelliSense silently turns on **if** PSReadLine ≥ 2.1 (this box
  ships 2.0 with Windows PowerShell 5.1, so it stays off until PSReadLine is
  upgraded — see below).

## Optional: PSReadLine 2.3 (predictive history)

Windows PowerShell 5.1 ships PSReadLine 2.0. Upgrading unlocks inline history
predictions the profile already tries to enable:

```powershell
Install-Module PSReadLine -Force -Scope CurrentUser -SkipPublisherCheck
```

Not done by `dev-setup.ps1` because it pulls from PSGallery (a network
dependency). Run it manually if you want predictions.

## Approval

Tools were installed and global config changed on request; `dev-setup.ps1`
was run with approval assumed (the runtime does not gate this — see
`AGENT-SETUP.md`). A backup of the pre-change git config is at
`~/.gitconfig.bak-<timestamp>`.
