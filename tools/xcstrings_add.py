#!/usr/bin/env python3
"""Add localized strings to Localizable.xcstrings WITHOUT reserializing the file.

Xcode writes this catalog with `" : "` separators and ICU-collated key order. Any
`json.dump()` round-trip changes both — a 4-key addition comes out as a ~4,300-line diff,
which is exactly what it must not do (three sessions have this file open). So: parse to
check what's already there, but edit as text, splicing whole blocks in and leaving every
untouched byte alone. Idempotent — re-running is a no-op.
"""
import json, sys

P = 'BallIQ/Localizable.xcstrings'

# key -> (spanish, anchor key, 'before'|'after')  — anchors must already exist.
# Position is cosmetic: Xcode re-collates on its next save. Validity is what matters.
NEW = [
    ("Your streak", "Tu racha", "Your rank", "before"),
    ("Your rating", "Tu puntuación", "Your rank", "before"),
    ("Your league", "Tu liga", "Your rank", "before"),
    ("You're on %lld. Reinstall without an account and it starts over at zero.",
     "Vas por %lld. Reinstala sin cuenta y vuelve a cero.", "Your rank", "before"),
    ("Play a day at a time and it builds. Without an account it starts over at zero.",
     "Juega un día a la vez y crece. Sin cuenta, vuelve a cero.", "Your rank", "before"),
    ("Every ranked game moves it. Signed in, it follows you to any device.",
     "Cada partida clasificatoria la mueve. Con sesión iniciada, te sigue a cualquier dispositivo.", "Your rank", "before"),
    ("You're placed with players at your level every Monday. That needs an account.",
     "Cada lunes te colocan con jugadores de tu nivel. Eso requiere una cuenta.", "Your rank", "before"),
]

def block(key, es):
    k = json.dumps(key, ensure_ascii=False)
    v = json.dumps(es, ensure_ascii=False)
    return (f'    {k} : {{\n'
            f'      "localizations" : {{\n'
            f'        "es" : {{\n'
            f'          "stringUnit" : {{\n'
            f'            "state" : "translated",\n'
            f'            "value" : {v}\n'
            f'          }}\n'
            f'        }}\n'
            f'      }}\n'
            f'    }},\n')

def span(src, key):
    """(start, end) offsets of `key`'s whole block, including its trailing `,\\n`."""
    marker = f'\n    {json.dumps(key, ensure_ascii=False)} : {{'
    i = src.index(marker) + 1
    depth, j = 0, i
    while True:
        c = src[j]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                j += 1
                if j < len(src) and src[j] == ',': j += 1
                if j < len(src) and src[j] == '\n': j += 1
                return i, j
        j += 1

src = open(P, encoding='utf-8').read()
added = 0
for key, es, anchor, where in NEW:
    if key in json.loads(src)['strings']:
        print('present, skipping:', key); continue
    s, e = span(src, anchor)
    at = s if where == 'before' else e
    src = src[:at] + block(key, es) + src[at:]
    added += 1
    print(f'added: {key!r}  ({where} {anchor!r})')

if added:
    json.loads(src)                      # refuse to write invalid JSON
    open(P, 'w', encoding='utf-8').write(src)
print(f'{added} added')
