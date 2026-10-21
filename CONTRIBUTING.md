# Contributing

## What this repository is

The kit. One configuration for Codex, OpenCode and Command Code: the global
policy, the agent roster, the model router, the nightly repair, and the
documentation.

The workspace it is developed in is a separate, private repository - the
*configuration repository* - because the machine state and the project
repositories do not belong in a public tree. This repository is what other
people download.

## The shape of a change

1. Change the source of truth, not the output. `workflows/agents.toml` holds
   the roster and the model table. `tools/README.template.md` holds the README.
   `workflow/AGENTS.template.md` is a frozen copy of the global policy.
2. Run the renderers. `tools/sync-agents.ps1` writes the roster into all three
   CLIs. `tools/setup.ps1 -RefreshTemplate` refreshes the policy template.
   `tools/package.ps1` builds the bundle.
3. Run the gate. `tools/verify.ps1` exits 0 when everything is consistent.
4. Commit the output too. The rendered agent files and the generated HTML are
   tracked, so a change that forgets to re-render is visible in the diff.

## Before you push

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1
```

That runs the continuation-runner tests, the documentation checks, the roster
sync checks, the instruction sync checks and the configuration-repository
check. It writes nothing to your CLIs.

The same three checks run on every push, on Windows, in CI.

## Style

- Plain PowerShell 5.1, no modules, no dependencies to install.
- Every script opens with a comment block saying what it does, what it writes
  and how to check it without writing.
- Every script that writes has a `-Check` mode.
- English prose in the documents. Say what happens, not what the code looks
  like.
- Never commit a secret, a machine path, a generated taste block, or a
  personal address. The packer refuses to ship all four; the CI does not check
  them, so run the packer before a release.

## Releasing

Not from this repository. A release is built by `tools/package.ps1`, verified
by unzipping it and running `tools/setup.ps1 -Check` inside, and published with
a `SHA256SUMS.txt` beside the zip.

## Reporting a problem

Open an issue. If it is a security problem, read [SECURITY.md](SECURITY.md)
first.
