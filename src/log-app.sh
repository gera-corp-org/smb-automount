#!/bin/bash
# Открывает журналы smb-automount в TextEdit. Терминал не нужен.
L1="$HOME/Library/Logs/smb-automount-app.log"
L2="$HOME/Library/Logs/smb-automount.log"
mkdir -p "$HOME/Library/Logs" 2>/dev/null
[ -f "$L1" ] || echo "(журнал приложения пуст — значит приложение ни разу не стартовало)" > "$L1"
[ -f "$L2" ] || echo "(журнал монтирования пуст)" > "$L2"
{
  echo "--- сведения о системе ---"
  echo "дата:    $(date '+%F %T')"
  echo "macOS:   $(sw_vers -productVersion 2>/dev/null)"
  echo "bash:    $BASH_VERSION"
  echo "конфиги: $(ls -1 "$HOME/.config/smb-automount"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
  echo "агенты:  $(ls -1 "$HOME/Library/LaunchAgents"/com.user.smb-automount.*.plist 2>/dev/null | wc -l | tr -d ' ')"
  echo "smbfs-монтирования:"
  /sbin/mount -t smbfs 2>/dev/null | sed 's/^/  /'
  echo "карантин на приложении:"
  xattr -l "$HOME/Downloads/Сетевая папка.app" 2>/dev/null | sed 's/^/  /'
} > "$HOME/Library/Logs/smb-automount-система.txt" 2>&1
open -a TextEdit "$HOME/Library/Logs/smb-automount-система.txt" "$L1" "$L2"
