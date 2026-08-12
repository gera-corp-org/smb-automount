# smb-automount

[![CI](https://github.com/gera-corp-org/smb-automount/actions/workflows/ci.yml/badge.svg)](https://github.com/gera-corp-org/smb-automount/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gera-corp-org/smb-automount)](https://github.com/gera-corp-org/smb-automount/releases/latest)

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

Intel and Apple Silicon are the same download. The `.app` bundles hold shell scripts rather than compiled binaries — there is no Mach-O code to build per architecture — and the interpreter is the system `/bin/bash`, which macOS ships as a universal binary. Both architectures are tested in CI all the same.

## Install

Take the files from the [latest release](https://github.com/gera-corp-org/smb-automount/releases/latest) — they carry the version in their names, `Network-Folder-<version>.app.zip` and `smb-automount-install-<version>.sh`. Unpack the archive and open the app; inside it the bundle is plain `Network Folder.app`.

The app is not signed by an Apple developer account, so the first launch goes through **right-click → Open → Open**; a plain double-click is refused by macOS as "from an unidentified developer". Later launches are ordinary double-clicks. See [docs/INSTALL.md](docs/INSTALL.md).

## Build

```bash
bash build/build.sh
```

The result lands in `dist/`:

| File | Purpose |
|---|---|
| `Network-Folder-<version>.app.zip` | the download: the app, archived |
| `Network Folder.app` | the bundle itself, for a local run |
| `smb-automount-install-<version>.sh` | the same setup for the terminal |

The two downloads carry the version so a copy found on a disk months later can
still say what it is, and they carry no spaces so the release links stay
readable — GitHub rewrites a space in an asset name as a dot.

The build substitutes `src/lib/common.sh` for the `@@COMMON@@` marker, embeds the worker script in place of `@@WORKER@@`, stamps the version over `@@VERSION@@`, checks syntax and bash 3.2 compatibility, then assembles the bundles and archives.

The version comes from the `VERSION` file — the single source for the apps' `Info.plist`, the app log and `smb-automount-install.sh --version`. `VERSION=1.2.3 bash build/build.sh` overrides it for a one-off build.

## Tests

```bash
bash tests/run-tests.sh            # worker behaviour against stubs
bash tests/check-bash32.sh file... # compatibility with the system bash on macOS
```

No real server needed: `mount_smbfs`, `osascript`, `mount`, `nc` and `security` are replaced with stubs, and the log plus the fact of mounting are checked. Covered: waiting for the VPN, mounting into `/Volumes`, resilience to network hiccups, recovery after a dropped session, the fallback into the home folder, and a server refusal.

`check-bash32.sh` catches `case` inside `$( )` and a backslash inside `${...}` — bash 5 digests both, while the system bash 3.2 on macOS rejects them with code 258 before the first line of output. The check is part of the build.

On every push and pull request [CI](.github/workflows/ci.yml) runs the tests and the build on two macOS runners — Apple Silicon (`macos-latest`) and Intel (`macos-15-intel`) — where `/bin/bash` really is 3.2, and keeps `dist/` as a build artifact from each. Each job asserts its own `uname -m`, so a relabelled runner cannot quietly turn the Intel leg into a second arm64 one, and prints the installer's checksum: the two are equal, which is the practical meaning of "architecture-independent" here.

## Releasing

1. Bump `VERSION` and add a `## <version>` section to [CHANGELOG.md](CHANGELOG.md) — it becomes the release notes; `bash build/release-notes.sh` prints what they will say.
2. Commit, then `git tag vX.Y.Z && git push origin master --tags`.
3. [The release workflow](.github/workflows/release.yml) checks that the tag matches `VERSION` and runs the tests and the build on Intel and on Apple Silicon; only if both pass does it publish a GitHub release with the `.app.zip` archive and the installer attached, both named with the version.

## Layout

```
VERSION             the version, single source for build and release
src/
  lib/common.sh     shared functions: URL encoding, login forms, error codes
  worker.sh         worker script: mounts and watches the state
  app.sh            app with macOS dialogs
  cli-install.sh    installer for the terminal
build/
  build.sh          builds dist/
  release-notes.sh  pulls one version's section out of the changelog
  release-footer.md install instructions appended to the release notes
tests/              tests
.github/workflows/  CI on macOS and the release on a tag
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
