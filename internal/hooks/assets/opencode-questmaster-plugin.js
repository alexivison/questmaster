// questmaster OpenCode plugin bridge - managed by `questmaster hooks install opencode`.
// Generated; do not edit. Re-install via `questmaster hooks install opencode` to refresh.
//
// Design contract:
//   - No-op unless $QUESTMASTER_SESSION is set (i.e. launched by questmaster).
//   - Observe-only: it only forwards OpenCode event-hook payloads.
//   - Fully best-effort: forwarding failures are swallowed and never block OpenCode.
//
// The SIDECAR_VERSION marker must match hooks.QuestmasterSidecarVersion so
// `questmaster hooks status opencode` can detect stale installs.
const SIDECAR_VERSION = "phase2-v1";

import { spawn } from "node:child_process";

function jsonSafe(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return String(value);
  }
}

function emit(bin, session, event) {
  try {
    const child = spawn(bin, ["hook", "--session", session, "opencode", "event"], {
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.on("error", () => {});
    child.stdin.on("error", () => {});
    child.stdin.end(
      JSON.stringify({
        schema: "questmaster-opencode/v1",
        version: SIDECAR_VERSION,
        captured_at: new Date().toISOString(),
        questmaster_session: session,
        event: jsonSafe(event),
      }),
    );
    child.unref();
  } catch {}
}

export const QuestmasterOpenCode = async () => {
  const session = process.env.QUESTMASTER_SESSION || "";
  if (!session) {
    return { event: async () => {} };
  }
  const bin = process.env.QUESTMASTER_BIN || "questmaster";
  return {
    event: async ({ event }) => {
      emit(bin, session, event);
    },
  };
};
