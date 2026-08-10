#!/bin/bash
#
# Проверка на конструкции, которых не понимает bash 3.2 — системный на macOS.
# Разработка идёт на bash 5, где всё это проходит молча, а на целевой машине
# скрипт падает с кодом 258 ещё до первой строки вывода. Так и случилось:
# из-за одного case внутри $( ) приложение закрывалось сразу после запуска.
#
#   bash tests/check-bash32.sh файл [файл...]
#
set -u

python3 - "$@" <<'PY'
import re, sys, pathlib

def strip_heredocs(text):
    """Тело heredoc bash не разбирает, поэтому вырезаем его из проверки."""
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
    """Ищет case внутри $( ... ).

    Кавычки внутри подстановки живут своей жизнью: "$(cat "$f")" — это
    строка, внутри неё подстановка, внутри неё снова строка. Поэтому на
    каждый $( кладём в стек новый контекст со своим состоянием кавычек,
    иначе закрывающая скобка теряется и разбор уезжает до конца файла.
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
            if text[i+2:i+3] == '(':          # арифметика $(( )) — не подстановка
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
        print('  %s:%d  case внутри $( ) — bash 3.2 не разберёт: %s' % (name, line, snippet[:70]))
        fail = True

    for n, ln in enumerate(src.split('\n'), 1):
        if re.search(r'\$\{[^}]*\\\\\}', ln):
            print('  %s:%d  обратный слэш внутри ${...} — заменить обычным if' % (name, n))
            fail = True
        if re.search(r'\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)', ln) or \
           re.search(r'(^|[^-\w])(mapfile|readarray|declare -A|local -n)\b', ln):
            print('  %s:%d  возможности bash 4+: %s' % (name, n, ln.strip()[:60]))
            fail = True

sys.exit(1 if fail else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "совместимость с bash 3.2: НЕ пройдена" >&2
  exit 1
fi
echo "совместимость с bash 3.2: в порядке"
