import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, realpathSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN,
} from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeGatewayToolCall,
  startFakeGateway, TmuxSession, tmuxAvailable,
} from "./tmux-helpers";

function fixture() {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-container-workspace-")));
  const profile = join(home, ".fx");
  mkdirSync(profile, { mode: 0o700 });
  // A real .git directory is required: linked worktrees expose outside paths.
  execFileSync("git", ["init", "--quiet", workspace]);
  // Root hosts execute as container uid 65534; the bind must be writable.
  chmodSync(workspace, 0o777);
  writeFileSync(join(profile, "settings.json"), "{}", { mode: 0o600 });
  return {
    home, profile, workspace,
    cleanup() {
      rmSync(workspace, { recursive: true, force: true });
      cleanupIsolatedTestHome(home);
    },
  };
}

function gatewayEnv(root: ReturnType<typeof fixture>, gateway: ReturnType<typeof startFakeGateway>) {
  // Deliberately do not inherit provider credentials or test overrides.
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: root.home, FX_HOME: root.profile,
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    AI_GATEWAY_API_KEY: "fake-container-test-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

async function ask(root: ReturnType<typeof fixture>, gateway: ReturnType<typeof startFakeGateway>, timeout = 20_000) {
  // Deliberately do not inherit provider credentials or test overrides.
  const proc = Bun.spawn([
    FX_BIN, "ask", "--json", "--quiet", "--config", "experimental.container_tools=true", "--full-access",
    "--model", FAKE_GATEWAY_MODEL, "Exercise the container tool boundary.",
  ], {
    cwd: root.workspace,
    env: gatewayEnv(root, gateway),
    stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill("SIGKILL"), timeout);
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
    ]);
    // Ask writes operational progress to stderr even in quiet JSON mode.
    // Reject every diagnostic except these expected warning/progress lines.
    const diagnostics = stderr.split("\n").filter((line) => line && ![
      "Full access enabled: fx permission checks disabled",
      "Running container command", "Building container toolchain",
      "Working: read_file", "Working: write_file", "Working: toolbox",
      "Working: mcp_fixture_write",
    ].includes(line));
    expect({ code, diagnostics }).toEqual({ code: 0, diagnostics: [] });
    expect(proc.signalCode).toBeNull();
    expect(stdout).not.toMatch(/panic|SIGABRT|Aborted|Segmentation fault/i);
    return stdout;
  } finally {
    clearTimeout(timer);
  }
}

function toolResult(body: string, id: string): string {
  const request = JSON.parse(body);
  const result = request.prompt.flatMap((message: any) =>
    Array.isArray(message.content) ? message.content : [],
  ).find((part: any) => part.type === "tool-result" && part.toolCallId === id);
  expect(result).toBeDefined();
  return JSON.stringify(result.output);
}

function assertSurface(body: string) {
  const request = JSON.parse(body);
  expect(request.tools.map((tool: any) => tool.name).sort()).toEqual(["container_setup", "shell"]);
  const setup = request.tools.find((tool: any) => tool.name === "container_setup").inputSchema;
  const shell = request.tools.find((tool: any) => tool.name === "shell").inputSchema;
  expect(Object.keys(setup.properties)).toEqual(["dockerfile"]);
  expect(setup.required).toEqual(["dockerfile"]);
  expect(setup.additionalProperties).toBe(false);
  expect(Object.keys(shell.properties).sort()).toEqual(["action", "command"]);
  expect(shell.required.sort()).toEqual(["action", "command"]);
  expect(shell.properties.action.enum).toEqual(["run"]);
  expect(shell.additionalProperties).toBe(false);
}

test("container experiment fences host and dynamic tools even with full access", async () => {
  const root = fixture();
  const sentinel = join(root.home, "host-secret");
  const mutation = join(root.home, "host-mutation");
  const shellMarker = join(root.workspace, "host-shell-ran");
  const mcpMarker = join(root.home, "mcp-started");
  writeFileSync(sentinel, "HOST_SECRET_MUST_NOT_REACH_MODEL");
  writeFileSync(join(root.workspace, "package.json"), '{"name":"bootstrap-manifest-fixture"}');
  writeFileSync(join(root.workspace, ".env"), "PRIVATE_ENV_CONTENT_MUST_NOT_REACH_MODEL");
  writeFileSync(join(root.workspace, "AGENTS.md"), "A".repeat(4096) + "MANIFEST_TAIL_MUST_NOT_REACH_MODEL");
  writeFileSync(join(root.profile, "mcp.json"), JSON.stringify({ mcp: {
    fixture: { type: "local", enabled: true, command: [
      "/bin/sh", "-c", `printf started > '${mcpMarker}'`,
    ] },
  } }), { mode: 0o600 });
  const calls: Array<[string, string, object]> = [
    ["pre-setup", "shell", { action: "run", command: `printf ran > '${shellMarker}'` }],
    ["host-read", "read_file", { path: sentinel }],
    ["host-write", "write_file", { path: mutation, content: "host changed" }],
    ["dynamic-open", "toolbox", { open: "fixture" }],
    ["dynamic-run", "toolbox", { run: "fixture_write", arguments: { path: mutation } }],
    ["direct-mcp", "mcp_fixture_write", { path: mutation }],
  ];
  const gateway = startFakeGateway([
    ...calls.map(([id, name, input]) => fakeGatewayToolCall(id, name, input)),
    fakeGatewayFinalText("CONTAINER_BOUNDARY_VERIFIED"),
  ]);
  try {
    const stdout = await ask(root, gateway);
    expect(stdout).toContain("CONTAINER_BOUNDARY_VERIFIED");
    expect(gateway.requests).toHaveLength(calls.length + 1);
    for (const request of gateway.requests) {
      assertSurface(request.body);
      expect(request.body).not.toContain("HOST_SECRET_MUST_NOT_REACH_MODEL");
      expect(request.body).not.toContain("PRIVATE_ENV_CONTENT_MUST_NOT_REACH_MODEL");
      expect(request.body).not.toContain("MANIFEST_TAIL_MUST_NOT_REACH_MODEL");
    }
    const first = gateway.requests[0].body;
    expect(first).toContain("bootstrap-manifest-fixture");
    expect(first).toContain("Repository root entries (at most 128)");
    expect(first).toContain("build context contains only your Dockerfile");
    expect(first.length).toBeLessThan(128 * 1024);
    for (let i = 0; i < calls.length; i++) {
      const output = toolResult(gateway.requests[i + 1].body, calls[i][0]);
      expect(output).toContain(i === 0 ? "ContainerNotRunning" : "container execution domain");
    }
    expect(existsSync(shellMarker)).toBe(false);
    expect(existsSync(mutation)).toBe(false);
    expect(existsSync(mcpMarker)).toBe(false);
    expect(readFileSync(sentinel, "utf8")).toBe("HOST_SECRET_MUST_NOT_REACH_MODEL");
    expect(gateway.classifierRequests).toHaveLength(0);
  } finally {
    gateway.stop();
    root.cleanup();
  }
}, 30_000);

test.skipIf(!tmuxAvailable())("interactive container startup keeps host context and tools fenced", async () => {
  const root = fixture();
  const secret = "TUI_HOST_SECRET_MUST_NOT_REACH_MODEL";
  const manifestTail = "TUI_MANIFEST_TAIL_MUST_NOT_REACH_MODEL";
  const branchSecret = "TUI_TRANSIENT_GIT_SECRET";
  const sentinel = join(root.home, "host-secret");
  const mutation = join(root.home, "host-mutation");
  const shellMarker = join(root.workspace, "host-shell-ran");
  const mcpMarker = join(root.home, "mcp-started");
  const stderrPath = join(root.home, "tui-stderr.log");
  writeFileSync(sentinel, secret);
  writeFileSync(stderrPath, "");
  writeFileSync(join(root.workspace, "package.json"), '{"name":"tui-bootstrap-manifest"}');
  // Ordinary project context reads beyond the bootstrap's 4096-byte allowance.
  writeFileSync(join(root.workspace, "AGENTS.md"), "A".repeat(4096) + manifestTail);
  execFileSync("git", ["-C", root.workspace, "symbolic-ref", "HEAD", `refs/heads/${branchSecret}`]);
  writeFileSync(join(root.profile, "settings.json"), JSON.stringify({
    experimental: { container_tools: true },
    permission_mode: "full-access",
  }), { mode: 0o600 });
  writeFileSync(join(root.profile, "mcp.json"), JSON.stringify({ mcp: {
    fixture: { type: "local", enabled: true, command: [
      "/bin/sh", "-c", `printf started > '${mcpMarker}'`,
    ] },
  } }), { mode: 0o600 });
  const gateway = startFakeGateway([
    fakeGatewayToolCall("tui-pre-setup", "shell", {
      action: "run", command: `printf ran > '${shellMarker}'`,
    }),
    fakeGatewayToolCall("tui-read", "read_file", { path: sentinel }),
    fakeGatewayToolCall("tui-write", "write_file", { path: mutation, content: "changed" }),
    fakeGatewayFinalText("TUI_CONTAINER_BOUNDARY_VERIFIED"),
  ]);
  let session: TmuxSession | undefined;
  try {
    session = await TmuxSession.create({
      isolated: true, cmd: FX_BIN, cwd: root.workspace, stderrPath,
      env: {
        HOME: root.home, FX_HOME: root.profile,
        AI_GATEWAY_API_KEY: "fake-container-test-key",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
      },
      width: 120, height: 40,
    });
    await session.waitForComposer(10_000);
    await session.sendText("Exercise the container boundary without setting it up.");
    const pane = await session.waitForText("TUI_CONTAINER_BOUNDARY_VERIFIED", 20_000);
    expect(pane).not.toMatch(/panic|SIGABRT|Aborted|Segmentation fault/i);
    expect(gateway.requests).toHaveLength(4);
    for (const { body } of gateway.requests) {
      assertSurface(body);
      expect(body).not.toContain(secret);
      expect(body).not.toContain(manifestTail);
      expect(body).not.toContain(branchSecret);
    }
    expect(gateway.requests[0].body).toContain("tui-bootstrap-manifest");
    expect(toolResult(gateway.requests[1].body, "tui-pre-setup")).toContain("ContainerNotRunning");
    expect(toolResult(gateway.requests[2].body, "tui-read")).toContain("container execution domain");
    expect(toolResult(gateway.requests[3].body, "tui-write")).toContain("container execution domain");
    expect(existsSync(shellMarker)).toBe(false);
    expect(existsSync(mutation)).toBe(false);
    expect(existsSync(mcpMarker)).toBe(false);
    expect(readFileSync(sentinel, "utf8")).toBe(secret);
    expect(gateway.classifierRequests).toHaveLength(0);
    await session.waitForComposer(10_000);
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(10_000)).toBe(true);
    expect(session.recordedExitStatus()).toBe(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    await session?.kill();
    gateway.stop();
    root.cleanup();
  }
}, 45_000);

// Verification-only owns the deterministic boundary above. Docker is an explicit
// local opt-in, not PGSO coverage: it requires a daemon and may pull an image.
test.skipIf(process.env.FX_TEST_CONTAINER_DOCKER !== "1")(
  "real Docker setup mounts only the repository and runs an unprivileged shell",
  async () => {
    const root = fixture();
    const sentinel = join(root.home, "host-secret");
    writeFileSync(sentinel, "DOCKER_HOST_SECRET_MUST_NOT_REACH_MODEL");
    const dockerfile = "FROM alpine:3.20\nRUN mkdir -p /home/fx && chmod 1777 /home/fx\n";
    const command = `pwd; id; test "$(id -u)" != 0 && printf container-write > mounted-proof && test ! -e '${sentinel}' && printf '\\nHOST_SENTINEL_INACCESSIBLE\\n'`;
    const gateway = startFakeGateway([
      fakeGatewayToolCall("setup", "container_setup", { dockerfile }),
      fakeGatewayToolCall("inside", "shell", { action: "run", command }),
      fakeGatewayFinalText("REAL_CONTAINER_VERIFIED"),
    ]);
    try {
      const stdout = await ask(root, gateway, 150_000);
      expect(stdout).toContain("REAL_CONTAINER_VERIFIED");
      expect(gateway.requests).toHaveLength(3);
      for (const request of gateway.requests) assertSurface(request.body);
      expect(toolResult(gateway.requests[1].body, "setup")).toContain("Container configured and running");
      const output = toolResult(gateway.requests[2].body, "inside");
      expect(output).toContain("/workspace");
      expect(output).toMatch(/uid=[1-9][0-9]*/);
      expect(output).toContain("HOST_SENTINEL_INACCESSIBLE");
      expect(output).not.toContain("DOCKER_HOST_SECRET_MUST_NOT_REACH_MODEL");
      expect(readFileSync(join(root.workspace, "mounted-proof"), "utf8")).toBe("container-write");
      expect(readFileSync(sentinel, "utf8")).toBe("DOCKER_HOST_SECRET_MUST_NOT_REACH_MODEL");
      const contexts = readdirSync(join(root.profile, "containers"), { recursive: true })
        .map(String).filter((path) => path.endsWith("/context"));
      expect(contexts).toHaveLength(1);
      for (const context of contexts) {
        const path = join(root.profile, "containers", context);
        expect(readdirSync(path)).toEqual(["Dockerfile"]);
        expect(readFileSync(join(path, "Dockerfile"), "utf8")).toBe(dockerfile);
        expect(statSync(path).mode & 0o777).toBe(0o700);
        expect(statSync(join(path, "..", "docker-config")).mode & 0o777).toBe(0o700);
      }
    } finally {
      gateway.stop();
      root.cleanup();
    }
  }, 180_000,
);

// This opt-in shares the Docker prerequisites above and never runs in PGSO.
test.skipIf(process.env.FX_TEST_CONTAINER_DOCKER !== "1")(
  "SIGINT cancels a sleeping container shell and removes its container promptly",
  async () => {
    const root = fixture();
    const marker = join(root.workspace, "cancel-started");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("cancel-setup", "container_setup", {
        dockerfile: "FROM alpine:3.20\nRUN mkdir -p /home/fx && chmod 1777 /home/fx\n",
      }),
      fakeGatewayToolCall("cancel-sleep", "shell", {
        action: "run", command: "printf started > cancel-started; exec sleep 60 >/dev/null 2>&1",
      }),
      fakeGatewayFinalText("CANCELLED_CONTAINER_TURN"),
    ]);
    const proc = Bun.spawn([
      FX_BIN, "ask", "--json", "--quiet", "--full-access",
      "--config", "experimental.container_tools=true", "--model", FAKE_GATEWAY_MODEL,
      "Set up the container, then run the sleeping command.",
    ], {
      cwd: root.workspace, env: gatewayEnv(root, gateway),
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const stdoutPromise = new Response(proc.stdout).text();
    const stderrPromise = new Response(proc.stderr).text();
    const watchdog = setTimeout(() => proc.kill("SIGKILL"), 150_000);
    let containerId: string | undefined;
    let cancelled = false;
    try {
      const deadline = Date.now() + 140_000;
      while (!existsSync(marker) && proc.exitCode === null && Date.now() < deadline) {
        await Bun.sleep(20);
      }
      expect(existsSync(marker)).toBe(true);
      expect(readFileSync(marker, "utf8")).toBe("started");
      expect(gateway.requests.length).toBeGreaterThanOrEqual(2);
      const records = readdirSync(join(root.profile, "containers"), { recursive: true })
        .map(String).filter((path) => path.endsWith("/recovery.json"));
      expect(records).toHaveLength(1);
      const recordPath = join(root.profile, "containers", records[0]);
      const runningRecord = JSON.parse(readFileSync(recordPath, "utf8"));
      expect(runningRecord.status).toBe("running");
      expect(runningRecord.workspace_root).toBe(root.workspace);
      containerId = runningRecord.container_id;
      expect(containerId).toMatch(/^[a-f0-9]{64}$/);
      const started = Date.now();
      proc.kill("SIGINT");
      cancelled = true;
      const cancelWatchdog = setTimeout(() => proc.kill("SIGKILL"), 10_000);
      let code: number;
      try {
        code = await proc.exited;
      } finally {
        clearTimeout(cancelWatchdog);
      }
      const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);
      expect(code).toBe(130);
      expect(Date.now() - started).toBeLessThan(10_000);
      expect([null, "SIGINT"]).toContain(proc.signalCode);
      expect(`${stdout}\n${stderr}`).not.toMatch(/panic|SIGABRT|Aborted|Segmentation fault/i);
      const remaining = execFileSync("docker", [
        "--host", "unix:///var/run/docker.sock", "ps", "--all", "--quiet",
        "--filter", `id=${containerId}`,
      ], { encoding: "utf8" });
      expect(remaining.trim()).toBe("");
      const cleanedRecord = JSON.parse(readFileSync(recordPath, "utf8"));
      expect(cleanedRecord.status).toBe("cleaned");
    } finally {
      clearTimeout(watchdog);
      if (proc.exitCode === null) {
        if (!cancelled) proc.kill("SIGINT");
        const cleanupWatchdog = setTimeout(() => proc.kill("SIGKILL"), 10_000);
        await proc.exited;
        clearTimeout(cleanupWatchdog);
      }
      // Limit failure cleanup to the container identified by this test's marker.
      if (containerId && /^[a-f0-9]{12,64}$/.test(containerId)) {
        try {
          execFileSync("docker", [
            "--host", "unix:///var/run/docker.sock", "rm", "--force", containerId,
          ], { stdio: "ignore" });
        } catch {}
      }
      gateway.stop();
      root.cleanup();
    }
  }, 180_000,
);
