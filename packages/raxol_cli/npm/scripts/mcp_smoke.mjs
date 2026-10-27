#!/usr/bin/env node
// Smoke `raxol mcp` the way OMP spawns it: `node bin/launcher.js mcp`, with
// `initialize` written to stdin before the binary has booted. Run 1: tools/list
// has raxol_start and no harness_*, TableDemo starts as `t`, list_changed
// arrives, resources/read of its widgets answers. Run 2 (LC_ALL=C): a non-ASCII
// argument comes back byte-exact. Both exit 0 at end of input with every stdout
// line JSON-RPC. Time to initialize is printed, never asserted.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const launcher = fileURLToPath(new URL("../bin/launcher.js", import.meta.url));
const fail = (message) => {
  console.error(`mcp smoke: FAIL: ${message}`);
  process.exit(1);
};

function start(label, env) {
  const child = spawn(process.execPath, [launcher, "mcp"], {
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const messages = [];
  let waiters = [];
  let buffer = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    const lines = (buffer + chunk).split("\n");
    buffer = lines.pop();
    for (const line of lines) {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        fail(`${label}: stdout line is not JSON: ${JSON.stringify(line)}`);
      }
      if (message.jsonrpc !== "2.0") fail(`${label}: not JSON-RPC: ${line}`);
      messages.push(message);
      waiters = waiters.filter((w) => !(w.match(message) && (w.resolve(message), true)));
    }
  });
  // `close` fires once stdout is drained; a step still waiting then fails.
  const closed = new Promise((resolve) =>
    child.on("close", (code, signal) => {
      for (const w of waiters) w.reject(new Error(`${label}: exited ${code ?? signal} awaiting ${w.what}`));
      resolve({ code, signal });
    }),
  );
  const wait = (what, match) =>
    messages.find(match) ??
    new Promise((resolve, reject) => {
      waiters.push({ what, match, resolve, reject });
      setTimeout(() => reject(new Error(`${label}: timed out awaiting ${what}`)), 180_000).unref();
    });
  let id = 0;
  return {
    async request(method, params) {
      const mine = ++id;
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: mine, method, params })}\n`);
      return wait(`${method} ${mine}`, (m) => m.id === mine);
    },
    notification: (method) => wait(method, (m) => m.method === method && m.id === undefined),
    notify: (method) => child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method })}\n`),
    async end() {
      child.stdin.end();
      const { code, signal } = await closed;
      if (buffer !== "") fail(`${label}: unterminated stdout: ${JSON.stringify(buffer)}`);
      if (code !== 0) fail(`${label}: exit ${code ?? signal}`);
      console.log(`${label}: exit 0 at end of input; ${messages.length} stdout lines, all JSON-RPC`);
    },
  };
}

async function handshake(label, env) {
  const t0 = performance.now();
  const mcp = start(label, env);
  // Written at once, before the binary has read anything.
  const init = await mcp.request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "mcp-smoke" } });
  console.log(`${label}: time to initialize ${Math.round(performance.now() - t0)} ms, ${JSON.stringify(init.result.serverInfo)}`);
  mcp.notify("notifications/initialized");
  return mcp;
}

const text = (reply) => reply.result.content.map((c) => c.text).join("");

try {
  const one = await handshake("run 1", {});
  const names = (await one.request("tools/list", {})).result.tools.map((t) => t.name);
  if (!names.includes("raxol_start")) fail(`run 1: no raxol_start in ${names}`);
  if (names.some((n) => n.startsWith("harness_"))) fail(`run 1: harness tools listed: ${names}`);
  console.log(`run 1: tools/list: ${names.join(", ")}`);
  const changed = one.notification("notifications/tools/list_changed");
  const started = await one.request("tools/call", { name: "raxol_start", arguments: { module: "Raxol.Playground.Demos.TableDemo", id: "t" } });
  if (started.result.isError) fail(`run 1: raxol_start: ${text(started)}`);
  console.log(`run 1: raxol_start: ${text(started)}`);
  await changed;
  console.log("run 1: notifications/tools/list_changed seen");
  const read = await one.request("resources/read", { uri: "raxol://session/t/widgets" });
  if (!read.result?.contents?.length) fail(`run 1: resources/read: ${JSON.stringify(read)}`);
  console.log(`run 1: resources/read raxol://session/t/widgets: ${read.result.contents[0].text.length} chars`);
  await one.end();

  const two = await handshake("run 2 (LC_ALL=C)", { LC_ALL: "C", LANG: "C" });
  const name = "Raxol.Playground.Demos.Täble€";
  const echoed = text(await two.request("tools/call", { name: "raxol_start", arguments: { module: name, id: "u" } }));
  if (!echoed.includes(name)) fail(`run 2: non-ASCII argument not echoed byte-exact: ${echoed}`);
  console.log(`run 2: non-ASCII argument round-tripped: ${echoed}`);
  await two.end();
  console.log("mcp smoke: OK");
} catch (error) {
  fail(error.message);
}
