#!/usr/bin/env python3
"""Flags a def that calls itself in two arguments of one Bool.pick.

Bool.pick(T, c, a, b) is an ordinary def: Bend computes a and b before it
picks, so a def recursing in both is exponential (Meta.pct once was).
Branch through a helper def that matches on the Bool instead, or bind the
recursive result once with a let. Usage: pick-recursion.py FILE...
"""
import re, sys

def args_of(text, start):
    """The top-level arguments of the call whose '(' is at start."""
    depth, cur, out, i = 0, [], [], start
    while i < len(text):
        ch = text[i]
        if ch in '([{':
            depth += 1
            if depth > 1: cur.append(ch)
        elif ch in ')]}':
            depth -= 1
            if depth == 0:
                out.append(''.join(cur)); return out
            cur.append(ch)
        elif ch == ',' and depth == 1:
            out.append(''.join(cur)); cur = []
        else:
            cur.append(ch)
        i += 1
    return out

bad = 0
for path in sys.argv[1:]:
    text = open(path).read()
    for d in re.split(r'\n(?=(?:@unsafe )?def )', text):
        m = re.match(r'(?:@unsafe )?def ([\w.]+)\(', d)
        if not m: continue
        name = m.group(1); body = d.split('\n', 1)[1] if '\n' in d else ''
        call = re.compile(r'(?<![\w.])' + re.escape(name) + r'\(')
        for p in re.finditer(r'Bool\.pick\(', body):
            hits = [a for a in args_of(body, p.end() - 1)[2:] if call.search(a)]
            if len(hits) >= 2:
                line = text[:text.index(d)].count('\n') + d[:d.index('\n') + 1 + p.start()].count('\n') + 1
                print(f"{path}:{line}: {name} recurses in two arguments of one Bool.pick (both are computed: exponential)")
                bad += 1
sys.exit(1 if bad else 0)
