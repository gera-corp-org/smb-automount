#!/bin/bash
#
# Тесты рабочего скрипта на заглушках. Настоящий сервер не нужен: подменяются
# mount_smbfs, osascript, mount, nc и security, а проверяется поведение —
# что уходит в журнал и что оказывается смонтировано.
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

# --- собираем рабочий скрипт из исходников и переводим на заглушки ---
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

bash -n "$WORK/worker.sh" || { echo "рабочий скрипт не проходит bash -n"; exit 1; }

cat > "$HOME_DIR/.config/smb-automount/x.conf" <<EOF
SERVER="vault.example.local"
SHARE="Общая папка"
USERNAME="admin"
DOMAIN=""
MOUNTPOINT="/Volumes/Общая папка"
FALLBACK="$HOME_DIR/mnt/Общая папка"
KEYCHAIN_SERVICE="smb:vault.example.local/Общая папка"
AUTHMODE="plain"
EOF
CONF="$HOME_DIR/.config/smb-automount/x.conf"

stub() { cat > "$STUB/$1"; chmod +x "$STUB/$1"; }

reset_state() {
  rm -rf "$HOME_DIR/Library" "$WORK/mounted" "$WORK/dead"
  rm -f "$HOME_DIR/.config/smb-automount/x.state" "$HOME_DIR/.config/smb-automount/x.fails"
  rm -rf "$VOL"/* "$HOME_DIR/mnt"
}

run_worker() {
  TESTVOL="$VOL" WORKDIR="$WORK" PATH="$STUB:$PATH" HOME="$HOME_DIR" \
    bash "$WORK/worker.sh" "$CONF" >/dev/null 2>&1
}

log_text() { cat "$HOME_DIR/Library/Logs/smb-automount.log" 2>/dev/null; }

check() { # описание образец-в-журнале
  if log_text | grep -q "$2"; then
    echo "  ok   $1"
    passed=$((passed + 1))
  else
    echo "  СБОЙ $1 — в журнале нет «$2»"
    echo "       журнал:"; log_text | sed 's/^/         /'
    failed=$((failed + 1))
  fi
}

# ---------------------------------------------------------------- заглушки ---
stub nc <<'S'
#!/bin/bash
[ -f "$WORKDIR/offline" ] && exit 1
exit 0
S
stub security <<'S'
#!/bin/bash
case "$1" in find-generic-password) echo 'сЕкрет' ;; esac
exit 0
S
stub mount_stub <<'S'
#!/bin/bash
[ -f "$WORKDIR/mounted" ] && echo "//admin@vault.example.local/%D0%9E%D0%B1%D1%89%D0%B0%D1%8F%20%D0%BF%D0%B0%D0%BF%D0%BA%D0%B0 on $(cat "$WORKDIR/mounted") (smbfs)"
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

# ------------------------------------------------------------------- тесты ---
echo "1. VPN выключен — ждём, без повторов в журнале"
reset_state; touch "$WORK/offline"
run_worker; run_worker; run_worker
check "сообщение об ожидании есть" "жду подключения VPN"
n=$(log_text | grep -c "жду подключения VPN")
if [ "$n" -eq 1 ]; then echo "  ok   повторов нет"; passed=$((passed+1))
else echo "  СБОЙ повторов $n вместо 1"; failed=$((failed+1)); fi
rm -f "$WORK/offline"

echo "2. Каталог в /Volumes доступен — монтируем туда"
reset_state
run_worker
check "смонтировано в /Volumes" "том в /Volumes"

echo "3. Живой том и заминка сети — том не отцепляется"
reset_state; run_worker
touch "$WORK/offline"; run_worker; rm -f "$WORK/offline"
if [ -f "$WORK/mounted" ]; then echo "  ok   том на месте"; passed=$((passed+1))
else echo "  СБОЙ том отцепился из-за пробы порта"; failed=$((failed+1)); fi

echo "4. Том умер — отцепляем на третьей проверке и сразу монтируем заново"
reset_state; run_worker
touch "$WORK/dead"
run_worker; run_worker; run_worker
check "отцепление и повторное подключение" "отцепляю и подключаю заново"
if [ -f "$WORK/mounted" ]; then echo "  ok   том поднят обратно"; passed=$((passed+1))
else echo "  СБОЙ том не вернулся"; failed=$((failed+1)); fi

echo "5. Каталог в /Volumes недоступен, NetFS зависает — уходим в домашнюю папку"
reset_state; chmod 500 "$VOL"; touch "$WORK/netfs_hangs"
run_worker
chmod 700 "$VOL"; rm -f "$WORK/netfs_hangs"
check "NetFS прерван по таймауту" "NetFS"
check "сработал запасной путь" "запасной путь"

echo "6. Сервер отвергает вход — честная ошибка"
reset_state
stub mount_smbfs <<'S'
#!/bin/bash
echo "mount_smbfs: server rejected the connection: Authentication error" >&2
exit 77
S
run_worker
check "причина отказа расшифрована" "отказано в доступе"
check "итоговая ошибка" "не удалось смонтировать"

echo
echo "успешно: $passed, сбоев: $failed"
[ "$failed" -eq 0 ]
