# Codex Apple Reminders

A local-first Codex plugin for managing Apple Reminders on macOS 14+ through Apple's public EventKit framework.

## Features

- Read reminder accounts, lists, and full reminder details
- Search, filter, sort, and page reminders
- Create and update dates, notes, locations, URLs, priorities, alarms, and advanced recurrence rules
- Create, rename, and recolor lists
- Move and complete reminders individually or in atomic batches
- Preview destructive bulk/list operations and confirm with a one-time, five-minute token
- Recover reminders through EventKit external identifiers when ordinary identifiers change

No third-party API key or hosted service is required.

## Install

Requirements: macOS 14+, Node.js 18+, and Apple Command Line Tools.

```sh
git clone https://github.com/missionary0326/codex-apple-reminders.git
cd codex-apple-reminders/plugins/apple-reminders
./scripts/build-native.sh
cd ../..
codex plugin marketplace add "$(pwd)"
codex plugin add apple-reminders@missionary0326-plugins
```

Start a new Codex task after installation. The first real operation prompts for Apple Reminders permission.

Example prompts:

- `Show unfinished reminders due this week.`
- `Add a reminder every second Tuesday with a notification one hour before.`
- `Create a list named Reading and color it blue.`
- `Preview deleting these completed reminders.`

## Architecture and privacy

```text
Codex
  -> local MCP server (Node.js)
  -> signed native helper (Objective-C)
  -> Apple EventKit
  -> Reminders / iCloud
```

Reminder data returned by a tool becomes part of the active Codex task context. The plugin never reads the private Reminders database and does not use AppleScript or UI automation.

## Limitations

Apple's public EventKit API does not expose complete native subtask, tag, section, attachment, smart-list, or sharing-management functionality. Those features are intentionally not claimed.

## Development

```sh
cd plugins/apple-reminders
node --test server/*.test.mjs
./scripts/build-native.sh
printf '%s' '{"action":"self_test"}' | ./native/build/reminders-helper
```

## License

MIT
