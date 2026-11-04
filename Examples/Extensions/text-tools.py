#!/usr/bin/env python3
"""API v1 text tools; behavior reference: FAR 1a6b0254 EditCase/Align.

Independent Unicode adaptation, not a FAR binary plugin. Python Unicode mappings
can expand characters; widths count Unicode code points, not terminal cells.
"""
import hashlib
import json
import re
import sys

WORD_DIVIDERS = set(" \t\r\n~!%^&*()+|{}:\"<>?`-=\\[];',./#")


def case_mode(text, mode):
    if mode == 'cyclic':
        signal = re.search('[^' + re.escape(''.join(WORD_DIVIDERS)) + ']+', text)
        if not signal:
            return text
        word = signal.group()
        if len(word) == 1:
            mode = 'lower' if word == word.upper() else 'upper'
        elif word == word.upper():
            mode = 'title'
        elif word == word.lower():
            mode = 'upper'
        elif word == word[0].upper() + word[1:].lower():
            mode = 'lower'
        else:
            mode = 'toggle' if sum(c == c.upper() for c in word) > len(word) // 2 else 'lower'
    result, previous = [], False
    for char in text:
        if char in WORD_DIVIDERS:
            result.append(char)
            previous = False
            continue
        if mode == 'lower':
            result.append(char.lower())
        elif mode == 'upper':
            result.append(char.upper())
        elif mode == 'title':
            result.append(char.lower() if previous else char.upper())
        else:
            result.append(char.upper() if char.islower() else char.lower())
        previous = True
    return ''.join(result)


def justify_line(body, width):
    # JustifyString adds spaces to existing internal gaps, left to right.
    if len(body) >= width:
        return body
    trimmed = body.rstrip(' ')
    gaps = list(re.finditer(r'(?<=[^ ]) +(?=[^ ])', trimmed))
    if not gaps:
        return body
    extra, remainder = divmod(width - len(trimmed), len(gaps))
    result, start = [], 0
    for i, gap in enumerate(gaps):
        result.append(trimmed[start:gap.end()] + ' ' * (extra + (i < remainder)))
        start = gap.end()
    return ''.join(result) + trimmed[start:]


def reformat_block(lines, width, smart, justify):
    # FAR reformats the entire selected stream block into one paragraph,
    # omitting empty lines, with its minimum common indentation.
    nonempty = [line for line in lines if line.strip(' ')]
    indent = min([len(s) - len(s.lstrip(' ')) for s in nonempty] or [0])
    indent = min(indent, width - 1, 1023)
    total = ''
    for line in nonempty:
        if total and not total.endswith(' '):
            total += ' '
        total += line.lstrip(' ')
    if not total:
        return ['']
    total += ' '  # Sentinel causes a final overlong word to be emitted intact.
    limit = width - indent
    start = 0
    while start < len(total) and total[start] == ' ':
        start += 1
    previous, i, result = start, start, []
    while i < len(total):
        length, last_length = i - start, previous - start
        if total[i] == ' ' and length > limit and last_length <= limit:
            if last_length <= 0:
                previous, last_length = i, length
            if smart:
                spaces = [j for j in range(previous - 1, start + 20, -1) if total[j] == ' '][:2]
                if spaces:
                    space2 = spaces[0]
                    space1 = spaces[1] if len(spaces) > 1 else None
                    if previous - space2 < 4 and (space1 is None or space2 - space1 > 4 or previous - space2 == 2):
                        previous = space2
                        while previous > start + 1 and total[previous - 1] == ' ':
                            previous -= 1
            body = total[start:previous].rstrip(' ')
            result.append(' ' * indent + (justify_line(body, limit) if justify else body))
            i = previous
            while i < len(total) and total[i] == ' ':
                previous = i
                i += 1
            start = i
        if i < len(total) and total[i] == ' ':
            previous = i
        i += 1
    result.append(' ' * indent + total[start:].rstrip(' '))
    # The sentinel must not introduce an extra empty line after a long last word.
    if start == len(total) and len(result) > 1:
        result.pop()
    return result


def align(text, options):
    width = options.get('rightMargin', 75)
    tabs = options.get('tabSize', 8)
    if type(width) is not int or not 1 <= width <= 1000 or type(tabs) is not int or not 1 <= tabs <= 32:
        raise ValueError('Invalid Align width or tab size')
    for name in ['reformat', 'smartMode', 'justify']:
        if name in options and type(options[name]) is not bool:
            raise ValueError('Invalid Align option')
    reformat = options.get('reformat', True)
    justify = options.get('justify', False)
    if not reformat and not justify:
        return text
    # Preserve every existing EOL for justify-only; reflow uses the first EOL
    # while preserving whether the captured block ended with an EOL.
    parts = re.findall(r'([^\r\n]*)(\r\n|\r|\n|$)', text)
    if parts and parts[-1] == ('', ''):
        parts.pop()
    if not parts:
        return text
    expanded = [(body.expandtabs(tabs), ending) for body, ending in parts]
    if not reformat:
        return ''.join(justify_line(body, width) + ending for body, ending in expanded)
    ending = next((e for _, e in parts if e), '\n')
    result = reformat_block([s for s, _ in expanded], width, options.get('smartMode', False), justify)
    return ending.join(result) + (ending if parts[-1][1] else '')


def main():
    request = json.load(sys.stdin)
    if request['apiVersion'] != 1:
        sys.exit(2)
    mode = sys.argv[1]
    kinds = {'checksum': 'command', 'stats': 'panel', 'json': 'viewer', 'uppercase': 'editor', 'align': 'editor'}
    kind = 'editor' if mode in ['editcase-' + m for m in ['lower', 'title', 'upper', 'toggle', 'cyclic']] else kinds[mode]
    if request['kind'] != kind:
        sys.exit(3)
    response = {'apiVersion': 1, 'kind': kind, 'title': mode.title(), 'rows': []}
    text = request.get('text') or ''
    if mode == 'checksum':
        response['text'] = hashlib.sha256(text.encode('utf-8')).hexdigest()
    elif mode == 'stats':
        entries = request['entries']
        response['rows'] = [
            {'label': 'Files', 'value': str(sum(not e['isDirectory'] for e in entries))},
            {'label': 'Directories', 'value': str(sum(e['isDirectory'] for e in entries))},
            {'label': 'File bytes', 'value': str(sum(e['size'] for e in entries if not e['isDirectory']))}]
    elif mode == 'json':
        response['text'] = json.dumps(json.loads(text), indent=2, ensure_ascii=False)
    elif mode == 'align':
        response['text'] = align(text, request.get('options') or {})
    elif mode.startswith('editcase-'):
        response['text'] = case_mode(text, mode.removeprefix('editcase-'))
    else:
        response['text'] = text.upper()
    json.dump(response, sys.stdout, ensure_ascii=False)


if __name__ == '__main__':
    main()
