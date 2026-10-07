import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { installPiHookStub } from "./pi_hook_stub.mjs";

const extensionPath = process.argv[2];
const root = await mkdtemp(join(tmpdir(), "qm-pi-activity-"));
const sessionID = `qm-pi-activity-${process.pid}`;
const runtimeDir = join("/tmp", sessionID);
const hooks = installPiHookStub();
await mkdir(runtimeDir, { mode: 0o700 });
process.env.QUESTMASTER_SESSION = sessionID;
process.env.PI_HOME = root;

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
const finalText = `${"猫".repeat(1501)}\n\nsecond paragraph\n\nthird paragraph\n\nfourth paragraph`;
let stopped = false;
try {
	await handlers.get("session_start")({}, context);
	await handlers.get("before_agent_start")({ prompt: "Check the config" }, context);
	await handlers.get("agent_start")({}, context);
	await handlers.get("turn_start")({ turnIndex: 1 }, context);
	for (const type of ["thinking_delta", "thinking_end", "text_delta", "toolcall_delta"]) {
		await handlers.get("message_update")({ assistantMessageEvent: { type, delta: "private thinking text" } }, context);
	}
	await handlers.get("message_update")({
		message: { role: "assistant", content: [{ type: "text", text: "Checking this now." }] },
		assistantMessageEvent: { type: "text_end", content: "Checking this now." },
	}, context);
	await handlers.get("tool_execution_start")({ toolCallId: "tool-1", toolName: "bash", args: { command: "echo hi" } }, context);
	await handlers.get("tool_execution_end")({ toolCallId: "tool-1", toolName: "bash", isError: false }, context);
	await handlers.get("tool_execution_start")({ toolCallId: "tool-2", toolName: "ask_user", args: { question: "Choose a target" } }, context);
	await handlers.get("tool_execution_end")({ toolCallId: "tool-2", toolName: "ask_user", isError: false }, context);
	await handlers.get("turn_end")({
		turnIndex: 1,
		message: { role: "assistant", content: [{ type: "toolCall", id: "tool-1", name: "bash" }], usage: { input: 12 } },
		toolResults: [{ isError: false }],
	}, context);
	await handlers.get("agent_end")({
		messages: [{ role: "assistant", content: [{ type: "text", text: finalText }], usage: { output: 8 } }],
	}, context);
	await handlers.get("session_shutdown")();
	stopped = true;

	const entries = hooks.calls;
	assert.deepEqual(entries.map((entry) => entry.args[2]), [
		"session_start", "before_agent_start", "agent_start", "say", "tool_execution_start", "tool_execution_end",
		"waiting_for_user", "tool_execution_start", "tool_execution_end", "agent_end", "session_shutdown",
	]);
	assert.equal(entries[3].payload.text, "Checking this now.");
	assert.equal(entries[4].payload.tool.name, "bash");
	assert.equal(entries[4].payload.tool.summary, "bash: echo hi");
	assert.equal(entries[6].payload.prompt, "Choose a target");
	assert.equal(entries[7].payload.tool.name, "ask_user");
	assert.equal(Array.from(entries[9].payload.text).length, 1_500);
	assert(!entries[9].payload.text.includes("second paragraph"));
	assert.equal(entries[9].payload.turn.index, 1);
	assert.equal(entries[9].payload.turn.tool_calls, 1);
	assert.equal(entries[9].payload.usage.last.output, 8);
	assert.deepEqual(entries[9].payload.recent.slice(-3), ["second paragraph", "third paragraph", "fourth paragraph"]);
	assert(!JSON.stringify(entries).includes("private thinking text"));
	assert.equal(await readFile(join(root, "agent", "extensions", ".questmaster-installed"), "utf8"), "phase2-v2\n");
} finally {
	if (!stopped) await handlers.get("session_shutdown")?.();
	await rm(runtimeDir, { recursive: true, force: true });
	await rm(root, { recursive: true, force: true });
}
