# SkillShelf

macOS app that lists the agent skills installed for Claude Code, Codex, Cursor, OpenCode, Grok and Antigravity, shows where each one lives, deletes them to the Trash, and pushes a skill to every harness with symlinks.

## Install

Download the zip from the [latest release](https://github.com/jdelaire/SkillShelf/releases/latest), unzip it and move `SkillShelf.app` to Applications. Releases are signed with Developer ID and notarized by Apple.

Requires macOS 15 or later on Apple silicon.

## Build

```sh
swift test
./scripts/package-app.sh
open dist/SkillShelf.app
```

`scripts/package-app.sh` signs ad hoc. To build a notarized release, store notary credentials once with `xcrun notarytool store-credentials`, then run `SKILLSHELF_NOTARY_PROFILE=<profile> ./scripts/notarize.sh`.

Where each harness loads skills from, and the delete and push rules, are in [docs/plan.md](docs/plan.md).
