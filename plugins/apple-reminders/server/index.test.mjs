import assert from "node:assert/strict";
import test from "node:test";
import {
  createRuntime,
  filterAndPageReminders,
  handleMessage,
  tools,
  validateToolArgs,
} from "./index.mjs";

const reminders = [
  {
    id: "a",
    title: "Alpha",
    notes: "project",
    completed: false,
    priority: 1,
    due: { date: "2026-08-20", allDay: true },
    alarms: [{ type: "absolute", at: "2026-08-20T01:00:00Z" }],
    recurrenceRules: [],
    createdAt: "2026-08-01T00:00:00Z",
    modifiedAt: "2026-08-10T00:00:00Z",
  },
  {
    id: "b",
    title: "Beta",
    location: "Office",
    completed: true,
    priority: 5,
    completedAt: "2026-08-19T03:00:00Z",
    due: { dateTime: "2026-08-21T09:00:00Z", allDay: false },
    alarms: [],
    recurrenceRules: [{ frequency: "weekly", interval: 1 }],
    createdAt: "2026-08-02T00:00:00Z",
    modifiedAt: "2026-08-11T00:00:00Z",
  },
  {
    id: "c",
    title: "Gamma",
    completed: false,
    priority: 9,
    alarms: [],
    recurrenceRules: [],
    createdAt: "2026-08-03T00:00:00Z",
    modifiedAt: "2026-08-12T00:00:00Z",
  },
];

test("tool surface keeps all legacy tools and adds the planned tools", () => {
  const names = new Set(tools.map((tool) => tool.name));
  for (const name of [
    "list_reminder_lists",
    "list_reminders",
    "create_reminder",
    "update_reminder",
    "set_reminder_completed",
    "delete_reminder",
    "get_reminder",
    "list_reminder_sources",
    "create_reminder_list",
    "update_reminder_list",
    "preview_delete_reminder_list",
    "delete_reminder_list",
    "bulk_set_reminders_completed",
    "bulk_move_reminders",
    "preview_delete_reminders",
    "delete_reminders",
  ]) assert.ok(names.has(name), `missing tool ${name}`);
});

test("legacy list behavior defaults to incomplete and returns an array", () => {
  const result = filterAndPageReminders(reminders, {});
  assert.deepEqual(result.map((item) => item.id), ["a", "c"]);
  assert.ok(Array.isArray(result));
  assert.equal(filterAndPageReminders(reminders, { include_completed: true }).length, 3);
});

test("status, search, date, feature, sorting, and pagination filters compose", () => {
  const result = filterAndPageReminders(reminders, {
    status: "all",
    due_from: "2026-08-20",
    due_to: "2026-08-21",
    has_alarm: false,
    search: "office",
    sort: "title",
    order: "desc",
    offset: 0,
    limit: 1,
  });
  assert.equal(result.total, 1);
  assert.equal(result.items[0].id, "b");
  assert.equal(result.nextOffset, null);
  assert.throws(() => filterAndPageReminders(reminders, { due_from: "2026-02-30" }), /Invalid date/);
});

test("validation preserves single-delete confirmation and rejects unsafe batches", () => {
  assert.throws(() => validateToolArgs("delete_reminder", { id: "a", confirm: false }), /confirm=true/);
  assert.doesNotThrow(() => validateToolArgs("delete_reminder", { id: "a", confirm: true }));
  assert.throws(() => validateToolArgs("preview_delete_reminders", { ids: ["a", "a"] }), /duplicates/);
  assert.throws(() => validateToolArgs("bulk_move_reminders", { ids: ["a"] }), /list_id or list/);
});

test("delete tokens are snapshot-bound, one-time, and expire after five minutes", async () => {
  let clock = Date.parse("2026-08-20T00:00:00Z");
  let snapshots = [{ id: "a", modifiedAt: "2026-08-10T00:00:00Z", listId: "work" }];
  const calls = [];
  const runHelper = async (action, args) => {
    calls.push({ action, args });
    if (action === "inspect_reminders_delete") {
      return { items: [{ id: "a", title: "Alpha", list: "Work" }], snapshots };
    }
    if (action === "delete_reminders") return { deleted: ["a"] };
    throw new Error(`unexpected action ${action}`);
  };
  const runtime = createRuntime({ runHelper, now: () => clock, uuid: () => "token-1" });
  const preview = await runtime.callTool("preview_delete_reminders", { ids: ["a"] });
  assert.equal(preview.confirmationToken, "token-1");
  assert.deepEqual(await runtime.callTool("delete_reminders", { confirmation_token: "token-1" }), { deleted: ["a"] });
  await assert.rejects(runtime.callTool("delete_reminders", { confirmation_token: "token-1" }), /invalid/);

  const expiring = createRuntime({ runHelper, now: () => clock, uuid: () => "token-2" });
  await expiring.callTool("preview_delete_reminders", { ids: ["a"] });
  clock += 5 * 60 * 1000;
  await assert.rejects(expiring.callTool("delete_reminders", { confirmation_token: "token-2" }), /expired/);

  clock = Date.parse("2026-08-20T00:00:00Z");
  const stale = createRuntime({ runHelper, now: () => clock, uuid: () => "token-3" });
  await stale.callTool("preview_delete_reminders", { ids: ["a"] });
  snapshots = [{ id: "a", modifiedAt: "2026-08-20T00:00:01Z", listId: "work" }];
  await assert.rejects(stale.callTool("delete_reminders", { confirmation_token: "token-3" }), /changed/);
});

test("MCP handler reports contract errors as tool errors", async () => {
  const runtime = createRuntime({ runHelper: async () => [] });
  const response = await handleMessage({
    jsonrpc: "2.0",
    id: 7,
    method: "tools/call",
    params: { name: "get_reminder", arguments: {} },
  }, runtime);
  assert.equal(response.result.isError, true);
  assert.match(response.result.content[0].text, /id or external_id/);
});
