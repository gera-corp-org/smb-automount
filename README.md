# smb-automount

Auto-mounting of a Windows network share (SMB) on macOS over a corporate VPN.

The stock "Login Items" do not work here: they fire at login, when the VPN is not up yet, and the connection fails silently. This project installs a background agent that waits for the server to appear and mounts the share itself — at login, after the VPN connects and after waking from sleep.

Setup is a double-click on the app; no terminal needed.

## Features

- Non-ASCII share names and spaces in them.
- Credentials form is discovered automatically: `DOMAIN;login`, plain `login` or `login@domain` — whichever the server accepts is the one remembered.
- The share is picked from a list requested from the server instead of typing the name by hand.
- The password lives in the macOS keychain, never in a file.
- The volume is mounted at `/Volumes/<share name>` and appears in Finder as an ordinary network drive.
- A live volume is checked by reading it, not by probing the port, and is unmounted only after three consecutive failures — otherwise it would flicker on every VPN hiccup.
- Every attempt is time-limited, and concurrent runs are blocked.

## Requirements

macOS with the system bash 3.2 (that is, any modern version). Nothing to install: only `mount_smbfs`, `smbutil`, `security`, `launchctl` and `osascript` are used.

## Build

```bash
bash build/build.sh
```

The result lands in `dist/`:

| File | Purpose |
|---|---|
| `Network Folder.app` | setup and management, double-click |
| `Network Folder Log.app` | opens the logs in TextEdit |
| `smb-automount-install.sh` | the same thing for the terminal |

The build substitutes `src/lib/common.sh` for the `@@COMMON@@` marker, embeds the worker script in place of `@@WORKER@@`, checks syntax and bash 3.2 compatibility, then assembles the bundles and archives.

## Tests

```bash
bash tests/run-tests.sh            # worker behaviour against stubs
bash tests/check-bash32.sh file... # compatibility with the system bash on macOS
```

No real server needed: `mount_smbfs`, `osascript`, `mount`, `nc` and `security` are replaced with stubs, and the log plus the fact of mounting are checked. Covered: waiting for the VPN, mounting into `/Volumes`, resilience to network hiccups, recovery after a dropped session, the fallback into the home folder, and a server refusal.

`check-bash32.sh` catches `case` inside `$( )` and a backslash inside `${...}` — bash 5 digests both, while the system bash 3.2 on macOS rejects them with code 258 before the first line of output. The check is part of the build.

## Layout

```
src/
  lib/common.sh     shared functions: URL encoding, login forms, error codes
  worker.sh         worker script: mounts and watches the state
  app.sh            app with macOS dialogs
  cli-install.sh    installer for the terminal
  log-app.sh        app for viewing the logs
build/build.sh      builds dist/
tests/              tests
docs/INSTALL.md     user guide
```

The worker is installed as a standalone file and cannot import anything, so the shared functions are substituted into it at build time rather than sourced at run time.

## What gets installed on the user's machine

| Path | What it is |
|---|---|
| `~/bin/smb-automount.sh` | worker script |
| `~/.config/smb-automount/<server-share>.conf` | settings, no password |
| `~/Library/LaunchAgents/com.user.smb-automount.*.plist` | background agent |
| `~/Library/Logs/smb-automount*.log` | logs |
| `/Volumes/<share name>` | directory for the volume, created once with administrator rights |

To remove: the "Remove" item in the app, or `smb-automount-install.sh --uninstall`.

## License

MIT, see [LICENSE](LICENSE).
