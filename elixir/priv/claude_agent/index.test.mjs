import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WRAPPER = path.join(__dirname, "index.mjs");

function spawnWrapper(args = []) {
  const env = { ...process.env, SYMPHONY_CLAUDE_SDK_FAKE: "1" };
  return spawn("node", [WRAPPER, ...args], { env, stdio: ["pipe", "pipe", "pipe"] });
}

async function readEventsUntil(child, predicate, { timeoutMs = 2000 } = {}) {
  const events = [];
  let buffer = "";
  let timer;
  const stop = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("timeout waiting for events")), timeoutMs);
  });

  const reader = new Promise((resolve) => {
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let idx;
      while ((idx = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        if (!line.trim()) continue;
        const ev = JSON.parse(line);
        events.push(ev);
        if (predicate(ev)) resolve(events);
      }
    });
  });

  try {
    return await Promise.race([reader, stop]);
  } finally {
    clearTimeout(timer);
  }
}

describe("claude_agent wrapper", () => {
  test("emits {event:'ready'} on startup", async () => {
    const child = spawnWrapper(["--workspace", "/tmp"]);
    try {
      const events = await readEventsUntil(child, (e) => e.event === "ready");
      assert.equal(events[0].event, "ready");
      assert.match(events[0].timestamp, /\d{4}-\d{2}-\d{2}T/);
    } finally {
      child.kill("SIGTERM");
    }
  });

  test("streams turn_start, message, tokens, turn_end for a start command", async () => {
    const child = spawnWrapper(["--workspace", "/tmp"]);
    try {
      await readEventsUntil(child, (e) => e.event === "ready");
      child.stdin.write(JSON.stringify({ type: "start", prompt: "hi", max_turns: 1 }) + "\n");
      const events = await readEventsUntil(child, (e) => e.event === "turn_end");
      const kinds = events.map((e) => e.event);
      assert.ok(kinds.includes("turn_start"), `expected turn_start, got: ${kinds.join(",")}`);
      assert.ok(kinds.includes("message"), `expected message, got: ${kinds.join(",")}`);
      assert.ok(kinds.includes("tokens"), `expected tokens, got: ${kinds.join(",")}`);
      assert.ok(kinds.includes("turn_end"), `expected turn_end, got: ${kinds.join(",")}`);
      const turnEnd = events.find((e) => e.event === "turn_end");
      assert.ok(typeof turnEnd.session_id === "string" && turnEnd.session_id.length > 0, "session_id should be set");
    } finally {
      child.kill("SIGTERM");
    }
  });

  test("emits session_end and exits 0 on {type:'stop'}", async () => {
    const child = spawnWrapper(["--workspace", "/tmp"]);
    try {
      await readEventsUntil(child, (e) => e.event === "ready");
      child.stdin.write(JSON.stringify({ type: "stop" }) + "\n");
      const events = await readEventsUntil(child, (e) => e.event === "session_end");
      const [code] = await once(child, "close");
      assert.equal(events.at(-1).event, "session_end");
      assert.equal(events.at(-1).reason, "completed");
      assert.equal(code, 0);
    } finally {
      if (child.exitCode === null) child.kill("SIGKILL");
    }
  });
});
