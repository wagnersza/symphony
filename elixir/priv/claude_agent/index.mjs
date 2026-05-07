#!/usr/bin/env node
// Symphony Claude agent wrapper.
// Protocol: see docs/superpowers/specs/2026-05-07-claude-agent-backend-design.md

import readline from "node:readline";
import process from "node:process";

const OUTPUT_MAX_BYTES = 8192;

function now() {
  return new Date().toISOString();
}

function emit(event) {
  process.stdout.write(JSON.stringify({ ...event, timestamp: now() }) + "\n");
}

function truncate(str) {
  if (typeof str !== "string") return str;
  const buf = Buffer.from(str, "utf8");
  if (buf.byteLength <= OUTPUT_MAX_BYTES) return str;
  return buf.subarray(0, OUTPUT_MAX_BYTES - 1).toString("utf8") + "…";
}

function parseArgs(argv) {
  const args = { workspace: null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--workspace" && argv[i + 1]) {
      args.workspace = argv[i + 1];
      i++;
    }
  }
  return args;
}

async function loadSdk() {
  if (process.env.SYMPHONY_CLAUDE_SDK_FAKE === "1") {
    return await import("./test-fake-sdk.mjs");
  }
  return await import("@anthropic-ai/claude-agent-sdk");
}

async function runTurn(sdk, { prompt, session_id, workspace }) {
  emit({ event: "turn_start", turn: 1 });

  const options = { cwd: workspace };
  if (session_id) options.resume = session_id;

  let sessionId = null;
  let tokensIn = 0;
  let tokensOut = 0;

  try {
    for await (const msg of sdk.query({ prompt, options })) {
      if (msg.type === "system" && msg.subtype === "init") {
        sessionId = msg.session_id || sessionId;
        continue;
      }
      if (msg.type === "assistant" && msg.message?.content) {
        for (const block of msg.message.content) {
          if (block.type === "text" && block.text) {
            emit({ event: "message", text: truncate(block.text) });
          } else if (block.type === "thinking" && block.thinking) {
            emit({ event: "thinking", text: truncate(block.thinking) });
          } else if (block.type === "tool_use") {
            emit({
              event: "tool_call",
              tool: block.name,
              args: block.input || {},
              tool_call_id: block.id || null,
            });
          }
        }
      }
      if (msg.type === "user" && msg.message?.content) {
        for (const block of msg.message.content) {
          if (block.type === "tool_result") {
            emit({
              event: "tool_result",
              tool: block.tool_name || "tool",
              ok: !block.is_error,
              exit: null,
              output: truncate(typeof block.content === "string" ? block.content : JSON.stringify(block.content)),
              tool_call_id: block.tool_use_id || null,
            });
          }
        }
      }
      if (msg.type === "result") {
        sessionId = msg.session_id || sessionId;
        if (msg.usage) {
          tokensIn = msg.usage.input_tokens ?? 0;
          tokensOut = msg.usage.output_tokens ?? 0;
        }
      }
    }
  } catch (err) {
    emit({ event: "session_end", reason: "error", detail: String(err?.message || err) });
    throw err;
  }

  emit({
    event: "tokens",
    input: tokensIn,
    output: tokensOut,
    total: tokensIn + tokensOut,
  });
  emit({ event: "turn_end", turn: 1, session_id: sessionId });
}

async function main() {
  const { workspace } = parseArgs(process.argv);
  if (!workspace) {
    process.stderr.write("missing --workspace\n");
    process.exit(2);
  }

  let sdk;
  try {
    sdk = await loadSdk();
  } catch (err) {
    process.stderr.write(`failed to load SDK: ${err?.message || err}\n`);
    process.exit(3);
  }

  emit({ event: "ready" });

  const rl = readline.createInterface({ input: process.stdin });

  let stopping = false;
  const shutdown = (reason) => {
    if (stopping) return;
    stopping = true;
    emit({ event: "session_end", reason, detail: null });
    rl.close();
  };

  rl.on("line", async (line) => {
    if (!line.trim()) return;
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch (e) {
      process.stderr.write(`ignoring unparseable stdin: ${line}\n`);
      return;
    }
    if (cmd.type === "start") {
      try {
        await runTurn(sdk, { prompt: cmd.prompt, session_id: cmd.session_id, workspace });
      } catch (_err) {
        stopping = true;
        rl.close();
      }
    } else if (cmd.type === "stop") {
      shutdown("completed");
    }
  });

  rl.on("close", () => {
    shutdown("completed");
    process.exit(0);
  });
}

main().catch((err) => {
  process.stderr.write(`wrapper crashed: ${err?.stack || err}\n`);
  process.exit(1);
});
