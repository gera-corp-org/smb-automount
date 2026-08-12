#!/bin/bash
# Диагностический зонд для smb-automount: какую форму учётных данных
# принимает сервер. Пароль нигде не печатается и никуда не сохраняется.
#
#   bash probe-auth.sh
#
set -u

printf 'Сервер (имя или IP): ';    IFS= read -r SERVER
printf 'Логин: ';                  IFS= read -r USERNAME
printf 'Домен (Enter — пусто): ';  IFS= read -r DOMAIN
printf 'Пароль (не отображается): '; IFS= read -rs PASS; echo
echo

[ -n "$SERVER" ] && [ -n "$USERNAME" ] && [ -n "$PASS" ] || { echo "нужны сервер, логин и пароль"; exit 1; }

# Полное кодирование — то, что smb-automount делает сейчас.
enc_full() { printf %s "$1" | /usr/bin/perl -pe 's/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord($1))/ge'; }
# Минимальное — только символы, ломающие разбор URL.
enc_min()  { printf %s "$1" | /usr/bin/perl -pe 's/([%@:\/?#\[\]\s])/sprintf("%%%02X", ord($1))/ge'; }
# Без кодирования.
enc_none() { printf %s "$1"; }

creds() { # mode encfn password
  local u p d
  u=$("$2" "$USERNAME"); p=$("$2" "$3")
  case "$1" in
    domain) d=$("$2" "$DOMAIN"); printf '%s;%s:%s' "$d" "$u" "$p" ;;
    upn)    printf '%s:%s' "$("$2" "$USERNAME@$DOMAIN")" "$p" ;;
    *)      printf '%s:%s' "$u" "$p" ;;
  esac
}

try() { # mode encfn password
  /usr/bin/smbutil view -N "//$(creds "$1" "$2" "$3")@$SERVER" >/dev/null 2>&1
}

modes="plain"
[ -n "$DOMAIN" ] && modes="plain domain upn"

printf '%-8s | %-14s | %-14s | %s\n' "режим" "полное (сейчас)" "минимальное" "без кодирования"
printf -- '---------|----------------|----------------|----------------\n'
any=0
for m in $modes; do
  r1=FAIL; r2=FAIL; r3=FAIL
  try "$m" enc_full "$PASS" && { r1=OK; any=1; }
  try "$m" enc_min  "$PASS" && { r2=OK; any=1; }
  try "$m" enc_none "$PASS" && { r3=OK; any=1; }
  printf '%-8s | %-14s | %-14s | %s\n' "$m" "$r1" "$r2" "$r3"
done

echo
# Контроль: заведомо неверный пароль. Если он тоже OK — сервер пускает гостя,
# и все строки выше ничего не доказывают.
if try plain enc_full "wrong-$$-wrong"; then
  echo "ВНИМАНИЕ: сервер принял заведомо неверный пароль — доступ гостевой,"
  echo "          таблица выше ничего не значит."
elif [ "$any" = 0 ]; then
  echo "Ни одна форма не принята. Значит дело не в кодировании пароля:"
  echo "проверьте логин и домен, или пароль действительно другой."
else
  echo "Контроль пройден: неверный пароль отвергнут, значит OK выше настоящие."
fi

unset PASS
