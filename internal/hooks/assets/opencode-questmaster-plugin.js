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
const SIDECAR_VERSION = "phase2-v2";

import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";

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

function questmasterBin() {
  const bin = process.env.QUESTMASTER_BIN || "";
  if (bin) {
    try {
      accessSync(bin, constants.X_OK);
      return bin;
    } catch {}
  }
  return "questmaster";
}

export const QuestmasterOpenCode = async () => {
  const session = process.env.QUESTMASTER_SESSION || "";
  if (!session) {
    return { event: async () => {} };
  }
  const bin = questmasterBin();

  // message.part.updated fires per streamed token chunk; forwarding each one
  // spawns a qm-hook process and rewrites state.json. Keep only the freshest
  // delta per throttle window, and flush it before any other event so the
  // Go side's part->message promotion still sees the final text first.
  const PART_THROTTLE_MS = 250;
  let pendingPart = null;
  let partTimer = null;

  const flushPart = () => {
    if (partTimer) {
      clearTimeout(partTimer);
      partTimer = null;
    }
    if (pendingPart) {
      const buffered = pendingPart;
      pendingPart = null;
      emit(bin, session, buffered);
    }
  };

  const armPartTimer = () => {
    if (partTimer) return;
    partTimer = setTimeout(flushPart, PART_THROTTLE_MS);
    if (partTimer.unref) partTimer.unref();
  };

  const bufferPart = (event) => {
    if (event?.type !== "message.part.updated") return false;
    pendingPart = event;
    armPartTimer();
    return true;
  };

  return {
    event: async ({ event }) => {
      if (bufferPart(event)) return;
      flushPart();
      emit(bin, session, event);
    },
  };
};
