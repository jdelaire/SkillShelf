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
xcrun actool Resources/SkillShelf.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon SkillShelf \
  --output-partial-info-plist "$repository_root/.build/icon-info.plist" --target-device mac >/dev/null
/usr/bin/xattr -cr "$app"
/usr/bin/codesign --force --deep --sign - "$app"

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw Resources/SkillShelf-Info.plist)"
archive="$repository_root/dist/SkillShelf-$version.zip"
rm -f "$archive"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"

print -- "SkillShelf app packaged: $app"
print -- "Release archive: $archive"
