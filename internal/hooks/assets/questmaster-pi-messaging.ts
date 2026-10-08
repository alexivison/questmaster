import { chmod, lstat, unlink } from "node:fs/promises";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { connect, createServer, type Server, type Socket } from "node:net";
import { dirname, join } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const maxRequestBytes = 1 << 20;
const maxIDBytes = 128;
const recentLimit = 40;
const snippetLimit = 180;
const hookTimeoutMs = 1_000;
const hookBatchLimit = 32;
const hookBatchByteLimit = 48 * 1024;
const hookBatchDelayMs = 150;
const sidecarVersion = "phase2-v2";
const sessionPattern = /^qm-[A-Za-z0-9_-]+$/;

type Request = { id: string; message: string };
type QueuedHook = { action: string; payload: Record<string, unknown>; bytes: number };
type PiContext = {
	cwd?: string;
	model?: unknown;
	sessionManager?: { getSessionId?: () => string | undefined; getSessionFile?: () => string | undefined };
	getContextUsage?: () => { tokens?: number | null; contextWindow?: number; percent?: number | null } | undefined;
};
type PiMessage = { role?: string; content?: unknown; model?: unknown; provider?: unknown; api?: unknown; usage?: unknown; stopReason?: unknown; errorMessage?: unknown };
type PiTurn = { index?: number; status?: "running" | "done"; started_at_ms?: number; ended_at_ms?: number; tool_calls?: number; errors?: number };
type PiTool = { name?: string; call_id?: string; summary?: string; status?: "running" | "done" | "error"; started_at_ms?: number; ended_at_ms?: number };

function safeLine(text: string, limit = snippetLimit): string {
	return Array.from(text.replace(/\s+/g, " ").trim()).slice(0, limit).join("");
}

function cleanString(value: unknown, limit = snippetLimit): string | undefined {
	return typeof value === "string" && value.trim() ? safeLine(value, limit) : undefined;
}

function boundedString(value: unknown, limit: number): string | undefined {
	return typeof value === "string" && value ? Array.from(value).slice(0, limit).join("") : undefined;
}

function cleanNumber(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value)
		? Math.max(-Number.MAX_SAFE_INTEGER, Math.min(value, Number.MAX_SAFE_INTEGER))
		: undefined;
}

function cleanNullableNumber(value: unknown): number | null | undefined {
	return value === null ? null : cleanNumber(value);
}

function textFromContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((part: { type?: string; text?: unknown }) => part?.type === "text" && typeof part.text === "string" ? part.text : "").filter(Boolean).join("\n");
}

function textFromMessage(message: unknown): string {
	const value = message as PiMessage | undefined;
	return value?.role === "assistant" ? textFromContent(value.content) : "";
}

function messageHasToolCall(message: unknown): boolean {
	const content = (message as PiMessage | undefined)?.content;
	return Array.isArray(content) && content.some((part: { type?: string }) => part?.type === "toolCall" || part?.type === "tool_call");
}

function nonEmptyLines(text: string): string[] {
	return text.split("\n").map((line) => line.trim()).filter(Boolean);
}

function lastTextLine(text: string): string | undefined {
	const lines = nonEmptyLines(text);
	return lines.length ? safeLine(lines[lines.length - 1]) : undefined;
}

function capChatText(text: string): string {
	const paragraphs: string[] = [];
	let lines: string[] = [];
	const flush = () => {
		if (lines.length) paragraphs.push(lines.join("\n"));
		lines = [];
	};
	for (const line of text.replace(/\r\n?/g, "\n").trim().split("\n")) {
		if (!line.trim()) {
			flush();
			if (paragraphs.length === 3) break;
		} else {
			lines.push(line);
		}
	}
	if (paragraphs.length < 3) flush();
	return Array.from(paragraphs.join("\n\n")).slice(0, 1_500).join("");
}

function modelState(raw: unknown): Record<string, unknown> | undefined {
	if (!raw || typeof raw !== "object") return undefined;
	const model = raw as Record<string, unknown>;
	const input = Array.isArray(model.input)
		? model.input.filter((value): value is string => typeof value === "string").slice(0, 8).map((value) => safeLine(value, 40))
		: undefined;
	const state = {
		provider: cleanString(model.provider, 80),
		id: cleanString(model.id, 120),
		name: cleanString(model.name, 120),
		api: cleanString(model.api, 80),
		...(typeof model.reasoning === "boolean" ? { reasoning: model.reasoning } : {}),
		context_window: cleanNumber(model.contextWindow),
		max_tokens: cleanNumber(model.maxTokens),
		...(input?.length ? { input } : {}),
	};
	return Object.values(state).some((value) => value !== undefined) ? state : undefined;
}

function usageSnapshot(raw: unknown): Record<string, number> | undefined {
	if (!raw || typeof raw !== "object") return undefined;
	const usage = raw as Record<string, unknown>;
	const cost = usage.cost && typeof usage.cost === "object" ? usage.cost as Record<string, unknown> : {};
	const state = {
		input: cleanNumber(usage.input),
		output: cleanNumber(usage.output),
		cache_read: cleanNumber(usage.cacheRead),
		cache_write: cleanNumber(usage.cacheWrite),
		total_tokens: cleanNumber(usage.totalTokens),
		cost_total: cleanNumber(cost.total),
	};
	return Object.values(state).some((value) => value !== undefined) ? state as Record<string, number> : undefined;
}

function contextState(ctx: PiContext): Record<string, number | null> | undefined {
	const usage = ctx.getContextUsage?.();
	if (!usage) return undefined;
	const state = {
		tokens: cleanNullableNumber(usage.tokens),
		context_window: cleanNumber(usage.contextWindow),
		percent: cleanNullableNumber(usage.percent),
	};
	return Object.values(state).some((value) => value !== undefined) ? state : undefined;
}

function mergeAssistantModel(current: Record<string, unknown> | undefined, message: unknown): Record<string, unknown> | undefined {
	if (!message || typeof message !== "object" || (message as PiMessage).role !== "assistant") return current;
	const value = message as PiMessage;
	const next = { ...(current ?? {}) };
	const provider = cleanString(value.provider, 80);
	const id = cleanString(value.model, 120);
	const api = cleanString(value.api, 80);
	if (provider) next.provider = provider;
	if (id) next.id = id;
	if (api) next.api = api;
	return Object.keys(next).length ? next : undefined;
}

function formatTool(toolName: string | undefined, rawArgs?: unknown): string {
	const name = cleanString(toolName, 80) ?? "tool";
	let args = rawArgs && typeof rawArgs === "object" ? rawArgs as Record<string, unknown> : {};
	if (typeof rawArgs === "string") {
		try {
			const parsed = JSON.parse(rawArgs) as unknown;
			if (parsed && typeof parsed === "object") args = parsed as Record<string, unknown>;
		} catch {}
	}
	const arg = (...keys: string[]) => keys.map((key) => args[key]).find((value) => typeof value === "string" && value.trim()) as string | undefined;
	switch (name) {
		case "bash": return `bash: ${safeLine(arg("command") ?? "running", 120)}`;
		case "read": return `read: ${safeLine(arg("path") ?? "file", 120)}`;
		case "edit":
		case "write": return `${name}: ${safeLine(arg("path") ?? "file", 120)}`;
		case "grep": return `grep: ${safeLine(arg("pattern", "query") ?? "search", 120)}`;
		case "find": return `find: ${safeLine(arg("pattern", "path") ?? "files", 120)}`;
		case "ls": return `ls: ${safeLine(arg("path") ?? "directory", 120)}`;
		default: return name;
	}
}

function markerPaths(): string[] {
	const home = process.env.PI_HOME || (process.env.HOME ? join(process.env.HOME, ".pi") : "");
	return home ? [join(home, "agent", "extensions", ".questmaster-installed"), join(home, "extensions", ".questmaster-installed")] : [];
}

function writeMarker(): void {
	for (const marker of markerPaths()) {
		try {
			mkdirSync(dirname(marker), { recursive: true });
			writeFileSync(marker, `${sidecarVersion}\n`, "utf8");
		} catch {}
	}
}

function runHook(action: string, input: string): Promise<void> {
	return new Promise((resolve) => {
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn("questmaster", ["hook", "pi", action], { stdio: ["pipe", "ignore", "ignore"] });
		} catch {
			resolve();
			return;
		}
		let finished = false;
		let forceKill: NodeJS.Timeout | undefined;
		const done = () => {
			if (finished) return;
			finished = true;
			clearTimeout(timeout);
			if (forceKill) clearTimeout(forceKill);
			resolve();
		};
		const timeout = setTimeout(() => {
			child.kill("SIGTERM");
			forceKill = setTimeout(() => child.kill("SIGKILL"), 100);
		}, hookTimeoutMs);
		child.once("error", done);
		child.once("close", done);
		child.stdin?.on("error", () => {});
		child.stdin?.end(input);
	});
}

export default function (pi: ExtensionAPI) {
	let server: Server | undefined;
	const connections = new Set<Socket>();
	let busy = false;
	let phase = "idle";
	let snippet = "";
	let recent: string[] = [];
	let currentTool = "";
	let questmasterSessionID = process.env.QUESTMASTER_SESSION ?? "";
	let piSessionID = "";
	let sessionFile = "";
	let cwd = process.cwd();
	let model: Record<string, unknown> | undefined;
	let thinking: { level: string } | undefined;
	let contextUsage: Record<string, number | null> | undefined;
	let turn: PiTurn | undefined;
	let tool: PiTool | undefined;
	let usage: { last: Record<string, number> } | undefined;
	let pendingNarration = "";
	let pendingNarrationAt = 0;
	let hookQueue: QueuedHook[] = [];
	let hookQueueBytes = 0;
	let hookFlushTimer: NodeJS.Timeout | undefined;
	let hookDrain: Promise<void> | undefined;

	function refreshMetadata(ctx?: PiContext): void {
		if (!ctx) return;
		model = modelState(ctx.model) ?? model;
		contextUsage = contextState(ctx) ?? contextUsage;
		cwd = ctx.cwd || cwd;
		try {
			const level = cleanString(pi.getThinkingLevel(), 40);
			if (level) thinking = { level };
		} catch {}
	}

	function recordAssistantMessage(message: unknown): void {
		model = mergeAssistantModel(model, message);
		const last = usageSnapshot((message as PiMessage | undefined)?.usage);
		if (last) usage = { last };
	}

	function pushRecent(line: string): void {
		const clean = safeLine(line);
		if (!clean || recent[recent.length - 1] === clean) return;
		recent.push(clean);
		if (recent.length > recentLimit) recent = recent.slice(-recentLimit);
	}

	function setSnippet(next: string | undefined, remember = true): void {
		const clean = safeLine(next ?? "");
		if (!clean) return;
		snippet = clean;
		if (remember) pushRecent(clean);
	}

	function activityPayload(extra?: Record<string, unknown>, occurredAtMS = Date.now()): Record<string, unknown> {
		return {
			version: 1,
			source: "pi",
			...(questmasterSessionID ? { id: safeLine(questmasterSessionID, maxIDBytes), session_id: safeLine(questmasterSessionID, maxIDBytes) } : {}),
			...(piSessionID ? { pi_session_id: boundedString(piSessionID, maxIDBytes) } : {}),
			...(sessionFile ? { session_file: boundedString(sessionFile, 1_024) } : {}),
			...(cwd ? { cwd: boundedString(cwd, 1_024) } : {}),
			updated_at_ms: Date.now(),
			occurred_at_ms: cleanNumber(occurredAtMS),
			busy,
			phase,
			...(snippet ? { snippet } : {}),
			...(recent.length ? { recent: recent.slice(-recentLimit).map((line) => safeLine(line)) } : {}),
			...(model ? { model } : {}),
			...(thinking ? { thinking } : {}),
			...(contextUsage ? { context: contextUsage } : {}),
			...(turn ? { turn } : {}),
			...(tool ? { tool } : {}),
			...(usage ? { usage } : {}),
			...(extra ?? {}),
		};
	}

	function scheduleHookFlush(): void {
		if (hookFlushTimer) return;
		hookFlushTimer = setTimeout(() => {
			hookFlushTimer = undefined;
			void drainHookQueue();
		}, hookBatchDelayMs);
	}

	async function drainHookQueue(): Promise<void> {
		if (hookFlushTimer) {
			clearTimeout(hookFlushTimer);
			hookFlushTimer = undefined;
		}
		if (hookDrain) {
			await hookDrain;
			return drainHookQueue();
		}
		if (hookQueue.length === 0) return;
		const events = hookQueue.splice(0);
		hookQueueBytes = 0;
		const operation = runHook("batch", `${JSON.stringify({ events: events.map(({ action, payload }) => ({ action, payload })) })}\n`);
		hookDrain = operation;
		await operation;
		if (hookDrain === operation) hookDrain = undefined;
		if (hookQueue.length >= hookBatchLimit || hookQueueBytes >= hookBatchByteLimit) return drainHookQueue();
		if (hookQueue.length) scheduleHookFlush();
	}

	async function emitHook(action: string, extra?: Record<string, unknown>, flush = false, occurredAtMS = Date.now()): Promise<void> {
		if (!sessionPattern.test(questmasterSessionID) || Buffer.byteLength(questmasterSessionID) > maxIDBytes) return;
		const payload = activityPayload(extra, occurredAtMS);
		const event = { action, payload };
		const bytes = Buffer.byteLength(JSON.stringify(event));
		if (bytes > hookBatchByteLimit) {
			await drainHookQueue();
			await runHook(action, `${JSON.stringify(payload)}\n`);
			return;
		}
		if (hookQueue.length >= hookBatchLimit || hookQueueBytes + bytes > hookBatchByteLimit) await drainHookQueue();
		hookQueue.push({ ...event, bytes });
		hookQueueBytes += bytes;
		if (flush || hookQueue.length >= hookBatchLimit || hookQueueBytes >= hookBatchByteLimit) await drainHookQueue();
		else scheduleHookFlush();
	}

	function setBusy(next: boolean, nextPhase: string, nextSnippet?: string): void {
		busy = next;
		phase = nextPhase;
		if (nextSnippet) setSnippet(nextSnippet);
	}

	function addTextToRecent(text: string): void {
		for (const line of nonEmptyLines(text).slice(-recentLimit)) pushRecent(line);
	}

	async function clearStaleSocket(path: string): Promise<boolean> {
		let before;
		try {
			before = await lstat(path);
		} catch (error: unknown) {
			return (error as NodeJS.ErrnoException).code === "ENOENT";
		}
		if (!before.isSocket() || before.uid !== process.getuid() || ![0o600, 0o700].includes(before.mode & 0o777)) return false;
		const stale = await new Promise<boolean>((resolve) => {
			const probe = connect(path);
			probe.setTimeout(250);
			probe.once("connect", () => { probe.destroy(); resolve(false); });
			probe.once("timeout", () => { probe.destroy(); resolve(false); });
			probe.once("error", (error: NodeJS.ErrnoException) => { resolve(error.code === "ECONNREFUSED" || error.code === "ENOENT"); });
		});
		if (!stale) return false;
		try {
			const after = await lstat(path);
			if (after.dev !== before.dev || after.ino !== before.ino) return false;
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
				if (typeof pi.sendUserMessage !== "function") return reject();
				pi.sendUserMessage(request.message, { deliverAs: "steer" });
				connection.end(JSON.stringify({ id: request.id, status: "unconfirmed" }) + "\n");
			} catch {
				reject();
			}
		});
	}

	async function start(): Promise<void> {
		if (typeof pi.sendUserMessage !== "function") return;
		const sessionID = process.env.QUESTMASTER_SESSION ?? "";
		if (!sessionPattern.test(sessionID)) return;
		const runtimeDir = join("/tmp", sessionID);
		try {
			const runtime = await lstat(runtimeDir);
			if (!runtime.isDirectory() || runtime.uid !== process.getuid() || (runtime.mode & 0o022) !== 0) return;
		} catch {
			return;
		}
		const socketPath = join("/tmp", sessionID, "pi.sock");
		if (!(await clearStaleSocket(socketPath))) return;
		const next = createServer(handle);
		next.on("error", () => {});
		const oldUmask = process.umask(0o077);
		try {
			await new Promise<void>((resolve, reject) => {
				next.once("error", reject);
				next.listen(socketPath, resolve);
			});
		} catch {
			return;
		} finally {
			process.umask(oldUmask);
		}
		try {
			await chmod(socketPath, 0o600);
		} catch {
			await new Promise<void>((resolve) => next.close(() => resolve()));
			return;
		}
		server = next;
	}

	pi.on("session_start", async (_event, rawContext) => {
		const occurredAtMS = Date.now();
		await stop();
		await start();
		const ctx = rawContext as PiContext | undefined;
		const sessionManager = ctx?.sessionManager;
		piSessionID = sessionManager?.getSessionId?.() || piSessionID;
		sessionFile = sessionManager?.getSessionFile?.() || sessionFile;
		refreshMetadata(ctx);
		tool = undefined;
		setBusy(false, "idle");
		await emitHook("session_start", undefined, false, occurredAtMS);
	});

	pi.on("before_agent_start", async (event: unknown, rawContext) => {
		const occurredAtMS = Date.now();
		writeMarker();
		const ctx = rawContext as PiContext | undefined;
		refreshMetadata(ctx);
		const record = event && typeof event === "object" ? event as Record<string, unknown> : {};
		const prompt = [record.prompt, record.input, record.message].find((value) => typeof value === "string" && value.trim()) as string | undefined;
		if (prompt) setSnippet(prompt);
		await emitHook("before_agent_start", prompt ? { prompt: safeLine(prompt) } : undefined, false, occurredAtMS);
	});

	pi.on("agent_start", async (_event, rawContext) => {
		const occurredAtMS = Date.now();
		const ctx = rawContext as PiContext | undefined;
		currentTool = "";
		tool = undefined;
		pendingNarration = "";
		pendingNarrationAt = 0;
		refreshMetadata(ctx);
		setBusy(true, "thinking");
		await emitHook("agent_start", undefined, false, occurredAtMS);
	});

	pi.on("model_select", (event: { model?: unknown }) => { model = modelState(event.model) ?? model; });
	pi.on("thinking_level_select", (event: { level?: unknown }) => {
		const level = cleanString(event.level, 40);
		if (level) thinking = { level };
	});
	pi.on("context", (_event, rawContext) => refreshMetadata(rawContext as PiContext | undefined));

	pi.on("turn_start", (event: { turnIndex?: unknown; timestamp?: unknown }, rawContext) => {
		refreshMetadata(rawContext as PiContext | undefined);
		pendingNarration = "";
		pendingNarrationAt = 0;
		turn = {
			index: cleanNumber(event.turnIndex),
			status: "running",
			started_at_ms: cleanNumber(event.timestamp) ?? Date.now(),
		};
	});

	pi.on("turn_end", (event: { turnIndex?: unknown; message?: unknown; toolResults?: Array<{ isError?: boolean }> }, rawContext) => {
		recordAssistantMessage(event.message);
		refreshMetadata(rawContext as PiContext | undefined);
		turn = {
			...(turn ?? {}),
			index: cleanNumber(event.turnIndex) ?? turn?.index,
			status: "done",
			ended_at_ms: Date.now(),
			tool_calls: Array.isArray(event.toolResults) ? Math.min(event.toolResults.length, 1_000_000) : undefined,
			errors: Array.isArray(event.toolResults) ? Math.min(event.toolResults.filter((result) => result?.isError).length, 1_000_000) : undefined,
		};
		pendingNarration = "";
	});

	pi.on("message_update", (event: { message?: unknown; assistantMessageEvent?: { type?: string; content?: unknown } }) => {
		const occurredAtMS = Date.now();
		const delta = event.assistantMessageEvent;
		if (delta?.type !== "text_end") return;
		const text = typeof delta.content === "string" ? delta.content : textFromMessage(event.message);
		if (!text.trim()) return;
		addTextToRecent(text);
		setSnippet(lastTextLine(text), false);
		pendingNarration = capChatText(`${pendingNarration}${pendingNarration ? "\n" : ""}${text}`);
		pendingNarrationAt = occurredAtMS;
	});

	pi.on("tool_execution_start", async (event: { toolCallId?: string; toolName?: string; args?: unknown }) => {
		const occurredAtMS = Date.now();
		if (pendingNarration.length) {
			await emitHook("say", { message: { role: "assistant", content: pendingNarration } }, false, pendingNarrationAt);
			pendingNarration = "";
			pendingNarrationAt = 0;
		}
		currentTool = formatTool(event.toolName, event.args);
		tool = {
			name: cleanString(event.toolName, 80) ?? "tool",
			call_id: cleanString(event.toolCallId, 120),
			summary: currentTool,
			status: "running",
			started_at_ms: Date.now(),
		};
		setSnippet(currentTool);
		setBusy(true, "tool");
		if (event.toolName === "ask_user") {
			const args = event.args && typeof event.args === "object" ? event.args as Record<string, unknown> : {};
			await emitHook("waiting_for_user", { prompt: typeof args.question === "string" ? safeLine(args.question) : currentTool }, true, occurredAtMS);
		}
		await emitHook("tool_execution_start", undefined, false, occurredAtMS);
	});

	pi.on("tool_execution_end", async (event: { toolCallId?: string; toolName?: string; isError?: boolean }) => {
		const occurredAtMS = Date.now();
		const label = currentTool || formatTool(event.toolName);
		tool = {
			...(tool ?? {}),
			name: cleanString(event.toolName, 80) ?? tool?.name ?? "tool",
			call_id: cleanString(event.toolCallId, 120) ?? tool?.call_id,
			summary: label,
			status: event.isError ? "error" : "done",
			ended_at_ms: Date.now(),
		};
		setSnippet(`${event.isError ? "✗" : "✓"} ${label}`);
		currentTool = "";
		await emitHook("tool_execution_end", undefined, event.toolName === "ask_user", occurredAtMS);
	});

	pi.on("agent_end", async (event: { messages?: unknown[] }, rawContext) => {
		const occurredAtMS = Date.now();
		let finalText = "";
		let stopReason: string | undefined;
		let errorMessage: string | undefined;
		for (const message of event.messages ?? []) {
			const assistant = message as PiMessage | undefined;
			if (assistant?.role !== "assistant") continue;
			recordAssistantMessage(message);
			const text = textFromMessage(message);
			finalText = text && !messageHasToolCall(message) ? text : "";
			stopReason = boundedString(assistant.stopReason, 80);
			errorMessage = boundedString(assistant.errorMessage, 1_500);
			if (text) addTextToRecent(text);
		}
		refreshMetadata(rawContext as PiContext | undefined);
		if (finalText) setSnippet(lastTextLine(finalText), false);
		if (tool) tool = { ...tool, status: "done", ended_at_ms: Date.now() };
		setBusy(false, "done", snippet || "Done");
		pendingNarration = "";
		pendingNarrationAt = 0;
		const finalPayload = {
			...(finalText ? { message: { role: "assistant", content: capChatText(finalText) } } : {}),
			...(stopReason ? { stopReason } : {}),
			...(errorMessage ? { errorMessage } : {}),
		};
		await emitHook("agent_end", Object.keys(finalPayload).length ? finalPayload : undefined, true, occurredAtMS);
	});

	pi.on("session_shutdown", async () => {
		const occurredAtMS = Date.now();
		setBusy(false, "idle");
		await stop();
		await emitHook("session_shutdown", undefined, true, occurredAtMS);
	});
}
