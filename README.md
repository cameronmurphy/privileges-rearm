# privileges-rearm

Renews SAP Privileges admin with a single Touch ID tap, instead of hunting the
menu bar, picking a reason, and hitting submit every few hours.

## Install

Open `PrivilegesRearm.app`. It copies itself to `~/Applications`, starts
watching in the background, and asks for Accessibility permission.

Approve **PrivilegesRearm** in System Settings > Privacy & Security >
Accessibility. That's the whole setup.

From then on, when your admin access expires, the request dialog opens, selects
**Developer Requirement**, submits itself, and macOS asks for your fingerprint.
It reacts within 15 seconds.

## It always asks for your fingerprint

This automates the clicking, never the authentication. It cannot grant itself
admin: without your live fingerprint nothing happens, and every grant is still
recorded with a reason, exactly as before. It only removes the tedious part.

It moves the mouse for about a second while it runs. It never types, so it
can't interfere with what you're writing.

## If nothing happens

Check the log:

```sh
tail ~/Library/Application\ Support/privileges-rearm/rearm.log
```

`accessibility=false` means the Accessibility toggle isn't on for the app.

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.cammurphy.privileges-rearm.plist
rm -f ~/Library/LaunchAgents/com.cammurphy.privileges-rearm.plist
rm -rf ~/Applications/PrivilegesRearm.app
```

Then remove the `PrivilegesRearm` entry from the Accessibility list.

---

Building, signing, and how it works internally: [DEVELOPING.md](DEVELOPING.md).
