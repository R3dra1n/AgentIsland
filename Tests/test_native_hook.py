import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = os.environ.get('AGENTISLAND_TEST_HOOK')

@unittest.skipUnless(HOOK, 'Native helper path not provided')
class NativeHookTests(unittest.TestCase):
    def run_hook(self, binary, source, payload, directory, event=None, env=None):
        cmd = ([sys.executable, str(binary)] if str(binary).endswith('.py') else [str(binary)]) + ['--source', source, '--directory', str(directory)]
        if event is not None:
            cmd += ['--event', event]
        return subprocess.run(cmd, input=payload, capture_output=True, timeout=3, env=env)

    def test_matches_existing_recorder_without_python_runtime(self):
        cases = [
            ('codex', None, {'hook_event_name': 'PermissionRequest', 'session_id': 's', 'turn_id': 't', 'tool_input': {'command': '  echo hello  '}, 'prompt': 'PRIVATE'}),
            ('antigravity', 'PostToolUse', {'conversationId': 's', 'toolCall': {'name': 'ask_question'}}),
            ('antigravity', 'Stop', {'conversationId': 's', 'terminationReason': 'model_stop', 'fullyIdle': False, 'error': ''}),
            ('antigravity', 'Stop', {'conversationId': 's', 'terminationReason': 'ERROR', 'fullyIdle': True, 'error': ''}),
            ('antigravity', 'Stop', {'conversationId': 's', 'terminationReason': 'NO_TOOL_CALL', 'fullyIdle': 1, 'error': ''}),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for i, (source, event, payload) in enumerate(cases):
                original, native = root / f'original-{i}', root / f'native-{i}'
                input_data = json.dumps(payload).encode()
                expected = self.run_hook(ROOT / 'scripts/record_hook.py', source, input_data, original, event)
                env = dict(os.environ); env.update(PATH='/nonexistent', PYTHONHOME='/nonexistent', PYTHONPATH='/nonexistent')
                actual = self.run_hook(HOOK, source, input_data, native, event, env)
                self.assertEqual(actual.returncode, 0)
                self.assertEqual(actual.stdout, expected.stdout)
                old = json.loads((original / f'{source}.jsonl').read_text())
                new = json.loads((native / f'{source}.jsonl').read_text())
                old.pop('received_at'); new.pop('received_at')
                self.assertEqual(new, old)
                self.assertNotIn('PRIVATE', json.dumps(new))

    def test_malformed_and_oversized_input_fail_neutrally(self):
        with tempfile.TemporaryDirectory() as directory:
            for payload in [b'{', b'x' * (1024 * 1024 + 1)]:
                result = self.run_hook(HOOK, 'codex', payload, directory)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'{}\n')
                self.assertFalse((Path(directory) / 'codex.jsonl').exists())
            stop = self.run_hook(HOOK, 'antigravity', b'bad json', directory, 'Stop')
            self.assertEqual(stop.returncode, 0)
            self.assertEqual(stop.stdout, b'{"decision":"stop"}\n')

    def test_refuses_symlink_and_preserves_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / 'target'; target.write_text('keep')
            (root / 'codex.jsonl').symlink_to(target)
            result = self.run_hook(HOOK, 'codex', b'{"hook_event_name":"Stop","session_id":"s"}', root)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'{}\n')
            self.assertEqual(target.read_text(), 'keep')

    def test_concurrent_events_remain_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            cmd = [HOOK, '--source', 'codex', '--directory', directory]
            processes = [subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(8)]
            for i, process in enumerate(processes):
                output, _ = process.communicate(json.dumps({'hook_event_name': 'Stop', 'session_id': str(i)}).encode(), timeout=3)
                self.assertEqual(output, b'{}\n'); self.assertEqual(process.returncode, 0)
            records = [json.loads(line) for line in (Path(directory) / 'codex.jsonl').read_text().splitlines()]
            self.assertEqual({record['session_id'] for record in records}, {str(i) for i in range(8)})

    def test_native_installer_preserves_custom_hooks_and_prior_backups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "with space's"; root.mkdir()
            config = root / 'hooks.json'; recorder = root / 'AgentIsland' / 'hooks'
            old = '/usr/bin/python3 /tmp/AiKeyboardLight/scripts/record_hook.py --source antigravity --event Stop'
            config.write_text(json.dumps({'aikeyboardlight': {'Stop': [{'command': old}, {'command': 'echo keep'}]}, 'other': {'enabled': True}}))
            command = [HOOK, '--install', '--source', 'antigravity', '--output', str(config), '--recorder-dir', str(recorder)]
            env = dict(os.environ); env.update(PATH='/nonexistent', PYTHONHOME='/nonexistent', PYTHONPATH='/nonexistent')
            subprocess.run(command, check=True, capture_output=True, env=env)
            first = json.loads(config.read_text())
            self.assertEqual(first['aikeyboardlight']['Stop'], [{'command': 'echo keep'}])
            self.assertEqual(first['other'], {'enabled': True})
            subprocess.run(command, check=True, capture_output=True, env=env)
            self.assertEqual(json.loads(config.read_text()), first)
            self.assertEqual(len(list(root.glob('hooks.json.agentisland-backup-*'))), 2)
            installed_command = first['agentisland']['Stop'][0]['command']
            import shlex
            helper = Path(shlex.split(installed_command)[0])
            self.assertTrue(helper.is_file()); self.assertTrue(os.access(helper, os.X_OK))
            self.assertNotIn('python', installed_command.lower())

    def test_native_installer_refuses_symlink_and_invalid_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); real = root / 'real'; real.write_text('{broken')
            link = root / 'hooks.json'; link.symlink_to(real)
            command = [HOOK, '--install', '--source', 'codex', '--output', str(link), '--recorder-dir', str(root / 'AgentIsland/hooks')]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(real.read_text(), '{broken')
            command[command.index(str(link))] = str(real)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(real.read_text(), '{broken')

    def test_concurrent_installers_preserve_both_registrations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'hooks.json'
            config.write_text(json.dumps({'existing': {'preserve': True}}))
            common = ['--install', '--output', str(config), '--recorder-dir', str(root / 'AgentIsland/hooks')]
            processes = [subprocess.Popen([HOOK, *common, '--source', source], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                         for source in ['codex', 'antigravity'] * 6]
            for process in processes:
                _, stderr = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 0, stderr.decode())
            result = json.loads(config.read_text())
            self.assertEqual(result['existing'], {'preserve': True})
            self.assertEqual(len(result['hooks']['Stop']), 1)
            self.assertEqual(len(result['agentisland']['Stop']), 1)

    def test_installer_refuses_symlinked_lock_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'hooks.json'; config.write_text('{}')
            target = root / 'unrelated'; target.write_text('untouched')
            digest = hashlib.sha256(config.name.encode()).hexdigest()
            (root / ('.agentisland-lock-' + digest)).symlink_to(target)
            result = subprocess.run([HOOK, '--install', '--source', 'codex', '--output', str(config),
                                     '--recorder-dir', str(root / 'AgentIsland/hooks')], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), 'untouched')
            self.assertEqual(config.read_text(), '{}')

    def test_codex_installer_only_replaces_exact_own_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'hooks.json'
            previous = '/usr/bin/python3 /tmp/AiKeyboardLight/scripts/record_hook.py --source codex'
            custom = previous + ' --extra-user-flag'
            original = {'hooks': {'Stop': [{'hooks': [{'command': previous}, {'command': custom}, {'command': 'echo keep'}]}]}}
            config.write_text(json.dumps(original))
            args = [HOOK, '--install', '--source', 'codex', '--output', str(config), '--recorder-dir', str(root / 'AgentIsland/hooks')]
            subprocess.run(args, check=True, capture_output=True)
            after = json.loads(config.read_text())
            self.assertEqual([h['command'] for h in after['hooks']['Stop'][0]['hooks']], [custom, 'echo keep'])
            self.assertNotIn('/usr/bin/python3', after['hooks']['Stop'][1]['hooks'][0]['command'])
            subprocess.run(args, check=True, capture_output=True)
            self.assertEqual(json.loads(config.read_text()), after)
            self.assertEqual(len(list(root.glob('hooks.json.agentisland-backup-*'))), 2)

    def test_uninstall_removes_only_own_hook_and_keeps_backups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'hooks.json'
            original = {'hooks': {'Stop': [{'hooks': [{'command': 'echo user'}]}, {'hooks': [], 'custom': 'retain'}]}, 'metadata': 'keep'}
            config.write_text(json.dumps(original))
            args = ['--source', 'codex', '--output', str(config)]
            subprocess.run([HOOK, '--install', *args, '--recorder-dir', str(root / 'AgentIsland/hooks')], check=True, capture_output=True)
            subprocess.run([HOOK, '--uninstall', *args], check=True, capture_output=True)
            after = json.loads(config.read_text())
            self.assertEqual(after['hooks']['Stop'], original['hooks']['Stop'])
            self.assertEqual(after['metadata'], 'keep')
            self.assertEqual(len(list(root.glob('hooks.json.agentisland-backup-*'))), 2)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            for backup in root.glob('hooks.json.agentisland-backup-*'):
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            subprocess.run([HOOK, '--uninstall', *args], check=True, capture_output=True)
            self.assertEqual(len(list(root.glob('hooks.json.agentisland-backup-*'))), 2)
