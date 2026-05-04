# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window and exposes its own menu-bar icon.

The rings are pet-agnostic. They work with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A rings icon appears in the macOS menu bar.
- `Show Rings` toggles the overlay without quitting the app.
- `Refresh Now` rereads usage and pet-position state.
- `Reset Ring Position` clears the saved manual ring position and returns to Codex pet tracking.
- Dragging the pet/rings saves the new overlay position so stale Codex bounds do not snap the rings back.
- The center of the rings always shows short-window usage as the large percentage and weekly usage as the smaller percentage.
- Hovering over the ring or pet shows exact remaining percentages at the arc endpoints.
- Dragging the pet makes the rings follow the gesture immediately while Codex persists the new position.
- Closing the Codex pet hides the rings.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads live usage first, then local files as support or fallback:

- `https://chatgpt.com/backend-api/wham/usage`: live usage endpoint, called with the local ChatGPT access token from `~/.codex/auth.json`.
- `~/.codex/auth.json`: local ChatGPT auth token used for the live usage call.
- `~/.codex/.codex-global-state.json`: current pet bounds, using `electron-avatar-overlay-bounds.mascot`.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/logs_2.sqlite`: fallback source using the newest `codex.rate_limits` event when the live usage call fails.

No OpenAI API key is required. The menu summary says `Live` when the direct usage read succeeds and `Cached` when it is showing the local event-log fallback.

## Rendering Model

- Outer ring: short-window remaining percentage.
- Inner ring: weekly remaining percentage.
- Ring colors are derived from remaining capacity: green/blue for healthy, amber for low, red for critical.
- The overlay footprint is scaled to 70% of the original companion-ring size so it stays compact around the pet.
- Center percentages use the matching ring colors: large text for short-window usage, smaller text for weekly usage.
- Exact percentages are shown only on hover to keep the pet feeling ambient rather than dashboard-like.
- Additional model-limit buckets may appear as small outer markers when available.

## Install Contract

`tools/install-limit-rings.sh` builds:

```text
~/Applications/CodexPetLimitRings.app
```

and installs:

```text
~/Library/LaunchAgents/com.codex-pet.limit-rings.plist
```

The LaunchAgent starts the app at login. The installer also removes the earlier prototype app and LaunchAgent names if present:

```text
~/Applications/CodexLimitAura.app
~/Library/LaunchAgents/com.codex-pet.limit-aura.plist
```

`tools/uninstall-limit-rings.sh` unloads the LaunchAgent, removes the app bundle, clears the saved ring visibility preference, and also cleans up those earlier prototype names.

## Development

Build and run the app from the repository:

```bash
tools/run-limit-rings.sh
```

Render a static preview:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
