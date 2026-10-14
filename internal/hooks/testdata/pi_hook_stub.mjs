import { EventEmitter } from "node:events";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { Writable } from "node:stream";

export function installPiHookStub(delayMs = 0) {
	const calls = [];
	const batches = [];
	let active = 0;
	let maxActive = 0;
	childProcess.spawn = (command, args) => {
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
		child.kill = (signal) => { finish(null, signal); return true; };
		child.stdin = new Writable({
			write(chunk, _encoding, callback) {
				input += chunk.toString();
				callback();
			},
		});
		child.stdin.once("finish", () => {
			if (closed) return;
			if (command !== "questmaster" || args[0] !== "hook" || args[1] !== "pi") throw new Error(`unexpected hook command: ${command} ${args.join(" ")}`);
			const payload = JSON.parse(input);
			const events = args[2] === "batch" ? payload.events : [{ action: args[2], payload }];
			batches.push(events);
			calls.push(...events.map(({ action, payload }) => ({ args: ["hook", "pi", action], payload })));
			timer = setTimeout(() => finish(0, null), delayMs);
		});
		return child;
	};
	syncBuiltinESMExports();
	return { calls, batches, get maxActive() { return maxActive; } };
}
