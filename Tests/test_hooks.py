import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
record = load('record_hook'); config = load('configure_hooks')

class HookTests(unittest.TestCase):
    def test_installed_codex_hook_survives_source_move_and_quotes_spaces(self):
        with tempfile.TemporaryDirectory() as directory:
            target = config.install_recorder(Path(directory) / 'Application Support' / 'hooks')
            old = config.configuration('codex', Path('/tmp/AgentIsland/scripts/record_hook.py'))
            updated = config.merge(old, 'codex', target)
            self.assertEqual(len(updated['hooks']['Stop']), 1)
            command = updated['hooks']['Stop'][0]['hooks'][0]['command']
            import shlex
            self.assertEqual(shlex.split(command)[1], str(target))
            result = subprocess.run(['/usr/bin/python3', str(target), '--source', 'codex'], input=b'bad json', capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), b'{}')
            self.assertEqual(config.merge(updated, 'codex', target), updated)

    def test_privacy_allowlist(self):
        value = record.normalize({'hook_event_name':'PermissionRequest','session_id':'s','turn_id':'t','prompt':'secret','tool_input':{'command':'secret'}},'codex')
        self.assertNotIn('secret',json.dumps(value))
        self.assertEqual(value['hook_event_name'],'PermissionRequest')
    def test_command_fingerprint_does_not_store_command(self):
        import hashlib
        value = record.normalize({'hook_event_name':'PermissionRequest', 'session_id':'s', 'tool_input':{'command':'echo  hello'}}, 'codex')
        self.assertEqual(value['command_digest'], hashlib.sha256(b'echo  hello').hexdigest())
        self.assertNotIn('echo', json.dumps(value))

    def test_antigravity_stop_metadata(self):
        value=record.normalize({'conversationId':'s','terminationReason':'model_stop','fullyIdle':False,'error':''},'antigravity','Stop')
        self.assertFalse(value['fully_idle']); self.assertEqual(value['termination_reason'],'model_stop')
        value=record.normalize({'conversationId':'s','terminationReason':'ERROR','fullyIdle':True,'error':''},'antigravity','Stop')
        self.assertEqual(value['termination_reason'], 'error')
    def test_merge_preserves_other_hooks_and_is_idempotent(self):
        existing={'description':'mine','hooks':{'Stop':[{'hooks':[{'type':'command','command':'echo mine'}]}]}}
        merged=config.merge(existing,'codex')
        self.assertEqual(config.merge(merged,'codex'),merged)
        self.assertEqual(merged['hooks']['Stop'][0]['hooks'][0]['command'],'echo mine')
    def test_antigravity_never_installs_permission_gates(self):
        self.assertNotIn('PreToolUse',config.configuration('antigravity')['agentisland'])
    def test_antigravity_migration_preserves_custom_handlers(self):
        previous = config.configuration('antigravity', Path('/tmp/AiKeyboardLight/scripts/record_hook.py'))['agentisland']
        previous['Stop'].append({'type': 'command', 'command': 'echo custom'})
        previous['custom_metadata'] = {'kept': True}
        existing = {'aikeyboardlight': previous, 'agentisland': {'Stop': [{'command': 'echo other'}]}}
        target = Path('/tmp/AgentIsland/hooks/record_hook.py')
        merged = config.merge(existing, 'antigravity', target)
        self.assertEqual(merged['aikeyboardlight']['custom_metadata'], {'kept': True})
        self.assertEqual(merged['aikeyboardlight']['Stop'], [{'type': 'command', 'command': 'echo custom'}])
        self.assertEqual(merged['agentisland']['Stop'][0], {'command': 'echo other'})
        self.assertEqual(config.merge(merged, 'antigravity', target), merged)

    def test_isolated_installs_preserve_each_prior_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / 'hooks.json'
            recorder = root / 'Application Support' / 'AgentIsland' / 'hooks'
            config_path.write_text(json.dumps({'marker': 'first'}))
            command = ['/usr/bin/python3', str(ROOT / 'scripts/configure_hooks.py'),
                       '--source', 'antigravity', '--output', str(config_path), '--recorder-dir', str(recorder)]
            subprocess.run(command, check=True, capture_output=True)
            changed = json.loads(config_path.read_text()); changed['marker'] = 'second'
            config_path.write_text(json.dumps(changed))
            subprocess.run(command, check=True, capture_output=True)
            backups = list(root.glob('hooks.json.agentisland-backup-*'))
            self.assertEqual(len(backups), 2)
            self.assertEqual({json.loads(p.read_text())['marker'] for p in backups}, {'first', 'second'})
            self.assertEqual(json.loads(config_path.read_text())['marker'], 'second')
            self.assertTrue((recorder / 'record_hook.py').is_file())

    @unittest.skipUnless(os.environ.get('AGENTISLAND_TEST_HOOK'), 'Native helper path not provided')
    def test_native_hook_migrates_and_preserves_other_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            recorder = Path(directory) / 'AgentIsland' / 'hooks'
            helper = config.install_recorder(recorder, native_helper=Path(os.environ['AGENTISLAND_TEST_HOOK']))
            old = config.configuration('antigravity', Path('/tmp/AiKeyboardLight/scripts/record_hook.py'))
            old['agentisland']['Stop'].append({'command': 'echo user-hook'})
            migrated = config.merge(old, 'antigravity', helper, native=True)
            self.assertEqual(migrated['agentisland']['Stop'][0]['command'], 'echo user-hook')
            self.assertEqual(config.merge(migrated, 'antigravity', helper, native=True), migrated)
            command = migrated['agentisland']['PostToolUse'][0]['hooks'][0]['command']
            import shlex
            self.assertEqual(shlex.split(command)[0], str(helper))
            self.assertNotIn('/usr/bin/python3', command)
            self.assertTrue(os.access(helper, os.X_OK))
    def test_concurrent_journal_has_complete_records_and_neutral_output(self):
        with tempfile.TemporaryDirectory() as directory:
            children=[]
            for i in range(12):
                child=subprocess.Popen(['/usr/bin/python3',str(ROOT/'scripts/record_hook.py'),'--source','codex','--directory',directory],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                child.stdin.write(json.dumps({'hook_event_name':'PermissionRequest','session_id':str(i),'turn_id':'t','prompt':'secret'}).encode()); child.stdin.close(); children.append(child)
            for child in children:
                self.assertEqual(child.wait(),0); self.assertEqual(child.stdout.read().strip(),b'{}'); child.stdout.close(); child.stderr.close()
            lines=(Path(directory)/'codex.jsonl').read_text().splitlines()
            self.assertEqual(len(lines),12)
            self.assertEqual(len({json.loads(line)['session_id'] for line in lines}),12)
            self.assertNotIn('secret',''.join(lines))
    def test_invalid_input_does_not_block_agent(self):
        result=subprocess.run(['/usr/bin/python3',str(ROOT/'scripts/record_hook.py'),'--source','codex'],input=b'bad json',capture_output=True)
        self.assertEqual(result.returncode,0); self.assertEqual(result.stdout.strip(),b'{}')

if __name__=='__main__': unittest.main()
