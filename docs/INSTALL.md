# Automatic mounting of a Windows network share on macOS

The share connects by itself: at login and after the corporate VPN comes up. While the VPN is down, the program simply waits.

## Installation

Unpack `Network Folder.app.zip` and launch the app. No terminal needed.

The very first launch has to be **right-click on the app → Open → Open**: the app carries no Apple developer signature, so a double-click on a freshly downloaded copy is refused with "cannot be opened because it is from an unidentified developer". If the dialog offers no "Open" button, go to **System Settings → Privacy & Security** and press **Open Anyway** there. From the second launch on, a double-click is enough.

What it will ask for:

1. **Server address** — host name or IP.
2. **Login** — the short account name (`admin`), not the full `admin@domain`. The domain is a separate field; the program assembles the right form itself.
3. **Domain** — leave empty if there is no domain.
4. **Password** — stored in the macOS keychain, never in a file.
5. **Share** — picked from a list the program fetches from the server. No typing needed, and non-ASCII names are supported.
6. **Directory in `/Volumes`** — macOS will ask for an administrator password once. Without it the volume will not appear under Locations with the share's name: Finder will only show a connection to the server.

On the next launch a menu appears: **Add share**, **Show status**, **Remove**.

## A shortcut within reach

The volume lives under Locations while it is connected. To keep a link always visible, drag the volume from Locations into the **Favorites** section of the sidebar — once, with the mouse. macOS does not allow adding it there programmatically.

If you also want an icon on the desktop: **Finder → Settings → General → Show these items on the desktop: Connected servers**.

## If something goes wrong

Check **Show status** in the program: it lists every share that has been set up, where it is mounted and the last few log lines.

The full logs are `~/Library/Logs/smb-automount.log` (mounting) and `~/Library/Logs/smb-automount-app.log` (the app itself). Open them in any editor — in Finder, **Go → Go to Folder…** and paste `~/Library/Logs` — or from the terminal: `tail -f ~/Library/Logs/smb-automount.log`.

Typical entries:

| Line in the log | What it means |
|---|---|
| `server unreachable (port 445 closed)` | the VPN is down, the program is waiting |
| `permission denied` | login, password, domain, or share permissions |
| `malformed URL` | the share name was passed in the wrong form |
| `NetFS did not answer within 30 s` | the stock macOS mechanism hung; the fallback will take over |
| `directory /Volumes/… is gone` | run setup again and agree to create the directory |

## How it works

- **LaunchAgent** `~/Library/LaunchAgents/com.user.smb-automount.*.plist` — starts at login, checks once a minute and reacts to network changes.
- **Worker script** `~/bin/smb-automount.sh` — mounts and watches the state.
- **Config** `~/.config/smb-automount/<server-share>.conf` — plain text, no password in it.
- A live volume is verified by reading the share, not by probing the port, and is detached only after three failures in a row — otherwise the volume would flicker on every VPN hiccup.
- Every attempt is limited to 30 seconds; parallel runs are held off by a lock.

## Details

- Several shares can be set up independently.
- The mount point is `/Volumes/<share name>`; if the directory there is unavailable, the program falls back to `~/mnt/<share name>` and notes this in the log.
- To remove: the **Remove** item in the program's menu (or `bash smb-automount-install.sh --uninstall` for the terminal variant).
