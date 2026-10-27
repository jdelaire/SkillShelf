#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SkillShelf.app"

cd "$repository_root"
swift build -c release --product SkillShelf
bin_dir="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/install -m 0644 Resources/SkillShelf-Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_dir/SkillShelf" "$app/Contents/MacOS/SkillShelf"
/usr/bin/codesign --force --deep --sign - "$app"

print -- "SkillShelf app packaged: $app"
