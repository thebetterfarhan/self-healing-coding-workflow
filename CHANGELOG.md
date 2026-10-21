# Changelog

The public releases of **self-healing-coding-workflow**. `vX.Y.Z` is the tag,
the release and the asset name.

## v0.1.12

- The documentation is published as a GitHub Pages site:
  **https://thebetterfarhan.github.io/self-healing-coding-workflow/** - the
  screen-reader build, readable in a browser and not only inside the
  downloaded bundle. A workflow deploys it on every push to main.
- The bundle's index no longer links to pages the bundle does not ship. The
  packer was copying the repository's committed HTML over the freshly
  rendered public subset, which put back the workspace instructions, the
  tools handover and the dated audits in the index - four dead links, and the
  names of the machine-specific documents in public view.

## v0.1.11

- Three workflows, so the repository proves itself instead of asking to be
  believed. A release is built from a tag, checked and published with its
  checksum. A drift check fails when a tracked file carries something private
  or when the generated documentation no longer matches its sources. An
  install check builds the bundle, installs it into an empty profile and
  asserts the policy landed in all three CLIs byte-identically.
- The leak scanner is `tools/leak-scan.ps1` now, shared by the packer and the
  workflow, so the bundle and the repository are checked by the same code.
- Five bugs the new checks found, all fixed:
  - the packer's leak scan ran before the README was written, so the README
    was never scanned;
  - `sync-skills.ps1` threw when there was no canonical skill set, which made
    the whole install fail on a clean machine - the public kit could not be
    installed at all;
  - the price catalog refresh threw when the Command Code CLI was not
    installed, with the same result;
  - a machine with no git identity could not create the configuration
    repository, so the install died there too;
  - `verify.ps1` asserted that the whole machine was healthy, so it failed on
    exactly the clean machine the install check creates.
- The README template now ships in the bundle, so the unpacked kit can
  repackage itself.
- v0.1.10 was withdrawn. It carried the install failure above, and it cannot
  be fixed in place, so it was removed rather than left for someone to
  download.

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
