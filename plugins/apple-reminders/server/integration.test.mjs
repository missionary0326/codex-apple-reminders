import assert from "node:assert/strict";
import test from "node:test";
import { createRuntime, runNativeHelper } from "./index.mjs";

const enabled = process.env.APPLE_REMINDERS_INTEGRATION_TESTS === "1";

test("disposable EventKit list supports the complete write lifecycle", { skip: !enabled }, async () => {
  const runtime = createRuntime({ runHelper: runNativeHelper });
  const suffix = String(Date.now()) + "-" + process.pid;
  const sourceName = "Codex Plugin Test " + suffix;
  const destinationName = "Codex Plugin Test Destination " + suffix;
  const createdListIds = new Set();

  async function safelyDeleteList(listId) {
    try {
      const preview = await runtime.callTool("preview_delete_reminder_list", { list_id: listId });
      await runtime.callTool("delete_reminder_list", { confirmation_token: preview.confirmationToken });
    } catch {
      // Preserve the original test failure. Any leftover list is visibly test-prefixed.
    }
  }

  try {
    const sources = await runtime.callTool("list_reminder_sources", {});
    assert.ok(Array.isArray(sources));

    const source = await runtime.callTool("create_reminder_list", { name: sourceName, color: "#FF9500" });
    createdListIds.add(source.id);
    const destination = await runtime.callTool("create_reminder_list", { name: destinationName, color: "#007AFF" });
    createdListIds.add(destination.id);

    const renamed = await runtime.callTool("update_reminder_list", {
      list_id: source.id,
      name: sourceName + " Renamed",
      color: "#34C759",
    });
    assert.equal(renamed.color, "#34C759");

    const due = new Date(Date.now() + 7 * 86_400_000).toISOString();
    const first = await runtime.callTool("create_reminder", {
      title: "Integration recurring reminder",
      list_id: source.id,
      notes: "created by disposable integration test",
      location: "Test location",
      url: "https://example.com/reminder",
      start: due,
      due,
      priority: 1,
      alarms: [{ type: "relative", offset_seconds: -3600 }],
      recurrence_rules: [{ frequency: "weekly", interval: 2, days_of_week: [{ day: "tuesday" }], end: { count: 3 } }],
    });
    const second = await runtime.callTool("create_reminder", {
      title: "Integration list-delete reminder",
      list_id: source.id,
      due,
    });

    const full = await runtime.callTool("get_reminder", { id: first.id });
    assert.equal(full.url, "https://example.com/reminder");
    assert.equal(full.alarms[0].type, "relative");
    assert.equal(full.recurrenceRules[0].frequency, "weekly");

    const updated = await runtime.callTool("update_reminder", {
      id: first.id,
      notes: "updated by disposable integration test",
      priority: 5,
    });
    assert.equal(updated.priority, 5);

    const completed = await runtime.callTool("bulk_set_reminders_completed", { ids: [first.id, second.id], completed: true });
    const recurringCompletion = completed.find((item) => item.id === first.id);
    const ordinaryCompletion = completed.find((item) => item.id === second.id);
    assert.equal(recurringCompletion.completionOutcome, "advanced_to_next_occurrence");
    assert.equal(ordinaryCompletion.completionOutcome, "completed");
    assert.equal(ordinaryCompletion.completed, true);
    const moved = await runtime.callTool("bulk_move_reminders", { ids: [first.id], list_id: destination.id });
    assert.equal(moved[0].listId, destination.id);

    const reminderPreview = await runtime.callTool("preview_delete_reminders", { ids: [first.id] });
    const reminderDelete = await runtime.callTool("delete_reminders", { confirmation_token: reminderPreview.confirmationToken });
    assert.equal(reminderDelete.count, 1);

    const listPreview = await runtime.callTool("preview_delete_reminder_list", { list_id: source.id });
    assert.ok(listPreview.count >= 1);
    assert.ok(listPreview.items.some((item) => item.id === second.id));
    await runtime.callTool("delete_reminder_list", { confirmation_token: listPreview.confirmationToken });
    createdListIds.delete(source.id);

    const destinationPreview = await runtime.callTool("preview_delete_reminder_list", { list_id: destination.id });
    await runtime.callTool("delete_reminder_list", { confirmation_token: destinationPreview.confirmationToken });
    createdListIds.delete(destination.id);
  } finally {
    for (const listId of createdListIds) await safelyDeleteList(listId);
  }
});
