#!/bin/bash
#
# Worker tests on stubs. No real server needed: mount_smbfs, osascript, mount,
# nc and security are replaced by stubs, and the behaviour is checked — what
# goes into the log and what ends up mounted.
#
#   bash tests/run-tests.sh
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
STUB="$WORK/stub"
HOME_DIR="$WORK/home"
VOL="$WORK/volumes"
passed=0
failed=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$STUB" "$HOME_DIR/.config/smb-automount" "$VOL"

# --- assemble the worker from sources and point it at the stubs ---
python3 - "$ROOT" "$WORK/worker.sh" <<'PY'
import sys, pathlib
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
tpl = (root / 'src/worker.sh').read_text()
common = (root / 'src/lib/common.sh').read_text().rstrip('\n')
out.write_text(tpl.replace('# @@COMMON@@', common))
PY

sed -i.bak \
  -e 's#/usr/bin/nc#nc#g' \
  -e 's#/usr/bin/security#security#g' \
  -e 's#/sbin/mount -t smbfs#mount_stub -t smbfs#g' \
  -e 's#/usr/bin/osascript#osascript#g' \
  -e 's#/sbin/mount_smbfs#mount_smbfs#g' \
  -e 's#/sbin/umount#umount#g' \
  -e 's#run_limited 10 /bin/ls#run_limited 3 ls#' \
  -e 's#run_limited 30 #run_limited 3 #g' \
  -e "s#\"/Volumes/\$SHARE\"#\"\$TESTVOL/\$SHARE\"#" \
  "$WORK/worker.sh"

bash -n "$WORK/worker.sh" || { echo "the worker does not pass bash -n"; exit 1; }

# The share name is deliberately non-ASCII and contains a space: that is what
# percent-encoding and the mount lookup have to survive.
cat > "$HOME_DIR/.config/smb-automount/x.conf" <<EOF
SERVER="vault.example.local"
SHARE="Équipe partagée"
USERNAME="admin"
DOMAIN=""
MOUNTPOINT="/Volumes/Équipe partagée"
FALLBACK="$HOME_DIR/mnt/Équipe partagée"
KEYCHAIN_SERVICE="smb:vault.example.local/Équipe partagée"
AUTHMODE="plain"
EOF
CONF="$HOME_DIR/.config/smb-automount/x.conf"

stub() { cat > "$STUB/$1"; chmod +x "$STUB/$1"; }

reset_state() {
  rm -rf "$HOME_DIR/Library" "$WORK/mounted" "$WORK/dead"
  rm -f "$HOME_DIR/.config/smb-automount/x.state" "$HOME_DIR/.config/smb-automount/x.fails"
  rm -f "$WORK/url"
  rm -rf "$VOL"/* "$HOME_DIR/mnt"
}

run_worker() {
  TESTVOL="$VOL" WORKDIR="$WORK" PATH="$STUB:$PATH" HOME="$HOME_DIR" \
    bash "$WORK/worker.sh" "$CONF" >/dev/null 2>&1
}

log_text() { cat "$HOME_DIR/Library/Logs/smb-automount.log" 2>/dev/null; }

check() { # description pattern-in-log
  if log_text | grep -q "$2"; then
    echo "  ok   $1"
    passed=$((passed + 1))
  else
    echo "  FAIL $1 — the log has no “$2”"
    echo "       log:"; log_text | sed 's/^/         /'
    failed=$((failed + 1))
  fi
}

# ------------------------------------------------------------------- stubs ---
stub nc <<'S'
#!/bin/bash
[ -f "$WORKDIR/offline" ] && exit 1
exit 0
S
stub security <<'S'
#!/bin/bash
case "$1" in find-generic-password) echo 's3cret' ;; esac
exit 0
S
stub mount_stub <<'S'
#!/bin/bash
[ -f "$WORKDIR/mounted" ] && echo "//admin@vault.example.local/%C3%89quipe%20partag%C3%A9e on $(cat "$WORKDIR/mounted") (smbfs)"
exit 0
S
stub umount <<'S'
#!/bin/bash
rm -f "$WORKDIR/mounted"; exit 0
S
stub ls <<'S'
#!/bin/bash
[ -f "$WORKDIR/dead" ] && sleep 60
exit 0
S
stub mount_smbfs <<'S'
#!/bin/bash
rm -f "$WORKDIR/dead"
printf '%s\n' "$3" > "$WORKDIR/mounted"
exit 0
S
stub osascript <<'S'
#!/bin/bash
[ -f "$WORKDIR/netfs_hangs" ] && sleep 60
exit 1
S

# ------------------------------------------------------------------- tests ---
echo "1. VPN down — wait, with no repeats in the log"
reset_state; touch "$WORK/offline"
run_worker; run_worker; run_worker
check "the waiting message is there" "waiting for VPN"
n=$(log_text | grep -c "waiting for VPN")
if [ "$n" -eq 1 ]; then echo "  ok   no repeats"; passed=$((passed+1))
else echo "  FAIL $n repeats instead of 1"; failed=$((failed+1)); fi
rm -f "$WORK/offline"

echo "2. The directory in /Volumes is available — mount there"
reset_state
run_worker
check "mounted into /Volumes" "volume in /Volumes"

echo "3. Live volume and a network hiccup — the volume stays mounted"
reset_state; run_worker
touch "$WORK/offline"; run_worker; rm -f "$WORK/offline"
if [ -f "$WORK/mounted" ]; then echo "  ok   the volume is still there"; passed=$((passed+1))
else echo "  FAIL the volume was unmounted because of a port probe"; failed=$((failed+1)); fi

echo "4. Dead volume — unmount on the third check and remount right away"
reset_state; run_worker
touch "$WORK/dead"
run_worker; run_worker; run_worker
check "unmount and reconnect" "unmounting and reconnecting"
if [ -f "$WORK/mounted" ]; then echo "  ok   the volume came back"; passed=$((passed+1))
else echo "  FAIL the volume did not come back"; failed=$((failed+1)); fi

echo "5. The directory in /Volumes is unavailable and NetFS hangs — fall back to the home folder"
reset_state; chmod 500 "$VOL"; touch "$WORK/netfs_hangs"
run_worker
chmod 700 "$VOL"; rm -f "$WORK/netfs_hangs"
check "NetFS aborted by timeout" "NetFS"
check "the fallback path worked" "fallback path"

echo "6. The server rejects the login — an honest error"
reset_state
stub mount_smbfs <<'S'
#!/bin/bash
echo "mount_smbfs: server rejected the connection: Authentication error" >&2
exit 77
S
run_worker
check "the reason is decoded" "permission denied"
check "the final error" "could not mount"

echo "7. A non-ASCII password comes back from the keychain as a hex dump"
reset_state
# The real `security -w` prints a password holding non-ASCII bytes as hex, and
# marks it as such only in the -g output. d09f… is UTF-8 for “Пароль”.
stub security <<'S'
#!/bin/bash
case "$1" in
  find-generic-password)
    case " $* " in
      *" -g "*) echo 'password: 0xD09FD0B0D180D0BED0BBD18C  "..."' >&2 ;;
      *)        echo 'd09fd0b0d180d0bed0bbd18c' ;;
    esac ;;
esac
exit 0
S
stub mount_smbfs <<'S'
#!/bin/bash
rm -f "$WORKDIR/dead"
printf '%s\n' "$2" > "$WORKDIR/url"
printf '%s\n' "$3" > "$WORKDIR/mounted"
exit 0
S
run_worker
if grep -q '%D0%9F%D0%B0%D1%80%D0%BE%D0%BB%D1%8C' "$WORK/url" 2>/dev/null; then
  echo "  ok   mount_smbfs got the decoded password"; passed=$((passed+1))
else
  echo "  FAIL mount_smbfs got: $(cat "$WORK/url" 2>/dev/null)"; failed=$((failed+1))
fi

echo "8. A plain ASCII password that merely looks like hex is left alone"
reset_state
stub security <<'S'
#!/bin/bash
case "$1" in
  find-generic-password)
    case " $* " in
      *" -g "*) echo 'password: "deadbeef"' >&2 ;;
      *)        echo 'deadbeef' ;;
    esac ;;
esac
exit 0
S
stub mount_smbfs <<'S'
#!/bin/bash
rm -f "$WORKDIR/dead"
printf '%s\n' "$2" > "$WORKDIR/url"
printf '%s\n' "$3" > "$WORKDIR/mounted"
exit 0
S
run_worker
if grep -q ':deadbeef@' "$WORK/url" 2>/dev/null; then
  echo "  ok   the password went through untouched"; passed=$((passed+1))
else
  echo "  FAIL mount_smbfs got: $(cat "$WORK/url" 2>/dev/null)"; failed=$((failed+1))
fi

echo "9. The port is open but no SMB session starts — an honest diagnosis, no grinding"
reset_state
rm -f "$WORK/calls"
stub security <<'S'
#!/bin/bash
case "$1" in find-generic-password) echo 's3cret' ;; esac
exit 0
S
# 68 = server not found: it never got as far as checking the credentials.
stub mount_smbfs <<'S'
#!/bin/bash
echo x >> "$WORKDIR/calls"
echo "mount_smbfs: server connection failed: Operation timed out" >&2
exit 68
S
run_worker
check "it says the SMB session never starts" "never starts an SMB session"
check "it names where to look" "dscacheutil"
if log_text | grep -q "trying NetFS"; then
  echo "  FAIL NetFS was tried anyway"; failed=$((failed+1))
else
  echo "  ok   NetFS was not tried"; passed=$((passed+1))
fi
n=$(wc -l < "$WORK/calls" 2>/dev/null | tr -d ' ')
if [ "${n:-0}" = 1 ]; then echo "  ok   mount_smbfs was called once"; passed=$((passed+1))
else echo "  FAIL mount_smbfs was called $n times instead of 1"; failed=$((failed+1)); fi
if log_text | grep -q "could not mount"; then
  echo "  FAIL the credentials are still blamed in the final message"; failed=$((failed+1))
else
  echo "  ok   the credentials are not blamed"; passed=$((passed+1))
fi

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
