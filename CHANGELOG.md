# Changelog

Versions follow [semver](https://semver.org). The dated entries under
"Pre-release history" are the builds from before the first published release.

## Unreleased

- The "Network Folder Log" app is gone. It only opened the two log files in
  TextEdit next to a system dump, while "Show status" in the app already reports
  the state and the last log lines; the logs stay where they were, in
  `~/Library/Logs`. One app to ship, one to get past Gatekeeper.
- The app log records `uname -m`, so a support log says whether it came from an
  Intel Mac or an Apple Silicon one.
- CI and the release now run the tests and the build on both architectures. The
  artifacts stay single: the bundles hold shell scripts, so there is nothing to
  compile per architecture.

## 1.0.0 — 2026-08-10

First published release. The pre-release builds were passed around by hand;
from here on the apps and the installer come from the Releases page and are
built by CI on macOS.

- A background agent that mounts the share at login, after the VPN comes up and
  after waking from sleep — the stock "Login Items" fire too early and fail
  silently.
- Setup is a double-click on `Network Folder.app`; `smb-automount-install.sh`
  does the same from the terminal.
- Non-ASCII share names and spaces in them; the share is picked from a list
  fetched from the server.
- The credentials form (`DOMAIN;login`, `login`, `login@domain`) is discovered
  automatically and the working one is remembered.
- The password lives in the macOS keychain, never in a file.
- The volume is mounted at `/Volumes/<share name>` and appears in Finder as an
  ordinary network drive.
- A live volume is verified by reading it and detached only after three failed
  checks in a row, so a VPN hiccup no longer makes it flicker.
- Every attempt is time-limited and parallel runs are held off by a lock.
- The build stamps this version into the apps and the installer:
  `smb-automount-install.sh --version`, and the app writes it to its log.

## Pre-release history

### 2026-08-10.8

- After detaching a hung volume the mount now happens immediately, in the same
  pass, instead of a minute later.
- A separate log message when the directory in `/Volumes` has disappeared:
  without administrator privileges it cannot be restored, so setup has to be
  run again.

### 2026-08-10.7

- The version is written to the app log — you can tell which copy is running.
- The app now waits for the background agent instead of silently exiting
  because of the lock, and waits up to a minute for the volume rather than one
  second.

### 2026-08-10.6

- Mounting into `/Volumes/<share name>`; the directory is created once with
  administrator privileges. Without this Finder showed a server connection
  rather than a volume.
- A live volume is verified by reading it, not by probing the port: a single
  failed probe over VPN used to detach a working volume, making it flicker once
  a minute.
- Detaching only after three failures in a row.

### 2026-08-10.5

- A time limit on every attempt: `mount volume` could hang forever waiting on an
  invisible dialog, and the agent piled up stuck copies.
- A lock against parallel runs.
- State is written to the log only when it changes.

### 2026-08-10.4

- Fixed bash 3.2 incompatibilities: `case` inside `$( )` and a backslash inside
  `${...}`. The app used to quit right after launch with code 258.
- bash errors are written to the app log.

### 2026-08-10.3

- Credential forms are tried in turn: `DOMAIN;login`, `login`, `login@domain`.
  The working form is remembered in the config.
- The share is picked from a list fetched from the server.

### 2026-08-10.2

- The share name is passed percent-encoded: non-ASCII characters and spaces.
- Success is determined by the fact of mounting, not by the return code.

### 2026-08-10.1

- First working version: LaunchAgent, password in the keychain, waiting for the
  VPN.
