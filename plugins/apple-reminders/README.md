# Apple Reminders for Codex

A local Codex plugin that manages Apple Reminders through Apple's public EventKit framework. It runs entirely on the Mac and requires no API key or hosted service.

## Requirements

- macOS 14 or newer
- Node.js 18 or newer
- Apple Command Line Tools (`xcode-select --install`)
- Full Reminders permission for the signed native helper

## Capabilities

- List reminder accounts/sources and lists, including stable identifiers, colors, and write capabilities
- List, search, filter, sort, and page reminders
- Read full reminder details and recover items by external identifier after an EventKit identifier change
- Create and edit title, notes, location text, URL, start date, due date, timezone, priority, alarms, and recurrence
- Create, rename, and recolor reminder lists
- Move and complete reminders individually or atomically in batches
- Delete one reminder with `confirm=true`
- Preview and token-confirm bulk or list deletion, with stale-snapshot protection

Dates use `YYYY-MM-DD` for all-day values and RFC 3339 for specific times. Codex resolves relative language such as “tomorrow” before calling the tools.

Alarms may be absolute, relative, or location-based. Recurrence rules support daily, weekly, monthly, and yearly frequency plus interval, weekday positions, month/year constraints, and count/date endings.

Completing a repeating reminder advances its series to the next occurrence, matching Apple Reminders. The response reports `completionOutcome: "advanced_to_next_occurrence"` instead of pretending the newly generated occurrence is completed.

## Safety

- Full macOS Reminders permission is required before data can be accessed.
- Write tools are intended only for explicit user requests.
- Bulk deletion and list deletion require a preview token valid for five minutes.
- A token is one-time and bound to reminder identifiers and modification timestamps.
- Batch writes are validated before an EventKit transaction is committed.
- Mixed event/reminder calendars are not deleted.
- The plugin never reads the private Reminders database and does not use AppleScript or UI automation.

## Public EventKit limitations

Apple does not expose complete public read/write APIs for native Reminders subtasks, tags, sections, attachments, smart lists, or sharing administration. This plugin reports those boundaries instead of simulating support through fragile private mechanisms.

## Build and test

```sh
./scripts/build-native.sh
node --test server/*.test.mjs
printf '%s' '{"action":"self_test"}' | ./native/build/reminders-helper
```

The first real Reminders operation may show a permission prompt. If permission was denied, enable it under **System Settings > Privacy & Security > Reminders**.

Integration tests must use a disposable list created specifically for testing; never point destructive tests at an existing user list.

Run the opt-in real EventKit lifecycle test with:

```sh
APPLE_REMINDERS_INTEGRATION_TESTS=1 node --test server/integration.test.mjs
```
