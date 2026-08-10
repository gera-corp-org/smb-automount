#!/bin/bash
#
# Checks for constructs that bash 3.2 — the system bash on macOS — cannot parse.
# Development happens on bash 5, where all of this passes silently, while on the
# target machine the script dies with code 258 before printing a single line.
# That actually happened: one case inside $( ) made the app quit right after
# launch.
#
#   bash tests/check-bash32.sh file [file...]
#
set -u

python3 - "$@" <<'PY'
import re, sys, pathlib

def strip_heredocs(text):
    """bash does not parse a heredoc body, so cut it out of the check."""
    lines = text.split('\n')
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = re.search(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1', line)
        if m and not line.lstrip().startswith('#'):
            term = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != term:
                out.append('')
                i += 1
            if i < len(lines):
                out.append(lines[i])
        i += 1
    return '\n'.join(out)


def case_inside_substitution(text):
    """Finds case inside $( ... ).

    Quotes inside a substitution live their own life: "$(cat "$f")" is a
    string, inside it a substitution, inside that a string again. So every $(
    pushes a fresh context with its own quote state onto the stack — otherwise
    the closing paren is lost and parsing runs away to the end of the file.
    """
    bad = []
    stack = [{'sq': False, 'dq': False}]
    i, n, line = 0, len(text), 1

    while i < n:
        top = stack[-1]
        c = text[i]

        if c == '\n':
            line += 1; i += 1; continue

        if top['sq']:
            if c == "'":
                top['sq'] = False
            i += 1; continue

        if c == '\\':
            i += 2; continue

        if c == '$' and text[i+1:i+2] == '(':
            if text[i+2:i+3] == '(':          # arithmetic $(( )) — not a substitution
                i += 3; continue
            stack.append({'sq': False, 'dq': False})
            i += 2; continue

        if c == ')' and len(stack) > 1:
            stack.pop()
            i += 1; continue

        if top['dq']:
            if c == '"':
                top['dq'] = False
            i += 1; continue

        if c == "'":
            top['sq'] = True; i += 1; continue
        if c == '"':
            top['dq'] = True; i += 1; continue

        if c == '#' and (i == 0 or text[i-1] in ' \t\n;'):
            while i < n and text[i] != '\n':
                i += 1
            continue

        if len(stack) > 1 and text.startswith('case', i) \
           and (i == 0 or text[i-1] in ' \t\n;(') and text[i+4:i+5] in (' ', '\t'):
            end = text.find('\n', i)
            bad.append((line, text[i:end if end > 0 else n].strip()))

        i += 1

    return bad


fail = False
for path in sys.argv[1:]:
    src = strip_heredocs(pathlib.Path(path).read_text())
    name = pathlib.Path(path).name

    for line, snippet in case_inside_substitution(src):
        print('  %s:%d  case inside $( ) — bash 3.2 will not parse it: %s' % (name, line, snippet[:70]))
        fail = True

    for n, ln in enumerate(src.split('\n'), 1):
        if re.search(r'\$\{[^}]*\\\\\}', ln):
            print('  %s:%d  backslash inside ${...} — replace with a plain if' % (name, n))
            fail = True
        if re.search(r'\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)', ln) or \
           re.search(r'(^|[^-\w])(mapfile|readarray|declare -A|local -n)\b', ln):
            print('  %s:%d  bash 4+ feature: %s' % (name, n, ln.strip()[:60]))
            fail = True

sys.exit(1 if fail else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "bash 3.2 compatibility: FAILED" >&2
  exit 1
fi
echo "bash 3.2 compatibility: ok"
