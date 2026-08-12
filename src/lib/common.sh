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
# Which login form the server accepts. Prints it and exits 0.
#   1 — the server answered and turned the credentials down.
#   2 — no SMB answer at all, so nothing was ever checked and the credentials
#       are not the suspect. A VPN client that intercepts DNS lands here: the
#       port answers, the SMB session never starts. Reporting that as a bad
#       password sends everyone hunting the wrong thing, which is exactly what
#       it did once already.
probe_mode() { # server user domain password
  local m rc conn_only=1
  for m in $(auth_modes "$3"); do
    /usr/bin/smbutil view -N "//$(auth_str "$m" "$2" "$3" "$4")@$1" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && { printf '%s\n' "$m"; return 0; }
    case "$rc" in (68|69) ;; (*) conn_only=0 ;; esac
  done
  [ "$conn_only" -eq 1 ] && return 2
  return 1
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

# `security … -w` prints the password as a lowercase hex dump instead of the
# text as soon as it holds one byte outside ASCII — a single umlaut or Cyrillic
# letter is enough. Handed on as-is, that dump travels to the server as the
# literal "d09f…" and the mount comes back as "permission denied", while setup,
# which still has the typed password in memory, succeeds. A dump cannot be told
# apart from a password that merely looks like one ("deadbeef"), so only that
# shape is re-checked with -g, which marks a real dump with an 0x prefix.
# The dump comes out lowercase on macOS 26, but both cases are accepted: it
# costs nothing, `perl hex()` eats either, and the -g check below still has the
# last word on whether it is a dump at all.
kc_is_hex() { # candidate -> true if it could be a hex dump
  case "$1" in (''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ $(( ${#1} % 2 )) -eq 0 ]
}
kc_unhex() { printf %s "$1" | /usr/bin/perl -pe 's/(..)/chr(hex($1))/ge'; }
