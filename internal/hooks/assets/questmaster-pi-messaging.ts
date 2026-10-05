import { chmod, lstat, unlink } from "node:fs/promises";
import { createServer, type Server, type Socket } from "node:net";
import { join } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const maxRequestBytes = 1 << 20;
const maxIDBytes = 128;
const sessionPattern = /^qm-[A-Za-z0-9_-]+$/;

type Request = { id: string; message: string };

export default function (pi: ExtensionAPI) {
	if (typeof pi.sendUserMessage !== "function") return;

	let server: Server | undefined;
	let socketPath = "";
	const connections = new Set<Socket>();

	async function removeOwnedSocket(path: string): Promise<boolean> {
		try {
			const info = await lstat(path);
			if (!info.isSocket() || info.uid !== process.getuid() || (info.mode & 0o777) !== 0o600) return false;
			await unlink(path);
			return true;
		} catch (error: unknown) {
			return (error as NodeJS.ErrnoException).code === "ENOENT";
		}
	}

	async function stop(): Promise<void> {
		const active = server;
		server = undefined;
		for (const connection of connections) connection.destroy();
		connections.clear();
		if (active) await new Promise<void>((resolve) => active.close(() => resolve()));
		if (socketPath) await removeOwnedSocket(socketPath);
		socketPath = "";
	}

	function parseRequest(line: Buffer): Request | undefined {
		if (line.length > maxRequestBytes) return undefined;
		let value: unknown;
		try {
			value = JSON.parse(line.toString("utf8"));
		} catch {
			return undefined;
		}
		if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
		const fields = Object.keys(value);
		if (fields.length !== 2 || !fields.includes("id") || !fields.includes("message")) return undefined;
		const request = value as Partial<Request>;
		if (typeof request.id !== "string" || request.id === "" || Buffer.byteLength(request.id) > maxIDBytes) return undefined;
		if (typeof request.message !== "string" || Buffer.byteLength(request.message) > maxRequestBytes) return undefined;
		return request as Request;
	}

	function handle(connection: Socket): void {
		connections.add(connection);
		let received = Buffer.alloc(0);
		let complete = false;
		const reject = () => connection.destroy();
		connection.on("close", () => connections.delete(connection));
		connection.on("error", () => {});
		connection.on("data", (chunk: Buffer) => {
			if (complete) return reject();
			if (received.length+chunk.length > maxRequestBytes+1) return reject();
			received = Buffer.concat([received, chunk]);
			const newline = received.indexOf(0x0a);
			if (newline < 0) return;
			complete = true;
			if (newline !== received.length-1) return reject();
			const request = parseRequest(received.subarray(0, newline));
			if (!request) return reject();
			try {
				pi.sendUserMessage(request.message, { deliverAs: "steer" });
				connection.end(JSON.stringify({ id: request.id, status: "unconfirmed" }) + "\n");
			} catch {
				reject();
			}
		});
	}

	async function start(): Promise<void> {
		const sessionID = process.env.QUESTMASTER_SESSION ?? "";
		if (!sessionPattern.test(sessionID)) return;
		const runtimeDir = join("/tmp", sessionID);
		try {
			const runtime = await lstat(runtimeDir);
		if (!runtime.isDirectory() || runtime.uid !== process.getuid() || (runtime.mode & 0o022) !== 0) return;
		} catch {
			return;
		}
		socketPath = join("/tmp", sessionID, "pi.sock");
		if (!(await removeOwnedSocket(socketPath))) return;
		const next = createServer(handle);
		next.on("error", () => { void removeOwnedSocket(socketPath); });
		const oldUmask = process.umask(0o077);
		try {
			await new Promise<void>((resolve, reject) => {
				next.once("error", reject);
				next.listen(socketPath, resolve);
			});
		} finally {
			process.umask(oldUmask);
		}
		try {
			await chmod(socketPath, 0o600);
		} catch {
			next.close();
			await removeOwnedSocket(socketPath);
			return;
		}
		server = next;
	}

	pi.on("session_start", async () => { await stop(); await start(); });
	pi.on("session_shutdown", async () => { await stop(); });
}
