#!/bin/bash
#
# smb-automount — installer for automounting a Windows SMB share on macOS.
#
# One file: copy it to any machine, run it, answer the questions.
#   bash smb-automount-install.sh              — install / reinstall
#   bash smb-automount-install.sh --uninstall  — remove
#   bash smb-automount-install.sh --list       — what is already installed
#   bash smb-automount-install.sh --version    — the version of this file
#
# Designed for work over a corporate VPN: while the VPN is down no mount is
# attempted; as soon as the server becomes reachable the share connects by
# itself.
#

set -u

VERSION="@@VERSION@@"      # substituted by the build from the VERSION file
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/smb-automount"
AGENT_DIR="$HOME/Library/LaunchAgents"
WORKER="$BIN_DIR/smb-automount.sh"
LABEL_PREFIX="com.user.smb-automount"

c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
err()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

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


list_shares() { # server user domain password mode
  /usr/bin/smbutil view -N "//$(auth_str "$5" "$2" "$3" "$4")@$1" 2>/dev/null \
    | /usr/bin/sed -nE 's/[[:space:]]{2,}Disk([[:space:]].*)?$//p' \
    | /usr/bin/grep -v '^Share$' \
    | /usr/bin/grep -v '\$$' \
    | /usr/bin/sed -E 's/[[:space:]]+$//' \
    | /usr/bin/grep -v '^$'
}

ask() { # ask <variable> <question> [default] [allow_empty]
  local __var="$1" __q="$2" __def="${3:-}" __allow="${4:-}" __in=""
  while :; do
    if [ -n "$__def" ]; then
      printf '%s%s%s [%s]: ' "$c_b" "$__q" "$c_0" "$__def"
    else
      printf '%s%s%s: ' "$c_b" "$__q" "$c_0"
    fi
    IFS= read -r __in || die "input interrupted"
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ] && [ "$__allow" != "allow_empty" ]; then
      warn "an answer is required"
      continue
    fi
    break
  done
  eval "$__var=\$__in"
}

yesno() { # yesno <question> <default y|n>
  local q="$1" def="${2:-y}" ans hint
  [ "$def" = "y" ] && hint="Y/n" || hint="y/N"
  printf '%s%s%s [%s]: ' "$c_b" "$q" "$c_0" "$hint"
  IFS= read -r ans || return 1
  ans=$(printf %s "${ans:-$def}" | tr '[:upper:]' '[:lower:]')
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
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

# ------------------------------------------------------------------ list -----
cmd_list() {
  local found=0 f
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    found=1
    # shellcheck disable=SC1090
    ( . "$f"
      mp=$(mounted_path "$SERVER" "$SHARE")
      if [ -n "$mp" ]; then st="${c_g}mounted${c_0}"; else st="${c_y}not mounted${c_0}"; mp="$MOUNTPOINT"; fi
      printf '  %s//%s/%s%s  ->  %s  [%b]\n' "$c_b" "$SERVER" "$SHARE" "$c_0" "$mp" "$st" )
  done
  [ "$found" = 1 ] || say "  (nothing installed)"
}

# ------------------------------------------------------------- uninstall -----
cmd_uninstall() {
  say ""
  say "${c_b}Installed connections:${c_0}"
  cmd_list
  say ""
  local slugs=() f s
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .conf)
    slugs+=("$s")
  done
  [ ${#slugs[@]} -gt 0 ] || { say "Nothing to remove."; exit 0; }

  for s in "${slugs[@]}"; do
    yesno "Remove “$s”?" n || continue
    launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$s" 2>/dev/null
    rm -f "$AGENT_DIR/$LABEL_PREFIX.$s.plist"
    # shellcheck disable=SC1090
    ( . "$CONF_DIR/$s.conf"
      mp=$(mounted_path "$SERVER" "$SHARE")
      [ -n "$mp" ] && { /sbin/umount -f "$mp" 2>/dev/null || /usr/sbin/diskutil unmount force "$mp" 2>/dev/null; }
      rmdir "${FALLBACK:-}" 2>/dev/null
      if yesno "  Delete the password from the keychain as well?" n; then
        /usr/bin/security delete-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 \
          && echo "  password deleted"
      fi )
    rm -f "$CONF_DIR/$s.conf"
    ok "“$s” removed"
  done
  exit 0
}

# --------------------------------------------------------------- install -----
cmd_install() {
  [ "$(uname -s)" = "Darwin" ] || die "this script is meant for macOS"

  say ""
  say "${c_b}=== Automounting a Windows network share ===${c_0}"
  say "Answer the questions; Enter accepts the value in brackets."
  say ""

  ask SERVER   "Server address (host name or IP)"
  ask USERNAME "Login" "$(id -un)"
  ask DOMAIN   "AD domain (Enter — if none)" "" allow_empty

  local P1 P2
  while :; do
    printf '%sPassword%s (not shown): ' "$c_b" "$c_0"; IFS= read -rs P1; echo
    printf '%sPassword again%s: ' "$c_b" "$c_0";       IFS= read -rs P2; echo
    [ -n "$P1" ] && [ "$P1" = "$P2" ] && break
    warn "the passwords did not match or were empty — try again"
  done

  # --- verify the credentials and fetch the list of shares from the server ---
  local SHARE="" shares i line pick MODE="" PROBE=0
  if /usr/bin/nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1; then
    MODE=$(probe_mode "$SERVER" "$USERNAME" "$DOMAIN" "$P1"); PROBE=$?
    [ "$PROBE" -eq 0 ] || MODE=""
    if [ "$PROBE" -eq 2 ]; then
      warn "$SERVER answers on port 445 but never starts an SMB session"
      warn "the password was not checked at all — it is not what is failing here"
      warn "most often a VPN client intercepts the name; check what it resolves to:"
      warn "  dscacheutil -q host -a name $SERVER      (198.18.x.x is a stand-in)"
    elif [ -z "$MODE" ]; then
      warn "the server accepted the credentials neither as “$USERNAME”, nor as “${DOMAIN:-DOMAIN}\\$USERNAME”, nor as “$USERNAME@${DOMAIN:-domain}”"
      warn "usually this is a typo in the password or an extra/missing domain"
    else
      say "  login form: $MODE"
      shares=$(list_shares "$SERVER" "$USERNAME" "$DOMAIN" "$P1" "$MODE")
      if [ -n "$shares" ]; then
        say ""
        say "${c_b}Shares available on $SERVER:${c_0}"
        i=0
        while IFS= read -r line; do i=$((i+1)); printf '  %2d) %s\n' "$i" "$line"; done <<<"$shares"
        printf '  %2d) type the name by hand\n' "$((i+1))"
        ask pick "Pick a number" "1"
        if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$i" ] 2>/dev/null; then
          SHARE=$(printf '%s\n' "$shares" | sed -n "${pick}p")
        fi
      fi
    fi
  fi
  [ -n "$SHARE" ] || ask SHARE "Name of the network share — exactly as on Windows"

  # Mounted through the stock macOS mechanism — the volume shows up in /Volumes
  # under the share name, just like connecting via ⌘K. The system picks the
  # exact path.
  local SLUG MOUNTPOINT FALLBACK MP
  SLUG=$(slugify "$SERVER-$SHARE")
  MOUNTPOINT="/Volumes/$SHARE"
  FALLBACK="$HOME/mnt/$SHARE"

  local INTERVAL
  ask INTERVAL "Check interval, sec (waiting for the VPN to come up)" "60"
  case "$INTERVAL" in (*[!0-9]*|'') INTERVAL=60 ;; esac

  local KEYCHAIN_SERVICE="smb:$SERVER/$SHARE"
  /usr/bin/security add-generic-password -U \
    -a "$USERNAME" -s "$KEYCHAIN_SERVICE" \
    -l "smb-automount: $SERVER/$SHARE" \
    -T /usr/bin/security -w "$P1" >/dev/null \
    || die "could not write the password to the keychain"
  unset P1 P2
  ok "password saved in the keychain"

  # --- files ---
  mkdir -p "$CONF_DIR" "$AGENT_DIR" "$BIN_DIR"
  chmod 700 "$CONF_DIR"
  drop_duplicates "$SERVER" "$SHARE" "$SLUG"

  cat >"$CONF_DIR/$SLUG.conf" <<CONF_EOF
# smb-automount: $SERVER/$SHARE
# created $(date '+%F %T'). Safe to edit by hand; no password here.
SERVER="$SERVER"
SHARE="$SHARE"
USERNAME="$USERNAME"
DOMAIN="$DOMAIN"
MOUNTPOINT="$MOUNTPOINT"
FALLBACK="$FALLBACK"
KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE"
AUTHMODE="$MODE"
CONF_EOF

  write_worker
  ok "script: $WORKER"
  ok "config: $CONF_DIR/$SLUG.conf"

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
  ok "agent:  $PLIST"

  launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$SLUG" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null \
    || die "could not load the LaunchAgent"
  ok "agent started (no reboot needed)"

  # --- verification ---
  say ""
  if /usr/bin/nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1; then
    say "Server reachable, trying to mount…"
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      say "  unmounting the previous mount: $MP"
      /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
      sleep 1
    fi
    /bin/bash "$WORKER" "$CONF_DIR/$SLUG.conf"
    sleep 1
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      ok "done: $MP"
      yesno "Open the share in Finder?" y && open "$MP"
    else
      err "the mount failed. Log:"
      tail -5 "$HOME/Library/Logs/smb-automount.log" 2>/dev/null | sed 's/^/    /'
      say ""
      say "Most often the cause is a wrong share name, login or domain."
      say "Check the values in $CONF_DIR/$SLUG.conf and run the installer again."
    fi
  else
    warn "server $SERVER is unreachable right now — the VPN appears to be off."
    say "  That is fine: the agent is already running and will mount the share"
    say "  by itself within $INTERVAL sec. after the VPN comes up."
  fi

  say ""
  say "${c_b}Useful:${c_0}"
  say "  Log:              tail -f ~/Library/Logs/smb-automount.log"
  say "  What's installed: bash $0 --list"
  say "  Remove:           bash $0 --uninstall"
  say "  The volume appears in the Finder sidebar named “$SHARE”"
  say ""
}

case "${1:-}" in
  --uninstall|-u) cmd_uninstall ;;
  --list|-l)      say ""; cmd_list; say "" ;;
  --version|-V)   say "smb-automount $VERSION" ;;
  # The header names the script generically; the copy on disk carries a version
  # in its name, so show that instead — the lines stay copy-pasteable.
  --help|-h)      sed -n '2,14p' "$0" | sed -e 's/^# \{0,1\}//' \
                    -e "s/smb-automount-install\\.sh/$(basename "$0")/g" ;;
  "")             cmd_install ;;
  *)              die "unknown argument: $1 (see --help)" ;;
esac
