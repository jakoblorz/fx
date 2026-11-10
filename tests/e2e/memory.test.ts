import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import { contentText, parseGatewayRequest } from "./conditional-guidance-oracle";
import { fakeGatewaySse, fakeGatewayToolCall, startDynamicFakeGateway } from "./tmux-helpers";

const MEMORY_TOOLS = ["write_memory", "read_memory", "list_memory", "query_memory"];
const TIMEOUT = 30_000;
type Step = { name: string; input: object; check: (output: string) => void };

function filenames(expected: string[]) {
  return (output: string) => expect(JSON.parse(output).sort()).toEqual([...expected].sort());
}

function rejected(output: string) {
  expect(output).toMatch(/error|invalid|must|denied|not allowed|not permitted|reserved|write_memory|already has|not found/i);
}

async function scenario(
  buildSteps: (home: string, workspace: string) => Step[],
  after?: (home: string, workspace: string) => void,
  options: { movedProfile?: boolean } = {},
) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  const profile = join(home, options.movedProfile ? "moved-profile" : ".fx");
  mkdirSync(profile, { recursive: true });
  writeFileSync(join(profile, "settings.json"), "{}");
  const steps = buildSteps(home, workspace);
  const results = new Map<string, unknown>();
  let calls = 0;
  const gateway = startDynamicFakeGateway((body) => {
    const request = parseGatewayRequest(body);
    for (const message of request.prompt ?? []) {
      if (!Array.isArray(message.content)) continue;
      for (const part of message.content) {
        if (part.type === "tool-result") results.set(part.toolCallId, part.output);
      }
    }
    const step = steps[calls++];
    if (step) return fakeGatewayToolCall(`memory_${calls}`, step.name, step.input);
    return fakeGatewaySse([
      { type: "text-delta", id: "answer", delta: "memory scenario checked" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]);
  });
  try {
    const result = await runFx([
      "ask", "--auto", "--json", "--no-save", "Exercise the requested memory tools in order.",
    ], {
      cwd: workspace,
      timeoutMs: TIMEOUT,
      env: {
        HOME: home,
        FX_HOME: options.movedProfile ? profile : undefined,
        FX_AUTH_MODE: undefined,
        AI_GATEWAY_API_KEY: "fake-memory-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_PROVIDER: "gateway",
        FX_MODEL: "openai/gpt-5",
        FX_PERMISSION_MODE: "auto",
        FX_MAX_AGENT_STEPS: "100",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
      },
    });
    expect(result.timedOut).toBe(false);
    expect(result.signal).toBeNull();
    expect(result.code).toBe(0);
    // Progress belongs on stderr; anything beyond these expected rows is a diagnostic.
    const progress: Record<string, string> = {
      write_memory: "Writing memory", list_memory: "Listing memory",
      read_memory: "Reading memory", query_memory: "Querying memory",
      write_file: "Writing file", edit_file: "Editing file",
    };
    expect(result.stderr).toBe(steps.map((step) => progress[step.name]).join("\n") + "\n");
    expect(JSON.parse(result.stdout).output).toContain("memory scenario checked");
    expect(calls).toBe(steps.length + 1);
    const advertised = parseGatewayRequest(gateway.requests[0].body).tools ?? [];
    for (const name of MEMORY_TOOLS) {
      expect(advertised.filter((tool) => tool.name === name)).toHaveLength(1);
      expect(advertised.find((tool) => tool.name === name)?.type).toBe("function");
    }
    for (let index = 0; index < steps.length; index++) {
      const id = `memory_${index + 1}`;
      expect(results.has(id)).toBe(true);
      steps[index].check(contentText(results.get(id)));
    }
    after?.(home, workspace);
  } finally {
    gateway.stop();
    cleanupIsolatedTestHome(home);
  }
}

function write(filename: string, content: string, frontmatter?: object): Step {
  return {
    name: "write_memory", input: { filename, content, ...(frontmatter ? { frontmatter } : {}) },
    check(output) {
      const canonical = filename.endsWith(".md") ? filename : `${filename}.md`;
      expect(output).toBe(`Wrote memory ${canonical}`);
    },
  };
}

function query(query: object, expected: string[]): Step {
  return { name: "query_memory", input: { query }, check: filenames(expected) };
}

describe("native memory tools", () => {
  test("FX_HOME selects memory storage and protects it from generic mutations", async () => {
    await scenario((home) => {
      const memory = join(home, "moved-profile", "memory");
      mkdirSync(memory, { recursive: true });
      const malformed = "---\nnested:\n  child: unsupported\n---\nraw note\n";
      writeFileSync(join(memory, "manual.md"), malformed);
      return [
        { name: "read_memory", input: { filename: "manual" }, check(output) { expect(output).toBe(malformed); } },
        { name: "query_memory", input: { query: { nested: null } }, check: rejected },
        write("moved", "profile note\n"),
        { name: "write_file", input: { path: join(memory, "moved.md"), content: "bypass" }, check(output) { expect(output).toContain("write_memory"); } },
        { name: "list_memory", input: {}, check: filenames(["manual.md", "moved.md"]) },
        { name: "read_memory", input: { filename: "moved" }, check(output) { expect(output).toBe("profile note\n"); } },
      ];
    }, (home) => {
      expect(existsSync(join(home, ".fx", "memory"))).toBe(false);
      expect(readFileSync(join(home, "moved-profile", "memory", "moved.md"), "utf8")).toBe("profile note\n");
    }, { movedProfile: true });
  }, TIMEOUT + 5_000);

  test("write, raw read, list, typed membership, AND, existence, and overwrite", async () => {
    await scenario(() => [
      { name: "list_memory", input: {}, check: filenames([]) },
      write("alpha.md", "# Alpha\nA durable note.\n", {
        project: "fx", active: true, score: 7,
        tags: ["zig", "runtime"], values: [7, true, "7"], numbers: [7], optional: null,
      }),
      write("beta.md", "# Beta\n", { project: "fx", active: false, score: "7", tags: ["ziggy"], values: ["true"] }),
      write("plain", "# Plain\nNo metadata.\n"),
      { name: "read_memory", input: { filename: "alpha.md" }, check(output) {
        expect(output.startsWith("---\n")).toBe(true);
        expect(output).toMatch(/["']?project["']?:\s*["']?fx["']?/);
        expect(output).toContain("# Alpha\nA durable note.\n");
        expect(output).toContain("zig");
        expect(output).toContain("runtime");
      } },
      { name: "read_memory", input: { filename: "plain.md" }, check(output) {
        expect(output).toBe("# Plain\nNo metadata.\n");
      } },
      { name: "list_memory", input: {}, check: filenames(["alpha.md", "beta.md", "plain.md"]) },
      query({}, ["alpha.md", "beta.md", "plain.md"]),
      query({ project: "fx" }, ["alpha.md", "beta.md"]),
      query({ score: 7 }, ["alpha.md"]),
      query({ score: "7" }, ["beta.md"]),
      query({ tags: "zig" }, ["alpha.md"]),
      query({ tags: "zi" }, []),
      query({ values: true }, ["alpha.md"]),
      query({ values: "true" }, ["beta.md"]),
      query({ values: 7 }, ["alpha.md"]),
      query({ values: false }, []),
      query({ numbers: 7 }, ["alpha.md"]),
      query({ numbers: "7" }, []),
      query({ project: "fx", active: true }, ["alpha.md"]),
      query({ project: "fx", active: true, score: "7" }, []),
      query({ optional: null }, ["alpha.md"]),
      query({ absent: null }, []),
      write("alpha.md", "# Replaced\n", { replacement: true }),
      { name: "read_memory", input: { filename: "alpha.md" }, check(output) {
        expect(output).toContain("# Replaced\n");
        expect(output).not.toContain("A durable note.");
        expect(output).not.toContain("project:");
      } },
      query({ project: "fx" }, ["beta.md"]),
      query({ replacement: true }, ["alpha.md"]),
      { name: "list_memory", input: {}, check: filenames(["alpha.md", "beta.md", "plain.md"]) },
    ]);
  }, TIMEOUT + 5_000);

  test("invalid input cannot create or overwrite notes", async () => {
    await scenario((home) => {
      const invalidWrites = [
        { filename: "../escape.md", content: "escape" },
        { filename: join(home, "absolute.md"), content: "escape" },
        { filename: "nested/note.md", content: "escape" },
        { filename: "nested\\note.md", content: "escape" },
        { filename: ".hidden.md", content: "escape" },
        { filename: "", content: "empty filename" },
        { filename: "valid.md", content: 42 },
        { filename: "valid.md", content: "---\nproject: bypass\n---\nreplacement" },
        { filename: "valid.md", content: "\ufeff\n  ---\nproject: bypass\n---\nreplacement" },
        { filename: "valid.md", content: "replacement", frontmatter: { nested: { bad: true } } },
        { filename: "valid.md", content: "replacement", frontmatter: { nested: [["bad"]] } },
        { filename: "valid.md", content: "replacement", frontmatter: { nested: [{ bad: true }] } },
        { filename: "valid.md", content: "replacement", frontmatter: "invalid" },
      ];
      return [
        write("valid.md", "original\n"),
        ...invalidWrites.map((input) => ({ name: "write_memory", input, check: rejected })),
        { name: "read_memory", input: { filename: "../escape.md" }, check: rejected },
        { name: "read_memory", input: { filename: "missing.md" }, check: rejected },
        { name: "read_memory", input: { filename: "valid.md" }, check(output) { expect(output).toBe("original\n"); } },
        { name: "list_memory", input: {}, check: filenames(["valid.md"]) },
      ];
    });
  }, TIMEOUT + 5_000);

  test("generic mutations cannot bypass memory ownership through path aliases", async () => {
    await scenario((home, workspace) => {
      const memory = join(home, ".fx", "memory");
      mkdirSync(memory, { recursive: true });
      symlinkSync(memory, join(workspace, "memory-alias"), "dir");
      const paths = [
        join(memory, "protected.md"),
        "~/.fx/memory/protected.md",
        `${memory}/../memory/protected.md`,
        join(workspace, "memory-alias", "protected.md"),
      ];
      return [
        { name: "write_file", input: { path: join(memory, "new.md"), content: "bypassed\n" }, check(output) { expect(output).toContain("write_memory"); } },
        write("protected.md", "original\n"),
        ...paths.flatMap((path) => [
          { name: "write_file", input: { path, content: "bypassed\n" }, check(output) { expect(output).toContain("write_memory"); } },
          { name: "edit_file", input: { path, old_string: "original", new_string: "bypassed" }, check(output) { expect(output).toContain("write_memory"); } },
        ]),
        { name: "read_memory", input: { filename: "protected.md" }, check(output) { expect(output).toBe("original\n"); } },
        { name: "list_memory", input: {}, check: filenames(["protected.md"]) },
      ];
    }, (home) => {
      expect(readFileSync(join(home, ".fx", "memory", "protected.md"), "utf8")).toBe("original\n");
      expect(existsSync(join(home, ".fx", "memory", "escape.md"))).toBe(false);
    });
  }, TIMEOUT + 5_000);
});
