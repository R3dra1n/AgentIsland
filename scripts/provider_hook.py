#!/usr/bin/env python3
"""Status-only Cursor / Windsurf hooks; no prompt, command or credential storage."""
import argparse, fcntl, hashlib, json, os, pathlib, tempfile, time

EVENTS = {'cursor': {'beforeSubmitPrompt':'running', 'stop':'completed', 'sessionEnd':'idle'},
          'windsurf': {'pre_user_prompt':'running', 'post_cascade_response':'completed'}}

def record(provider, event, payload, root):
    status = EVENTS[provider].get(event)
    if status is None: return
    session = payload.get('conversation_id') or payload.get('trajectory_id') or payload.get('session_id')
    # Without identity concurrent tasks cannot be safely combined.
    if not isinstance(session, str) or not session: return
    if event == 'stop':
        status = {'error':'failed', 'aborted':'interrupted'}.get(payload.get('status'), status)
    folder = pathlib.Path(root) / provider
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256(session.encode()).hexdigest()
    with open(folder / (key + '.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        destination = folder / (key + '.json')
        previous = json.loads(destination.read_text()) if destination.exists() else {}
        generation = payload.get('generation_id')
        if event == 'stop' and generation and previous.get('generation') not in (None, generation): return
        data = dict(state=status, updatedAt=time.time(), generation=generation)
        fd, name = tempfile.mkstemp(dir=folder)
        with os.fdopen(fd,'w') as out: json.dump(data,out)
        os.replace(name,destination)

if __name__ == '__main__':
    import sys
    p=argparse.ArgumentParser();p.add_argument('provider',choices=EVENTS);p.add_argument('event');args=p.parse_args()
    try:
        record(args.provider,args.event,json.load(sys.stdin),os.path.expanduser('~/Library/Application Support/AgentIsland/providers'))
    except Exception:
        pass # Observation must never block the editor's agent.
