---
name: codex-pet-limit-rings
description: Install, run, customize, package, or debug the Codex Pet Limit Rings macOS companion app for Codex pets. Use when the user asks for Codex pet usage-limit rings, a menu-bar toggle, launch-at-login packaging, live/cached Codex limit visualization, or open-source distribution of the rings overlay.
---

# Codex Pet Limit Rings

## Core Rule

Keep the Codex desktop app unpatched by default. Ship and modify the rings as a companion macOS app that reads local Codex state and exposes its own menu-bar icon. Only discuss direct Codex app menu patching as a brittle optional route, because it requires `app.asar` patching, Electron integrity updates, and re-signing after Codex updates.

The rings are pet-agnostic. Do not add pet-specific setup unless a user explicitly asks for a custom visual treatment; by default the overlay follows whatever Codex pet is currently active.

## Locate The Project

If this skill is bundled in the repository, the project root is two directories above this `SKILL.md`. Otherwise find or ask for a checkout containing:

```text
tools/codex-pet-limit-rings.swift
tools/install-limit-rings.sh
tools/run-limit-rings.sh
```

Use that checkout as the working directory. Read `AGENTS.md` first if it exists.

## Common Tasks

Install or enable the rings for a user:

```bash
tools/install-limit-rings.sh
```

Run a development build without installing a login item:

```bash
tools/run-limit-rings.sh
```

Uninstall:

```bash
tools/uninstall-limit-rings.sh
```

Install this skill into local Codex:

```bash
tools/install-codex-skill.sh
```

Build a shareable macOS installer package and DMG:

```bash
tools/build-limit-rings-pkg.sh
tools/package-limit-rings-dmg.sh
```

Verify the live app:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings" >/dev/null
```

## Data Contract

The rings read:

- `~/.codex/auth.json` for a local ChatGPT access token, then `https://chatgpt.com/backend-api/wham/usage` for live usage data.
- `~/.codex/.codex-global-state.json` for `electron-avatar-overlay-open` and `electron-avatar-overlay-bounds.mascot`.
- `~/.codex/logs_2.sqlite` for fallback to the newest `codex.rate_limits` event when live usage fails.

The outer ring is the short-window usage percentage. The inner ring is the weekly usage percentage. Both rings start at 12 o'clock and fill clockwise. Clicking the center toggles the center label between usage and remaining-limit percentages. Decorative borders, inactive track outlines, and extra dots stay hidden. Hover readouts show unprefixed reset countdowns together below the center label, with the 5h value above the weekly value and colors matching their rings, not usage percentages. Hovering over the pet/rings uses an open-hand cursor, and dragging that hover area saves the overlay position. The menu summary should say `Live` when direct usage succeeds and `Cached` when the local log fallback is active.

## Editing Workflow

When changing behavior or visuals:

1. Edit `tools/codex-pet-limit-rings.swift`.
2. Keep packaging scripts in `tools/`, keep the app icon generation in `tools/generate-app-icon.swift`, and update `docs/limit-rings.md` when the user-facing contract changes.
3. Run:

```bash
bash -n tools/*.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
tools/build-limit-rings.sh tmp/CodexPetLimitRings.app
tools/build-limit-rings-pkg.sh
tools/package-limit-rings-dmg.sh
```

4. Relaunch with `tools/run-limit-rings.sh` for development or `tools/install-limit-rings.sh` for the packaged login-item flow.

## Open-Source Hygiene

Keep the app privacy-preserving, source-buildable, installer-packageable, and uninstallable. Do not commit local `tmp/` builds, `dist/` DMGs/PKGs, logs, derived pet spritesheets, or user-specific Codex data. Preserve the MIT license and document any new local files or permissions in `docs/limit-rings.md`.
