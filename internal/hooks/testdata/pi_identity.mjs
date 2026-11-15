import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import { syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

// Checks the identity the launch command passes in: the footer status for each
// role, and /workers and /quests as transcript entries that run the CLI and start
// no model turn. The CLI is a stub, so no session or quest state is read.
const extensionPath = process.argv[2];
process.env.QUESTMASTER_SESSION = "qm-identity-1";
const masterID = process.env.QUESTMASTER_SESSION;

const cli = new Map();
const calls = [];
childProcess.spawn = (_command, args) => {
	const child = new EventEmitter();
	child.kill = () => true;
	child.stdout = new Readable({ read() {} });
	child.stderr = new Readable({ read() {} });
	if (args[0] === "hook") {
		setImmediate(() => child.emit("close", 0));
		return child;
	}
	const key = args.join(" ");
	calls.push(key);
	const response = cli.get(key) ?? { code: 1, stdout: "", stderr: `no stub for ${key}` };
	let open = 2;
	const finish = () => {
		open -= 1;
		if (open === 0) child.emit("close", response.code);
	};
	child.stdout.on("end", finish);
	child.stderr.on("end", finish);
	setImmediate(() => {
		if (response.stdout) child.stdout.push(response.stdout);
		child.stdout.push(null);
		if (response.stderr) child.stderr.push(response.stderr);
		child.stderr.push(null);
	});
	return child;
};
syncBuiltinESMExports();

const { default: extension } = await import(pathToFileURL(extensionPath));
const identityKeys = ["QUESTMASTER_ROLE", "QUESTMASTER_TITLE", "QUESTMASTER_CLASS", "QUESTMASTER_MASTER_CLASS"];

// launch sets the identity variables the way the launch command exports them,
// then starts an extension instance with a recording Pi API.
function launch(identity) {
	for (const key of identityKeys) delete process.env[key];
	Object.assign(process.env, identity);
	const handlers = new Map();
	const entryRenderers = new Map();
	const commands = new Map();
	const appended = [];
	const messages = [];
	extension({
		on(event, handler) { handlers.set(event, handler); },
		events: { on() {} },
		registerMessageRenderer() {},
		registerEntryRenderer(type, renderer) { entryRenderers.set(type, renderer); },
		registerCommand(name, options) { commands.set(name, options); },
		appendEntry(type, data) { appended.push({ type, data }); },
		sendMessage(message, options) { messages.push({ message, options }); },
		getThinkingLevel() { return "high"; },
	});
	const statuses = [];
	const ctx = {
		cwd: "/workspace",
		hasUI: true,
		ui: { setStatus(key, text) { statuses.push({ key, text }); } },
		sessionManager: { getSessionId: () => "pi-session", getSessionFile: () => "session.jsonl" },
	};
	return { handlers, entryRenderers, commands, appended, messages, statuses, ctx };
}

async function started(session, ctx = session.ctx) {
	await session.handlers.get("session_start")({}, ctx);
	return session;
}

// The footer status names the role, the title and the class or familiar. The
// colours are Questmaster's masterRole and workerRole tokens.
const master = await started(launch({ QUESTMASTER_ROLE: "master", QUESTMASTER_TITLE: "Ship the change", QUESTMASTER_CLASS: "paladin" }));
assert.equal(master.statuses.length, 1);
assert.equal(master.statuses[0].key, "questmaster");
assert.ok(master.statuses[0].text.includes("Ship the change"));
assert.ok(master.statuses[0].text.includes(" · Paladin"));
assert.ok(master.statuses[0].text.includes("\x1b[38;2;242;204;96m"), "a master's status uses masterRole");

const worker = await started(launch({ QUESTMASTER_ROLE: "worker", QUESTMASTER_TITLE: "Scan repo", QUESTMASTER_MASTER_CLASS: "wizard" }));
assert.equal(worker.statuses.length, 1);
assert.ok(worker.statuses[0].text.includes("Scan repo"));
assert.ok(worker.statuses[0].text.includes(" · Fire Elemental familiar"), "a worker shows its master's familiar");
assert.ok(worker.statuses[0].text.includes("\x1b[38;2;188;140;255m"), "a worker's status uses workerRole");

const bare = await started(launch({}));
assert.equal(bare.statuses.length, 0, "a session Questmaster did not launch gets no status");

const unknown = await started(launch({ QUESTMASTER_ROLE: "master", QUESTMASTER_TITLE: "Odd", QUESTMASTER_CLASS: "dragon" }));
assert.equal(unknown.statuses.length, 1);
assert.ok(!unknown.statuses[0].text.includes("·"), "an unknown class id is not shown");

const headless = launch({ QUESTMASTER_ROLE: "master", QUESTMASTER_TITLE: "Quiet" });
await started(headless, { ...headless.ctx, hasUI: false });
assert.equal(headless.statuses.length, 0, "no status is set without a UI");

// /workers on a master lists its workers with their states. Titles are printed
// without control characters, and no model turn starts.
cli.set(`workers ${masterID}`, { code: 0, stdout: JSON.stringify({ master_id: masterID, workers: [
	{ session_id: "qm-worker-1", status: "working", title: "Scan\x1b[31m repo" },
	{ session_id: "qm-worker-2", status: "done", title: "Build" },
] }) });
await master.commands.get("workers").handler("", master.ctx);
const workers = master.appended.at(-1);
assert.equal(workers.type, "questmaster.list");
assert.equal(workers.data.title, "Workers (2)", JSON.stringify(workers.data));
assert.deepEqual(workers.data.rows.map((row) => row.lead), ["working", "done"]);
assert.ok(workers.data.rows[0].text.startsWith("qm-worker-1  Scan"));
assert.ok(!workers.data.rows[0].text.includes("\x1b"), "titles cannot set terminal state");
assert.equal(master.messages.length, 0, "/workers starts no model turn");
const rows = master.entryRenderers.get("questmaster.list")(workers, {}, {}).render(60);
assert.ok(rows[0].includes("Workers (2)"));
assert.ok(rows.some((row) => row.includes("working") && row.includes("qm-worker-1")));

// A worker runs no CLI call for /workers; it is told what the command is for.
const callsBeforeWorker = calls.length;
await worker.commands.get("workers").handler("", worker.ctx);
assert.equal(calls.length, callsBeforeWorker, "a worker runs no CLI call for /workers");
assert.ok(worker.appended.at(-1).data.rows[0].text.includes("lists a master's workers"));

// A session Questmaster did not launch is told so, not that it is a worker.
await bare.commands.get("workers").handler("", bare.ctx);
assert.ok(bare.appended.at(-1).data.rows[0].text.includes("not launched by Questmaster"));
assert.equal(bare.messages.length, 0);

// An empty list and a failed call are rows too.
cli.set(`workers ${masterID}`, { code: 0, stdout: JSON.stringify({ master_id: masterID, workers: [] }) });
await master.commands.get("workers").handler("", master.ctx);
assert.equal(master.appended.at(-1).data.rows[0].text, "No workers.");
cli.set(`workers ${masterID}`, { code: 1, stdout: "", stderr: "store unavailable\n" });
await master.commands.get("workers").handler("", master.ctx);
assert.equal(master.appended.at(-1).data.rows[0].lead, "error");
assert.ok(master.appended.at(-1).data.rows[0].text.includes("store unavailable"));

// One call lists every worker, and only 25 rows are shown.
const many = Array.from({ length: 30 }, (_, index) => ({ session_id: `qm-many-${index}`, status: "active", title: `Task ${index}` }));
cli.set(`workers ${masterID}`, { code: 0, stdout: JSON.stringify({ master_id: masterID, workers: many }) });
const callsBeforeMany = calls.length;
await master.commands.get("workers").handler("", master.ctx);
const bounded = master.appended.at(-1).data;
assert.equal(bounded.title, "Workers (30)");
assert.equal(calls.length - callsBeforeMany, 1, "one call lists every worker");
assert.equal(bounded.rows.length, 26, "25 worker rows and one line for the rest");
assert.ok(bounded.rows.at(-1).text.includes("5 more not shown"));

// /quests lists the project's quests, for the working directory of the command.
cli.set("quest ls --project /workspace", { code: 0, stdout: JSON.stringify({ quests: [{ id: "q-1", content: "Improve pagination\nmore detail", types: ["improvement"], size: "S" }] }) });
await master.commands.get("quests").handler("", master.ctx);
const quests = master.appended.at(-1).data;
assert.equal(quests.title, "Quests (1)");
assert.equal(quests.rows[0].lead, "q-1");
assert.ok(quests.rows[0].text.startsWith("improvement  S  Improve pagination"));
assert.equal(master.messages.length, 0, "/quests starts no model turn");

// A CLI failure is shown as a row, not thrown into Pi.
cli.set("quest ls --project /nowhere", { code: 1, stdout: "", stderr: "not a project\n" });
await master.commands.get("quests").handler("", { ...master.ctx, cwd: "/nowhere" });
const failed = master.appended.at(-1).data.rows[0];
assert.equal(failed.lead, "error");
assert.ok(failed.text.includes("not a project"));

await master.handlers.get("session_shutdown")();
