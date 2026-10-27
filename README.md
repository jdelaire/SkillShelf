# SkillShelf

macOS app that lists the agent skills installed for Claude Code, Codex, Cursor, OpenCode and Grok, shows where each one lives, deletes them to the Trash, and pushes a skill to every harness with symlinks.

## Build

```sh
swift test
./scripts/package-app.sh
open dist/SkillShelf.app
```

Where each harness loads skills from, and the delete and push rules, are in [docs/plan.md](docs/plan.md).
