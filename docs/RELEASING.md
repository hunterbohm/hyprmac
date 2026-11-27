# Releasing HyprMac

`release.sh` turns a release tag into a Developer ID signed, Apple-notarized `HyprMac-<tag>.zip` and uploads it to
that tag's release on `hunterbohm/hyprmac`. A source build (`app/build.sh`, `./install.sh`) needs none of this and
keeps working without a certificate.

## How the pieces fit

- **Developer ID certificate** signs the app, with the hardened runtime, as bundle id `com.hunterbohm.hyprmac`.
  macOS ties the Accessibility switch to that signer and bundle id, so every release uses the same ones and an
  update keeps the switch.
- **Notarization**: Apple scans the signed app and issues a ticket, which `stapler` attaches, so Gatekeeper opens
  it without a warning, even offline.
- **The zip** holds `HyprMac.app`, which carries `install.sh`, `uninstall.sh`, `bar/` and `config/` in
  `Contents/Resources`. `install.sh` run from there installs that app instead of building one, and refuses an app
  Gatekeeper would refuse.
- **In-app updates** (`app/Sources/Updater.swift`) have one trust anchor: the code signature. The running copy
  reads its own Apple team id, asks GitHub for the latest release tag, and builds the download URL itself from the
  tag. It installs only a zip whose app has this bundle id, is exactly that version and newer than the running
  one, satisfies `anchor apple generic` through Developer ID for the same team (strict, with nested code), and that
  `spctl` reports as `Notarized Developer ID`. It then runs the new app's own `install.sh`, which swaps the app and
  restarts the login agents. There is no separate update key: stealing the GitHub login lets someone publish a
  release, but not one signed by the team's certificate, so no copy installs it. The one gap is a replay of an
  older release the team really signed, which is refused unless it is newer than the running copy.
- A copy built from source has no Apple team, so it skips all of this (`hyprctl update` says so).

Why not Sparkle: HyprMac is a login agent with no window to show a Sparkle prompt, and the update also has to refresh
the OmniWM widgets and login items that `install.sh` manages, which Sparkle would not do.

## One-time setup

1. Install the "Developer ID Application" certificate in the login keychain of the Mac that releases. Check it:
   `security find-identity -v -p codesigning` lists `"Developer ID Application: <company> (<TEAM ID>)"`.
2. Infisical (prod, path `/`) holds the signing secrets under the names the company's other Mac app uses:

   | Name | Value |
   | --- | --- |
   | `HEREBY_SIGN_IDENTITY` | the certificate's full name |
   | `HEREBY_TEAM_ID` | the ten-character team id |
   | `HEREBY_NOTARY_KEY`, `HEREBY_NOTARY_KEY_ID`, `HEREBY_NOTARY_ISSUER` | the App Store Connect API key's `.p8` text (line breaks may be stored as literal `\n`), key id, issuer id |
   | or `HEREBY_NOTARY_PROFILE` | a `notarytool store-credentials` keychain profile, instead of the three above |

## Each release

1. Merge to `master`, then tag the commit `vX.Y.Z` (three numbers; the app reads the version from the tag) and check
   out that tag in a clean clone.
2. `infisical run --env=prod -- ./release.sh` builds, signs, notarizes, staples, zips, runs the zip through the
   updater's own checks (`hyprmac update --verify ZIP TAG`), pushes the tag's release to GitHub and marks it latest.
   `--no-upload` stops after writing `build/release/<tag>/HyprMac-<tag>.zip`. Push the tag to GitHub before
   uploading (`--verify-tag`).
3. Installed copies offer it within a day. Check with `hyprctl update --check`.

## The first signed install on a Mac that ran a source build

The signer changes from the local certificate to Developer ID, so macOS asks for the Accessibility switch once more
(`install.sh` clears the old, stale switch). Later signed updates keep it.
