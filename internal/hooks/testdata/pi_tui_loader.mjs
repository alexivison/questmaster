const testDouble = new URL("./pi_tui_stub.mjs", import.meta.url).href;

export async function resolve(specifier, context, nextResolve) {
	if (specifier === "@earendil-works/pi-tui") return { url: testDouble, shortCircuit: true };
	return nextResolve(specifier, context);
}
