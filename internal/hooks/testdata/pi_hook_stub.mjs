import { EventEmitter } from "node:events";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { Writable } from "node:stream";

// installPiHookStub replaces spawn with a fake hook binary. With no command
// given, the extension must fall back to the bare "questmaster" name, so the
// stub clears the caller's QUESTMASTER_BIN and PATH; given a command, the stub
// makes it QUESTMASTER_BIN and expects the extension to spawn exactly that.
export function installPiHookStub(delayMs = 0, expectedCommand = "") {
	const calls = [];
	const batches = [];
	let active = 0;
	let maxActive = 0;
	let kills = 0;
	if (expectedCommand) {
		process.env.QUESTMASTER_BIN = expectedCommand;
	} else {
		delete process.env.QUESTMASTER_BIN;
		process.env.PATH = "";
	}
	const command = expectedCommand || "questmaster";
	childProcess.spawn = (spawned, args) => {
		const child = new EventEmitter();
		let input = "";
		let closed = false;
		let timer;
		active++;
		maxActive = Math.max(maxActive, active);
		const finish = (code, signal) => {
			if (closed) return;
			closed = true;
			if (timer) clearTimeout(timer);
			active--;
			child.emit("close", code, signal);
		};
		child.kill = (signal) => { kills++; finish(null, signal); return true; };
		child.stdin = new Writable({
			write(chunk, _encoding, callback) {
				input += chunk.toString();
				callback();
			},
		});
		child.stdin.once("finish", () => {
			if (closed) return;
			if (spawned !== command || args[0] !== "hook" || args[1] !== "pi") throw new Error(`unexpected hook command: ${spawned} ${args.join(" ")}`);
			const payload = JSON.parse(input);
			const events = args[2] === "batch" ? payload.events : [{ action: args[2], payload }];
			batches.push(events);
			calls.push(...events.map(({ action, payload }) => ({ args: ["hook", "pi", action], payload })));
			timer = setTimeout(() => finish(0, null), delayMs);
		});
		return child;
	};
	syncBuiltinESMExports();
	return { calls, batches, get maxActive() { return maxActive; }, get kills() { return kills; } };
}
