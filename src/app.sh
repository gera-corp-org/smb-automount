#!/bin/bash
#
# smb-automount.app — графический установщик автомонтирования Windows-шары.
# Запускается двойным щелчком из Finder, терминал не нужен.
#
set -u

# --- журнал самого приложения: пишется всегда, даже если диалоги не показались.
# Смотреть: ~/Library/Logs/smb-automount-app.log
APPLOG="$HOME/Library/Logs/smb-automount-app.log"
mkdir -p "$(dirname "$APPLOG")" 2>/dev/null
alog() { echo "$(date '+%F %T') $*" >>"$APPLOG" 2>/dev/null; }
VERSION="2026-08-10.8"
alog "=== запуск (версия $VERSION): $0"
alog "    bash $BASH_VERSION, uid $(id -u), TERM=${TERM:-нет}"
trap 'alog "=== завершение, код $?"' EXIT
exec 2>>"$APPLOG"        # ошибки bash тоже попадают в журнал

TITLE="Сетевая папка"
BIN_DIR="$HOME/bin"
CONF_DIR="$HOME/.config/smb-automount"
AGENT_DIR="$HOME/Library/LaunchAgents"
WORKER="$BIN_DIR/smb-automount.sh"
LABEL_PREFIX="com.user.smb-automount"
LOG="$HOME/Library/Logs/smb-automount.log"

# ------------------------------------------------------------------- UI ------
# Экранирование для строкового литерала AppleScript: обратный слэш, кавычка
# и перевод строки (в AppleScript строка не может содержать реальный перенос).
esc() { printf %s "$1" | /usr/bin/perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'; }

ui_input() { # prompt default [hidden]
  local p d hidden extra
  p=$(esc "$1"); d=$(esc "${2:-}"); hidden="${3:-}"
  [ -n "$hidden" ] && extra="with hidden answer" || extra=""
  /usr/bin/osascript <<OSA 2>/dev/null
set r to display dialog "$p" default answer "$d" $extra with title "$TITLE" buttons {"Отмена", "Далее"} default button "Далее" with icon note
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
  t=$(esc "$1"); ok=$(esc "${2:-Да}"); no=$(esc "${3:-Нет}")
  /usr/bin/osascript <<OSA >/dev/null 2>&1
set r to display dialog "$t" with title "$TITLE" buttons {"$no", "$ok"} default button "$ok" with icon note
if button returned of r is not "$ok" then error number -128
OSA
}

ui_menu() { # text b1 b2 b3(default) -> печатает нажатую кнопку
  local t b1 b2 b3
  alog "ui_menu: вызываю osascript"
  t=$(esc "$1"); b1=$(esc "$2"); b2=$(esc "$3"); b3=$(esc "$4")
  /usr/bin/osascript <<OSA 2>/dev/null
set r to display dialog "$t" with title "$TITLE" buttons {"$b1", "$b2", "$b3"} default button "$b3" with icon note
return button returned of r
OSA
}

ui_pick() { # prompt; список строк на stdin -> печатает выбранное
  local p line as_items=""
  p=$(esc "$1")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "$as_items" ] && as_items="$as_items, "
    as_items="$as_items\"$(esc "$line")\""
  done
  [ -n "$as_items" ] || return 1
  /usr/bin/osascript <<OSA 2>/dev/null
set r to choose from list {$as_items} with title "$TITLE" with prompt "$p" OK button name "Выбрать" cancel button name "Отмена"
if r is false then error number -128
return item 1 of r
OSA
}

# @@COMMON@@



# Точка монтирования шары, если она подключена (иначе пусто). Имя тома
# в /Volumes выбирает система, поэтому ищем по серверу и имени папки.
mounted_path() { # server share
  /sbin/mount -t smbfs 2>/dev/null | SRV="$1" SH="$2" SHE="$(urlenc "$2")" \
    /usr/bin/perl -ne '
      my ($src, $mp) = /^(\S+) on (.+?) \(/ or next;
      my $s = lc $src;
      next unless index($s, lc $ENV{SRV}) >= 0;
      if (index($s, lc $ENV{SH}) >= 0 || index($s, lc $ENV{SHE}) >= 0) { print "$mp\n"; last; }
    '
}


# Кириллица не даёт ASCII-части, поэтому к идентификатору всегда добавляется
# хеш — иначе разные папки получили бы одинаковое имя конфига.
slugify() {
  local ascii hash
  ascii=$(printf %s "$1" | tr '[:upper:]' '[:lower:]' \
          | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-40)
  ascii=$(printf %s "$ascii" | sed -E 's/-$//')
  hash=$(printf %s "$1" | { md5 -q 2>/dev/null || md5sum | cut -d' ' -f1; } | cut -c1-6)
  printf '%s\n' "${ascii:-share}-$hash"
}

reachable() { /usr/bin/nc -z -G 3 "$1" 445 >/dev/null 2>&1; }

# Какой вариант учётных данных принимает сервер. Печатает mode или ничего.
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

# Убирает старые конфиги/агенты для той же папки, оставшиеся от прежних версий
# (идентификатор конфига изменился, иначе рядом жил бы второй агент).
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

conf_by_label() { # "//server/share" -> путь к .conf
  local want="$1" f
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    ( . "$f"; [ "//$SERVER/$SHARE" = "$want" ] ) && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# ----------------------------------------------------------------- статус ----
do_status() {
  local out="" f line
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    line=$( . "$f"
      mp=$(mounted_path "$SERVER" "$SHARE")
      if [ -n "$mp" ]; then
        s="подключена"
        raw=$(/sbin/mount -t smbfs 2>/dev/null | grep -F " on $mp " | head -1)
        # без case: bash 3.2 не разбирает case внутри $( ... )
        if [ "${raw#*nobrowse}" != "$raw" ]; then
          s="подключена, но скрыта от Finder (nobrowse)"
        fi
      else
        s="не подключена"; mp="$MOUNTPOINT"
      fi
      printf '•  //%s/%s\n    %s\n    %s' "$SERVER" "$SHARE" "$mp" "$s" )
    out="$out$line"$'\n\n'
  done
  [ -n "$out" ] || out="Пока ничего не настроено."$'\n\n'
  if [ -f "$LOG" ]; then
    out="$out"'Последние записи журнала:'$'\n'"$(tail -6 "$LOG")"
  fi
  ui_msg "$out"
}

# ---------------------------------------------------------------- удаление ---
do_uninstall() {
  local pick conf slug
  pick=$(conf_list | ui_pick "Какое подключение удалить?") || return 0
  conf=$(conf_by_label "$pick") || { ui_msg "Не нашёл конфиг для $pick" caution; return 0; }
  slug=$(basename "$conf" .conf)
  ui_confirm "Удалить автоподключение $pick?" "Удалить" "Отмена" || return 0

  launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$slug" 2>/dev/null
  rm -f "$AGENT_DIR/$LABEL_PREFIX.$slug.plist"
  ( . "$conf"
    mp=$(mounted_path "$SERVER" "$SHARE")
    [ -n "$mp" ] && { /sbin/umount -f "$mp" 2>/dev/null || /usr/sbin/diskutil unmount force "$mp" 2>/dev/null; }
    rmdir "${FALLBACK:-}" 2>/dev/null
    if ui_confirm "Удалить также сохранённый пароль из связки ключей?" "Удалить" "Оставить"; then
      /usr/bin/security delete-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
    fi )
  rm -f "$conf"
  ui_msg "Готово: $pick отключено."
}

# ---------------------------------------------------------------- установка --
do_install() {
  local SERVER SHARE USERNAME DOMAIN MOUNTPOINT INTERVAL SLUG KEYCHAIN_SERVICE
  local PASS PASS2 shares picked MODE="" FALLBACK MP

  SERVER=$(ui_input "Адрес сервера — имя или IP.

Например: fileserver.corp.local" "") || return 0
  [ -n "$SERVER" ] || { ui_msg "Адрес сервера не указан." caution; return 0; }

  USERNAME=$(ui_input "Ваш логин на сервере:" "$(id -un)") || return 0
  [ -n "$USERNAME" ] || { ui_msg "Логин не указан." caution; return 0; }

  DOMAIN=$(ui_input "Домен Active Directory.

Если домена нет — оставьте поле пустым." "") || return 0

  while :; do
    PASS=$(ui_input "Пароль для $USERNAME@$SERVER:" "" hidden) || return 0
    [ -n "$PASS" ] && break
    ui_msg "Пароль не может быть пустым." caution
  done

  # --- проверяем учётные данные и получаем список папок ---
  SHARE=""
  local DOMSLASH DOMAT
  if [ -n "$DOMAIN" ]; then DOMSLASH="$DOMAIN\\"; DOMAT="$DOMAIN"; else DOMSLASH=""; DOMAT="домен"; fi
  if reachable "$SERVER"; then
    MODE=$(probe_mode "$SERVER" "$USERNAME" "$DOMAIN" "$PASS") || MODE=""
    if [ -z "$MODE" ]; then
      ui_confirm "Сервер $SERVER не принимает эти учётные данные ни в одной из форм:

  $USERNAME
  $DOMSLASH$USERNAME
  $USERNAME@$DOMAT

Обычно это опечатка в пароле, лишний или, наоборот, отсутствующий домен. Продолжить всё равно?" "Продолжить" "Отмена" || return 0
    else
      shares=$(list_shares "$SERVER" "$USERNAME" "$DOMAIN" "$PASS" "$MODE")
      if [ -n "$shares" ]; then
        picked=$(printf '%s\n' "$shares" | ui_pick "Папки, доступные на $SERVER:") || return 0
        SHARE="$picked"
      else
        ui_msg "Учётные данные приняты, но список папок сервер не отдал. Имя папки можно ввести вручную на следующем шаге." caution
      fi
    fi
  fi

  if [ -z "$SHARE" ]; then
    SHARE=$(ui_input "Имя сетевой папки на сервере — точно как на Windows, регистр важен.

Например: Documents или Общая папка" "") || return 0
    [ -n "$SHARE" ] || { ui_msg "Имя папки не указано." caution; return 0; }
  fi

  # Монтируем штатным механизмом macOS — том появляется в /Volumes под именем
  # папки, как при подключении через ⌘K. Точный путь выбирает система.
  MOUNTPOINT="/Volumes/$SHARE"
  FALLBACK="$HOME/mnt/$SHARE"

  INTERVAL=$(ui_input "Как часто проверять, поднялся ли VPN (секунды):" "60") || return 0
  case "$INTERVAL" in (*[!0-9]*|'') INTERVAL=60 ;; esac

  SLUG=$(slugify "$SERVER-$SHARE")
  KEYCHAIN_SERVICE="smb:$SERVER/$SHARE"

  /usr/bin/security add-generic-password -U \
    -a "$USERNAME" -s "$KEYCHAIN_SERVICE" \
    -l "smb-automount: $SERVER/$SHARE" \
    -T /usr/bin/security -w "$PASS" >/dev/null 2>&1 \
    || { ui_msg "Не удалось сохранить пароль в связку ключей." stop; return 1; }
  unset PASS PASS2

  local SHOWUSER
  if [ -n "$DOMAIN" ]; then SHOWUSER="$DOMAIN\\$USERNAME"; else SHOWUSER="$USERNAME"; fi

  ui_confirm "Проверьте данные:

Сервер:  $SERVER
Папка:   $SHARE
Логин:   $SHOWUSER
Подключать как том:  $SHARE (в /Volumes, как через ⌘K)
Проверка каждые $INTERVAL сек.

Настроить автоподключение?" "Настроить" "Отмена" || return 0

  mkdir -p "$CONF_DIR" "$AGENT_DIR" "$BIN_DIR"
  chmod 700 "$CONF_DIR"
  drop_duplicates "$SERVER" "$SHARE" "$SLUG"

  cat >"$CONF_DIR/$SLUG.conf" <<CONF_EOF
# smb-automount: $SERVER/$SHARE
# создан $(date '+%F %T'). Пароля здесь нет — он в связке ключей.
SERVER="$SERVER"
SHARE="$SHARE"
USERNAME="$USERNAME"
DOMAIN="$DOMAIN"
MOUNTPOINT="$MOUNTPOINT"
FALLBACK="$FALLBACK"
KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE"
AUTHMODE="$MODE"
CONF_EOF

  # /Volumes закрыт для записи обычному пользователю. Каталог для тома создаём
  # один раз с правами администратора — иначе Finder покажет не том, а просто
  # соединение с сервером.
  if [ ! -d "$MOUNTPOINT" ] && ! mkdir -p "$MOUNTPOINT" 2>/dev/null; then
    if ui_confirm "Чтобы папка была видна в Finder как отдельный том с именем «$SHARE», нужно один раз создать каталог:

$MOUNTPOINT

macOS спросит пароль администратора. Если отказаться, папка будет подключаться в домашнюю папку, а в боковой панели будет значиться имя сервера." "Создать" "Пропустить"; then
      local mkcmd
      mkcmd="mkdir -p '$MOUNTPOINT' && chown $(id -u):$(id -g) '$MOUNTPOINT'"
      /usr/bin/osascript -e "do shell script \"$(esc "$mkcmd")\" with administrator privileges" >/dev/null 2>&1
      if [ -d "$MOUNTPOINT" ]; then
        alog "каталог $MOUNTPOINT создан"
      else
        ui_msg "Каталог создать не удалось. Папка будет подключаться в домашнюю папку." caution
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
    || { ui_msg "Не удалось запустить фоновый агент." stop; return 1; }

  if reachable "$SERVER"; then
    # Старое монтирование этой же шары (например, в ~/mnt от прежней версии)
    # заставило бы агента решить, что всё уже подключено. Отцепляем.
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
      sleep 1
    fi
    # Фоновый агент мог уже начать работу и держать замок — дожидаемся его,
    # иначе наш запуск молча ничего не сделает.
    local lockf waited tries
    lockf="$CONF_DIR/$SLUG.lock"
    waited=0
    while [ -f "$lockf" ] && [ "$waited" -lt 60 ]; do
      sleep 2
      waited=$((waited + 2))
    done
    alog "запускаю монтирование (ждал замок $waited с)"
    /bin/bash "$WORKER" "$CONF_DIR/$SLUG.conf"
    # Монтирование через VPN занимает время; ждём появления тома до минуты.
    MP=$(mounted_path "$SERVER" "$SHARE")
    tries=0
    while [ -z "$MP" ] && [ "$tries" -lt 30 ]; do
      sleep 2
      tries=$((tries + 1))
      MP=$(mounted_path "$SERVER" "$SHARE")
    done
    alog "итог монтирования: ${MP:-не смонтировано}"
    if [ -n "$MP" ]; then
      if ui_confirm "Готово — папка подключена:
$MP

Дальше она будет подключаться сама после каждого входа в систему и после подключения к VPN.

Открыть её в Finder?" "Открыть" "Позже"; then
        open "$MP"
      fi
    else
      ui_msg "Настройка сохранена, но подключиться не удалось.

Журнал ($LOG):

$(tail -4 "$LOG" 2>/dev/null)" caution
    fi
  else
    ui_msg "Настройка сохранена.

Сервер $SERVER сейчас недоступен — похоже, VPN не подключён. Это нормально: папка подключится сама в течение $INTERVAL сек. после подключения к VPN, и дальше при каждом входе в систему." note
  fi
}

# -------------------------------------------------------------------- main ---
main() {
  alog "main: конфигов найдено: $(conf_list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "только macOS" >&2; exit 1
  fi
  if [ -n "$(conf_list 2>/dev/null)" ]; then
    alog "main: показываю меню"
    local choice
    choice=$(ui_menu "Автоподключение сетевой папки.

Что сделать?" "Удалить" "Показать статус" "Добавить папку")
    case "$choice" in
      "Добавить папку")  do_install ;;
      "Показать статус") do_status ;;
      "Удалить")         do_uninstall ;;
      *) exit 0 ;;
    esac
  else
    alog "main: конфигов нет, сразу установка"
    do_install
  fi
}

main
