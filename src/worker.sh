#!/bin/bash
# smb-automount worker. Запускается LaunchAgent'ом. Аргумент — путь к .conf.
set -u

CONF="${1:-}"
[ -n "$CONF" ] && [ -f "$CONF" ] || { echo "нет конфига: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

LOG="$HOME/Library/Logs/smb-automount.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
log() { echo "$(date '+%F %T') [$SHARE] $*"; }

# Состояние пишем в файл рядом с конфигом и сообщаем в журнал только при
# изменении — иначе проверка раз в минуту засыпала бы журнал повторами.
STATE_FILE="${CONF%.conf}.state"
set_state() { # состояние текст-для-журнала
  local prev=""
  [ -f "$STATE_FILE" ] && prev=$(cat "$STATE_FILE" 2>/dev/null)
  printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null
  [ "$prev" = "$1" ] && return 0
  log "$2"
}

# Замок: если предыдущий запуск ещё жив, второй не начинаем.
LOCK="${CONF%.conf}.lock"
if [ -f "$LOCK" ]; then
  oldpid=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$LOCK" 2>/dev/null
trap 'rm -f "$LOCK" 2>/dev/null' EXIT

# Ограничение времени: в macOS нет timeout(1), поэтому свой.
# Возвращает 124, если команда не уложилась в отведённые секунды.
run_limited() { # секунды команда...
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

# ротация лога (>1 МБ)
if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG" "$LOG.old" 2>/dev/null
fi

# @@COMMON@@




# экранирование для строкового литерала AppleScript
esc_as() {
  printf %s "$1" | /usr/bin/perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

reachable() { /usr/bin/nc -z -G 8 "$SERVER" 445 >/dev/null 2>&1; }

# Точка монтирования этой шары, если она уже подключена (иначе пусто).
find_mount() {
  /sbin/mount -t smbfs 2>/dev/null | SRV="$SERVER" SH="$SHARE" SHE="$(urlenc "$SHARE")" \
    /usr/bin/perl -ne '
      my ($src, $mp) = /^(\S+) on (.+?) \(/ or next;
      my $s = lc $src;
      next unless index($s, lc $ENV{SRV}) >= 0;
      if (index($s, lc $ENV{SH}) >= 0 || index($s, lc $ENV{SHE}) >= 0) { print "$mp\n"; last; }
    '
}

# Имя пользователя в той форме, которую понимает NetFS
auth_user() { # mode
  case "$1" in
    domain) printf '%s\\%s' "$DOMAIN" "$USERNAME" ;;
    upn)    printf '%s@%s' "$USERNAME" "$DOMAIN" ;;
    *)      printf '%s' "$USERNAME" ;;
  esac
}

# Способ 1 и 3: прямое монтирование в указанный каталог.
try_smbfs() { # mode mountpoint
  local auth rc
  auth=$(auth_str "$1" "$USERNAME" "${DOMAIN:-}" "$PASS")
  mkdir -p "$2" 2>/dev/null || return 2   # каталог создать нельзя (например, /Volumes)
  log "  пробую mount_smbfs в $2 (вход: $1)"
  run_limited 30 /sbin/mount_smbfs -N "//${auth}@${SERVER}/$(urlenc "$SHARE")" "$2"
  rc=$?
  [ "$rc" -eq 124 ] && log "  mount_smbfs не ответил за 30 с — прерван"
  if [ "$rc" -eq 0 ] && [ -n "$(find_mount)" ]; then return 0; fi
  rmdir "$2" 2>/dev/null
  log "  mount_smbfs в $2 (вход: $1): $(code_hint "$rc")"
  return 1
}

# Способ 2: штатный механизм macOS, тот же, что за ⌘K в Finder.
try_netfs() { # mode
  local u p url rc
  u=$(esc_as "$(auth_user "$1")")
  p=$(esc_as "$PASS")
  url=$(esc_as "smb://$SERVER/$(urlenc "$SHARE")")
  log "  пробую NetFS (вход: $1)"
  run_limited 30 /usr/bin/osascript -e "mount volume \"$url\" as user name \"$u\" with password \"$p\"" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 124 ]; then
    log "  NetFS не ответил за 30 с (похоже, ждал скрытого диалога) — прерван"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    sleep 1
    [ -n "$(find_mount)" ] && return 0
  fi
  log "  NetFS (вход: $1) не сработал (код $rc)"
  return 1
}

MP=$(find_mount)
FAILS_FILE="${CONF%.conf}.fails"

# --- том уже смонтирован: проверяем его живость чтением, а не пробой порта ---
# Раньше единственная неудачная проба порта (через VPN она легко не успевает)
# приводила к отцеплению рабочего тома, и он мигал раз в минуту.
if [ -n "$MP" ]; then
  if run_limited 10 /bin/ls "$MP" >/dev/null 2>&1; then
    rm -f "$FAILS_FILE" 2>/dev/null
    set_state "mounted:$MP" "уже смонтировано -> $MP"
    exit 0
  fi
  fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)
  case "$fails" in (*[!0-9]*|'') fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$FAILS_FILE" 2>/dev/null
  if [ "$fails" -ge 3 ]; then
    log "том $MP не отвечает три проверки подряд — отцепляю и подключаю заново"
    /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
    rm -f "$FAILS_FILE" 2>/dev/null
    MP=""          # не ждём следующей проверки — монтируем прямо сейчас
  else
    log "том $MP не ответил (проверка $fails из 3) — пока оставляю как есть"
    exit 0
  fi
fi

# --- том не смонтирован: есть ли вообще связь с сервером ---
if ! reachable; then
  set_state "waiting" "сервер $SERVER недоступен (порт 445 закрыт) — жду подключения VPN"
  exit 0
fi

set_state "trying" "сервер доступен, пробую смонтировать //$SERVER/$SHARE"

PASS=$(run_limited 15 /usr/bin/security find-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)
if [ -z "$PASS" ]; then
  log "ОШИБКА: пароль не найден в связке ключей (service=$KEYCHAIN_SERVICE account=$USERNAME)"
  exit 1
fi

MODES="${AUTHMODE:-$(auth_modes "${DOMAIN:-}")}"
VOLMP="/Volumes/$SHARE"

# Сначала /Volumes: только том, лежащий там, Finder показывает в «Размещениях»
# под именем папки. Каталог создаётся при настройке (с правами администратора).
for m in $MODES; do
  try_smbfs "$m" "$VOLMP"
  case $? in
    0) MP=$(find_mount); set_state "mounted:$MP" "смонтировано -> $MP (вход: $m, том в /Volumes)"; exit 0 ;;
    2) set_state "novoldir" "каталог $VOLMP исчез, а создать его без пароля администратора нельзя — запустите «Сетевая папка» и пройдите настройку заново"; break ;;
  esac
done

# NetFS — если каталог в /Volumes недоступен. На некоторых машинах команда
# зависает в ожидании скрытого диалога, поэтому она не первая и под таймаутом.
for m in $MODES; do
  if try_netfs "$m"; then
    MP=$(find_mount)
    set_state "mounted:$MP" "смонтировано -> $MP (вход: $m, NetFS)"
    exit 0
  fi
done

# Последний рубеж — домашняя папка.
for m in $MODES; do
  if try_smbfs "$m" "$FALLBACK"; then
    MP=$(find_mount)
    set_state "mounted:$MP" "смонтировано -> $MP (вход: $m, запасной путь)"
    exit 0
  fi
done

set_state "failed" "ОШИБКА: не удалось смонтировать //$SERVER/$SHARE"
exit 1