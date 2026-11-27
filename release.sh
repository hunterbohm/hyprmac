#!/bin/bash
# Builds the tagged HEAD as a Developer ID signed, Apple-notarized HyprMac release and uploads it. Usage: release.sh [--no-upload]
# Run it on a Mac with the Developer ID certificate in its keychain, under `infisical run --env=prod --` (see docs/RELEASING.md).
# These are Bohm & Company's signing secrets, which Infisical keeps under HEREBY_* names:
#   HEREBY_SIGN_IDENTITY   the certificate's name, "Developer ID Application: <company> (<team id>)"
#   HEREBY_TEAM_ID         the ten-character team id; updates must be signed by it
#   Notarization, one of:  HEREBY_NOTARY_PROFILE (a `notarytool store-credentials` keychain profile), or
#                          HEREBY_NOTARY_KEY (the App Store Connect API key's .p8 text), HEREBY_NOTARY_KEY_ID, HEREBY_NOTARY_ISSUER
# It writes HyprMac-<tag>.zip to RELEASE_OUT (default build/release/<tag>), then uploads it to the tag's release on
# hunterbohm/hyprmac, which is where installed apps look. --no-upload stops before uploading.
set -euo pipefail
umask 022
upload=1
for argument in "$@"; do
    case "$argument" in
        --no-upload) upload=0 ;;
        *) printf 'usage: release.sh [--no-upload]\n' >&2; exit 2 ;;
    esac
done
here="$(cd "$(dirname "$0")" && pwd)"
repo=hunterbohm/hyprmac   # also in app/Sources/Updater.swift: installed apps read this repo's releases
bundle_id=com.hunterbohm.hyprmac

if ! version="$(git -C "$here" describe --tags --exact-match HEAD 2>/dev/null)" || [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'A release needs HEAD on a release tag like v0.2.0.\n' >&2
    exit 1
fi
if [[ -n "$(git -C "$here" status --porcelain)" ]]; then
    printf 'Not releasing: the clone has uncommitted or untracked files, so the build would not match %s.\n' "$version" >&2
    exit 1
fi
missing=()
for name in HEREBY_SIGN_IDENTITY HEREBY_TEAM_ID; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
done
if [[ -z "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    for name in HEREBY_NOTARY_KEY HEREBY_NOTARY_KEY_ID HEREBY_NOTARY_ISSUER; do
        [[ -n "${!name:-}" ]] || missing+=("$name (or HEREBY_NOTARY_PROFILE)")
    done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Not releasing: missing %s. Run it under `infisical run --env=prod --`; see docs/RELEASING.md.\n' "${missing[*]}" >&2
    exit 1
fi
if [[ ! "$HEREBY_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then printf 'HEREBY_TEAM_ID is not a team id.\n' >&2; exit 1; fi
if [[ "$HEREBY_SIGN_IDENTITY" != "Developer ID Application: "*"($HEREBY_TEAM_ID)" ]]; then
    printf 'HEREBY_SIGN_IDENTITY must be a Developer ID Application certificate of team %s.\n' "$HEREBY_TEAM_ID" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "\"$HEREBY_SIGN_IDENTITY\""; then
    printf 'No valid "%s" in the keychain. See docs/RELEASING.md.\n' "$HEREBY_SIGN_IDENTITY" >&2
    exit 1
fi

out="${RELEASE_OUT:-$here/build/release/$version}"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/HyprMac.app"
zip="$out/HyprMac-$version.zip"

# Unsigned build from the tagged source, then the release's own signature.
HYPRMAC_UNSIGNED=1 "$here/app/build.sh" "$work/build" >/dev/null
mv "$work/build/HyprMac.app" "$app"
info="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "${version#v}" "$info"
plutil -replace CFBundleVersion -string "${version#v}" "$info"

# A downloaded app has no clone, so it carries what install.sh needs (it installs this app instead of building one).
res="$app/Contents/Resources"
mkdir -p "$res"
cp "$here/install.sh" "$here/uninstall.sh" "$res/"
cp -R "$here/bar" "$here/config" "$res/"
find "$res" -name .DS_Store -delete
chmod -R u+rwX,go+rX "$app"
chmod 755 "$res/install.sh" "$res/uninstall.sh"

# One identity and one bundle id for every release keep the Accessibility switch across updates.
codesign --force --timestamp --options runtime --identifier "$bundle_id" --sign "$HEREBY_SIGN_IDENTITY" "$app"
requirement="anchor apple generic and identifier \"$bundle_id\" and certificate leaf[subject.OU] = \"$HEREBY_TEAM_ID\""
codesign --verify --deep --strict -R "=$requirement" "$app"

ditto -c -k --keepParent "$app" "$work/notarize.zip"
notary=()
if [[ -n "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$HEREBY_NOTARY_PROFILE")
else
    # %b: secret stores that keep one-line values hold the .p8's line breaks as literal \n.
    (umask 077; printf '%b\n' "$HEREBY_NOTARY_KEY" > "$work/notary.p8")
    notary=(--key "$work/notary.p8" --key-id "$HEREBY_NOTARY_KEY_ID" --issuer "$HEREBY_NOTARY_ISSUER")
fi
printf 'Notarizing %s; Apple usually answers in a few minutes.\n' "$version"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json > "$work/notary.json" || true
status="$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    submission="$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)"
    printf 'Notarization ended as "%s".\n' "${status:-unknown}" >&2
    [[ -n "$submission" ]] && xcrun notarytool log "$submission" "${notary[@]}" >&2 || true
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"

ditto -c -k --keepParent "$app" "$zip"
# The zip must pass the same checks an installed copy runs before it installs an update.
"$app/Contents/MacOS/hyprmac" update --verify "$zip" "$version"
printf 'Built %s\n' "$zip"
[[ $upload == 1 ]] || exit 0

notes="Signed and notarized build of $version. Download HyprMac-$version.zip, unzip it, and run HyprMac.app/Contents/Resources/install.sh. Installed copies offer it within a day (hyprctl update installs it)."
if gh release view "$version" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$version" "$zip" --repo "$repo" --clobber
else
    gh release create "$version" "$zip" --repo "$repo" --verify-tag --title "$version" --notes "$notes" --latest
fi
printf 'Published %s to %s; installed apps offer it within a day.\n' "$version" "$repo"
