#!/bin/bash
# smb-automount worker. Started by the LaunchAgent. Argument: path to the .conf.
set -u

CONF="${1:-}"
[ -n "$CONF" ] && [ -f "$CONF" ] || { echo "no config: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

LOG="$HOME/Library/Logs/smb-automount.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
log() { echo "$(date '+%F %T') [$SHARE] $*"; }

# State is kept in a file next to the config and reported to the log only when
# it changes — otherwise the once-a-minute check would flood the log with
# repeats.
STATE_FILE="${CONF%.conf}.state"
set_state() { # state log-message
  local prev=""
  [ -f "$STATE_FILE" ] && prev=$(cat "$STATE_FILE" 2>/dev/null)
  printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null
  [ "$prev" = "$1" ] && return 0
  log "$2"
}

# Lock: if the previous run is still alive, don't start a second one.
LOCK="${CONF%.conf}.lock"
if [ -f "$LOCK" ]; then
  oldpid=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$LOCK" 2>/dev/null
trap 'rm -f "$LOCK" 2>/dev/null' EXIT

# Time limit: macOS has no timeout(1), so here is our own.
# Returns 124 if the command did not finish within the given seconds.
run_limited() { # seconds command...
  local secs="$1"; shift
  "$@" &
  local pid=$! i=0 rc
  while [ "$i" -lt "$secs" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; rc=$?
      return $rc
    fi
    sleep 1
    i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# log rotation (>1 MB)
if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "$LOG.old" 2>/dev/null
fi

# @@COMMON@@




# escaping for an AppleScript string literal
esc_as() {
  printf %s "$1" | /usr/bin/perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

reachable() { /usr/bin/nc -z -G 8 "$SERVER" 445 >/dev/null 2>&1; }

# Mount point of this share if it is already mounted (empty otherwise).
find_mount() {
  /sbin/mount -t smbfs 2>/dev/null | SRV="$SERVER" SH="$SHARE" SHE="$(urlenc "$SHARE")" \
    /usr/bin/perl -ne '
      my ($src, $mp) = /^(\S+) on (.+?) \(/ or next;
      my $s = lc $src;
      next unless index($s, lc $ENV{SRV}) >= 0;
      if (index($s, lc $ENV{SH}) >= 0 || index($s, lc $ENV{SHE}) >= 0) { print "$mp\n"; last; }
    '
}

# User name in the form NetFS understands
auth_user() { # mode
  case "$1" in
    domain) printf '%s\\%s' "$DOMAIN" "$USERNAME" ;;
    upn)    printf '%s@%s' "$USERNAME" "$DOMAIN" ;;
    *)      printf '%s' "$USERNAME" ;;
  esac
}

# Methods 1 and 3: direct mount into the given directory.
try_smbfs() { # mode mountpoint
  local auth rc
  auth=$(auth_str "$1" "$USERNAME" "${DOMAIN:-}" "$PASS")
  mkdir -p "$2" 2>/dev/null || return 2   # cannot create the directory (e.g. /Volumes)
  log "  trying mount_smbfs into $2 (login: $1)"
  run_limited 30 /sbin/mount_smbfs -N "//${auth}@${SERVER}/$(urlenc "$SHARE")" "$2"
  rc=$?
  [ "$rc" -eq 124 ] && log "  mount_smbfs did not answer within 30 s — aborted"
  if [ "$rc" -eq 0 ] && [ -n "$(find_mount)" ]; then return 0; fi
  rmdir "$2" 2>/dev/null
  log "  mount_smbfs into $2 (login: $1): $(code_hint "$rc")"
  # 68/69 mean the SMB session never started, so the credentials were never
  # looked at. Every other login form will fail the same way — say so instead
  # of grinding through them.
  case "$rc" in (68|69) return 3 ;; esac
  return 1
}

# The server answers on port 445 but not over SMB. Port-open is all reachable()
# can see, so this is the first place the difference shows.
no_smb() {
  set_state "nosmb" "ERROR: $SERVER answers on port 445 but never starts an SMB session — the login form makes no difference, so the remaining attempts are skipped. Most often a VPN client is intercepting the name: check that it resolves to the real address with 'dscacheutil -q host -a name $SERVER' (198.18.x.x is a stand-in, not the server)."
}

# Method 2: the stock macOS mechanism, the same one behind ⌘K in Finder.
try_netfs() { # mode
  local u p url rc
  u=$(esc_as "$(auth_user "$1")")
  p=$(esc_as "$PASS")
  url=$(esc_as "smb://$SERVER/$(urlenc "$SHARE")")
  log "  trying NetFS (login: $1)"
  run_limited 30 /usr/bin/osascript -e "mount volume \"$url\" as user name \"$u\" with password \"$p\"" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    log "  NetFS did not answer within 30 s (likely waiting on a hidden dialog) — aborted"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    sleep 1
    [ -n "$(find_mount)" ] && return 0
  fi
  log "  NetFS (login: $1) failed (code $rc)"
  return 1
}

MP=$(find_mount)
FAILS_FILE="${CONF%.conf}.fails"

# --- volume already mounted: check it is alive by reading it, not by probing
# the port. A single failed port probe (easy to miss over VPN) used to unmount
# a perfectly working volume, making it flicker once a minute.
if [ -n "$MP" ]; then
  if run_limited 10 /bin/ls "$MP" >/dev/null 2>&1; then
    rm -f "$FAILS_FILE" 2>/dev/null
    set_state "mounted:$MP" "already mounted -> $MP"
    exit 0
  fi
  fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)
  case "$fails" in (*[!0-9]*|'') fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$FAILS_FILE" 2>/dev/null
  if [ "$fails" -ge 3 ]; then
    log "volume $MP failed three checks in a row — unmounting and reconnecting"
    /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
    rm -f "$FAILS_FILE" 2>/dev/null
    MP=""          # don't wait for the next check — mount right now
  else
    log "volume $MP did not answer (check $fails of 3) — leaving it alone for now"
    exit 0
  fi
fi

# --- volume not mounted: is the server reachable at all ---
if ! reachable; then
  set_state "waiting" "server $SERVER unreachable (port 445 closed) — waiting for VPN"
  exit 0
fi

set_state "trying" "server reachable, trying to mount //$SERVER/$SHARE"

PASS=$(run_limited 15 /usr/bin/security find-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)
if [ -z "$PASS" ]; then
  log "ERROR: password not found in the keychain (service=$KEYCHAIN_SERVICE account=$USERNAME)"
  exit 1
fi
if kc_is_hex "$PASS"; then
  # -g prints the item to stderr and puts an 0x in front of a real hex dump.
  KCDUMP=$(run_limited 15 /usr/bin/security find-generic-password \
             -a "$USERNAME" -s "$KEYCHAIN_SERVICE" -g 2>&1 >/dev/null)
  case "$KCDUMP" in
    *"password: 0x"*)
      PASS=$(kc_unhex "$PASS")
      log "  keychain returned the password as a hex dump (it is not pure ASCII) — decoded"
      ;;
    *'password: "'*)
      : ;;   # a password that merely looks like hex — leave it as it is
    *)
      # -g answered neither way: killed by the timeout above, or stopped by an
      # access prompt. Going on with the text is the safe guess, but say so —
      # otherwise this ends as a bare "permission denied" with no explanation.
      log "  WARNING: the password looks like a hex dump, but 'security -g' gave no answer"
      log "           (access prompt or timeout) — using it as plain text"
      ;;
  esac
  unset KCDUMP
fi

MODES="${AUTHMODE:-$(auth_modes "${DOMAIN:-}")}"
VOLMP="/Volumes/$SHARE"

# /Volumes first: only a volume living there shows up in Finder's Locations
# under the share name. The directory is created during setup (as admin).
for m in $MODES; do
  try_smbfs "$m" "$VOLMP"
  case $? in
    0) MP=$(find_mount); set_state "mounted:$MP" "mounted -> $MP (login: $m, volume in /Volumes)"; exit 0 ;;
    2) set_state "novoldir" "directory $VOLMP is gone and cannot be recreated without an admin password — run Network Folder and go through setup again"; break ;;
    3) no_smb; exit 1 ;;
  esac
done

# NetFS — used when the directory in /Volumes is unavailable. On some machines
# the command hangs waiting on a hidden dialog, so it is not first and runs
# under a timeout.
for m in $MODES; do
  if try_netfs "$m"; then
    MP=$(find_mount)
    set_state "mounted:$MP" "mounted -> $MP (login: $m, NetFS)"
    exit 0
  fi
done

# Last resort — the home directory.
for m in $MODES; do
  try_smbfs "$m" "$FALLBACK"
  case $? in
    0) MP=$(find_mount); set_state "mounted:$MP" "mounted -> $MP (login: $m, fallback path)"; exit 0 ;;
    3) no_smb; exit 1 ;;
  esac
done

set_state "failed" "ERROR: could not mount //$SERVER/$SHARE"
exit 1
