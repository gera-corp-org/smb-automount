# Общие функции smb-automount.
# Сборщик подставляет этот файл вместо строки @@COMMON@@ и во фронтенды,
# и в рабочий скрипт: тот ставится отдельным файлом и импортировать ничего не может.

# --------------------------------------------------------------- утилиты -----
urlenc() {
  printf %s "$1" | /usr/bin/perl -pe 's/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord($1))/ge'
}
# Строка учётных данных для SMB-URL. Разные серверы ждут разную форму имени,
# поэтому вариантов три: DOMAIN;user, просто user и user@domain (UPN).
auth_str() { # mode user domain password
  local u p d
  u=$(urlenc "$2"); p=$(urlenc "$4")
  case "$1" in
    domain) d=$(urlenc "$3"); printf '%s;%s:%s' "$d" "$u" "$p" ;;
    upn)    printf '%s:%s' "$(urlenc "$2@$3")" "$p" ;;
    *)      printf '%s:%s' "$u" "$p" ;;
  esac
}
auth_modes() { # domain -> список вариантов для перебора
  if [ -n "$1" ]; then printf 'domain plain upn'; else printf 'plain'; fi
}
# Расшифровка кодов выхода mount_smbfs (sysexits.h)
code_hint() {
  case "$1" in
    64) echo "не разобран URL" ;;
    68) echo "сервер не найден" ;;
    69) echo "сервер недоступен" ;;
    71) echo "ошибка системы" ;;
    77) echo "отказано в доступе — логин, пароль, домен или права на папку" ;;
    78) echo "ошибка конфигурации" ;;
    *)  echo "код $1" ;;
  esac
}
