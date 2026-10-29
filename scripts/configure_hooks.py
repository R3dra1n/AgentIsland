#!/usr/bin/env python3
"""Generate/merge AgentIsland hooks without replacing unrelated registrations."""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import tempfile
import os
import time

NAME = 'agentisland'

def configuration(source, script=None, native=False):
    script = script or Path(__file__).resolve().with_name('record_hook.py')
    base = ('' if native else '/usr/bin/python3 ') + shlex.quote(str(script)) + ' --source ' + source
    if source == 'codex':
        names = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse',
                 'PermissionRequest', 'PostToolUse', 'SubagentStart', 'SubagentStop', 'Stop', 'Interrupt']
        return {'hooks': {name: [{'hooks': [{'type': 'command', 'command': base, 'timeout': 1}]}] for name in names}}
    # PreToolUse can change permission decisions in Antigravity, so it is intentionally not installed.
    result = {}
    for name in ['PreInvocation', 'PostToolUse', 'Stop']:
        handler = {'type': 'command', 'command': base + ' --event ' + name, 'timeout': 1}
        result[name] = [{'matcher': '*', 'hooks': [handler]}] if name == 'PostToolUse' else [handler]
    return {NAME: result}

def merge(existing, source, script=None, native=False):
    result = dict(existing)
    generated = configuration(source, script, native=native)
    if source == 'antigravity':
        # Migrate only our own handlers, including those alongside user hooks.
        # Never replace an entire namespace that may contain custom settings.
        for namespace in ('aikeyboardlight', NAME):
            existing_events = result.get(namespace)
            if not isinstance(existing_events, dict):
                continue
            preserved_events = {}
            for event, entries in existing_events.items():
                if not isinstance(entries, list):
                    preserved_events[event] = entries
                    continue
                kept = []
                for entry in entries:
                    if not isinstance(entry, dict):
                        kept.append(entry)
                    elif isinstance(entry.get('hooks'), list):
                        group = dict(entry)
                        group['hooks'] = [item for item in entry['hooks']
                                          if not (isinstance(item, dict) and is_own_antigravity_hook(item.get('command', '')))]
                        if group['hooks'] or not entry['hooks'] or not set(group).issubset({'hooks', 'matcher'}):
                            kept.append(group)
                    elif not is_own_antigravity_hook(entry.get('command', '')):
                        kept.append(entry)
                if kept:
                    preserved_events[event] = kept
            if preserved_events:
                result[namespace] = preserved_events
            else:
                result.pop(namespace, None)
        target = result.setdefault(NAME, {})
        if not isinstance(target, dict):
            raise ValueError('AgentIsland hook namespace is not an object')
        for event, entries in generated[NAME].items():
            current = target.setdefault(event, [])
            if not isinstance(current, list):
                raise ValueError('AgentIsland hook event is not a list')
            current.extend(entries)
        return result
    hooks = dict(result.get('hooks', {}))
    for event, groups in generated['hooks'].items():
        preserved = []
        for group in hooks.get(event, []):
            group = dict(group)
            original_handlers = group.get('hooks', [])
            group['hooks'] = [handler for handler in original_handlers
                              if not isinstance(handler, dict) or not is_own_codex_hook(handler.get('command', ''), groups[0]['hooks'][0]['command'])]
            if group['hooks'] or not original_handlers or not set(group).issubset({'hooks', 'matcher'}):
                preserved.append(group)
        hooks[event] = preserved + groups
    result['hooks'] = hooks
    return result

def is_own_antigravity_hook(command):
    if not isinstance(command, str):
        return False
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    if len(parts) == 6 and parts[0] == '/usr/bin/python3':
        script, args = Path(parts[1]), parts[2:]
        valid_name = script.name == 'record_hook.py'
    elif len(parts) == 5:
        script, args = Path(parts[0]), parts[1:]
        valid_name = script.name == 'AgentIslandHook'
    else:
        return False
    return (valid_name and script.parent.name in {'scripts', 'hooks'}
            and script.parent.parent.name in {'AiKeyboardLight', 'AgentIsland', 'AiStatusBar'}
            and args[:2] == ['--source', 'antigravity']
            and args[2] == '--event' and args[3] in {'PreInvocation', 'PostToolUse', 'Stop'})

def is_own_codex_hook(command, generated):
    if command == generated:
        return True
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    # Migrate only our precise old recorder invocation, preserving unrelated hooks.
    if len(parts) == 4 and parts[0] == '/usr/bin/python3':
        script, args = Path(parts[1]), parts[2:]
        valid_name = script.name == 'record_hook.py'
    elif len(parts) == 3:
        script, args = Path(parts[0]), parts[1:]
        valid_name = script.name == 'AgentIslandHook'
    else:
        return False
    return (valid_name and script.parent.name in {'scripts', 'hooks'}
            and script.parent.parent.name in {'AiKeyboardLight', 'AgentIsland', 'AiStatusBar'}
            and args == ['--source', 'codex'])

def install_recorder(directory=None, native_helper=None):
    directory = directory or Path.home() / 'Library/Application Support/AgentIsland/hooks'
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / ('AgentIslandHook' if native_helper else 'record_hook.py')
    fd, temp = tempfile.mkstemp(dir=directory, prefix='.recorder-')
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write((Path(native_helper) if native_helper else Path(__file__).with_name('record_hook.py')).read_bytes())
        if native_helper:
            os.chmod(temp, 0o700)
        os.replace(temp, target)
    finally:
        if os.path.exists(temp): os.unlink(temp)
    return target

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, choices=['codex', 'antigravity'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--recorder-dir', type=Path, help='Override recorder directory for isolated installs and tests')
    parser.add_argument('--native-helper', type=Path, help='Install an AgentIslandHook executable instead of Python recorder')
    args = parser.parse_args()
    path = args.output.expanduser().resolve()
    existing = json.loads(path.read_text()) if path.exists() else {}
    
    script = install_recorder(args.recorder_dir, native_helper=args.native_helper)
    updated = merge(existing, args.source, script, native=args.native_helper is not None)
    path.parent.mkdir(parents=True, exist_ok=True)
    
    if path.exists():
        # Preserve the immediately preceding configuration on every install;
        # later user edits must not be silently lost behind one stale backup.
        backup = path.with_name(path.name + '.agentisland-backup-' + str(time.time_ns()))
        shutil.copy2(path, backup)
            
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=path.name + '.')
    try:
        with os.fdopen(fd, 'w') as f: json.dump(updated, f, ensure_ascii=False, indent=2); f.write('\n')
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)
    print('Wrote ' + str(path))
    print('Codex hooks require review/trust in Codex before they execute.' if args.source == 'codex' else 'Reload Antigravity to pick up its hooks.')

if __name__ == '__main__': main()
