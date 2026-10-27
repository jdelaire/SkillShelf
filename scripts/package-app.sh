#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SkillShelf.app"
sign_identity="${SKILLSHELF_SIGN_IDENTITY:--}"

cd "$repository_root"
swift build -c release --product SkillShelf
bin_dir="$(swift build -c release --show-bin-path)"
sparkle="$repository_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$sparkle" ]] || { print -u2 -- "Sparkle.framework not found at $sparkle"; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
/usr/bin/install -m 0644 Resources/SkillShelf-Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_dir/SkillShelf" "$app/Contents/MacOS/SkillShelf"
xcrun actool Resources/SkillShelf.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --app-icon SkillShelf \
  --output-partial-info-plist "$repository_root/.build/icon-info.plist" --target-device mac >/dev/null

framework="$app/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$sparkle" "$framework"
rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
/usr/bin/xattr -cr "$app"

sign() {
  if [[ "$sign_identity" == - ]]; then
    /usr/bin/codesign --force --sign - "$@"
  else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$sign_identity" "$@"
  fi
}
sign "$framework/Versions/B/Autoupdate"
sign "$framework/Versions/B/Updater.app"
sign "$framework"
sign "$app"
/usr/bin/codesign --verify --deep --strict "$app"

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw Resources/SkillShelf-Info.plist)"
archive="$repository_root/dist/SkillShelf-$version.zip"
rm -f "$archive"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"

print -- "SkillShelf app packaged: $app"
print -- "Release archive: $archive"
