#!/usr/bin/env python3
"""Far extension API v1 examples: checksum, stats, json, uppercase."""
import hashlib
import json
import sys

request = json.load(sys.stdin)
if request['apiVersion'] != 1:
    sys.exit(2)
mode = sys.argv[1]
kind = {'checksum': 'command', 'stats': 'panel', 'json': 'viewer', 'uppercase': 'editor', 'editcase-upper': 'editor', 'editcase-lower': 'editor', 'align': 'editor'}[mode]
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
    def justify(line):
        ending = '\r\n' if line.endswith('\r\n') else (line[-1:] if line.endswith(('\n', '\r')) else '')
        body = line[:-len(ending)] if ending else line
        words = body.split(' ')
        if (not 0 < len(body) < 75 or len(words) < 2 or any(not word for word in words)
                or any(ord(c) < 32 or ord(c) > 126 for c in body)):
            return line
        quotient, remainder = divmod(75 - len(body), len(words) - 1)
        return ''.join(word + (' ' * (1 + quotient + (i < remainder)) if i < len(words) - 1 else '')
                       for i, word in enumerate(words)) + ending
    response['text'] = ''.join(justify(line) for line in text.splitlines(keepends=True))
elif mode == 'editcase-lower':
    response['text'] = text.translate(str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))
elif mode == 'editcase-upper':
    response['text'] = text.translate(str.maketrans('abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'))
else:
    response['text'] = text.upper()
json.dump(response, sys.stdout, ensure_ascii=False)
