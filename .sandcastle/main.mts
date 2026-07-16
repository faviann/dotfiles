import { run, codex } from "@ai-hero/sandcastle";
import { docker } from "@ai-hero/sandcastle/sandboxes/docker";
import { copyFile, mkdtemp, rm, chmod, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const hostAuthFile = join(
  process.env.CODEX_HOME ?? join(homedir(), ".codex"),
  "auth.json",
);
const hostAuthStat = await stat(hostAuthFile).catch(() => undefined);

if (!hostAuthStat?.isFile()) {
  throw new Error(
    `Codex subscription login not found at ${hostAuthFile}. Run codex login first.`,
  );
}

// Never allow the subscription-backed workflow to fall back to API billing.
delete process.env.OPENAI_KEY;
delete process.env.OPENAI_API_KEY;

const stagedAuthDir = await mkdtemp(join(tmpdir(), "sandcastle-codex-auth-"));
const stagedAuthFile = join(stagedAuthDir, "auth.json");
await chmod(stagedAuthDir, 0o700);
await copyFile(hostAuthFile, stagedAuthFile);
await chmod(stagedAuthFile, 0o600);

// Simple loop: an agent that picks open issues one by one and closes them.
// Run this with: npx tsx .sandcastle/main.mts
// Or add to package.json scripts: "sandcastle": "npx tsx .sandcastle/main.mts"

try {
  await run({
    // A name for this run, shown as a prefix in log output.
    name: "worker",

    // The staged copy is the only host Codex state visible in the container.
    // It is mounted read-only and copied into a fresh writable Codex home before
    // the subscription login check runs.
    sandbox: docker({
      mounts: [
        {
          hostPath: stagedAuthDir,
          sandboxPath: "/run/sandcastle-codex-auth",
          readonly: true,
        },
      ],
      env: { CODEX_HOME: "/home/agent/.codex" },
    }),

    agent: codex("gpt-5.4"),

    // Path to the prompt file. Shell expressions inside are evaluated inside the
    // sandbox at the start of each iteration, so the agent always sees fresh data.
    promptFile: "./.sandcastle/prompt.md",

    // Keep the generated default: at most three one-issue agent invocations.
    maxIterations: 3,

    branchStrategy: { type: "merge-to-head" },

    copyToWorktree: ["node_modules"],

    hooks: {
      sandbox: {
        onSandboxReady: [
          {
            command:
              'install -d -m 700 "$CODEX_HOME" && ' +
              'install -m 600 /run/sandcastle-codex-auth/auth.json "$CODEX_HOME/auth.json" && ' +
              'test -z "${OPENAI_KEY:-}" && test -z "${OPENAI_API_KEY:-}" && ' +
              "codex login status && npm install",
          },
        ],
      },
    },
  });
} finally {
  await rm(stagedAuthDir, { recursive: true, force: true });
}
