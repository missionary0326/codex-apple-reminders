import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";

const pluginRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helperPath = path.join(pluginRoot, "native", "build", "reminders-helper");

const tools = [
  {
    name: "list_reminder_lists",
    description: "List Apple Reminders lists available on this Mac. This is read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "list_reminders",
    description: "List or search Apple Reminders. Defaults to unfinished reminders only. This is read-only.",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string", description: "Exact reminder list name, such as 工作." },
        include_completed: { type: "boolean", default: false },
        search: { type: "string", description: "Case-insensitive text to match in title or notes." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "create_reminder",
    description: "Create an Apple Reminder after the user explicitly asks for it. Use an absolute date (YYYY-MM-DD) or RFC 3339 timestamp; resolve relative dates before calling.",
    inputSchema: {
      type: "object",
      required: ["title"],
      properties: {
        title: { type: "string", minLength: 1 },
        list: { type: "string", description: "Exact list name. Uses the default Reminders list when omitted." },
        notes: { type: "string" },
        due: { type: "string", description: "YYYY-MM-DD for all-day, or RFC 3339 for a specific time." },
        timezone: { type: "string", description: "IANA timezone, for example Asia/Shanghai." },
        priority: { type: "integer", minimum: 0, maximum: 9, default: 0 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "update_reminder",
    description: "Update an existing reminder after the user explicitly asks. Pass only fields that should change.",
    inputSchema: {
      type: "object",
      required: ["id"],
      properties: {
        id: { type: "string", description: "Reminder identifier returned by list_reminders." },
        title: { type: "string", minLength: 1 },
        list: { type: "string" },
        notes: { type: "string" },
        due: { type: "string", description: "YYYY-MM-DD or RFC 3339." },
        timezone: { type: "string" },
        clear_due: { type: "boolean", default: false },
        priority: { type: "integer", minimum: 0, maximum: 9 },
      },
      additionalProperties: false,
    },
  },
  {
    name: "set_reminder_completed",
    description: "Mark a reminder completed or incomplete after the user explicitly asks.",
    inputSchema: {
      type: "object",
      required: ["id", "completed"],
      properties: {
        id: { type: "string" },
        completed: { type: "boolean" },
      },
      additionalProperties: false,
    },
  },
  {
    name: "delete_reminder",
    description: "Permanently delete a reminder. Only call after the user explicitly confirms deletion; confirm must be true.",
    inputSchema: {
      type: "object",
      required: ["id", "confirm"],
      properties: {
        id: { type: "string" },
        confirm: { type: "boolean", const: true },
      },
      additionalProperties: false,
    },
  },
];

function writeMessage(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function toolResult(value, isError = false) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
    isError,
  };
}

function runHelper(action, args = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(helperPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("Reminders helper timed out after 45 seconds."));
    }, 120_000);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      let payload;
      try {
        payload = JSON.parse(stdout.trim());
      } catch {
        reject(new Error(stderr.trim() || stdout.trim() || `Helper exited with code ${code}.`));
        return;
      }
      if (!payload.ok) {
        reject(new Error(payload.error || stderr.trim() || "Apple Reminders operation failed."));
        return;
      }
      resolve(payload.data);
    });

    child.stdin.end(JSON.stringify({ action, ...args }));
  });
}

async function callTool(name, args) {
  switch (name) {
    case "list_reminder_lists":
      return runHelper("list_lists");
    case "list_reminders":
      return runHelper("list_reminders", args);
    case "create_reminder":
      return runHelper("create_reminder", args);
    case "update_reminder":
      return runHelper("update_reminder", args);
    case "set_reminder_completed":
      return runHelper("set_completed", args);
    case "delete_reminder":
      if (args?.confirm !== true) throw new Error("Deletion requires explicit confirmation.");
      return runHelper("delete_reminder", args);
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function handle(message) {
  if (!message || message.jsonrpc !== "2.0") return;
  if (message.id === undefined) return;

  try {
    let result;
    switch (message.method) {
      case "initialize":
        result = {
          protocolVersion: message.params?.protocolVersion || "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "apple-reminders", version: "0.1.0" },
        };
        break;
      case "ping":
      case "logging/setLevel":
        result = {};
        break;
      case "tools/list":
        result = { tools };
        break;
      case "tools/call":
        try {
          result = toolResult(await callTool(message.params?.name, message.params?.arguments || {}));
        } catch (error) {
          result = toolResult(error instanceof Error ? error.message : String(error), true);
        }
        break;
      default:
        writeMessage({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } });
        return;
    }
    writeMessage({ jsonrpc: "2.0", id: message.id, result });
  } catch (error) {
    writeMessage({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32603, message: error instanceof Error ? error.message : String(error) },
    });
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  if (!line.trim()) return;
  try {
    void handle(JSON.parse(line));
  } catch (error) {
    process.stderr.write(`Invalid MCP message: ${error instanceof Error ? error.message : String(error)}\n`);
  }
});
