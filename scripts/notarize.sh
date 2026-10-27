#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SkillShelf.app"
if [[ -n "${SKILLSHELF_NOTARY_KEY:-}" ]]; then
  notary_auth=(--key "$SKILLSHELF_NOTARY_KEY" --key-id "${SKILLSHELF_NOTARY_KEY_ID:?}" --issuer "${SKILLSHELF_NOTARY_ISSUER:?}")
else
  notary_auth=(--keychain-profile "${SKILLSHELF_NOTARY_PROFILE:-jdelaire-notary}")
fi

export SKILLSHELF_SIGN_IDENTITY="${SKILLSHELF_SIGN_IDENTITY:-Developer ID Application}"
"$script_dir/package-app.sh"

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$repository_root/Resources/SkillShelf-Info.plist")"
archive="$repository_root/dist/SkillShelf-$version.zip"

xcrun notarytool submit "$archive" "${notary_auth[@]}" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute --verbose "$app"

rm -f "$archive"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$archive"

sparkle_bin="$repository_root/.build/artifacts/sparkle/Sparkle/bin"
bundled_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$repository_root/Resources/SkillShelf-Info.plist")"
keychain_key="$("$sparkle_bin/generate_keys" --account skillshelf -p)"
[[ "$keychain_key" == "$bundled_key" ]] || { print -u2 -- "Sparkle key in keychain does not match SUPublicEDKey"; exit 1; }

download_prefix="${SKILLSHELF_DOWNLOAD_PREFIX:-https://github.com/jdelaire/SkillShelf/releases/download/v$version/}"
staging="$repository_root/dist/appcast"
rm -rf "$staging"
mkdir -p "$staging"
cp "$archive" "$staging/"
notes="$repository_root/docs/releases/$version.md"
[[ -f "$notes" ]] && cp "$notes" "$staging/SkillShelf-$version.md"
"$sparkle_bin/generate_appcast" "$staging" \
  --account skillshelf --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "$download_prefix" \
  --link https://github.com/jdelaire/SkillShelf
signature="$(/usr/bin/sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "$staging/appcast.xml")"
[[ -n "$signature" ]] || { print -u2 -- "appcast.xml has no edSignature"; exit 1; }
"$sparkle_bin/sign_update" --account skillshelf --verify "$archive" "$signature"
cp "$staging/appcast.xml" "$repository_root/dist/appcast.xml"

print -- "Notarized release archive: $archive"
print -- "Appcast: $repository_root/dist/appcast.xml"
