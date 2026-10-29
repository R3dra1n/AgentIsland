#!/usr/bin/env python3
"""Record only task identity and lifecycle metadata. Never approve, deny, or block tools."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import time

EVENTS = {'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PermissionRequest',
          'PreToolUse', 'PostToolUse', 'SubagentStart', 'SubagentStop', 'Stop',
          'Interrupt', 'PreInvocation'}

def normalize(data, source, event=None):
    name = event or data.get('hook_event_name')
    session = data.get('session_id') if source == 'codex' else data.get('conversationId')
    if name not in EVENTS or not isinstance(session, str) or not session or len(session) > 256:
        raise ValueError('unsupported or missing lifecycle identity')
    record = {'hook_event_name': name, 'session_id': session}
    for key in ('turn_id', 'agent_id', 'tool_use_id', 'tool_name', 'request_id'):
        value = data.get(key)
        if isinstance(value, str) and 0 < len(value) <= 256:
            record[key] = value
    if source == 'codex' and name == 'PermissionRequest':
        # Match the displayed command without journaling command text or tool input.
        tool_input = data.get('tool_input')
        if isinstance(tool_input, dict):
            command = tool_input.get('command', tool_input.get('cmd'))
            if isinstance(command, str) and 0 < len(command) <= 65536:
                normalized = command.strip()
                record['command_digest'] = hashlib.sha256(normalized.encode()).hexdigest()
    if source == 'antigravity':
        # Antigravity uses camelCase fields; no synthetic turn IDs are invented.
        tool = data.get('toolCall', {}).get('name')
        if isinstance(tool, str) and len(tool) <= 256: record['tool_name'] = tool
        if name == 'Stop':
            reason = data.get('terminationReason')
            if isinstance(reason, str):
                reason = {'ERROR': 'error', 'USER_CANCELED': 'cancelled',
                          'MAX_INVOCATIONS': 'max_steps_exceeded',
                          'MAX_TOKEN_BUDGET_EXCEEDED': 'max_steps_exceeded',
                          'NO_TOOL_CALL': 'model_stop'}.get(reason, reason)
            if isinstance(reason, str) and reason in {'model_stop', 'max_steps_exceeded', 'error', 'cancelled', 'interrupted'}:
                record['termination_reason'] = reason
            record['fully_idle'] = data.get('fullyIdle') is True
            record['has_error'] = bool(data.get('error'))
    return record

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, choices=['codex', 'antigravity'])
    parser.add_argument('--event', choices=sorted(EVENTS))
    parser.add_argument('--directory', type=Path, default=Path.home() / 'Library/Application Support/AgentIsland/events')
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024: raise ValueError('oversized hook input')
        record = normalize(json.loads(raw), args.source, args.event)
        args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = args.directory / (args.source + '.jsonl')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as stream:
            deadline = time.monotonic() + .25
            while True:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline: raise TimeoutError('event journal busy')
                    time.sleep(.005)
            record['received_at'] = time.time()
            stream.write(json.dumps(record, separators=(',', ':')) + '\n')
            stream.flush()
    except Exception as error:
        # Do not emit input contents, or change the host's approval decision on a logging failure.
        print('AgentIsland hook was not recorded: ' + type(error).__name__, file=sys.stderr)
    print('{"decision":"stop"}' if args.source == 'antigravity' and args.event == 'Stop' else '{}')

if __name__ == '__main__': main()
