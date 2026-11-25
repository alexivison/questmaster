// Questmaster's Pi messaging extension. Questmaster writes this file into its own
// state directory on every Pi launch and loads it with `pi -e`; it is never
// installed into Pi's extensions directory, so it has no install marker.
//
// Other extensions read the launch environment, never the styled text drawn here:
//   QUESTMASTER_SESSION       the session ID (qm-...)
//   QUESTMASTER_ROLE          "master" or "worker"
//   QUESTMASTER_TITLE         the session title, when set
//   QUESTMASTER_CLASS         a master's class id (paladin, wizard, ...), when set
//   QUESTMASTER_MASTER_CLASS  a worker's master's class id, when set (its familiar)
// The footer status key is "questmaster". Routed messages are custom messages with
// the customType names in cardStyles.
import { chmod, lstat, unlink } from "node:fs/promises";
import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { connect, createServer, type Server, type Socket } from "node:net";
import { basename, delimiter, isAbsolute, join } from "node:path";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const maxRequestBytes = 1 << 20;
const maxIDBytes = 128;
const recentLimit = 40;
const snippetLimit = 180;
// The hook bounds itself (800 ms), so this only catches a hook that hangs.
const hookTimeoutMs = 5_000;
const hookBatchLimit = 32;
const hookBatchByteLimit = 48 * 1024;
const hookBatchDelayMs = 150;
const sessionPattern = /^qm-[A-Za-z0-9_-]+$/;
// Frames that arrive while Pi compacts wait here. A full queue answers "rejected",
// so Questmaster types the message instead of holding it without bound.
const maxHeldMessages = 32;
// The card shows at most this many characters. The model still gets the whole text.
const cardCharLimit = 4_000;
// Lists are transcript entries that never reach the model. The worker list comes
// from one `questmaster workers` call; quests come from one `quest ls` call. Each
// list shows at most its row limit.
const listEntryType = "questmaster.list";
const listRowLimit = 50;
const workerRowLimit = 25;
const questmasterTimeoutMs = 5_000;
const questmasterOutputLimit = 512 * 1024;

type Request = { id: string; message: string };
type AckStatus = "accepted" | "queued" | "rejected";
type QueuedHook = { action: string; payload: Record<string, unknown>; bytes: number };
type CardKind = "worker" | "master" | "peer" | "pr" | "message";
type Card = { customType: string; content: string; display: true; details: { kind: CardKind; from: string } };
type PiContext = {
	cwd?: string;
	model?: unknown;
	sessionManager?: { getSessionId?: () => string | undefined; getSessionFile?: () => string | undefined };
	getContextUsage?: () => { tokens?: number | null; contextWindow?: number; percent?: number | null } | undefined;
	hasUI?: boolean;
	ui?: { setStatus?: (key: string, text: string | undefined) => void };
};
type PiMessage = { role?: string; content?: unknown; model?: unknown; provider?: unknown; api?: unknown; usage?: unknown; stopReason?: unknown; errorMessage?: unknown };
type PiTurn = { index?: number; status?: "running" | "done"; started_at_ms?: number; ended_at_ms?: number; tool_calls?: number; errors?: number };
type PiTool = { name?: string; call_id?: string; summary?: string; status?: "running" | "done" | "error"; started_at_ms?: number; ended_at_ms?: number };

// Colours are Questmaster's tokens from app/Sources/App/SharedUI/Theme.swift.
const cardStyles: Record<CardKind, { customType: string; rgb: [number, number, number]; heading: string }> = {
	worker: { customType: "questmaster.worker", rgb: [188, 140, 255], heading: "worker report" }, // workerRole
	master: { customType: "questmaster.master", rgb: [242, 204, 96], heading: "master" }, // masterRole
	peer: { customType: "questmaster.peer", rgb: [88, 166, 255], heading: "from" }, // trackerNeedsInput
	pr: { customType: "questmaster.pr", rgb: [217, 164, 65], heading: "pull request" }, // gitAmber
	message: { customType: "questmaster.message", rgb: [217, 219, 184], heading: "message" }, // chatSpeech
};

// The routing tags Questmaster's Go side writes: [WORKER:<id>], [MASTER:<id>],
// [FROM:<id>] (external for an outside sender) and [PR <ref>].
const routeTag = /^\[(WORKER|MASTER|FROM|PR)([: ])([^\]]*)\] ?/;

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

function isExecutable(path: string): boolean {
	try {
		accessSync(path, constants.X_OK);
		return true;
	} catch {
		return false;
	}
}

// questmasterBin picks the binary the way questmaster-state.sh does: an
// executable $QUESTMASTER_BIN, then questmaster, then qm on PATH.
function questmasterBin(): string {
	const configured = process.env.QUESTMASTER_BIN ?? "";
	if (configured && isExecutable(configured)) return configured;
	const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
	for (const name of ["questmaster", "qm"]) {
		if (dirs.some((dir) => isExecutable(join(dir, name)))) return name;
	}
	return "questmaster";
}

function runHook(action: string, input: string): Promise<void> {
	return new Promise((resolve) => {
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(questmasterBin(), ["hook", "pi", action], { stdio: ["pipe", "ignore", "ignore"] });
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

// printable drops control characters, so a frame cannot set terminal state.
function printable(text: string): string {
	return text.replace(/\r/g, "").replace(/\t/g, "  ").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
}

function classify(text: string): { kind: CardKind; from: string } {
	const match = routeTag.exec(text);
	if (!match) return { kind: "message", from: "" };
	const value = safeLine(printable(match[3]), 120);
	switch (match[1]) {
		case "WORKER": return { kind: "worker", from: value };
		case "MASTER": return { kind: "master", from: value };
		case "PR": return { kind: "pr", from: value };
		default: return { kind: "peer", from: value };
	}
}

// cardFor makes the custom message a routed frame becomes. Its content is the
// frame unchanged, so the model reads the same text it always did.
function cardFor(text: string): Card {
	const { kind, from } = classify(text);
	return { customType: cardStyles[kind].customType, content: text, display: true, details: { kind, from } };
}

function wrapCardLine(text: string, width: number, colour: string, style = "", reset = ""): string[] {
	const cells = Math.max(0, Math.floor(width));
	const prefix = truncateToWidth(`${colour}┃\x1b[39m `, cells, "");
	const contentCells = Math.max(0, cells - visibleWidth(prefix));
	if (contentCells === 0) return [prefix];
	return wrapTextWithAnsi(text, contentCells).map((row) => {
		const content = truncateToWidth(row, contentCells, "");
		return truncateToWidth(`${prefix}${style}${content}${reset}`, cells, "");
	});
}

// renderCard draws a routed message as a card: a coloured bar, a heading and the
// text wrapped to the viewport. Control characters go, so a message cannot
// change the terminal.
function renderCard(kind: CardKind, from: string, text: string, width: number): string[] {
	const [r, g, b] = cardStyles[kind].rgb;
	const colour = `\x1b[38;2;${r};${g};${b}m`;
	const heading = [cardStyles[kind].heading, from].filter(Boolean).join(" ");
	const lines = wrapCardLine(printable(heading), width, colour, `${colour}\x1b[1m`, "\x1b[22m\x1b[39m");
	// Only the first stretch is laid out, so a large frame costs the same on each redraw.
	const shown = Array.from(printable(text.slice(0, cardCharLimit * 4))).slice(0, cardCharLimit).join("");
	for (const line of shown.split("\n")) {
		lines.push(...wrapCardLine(line, width, colour));
	}
	if (text.length > cardCharLimit) lines.push(...wrapCardLine("… shortened here; the full message is kept in the session", width, colour, "\x1b[2m", "\x1b[22m"));
	return lines.map((line) => truncateToWidth(line, Math.max(0, Math.floor(width)), ""));
}

function cardComponent(message: { content?: unknown; details?: unknown }) {
	const details = (message.details ?? {}) as { kind?: unknown; from?: unknown };
	const kind = (Object.keys(cardStyles) as CardKind[]).find((name) => name === details.kind) ?? "message";
	const from = typeof details.from === "string" ? details.from : "";
	const body = textFromContent(message.content).replace(routeTag, "");
	let cached: { width: number; lines: string[] } | undefined;
	return {
		render(width: number): string[] {
			if (cached?.width !== width) cached = { width, lines: renderCard(kind, from, body, width) };
			return cached.lines;
		},
		invalidate() {
			cached = undefined;
		},
	};
}

// Class ids and the familiar each one summons. They are kept in step with
// internal/state/session_class.go and familiarName in
// app/Sources/Core/Mutations/SessionClassLogic.swift; a Go test checks both.
const familiars: Record<string, string> = {
	paladin: "Animated Armour",
	wizard: "Fire Elemental",
	druid: "Treant",
	barbarian: "Bear",
	rogue: "Shadow",
	cleric: "Light Spirit",
	bard: "Imp",
	ranger: "Hawk",
	necromancer: "Skeleton",
	sorcerer: "Lightning Elemental",
	fighter: "War Hound",
};

type Identity = { role: "master" | "worker" | ""; title: string; sessionClass: string; masterClass: string };

function classID(value: string | undefined): string {
	const id = (value ?? "").trim().toLowerCase();
	return Object.hasOwn(familiars, id) ? id : "";
}

function readIdentity(env: NodeJS.ProcessEnv): Identity {
	const role = env.QUESTMASTER_ROLE;
	return {
		role: role === "master" || role === "worker" ? role : "",
		title: safeLine(printable(env.QUESTMASTER_TITLE ?? ""), 120),
		sessionClass: classID(env.QUESTMASTER_CLASS),
		masterClass: classID(env.QUESTMASTER_MASTER_CLASS),
	};
}

// Colours are Questmaster's tokens from app/Sources/App/SharedUI/Theme.swift.
const accentRGB = [215, 177, 61]; // accent
const dimRGB = [111, 117, 124]; // inert
const stateRGB: Record<string, number[]> = {
	working: accentRGB,
	active: accentRGB,
	blocked: [229, 83, 75], // trackerBlocked
	done: [87, 171, 90], // trackerDone
	stopped: dimRGB,
};

function paint(rgb: number[], text: string, bold = false): string {
	return `${bold ? "\x1b[1m" : ""}\x1b[38;2;${rgb.join(";")}m${text}\x1b[39m${bold ? "\x1b[22m" : ""}`;
}

// identityLine is the footer status: the role's glyph and colour, the title, and
// the class or, for a worker, its master's familiar. A session Questmaster did
// not launch gets none.
function identityLine(identity: Identity): string | undefined {
	if (identity.role === "master") {
		const name = safeLine(identity.title || "master", 40);
		const cls = identity.sessionClass ? identity.sessionClass.charAt(0).toUpperCase() + identity.sessionClass.slice(1) : "";
		return paint(cardStyles.master.rgb, `◆ ${name}`, true) + (cls ? paint(dimRGB, ` · ${cls}`) : "");
	}
	if (identity.role === "worker") {
		const name = safeLine(identity.title || "worker", 40);
		const familiar = identity.masterClass ? familiars[identity.masterClass] : "";
		return paint(cardStyles.worker.rgb, `◇ ${name}`, true) + (familiar ? paint(dimRGB, ` · ${familiar} familiar`) : "");
	}
	return undefined;
}

type ListRow = { lead: string; leadRGB?: number[]; text: string };
type ListEntry = { title: string; leadWidth: number; rows: ListRow[] };

function listEntry(title: string, rows: ListRow[]): ListEntry {
	return { title, leadWidth: rows.reduce((width, row) => Math.max(width, visibleWidth(row.lead)), 0), rows };
}

function listComponent(entry: ListEntry) {
	return {
		render(width: number): string[] {
			const cells = Math.max(0, Math.floor(width));
			if (cells === 0) return [""];
			const lines = [paint(accentRGB, truncateToWidth(entry.title, cells), true)];
			for (const row of entry.rows) {
				const rowLeadWidth = visibleWidth(row.lead);
				if (rowLeadWidth > cells) {
					const wrapped = wrapTextWithAnsi(row.lead, cells);
					lines.push(...wrapped.map((line) => {
						const fitted = truncateToWidth(line, cells, "");
						return row.leadRGB ? paint(row.leadRGB, fitted) : fitted;
					}));
					continue;
				}

				const leadWidth = Math.min(entry.leadWidth, cells);
				const lead = truncateToWidth(row.lead, leadWidth, "", true);
				const shown = row.leadRGB ? paint(row.leadRGB, lead) : lead;
				const gap = leadWidth > 0 && leadWidth < cells ? " " : "";
				const textWidth = Math.max(0, cells - visibleWidth(shown) - gap.length);
				lines.push(`${shown}${gap}${truncateToWidth(row.text, textWidth)}`);
			}
			return lines;
		},
		invalidate() {},
	};
}

function errorText(error: unknown): string {
	return safeLine(error instanceof Error ? error.message : String(error), 200);
}

// questmasterJSON runs the Questmaster CLI and parses its JSON. The CLI owns the
// session and quest state; this extension reads none of it directly.
function questmasterJSON(args: string[]): Promise<unknown> {
	return new Promise((resolve, reject) => {
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(questmasterBin(), args, { stdio: ["ignore", "pipe", "pipe"] });
		} catch (error) {
			reject(error);
			return;
		}
		let out = "";
		let err = "";
		const timer = setTimeout(() => child.kill("SIGKILL"), questmasterTimeoutMs);
		child.stdout?.on("data", (chunk: Buffer) => {
			if (out.length < questmasterOutputLimit) out += chunk.toString("utf8");
		});
		child.stderr?.on("data", (chunk: Buffer) => {
			if (err.length < 4_096) err += chunk.toString("utf8");
		});
		child.once("error", (error) => {
			clearTimeout(timer);
			reject(error);
		});
		child.once("close", (code: number | null) => {
			clearTimeout(timer);
			if (code !== 0) {
				reject(new Error(safeLine(err || `questmaster exited with ${code}`, 200)));
				return;
			}
			try {
				resolve(JSON.parse(out));
			} catch {
				reject(new Error("questmaster printed no JSON"));
			}
		});
	});
}

type WorkerRow = { session_id?: unknown; status?: unknown; title?: unknown };

async function workersList(identity: Identity, sessionID: string): Promise<ListEntry> {
	const entry = (rows: ListRow[], title = "Workers"): ListEntry => listEntry(title, rows);
	if (identity.role !== "master") {
		const text = identity.role === "worker"
			? "This session is a worker. /workers lists a master's workers."
			: "This session was not launched by Questmaster, so it has no workers.";
		return entry([{ lead: "", text }]);
	}
	try {
		// One call returns every worker with its state, however many there are.
		const listed = (await questmasterJSON(["workers", sessionID])) as { workers?: unknown };
		const workers = (Array.isArray(listed.workers) ? listed.workers : []) as WorkerRow[];
		const shown = workers.slice(0, workerRowLimit);
		const rows: ListRow[] = shown.map((worker) => {
			const state = typeof worker.status === "string" ? safeLine(worker.status, 9) : "unknown";
			const id = typeof worker.session_id === "string" ? worker.session_id : "";
			const title = typeof worker.title === "string" ? safeLine(printable(worker.title), 80) : "";
			return { lead: state, leadRGB: stateRGB[state], text: printable([id, title].filter(Boolean).join("  ")) };
		});
		if (workers.length > shown.length) rows.push({ lead: "", text: `${workers.length - shown.length} more not shown` });
		return entry(rows.length ? rows : [{ lead: "", text: "No workers." }], `Workers (${workers.length})`);
	} catch (error) {
		return entry([{ lead: "error", text: errorText(error) }]);
	}
}

async function questsList(projectDir: string): Promise<ListEntry> {
	const entry = (rows: ListRow[], title: string): ListEntry => listEntry(title, rows);
	try {
		const body = (await questmasterJSON(["quest", "ls", "--project", projectDir])) as { quests?: unknown };
		const quests = (Array.isArray(body.quests) ? body.quests : []) as Array<{ id?: unknown; content?: unknown; types?: unknown; size?: unknown }>;
		const shown = quests.slice(0, listRowLimit);
		const rows = shown.map((quest): ListRow => {
			const tags = Array.isArray(quest.types) ? quest.types.filter((tag): tag is string => typeof tag === "string").join(",") : "";
			const size = typeof quest.size === "string" ? quest.size : "";
			const first = typeof quest.content === "string" ? nonEmptyLines(quest.content)[0] ?? "" : "";
			const id = typeof quest.id === "string" ? quest.id : "";
			return { lead: printable(id), text: printable([tags, size, safeLine(first, 160)].filter(Boolean).join("  ")) };
		});
		if (quests.length > shown.length) rows.push({ lead: "", text: `${quests.length - shown.length} more not shown` });
		return entry(rows.length ? rows : [{ lead: "", text: "No quests for this project." }], `Quests (${quests.length})`);
	} catch (error) {
		return entry([{ lead: "error", text: errorText(error) }], "Quests");
	}
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
	// Pi reports run_end before retries, compaction and queued work finish, so the
	// final payload waits here until agent_settled.
	let finalRun: { message?: unknown; stopReason?: string; errorMessage?: string } = {};
	// True from ask_user's question or a dialog's start until its end.
	let promptWaiting = false;
	// Between session_before_compact and its end, Pi refuses new prompts, so routed
	// frames wait in held and go out after the compaction finishes.
	let compacting = false;
	let held: Card[] = [];
	let heldFlush: NodeJS.Timeout | undefined;
	const identity = readIdentity(process.env);

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

	const subagentEvents = (pi as unknown as {
		events?: { on?: (name: string, listener: (event: unknown) => void) => void };
	}).events;
	const forwardSubagent = (action: string) => (event: unknown): void => {
		if (!event || typeof event !== "object") return;
		const fields = event as Record<string, unknown>;
		const id = cleanString(fields.id, maxIDBytes);
		const type = cleanString(fields.type, 80);
		if (!id || !type) return;
		void emitHook(action, { subagent_id: id, agent_type: type }, true);
	};
	subagentEvents?.on?.("subagents:started", forwardSubagent("subagent_start"));
	subagentEvents?.on?.("subagents:completed", forwardSubagent("subagent_stop"));
	subagentEvents?.on?.("subagents:failed", forwardSubagent("subagent_stop"));

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

	function sendCard(card: Card): void {
		pi.sendMessage(card, { triggerTurn: true, deliverAs: "steer" });
	}

	function scheduleHeldFlush(): void {
		if (heldFlush || held.length === 0) return;
		heldFlush = setTimeout(flushHeld, 0);
	}

	// flushHeld runs one macrotask after compaction ends, so the compaction has
	// cleared Pi's state before the first card starts a run.
	function flushHeld(): void {
		heldFlush = undefined;
		if (compacting) return;
		while (held.length) {
			const card = held.shift() as Card;
			try {
				sendCard(card);
			} catch {
				// The frame was acknowledged as queued and Pi refused the card now. Pi
				// is shutting down or its runtime was replaced, so there is nowhere to retry.
			}
		}
	}

	// acceptMessage takes ownership of a routed frame and says what it did. The
	// ack is what Questmaster reports, so it names only outcomes this function has.
	function acceptMessage(text: string): AckStatus {
		if (typeof pi.sendMessage !== "function") return "rejected";
		const card = cardFor(text);
		if (compacting || held.length) {
			if (held.length >= maxHeldMessages) return "rejected";
			held.push(card);
			scheduleHeldFlush();
			return "queued";
		}
		try {
			sendCard(card);
			return "accepted";
		} catch {
			return "rejected";
		}
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
			connection.end(JSON.stringify({ id: request.id, status: acceptMessage(request.message) }) + "\n");
		});
	}

	async function start(): Promise<void> {
		if (typeof pi.sendMessage !== "function") return;
		const sessionID = process.env.QUESTMASTER_SESSION ?? "";
		if (!sessionPattern.test(sessionID)) return;
		// Questmaster names the session's runtime directory; without it there is
		// no socket, and messages fall back to typed input.
		const runtimeDir = process.env.QUESTMASTER_RUNTIME_DIR ?? "";
		if (!isAbsolute(runtimeDir) || basename(runtimeDir) !== sessionID) return;
		try {
			const runtime = await lstat(runtimeDir);
			if (!runtime.isDirectory() || runtime.uid !== process.getuid() || (runtime.mode & 0o022) !== 0) return;
		} catch {
			return;
		}
		const socketPath = join(runtimeDir, "pi.sock");
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

	for (const style of Object.values(cardStyles)) {
		pi.registerMessageRenderer(style.customType, (message) => cardComponent(message));
	}
	pi.registerEntryRenderer(listEntryType, (entry) => listComponent(entry.data as ListEntry));
	pi.registerCommand("workers", {
		description: "List this master's workers and their states",
		handler: async () => {
			pi.appendEntry(listEntryType, await workersList(identity, questmasterSessionID));
		},
	});
	pi.registerCommand("quests", {
		description: "List this project's quests",
		handler: async (_args: string, ctx: { cwd?: string }) => {
			pi.appendEntry(listEntryType, await questsList(ctx.cwd || cwd));
		},
	});

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
		promptWaiting = false;
		const line = identityLine(identity);
		if (line && ctx?.hasUI) ctx.ui?.setStatus?.("questmaster", line);
		setBusy(false, "idle");
		await emitHook("session_start", undefined, false, occurredAtMS);
	});

	pi.on("before_agent_start", async (event: unknown, rawContext) => {
		const occurredAtMS = Date.now();
		const ctx = rawContext as PiContext | undefined;
		refreshMetadata(ctx);
		const record = event && typeof event === "object" ? event as Record<string, unknown> : {};
		// A run that a routed card starts carries the card as event.message.
		const cardText = textFromContent((record.message as { content?: unknown } | undefined)?.content);
		const prompt = [record.prompt, record.input, cardText].find((value) => typeof value === "string" && value.trim()) as string | undefined;
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
		finalRun = {};
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

	pi.on("turn_end", async (event: { turnIndex?: unknown; message?: unknown; toolResults?: Array<{ isError?: boolean }> }, rawContext) => {
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
		await emitHook("turn_end");
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
			// The question is the prompt, so the dialog's own start does not report it again.
			promptWaiting = true;
			await emitHook("waiting_for_user", { prompt: typeof args.question === "string" ? safeLine(args.question) : currentTool }, true, occurredAtMS);
		}
		await emitHook("tool_execution_start", {
			tool_call_id: cleanString(event.toolCallId, 120),
			tool_name: cleanString(event.toolName, 80),
			args: event.args && typeof event.args === "object" && !Array.isArray(event.args)
				? { command: (event.args as Record<string, unknown>).command }
				: undefined,
		}, false, occurredAtMS);
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
		promptWaiting = false;
		await emitHook("tool_execution_end", {
			tool_call_id: cleanString(event.toolCallId, 120),
			tool_name: cleanString(event.toolName, 80),
		}, event.toolName === "ask_user", occurredAtMS);
	});

	// agent_end is not idle: Pi may retry, compact or run queued messages after it.
	// Keep what it carries for the report agent_settled makes.
	pi.on("agent_end", (event: { messages?: unknown[] }, rawContext) => {
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
		finalRun = {
			...(finalText ? { message: { role: "assistant", content: capChatText(finalText) } } : {}),
			...(stopReason ? { stopReason } : {}),
			...(errorMessage ? { errorMessage } : {}),
		};
	});

	// agent_settled is the final boundary: Pi will not run again on its own.
	pi.on("agent_settled", async (event: { aborted?: unknown }, rawContext) => {
		const occurredAtMS = Date.now();
		refreshMetadata(rawContext as PiContext | undefined);
		if (tool) tool = { ...tool, status: "done", ended_at_ms: Date.now() };
		setBusy(false, "done", snippet || "Done");
		pendingNarration = "";
		pendingNarrationAt = 0;
		const run = finalRun;
		finalRun = {};
		const payload = {
			...run,
			...(event.aborted === true && !run.stopReason ? { stopReason: "aborted" } : {}),
		};
		await emitHook("agent_settled", Object.keys(payload).length ? payload : undefined, true, occurredAtMS);
	});

	// Any blocking dialog is a wait for the user, not only ask_user. A dialog that
	// opens inside ask_user is already reported as the question.
	pi.on("ui_prompt_start", async (event: { title?: unknown; kind?: unknown }) => {
		if (promptWaiting) return;
		promptWaiting = true;
		const prompt = cleanString(event.title) ?? cleanString(event.kind, 40) ?? "Waiting for input";
		await emitHook("waiting_for_user", { prompt }, true);
	});

	pi.on("ui_prompt_end", async () => {
		if (!promptWaiting) return;
		promptWaiting = false;
		await emitHook("ui_prompt_end", undefined, true);
	});

	pi.on("session_before_compact", () => {
		compacting = true;
	});

	pi.on("session_compact", () => {
		compacting = false;
		scheduleHeldFlush();
	});

	pi.on("session_compact_failed", () => {
		compacting = false;
		scheduleHeldFlush();
	});

	pi.on("session_shutdown", async () => {
		const occurredAtMS = Date.now();
		setBusy(false, "idle");
		await stop();
		held = [];
		if (heldFlush) {
			clearTimeout(heldFlush);
			heldFlush = undefined;
		}
		await emitHook("session_shutdown", undefined, true, occurredAtMS);
	});
}
