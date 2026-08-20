# Codex Apple Reminders

A local-first Codex plugin for reading and managing Apple Reminders on macOS through Apple's EventKit framework.

## What it can do

- List reminder lists
- List and search reminders
- Create and update reminders
- Mark reminders complete or incomplete
- Delete reminders only after explicit confirmation

## Install

Requirements: macOS, Node.js 18+, and Apple Command Line Tools.

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

- `Show my unfinished reminders.`
- `Add "Read for 30 minutes" to my default list for today.`
- `Mark the reminder "Read for 30 minutes" as completed.`

## Architecture

```text
Codex
  -> local MCP server (Node.js)
  -> signed native helper (Objective-C)
  -> Apple EventKit
  -> Reminders / iCloud
```

No third-party API key or hosted service is required. Reminder data returned by a tool becomes part of the active Codex task context.

## Limitations

Apple's public EventKit API does not expose the native Reminders subtask hierarchy, so this plugin does not claim subtask support.

## License

MIT
