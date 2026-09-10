# Developing

## Build

Needs Xcode command line tools.

```sh
make app       # compile + assemble + sign into build/
make install   # the above, then let the app install itself
make status    # admin state, Accessibility state, agent state, recent log
make clean
```

`make install` just runs the built app with `--install`, which is the same
thing double-clicking it does. The app owns its own installation: copying to
`~/Applications`, writing and loading the LaunchAgent, and raising the
Accessibility prompt from the installed copy.

## Modes

| Command | Effect |
| --- | --- |
| (no args) / `--install` | Install: copy to `~/Applications`, load the agent, request Accessibility. |
| `--watch` | Edge detect. Requests only on the admin to standard transition. What the LaunchAgent runs. |
| `--now` | Run the request immediately. |
| `--dry` | Select the reason but do not submit. Safe to repeat. |
| `--setup` | Ask macOS for Accessibility permission. |
| `--status` | Print admin and Accessibility state. |

## Versioning

`CFBundleShortVersionString` comes from the latest git tag (`v0.0.1` becomes
`0.0.1`, falling back to `0.0.0` when untagged). `CFBundleVersion` is the commit
count, which is numeric and monotonic as that key requires. Nothing is
hardcoded, so a tagged build can't ship claiming the wrong version.

CI checks out with `fetch-depth: 0` because the default shallow clone has no
tags and no history to count.

## How it drives the dialog

The Privileges request dialog opts out of Accessibility, so its controls can't
be scripted the usual way. Instead:

- Window frames come from `CGWindowListCopyWindowInfo`, which still reports the
  dialog and its popup menu. Bounds are read live every run, so it doesn't care
  which monitor the dialog lands on (it moves) or what the Retina scale is.
  Frames and click events are both in points, so there's no pixel math.
- The reason row is derived from `ReasonPresetList` in
  `/Library/Managed Preferences/corp.sap.privileges.plist`. Menu rows are the
  presets in profile order followed by `Other...`, so the row index adapts if
  IT changes the presets.
- Control positions within the dialog are fractions of its frame, measured from
  the real dialog. This is the brittle part: a Privileges redesign means
  re-measuring `popupXF` / `buttonYF`.

Everything happens in-process. There's no `osascript` or `bash` helper, which
matters because macOS attributes Accessibility to the actual executable. A
shebang script runs as `/bin/bash`, so approving it would authorize *every*
shell script on the machine, and a script can't carry a signature anyway.

## Install internals, and App Translocation

Opening the app installs it. Two macOS behaviours make that less obvious than
it sounds, and both bit us:

- **App Translocation.** Launching a quarantined app from somewhere like
  `~/Downloads` does not run it in place. macOS mounts a read-only randomized
  copy under `/private/var/folders/.../AppTranslocation/<uuid>/d/` and runs
  that, so `Bundle.main.bundleURL` is an ephemeral mount, not the file the user
  can see. Trashing it fails with "the volume doesn't have one".
  `originalPath(of:)` resolves it back via `SecTranslocateCreateOriginalPathForURL`,
  bound with `dlsym` because those symbols are C-only in the SDK and invisible
  to `import Security`.
- **Ordering.** Launching the installed copy can tear down the translocated
  mount we are executing from, which kills the process the instant it faults in
  more code. So cleanup and all logging happen *before* the final `open`, which
  is the last thing the installer does.

Cleanup only trashes a source carrying `com.apple.quarantine`, so a locally
built bundle is never deleted and `make install` leaves `build/` intact. It
trashes rather than deletes, and logs the resulting Trash path, which is also
how it gets verified: `~/.Trash` is itself protected, so the app reporting
where it landed beats trying to read the folder.

## Signing

`make` auto-detects a `Developer ID Application` identity. Override with
`make app SIGN_ID="..."`, or `SIGN_ID=-` for ad-hoc. `make sign-info` shows
what it picked.

This is not cosmetic. A Developer ID signature gives a designated requirement
of bundle ID plus team ID, which is what TCC records, so the Accessibility
approval survives rebuilds. Ad-hoc signing is keyed to the binary's cdhash, so
every rebuild silently revokes the grant and the agent starts failing.

Notarization is only needed if the app will be *downloaded*, since downloads are
quarantined and Gatekeeper refuses unnotarized apps. Locally built copies are
not quarantined.

```sh
xcrun notarytool store-credentials privileges-rearm   # once
make notarize
```

## CI

`.github/workflows/build.yml` builds on `macos-latest`, imports the certificate
into a throwaway keychain, signs, verifies, and uploads the app as an artifact.
Tagged pushes (`v*`) also notarize, staple, and attach to a release. Without
secrets it degrades to an unsigned compile check instead of failing.

CI can't test behaviour: no GUI to drive, no Accessibility, no Touch ID sensor.

| Secret | What it is |
| --- | --- |
| `CERT_P12_BASE64` | Developer ID cert + key, exported as `.p12`, base64, unwrapped |
| `CERT_P12_PASSWORD` | password used for that `.p12` export |
| `KEYCHAIN_PASSWORD` | any string, for the throwaway CI keychain |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |

Notarized tag builds also need `AC_API_KEY_BASE64` (App Store Connect `.p8`,
base64, unwrapped), `AC_API_KEY_ID`, and `AC_API_ISSUER_ID`. Without them a
`v*` tag still builds and signs, it just skips notarization rather than failing.

The repo must exist before secrets can be set, since `gh secret set` resolves
the target from the git remote. Export the identity from Keychain Access
(right-click it, Export, choose `.p12`), then:

```sh
base64 -i Certificates.p12 | tr -d '\n' | gh secret set CERT_P12_BASE64
gh secret set CERT_P12_PASSWORD
gh secret set KEYCHAIN_PASSWORD
gh secret set SIGN_IDENTITY --body "Developer ID Application: Name (TEAMID)"
```

Delete the exported `.p12` afterwards; it contains your private key.

## Alternative that removes the need for all of this

If your Mac admins set `AllowCLIBiometricAuthentication = true` in the
Privileges configuration profile, then
`PrivilegesCLI --add --reason "Developer Requirement"` prompts for Touch ID
directly, with no UI automation and no Accessibility grant. A local override
does not work; the root daemon only honours that key from an MDM profile.

`legacy/privileges-rearm.sh` is the original shell implementation, superseded by
the Swift binary and kept only for reference.
