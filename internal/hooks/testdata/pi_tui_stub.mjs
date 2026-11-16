// Small test double for the Pi TUI helpers used by the extension. It keeps the
// fake-extension tests independent of a Pi install while covering the graphemes
// and display widths exercised by the list renderer.
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const emoji = /^\p{RGI_Emoji}$/v;
const wideCodePoint = (code) => (code >= 0x1100 && code <= 0x115f) || (code >= 0x2e80 && code <= 0xa4cf) ||
	(code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) ||
	(code >= 0xfe30 && code <= 0xfe4f) || (code >= 0xff00 && code <= 0xff60) ||
	(code >= 0xffe0 && code <= 0xffe6);

function graphemeWidth(grapheme) {
	if (/^\p{Mark}+$/u.test(grapheme)) return 0;
	if (emoji.test(grapheme)) return 2;
	const code = grapheme.codePointAt(0) ?? 0;
	return wideCodePoint(code) ? 2 : 1;
}

function segments(text) {
	return Array.from(graphemes.segment(text), ({ segment }) => segment);
}

export function visibleWidth(text) {
	const plain = text.replace(/\x1b\[[0-9;]*m/g, "");
	return segments(plain).reduce((width, grapheme) => width + graphemeWidth(grapheme), 0);
}

function takeWidth(text, maxWidth) {
	let width = 0;
	let result = "";
	for (const grapheme of segments(text)) {
		const nextWidth = graphemeWidth(grapheme);
		if (width + nextWidth > maxWidth) break;
		result += grapheme;
		width += nextWidth;
	}
	return { text: result, width };
}

export function truncateToWidth(text, maxWidth, ellipsis = "...", pad = false) {
	if (maxWidth <= 0) return "";
	const textWidth = visibleWidth(text);
	if (textWidth <= maxWidth) return pad ? text + " ".repeat(maxWidth - textWidth) : text;
	const ellipsisWidth = visibleWidth(ellipsis);
	const suffix = ellipsisWidth <= maxWidth ? ellipsis : takeWidth(ellipsis, maxWidth).text;
	const prefix = takeWidth(text, Math.max(0, maxWidth - visibleWidth(suffix)));
	const result = prefix.text + suffix;
	return pad ? result + " ".repeat(Math.max(0, maxWidth - visibleWidth(result))) : result;
}

export function wrapTextWithAnsi(text, width) {
	if (!text) return [""];
	const lines = [];
	let line = "";
	let used = 0;
	for (const grapheme of segments(text)) {
		const size = graphemeWidth(grapheme);
		if (line && used + size > width) {
			lines.push(line);
			line = "";
			used = 0;
		}
		line += grapheme;
		used += size;
	}
	if (line || lines.length === 0) lines.push(line);
	return lines;
}
