import assert from "node:assert/strict";
import { connect } from "node:net";
import { lstat, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { installPiHookStub } from "./pi_hook_stub.mjs";
import { visibleWidth } from "./pi_tui_fixture.mjs";

// Checks the routed-message path end to end against a fake Pi: frames are
// acknowledged truthfully, held across compaction, sent as cards with steer
// semantics, and idle and prompt state comes from agent_settled and ui_prompt_*.
const extensionPath = process.argv[2];
assert.ok(process.env.QUESTMASTER_STATE_ROOT, "test must isolate spawned hook state");
const sessionID = `qm-pi-native-${process.pid}`;
// The socket path must stay under 104 bytes, so the runtime root is short.
const runtimeRoot = await mkdtemp(join(tmpdir(), "qmn"));
const runtimeDir = join(runtimeRoot, sessionID);
const socketPath = join(runtimeDir, "pi.sock");
const hooks = installPiHookStub();
await mkdir(runtimeDir, { mode: 0o700 });
process.env.QUESTMASTER_SESSION = sessionID;
process.env.QUESTMASTER_RUNTIME_DIR = runtimeDir;

const { default: extension } = await import(pathToFileURL(extensionPath));
const handlers = new Map();
const renderers = new Map();
const messages = [];
const userMessages = [];
const pi = {
	on(event, handler) { handlers.set(event, handler); },
	events: { on() {} },
	sendMessage(message, options) { messages.push({ message, options }); },
	sendUserMessage(message, options) { userMessages.push({ message, options }); },
	registerMessageRenderer(customType, renderer) { renderers.set(customType, renderer); },
	getThinkingLevel() { return "high"; },
};
extension(pi);

const context = {
	cwd: "/workspace",
	sessionManager: { getSessionId: () => "pi-session", getSessionFile: () => "session.jsonl" },
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 20));
const actions = () => hooks.calls.map(({ args }) => args[2]);
const hookCalls = (action) => hooks.calls.filter(({ args }) => args[2] === action);
const stripAnsi = (text) => text.replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g, "");
const cardText = (row) => stripAnsi(row).replace(/^┃ ?/, "");
function assertCardRowsFit(rows, width, label) {
	for (const [index, row] of rows.entries()) {
		assert.ok(visibleWidth(row) <= width, `${label} row ${index + 1} is ${visibleWidth(row)} cells at width ${width}: ${JSON.stringify(row)}`);
	}
}

let requests = 0;
async function send(message) {
	const id = `req-${++requests}`;
	return new Promise((resolve, reject) => {
		const socket = connect(socketPath);
		let response = "";
		socket.on("error", reject);
		socket.on("data", (data) => { response += data; });
		socket.on("end", () => resolve(JSON.parse(response)));
		socket.on("connect", () => socket.write(JSON.stringify({ id, message }) + "\n"));
	});
}

// sendRaw writes bytes that are not a request and returns whatever the server
// wrote back before it closed: nothing, for a refused frame.
async function sendRaw(bytes) {
	return new Promise((resolve) => {
		const socket = connect(socketPath);
		let response = "";
		socket.on("error", () => resolve(response));
		socket.on("data", (data) => { response += data; });
		socket.on("end", () => resolve(response));
		socket.on("connect", () => socket.end(bytes));
	});
}

let stopped = false;
try {
	await handlers.get("session_start")({}, context);

	// Idle delivery: an accepted frame becomes a card that steers and starts a turn,
	// and the model gets the whole frame.
	const plain = "hello there";
	const first = await send(plain);
	assert.equal(first.status, "accepted");
	assert.deepEqual(messages.at(-1), {
		message: { customType: "questmaster.message", content: plain, display: true, details: { kind: "message", from: "" } },
		options: { triggerTurn: true, deliverAs: "steer" },
	});

	const cases = [
		["[WORKER:qm-worker-1] Report: all green", "questmaster.worker", { kind: "worker", from: "qm-worker-1" }],
		["[MASTER:qm-master-1] Ship the change", "questmaster.master", { kind: "master", from: "qm-master-1" }],
		["[FROM:external] Ping", "questmaster.peer", { kind: "peer", from: "external" }],
		["[PR owner/repo#7] review: approved", "questmaster.pr", { kind: "pr", from: "owner/repo#7" }],
	];
	for (const [text, customType, details] of cases) {
		assert.equal((await send(text)).status, "accepted");
		assert.equal(messages.at(-1).message.customType, customType);
		assert.equal(messages.at(-1).message.content, text);
		assert.deepEqual(messages.at(-1).message.details, details);
	}
	assert.equal(userMessages.length, 0, "routed frames must not use sendUserMessage");

	// A frame the server cannot parse is closed without an acknowledgment, so the
	// sender can tell it was never taken.
	assert.equal(await sendRaw("not a request\n"), "");

	// Compaction: Pi refuses prompts while it compacts, so frames wait and go out
	// once it ends, in order.
	const beforeCompaction = messages.length;
	await handlers.get("session_before_compact")({ reason: "manual" }, context);
	assert.equal((await send("[WORKER:qm-worker-2] during manual compaction")).status, "queued");
	assert.equal((await send("second held frame")).status, "queued");
	assert.equal(messages.length, beforeCompaction, "held frames must wait for compaction to end");
	await handlers.get("session_compact")({ reason: "manual" }, context);
	await settle();
	assert.deepEqual(messages.slice(beforeCompaction).map(({ message }) => message.content), [
		"[WORKER:qm-worker-2] during manual compaction",
		"second held frame",
	]);

	// A failed compaction releases the same way.
	const beforeFailure = messages.length;
	await handlers.get("session_before_compact")({ reason: "threshold" }, context);
	assert.equal((await send("held across a failed compaction")).status, "queued");
	await handlers.get("session_compact_failed")({ reason: "threshold", aborted: false }, context);
	await settle();
	assert.equal(messages.at(-1).message.content, "held across a failed compaction");
	assert.equal(messages.length, beforeFailure + 1);

	// The queue is bounded: past the limit the frame is refused, so Questmaster
	// types it into the pane instead.
	await handlers.get("session_before_compact")({ reason: "manual" }, context);
	const statuses = [];
	for (let index = 0; index < 33; index += 1) statuses.push((await send(`bulk ${index}`)).status);
	assert.equal(statuses.filter((status) => status === "queued").length, 32);
	assert.equal(statuses.at(-1), "rejected");
	await handlers.get("session_compact")({ reason: "manual" }, context);
	await settle();

	// A card that Pi refuses now is acknowledged as rejected, so the caller falls back.
	const sendMessage = pi.sendMessage;
	pi.sendMessage = () => { throw new Error("runtime replaced"); };
	try {
		assert.equal((await send("refused by Pi")).status, "rejected");
	} finally {
		pi.sendMessage = sendMessage;
	}

	// Idle is reported by agent_settled, not agent_end. A retry between them keeps
	// the run open, and only the final attempt's outcome is reported.
	await handlers.get("agent_start")({}, context);
	await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "text", text: "Retrying" }], stopReason: "error", errorMessage: "overloaded" }] }, context);
	await settle();
	assert(!actions().includes("agent_end"), "agent_end must not be reported as idle");
	assert(!actions().includes("agent_settled"), "the run is not settled while Pi retries");
	await handlers.get("agent_start")({}, context);
	await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "text", text: "Done." }], usage: { output: 3 } }] }, context);
	await handlers.get("agent_settled")({ aborted: false }, context);
	const settled = hookCalls("agent_settled").at(-1);
	assert.equal(settled.payload.busy, false);
	assert.equal(settled.payload.phase, "done");
	assert.equal(settled.payload.message.content, "Done.");
	assert.equal(settled.payload.errorMessage, undefined, "a retried error must not leak into the settled report");

	// An aborted run settles without a stop reason from the model.
	await handlers.get("agent_start")({}, context);
	await handlers.get("agent_settled")({ aborted: true }, context);
	assert.equal(hookCalls("agent_settled").at(-1).payload.stopReason, "aborted");

	// Any dialog waits for the user, not only ask_user. Overlapping dialogs are one wait.
	const waits = () => hookCalls("waiting_for_user").length;
	const ends = () => hookCalls("ui_prompt_end").length;
	const beforeDialog = [waits(), ends()];
	await handlers.get("ui_prompt_start")({ kind: "select", title: "Pick a target" }, context);
	await handlers.get("ui_prompt_start")({ kind: "confirm" }, context);
	await handlers.get("ui_prompt_end")({}, context);
	assert.deepEqual([waits() - beforeDialog[0], ends() - beforeDialog[1]], [1, 1]);
	assert.equal(hookCalls("waiting_for_user").at(-1).payload.prompt, "Pick a target");

	// ask_user reports its question once; the dialog it opens adds nothing.
	await handlers.get("agent_start")({}, context);
	const beforeAsk = [waits(), ends()];
	await handlers.get("tool_execution_start")({ toolCallId: "ask-1", toolName: "ask_user", args: { question: "Which target?" } }, context);
	await handlers.get("ui_prompt_start")({ kind: "select", title: "Which target?" }, context);
	await handlers.get("ui_prompt_end")({}, context);
	await handlers.get("tool_execution_end")({ toolCallId: "ask-1", toolName: "ask_user", isError: false }, context);
	assert.deepEqual([waits() - beforeAsk[0], ends() - beforeAsk[1]], [1, 1]);
	assert.equal(hookCalls("waiting_for_user").at(-1).payload.prompt, "Which target?");
	await handlers.get("agent_settled")({ aborted: false }, context);

	// Cards render as a coloured heading and wrapped text. Control characters never
	// reach the terminal, and long text is shown in part while the model gets all of it.
	const worker = renderers.get("questmaster.worker")({
		customType: "questmaster.worker",
		content: "[WORKER:qm-worker-1] Report: all green\nsecond line",
		details: { kind: "worker", from: "qm-worker-1" },
	}, { expanded: false }, {});
	const rows = worker.render(40);
	assert.ok(rows[0].includes("worker report qm-worker-1"));
	assert.ok(rows[0].includes("\x1b[38;2;188;140;255m"), "worker cards use workerRole");
	assert.ok(rows.some((row) => row.includes("second line")));
	assert.ok(!rows.some((row) => row.includes("[WORKER:")), "the routing tag is shown in the heading only");

	const escaped = renderers.get("questmaster.message")({
		customType: "questmaster.message",
		content: "\x1b[31mred\x1b[0m",
		details: { kind: "message", from: "" },
	}, {}, {}).render(40);
	assert.ok(!escaped.some((row) => row.includes("\x1b[31m")), "a message cannot set terminal colours");

	const long = renderers.get("questmaster.message")({
		customType: "questmaster.message",
		content: "x".repeat(5_000),
		details: { kind: "message", from: "" },
	}, {}, {}).render(40);
	assertCardRowsFit(long, 40, "long ASCII card");
	assert.ok(long.some((row) => stripAnsi(row).includes("shortened here")), "a long card says it was shortened");
	const longBody = long.map(cardText).filter((row) => /^x+$/.test(row));
	assert.equal(longBody.join(""), "x".repeat(4_000), "a long card shows only its first 4000 characters");

	const wide = renderers.get("questmaster.message")({
		customType: "questmaster.message",
		content: "猫".repeat(12),
		details: { kind: "message", from: "" },
	}, {}, {}).render(12);
	assert.equal(wide.length, 4, "wide characters wrap by cell width: heading plus three rows");
	assertCardRowsFit(wide, 12, "CJK card");

	// All visible rows, including a long heading and the shortening notice, fit
	// even when the pane is too narrow for the usual bar and content gutter.
	for (const width of [0, 1, 2, 3, 7, 40, 59, 80]) {
		const narrow = renderers.get("questmaster.worker")({
			customType: "questmaster.worker",
			content: "x".repeat(5_000),
			details: { kind: "worker", from: "worker-" + "x".repeat(120) },
		}, {}, {}).render(width);
		assertCardRowsFit(narrow, width, `narrow card at width ${width}`);
	}

	// Pi treats the checkmark as two cells and keeps emoji sequences and combining
	// marks intact as graphemes when it wraps them.
	const checks = "✅".repeat(78);
	const checkRows = renderers.get("questmaster.message")({
		customType: "questmaster.message",
		content: checks,
		details: { kind: "message", from: "" },
	}, {}, {}).render(80);
	assertCardRowsFit(checkRows, 80, "checkmark emoji card");
	assert.equal(checkRows.map(cardText).filter((row) => /^✅+$/.test(row)).join(""), checks, "the 78 checkmarks remain intact");

	const graphemes = "✅👨‍👩‍👧‍👦e\u0301👩🏽‍💻".repeat(10);
	const graphemeRows = renderers.get("questmaster.message")({
		customType: "questmaster.message",
		content: graphemes,
		details: { kind: "message", from: "" },
	}, {}, {}).render(17);
	assertCardRowsFit(graphemeRows, 17, "grapheme boundary card");
	const graphemeBody = graphemeRows.map(cardText).filter((row) => /[✅👨👩]/u.test(row));
	assert.equal(graphemeBody.join(""), graphemes, "emoji and combining sequences are not split at wrap boundaries");

	await handlers.get("session_shutdown")();
	stopped = true;
	await assert.rejects(lstat(socketPath), { code: "ENOENT" });
} finally {
	if (!stopped) await handlers.get("session_shutdown")?.();
	await rm(runtimeRoot, { recursive: true, force: true });
}
