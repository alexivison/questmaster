// Node test loader: map Pi's public imports to an isolated contract fixture,
// so tests don't depend on an installed Pi or package download.
const fixture = new URL("./pi_tui_fixture.mjs", import.meta.url).href;

export async function resolve(specifier, context, nextResolve) {
	if (specifier === "@earendil-works/pi-tui" || specifier === "@earendil-works/pi-coding-agent") {
		return { url: fixture, shortCircuit: true };
	}
	return nextResolve(specifier, context);
}
