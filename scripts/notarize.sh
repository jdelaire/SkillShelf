#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SkillShelf.app"
profile="${SKILLSHELF_NOTARY_PROFILE:-jdelaire-notary}"

export SKILLSHELF_SIGN_IDENTITY="${SKILLSHELF_SIGN_IDENTITY:-Developer ID Application}"
"$script_dir/package-app.sh"

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$repository_root/Resources/SkillShelf-Info.plist")"
archive="$repository_root/dist/SkillShelf-$version.zip"

xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute --verbose "$app"

rm -f "$archive"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"
print -- "Notarized release archive: $archive"
