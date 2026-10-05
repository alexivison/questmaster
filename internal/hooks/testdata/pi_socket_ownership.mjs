import assert from "node:assert/strict";
import { lstat, mkdir, rm } from "node:fs/promises";
import { connect } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { default: extension } = await import(pathToFileURL(process.argv[2]));
const sessionID = `qm-pi-ownership-${process.pid}`;
const runtimeDir = join("/tmp", sessionID);
const socketPath = join(runtimeDir, "pi.sock");
process.env.QUESTMASTER_SESSION = sessionID;
await mkdir(runtimeDir, { mode: 0o700 });

function instance() {
	const handlers = new Map();
	const messages = [];
	extension({
		on(event, handler) { handlers.set(event, handler); },
		sendUserMessage(message, options) { messages.push({ message, options }); },
	});
	return { handlers, messages };
}

async function send(message) {
	return new Promise((resolve, reject) => {
		const socket = connect(socketPath);
		let response = "";
		socket.on("error", reject);
		socket.on("data", (data) => { response += data; });
		socket.on("end", () => resolve(JSON.parse(response)));
		socket.on("connect", () => socket.write(JSON.stringify({ id: "check", message }) + "\n"));
	});
}

const primary = instance();
const inherited = instance();
try {
	await primary.handlers.get("session_start")();
	await inherited.handlers.get("session_start")();
	assert.equal((await send("first")).status, "unconfirmed");
	assert.deepEqual(primary.messages, [{ message: "first", options: { deliverAs: "steer" } }]);
	assert.equal(inherited.messages.length, 0);
	await inherited.handlers.get("session_shutdown")();
	assert.equal((await send("second")).status, "unconfirmed");
	assert.equal(primary.messages.length, 2);
	await primary.handlers.get("session_start")();
	assert.equal((await send("third")).status, "unconfirmed");
	assert.equal(primary.messages.length, 3);
	await primary.handlers.get("session_shutdown")();
	await assert.rejects(lstat(socketPath), { code: "ENOENT" });
} finally {
	await inherited.handlers.get("session_shutdown")();
	await primary.handlers.get("session_shutdown")();
	await rm(runtimeDir, { recursive: true, force: true });
}
