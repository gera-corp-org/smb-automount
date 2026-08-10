---

## Install

1. Download the "Network Folder.app" archive below (GitHub writes its spaces as
   dots), unpack it and move `Network Folder.app` to `/Applications` (or
   anywhere else).
2. The app is not signed by an Apple developer account, so the first launch has
   to go through **right-click → Open → Open**. A plain double-click is refused
   by macOS with "cannot be opened because it is from an unidentified
   developer". Every later launch is an ordinary double-click.
3. Answer the questions: server, login, domain, password, share. macOS asks for
   an administrator password once, to create the directory in `/Volumes`.

For the terminal: `bash smb-automount-install.sh` (`--list`, `--uninstall`,
`--version`).

`Network Folder Log.app` opens the logs in TextEdit when something goes wrong.

Full guide: [docs/INSTALL.md](docs/INSTALL.md).
