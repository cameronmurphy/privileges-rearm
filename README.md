# privileges-rearm

Re-arms SAP Privileges admin the moment it expires, so renewing costs one
Touch ID tap instead of hunting the menu bar, picking a reason, and clicking.

## What it does, and what it deliberately does not

When admin access drops, a LaunchAgent notices within 15 seconds and:

1. opens the Privileges request dialog,
2. selects **Developer Requirement** from the reason dropdown,
3. clicks **Request Privileges**.

Then it stops. macOS asks for your fingerprint and only you can supply that.

**This tool cannot complete an elevation on its own.** It automates the clicks
you are already entitled to make; the authentication requirement your org
configured (`RequireAuthentication = true`) is untouched, and every grant is
still logged with a reason. Without a live fingerprint, nothing happens.

## Why a compiled binary rather than a shell script

The clicks are synthetic events, which need Accessibility permission. macOS
attributes that permission to the *actual executable* and its code signature.
A script starting with `#!/bin/bash` runs as `/bin/bash`, so macOS asks you to
authorize bash itself, which would let **every** shell script on the machine
drive your UI. A shell script also cannot carry an embedded signature.

So this is Swift, compiled to a real Mach-O and ad-hoc signed. The window
lookup and the clicking both happen in-process, with no `osascript` or `bash`
children, so there is exactly one binary to authorize and the prompt names
`PrivilegesRearm`.

## How it finds the controls

The request dialog opts out of Accessibility, so its buttons cannot be scripted
the normal way. Instead:

- Window frames come from `CGWindowListCopyWindowInfo`, which still reports the
  dialog and its popup menu. Bounds are read live on every run, so it does not
  care which monitor the dialog lands on (it moves around) or what the Retina
  scale is. Both the frames and the click events are in points, so no pixel math.
- The reason row is derived from `ReasonPresetList` in the managed profile at
  `/Library/Managed Preferences/corp.sap.privileges.plist`. Menu rows are the
  presets in profile order followed by `Other...`, so if IT changes the presets
  the row index adapts automatically.
- Control positions within the dialog are fractions of its frame, measured from
  the real dialog. These are the one brittle part: a Privileges redesign would
  need them re-measured. See `popupXF` / `buttonYF` in the source.

## Requirements

- SAP Privileges 2.x at `/Applications/Privileges.app`
- Xcode command line tools (`swiftc`)
- Accessibility permission for the built app

## Install

```sh
make install   # build, sign, install to ~/Applications, load the LaunchAgent
make grant     # raise the Accessibility prompt in the app's own name
```

`make grant` launches the app standalone on purpose. Running it from a terminal
would inherit the terminal's Accessibility grant and report a false positive.

Approve **PrivilegesRearm** in System Settings > Privacy & Security >
Accessibility. If earlier experiments left `bash` or `osascript` in that list,
remove them; they are far broader than needed and nothing here uses them.

## Verify

```sh
make status
/Applications/Privileges.app/Contents/MacOS/PrivilegesCLI --remove
```

The second command drops you to standard. Within 15 seconds the dialog should
open, fill itself in, submit, and present Touch ID. If the dialog opens but
nothing is clicked, Accessibility is not approved for the app.

## Modes

| Command | Effect |
| --- | --- |
| (no args) | Edge detect. Requests only on the admin to standard transition. Used by the LaunchAgent. |
| `--now` | Run the request immediately. |
| `--dry` | Select the reason but do not submit. Safe to repeat. |
| `--setup` | Ask macOS for Accessibility permission. |
| `--status` | Print admin and Accessibility state. |

## Caveats

- With a Developer ID signature the Accessibility grant survives rebuilds,
  because TCC keys it to the designated requirement (bundle ID + team ID)
  rather than the binary's hash. If you fall back to ad-hoc signing, expect to
  re-approve after every `make install`.
- It moves the mouse pointer for about a second while it runs. It never types,
  so it cannot collide with your keyboard.
- It fires only on the transition to standard, giving one prompt per expiry
  rather than a repeating nag.

## Signing

`make` auto-detects a `Developer ID Application` identity and uses it, adding
hardened runtime and a secure timestamp. Override with `make app SIGN_ID="..."`,
or `SIGN_ID=-` for ad-hoc. Check what it picked with `make sign-info`.

This matters for more than tidiness. A Developer ID signature gives the bundle a
designated requirement of bundle ID plus team ID, which is what TCC records, so
the Accessibility approval keeps working across rebuilds.

Notarization is only needed if the app will be *downloaded*, since a download is
quarantined and Gatekeeper refuses unnotarized apps. A locally built app is not
quarantined and runs fine without it.

```sh
xcrun notarytool store-credentials privileges-rearm   # once
make notarize
```

## CI

`.github/workflows/build.yml` builds on `macos-latest`, imports the certificate
into a temporary keychain, signs, verifies, and uploads the app as an artifact.
Tagged pushes (`v*`) additionally notarize, staple, and attach to a release.
Without secrets, for example on a fork PR, it degrades to an unsigned compile
check instead of failing.

CI cannot test behaviour. The tool drives another app's GUI, needs Accessibility,
and ends at a fingerprint sensor, none of which exist on a runner.

Required secrets:

| Secret | What it is |
| --- | --- |
| `CERT_P12_BASE64` | Developer ID cert + private key, exported as `.p12`, base64, unwrapped |
| `CERT_P12_PASSWORD` | password used for that `.p12` export |
| `KEYCHAIN_PASSWORD` | any string; for the throwaway CI keychain |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |

Only for notarized tag builds:

| Secret | What it is |
| --- | --- |
| `AC_API_KEY_BASE64` | App Store Connect API key `.p8`, base64, unwrapped |
| `AC_API_KEY_ID` | the key ID |
| `AC_API_ISSUER_ID` | the issuer ID |

Export the certificate from Keychain Access (right-click the identity, Export,
choose `.p12`), then:

```sh
base64 -i Certificates.p12 | tr -d '\n' | gh secret set CERT_P12_BASE64
gh secret set CERT_P12_PASSWORD
gh secret set KEYCHAIN_PASSWORD
gh secret set SIGN_IDENTITY --body "Developer ID Application: Name (TEAMID)"
```

Delete the exported `.p12` afterwards; it contains your private key.

## Uninstall

```sh
make uninstall
```

Then remove the `PrivilegesRearm` entry from Accessibility manually.

## Alternative worth knowing

If your Mac admins will set `AllowCLIBiometricAuthentication = true` in the
Privileges configuration profile, none of this is necessary:
`PrivilegesCLI --add --reason "Developer Requirement"` would then prompt for
Touch ID directly, with no UI automation and no Accessibility grant at all.
A local override of that key does not work; the root daemon only honours it
from an MDM profile.

`legacy/privileges-rearm.sh` is the original shell implementation, superseded
by the Swift binary and kept only for reference.
