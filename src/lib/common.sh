# Shared smb-automount functions.
# The build substitutes this file for the @@COMMON@@ marker in both the
# frontends and the worker: the worker is installed as a standalone file and
# cannot import anything.

# --------------------------------------------------------------- helpers -----
urlenc() {
  printf %s "$1" | /usr/bin/perl -pe 's/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord($1))/ge'
}
# Credentials string for an SMB URL. Servers expect different forms of the
# user name, hence three variants: DOMAIN;user, plain user, and user@domain (UPN).
auth_str() { # mode user domain password
  local u p d
  u=$(urlenc "$2"); p=$(urlenc "$4")
  case "$1" in
    domain) d=$(urlenc "$3"); printf '%s;%s:%s' "$d" "$u" "$p" ;;
    upn)    printf '%s:%s' "$(urlenc "$2@$3")" "$p" ;;
    *)      printf '%s:%s' "$u" "$p" ;;
  esac
}
auth_modes() { # domain -> variants to try
  if [ -n "$1" ]; then printf 'domain plain upn'; else printf 'plain'; fi
}
# Decoding of mount_smbfs exit codes (sysexits.h)
code_hint() {
  case "$1" in
    64) echo "malformed URL" ;;
    68) echo "server not found" ;;
    69) echo "server unavailable" ;;
    71) echo "system error" ;;
    77) echo "permission denied — login, password, domain or share permissions" ;;
    78) echo "configuration error" ;;
    *)  echo "code $1" ;;
  esac
}
