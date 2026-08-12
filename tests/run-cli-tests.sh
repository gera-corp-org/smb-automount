#!/bin/bash
#
# Setup-flow tests for the terminal installer, on stubs. The app asks the same
# questions in the same order through dialogs, so this is the closest thing to
# a test of the setup flow there is — the app's own osascript layer stays
# untested.
#
#   bash build/build.sh && bash tests/run-cli-tests.sh
#
# Needs dist/: the built installer is what a user actually runs.
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d); STUB="$WORK/stub"
passed=0; failed=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STUB"

CLI=$(ls "$ROOT"/dist/smb-automount-install-*.sh 2>/dev/null | head -1)
[ -n "$CLI" ] || { echo "no built installer in dist/ — run build/build.sh first" >&2; exit 1; }

# The same rewrite the worker tests use: absolute paths become stub names.
sed -e 's#/usr/bin/nc#nc#g' -e 's#/usr/bin/smbutil#smbutil#g' \
    -e 's#/usr/bin/security#security#g' -e 's#/sbin/mount#mount_stub#g' \
    "$CLI" > "$WORK/cli.sh"

stub() { cat > "$STUB/$1"; chmod +x "$STUB/$1"; }
stub uname      <<<'#!/bin/bash
echo Darwin'
stub security   <<<'#!/bin/bash
exit 0'
stub mount_stub <<<'#!/bin/bash
exit 0'
stub launchctl  <<<'#!/bin/bash
exit 0'

# Runs the installer with canned answers. $1 names the case, $2 is nc's exit
# code (the port probe), $3 smbutil's, $4 what smbutil prints.
run() { # name nc-code smbutil-code [share-listing]
  printf '#!/bin/bash\nexit %s\n' "$2" > "$STUB/nc"
  { printf '#!/bin/bash\n'; printf "printf '%%s' '%s'\n" "${4:-}"; printf 'exit %s\n' "$3"; } > "$STUB/smbutil"
  chmod +x "$STUB/nc" "$STUB/smbutil"
  local home="$WORK/home-$1"; mkdir -p "$home"
  printf 'vault.example.local\nCORP\nadmin\nsecret\nsecret\n1\n60\n' \
    | HOME="$home" PATH="$STUB:$PATH" bash "$WORK/cli.sh" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/out"
}

check() { # description pattern
  if grep -q "$2" "$WORK/out"; then
    echo "  ok   $1"; passed=$((passed + 1))
  else
    echo "  FAIL $1 — no “$2” in the output"
    sed 's/^/         /' "$WORK/out"; failed=$((failed + 1))
  fi
}
check_not() { # description pattern
  if grep -q "$2" "$WORK/out"; then
    echo "  FAIL $1 — “$2” should not be there"; failed=$((failed + 1))
  else
    echo "  ok   $1"; passed=$((passed + 1))
  fi
}

echo "1. The questions come in order, and the password prompt names the account"
run order 1 0
# All four prompts sit on one line: each waits for an answer without a newline.
check "server, then domain, then login, then password" \
      'Server address.*AD domain.*Login (short.*Password for CORP\\admin'

echo "2. The server does not answer — say so instead of moving on in silence"
run unreachable 1 0
check "the port probe failure is reported" "does not answer on port 445"
check "and it is not presented as a fatal error" "the agent will mount the share"
check_not "no share list is offered" "Shares available"

echo "3. The server answers and turns the credentials down"
run rejected 0 77
check "the rejection is reported" "accepted the credentials neither as"
check_not "the port is not blamed" "does not answer on port 445"

echo "4. The server answers over SMB but never starts a session"
run nosmb 0 68
check "the connection is blamed, not the password" "never starts an SMB session"
check "and it says where to look" "dscacheutil"
check_not "the password is not blamed" "accepted the credentials neither as"

echo "5. Everything checks out — the shares are offered"
run accepted 0 0 'Share                Type       Comment
-------------------------------------------
Documents            Disk
Reports              Disk
'
check "the list is shown" "Shares available on vault.example.local"
check "the shares are in it" "1) Documents"
check "typing by hand is still an option" "type the name by hand"
check_not "nothing is reported as broken" "does not answer on port 445"

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
