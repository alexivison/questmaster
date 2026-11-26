// Isolated Pi UI contract for extension tests. Unicode fixtures use
// Intl.Segmenter and Unicode properties, not a copied display-width table.

export class Container {
	children = [];

	addChild(child) { this.children.push(child); }
	clear() { this.children.length = 0; }
}

export class CustomEditor {
	borderColor = (text) => text;
	text = "";

	constructor(_tui, _theme, _keybindings, options) {
		this.embedWorkingStatus = options?.embedWorkingStatus;
	}

	getText() { return this.text; }
	setText(text) { this.text = text; }
	render(width) {
		const border = this.borderColor("─".repeat(width));
		return [border, this.text, border];
	}
}
const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });
const ansiPattern = /\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/y;
const emojiPresentation = /\p{Emoji_Presentation}/u;
const extendedPictographic = /\p{Extended_Pictographic}/u;
const regionalIndicator = /\p{Regional_Indicator}/u;
const wideScript = /[\p{Script=Han}\p{Script=Hangul}\p{Script=Hiragana}\p{Script=Katakana}]/u;
const markOnly = /^\p{Mark}+$/u;

function stripAnsi(text) {
	return text.replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g, "");
}

function graphemeWidth(segment) {
	if (emojiPresentation.test(segment) || segment.includes("\ufe0f") ||
		(segment.includes("\u200d") && extendedPictographic.test(segment)) ||
		regionalIndicator.test(segment) || wideScript.test(segment)) return 2;
	return markOnly.test(segment) ? 0 : 1;
}

function graphemes(text) {
	return Array.from(segmenter.segment(text), ({ segment }) => segment);
}

function tokens(text) {
	const result = [];
	let plain = "";
	const flush = () => {
		for (const segment of graphemes(plain)) result.push({ text: segment, width: graphemeWidth(segment) });
		plain = "";
	};
	for (let index = 0; index < text.length;) {
		ansiPattern.lastIndex = index;
		const ansi = ansiPattern.exec(text);
		if (ansi) {
			flush();
			result.push({ text: ansi[0], width: 0 });
			index = ansiPattern.lastIndex;
		} else {
			plain += text[index++];
		}
	}
	flush();
	return result;
}

export function visibleWidth(text) {
	return graphemes(stripAnsi(text).replace(/\t/g, "   ")).reduce((width, segment) => width + graphemeWidth(segment), 0);
}

export function truncateToWidth(text, maxWidth, ellipsis = "...", pad = false) {
	if (maxWidth <= 0) return "";
	const textWidth = visibleWidth(text);
	if (textWidth <= maxWidth) return pad ? text + " ".repeat(maxWidth - textWidth) : text;
	const targetWidth = Math.max(0, maxWidth - visibleWidth(ellipsis));
	let result = "";
	let width = 0;
	for (const token of tokens(text)) {
		if (token.width && width + token.width > targetWidth) break;
		result += token.text;
		width += token.width;
	}
	if (ellipsis) result += truncateToWidth(ellipsis, maxWidth - width, "");
	if (pad) result += " ".repeat(Math.max(0, maxWidth - visibleWidth(result)));
	return result;
}

export function wrapTextWithAnsi(text, width) {
	if (!text) return [""];
	const rows = [];
	for (const line of text.split("\n")) {
		let row = "";
		let rowWidth = 0;
		for (const token of tokens(line)) {
			if (token.width && rowWidth > 0 && rowWidth + token.width > width) {
				rows.push(row);
				row = "";
				rowWidth = 0;
			}
			row += token.text;
			rowWidth += token.width;
		}
		rows.push(row);
	}
	return rows;
}
