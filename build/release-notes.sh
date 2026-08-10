#!/bin/bash
#
# Prints the CHANGELOG.md section for one version — the body of a GitHub
# release. The release workflow calls it; running it by hand shows what the
# release will say.
#
#   bash build/release-notes.sh 1.0.0
#
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=${1:-$(cat "$ROOT/VERSION")}
VER=${VER#v}

# The heading is "## 1.0.0" or "## 1.0.0 — 2026-08-10": the version is the
# second field. Blank lines are held back until something follows them, so the
# section comes out without leading or trailing empties.
awk -v ver="$VER" '
  /^## / { if (found) exit; found = ($2 == ver); next }
  !found { next }
  NF == 0 { if (printed) blank++; next }
  { while (blank-- > 0) print ""; blank = 0; printed = 1; print }
  END { if (!found) { print "no CHANGELOG.md section for version " ver > "/dev/stderr"; exit 1 } }
' "$ROOT/CHANGELOG.md"
