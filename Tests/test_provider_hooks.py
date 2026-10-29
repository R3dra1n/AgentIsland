import importlib.util,json,pathlib,sys,tempfile,unittest
sys.path.insert(0,str(pathlib.Path(__file__).parents[1]/'scripts'))
from provider_hook import record
from install_provider_hooks import install
class ProviderTests(unittest.TestCase):
    def test_late_stop_cannot_clear_new_generation(self):
        with tempfile.TemporaryDirectory() as d:
            record('cursor','beforeSubmitPrompt',{'conversation_id':'a','generation_id':'new'},d)
            record('cursor','stop',{'conversation_id':'a','generation_id':'old'},d)
            state=json.loads(next((pathlib.Path(d)/'cursor').glob('*.json')).read_text())
            self.assertEqual(state['state'],'running')
    def test_anonymous_event_not_merged(self):
        with tempfile.TemporaryDirectory() as d:
            record('windsurf','pre_user_prompt',{},d)
            self.assertEqual(list(pathlib.Path(d).iterdir()),[])
    def test_install_preserves_foreign_hooks_and_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'.cursor/hooks.json';p.parent.mkdir();p.write_text(json.dumps({'hooks':{'stop':[{'command':'custom'}]}}))
            install(d,['cursor'],True);first=p.read_text();install(d,['cursor'],True)
            self.assertEqual(first,p.read_text())
            self.assertEqual(json.loads(first)['hooks']['stop'][0]['command'],'custom')
