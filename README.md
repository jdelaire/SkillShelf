# SkillShelf

macOS app that lists the agent skills installed for Claude Code, Codex, Cursor, OpenCode, Grok and Antigravity, shows where each one lives, deletes them to the Trash, and pushes a skill to every harness with symlinks.

## Install

Download `SkillShelf-0.1.0.zip` from the [latest release](https://github.com/jdelaire/SkillShelf/releases/latest), unzip it and move `SkillShelf.app` to Applications. The app is ad-hoc signed and not notarized, so the first time, right-click it and choose Open.

Requires macOS 15 or later on Apple silicon.

## Build

```sh
swift test
./scripts/package-app.sh
open dist/SkillShelf.app
```

Where each harness loads skills from, and the delete and push rules, are in [docs/plan.md](docs/plan.md).
