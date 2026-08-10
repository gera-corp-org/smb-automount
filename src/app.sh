#!/bin/bash
#
# smb-automount.app — graphical installer for automounting a Windows SMB share.
# Launched by double-click from Finder; no terminal needed.
#
set -u

# --- the app's own log: always written, even if no dialog ever appeared.
# See: ~/Library/Logs/smb-automount-app.log
APPLOG="$HOME/Library/Logs/smb-automount-app.log"
mkdir -p "$(dirname "$APPLOG")" 2>/dev/null
alog() { echo "$(date '+%F %T') $*" >>"$APPLOG" 2>/dev/null; }
VERSION="2026-08-10.8"
alog "=== start (version $VERSION): $0"
alog "    bash $BASH_VERSION, uid $(id -u), TERM=${TERM:-none}"
trap 'alog "=== exit, code $?"' EXIT
exec 2>>"$APPLOG"        # bash errors go to the log as well

TITLE="Network Folder"
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/smb-automount"
AGENT_DIR="$HOME/Library/LaunchAgents"
WORKER="$BIN_DIR/smb-automount.sh"
LABEL_PREFIX="com.user.smb-automount"
LOG="$HOME/Library/Logs/smb-automount.log"

# ------------------------------------------------------------------- UI ------
# Escaping for an AppleScript string literal: backslash, quote and newline
# (an AppleScript string cannot contain a real line break).
esc() { printf %s "$1" | /usr/bin/perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'; }

ui_input() { # prompt default [hidden]
  local p d hidden extra
  p=$(esc "$1"); d=$(esc "${2:-}"); hidden="${3:-}"
  [ -n "$hidden" ] && extra="with hidden answer" || extra=""
  /usr/bin/osascript <<OSA 2>/dev/null
set r to display dialog "$p" default answer "$d" $extra with title "$TITLE" buttons {"Cancel", "Next"} default button "Next" with icon note
return text returned of r
OSA
}

ui_msg() { # text [icon: note|caution|stop]
  local t i
  t=$(esc "$1"); i="${2:-note}"
  /usr/bin/osascript <<OSA >/dev/null 2>&1
display dialog "$t" with title "$TITLE" buttons {"OK"} default button "OK" with icon $i
OSA
}

ui_confirm() { # text [ok_label] [cancel_label]
  local t ok no
  t=$(esc "$1"); ok=$(esc "${2:-Yes}"); no=$(esc "${3:-No}")
  /usr/bin/osascript <<OSA >/dev/null 2>&1
set r to display dialog "$t" with title "$TITLE" buttons {"$no", "$ok"} default button "$ok" with icon note
if button returned of r is not "$ok" then error number -128
OSA
}

ui_menu() { # text b1 b2 b3(default) -> prints the button pressed
  local t b1 b2 b3
  alog "ui_menu: calling osascript"
  t=$(esc "$1"); b1=$(esc "$2"); b2=$(esc "$3"); b3=$(esc "$4")
  /usr/bin/osascript <<OSA 2>/dev/null
set r to display dialog "$t" with title "$TITLE" buttons {"$b1", "$b2", "$b3"} default button "$b3" with icon note
return button returned of r
OSA
}

ui_pick() { # prompt; list of lines on stdin -> prints the chosen one
  local p line as_items=""
  p=$(esc "$1")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "$as_items" ] && as_items="$as_items, "
    as_items="$as_items\"$(esc "$line")\""
  done
  [ -n "$as_items" ] || return 1
  /usr/bin/osascript <<OSA 2>/dev/null
set r to choose from list {$as_items} with title "$TITLE" with prompt "$p" OK button name "Choose" cancel button name "Cancel"
if r is false then error number -128
return item 1 of r
OSA
}

# @@COMMON@@



# Mount point of the share if it is mounted (empty otherwise). The system picks
# the volume name in /Volumes, so we search by server and share name.
mounted_path() { # server share
  /sbin/mount -t smbfs 2>/dev/null | SRV="$1" SH="$2" SHE="$(urlenc "$2")" \
    /usr/bin/perl -ne '
      my ($src, $mp) = /^(\S+) on (.+?) \(/ or next;
      my $s = lc $src;
      next unless index($s, lc $ENV{SRV}) >= 0;
      if (index($s, lc $ENV{SH}) >= 0 || index($s, lc $ENV{SHE}) >= 0) { print "$mp\n"; last; }
    '
}


# A non-ASCII name leaves no ASCII part behind, so a hash is always appended to
# the identifier — otherwise different shares would get the same config name.
slugify() {
  local ascii hash
  ascii=$(printf %s "$1" | tr '[:upper:]' '[:lower:]' \
          | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-40)
  ascii=$(printf %s "$ascii" | sed -E 's/-$//')
  hash=$(printf %s "$1" | { md5 -q 2>/dev/null || md5sum | cut -d' ' -f1; } | cut -c1-6)
  printf '%s\n' "${ascii:-share}-$hash"
}

reachable() { /usr/bin/nc -z -G 3 "$1" 445 >/dev/null 2>&1; }

# Which credential form the server accepts. Prints the mode, or nothing.
probe_mode() { # server user domain password
  local m
  for m in $(auth_modes "$3"); do
    if /usr/bin/smbutil view -N "//$(auth_str "$m" "$2" "$3" "$4")@$1" >/dev/null 2>&1; then
      printf '%s\n' "$m"; return 0
    fi
  done
  return 1
}

list_shares() { # server user domain password mode
  /usr/bin/smbutil view -N "//$(auth_str "$5" "$2" "$3" "$4")@$1" 2>/dev/null \
    | /usr/bin/sed -nE 's/[[:space:]]{2,}Disk([[:space:]].*)?$//p' \
    | /usr/bin/grep -v '^Share$' \
    | /usr/bin/grep -v '\$$' \
    | /usr/bin/sed -E 's/[[:space:]]+$//' \
    | /usr/bin/grep -v '^$'
}

# Removes stale configs/agents for the same share left over from earlier
# versions (the config identifier changed, otherwise a second agent would
# live alongside).
drop_duplicates() { # server share keep_slug
  local f other
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    other=$(basename "$f" .conf)
    [ "$other" = "$3" ] && continue
    ( . "$f"; [ "$SERVER" = "$1" ] && [ "$SHARE" = "$2" ] ) || continue
    launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$other" 2>/dev/null
    rm -f "$AGENT_DIR/$LABEL_PREFIX.$other.plist" "$f"
  done
}

# ------------------------------------------------------------------ worker ---
write_worker() {
  mkdir -p "$BIN_DIR"
  cat >"$WORKER" <<'WORKER_EOF'
# @@WORKER@@
WORKER_EOF
  chmod +x "$WORKER"
}

conf_list() {
  local f
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    ( . "$f"; printf '%s\n' "//$SERVER/$SHARE" )
  done
}

conf_by_label() { # "//server/share" -> path to the .conf
  local want="$1" f
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    ( . "$f"; [ "//$SERVER/$SHARE" = "$want" ] ) && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# ----------------------------------------------------------------- status ----
do_status() {
  local out="" f line
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    line=$( . "$f"
      mp=$(mounted_path "$SERVER" "$SHARE")
      if [ -n "$mp" ]; then
        s="connected"
        raw=$(/sbin/mount -t smbfs 2>/dev/null | grep -F " on $mp " | head -1)
        # no case here: bash 3.2 cannot parse case inside $( ... )
        if [ "${raw#*nobrowse}" != "$raw" ]; then
          s="connected, but hidden from Finder (nobrowse)"
        fi
      else
        s="not connected"; mp="$MOUNTPOINT"
      fi
      printf '•  //%s/%s\n    %s\n    %s' "$SERVER" "$SHARE" "$mp" "$s" )
    out="$out$line"$'\n\n'
  done
  [ -n "$out" ] || out="Nothing has been set up yet."$'\n\n'
  if [ -f "$LOG" ]; then
    out="$out"'Latest log entries:'$'\n'"$(tail -6 "$LOG")"
  fi
  ui_msg "$out"
}

# ----------------------------------------------------------------- removal ---
do_uninstall() {
  local pick conf slug
  pick=$(conf_list | ui_pick "Which connection should be removed?") || return 0
  conf=$(conf_by_label "$pick") || { ui_msg "No config found for $pick" caution; return 0; }
  slug=$(basename "$conf" .conf)
  ui_confirm "Remove automounting of $pick?" "Remove" "Cancel" || return 0

  launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$slug" 2>/dev/null
  rm -f "$AGENT_DIR/$LABEL_PREFIX.$slug.plist"
  ( . "$conf"
    mp=$(mounted_path "$SERVER" "$SHARE")
    [ -n "$mp" ] && { /sbin/umount -f "$mp" 2>/dev/null || /usr/sbin/diskutil unmount force "$mp" 2>/dev/null; }
    rmdir "${FALLBACK:-}" 2>/dev/null
    if ui_confirm "Also delete the saved password from the keychain?" "Delete" "Keep"; then
      /usr/bin/security delete-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
    fi )
  rm -f "$conf"
  ui_msg "Done: $pick disconnected."
}

# ------------------------------------------------------------ installation ---
do_install() {
  local SERVER SHARE USERNAME DOMAIN MOUNTPOINT INTERVAL SLUG KEYCHAIN_SERVICE
  local PASS PASS2 shares picked MODE="" FALLBACK MP

  SERVER=$(ui_input "Server address — host name or IP.

For example: fileserver.corp.local" "") || return 0
  [ -n "$SERVER" ] || { ui_msg "No server address given." caution; return 0; }

  USERNAME=$(ui_input "Your login on the server:" "$(id -un)") || return 0
  [ -n "$USERNAME" ] || { ui_msg "No login given." caution; return 0; }

  DOMAIN=$(ui_input "Active Directory domain.

If there is no domain, leave the field empty." "") || return 0

  while :; do
    PASS=$(ui_input "Password for $USERNAME@$SERVER:" "" hidden) || return 0
    [ -n "$PASS" ] && break
    ui_msg "The password cannot be empty." caution
  done

  # --- verify the credentials and fetch the list of shares ---
  SHARE=""
  local DOMSLASH DOMAT
  if [ -n "$DOMAIN" ]; then DOMSLASH="$DOMAIN\\"; DOMAT="$DOMAIN"; else DOMSLASH=""; DOMAT="domain"; fi
  if reachable "$SERVER"; then
    MODE=$(probe_mode "$SERVER" "$USERNAME" "$DOMAIN" "$PASS") || MODE=""
    if [ -z "$MODE" ]; then
      ui_confirm "Server $SERVER does not accept these credentials in any form:

  $USERNAME
  $DOMSLASH$USERNAME
  $USERNAME@$DOMAT

Usually this is a typo in the password, or a domain that is either extra or missing. Continue anyway?" "Continue" "Cancel" || return 0
    else
      shares=$(list_shares "$SERVER" "$USERNAME" "$DOMAIN" "$PASS" "$MODE")
      if [ -n "$shares" ]; then
        picked=$(printf '%s\n' "$shares" | ui_pick "Shares available on $SERVER:") || return 0
        SHARE="$picked"
      else
        ui_msg "The credentials were accepted, but the server did not return a list of shares. You can type the share name by hand in the next step." caution
      fi
    fi
  fi

  if [ -z "$SHARE" ]; then
    SHARE=$(ui_input "Name of the network share on the server — exactly as on Windows, case matters.

For example: Documents or Shared Files" "") || return 0
    [ -n "$SHARE" ] || { ui_msg "No share name given." caution; return 0; }
  fi

  # Mounted through the stock macOS mechanism — the volume shows up in /Volumes
  # under the share name, just like connecting via ⌘K. The system picks the
  # exact path.
  MOUNTPOINT="/Volumes/$SHARE"
  FALLBACK="$HOME/mnt/$SHARE"

  INTERVAL=$(ui_input "How often to check whether the VPN is up (seconds):" "60") || return 0
  case "$INTERVAL" in (*[!0-9]*|'') INTERVAL=60 ;; esac

  SLUG=$(slugify "$SERVER-$SHARE")
  KEYCHAIN_SERVICE="smb:$SERVER/$SHARE"

  /usr/bin/security add-generic-password -U \
    -a "$USERNAME" -s "$KEYCHAIN_SERVICE" \
    -l "smb-automount: $SERVER/$SHARE" \
    -T /usr/bin/security -w "$PASS" >/dev/null 2>&1 \
    || { ui_msg "Could not save the password to the keychain." stop; return 1; }
  unset PASS PASS2

  local SHOWUSER
  if [ -n "$DOMAIN" ]; then SHOWUSER="$DOMAIN\\$USERNAME"; else SHOWUSER="$USERNAME"; fi

  ui_confirm "Please check the details:

Server:  $SERVER
Share:   $SHARE
Login:   $SHOWUSER
Mount as volume:  $SHARE (in /Volumes, as via ⌘K)
Check every $INTERVAL sec.

Set up automounting?" "Set up" "Cancel" || return 0

  mkdir -p "$CONF_DIR" "$AGENT_DIR" "$BIN_DIR"
  chmod 700 "$CONF_DIR"
  drop_duplicates "$SERVER" "$SHARE" "$SLUG"

  cat >"$CONF_DIR/$SLUG.conf" <<CONF_EOF
# smb-automount: $SERVER/$SHARE
# created $(date '+%F %T'). No password here — it lives in the keychain.
SERVER="$SERVER"
SHARE="$SHARE"
USERNAME="$USERNAME"
DOMAIN="$DOMAIN"
MOUNTPOINT="$MOUNTPOINT"
FALLBACK="$FALLBACK"
KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE"
AUTHMODE="$MODE"
CONF_EOF

  # /Volumes is not writable by a regular user. The directory for the volume is
  # created once with administrator privileges — otherwise Finder shows a plain
  # server connection instead of a volume.
  if [ ! -d "$MOUNTPOINT" ] && ! mkdir -p "$MOUNTPOINT" 2>/dev/null; then
    if ui_confirm "For the share to appear in Finder as a separate volume named “$SHARE”, a directory has to be created once:

$MOUNTPOINT

macOS will ask for an administrator password. If you decline, the share will be mounted inside your home folder and the sidebar will show the server name instead." "Create" "Skip"; then
      local mkcmd
      mkcmd="mkdir -p '$MOUNTPOINT' && chown $(id -u):$(id -g) '$MOUNTPOINT'"
      /usr/bin/osascript -e "do shell script \"$(esc "$mkcmd")\" with administrator privileges" >/dev/null 2>&1
      if [ -d "$MOUNTPOINT" ]; then
        alog "directory $MOUNTPOINT created"
      else
        ui_msg "The directory could not be created. The share will be mounted inside your home folder." caution
      fi
    fi
  fi

  write_worker

  local PLIST="$AGENT_DIR/$LABEL_PREFIX.$SLUG.plist"
  cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL_PREFIX.$SLUG</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WORKER</string>
        <string>$CONF_DIR/$SLUG.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>WatchPaths</key>
    <array>
        <string>/etc/resolv.conf</string>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

  launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$SLUG" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null \
    || { ui_msg "Could not start the background agent." stop; return 1; }

  if reachable "$SERVER"; then
    # An old mount of the same share (say, in ~/mnt from a previous version)
    # would make the agent think everything is already connected. Unmount it.
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
      sleep 1
    fi
    # The background agent may already be running and holding the lock — wait
    # for it, otherwise our run would silently do nothing.
    local lockf waited tries
    lockf="$CONF_DIR/$SLUG.lock"
    waited=0
    while [ -f "$lockf" ] && [ "$waited" -lt 60 ]; do
      sleep 2
      waited=$((waited + 2))
    done
    alog "starting the mount (waited $waited s for the lock)"
    /bin/bash "$WORKER" "$CONF_DIR/$SLUG.conf"
    # Mounting over VPN takes time; wait up to a minute for the volume.
    MP=$(mounted_path "$SERVER" "$SHARE")
    tries=0
    while [ -z "$MP" ] && [ "$tries" -lt 30 ]; do
      sleep 2
      tries=$((tries + 1))
      MP=$(mounted_path "$SERVER" "$SHARE")
    done
    alog "mount result: ${MP:-not mounted}"
    if [ -n "$MP" ]; then
      if ui_confirm "Done — the share is connected:
$MP

From now on it will connect by itself after every login and after the VPN comes up.

Open it in Finder?" "Open" "Later"; then
        open "$MP"
      fi
    else
      ui_msg "The setup was saved, but the connection failed.

Log ($LOG):

$(tail -4 "$LOG" 2>/dev/null)" caution
    fi
  else
    ui_msg "The setup was saved.

Server $SERVER is unreachable right now — the VPN appears to be down. That is fine: the share will connect by itself within $INTERVAL sec. after the VPN comes up, and then at every login." note
  fi
}

# -------------------------------------------------------------------- main ---
main() {
  alog "main: configs found: $(conf_list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS only" >&2; exit 1
  fi
  if [ -n "$(conf_list 2>/dev/null)" ]; then
    alog "main: showing the menu"
    local choice
    choice=$(ui_menu "Network folder automounting.

What would you like to do?" "Remove" "Show status" "Add share")
    case "$choice" in
      "Add share")   do_install ;;
      "Show status") do_status ;;
      "Remove")      do_uninstall ;;
      *) exit 0 ;;
    esac
  else
    alog "main: no configs, going straight to setup"
    do_install
  fi
}

main
