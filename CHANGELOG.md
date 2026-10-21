# Changelog

The public releases of **self-healing-coding-workflow**. `vX.Y.Z` is the tag,
the release and the asset name.

## v0.1.9

- The verification badge sits at the top of the README. It points at the
  workflow that runs on every push on Windows.

## v0.1.8

- The README shows what the thing looks like: a real `work -Preview` route and
  a real `workflow-status` screen, both captured from a live install.
- Every release ships a `SHA256SUMS.txt`, so the download can be verified
  against a hash.
- CI runs on every push, on Windows: the continuation-runner tests, the
  documentation structure and accessibility checks, and the roster rendering
  for all three CLIs.
- `SECURITY.md` says exactly what the kit writes to your machine, what the
  guard hook blocks, and what the packer refuses to ship.
- `CONTRIBUTING.md` describes the shape of a change and what to run before a
  push.

## v0.1.7

- The README was a file listing. It is now the front door: the problem, what
  the workflow does, a diagram of the routing and the nightly repair, a
  one-minute install, the piece-by-piece map and the model table.
- The README is a template now, `tools/README.template.md`, read by
  `package.ps1`. The here-string it replaced was mangling the inline code -
  the published file showed stray backslashes instead of code markers.

## v0.1.6

- Personal leak patterns moved out of the shipped script into
  `tools/leak-patterns.local.json`, which is git-ignored and never packaged.
  The guard reads them from there, so it still blocks your addresses - and the
  published bundle no longer carries one.

## v0.1.5

- `setup.ps1 -Check` warned "would run the smoke checks" in check mode, and a
  warning set the drift flag. The exit code was always 2, even on a healthy
  machine. It is a note now: the check ends with "All good." and exit 0 where
  the kit is installed.

## v0.1.4

- One authority for model selection. `workflows/agents.toml` holds the role
  pins for all three backends and the tier table the cross-CLI router reads,
  so the two cannot drift apart. CommandCode's agents get a model and a
  reasoning effort. The OpenCode agents get an effort and a step cap.

## v0.1.3

- The continuation runner, `tools/auto-next.py`: it keeps one explicit task
  going on one backend until it says it is done, and never picks up another
  task.
- `setup.ps1 -RefreshTemplate` and `package.ps1` share one policy template
  instead of two copies of the same block.

## v0.1.2

- The bundle refuses to ship a taste block, a credential or a machine path.
  The packer removes the staging folder and exits non-zero.

## v0.1.1

- The kit carries the current policy, and the documentation says how to change
  something.

## v0.1.0

- The first public release: the global policy, the agent roster, the model
  router, the nightly repair and the documentation.
