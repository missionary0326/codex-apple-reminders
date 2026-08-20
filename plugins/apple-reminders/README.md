# Apple Reminders for Codex

A local Codex plugin that uses a Node.js MCP server and a signed Objective-C/EventKit helper to work with Apple Reminders on macOS.

The connector runs locally and does not require a third-party API key. Reminder data returned by a tool becomes part of the active Codex task context.

## Supported operations

- List reminder lists
- List and search reminders
- Create and update reminders
- Mark reminders complete or incomplete
- Delete reminders only with explicit confirmation

Apple's public EventKit API does not expose Reminders subtask hierarchy. This plugin therefore does not claim native subtask support.

## Local build

Requirements:

- macOS
- Node.js 18 or newer
- Apple Command Line Tools (`xcode-select --install`)

```sh
./scripts/build-native.sh
```

The first real Reminders operation prompts for macOS permission. If access was denied previously, enable it under **System Settings > Privacy & Security > Reminders**.

Relative date language is resolved by Codex. The MCP tools receive `YYYY-MM-DD` or RFC 3339 timestamps so date handling remains explicit and testable.

## Safety

- macOS permission is required before any reminder data can be accessed.
- Write tools are described for explicit user requests only.
- Deletion additionally requires `confirm=true`.
- The plugin never reads the Reminders database directly; it uses Apple's EventKit framework.
