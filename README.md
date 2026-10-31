# SkillShelf

macOS app that lists the agent skills installed for Claude Code, Codex, Cursor, OpenCode, Grok and Antigravity, shows where each one lives, deletes them to the Trash, and pushes a skill to every harness with symlinks.

It also shows each harness's system prompt: instruction files, the vendor base prompt where it is public, and a sandboxed capture of the request it sends.

## Install

Download the zip from the [latest release](https://github.com/jdelaire/SkillShelf/releases/latest), unzip it and move `SkillShelf.app` to Applications. Releases are signed with Developer ID and notarized by Apple. From 0.1.2 on, SkillShelf updates itself with [Sparkle](https://sparkle-project.org): it checks once a day, and SkillShelf > Check for Updates… checks right away.

Requires macOS 15 or later on Apple silicon.

## Build

```sh
swift test
./scripts/package-app.sh
open dist/SkillShelf.app
```

`scripts/package-app.sh` signs ad hoc. To build a release:

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/SkillShelf-Info.plist`, and write the notes in `docs/releases/<version>.md`.
2. Run `./scripts/notarize.sh`. It signs with Developer ID, notarizes, staples, zips and writes `dist/appcast.xml` signed with the Sparkle key stored in the keychain under the account `skillshelf`. Notary credentials come from a `notarytool` keychain profile (`SKILLSHELF_NOTARY_PROFILE`) or an App Store Connect API key (`SKILLSHELF_NOTARY_KEY`, `SKILLSHELF_NOTARY_KEY_ID`, `SKILLSHELF_NOTARY_ISSUER`).
3. Publish both files: `gh release create v<version> dist/SkillShelf-<version>.zip dist/appcast.xml --notes-file docs/releases/<version>.md`. Every release must include `appcast.xml`, because the app reads it from the latest release.

Where each harness loads skills from, and the delete and push rules, are in [docs/plan.md](docs/plan.md).
