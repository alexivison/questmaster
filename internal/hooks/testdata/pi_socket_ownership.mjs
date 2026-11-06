import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { lstat, mkdir, mkdtemp, rm } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { default: extension } = await import(pathToFileURL(process.argv[2]));
assert.ok(process.env.QUESTMASTER_STATE_ROOT, "test must isolate spawned hook state");
assert.notEqual(process.env.QUESTMASTER_STATE_ROOT, join(process.env.HOME, ".questmaster-state"));
const sessionID = `qm-pi-ownership-${process.pid}`;
// The session's runtime directory comes from $QUESTMASTER_RUNTIME_DIR, never
// from /tmp/<id>. The parent is short so the socket path stays under 104 bytes.
const runtimeRoot = await mkdtemp(join(tmpdir(), "qmp"));
const runtimeDir = join(runtimeRoot, sessionID);
const socketPath = join(runtimeDir, "pi.sock");
const legacyDir = join("/tmp", sessionID);
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

// Without the variable, or with a directory named for another session, the
// extension listens nowhere and creates nothing.
for (const dir of [undefined, join(runtimeRoot, "qm-other")]) {
	if (dir === undefined) delete process.env.QUESTMASTER_RUNTIME_DIR;
	else {
		process.env.QUESTMASTER_RUNTIME_DIR = dir;
		await mkdir(dir, { mode: 0o700 });
	}
	const stray = instance();
	await stray.handlers.get("session_start")();
	await assert.rejects(lstat(socketPath), { code: "ENOENT" });
	await assert.rejects(lstat(join(legacyDir, "pi.sock")), { code: "ENOENT" });
	if (dir !== undefined) await assert.rejects(lstat(join(dir, "pi.sock")), { code: "ENOENT" });
	await stray.handlers.get("session_shutdown")();
}
process.env.QUESTMASTER_RUNTIME_DIR = runtimeDir;

const primary = instance();
const inherited = instance();
let crashed;
let recovered;
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
	crashed = spawn(process.execPath, ["-e", "const net=require('node:net');const fs=require('node:fs');const path=process.argv[1];net.createServer().listen(path,()=>{fs.chmodSync(path,0o600);console.log('ready')})", socketPath], { stdio: ["ignore", "pipe", "pipe"] });
	assert.equal((await once(crashed.stdout, "data"))[0].toString().trim(), "ready");
	crashed.kill("SIGKILL");
	await once(crashed, "exit");
	assert.equal((await lstat(socketPath)).isSocket(), true);
	recovered = instance();
	await recovered.handlers.get("session_start")();
	assert.equal((await send("recovered")).status, "unconfirmed");
	assert.equal(recovered.messages[0].message, "recovered");
	await recovered.handlers.get("session_shutdown")();
	await assert.rejects(lstat(socketPath), { code: "ENOENT" });
} finally {
	crashed?.kill("SIGKILL");
	await recovered?.handlers.get("session_shutdown")();
	await inherited.handlers.get("session_shutdown")();
	await primary.handlers.get("session_shutdown")();
	await rm(runtimeRoot, { recursive: true, force: true });
}
