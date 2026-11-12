# Container-only native tools experiment

## Goal

Let a native CLI agent define its repository's toolchain in a Dockerfile under the fx profile, then execute repository work only in a local container with the repository bind-mounted. This document records decisions as implementation proceeds. It describes an experiment, not released behavior.

## Decisions

1. **Use an execution boundary, not prompt compliance.** Enabling the experiment removes the ordinary native tool set and routes authorized execution through a container runtime before native file mutations or command dispatch can run. `full-access` does not disable isolation.
2. **Start with a restricted vertical slice.** The experiment offers `container_setup` and a foreground-only `shell`. Repository reads, searches, and edits happen through the container shell. TTY, background handles, MCP, subagents, web tools, skill installation, and arbitrary host tools are unavailable. Their existing host implementations are not reused. A typed tool worker can restore those tools later.
3. **Bootstrap has no general host tools.** Before successful setup, shell calls fail. The model submits Dockerfile text through a fixed-purpose tool; fx chooses the profile path, build context, Docker invocation, and mount policy. Repository information must come from bounded host-supplied context rather than agent-directed host execution.
4. **Store definitions outside the repository.** Use `profile_paths` under `~/.fx/containers/`, respecting `FX_HOME`. Never mount the profile, home directory, credentials, Docker socket, or host shell environment into the container.
5. **Keep permissions separate.** Permission admission remains required. Isolation does not grant authority and permission approval does not authorize host fallback. Bootstrap and execution need an execution-domain check independent of the permission mode.
6. **Target the native CLI explicitly.** Native libfx and WASM must return unsupported rather than accidentally enabling Docker through an operating-system-only check.
7. **Fail closed.** Missing Docker, build failures, startup failures, stale container identity, unknown tool names, and unsupported tool forms must not invoke ordinary host tools.
8. **Use a profile-only experiment.** Setting: `experimental.container_tools`, off by default. No dedicated flag, environment variable, or project-safe setting. The experiment is fixed for a running tool domain; changing settings cannot silently widen the domain.
9. **Use a local daemon with host-controlled arguments.** The agent cannot choose the daemon endpoint, build flags, mounts, user, entrypoint, capabilities, or network policy. The build context contains only the definition, not the repository or profile. Build-time network access is needed to install toolchains; runtime networking starts disabled.
10. **A writable bind mount is intentional authority over repository files.** This does not protect the repository from deletion or malicious modifications. Linked worktrees, external Git directories, and additional workspace mounts require explicit support rather than implicit host access. Docker isolation is not a guarantee against kernel or daemon vulnerabilities.

## Implementation map

- `src/core/sandbox/`: lifecycle, definition storage, Docker control, and container execution.
- `src/builtins/container_tools.zig`: restricted model-facing tool specifications.
- `src/core/tooling/`: authoritative container-domain routing before native mutation, host-tool, or ordinary dispatch.
- Native application composition: runtime lifetime, tool-set selection, and bootstrap context.
- Configuration and CLI configuration surfaces: profile-only experiment.

## Verification plan

Run focused Zig tests for lifecycle, argument validation, domain routing, and configuration. Build the native binary, then drive a real interaction using the built binary: submit a Dockerfile, write a file through the mounted repository, run a command, and prove an unmounted host sentinel is inaccessible. Check that unsupported tools and Docker failure never fall back to host execution. Run SDK checks appropriate to any shared host-contract change. Classify any new root E2E owner in the PGSO corpus and shard weights.

## Environment and current evidence

- Initial checkout: `e812bc3e`; implementation uses a dedicated feature worktree.
- Zig reports `0.17.0`.
- Docker and Bun were initially absent. The user authorized installing both; installation and daemon availability are being checked.
- Source inspection confirmed separate native mutation, direct-command, captured-shell, TTY, host-tool, and MCP bridge paths. Wrapping only shell spawning is insufficient.

## Try the experiment

Build with `zig build`. Enable the experiment for subsequent native interactive launches through the profile:

```sh
./zig-out/bin/fx config set experimental.container_tools true
./zig-out/bin/fx
```

For one noninteractive request, use the existing configuration override:

```sh
./zig-out/bin/fx ask --config experimental.container_tools=true "Inspect this repository and run its focused tests"
```

Normal permission policy still applies. This experiment does not require `full-access`. To disable it for a subsequent launch, run `./zig-out/bin/fx config unset experimental.container_tools`. Changing the profile does not widen a running container domain.

Docker must be installed with a local daemon available at `unix:///var/run/docker.sock`. The repository must have an ordinary `.git` directory. Linked worktrees are refused in this slice. The image must provide `/bin/sh`, `sleep`, and `id`; add the repository's toolchain in its Dockerfile. Build context contains only that Dockerfile. The image's entrypoint and user are overridden.

The repository owner must permit the container's numeric user to write the repository. Normal launches use the host UID/GID. A root launch uses UID/GID 65534 rather than running the container as root. Setup fails with a diagnostic if that user cannot write `/workspace`; fx never changes repository permissions to make setup pass.

Definitions are stored at `~/.fx/containers/<workspace-hash>/<run-token>/context/Dockerfile`, or beneath `FX_HOME` when set. Containers and images are session-local and removed on normal teardown. Definitions remain available for inspection. A new process, including a resumed conversation, must bootstrap again; it does not adopt an old container. Parallel conversations in one interactive process share that process's serialized container domain in this first slice.

## Additional decisions from implementation and review

11. **Keep the tool schema stable across bootstrap.** Both tool names are advertised, but shell execution is unavailable until setup and its smoke check succeed. This avoids relying on model-side schema refresh for enforcement. A running definition is immutable; a failed definition can be revised.
12. **Use one argument contract.** Tool decoding and execution validate the same bounded request shape. Setup accepts only Dockerfile text; shell accepts only `action=run` and command text. Extra mount, path, TTY, environment, and daemon controls are rejected.
13. **Bypass host shell planning, not permissions.** The two tools use ordinary exact-argument permission admission rather than native shell admission. Native shell environment capture, direct-command planning, and the MCP shell bridge are not used.
14. **Suppress ordinary model context in both harnesses.** Interactive static/transient context callbacks and project-context refresh are guarded independently of the mutable context preference. The ask harness also skips its static/transient context and optional startup integrations. The bounded bootstrap prompt reads fixed root manifest prefixes without following manifest symlinks.
15. **Bound and sanitize results.** Docker process output is bounded; the runtime uses fx's existing model-output sanitizer and configured result cap before handing output to the model.
16. **Keep unsupported surfaces explicit.** ACP rejects the experiment at initialization. SDK and WASM runtime implementations report unsupported and never invoke Docker. Native interactive fx and `fx ask` are the supported experiment owners.
17. **Classify deterministic isolation as verification-only.** `tests/e2e/container-tools.test.ts` is in the PGSO verification corpus and CI shard weights. Real Docker execution is opt-in with the test-only `FX_TEST_CONTAINER_DOCKER=1`; PGSO clears that variable because daemon availability and base-image pulls are not deterministic training inputs.

18. **Exclude nested host mounts.** Repository binds use `bind-recursive=disabled`. Docker versions that cannot enforce that option fail setup rather than broadening the mount.
19. **Cancel the operation and its container work.** Tool cancellation reaches the Docker runner, which cancels and joins the client process task before cleanup. Absolute deadlines also cover clients that close their output pipes and then hang. Cleanup ignores the canceled operation token so it can remove the container.
20. **Retain cleanup evidence.** Each run keeps a private, atomically replaced `recovery.json` with the endpoint, canonical workspace, container name/ID, image tag/ID, and lifecycle status. Failed removal records `cleanup_failed`, reports the recovery path, and prevents the same runtime from silently replacing its outstanding resources. This is a recovery record for inspection, not automatic adoption on resume.
21. **Use immutable container identity and owned image tags.** Start, exec, and removal target the captured container ID. Image cleanup verifies that the unique per-run tag still resolves to the captured image ID, then removes only that tag. It does not force-delete an image another session may share.

## Verification record

All runtime checks use this worktree's `zig-out/bin/fx`, never an installed fx. Bun commands run from `tests/e2e/`; the SDK and Zig commands run from the repository root. Tests that create profile fixtures use `umask 022`.

| Command | Result | Evidence |
| --- | --- | --- |
| `(umask 022; zig build test-container-tools --summary all)` | Pass, exit 0 | Native build succeeded; 61 of 61 focused tests passed. Injected cleanup-failure cases intentionally emit recovery warnings. |
| `FX_SOUND=0 FX_E2E_DISABLE_DOTENV=1 FX_TEST_CONTAINER_DOCKER=1 bun test container-tools.test.ts` | Pass, exit 0 | Four tests and 220 assertions: headless fences, interactive startup/context fences, real Docker setup and mounted writes, and cancellation cleanup. |
| `FX_SOUND=0 FX_E2E_DISABLE_DOTENV=1 bun test cli.test.ts --test-name-pattern config` | Pass, exit 0 | Five configuration tests passed; 153 unrelated tests were filtered out. |
| `FX_SOUND=0 FX_E2E_DISABLE_DOTENV=1 bun test ci-shards.test.ts` | Pass, exit 0 | Eleven shard/platform-manifest tests passed. |
| `python3 -m unittest scripts.pgso.tests.test_corpus` | Pass, exit 0 | All 35 corpus tests passed. |
| `python3 -m scripts.check_cli_shape` | Pass, exit 0 | New experiment and tool surfaces conform to the registry checks. |
| `zig fmt --check build.zig src/` and `git diff --check` | Pass, exit 0 | Formatting and whitespace checks passed. |
| `scripts/check-public-surface.sh` and the agents, compactor, indexer, and recovery boundary scripts | Pass, exit 0 | Each check passed. |
| `zig build -Dwasm-surface=core -Dnapi-surface=core --prefix /tmp/fx-container-sdk-check` | Pass, exit 0 | SDK core and native addon compiled with the unsupported container implementation. |
| `zig build -Dwasm-surface=term --prefix /tmp/fx-container-sdk-check` | Pass, exit 0 | WebAssembly terminal compiled. |

The real Docker test observes a nonzero container UID, `/workspace`, a file written through the repository mount, an inaccessible unmounted host sentinel, and private definition/config directories. Normal headless and interactive processes exit without aborting or unexpected stderr diagnostics. The deliberate SIGINT case exits 130 in under 10 seconds, removes the exact container ID, and leaves its recovery status `cleaned`.

During development, a CLI fixture needed to finish its prompt rather than assert preview text as final output. Existing profile tests also exposed this runner's `umask 0007`; rerunning under `umask 022` passed without weakening private-state permissions. Output tests now separately cover valid-text truncation and invalid-UTF-8 omission. A Docker mock asserts external argument layout rather than treating Docker flags as fx options.

The built binary's configuration set/get also passed in an isolated `HOME` and `FX_HOME`, with effective JSON value `true`. Exact-commit CI, macOS runtime verification, and the final ship gate remain outstanding. These local checks do not establish merge readiness.

## Open limitations

- The first slice deliberately does not preserve the full native tool surface.
- Toolchain completeness cannot be inferred perfectly from repository metadata. Build and smoke-check failures require a Dockerfile revision.
- Runtime networking is disabled. Dependency installation belongs in the Dockerfile for this slice.
- A writable repository exposes its committed and uncommitted files to the container, including repository-local secrets. This is not an exfiltration guarantee for secrets already inside the mount. Filesystem IPC endpoints already inside the repository are also part of that capability: do not use this experiment with host service sockets or device files beneath the repository. This slice does not filter every repository entry or claim to be a hardened hostile-code sandbox.
- Docker is a local container boundary, not a separate kernel security boundary on Linux. The daemon and image supply chain remain trusted dependencies.
- A process killed without teardown or an unavailable daemon can leave a container running. Inspect the private recovery record and the `dev.fx.container-tools=true` Docker ownership label; cleanup is not guaranteed after a crash. No startup sweep deletes containers from other sessions.
- Container-only execution is fixed for the interactive process. Its parallel conversations share a serialized runtime rather than receiving separate containers in this first slice.
