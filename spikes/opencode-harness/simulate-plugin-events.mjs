#!/usr/bin/env bun

import { mkdir, rm } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const outDir = resolve(process.argv[2] || `${here}/fixtures/generated-simulated`)

process.env.QUESTMASTER_SESSION = process.env.QUESTMASTER_SESSION || "qm-opencode-spike"
process.env.QUESTMASTER_OPENCODE_SPIKE_EVENTS = `${outDir}/simulated-events.ndjson`
process.env.QUESTMASTER_OPENCODE_SPIKE_STATE = `${outDir}/simulated-state.json`

await rm(outDir, { recursive: true, force: true })
await mkdir(outDir, { recursive: true })

const { QuestmasterSpike } = await import("./questmaster-spike-plugin.js")

const plugin = await QuestmasterSpike({
  directory: "/tmp/questmaster-opencode-spike/project",
  worktree: "/tmp/questmaster-opencode-spike/project",
  project: {
    id: "questmaster-opencode-spike",
    worktree: "/tmp/questmaster-opencode-spike/project",
  },
})

const sessionID = "ses_phase0simulated000000000001"
const events = [
  {
    id: "evt_sim_session_created",
    type: "session.created",
    properties: {
      sessionID,
      info: {
        id: sessionID,
        version: "1.17.11",
        title: "Questmaster OpenCode spike",
        agent: "questmaster-spike",
      },
    },
  },
  {
    id: "evt_sim_status_busy",
    type: "session.status",
    properties: {
      sessionID,
      status: { type: "busy" },
    },
  },
  {
    id: "evt_sim_user_message",
    type: "message.updated",
    properties: {
      sessionID,
      info: {
        id: "msg_sim_user",
        sessionID,
        role: "user",
        agent: "questmaster-spike",
      },
    },
  },
  {
    id: "evt_sim_tool_before",
    type: "tool.execute.before",
    properties: {
      sessionID,
      tool: "bash",
      callID: "call_sim_bash",
    },
  },
  {
    id: "evt_sim_permission_asked",
    type: "permission.asked",
    properties: {
      sessionID,
      permission: {
        id: "perm_sim_bash",
        tool: "bash",
      },
    },
  },
  {
    id: "evt_sim_permission_replied",
    type: "permission.replied",
    properties: {
      sessionID,
      permission: {
        id: "perm_sim_bash",
        action: "allow",
      },
    },
  },
  {
    id: "evt_sim_tool_after",
    type: "tool.execute.after",
    properties: {
      sessionID,
      tool: "bash",
      callID: "call_sim_bash",
      error: null,
    },
  },
  {
    id: "evt_sim_text",
    type: "message.part.updated",
    properties: {
      sessionID,
      part: {
        id: "part_sim_text",
        messageID: "msg_sim_assistant",
        sessionID,
        type: "text",
        text: "QM_SPIKE_OK",
      },
    },
  },
  {
    id: "evt_sim_status_idle",
    type: "session.status",
    properties: {
      sessionID,
      status: { type: "idle" },
    },
  },
  {
    id: "evt_sim_idle",
    type: "session.idle",
    properties: {
      sessionID,
    },
  },
  {
    id: "evt_sim_error",
    type: "session.error",
    properties: {
      sessionID,
      message: "simulated provider error",
    },
  },
]

for (const event of events) {
  await plugin.event({ event })
}
await globalThis.__questmasterSpikeFlushForTests()

console.log(`wrote ${process.env.QUESTMASTER_OPENCODE_SPIKE_EVENTS}`)
console.log(`wrote ${process.env.QUESTMASTER_OPENCODE_SPIKE_STATE}`)
