#!/bin/bash
# Opens the smb-automount logs in TextEdit. No terminal needed.
L1="$HOME/Library/Logs/smb-automount-app.log"
L2="$HOME/Library/Logs/smb-automount.log"
mkdir -p "$HOME/Library/Logs" 2>/dev/null
[ -f "$L1" ] || echo "(the app log is empty — meaning the app has never started)" > "$L1"
[ -f "$L2" ] || echo "(the mount log is empty)" > "$L2"
{
  echo "--- system information ---"
  echo "date:     $(date '+%F %T')"
  echo "macOS:    $(sw_vers -productVersion 2>/dev/null)"
  echo "bash:     $BASH_VERSION"
  echo "configs:  $(ls -1 "$HOME/.config/smb-automount"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
  echo "agents:   $(ls -1 "$HOME/Library/LaunchAgents"/com.user.smb-automount.*.plist 2>/dev/null | wc -l | tr -d ' ')"
  echo "smbfs mounts:"
  /sbin/mount -t smbfs 2>/dev/null | sed 's/^/  /'
  echo "quarantine on the app:"
  xattr -l "$HOME/Downloads/Network Folder.app" 2>/dev/null | sed 's/^/  /'
} > "$HOME/Library/Logs/smb-automount-system.txt" 2>&1
open -a TextEdit "$HOME/Library/Logs/smb-automount-system.txt" "$L1" "$L2"
