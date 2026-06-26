import { promises as fs } from "node:fs"
import { dirname } from "node:path"

const schema = "questmaster-opencode-spike/v0"
const eventsPath = process.env.QUESTMASTER_OPENCODE_SPIKE_EVENTS || ""
const statePath = process.env.QUESTMASTER_OPENCODE_SPIKE_STATE || ""
const qmSession = process.env.QUESTMASTER_SESSION || ""

let lastSessionID = ""
let currentState = {
  schema,
  questmaster_session: qmSession,
  opencode_session_id: "",
  state: "starting",
  activity: "Plugin loaded",
  last_event_type: "questmaster.plugin.loaded",
  updated_at: new Date().toISOString(),
}
let eventQueue = Promise.resolve()
let stateQueue = Promise.resolve()

function queueAppend(record) {
  if (!eventsPath) return
  eventQueue = eventQueue
    .then(async () => {
      await fs.mkdir(dirname(eventsPath), { recursive: true })
      await fs.appendFile(eventsPath, JSON.stringify(record) + "\n")
    })
    .catch(() => {})
}

function queueState(patch) {
  if (!statePath) return
  currentState = { ...currentState, ...patch }
  if (lastSessionID && !currentState.opencode_session_id) {
    currentState.opencode_session_id = lastSessionID
  }
  const snapshot = { ...currentState }
  stateQueue = stateQueue
    .then(async () => {
      await fs.mkdir(dirname(statePath), { recursive: true })
      await fs.writeFile(statePath, JSON.stringify(snapshot, null, 2) + "\n")
    })
    .catch(() => {})
}

function jsonSafe(value) {
  try {
    return JSON.parse(JSON.stringify(value))
  } catch {
    return String(value)
  }
}

function compactText(value, max = 120) {
  if (value == null) return ""
  const text = String(value).replace(/\s+/g, " ").trim()
  if (text.length <= max) return text
  return text.slice(0, max - 1) + "..."
}

function isObject(value) {
  return value !== null && typeof value === "object"
}

function objectValue(value) {
  return isObject(value) ? value : {}
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value !== "") return value
  }
  return ""
}

const sessionIDKeys = ["sessionID", "sessionId", "session_id"]

function indexedString(value, key) {
  return typeof value[key] === "string" ? value[key] : ""
}

function directSessionID(value) {
  return firstString(
    ...sessionIDKeys.map((key) => indexedString(value, key)),
    value.info?.id,
    value.session?.id,
  )
}

function isSearchable(item, seen) {
  if (!isObject(item.value)) return false
  if (item.depth > 8) return false
  return !seen.has(item.value)
}

function enqueueChildren(queue, value, depth) {
  for (const child of Object.values(value)) {
    queue.push({ value: child, depth })
  }
}

function findSessionID(value) {
  const seen = new Set()
  const queue = [{ value, depth: 0 }]

  for (let index = 0; index < queue.length; index += 1) {
    const item = queue[index]
    const current = item.value
    if (!isSearchable(item, seen)) continue
    seen.add(current)

    const found = directSessionID(current)
    if (found) return found

    enqueueChildren(queue, current, item.depth + 1)
  }
  return ""
}

function permissionLabel(event) {
  const props = objectValue(event.properties)
  const permission = objectValue(props.permission || props.request)
  return compactText(
    firstString(
      permission.id,
      permission.type,
      permission.tool,
      props.tool,
      props.id,
      "permission",
    ),
  )
}

function toolLabel(event) {
  const props = objectValue(event.properties)
  const call = objectValue(props.call || props.toolCall)
  return compactText(firstString(props.tool, props.name, call.tool, call.name, "tool"))
}

function errorLabel(event) {
  const props = objectValue(event.properties)
  const error = objectValue(props.error)
  return compactText(
    firstString(
      error.data?.message,
      error.message,
      props.message,
      props.error,
      "session.error",
    ),
  )
}

function statusPatch(props) {
  const statusType = props.status?.type
  if (statusType === "busy") return { state: "working" }
  if (statusType === "idle") return { state: "idle" }
  return {}
}

function textPartPatch(props) {
  const part = objectValue(props.part)
  if (part.type === "text" && part.text) {
    return { activity: "Assistant: " + compactText(part.text) }
  }
  return {}
}

const eventPatches = {
  "session.created": () => ({ state: "starting", activity: "Session created" }),
  "session.status": statusPatch,
  "session.idle": () => ({ state: "idle" }),
  "session.error": (_props, event) => ({ state: "error", activity: "Error: " + errorLabel(event) }),
  "permission.asked": (_props, event) => ({
    state: "needs_input",
    activity: "Permission: " + permissionLabel(event),
  }),
  "permission.replied": () => ({ state: "working", activity: "Permission replied" }),
  "tool.execute.before": (_props, event) => ({
    state: "working",
    activity: "Tool: " + toolLabel(event),
  }),
  "tool.execute.after": (_props, event) => ({ activity: "Tool done: " + toolLabel(event) }),
  "message.part.updated": textPartPatch,
}

function patchForEvent(event) {
  const safeEvent = objectValue(event)
  const type = safeEvent.type || "unknown"
  const props = objectValue(safeEvent.properties)
  const patcher = eventPatches[type]

  return {
    last_event_type: type,
    last_event_id: safeEvent.id || "",
    ...(patcher ? patcher(props, safeEvent) : {}),
  }
}

function recordLoaded(ctx) {
  const at = new Date().toISOString()
  const record = {
    schema,
    kind: "questmaster.plugin.loaded",
    captured_at: at,
    questmaster_session: qmSession,
    env: {
      questmaster_session_present: qmSession !== "",
      events_path_present: eventsPath !== "",
      state_path_present: statePath !== "",
    },
    context: {
      directory: ctx.directory || "",
      worktree: ctx.worktree || "",
      project: jsonSafe(ctx.project || null),
    },
  }
  queueAppend(record)
  queueState({ updated_at: at })
}

function recordEvent(event) {
  const at = new Date().toISOString()
  const sessionID = findSessionID(event) || lastSessionID
  if (sessionID) lastSessionID = sessionID

  queueAppend({
    schema,
    kind: "opencode.event",
    captured_at: at,
    questmaster_session: qmSession,
    opencode_session_id: sessionID,
    event: jsonSafe(event),
  })

  queueState({
    ...patchForEvent(event || {}),
    updated_at: at,
    opencode_session_id: sessionID,
  })
}

export const QuestmasterSpike = async (ctx) => {
  recordLoaded(ctx)
  return {
    event: async ({ event }) => {
      recordEvent(event)
    },
  }
}

globalThis.__questmasterSpikeFlushForTests = async () => {
  await eventQueue
  await stateQueue
}
