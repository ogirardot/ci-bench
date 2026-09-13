#!/usr/bin/env python3
"""join_push_times.py — build compare.py's --push-times map from push-times.jsonl.

Joins each collected run (results/<platform>/<run-id>.json, keyed by the
run_id embedded in its records) to its push timestamp via the 7-char short
sha both carry. Emits {"<platform>/<run_id>": "<iso8601>", ...}.
"""
import json, glob, sys

pushes = {}
for line in open('push-times.jsonl'):
    r = json.loads(line)
    pushes[(r['platform'], r['sha'][:7])] = r['pushed_at']

out = {}
for f in sorted(glob.glob('results/*/*.json')):
    recs = json.load(open(f))
    if not recs:
        continue
    rid, plat = recs[0]['run_id'], recs[0]['platform']
    key = (plat, rid.split('-')[-1])
    if key in pushes:
        out[f'{plat}/{rid}'] = pushes[key]

json.dump(out, open('push-times.json', 'w'), indent=1)
print(f'join_push_times: {len(out)} runs matched')
