"""The helper that lets the island answer Claude Code's multiple-choice question.

Runs the real native helper. The contract under test: it prints an answer only
when the island is running and a response names one of the offered options;
every other path prints `{}`, which hands the question back to Claude's own dialog.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

HOOK = os.environ.get('AGENTISLAND_TEST_HOOK')

QUESTION = {
    'question': 'Which framework?', 'header': 'Framework', 'multiSelect': False,
    'options': [{'label': 'React', 'description': 'Component library'}, {'label': 'Vue', 'description': 'Progressive'}],
}


def payload(questions=None, tool='AskUserQuestion', tool_use_id='toolu_01ABC'):
    return {'hook_event_name': 'PreToolUse', 'session_id': 'session-1', 'tool_use_id': tool_use_id, 'tool_name': tool,
            'tool_input': {'questions': questions if questions is not None else [QUESTION]}}


@unittest.skipUnless(HOOK, 'Native helper path not provided')
class AnswerQuestionsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name) / 'answers'
        self.dir.mkdir(mode=0o700)
        os.chmod(self.dir, 0o700)

    def island_running(self, age=0):
        ready = self.dir / 'ready'
        ready.write_text('')
        if age:
            past = time.time() - age
            os.utime(ready, (past, past))

    def command(self, wait, source='claude'):
        return [HOOK, '--source', source, '--answer-questions', '--answers-directory', str(self.dir), '--wait', str(wait)]

    def run_hook(self, data, wait=1, source='claude'):
        started = time.monotonic()
        result = subprocess.run(self.command(wait, source), input=json.dumps(data).encode(), capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        return result.stdout, time.monotonic() - started

    def respond(self, text, mode=0o600, name='toolu_01ABC'):
        responses = self.dir / 'responses'
        deadline = time.time() + 5
        while not (self.dir / 'requests' / (name + '.json')).exists() and time.time() < deadline:
            time.sleep(0.02)
        responses.mkdir(exist_ok=True, mode=0o700)
        target = responses / (name + '.json')
        target.write_text(text)
        os.chmod(target, mode)

    def ask(self, wait, answer, mode=0o600):
        """Run the helper while a thread of this test plays the island."""
        import threading
        thread = threading.Thread(target=lambda: self.respond(answer, mode))
        thread.start()
        out = self.run_hook(payload(), wait=wait)
        thread.join()
        return out

    # --- answering ---------------------------------------------------------

    def test_a_chosen_option_becomes_the_answer(self):
        self.island_running()
        (out, elapsed) = self.ask(8, json.dumps({'label': 'Vue'}))
        expected = {'hookSpecificOutput': {
            'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'permissionDecisionReason': 'Answered from AgentIsland',
            'updatedInput': {'questions': [QUESTION], 'answers': {'Which framework?': 'Vue'}}}}
        self.assertEqual(json.loads(out), expected)
        self.assertLess(elapsed, 4, 'it must not wait out the whole window once answered')
        self.assertEqual(list((self.dir / 'requests').iterdir()), [], 'the request is cleaned up')
        self.assertEqual(list((self.dir / 'responses').iterdir()), [], 'the response is cleaned up')

    def test_the_request_tells_the_island_what_was_asked(self):
        self.island_running()
        import threading
        seen = {}
        def play():
            path = self.dir / 'requests' / 'toolu_01ABC.json'
            deadline = time.time() + 5
            while not path.exists() and time.time() < deadline: time.sleep(0.02)
            seen['mode'] = path.stat().st_mode & 0o777
            seen['body'] = json.loads(path.read_text())
        t = threading.Thread(target=play); t.start()
        self.run_hook(payload(), wait=1); t.join()
        self.assertEqual(seen['mode'], 0o600)
        self.assertEqual(seen['body']['session_id'], 'session-1')
        self.assertEqual(seen['body']['question'], 'Which framework?')
        self.assertEqual([o['label'] for o in seen['body']['options']], ['React', 'Vue'])

    # --- nothing to wait for: decline at once ------------------------------

    def test_without_the_island_running_it_declines_at_once(self):
        out, elapsed = self.run_hook(payload(), wait=10)
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 2)
        self.assertFalse((self.dir / 'requests').exists() and any((self.dir / 'requests').iterdir()))

    def test_a_stale_heartbeat_counts_as_not_running(self):
        self.island_running(age=60)
        out, elapsed = self.run_hook(payload(), wait=10)
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 2)

    def test_several_questions_are_left_to_claude(self):
        self.island_running()
        out, elapsed = self.run_hook(payload([QUESTION, dict(QUESTION, question='Which bundler?')]), wait=10)
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 2)

    def test_a_multi_select_question_is_left_to_claude(self):
        self.island_running()
        out, elapsed = self.run_hook(payload([dict(QUESTION, multiSelect=True)]), wait=10)
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 2)

    def test_other_tools_and_other_sources_are_left_alone(self):
        self.island_running()
        self.assertEqual(json.loads(self.run_hook(payload(tool='Bash'), wait=10)[0]), {})
        self.assertEqual(json.loads(self.run_hook(payload(), wait=10, source='codex')[0]), {})

    def test_malformed_input_declines(self):
        self.island_running()
        result = subprocess.run(self.command(1), input=b'not json', capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})

    # --- a response that must not be trusted -------------------------------

    def test_no_response_in_time_declines_and_cleans_up(self):
        self.island_running()
        out, elapsed = self.run_hook(payload(), wait=1)
        self.assertEqual(json.loads(out), {})
        self.assertGreaterEqual(elapsed, 1)
        self.assertEqual(list((self.dir / 'requests').iterdir()), [])

    def test_a_label_that_was_not_offered_is_ignored(self):
        self.island_running()
        out, _ = self.ask(1.5, json.dumps({'label': 'Angular'}))
        self.assertEqual(json.loads(out), {})

    def test_the_label_must_match_exactly(self):
        self.island_running()
        out, _ = self.ask(1.5, json.dumps({'label': 'react'}))
        self.assertEqual(json.loads(out), {})

    def test_a_response_others_can_write_is_ignored(self):
        self.island_running()
        out, _ = self.ask(1.5, json.dumps({'label': 'Vue'}), mode=0o666)
        self.assertEqual(json.loads(out), {}, 'a file anyone can write is not proof the user clicked')

    def test_a_response_that_is_not_json_is_ignored(self):
        self.island_running()
        out, _ = self.ask(1.5, 'Vue')
        self.assertEqual(json.loads(out), {})

    def test_a_symlinked_response_is_ignored(self):
        self.island_running()
        import threading
        target = Path(self._tmp.name) / 'elsewhere.json'
        target.write_text(json.dumps({'label': 'Vue'})); os.chmod(target, 0o600)
        def play():
            deadline = time.time() + 5
            while not (self.dir / 'requests' / 'toolu_01ABC.json').exists() and time.time() < deadline: time.sleep(0.02)
            (self.dir / 'responses').mkdir(exist_ok=True, mode=0o700)
            os.symlink(target, self.dir / 'responses' / 'toolu_01ABC.json')
        t = threading.Thread(target=play); t.start()
        out, _ = self.run_hook(payload(), wait=1.5); t.join()
        self.assertEqual(json.loads(out), {})

    def test_an_unsafe_directory_declines(self):
        self.island_running()
        os.chmod(self.dir, 0o777)
        out, elapsed = self.run_hook(payload(), wait=10)
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 2)

    def test_a_tool_use_id_cannot_name_a_path_outside_the_directory(self):
        self.island_running()
        out, _ = self.run_hook(payload(tool_use_id='../../escape'), wait=1)
        self.assertEqual(json.loads(out), {})
        self.assertFalse((Path(self._tmp.name) / 'escape.json').exists())
        self.assertFalse((self.dir.parent / 'escape.json').exists())

    def test_the_island_quitting_while_it_waits_hands_back_at_once(self):
        self.island_running()
        import threading
        def quit_island():
            deadline = time.time() + 5
            while not (self.dir / 'requests' / 'toolu_01ABC.json').exists() and time.time() < deadline: time.sleep(0.02)
            (self.dir / 'ready').unlink()
        t = threading.Thread(target=quit_island); t.start()
        out, elapsed = self.run_hook(payload(), wait=15); t.join()
        self.assertEqual(json.loads(out), {})
        self.assertLess(elapsed, 4)


@unittest.skipUnless(HOOK, 'Native helper path not provided')
class AnswerHookRegistrationTests(unittest.TestCase):
    def run_install(self, settings, flag):
        return subprocess.run([HOOK, '--source', 'claude', flag, '--output', str(settings), '--recorder-dir', str(settings.parent / 'AgentIsland' / 'hooks')],
                              capture_output=True, timeout=20)

    def test_install_adds_a_separate_longer_registration_and_uninstall_removes_it(self):
        with tempfile.TemporaryDirectory() as d:
            settings = Path(d) / 'settings.json'
            other = {'hooks': {'PreToolUse': [{'hooks': [{'type': 'command', 'command': '/usr/local/bin/other'}]}]}, 'model': 'x'}
            settings.write_text(json.dumps(other))
            self.assertEqual(self.run_install(settings, '--install').returncode, 0)
            installed = json.loads(settings.read_text())
            groups = installed['hooks']['PreToolUse']
            answering = [g for g in groups if g.get('matcher') == 'AskUserQuestion']
            self.assertEqual(len(answering), 1)
            command = answering[0]['hooks'][0]
            self.assertIn('--answer-questions', command['command'])
            self.assertEqual(command['timeout'], 30)
            recorders = [h for g in groups if g.get('matcher') is None for h in g['hooks'] if '--event PreToolUse' in h.get('command', '')]
            self.assertEqual([h['timeout'] for h in recorders], [1], 'the recorder keeps its 1 second limit')
            self.assertIn({'hooks': [{'type': 'command', 'command': '/usr/local/bin/other'}]}, groups, 'others are untouched')

            self.assertEqual(self.run_install(settings, '--install').returncode, 0)   # again: replaced, not added
            self.assertEqual(len([g for g in json.loads(settings.read_text())['hooks']['PreToolUse'] if g.get('matcher') == 'AskUserQuestion']), 1)

            self.assertEqual(self.run_install(settings, '--uninstall').returncode, 0)
            self.assertEqual(json.loads(settings.read_text()), other, 'uninstall leaves exactly what was there before')


if __name__ == '__main__':
    unittest.main()
