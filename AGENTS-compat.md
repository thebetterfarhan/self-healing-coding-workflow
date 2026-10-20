# AGENTS-compat.md

Appendix to `AGENTS.md`: the full risk-review checklist and the legacy, compatibility, and dependency procedure. Read it before compatibility work or a broad review. Every restriction in `AGENTS.md` still applies.

## Risk-triggered review checklist

Add only the reviews the change actually triggers — normal work does not require every check.

- **UI, navigation, focus, input:** interaction, accessibility, regression behavior.
- **Accessibility:** authoritative research, semantics, focus/navigation, announcements, real assistive-technology behavior.
- **API, networking:** contracts, callers, errors, cancellation, timeouts, integration, external assumptions, security.
- **State, persistence, database:** ownership, restoration, partial failure, migrations, compatibility, user data, privacy, security.
- **Async, threading, concurrency:** ownership, cancellation, races, deadlocks, stale results, lifecycle, responsiveness.
- **Resource management:** allocation, lifetime, cleanup, leaks, unbounded growth, background activity.
- **Performance:** measurements, user-visible latency, CPU, memory, I/O, blocking, accessibility responsiveness.
- **Dependencies:** necessity, provenance, supply-chain risk, compatibility, licensing, build impact.
- **Build configuration:** environment, toolchain, reproducibility, variants, packaging, release implications.
- **Security-sensitive behavior:** authentication, authorization, secrets, permissions, storage, network boundaries, logging, user data.
- **Release work:** release build, tests, static analysis, packaging, signing, versioning, permissions, dependencies, accessibility, security/privacy, exposure, documentation.

## Legacy / compatibility failure

Trigger when an old project will not build or run, dependencies no longer resolve, SDK or toolchain versions conflict, APIs were removed or deprecated, native binaries are incompatible, or upgrading one component breaks another. Desired order:

REPRODUCE CURRENT FAILURE -> IDENTIFY COMPATIBILITY BOUNDARY -> RESTORE OR ESTABLISH BASELINE -> MINIMUM NECESSARY CHANGE -> BUILD AND TEST -> MODERNIZE FURTHER ONLY WHEN NEEDED

## Compatibility baseline

Do not assume an old project should be upgraded immediately. Before changing dependencies, SDKs, compilers, runtimes, build tools, package managers, or language versions, establish the compatibility baseline: language, runtime, and compiler versions; SDK, platform, build-tool, and package-manager versions; direct and transitive dependencies and lockfiles; target OS and API levels; CPU architectures and ABIs; deprecated or removed APIs; generated code and tooling; native libraries; external services or APIs; known project constraints; the last known working environment.

Distinguish a source-code defect from environment or toolchain problems, dependency incompatibility, platform or API incompatibility, abandoned dependencies, native binary incompatibility, and machine-specific configuration. Do not modify application code merely to hide an environment failure.

## Compatibility-first procedure

When a project fails to build or run:

1. Inspect declared versions, lockfiles, project instructions, and known-good records.
2. Reproduce the failure before upgrading components when practical.
3. Identify the smallest incompatible component or version boundary.
4. Research current official compatibility, release, breaking-change, and migration documentation.
5. Prefer restoring a safe, reproducible compatible environment before changing source.
6. Upgrade only what is necessary.
7. Change one compatibility layer at a time when practical.
8. Update tightly coupled components as the minimum required compatible set.
9. Build and run targeted tests after each meaningful change.
10. Record durable compatibility decisions and remaining limits.

Do not broadly upgrade because newer versions exist — newer is not automatically more compatible. Do not assume semantic versioning guarantees compatibility. Do not downgrade a security-sensitive dependency to make a build pass without evaluating and reporting the risk.

## Repair versus modernization

Decide the objective first: build as-is, repair, modernize, port, or replace a dead dependency. Unless modernization is requested or unavoidable, restore the project with the smallest reasonable compatibility changes and preserve behavior. Do not change architecture, language version, build system, SDK, major dependencies, and persisted-data formats at once unless inseparable — broad simultaneous upgrades obscure the first failing boundary. Modernization is separate work, not a side effect of making something build; when needed, stage it: restore a baseline, remove blockers, update the toolchain, update dependencies in controlled groups, migrate removed APIs, validate behavior, run accessibility regressions, review security/privacy, update docs.

## Dependencies and old libraries

Before replacing a dependency, determine why it fails and how the project uses it: runtime, compiler, SDK, build tool, coordinates, transitive dependencies, architecture, native binaries, artifact availability, TLS or certificate changes, removed APIs, OS compatibility, abandonment. Inspect dependency trees and resolution output when useful. Prefer documented migration paths. Do not swap a library for a superficially similar one without checking API, behavior, data, accessibility, licensing, and security differences.

Classify version changes as patch, minor, major, toolchain, or platform; the last three need broader validation. Reason about versions as one compatibility set — LANGUAGE <-> COMPILER <-> RUNTIME <-> BUILD TOOL <-> SDK <-> FRAMEWORK <-> LIBRARIES <-> OS <-> ARCHITECTURE — and prefer a known-compatible set over the newest version of every component.

## Generated, vendored, and native code

Determine whether problematic code is project source, generated, vendored, third-party, or compiled output. Fix the generator rather than the generated output where appropriate; do not modify vendored dependencies unless that is intentionally safest. For native components, verify CPU architecture, ABI, compiler/runtime ABI, calling conventions, binary format, minimum OS or API level, page-size requirements, dynamic libraries, symbols, and packaging; never assume a binary working on one architecture or OS version works on another.

## Accessibility and security during compatibility work

When updating a UI framework, platform API, accessibility library, or input/navigation framework, research current official documentation for the target version and re-check semantics, accessibility APIs, screen-reader behavior, focus, keyboard, D-pad, announcements, and deprecated mechanisms. Do not carry an obsolete accessibility workaround forward when a supported mechanism exists.

Never solve compatibility by disabling certificate or signature verification, authentication, sandboxing, or security controls; weakening TLS; running everything elevated; using untrusted repositories; downloading random binaries; or exposing credentials. If old software requires an unsafe environment, report the conflict and investigate a safer migration path.

When reporting compatibility work, state what was incompatible and why, the expected environment, what changed, what now builds or runs, what remains unverified, and whether further modernization is recommended. Compilation alone does not prove the project is fixed.
