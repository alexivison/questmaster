import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { installPiHookStub } from "./pi_hook_stub.mjs";

// The extension spawns the binary questmaster-state.sh would pick, an
// executable $QUESTMASTER_BIN first, and gives a hook that bounds itself
// time to finish instead of killing it at one second.
const extensionPath = process.argv[2];
const binary = process.argv[3];
const root = await mkdtemp(join(tmpdir(), "qm-pi-bin-"));
const sessionID = `qm-pi-bin-${process.pid}`;
const runtimeDir = join("/tmp", sessionID);
const hooks = installPiHookStub(1_500, binary);
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
const context = { cwd: "/workspace", sessionManager: { getSessionId: () => "pi-session", getSessionFile: () => "session.jsonl" } };
let stopped = false;
try {
	await handlers.get("session_start")({}, context);
	await handlers.get("agent_end")({ messages: [{ role: "assistant", content: [{ type: "text", text: "Finished." }] }] }, context);
	await handlers.get("session_shutdown")();
	stopped = true;
	assert(hooks.calls.length > 0, "no hook ran");
	assert.equal(hooks.kills, 0, "a 1.5 s hook was killed");
} finally {
	if (!stopped) await handlers.get("session_shutdown")?.();
	await rm(runtimeDir, { recursive: true, force: true });
	await rm(root, { recursive: true, force: true });
}
