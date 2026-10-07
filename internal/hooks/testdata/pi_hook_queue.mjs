import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const extensionPath = process.argv[2];
const root = await mkdtemp(join(tmpdir(), "qm-pi-queue-"));
const sessionID = `qm-pi-queue-${process.pid}`;
const runtimeDir = join("/tmp", sessionID);
const logPath = join(root, "hooks.jsonl");
const cliPath = join(root, "questmaster");
await mkdir(runtimeDir, { mode: 0o700 });
process.env.QUESTMASTER_SESSION = sessionID;
process.env.PI_HOME = root;
process.env.QM_PI_QUEUE_LOG = logPath;
process.env.PATH = `${root}:${process.env.PATH}`;
await writeFile(cliPath, `#!/bin/sh
sleep 0.08
cat >> "$QM_PI_QUEUE_LOG"
`);
await chmod(cliPath, 0o755);

const { default: extension } = await import(pathToFileURL(extensionPath));
const handlers = new Map();
extension({
	on(event, handler) { handlers.set(event, handler); },
	sendUserMessage() {},
	getThinkingLevel() { return "high"; },
});
const context = {
	cwd: "/workspace",
	model: { provider: "openai-codex", id: "gpt-test", contextWindow: 1000 },
	sessionManager: { getSessionId: () => "pi-session", getSessionFile: () => "session.jsonl" },
	getContextUsage: () => ({ tokens: 42, contextWindow: 1000, percent: 4.2 }),
};
let stopped = false;
try {
	await handlers.get("session_start")({}, context);
	await handlers.get("before_agent_start")({ prompt: "Run many tools" }, context);
	await handlers.get("agent_start")({}, context);
	for (let i = 0; i < 100; i++) {
		await handlers.get("tool_execution_start")({ toolCallId: `tool-${i}`, toolName: "bash", args: { command: `echo ${i}` } }, context);
		await handlers.get("tool_execution_end")({ toolCallId: `tool-${i}`, toolName: "bash" }, context);
	}
	const controlStarted = Date.now();
	await handlers.get("tool_execution_start")({ toolCallId: "ask", toolName: "ask_user", args: { question: "Continue?" } }, context);
	const controlElapsed = Date.now() - controlStarted;
	await handlers.get("tool_execution_end")({ toolCallId: "ask", toolName: "ask_user" }, context);
	await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "text", text: "Finished." }] }] }, context);
	await handlers.get("session_shutdown")();
	stopped = true;

	const batches = (await readFile(logPath, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
	const actions = batches.flatMap((batch) => batch.events.map(({ action }) => action));
	const expected = ["session_start", "before_agent_start", "agent_start"];
	for (let i = 0; i < 100; i++) expected.push("tool_execution_start", "tool_execution_end");
	expected.push("waiting_for_user", "tool_execution_start", "tool_execution_end", "agent_end", "session_shutdown");
	assert.deepEqual(actions, expected);
	assert.equal(actions.filter((action) => action === "tool_execution_start").length, 101);
	assert.equal(actions.filter((action) => action === "tool_execution_end").length, 101);
	assert.equal(actions.filter((action) => action === "waiting_for_user").length, 1);
	assert(batches.length < actions.length / 2, `batch count ${batches.length} for ${actions.length} events`);
	assert(batches.every((batch) => batch.events.length <= 32));
	const waitingBatch = batches.find((batch) => batch.events.some(({ action }) => action === "waiting_for_user"));
	assert(waitingBatch.events.length <= 32, `control batch had ${waitingBatch.events.length} events`);
	assert(controlElapsed < 2_500, `control event waited ${controlElapsed}ms`);
} finally {
	if (!stopped) await handlers.get("session_shutdown")?.();
	await rm(runtimeDir, { recursive: true, force: true });
	await rm(root, { recursive: true, force: true });
}
