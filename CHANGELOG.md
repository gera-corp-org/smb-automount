# Changelog

## 2026-08-10.8

- After detaching a hung volume the mount now happens immediately, in the same
  pass, instead of a minute later.
- A separate log message when the directory in `/Volumes` has disappeared:
  without administrator privileges it cannot be restored, so setup has to be
  run again.

## 2026-08-10.7

- The version is written to the app log — you can tell which copy is running.
- The app now waits for the background agent instead of silently exiting
  because of the lock, and waits up to a minute for the volume rather than one
  second.

## 2026-08-10.6

- Mounting into `/Volumes/<share name>`; the directory is created once with
  administrator privileges. Without this Finder showed a server connection
  rather than a volume.
- A live volume is verified by reading it, not by probing the port: a single
  failed probe over VPN used to detach a working volume, making it flicker once
  a minute.
- Detaching only after three failures in a row.

## 2026-08-10.5

- A time limit on every attempt: `mount volume` could hang forever waiting on an
  invisible dialog, and the agent piled up stuck copies.
- A lock against parallel runs.
- State is written to the log only when it changes.

## 2026-08-10.4

- Fixed bash 3.2 incompatibilities: `case` inside `$( )` and a backslash inside
  `${...}`. The app used to quit right after launch with code 258.
- bash errors are written to the app log.

## 2026-08-10.3

- Credential forms are tried in turn: `DOMAIN;login`, `login`, `login@domain`.
  The working form is remembered in the config.
- The share is picked from a list fetched from the server.

## 2026-08-10.2

- The share name is passed percent-encoded: non-ASCII characters and spaces.
- Success is determined by the fact of mounting, not by the return code.

## 2026-08-10.1

- First working version: LaunchAgent, password in the keychain, waiting for the
  VPN.
