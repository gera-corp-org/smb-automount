#!/bin/bash
#
# smb-automount — установщик автомонтирования Windows SMB-шары на macOS.
#
# Один файл: скопируйте на любую машину, запустите, ответьте на вопросы.
#   bash smb-automount-install.sh              — установка / переустановка
#   bash smb-automount-install.sh --uninstall  — удаление
#   bash smb-automount-install.sh --list       — что уже установлено
#
# Рассчитан на работу через корпоративный VPN: пока VPN не поднят,
# монтирование не пытается выполняться; как только сервер стал доступен —
# папка подключается сама.
#

set -u

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

ask() { # ask <переменная> <вопрос> [значение_по_умолчанию] [allow_empty]
  local __var="$1" __q="$2" __def="${3:-}" __allow="${4:-}" __in=""
  while :; do
    if [ -n "$__def" ]; then
      printf '%s%s%s [%s]: ' "$c_b" "$__q" "$c_0" "$__def"
    else
      printf '%s%s%s: ' "$c_b" "$__q" "$c_0"
    fi
    IFS= read -r __in || die "ввод прерван"
    [ -z "$__in" ] && __in="$__def"
    if [ -z "$__in" ] && [ "$__allow" != "allow_empty" ]; then
      warn "нужно что-то ввести"
      continue
    fi
    break
  done
  eval "$__var=\$__in"
}

yesno() { # yesno <вопрос> <y|n по умолчанию>
  local q="$1" def="${2:-y}" ans hint
  [ "$def" = "y" ] && hint="Y/n" || hint="y/N"
  printf '%s%s%s [%s]: ' "$c_b" "$q" "$c_0" "$hint"
  IFS= read -r ans || return 1
  ans=$(printf %s "${ans:-$def}" | tr '[:upper:]' '[:lower:]')
  [ "$ans" = "y" ] || [ "$ans" = "yes" ] || [ "$ans" = "д" ] || [ "$ans" = "да" ]
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

# ------------------------------------------------------------------ list -----
cmd_list() {
  local found=0 f
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    found=1
    # shellcheck disable=SC1090
    ( . "$f"
      mp=$(mounted_path "$SERVER" "$SHARE")
      if [ -n "$mp" ]; then st="${c_g}смонтировано${c_0}"; else st="${c_y}не смонтировано${c_0}"; mp="$MOUNTPOINT"; fi
      printf '  %s//%s/%s%s  ->  %s  [%b]\n' "$c_b" "$SERVER" "$SHARE" "$c_0" "$mp" "$st" )
  done
  [ "$found" = 1 ] || say "  (ничего не установлено)"
}

# ------------------------------------------------------------- uninstall -----
cmd_uninstall() {
  say ""
  say "${c_b}Установленные подключения:${c_0}"
  cmd_list
  say ""
  local slugs=() f s
  for f in "$CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .conf)
    slugs+=("$s")
  done
  [ ${#slugs[@]} -gt 0 ] || { say "Удалять нечего."; exit 0; }

  for s in "${slugs[@]}"; do
    yesno "Удалить «$s»?" n || continue
    launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$s" 2>/dev/null
    rm -f "$AGENT_DIR/$LABEL_PREFIX.$s.plist"
    # shellcheck disable=SC1090
    ( . "$CONF_DIR/$s.conf"
      mp=$(mounted_path "$SERVER" "$SHARE")
      [ -n "$mp" ] && { /sbin/umount -f "$mp" 2>/dev/null || /usr/sbin/diskutil unmount force "$mp" 2>/dev/null; }
      rmdir "${FALLBACK:-}" 2>/dev/null
      if yesno "  Удалить и пароль из связки ключей?" n; then
        /usr/bin/security delete-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 \
          && echo "  пароль удалён"
      fi )
    rm -f "$CONF_DIR/$s.conf"
    ok "«$s» удалено"
  done
  exit 0
}

# --------------------------------------------------------------- install -----
cmd_install() {
  [ "$(uname -s)" = "Darwin" ] || die "скрипт рассчитан на macOS"

  say ""
  say "${c_b}=== Автомонтирование сетевой папки Windows ===${c_0}"
  say "Отвечайте на вопросы; Enter принимает значение в скобках."
  say ""

  ask SERVER   "Адрес сервера (имя или IP)"
  ask USERNAME "Логин" "$(id -un)"
  ask DOMAIN   "Домен AD (Enter — если нет)" "" allow_empty

  local P1 P2
  while :; do
    printf '%sПароль%s (не отображается): ' "$c_b" "$c_0"; IFS= read -rs P1; echo
    printf '%sПароль ещё раз%s: ' "$c_b" "$c_0";           IFS= read -rs P2; echo
    [ -n "$P1" ] && [ "$P1" = "$P2" ] && break
    warn "пароли не совпали или пусты — попробуйте снова"
  done

  # --- проверяем учётные данные и берём список папок с сервера ---
  local SHARE="" shares i line pick MODE=""
  if /usr/bin/nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1; then
    MODE=$(probe_mode "$SERVER" "$USERNAME" "$DOMAIN" "$P1") || MODE=""
    if [ -z "$MODE" ]; then
      warn "сервер не принял учётные данные ни как «$USERNAME», ни как «${DOMAIN:-ДОМЕН}\\$USERNAME», ни как «$USERNAME@${DOMAIN:-домен}»"
      warn "обычно это опечатка в пароле либо лишний/отсутствующий домен"
    else
      say "  вариант входа: $MODE"
      shares=$(list_shares "$SERVER" "$USERNAME" "$DOMAIN" "$P1" "$MODE")
      if [ -n "$shares" ]; then
        say ""
        say "${c_b}Папки, доступные на $SERVER:${c_0}"
        i=0
        while IFS= read -r line; do i=$((i+1)); printf '  %2d) %s\n' "$i" "$line"; done <<<"$shares"
        printf '  %2d) ввести имя вручную\n' "$((i+1))"
        ask pick "Выберите номер" "1"
        if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$i" ] 2>/dev/null; then
          SHARE=$(printf '%s\n' "$shares" | sed -n "${pick}p")
        fi
      fi
    fi
  fi
  [ -n "$SHARE" ] || ask SHARE "Имя сетевой папки — точно как на Windows"

  # Монтируем штатным механизмом macOS — том появляется в /Volumes под именем
  # папки, как при подключении через ⌘K. Точный путь выбирает система.
  local SLUG MOUNTPOINT FALLBACK MP
  SLUG=$(slugify "$SERVER-$SHARE")
  MOUNTPOINT="/Volumes/$SHARE"
  FALLBACK="$HOME/mnt/$SHARE"

  local INTERVAL
  ask INTERVAL "Интервал проверки, сек (ждём поднятия VPN)" "60"
  case "$INTERVAL" in (*[!0-9]*|'') INTERVAL=60 ;; esac

  local KEYCHAIN_SERVICE="smb:$SERVER/$SHARE"
  /usr/bin/security add-generic-password -U \
    -a "$USERNAME" -s "$KEYCHAIN_SERVICE" \
    -l "smb-automount: $SERVER/$SHARE" \
    -T /usr/bin/security -w "$P1" >/dev/null \
    || die "не удалось записать пароль в связку ключей"
  unset P1 P2
  ok "пароль сохранён в связке ключей"

  # --- файлы ---
  mkdir -p "$CONF_DIR" "$AGENT_DIR" "$BIN_DIR"
  chmod 700 "$CONF_DIR"
  drop_duplicates "$SERVER" "$SHARE" "$SLUG"

  cat >"$CONF_DIR/$SLUG.conf" <<CONF_EOF
# smb-automount: $SERVER/$SHARE
# создан $(date '+%F %T'). Можно править вручную, пароля здесь нет.
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
  ok "скрипт: $WORKER"
  ok "конфиг: $CONF_DIR/$SLUG.conf"

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
  ok "агент:  $PLIST"

  launchctl bootout "gui/$(id -u)/$LABEL_PREFIX.$SLUG" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null \
    || die "не удалось загрузить LaunchAgent"
  ok "агент запущен (перезагрузка не нужна)"

  # --- проверка ---
  say ""
  if /usr/bin/nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1; then
    say "Сервер доступен, пробую смонтировать…"
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      say "  отцепляю прежнее монтирование: $MP"
      /sbin/umount -f "$MP" 2>/dev/null || /usr/sbin/diskutil unmount force "$MP" 2>/dev/null
      sleep 1
    fi
    /bin/bash "$WORKER" "$CONF_DIR/$SLUG.conf"
    sleep 1
    MP=$(mounted_path "$SERVER" "$SHARE")
    if [ -n "$MP" ]; then
      ok "готово: $MP"
      yesno "Открыть папку в Finder?" y && open "$MP"
    else
      err "смонтировать не удалось. Лог:"
      tail -5 "$HOME/Library/Logs/smb-automount.log" 2>/dev/null | sed 's/^/    /'
      say ""
      say "Чаще всего дело в неверном имени шары, логине или домене."
      say "Проверьте значения в $CONF_DIR/$SLUG.conf и запустите установщик заново."
    fi
  else
    warn "сервер $SERVER сейчас недоступен — похоже, VPN выключен."
    say "  Это нормально: агент уже работает и смонтирует папку сам,"
    say "  в течение $INTERVAL сек. после подключения к VPN."
  fi

  say ""
  say "${c_b}Полезное:${c_0}"
  say "  Лог:              tail -f ~/Library/Logs/smb-automount.log"
  say "  Что установлено:  bash $0 --list"
  say "  Удалить:          bash $0 --uninstall"
  say "  Том появится в боковой панели Finder под именем «$SHARE»"
  say ""
}

case "${1:-}" in
  --uninstall|-u) cmd_uninstall ;;
  --list|-l)      say ""; cmd_list; say "" ;;
  --help|-h)      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' ;;
  "")             cmd_install ;;
  *)              die "неизвестный аргумент: $1 (см. --help)" ;;
esac
