import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const pluginRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const defaultHelperPath = path.join(pluginRoot, "native", "build", "reminders-helper");
const confirmationTtlMs = 5 * 60 * 1000;
const maxBatchSize = 500;

const dateProperty = {
  type: "string",
  description: "YYYY-MM-DD for an all-day value, or an RFC 3339 timestamp for a specific time.",
};

const alarmSchema = {
  type: "object",
  required: ["type"],
  properties: {
    type: { type: "string", enum: ["absolute", "relative", "location"] },
    at: { type: "string", description: "RFC 3339 timestamp for an absolute alarm." },
    offset_seconds: { type: "number", description: "Signed offset from the reminder start/due date." },
    proximity: { type: "string", enum: ["enter", "leave"] },
    title: { type: "string" },
    latitude: { type: "number", minimum: -90, maximum: 90 },
    longitude: { type: "number", minimum: -180, maximum: 180 },
    radius_m: { type: "number", minimum: 0 },
  },
  additionalProperties: false,
};

const recurrenceSchema = {
  type: "object",
  required: ["frequency"],
  properties: {
    frequency: { type: "string", enum: ["daily", "weekly", "monthly", "yearly"] },
    interval: { type: "integer", minimum: 1, default: 1 },
    days_of_week: {
      type: "array",
      items: {
        type: "object",
        required: ["day"],
        properties: {
          day: { type: "string", enum: ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"] },
          week_number: { type: "integer", minimum: -53, maximum: 53 },
        },
        additionalProperties: false,
      },
    },
    days_of_month: { type: "array", items: { type: "integer", minimum: -31, maximum: 31 } },
    months_of_year: { type: "array", items: { type: "integer", minimum: 1, maximum: 12 } },
    weeks_of_year: { type: "array", items: { type: "integer", minimum: -53, maximum: 53 } },
    days_of_year: { type: "array", items: { type: "integer", minimum: -366, maximum: 366 } },
    set_positions: { type: "array", items: { type: "integer", minimum: -366, maximum: 366 } },
    end: {
      type: "object",
      properties: { date: dateProperty, count: { type: "integer", minimum: 1 } },
      additionalProperties: false,
    },
  },
  additionalProperties: false,
};

const identityProperties = {
  id: { type: "string", description: "EventKit reminder identifier." },
  external_id: { type: "string", description: "Sync-oriented external identifier used if the normal id changed." },
  list_id: { type: "string", description: "Disambiguates an external identifier when necessary." },
  current_list_id: { type: "string", description: "Disambiguates external_id when update_reminder also uses list_id as the destination." },
};

const writableReminderProperties = {
  title: { type: "string", minLength: 1 },
  list: { type: "string", description: "Exact list name. Uses the default list when omitted on create." },
  list_id: { type: "string", description: "Preferred stable list selector; takes precedence over list." },
  notes: { type: "string" },
  location: { type: "string" },
  url: { type: "string", description: "Absolute URL." },
  start: dateProperty,
  due: dateProperty,
  timezone: { type: "string", description: "IANA timezone, for example Asia/Shanghai." },
  priority: { type: "integer", minimum: 0, maximum: 9 },
  alarms: { type: "array", items: alarmSchema },
  recurrence_rules: { type: "array", items: recurrenceSchema },
};

export const tools = [
  {
    name: "list_reminder_lists",
    description: "List Apple Reminders lists with stable ids, account sources, colors, and write capabilities. Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "list_reminder_sources",
    description: "List accounts/sources that provide reminder lists. Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "list_reminders",
    description: "List, search, filter, sort, and optionally page Apple Reminders. Defaults to unfinished reminders only. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string", description: "Exact reminder list name." },
        list_id: { type: "string" },
        include_completed: { type: "boolean", default: false, description: "Legacy option; status takes precedence when supplied." },
        status: { type: "string", enum: ["incomplete", "completed", "all"] },
        search: { type: "string", description: "Case-insensitive title/notes/location match." },
        due_from: dateProperty,
        due_to: dateProperty,
        completion_from: dateProperty,
        completion_to: dateProperty,
        priority_min: { type: "integer", minimum: 0, maximum: 9 },
        priority_max: { type: "integer", minimum: 0, maximum: 9 },
        has_due: { type: "boolean" },
        has_alarm: { type: "boolean" },
        has_recurrence: { type: "boolean" },
        sort: { type: "string", enum: ["due", "title", "created", "modified", "completed", "priority"] },
        order: { type: "string", enum: ["asc", "desc"] },
        limit: { type: "integer", minimum: 1, maximum: 500 },
        offset: { type: "integer", minimum: 0 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_reminder",
    description: "Get one reminder with all EventKit-exposed details. Read-only. Supply id or external_id.",
    inputSchema: { type: "object", properties: identityProperties, additionalProperties: false },
  },
  {
    name: "create_reminder",
    description: "Create an Apple Reminder after an explicit user request. Dates must be absolute.",
    inputSchema: { type: "object", required: ["title"], properties: writableReminderProperties, additionalProperties: false },
  },
  {
    name: "update_reminder",
    description: "Update an existing reminder after an explicit user request. Pass only fields that should change.",
    inputSchema: {
      type: "object",
      properties: {
        ...identityProperties,
        ...writableReminderProperties,
        clear_notes: { type: "boolean", default: false },
        clear_location: { type: "boolean", default: false },
        clear_url: { type: "boolean", default: false },
        clear_start: { type: "boolean", default: false },
        clear_due: { type: "boolean", default: false },
        clear_alarms: { type: "boolean", default: false },
        clear_recurrence: { type: "boolean", default: false },
      },
      additionalProperties: false,
    },
  },
  {
    name: "set_reminder_completed",
    description: "Mark a reminder completed or incomplete after an explicit user request.",
    inputSchema: { type: "object", required: ["completed"], properties: { ...identityProperties, completed: { type: "boolean" } }, additionalProperties: false },
  },
  {
    name: "delete_reminder",
    description: "Permanently delete one reminder. Backward-compatible single-item deletion requires confirm=true.",
    inputSchema: { type: "object", required: ["confirm"], properties: { ...identityProperties, confirm: { type: "boolean", const: true } }, additionalProperties: false },
  },
  {
    name: "create_reminder_list",
    description: "Create a reminder list after an explicit request. Uses the default reminder account unless source_id is supplied.",
    inputSchema: {
      type: "object",
      required: ["name"],
      properties: { name: { type: "string", minLength: 1 }, source_id: { type: "string" }, color: { type: "string", pattern: "^#[0-9A-Fa-f]{6}$" } },
      additionalProperties: false,
    },
  },
  {
    name: "update_reminder_list",
    description: "Rename or recolor a writable reminder list after an explicit request.",
    inputSchema: {
      type: "object",
      properties: { list_id: { type: "string" }, list: { type: "string" }, name: { type: "string", minLength: 1 }, color: { type: "string", pattern: "^#[0-9A-Fa-f]{6}$" } },
      additionalProperties: false,
    },
  },
  {
    name: "preview_delete_reminder_list",
    description: "Preview deletion of a reminder-only list and receive a five-minute one-time confirmation token. Read-only.",
    inputSchema: { type: "object", properties: { list_id: { type: "string" }, list: { type: "string" } }, additionalProperties: false },
  },
  {
    name: "delete_reminder_list",
    description: "Delete a reminder-only list using the unexpired token returned by preview_delete_reminder_list.",
    inputSchema: { type: "object", required: ["confirmation_token"], properties: { confirmation_token: { type: "string" } }, additionalProperties: false },
  },
  {
    name: "bulk_set_reminders_completed",
    description: "Atomically mark up to 500 reminders complete or incomplete after an explicit request.",
    inputSchema: { type: "object", required: ["ids", "completed"], properties: { ids: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 500 }, completed: { type: "boolean" } }, additionalProperties: false },
  },
  {
    name: "bulk_move_reminders",
    description: "Atomically move up to 500 reminders to a writable list after an explicit request.",
    inputSchema: { type: "object", required: ["ids"], properties: { ids: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 500 }, list_id: { type: "string" }, list: { type: "string" } }, additionalProperties: false },
  },
  {
    name: "preview_delete_reminders",
    description: "Preview permanent deletion of up to 500 reminders and receive a five-minute one-time confirmation token. Read-only.",
    inputSchema: { type: "object", required: ["ids"], properties: { ids: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 500 } }, additionalProperties: false },
  },
  {
    name: "delete_reminders",
    description: "Permanently delete the exact unchanged reminders bound to a token from preview_delete_reminders.",
    inputSchema: { type: "object", required: ["confirmation_token"], properties: { confirmation_token: { type: "string" } }, additionalProperties: false },
  },
];

function fail(message) { throw new Error(message); }
function nonEmptyString(value) { return typeof value === "string" && value.trim().length > 0; }
function assertObject(args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) fail("Arguments must be a JSON object.");
}
function assertIdentity(args) {
  if (!nonEmptyString(args.id) && !nonEmptyString(args.external_id)) fail("Provide id or external_id.");
}
function assertListSelector(args) {
  if (!nonEmptyString(args.list_id) && !nonEmptyString(args.list)) fail("Provide list_id or list.");
}
function uniqueIds(value) {
  if (!Array.isArray(value) || value.length === 0) fail("ids must be a non-empty array.");
  if (value.length > maxBatchSize) fail(`A batch may contain at most ${maxBatchSize} reminders.`);
  if (value.some((id) => !nonEmptyString(id))) fail("Every reminder id must be a non-empty string.");
  const ids = [...new Set(value)];
  if (ids.length !== value.length) fail("ids must not contain duplicates.");
  return ids;
}

export function validateToolArgs(name, args = {}) {
  assertObject(args);
  switch (name) {
    case "get_reminder":
    case "update_reminder":
    case "set_reminder_completed":
    case "delete_reminder":
      assertIdentity(args);
      break;
    case "create_reminder":
      if (!nonEmptyString(args.title)) fail("title is required.");
      break;
    case "create_reminder_list":
      if (!nonEmptyString(args.name)) fail("name is required.");
      break;
    case "update_reminder_list":
    case "preview_delete_reminder_list":
      assertListSelector(args);
      break;
    case "bulk_set_reminders_completed":
      args.ids = uniqueIds(args.ids);
      if (typeof args.completed !== "boolean") fail("completed must be true or false.");
      break;
    case "bulk_move_reminders":
      args.ids = uniqueIds(args.ids);
      assertListSelector(args);
      break;
    case "preview_delete_reminders":
      args.ids = uniqueIds(args.ids);
      break;
    case "delete_reminder_list":
    case "delete_reminders":
      if (!nonEmptyString(args.confirmation_token)) fail("confirmation_token is required.");
      break;
    default:
      break;
  }
  if (name === "delete_reminder" && args.confirm !== true) fail("Single-reminder deletion requires confirm=true.");
  if (args.limit !== undefined && (!Number.isInteger(args.limit) || args.limit < 1 || args.limit > 500)) fail("limit must be an integer from 1 to 500.");
  if (args.offset !== undefined && (!Number.isInteger(args.offset) || args.offset < 0)) fail("offset must be a non-negative integer.");
  return args;
}

function parseBoundary(raw, upper = false) {
  if (raw === undefined) return undefined;
  if (!nonEmptyString(raw)) fail("Date filters must be YYYY-MM-DD or RFC 3339 strings.");
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    const value = Date.parse(`${raw}T00:00:00.000Z`);
    const roundTrip = Number.isFinite(value) ? new Date(value).toISOString().slice(0, 10) : "";
    if (roundTrip !== raw) fail(`Invalid date filter: ${raw}`);
    return upper ? value + 86_400_000 - 1 : value;
  }
  const value = Date.parse(raw);
  if (!Number.isFinite(value)) fail(`Invalid date filter: ${raw}`);
  return value;
}

function reminderDate(reminder, field) {
  if (field === "due") {
    if (reminder.due?.dateTime) return Date.parse(reminder.due.dateTime);
    if (reminder.due?.date) return Date.parse(`${reminder.due.date}T00:00:00.000Z`);
    return undefined;
  }
  const raw = reminder[field];
  return raw ? Date.parse(raw) : undefined;
}

function compareOptional(a, b) {
  if (a === undefined && b === undefined) return 0;
  if (a === undefined) return 1;
  if (b === undefined) return -1;
  return a < b ? -1 : a > b ? 1 : 0;
}

export function filterAndPageReminders(reminders, args = {}) {
  const status = args.status ?? (args.include_completed === true ? "all" : "incomplete");
  const dueFrom = parseBoundary(args.due_from);
  const dueTo = parseBoundary(args.due_to, true);
  const completionFrom = parseBoundary(args.completion_from);
  const completionTo = parseBoundary(args.completion_to, true);
  const search = typeof args.search === "string" ? args.search.toLocaleLowerCase() : "";

  let result = reminders.filter((reminder) => {
    if (status === "incomplete" && reminder.completed) return false;
    if (status === "completed" && !reminder.completed) return false;
    if (search) {
      const haystack = [reminder.title, reminder.notes, reminder.location].filter(Boolean).join("\n").toLocaleLowerCase();
      if (!haystack.includes(search)) return false;
    }
    const due = reminderDate(reminder, "due");
    const completed = reminderDate(reminder, "completedAt");
    if (dueFrom !== undefined && (due === undefined || due < dueFrom)) return false;
    if (dueTo !== undefined && (due === undefined || due > dueTo)) return false;
    if (completionFrom !== undefined && (completed === undefined || completed < completionFrom)) return false;
    if (completionTo !== undefined && (completed === undefined || completed > completionTo)) return false;
    if (args.priority_min !== undefined && reminder.priority < args.priority_min) return false;
    if (args.priority_max !== undefined && reminder.priority > args.priority_max) return false;
    if (args.has_due !== undefined && Boolean(reminder.due) !== args.has_due) return false;
    if (args.has_alarm !== undefined && Boolean(reminder.alarms?.length) !== args.has_alarm) return false;
    if (args.has_recurrence !== undefined && Boolean(reminder.recurrenceRules?.length) !== args.has_recurrence) return false;
    return true;
  });

  const sort = args.sort ?? "due";
  const direction = args.order === "desc" ? -1 : 1;
  result.sort((left, right) => {
    let order = 0;
    if (sort === "title") order = left.title.localeCompare(right.title, undefined, { sensitivity: "base" });
    else if (sort === "priority") order = compareOptional(left.priority, right.priority);
    else if (sort === "created") order = compareOptional(reminderDate(left, "createdAt"), reminderDate(right, "createdAt"));
    else if (sort === "modified") order = compareOptional(reminderDate(left, "modifiedAt"), reminderDate(right, "modifiedAt"));
    else if (sort === "completed") order = compareOptional(reminderDate(left, "completedAt"), reminderDate(right, "completedAt"));
    else order = compareOptional(reminderDate(left, "due"), reminderDate(right, "due"));
    if (order === 0) order = left.title.localeCompare(right.title, undefined, { sensitivity: "base" });
    return order * direction;
  });

  if (args.limit === undefined && args.offset === undefined) return result;
  const offset = args.offset ?? 0;
  const limit = args.limit ?? 100;
  const items = result.slice(offset, offset + limit);
  return { items, total: result.length, offset, limit, nextOffset: offset + items.length < result.length ? offset + items.length : null };
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

export function createRuntime({ runHelper = runNativeHelper, now = () => Date.now(), uuid = randomUUID } = {}) {
  const confirmations = new Map();
  function issueConfirmation(type, preview, target) {
    const token = uuid();
    const expiresAtMs = now() + confirmationTtlMs;
    confirmations.set(token, { type, target, fingerprint: stableJSON(preview.snapshots), expiresAtMs });
    return { ...preview, confirmationToken: token, expiresAt: new Date(expiresAtMs).toISOString() };
  }
  function takeConfirmation(token, type) {
    const record = confirmations.get(token);
    if (!record || record.type !== type) fail("Confirmation token is invalid or belongs to another operation.");
    confirmations.delete(token);
    if (record.expiresAtMs <= now()) fail("Confirmation token expired. Preview the deletion again.");
    return record;
  }
  return {
    async callTool(name, rawArgs = {}) {
      const args = validateToolArgs(name, { ...rawArgs });
      switch (name) {
        case "list_reminder_lists": return runHelper("list_lists", args);
        case "list_reminder_sources": return runHelper("list_sources", args);
        case "list_reminders": {
          const reminders = await runHelper("list_reminders", { list: args.list, list_id: args.list_id, include_completed: true });
          return filterAndPageReminders(reminders, args);
        }
        case "get_reminder": return runHelper("get_reminder", args);
        case "create_reminder": return runHelper("create_reminder", args);
        case "update_reminder": return runHelper("update_reminder", args);
        case "set_reminder_completed": return runHelper("set_completed", args);
        case "delete_reminder": return runHelper("delete_reminder", args);
        case "create_reminder_list": return runHelper("create_list", args);
        case "update_reminder_list": return runHelper("update_list", args);
        case "bulk_set_reminders_completed": return runHelper("bulk_set_completed", args);
        case "bulk_move_reminders": return runHelper("bulk_move", args);
        case "preview_delete_reminder_list": {
          const preview = await runHelper("inspect_list_delete", args);
          return issueConfirmation("delete_list", preview, { list_id: preview.list.id });
        }
        case "delete_reminder_list": {
          const record = takeConfirmation(args.confirmation_token, "delete_list");
          const current = await runHelper("inspect_list_delete", record.target);
          if (stableJSON(current.snapshots) !== record.fingerprint) fail("The list or its reminders changed after preview. Preview the deletion again.");
          return runHelper("delete_list", { ...record.target, expected_snapshots: current.snapshots });
        }
        case "preview_delete_reminders": {
          const preview = await runHelper("inspect_reminders_delete", { ids: args.ids });
          return issueConfirmation("delete_reminders", preview, { ids: args.ids });
        }
        case "delete_reminders": {
          const record = takeConfirmation(args.confirmation_token, "delete_reminders");
          const current = await runHelper("inspect_reminders_delete", record.target);
          if (stableJSON(current.snapshots) !== record.fingerprint) fail("One or more reminders changed after preview. Preview the deletion again.");
          return runHelper("delete_reminders", { ...record.target, expected_snapshots: current.snapshots });
        }
        default: throw new Error(`Unknown tool: ${name}`);
      }
    },
  };
}

export function runNativeHelper(action, args = {}) {
  return new Promise((resolve, reject) => {
    const helperPath = process.env.APPLE_REMINDERS_HELPER_PATH || defaultHelperPath;
    const child = spawn(helperPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("Reminders helper timed out after 120 seconds."));
    }, 120_000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer);
      let payload;
      try { payload = JSON.parse(stdout.trim()); }
      catch { reject(new Error(stderr.trim() || stdout.trim() || `Helper exited with code ${code}.`)); return; }
      if (!payload.ok) { reject(new Error(payload.error || stderr.trim() || "Apple Reminders operation failed.")); return; }
      resolve(payload.data);
    });
    child.stdin.end(JSON.stringify({ action, ...args }));
  });
}

function toolResult(value, isError = false) {
  return { content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }], isError };
}

export async function handleMessage(message, runtime) {
  if (!message || message.jsonrpc !== "2.0" || message.id === undefined) return null;
  if (message.method === "initialize") {
    return { jsonrpc: "2.0", id: message.id, result: { protocolVersion: message.params?.protocolVersion || "2025-06-18", capabilities: { tools: { listChanged: false } }, serverInfo: { name: "apple-reminders", version: "0.2.0" } } };
  }
  if (message.method === "ping" || message.method === "logging/setLevel") return { jsonrpc: "2.0", id: message.id, result: {} };
  if (message.method === "tools/list") return { jsonrpc: "2.0", id: message.id, result: { tools } };
  if (message.method === "tools/call") {
    try { return { jsonrpc: "2.0", id: message.id, result: toolResult(await runtime.callTool(message.params?.name, message.params?.arguments || {})) }; }
    catch (error) { return { jsonrpc: "2.0", id: message.id, result: toolResult(error instanceof Error ? error.message : String(error), true) }; }
  }
  return { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } };
}

export function startServer(runtime = createRuntime()) {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on("line", (line) => {
    if (!line.trim()) return;
    let message;
    try { message = JSON.parse(line); }
    catch (error) { process.stderr.write(`Invalid MCP message: ${error instanceof Error ? error.message : String(error)}\n`); return; }
    void handleMessage(message, runtime).then((response) => {
      if (response) process.stdout.write(`${JSON.stringify(response)}\n`);
    });
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) startServer();
