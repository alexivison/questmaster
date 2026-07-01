// questmaster oh-my-pi activity sidecar — managed by `questmaster hooks install omp`.
// Generated; do not edit. Re-install via `questmaster hooks install omp` to refresh.
//
// This is an oh-my-pi extension (https://github.com/can1357/oh-my-pi). omp
// auto-discovers extensions from ~/.omp/agent/extensions, loads this module,
// and calls the default export with the ExtensionAPI. The sidecar subscribes
// to lifecycle/observability events and forwards each one to
// `questmaster hook --session <id> omp <action>` so questmaster's state
// tracker can render live status for the pane.
//
// Design contract:
//   - No-op unless $QUESTMASTER_SESSION is set (i.e. launched by questmaster).
//   - Observe-only: it never subscribes to blocking hooks (tool_call /
//     tool_result), so it cannot interfere with omp's own tool execution.
//   - Fully best-effort: every handler is wrapped so a forwarding failure can
//     never surface to the agent. Forwarding is asynchronous so it does not
//     block omp's event loop.
//
// The SIDECAR_VERSION marker must match hooks.QuestmasterSidecarVersion so
// `questmaster hooks status omp` can detect stale installs.
const SIDECAR_VERSION = "phase2-v1";

import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";

type AnyRecord = Record<string, unknown>;

function questmasterBin(): string {
  const bin = process.env.QUESTMASTER_BIN || "";
  if (bin) {
    try {
      accessSync(bin, constants.X_OK);
      return bin;
    } catch {}
  }
  return "questmaster";
}

export default function questmasterOmpSidecar(pi: any): void {
  const session = process.env.QUESTMASTER_SESSION;
  if (!session) {
    return; // not running under questmaster — stay inert
  }
  const bin = questmasterBin();

  const emit = (action: string, payload: AnyRecord): void => {
    try {
      const child = spawn(bin, ["hook", "--session", session, "omp", action], {
        stdio: ["pipe", "ignore", "ignore"],
      });
      child.on("error", () => {});
      try {
        child.stdin.write(JSON.stringify({ ...payload, version: SIDECAR_VERSION }));
        child.stdin.end();
      } catch {}
      child.unref();
    } catch {}
  };

  const sessionFile = (ctx: any): string => {
    try {
      const f = ctx?.sessionManager?.getSessionFile?.();
      return typeof f === "string" ? f : "";
    } catch {
      return "";
    }
  };

  // Pull assistant text out of the various shapes message_* events use.
  const messageText = (event: any): string => {
    if (!event) return "";
    const direct = event.text ?? event.delta ?? event.snippet;
    if (typeof direct === "string" && direct.trim() !== "") return direct;
    const content = event.content ?? event.message?.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      const parts: string[] = [];
      for (const block of content) {
        if (block && (block.type === "text" || block.type == null) && typeof block.text === "string") {
          parts.push(block.text);
        }
      }
      if (parts.length) return parts.join("\n");
    }
    return "";
  };

  const toolName = (event: any): string =>
    event?.toolName ?? event?.tool_name ?? event?.name ?? event?.tool?.name ?? "";

  const toolInput = (event: any): unknown =>
    event?.input ?? event?.args ?? event?.arguments ?? event?.tool?.input ?? null;

  const on = (eventName: string, handler: (event: any, ctx: any) => void): void => {
    try {
      pi.on(eventName, (event: any, ctx: any) => {
        try {
          handler(event, ctx);
        } catch {}
      });
    } catch {}
  };

  // Session lifecycle.
  on("session_start", (event, ctx) =>
    emit("session_start", { session_file: sessionFile(ctx), prompt: event?.prompt, text: event?.text }),
  );
  on("before_agent_start", (event, ctx) =>
    emit("before_agent_start", { session_file: sessionFile(ctx), prompt: event?.prompt }),
  );
  on("agent_start", (event, ctx) =>
    emit("agent_start", { session_file: sessionFile(ctx), prompt: event?.prompt }),
  );

  // Assistant messages.
  on("message_update", (event, ctx) =>
    emit("message_update", { text: messageText(event), session_file: sessionFile(ctx) }),
  );
  on("message_end", (event, ctx) =>
    emit("message_end", { text: messageText(event), session_file: sessionFile(ctx) }),
  );

  // Tool execution (observability-only events — never the blocking tool_call).
  on("tool_execution_start", (event, ctx) =>
    emit("tool_execution_start", { toolName: toolName(event), input: toolInput(event), session_file: sessionFile(ctx) }),
  );
  on("tool_execution_end", (event, ctx) =>
    emit("tool_execution_end", { toolName: toolName(event) }),
  );

  // Prompt-the-user gate, if omp surfaces it (harmless when never fired).
  on("waiting_for_user", (event, ctx) =>
    emit("waiting_for_user", { prompt: event?.prompt ?? event?.summary, toolName: toolName(event), session_file: sessionFile(ctx) }),
  );

  // Turn / session end.
  on("agent_end", (event, ctx) =>
    emit("agent_end", { text: messageText(event), session_file: sessionFile(ctx) }),
  );
  on("session_shutdown", () => emit("session_shutdown", {}));
}
