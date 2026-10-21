// questmaster OpenCode plugin bridge - managed by `questmaster hooks install opencode`.
// Generated; do not edit. Re-install via `questmaster hooks install opencode` to refresh.
//
// Design contract:
//   - No-op unless $QUESTMASTER_SESSION is set (i.e. launched by questmaster).
//   - Observe-only: it forwards OpenCode events and tool execution hooks.
//   - Fully best-effort: forwarding failures are swallowed and never block OpenCode.
//
// The SIDECAR_VERSION marker must match openCodeSidecarVersion in opencode.go so
// `questmaster hooks status opencode` can detect stale installs.
const SIDECAR_VERSION = "phase2-v5";
const EMIT_TIMEOUT_MS = 5000;
const EMIT_KILL_GRACE_MS = 1000;

import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";

function jsonSafe(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return String(value);
  }
}

function createEmitter(bin, session) {
  let queue = Promise.resolve();
  return (event) => {
    const payload = JSON.stringify({
      schema: "questmaster-opencode/v1",
      version: SIDECAR_VERSION,
      captured_at: new Date().toISOString(),
      questmaster_session: session,
      event: jsonSafe(event),
    });
    queue = queue.then(
      () =>
        new Promise((resolve) => {
          let timer;
          let killTimer;
          let finishTimer;
          let finished = false;
          const finish = () => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            clearTimeout(killTimer);
            clearTimeout(finishTimer);
            resolve();
          };
          try {
            const child = spawn(bin, ["hook", "--session", session, "opencode", "event"], {
              stdio: ["pipe", "ignore", "ignore"],
            });
            timer = setTimeout(() => {
              child.kill("SIGTERM");
              killTimer = setTimeout(() => {
                child.kill("SIGKILL");
                finishTimer = setTimeout(finish, EMIT_KILL_GRACE_MS);
              }, EMIT_KILL_GRACE_MS);
            }, EMIT_TIMEOUT_MS);
            child.once("error", finish);
            child.once("close", finish);
            child.stdin.on("error", () => {});
            child.stdin.end(payload);
            child.unref();
          } catch {
            finish();
          }
        }),
    );
    queue = queue.catch(() => {});
  };
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
  const emit = createEmitter(bin, session);

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
      emit(buffered);
    }
  };

  const armPartTimer = () => {
    if (partTimer) return;
    partTimer = setTimeout(flushPart, PART_THROTTLE_MS);
    if (partTimer.unref) partTimer.unref();
  };

  const bufferPart = (event) => {
    if (event?.type !== "message.part.updated") return false;
    const part = event.properties?.part;
    if (part?.type === "tool" && part.state?.status === "error") {
      // Error parts close a call and must not be coalesced away.
      flushPart();
      emit(event);
      return true;
    }
    pendingPart = event;
    armPartTimer();
    return true;
  };

  return {
    event: async ({ event }) => {
      if (bufferPart(event)) return;
      flushPart();
      emit(event);
    },
    "tool.execute.before": async (input, output) => {
      flushPart();
      emit({
        type: "tool.execute.before",
        properties: {
          tool: input.tool,
          sessionID: input.sessionID,
          callID: input.callID,
          args: { command: output.args?.command },
        },
      });
    },
    "tool.execute.after": async (input) => {
      flushPart();
      emit({
        type: "tool.execute.after",
        properties: { tool: input.tool, sessionID: input.sessionID, callID: input.callID },
      });
    },
  };
};
