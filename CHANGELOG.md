# Changelog

Versions follow [semver](https://semver.org). The dated entries under
"Pre-release history" are the builds from before the first published release.

## 1.2.1 — 2026-08-19

- Fixed: the agent was tearing the volume off itself, about every three minutes.
  It checked whether a mounted volume was alive by reading its directory, and
  macOS refuses a launchd agent access to the contents of a network volume —
  `readdir` and `open()` return "Operation not permitted" on a perfectly healthy
  mount, and a background agent cannot ask for consent. That EPERM was taken for
  a dead session, so after three checks the agent force-unmounted a working
  volume and mounted it again. The read-based check had been introduced to stop
  the volume flickering; on a current macOS it was causing it.

  Liveness is now `statfs`, which the agent is allowed and which asks the server
  for free space rather than the kernel for a cached answer. A refusal is never
  read as death: "I was not allowed to look" says nothing about the server, so
  the check falls back to the port probe. Diagnosed on a real machine — the
  volume dropped 26 times in one log, every three minutes and ten seconds.

## 1.2.0 — 2026-08-13

- Setup now asks in the order server, domain, login, password — the domain
  belongs with the server it qualifies, and by the time the password is asked
  for the prompt can name the account the way the server will see it
  (`CORP\admin`). Then, with everything in hand, it checks: a server that does
  not answer on port 445 is now said out loud instead of being passed over in
  silence, which left setup asking for the share name by hand with no
  explanation. It is not treated as a failure — installing while the VPN is
  down is what this program is for — but nothing can be verified then, and now
  it says so.
- Fixed: setup died on the spot when the server turned the credentials down.
  `“$USERNAME”` reads as a variable named `USERNAME”` in bash 3.2 outside a
  UTF-8 locale — the quote's bytes are taken for part of the name — so `set -u`
  killed the script at exactly the point where it was supposed to explain what
  had gone wrong. Five more places had the same shape, among them the app's
  dialog about creating the directory in `/Volumes`. A terminal usually carries
  a UTF-8 locale, which is why this survived there; an app launched from Finder
  and an agent under launchd do not. All six now write `${VAR}`, and
  `check-bash32.sh` refuses the pattern from here on.
- The setup flow has tests: `tests/run-cli-tests.sh` drives the built installer
  with canned answers and checks that each outcome is reported as itself. Until
  now nothing covered the frontends at all.
- The downloads carry the version in their names — `Network-Folder-<version>.app.zip`
  and `smb-automount-install-<version>.sh` — so a copy found on a disk months
  later can still say what it is, and the two no longer differ only by the date
  they were fetched. They also lost their spaces, which GitHub rewrote as dots
  in the release links. Inside the archive the bundle is still plain
  `Network Folder.app`, and the installer's `--help` now prints the name of the
  file it was actually run from rather than a generic one.

## 1.1.2 — 2026-08-12

- Fixed: a server that answers on port 445 but never gets as far as an SMB
  session was reported as rejecting the password. Setup said the credentials
  were accepted "in no form" and named a typo or a wrong domain as the likely
  cause, while the worker ground through every login form and both mount
  methods, each one timing out. Nothing was ever authenticated — there was no
  SMB session to authenticate over. `probe_mode` now separates the two: exit 1
  is a real rejection, exit 2 means nothing was checked. Both frontends say so
  and point at name resolution, and the worker stops after the first such
  failure instead of repeating it eight more times. A VPN client intercepting
  DNS and handing back a stand-in address (198.18.x.x) is the usual cause; that
  is what sent a day of debugging after a password that was never the problem.

## 1.1.1 — 2026-08-12

- Fixed: a password holding any character outside ASCII — an umlaut, a Cyrillic
  letter, an emoji — never mounted. `security … -w` hands such a password back
  as a hex dump rather than the text, and the worker sent that dump to
  the server verbatim, so every attempt came back as "permission denied". Setup
  gave no hint of it: it still had the typed password in memory and connected
  fine. The worker now recognises a dump (confirmed against `security … -g`,
  which prefixes a real one with `0x`) and decodes it; a password that merely
  looks like hex, such as `deadbeef`, is left alone. Nothing was wrong with what
  the keychain stored, so the fix needs no password re-entry — only the worker
  is rewritten. ASCII punctuation was never affected.

## 1.1.0 — 2026-08-10

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
