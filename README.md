# claude-usage-extension

A tiny macOS menu bar app that shows your Claude 5-hour session and weekly usage at a glance.

![demo](docs/demo.png)

## What it shows

- **Menu bar title**: `5h NN% · 7d NN%` — current session usage and weekly all-models usage, updated live.
- **Popover** (on click): both numbers plus the countdown to reset and the absolute reset time. Two buttons: **Refresh** and **Quit**.

That's it. No settings, no thresholds, no notifications, no Sonnet-only breakdown.

## How it works

The app reuses the OAuth token that the [Claude Code](https://claude.ai/code) CLI stores in your macOS Keychain (item `Claude Code-credentials`). It then calls the same undocumented endpoint that powers `claude.ai/settings/usage`:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

The response includes a `five_hour` and `seven_day` section with `utilization` (0–100) and `resets_at` (ISO8601). The app parses those, redraws the menu bar, and schedules the next refresh.

- **Auto-refresh** every 10 minutes.
- **Manual refresh** via the button in the popover.
- **Backoff** to 15 minutes on HTTP 429; the cached token is dropped so the next attempt re-reads the keychain (in case Claude Code rotated it).

Because the token is already on your machine, there's no separate login step. If you're signed into Claude Code, this works.

> The `/api/oauth/usage` endpoint is undocumented and may change without notice.

## Requirements

- macOS 13+
- Xcode command-line tools (`xcode-select --install`)
- Claude Code installed and logged in

## Build

```bash
git clone https://github.com/rvthak/claude-usage-extension
cd claude-usage-extension
./build.sh
open ClaudeUsage.app
```

`build.sh` runs `swift build -c release` and wraps the binary into `ClaudeUsage.app` with a proper `Info.plist` (`LSUIElement = true`, so no Dock icon).

## First-launch keychain prompt

On first launch macOS will ask for your **login keychain password** (the same one you use to log in to your Mac) before allowing the unsigned binary to read the `Claude Code-credentials` item. Click **Always Allow** so it doesn't reappear every refresh. If you click "Allow" once by mistake, open Keychain Access, find `Claude Code-credentials`, and add `ClaudeUsage.app` to its Access Control list.

## Project layout

```
Package.swift                       Swift Package manifest
Sources/ClaudeUsage/
  main.swift                        NSApplication bootstrap
  AppDelegate.swift                 NSStatusItem + popover + refresh timer
  UsageService.swift                Keychain read + API call + JSON decode
  PopoverView.swift                 SwiftUI popover (rows + buttons)
Resources/Info.plist                LSUIElement bundle metadata
build.sh                            Compile + package as .app
```

## License

MIT.
