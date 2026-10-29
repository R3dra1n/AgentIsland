import importlib.util, json, pathlib, socket, struct, sys, unittest
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('bridge',pathlib.Path(__file__).parents[1]/'Tests/Fixtures/codex_bridge_reference.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class CodexBridgeTests(unittest.TestCase):
    def state(self, items, status='inProgress'):
        return {'requests':[], 'turnHistory':{'kind':'canonical','history':{'entitiesByKey':{'turn:1':{'status':status,'items':items}}}}}
    def question(self):
        return {'type':'agentMessage','id':'call-real','delivery':'async','questions':[{'title':'选择？','options':['A','B']}]}
    def test_real_async_identity_and_choices(self):
        r=b.pending(self.state([self.question()]))[0]
        self.assertEqual(r['requestID'],'["request_user_input_async","call-real",0]')
        self.assertEqual(r['questions'][0]['options'],['A','B'])
    def test_unrelated_tool_does_not_clear(self):
        self.assertEqual(len(b.pending(self.state([self.question(),{'type':'commandExecution','status':'completed'}]))),1)
    def test_accepted_reply_clears_only_matching_question(self):
        qid=b.pending(self.state([self.question()]))[0]['requestID']
        text='<send_user_message_question_reply>\n'+json.dumps([{'questionItemId':qid,'question':'选择？','answer':'A'}])+'\n</send_user_message_question_reply>'
        reply={'type':'steeringUserMessage','status':'pending','input':[{'type':'text','text':text}]}
        self.assertEqual(len(b.pending(self.state([self.question(),reply]))),1)
        reply['status']='accepted'
        self.assertEqual(b.pending(self.state([self.question(),reply])),[])
    def test_completed_turn_not_actionable(self):
        self.assertEqual(b.pending(self.state([self.question()],'completed')),[])
    def test_ordinary_async_message_is_not_question(self):
        self.assertEqual(b.pending(self.state([{'type':'agentMessage','id':'notice','delivery':'async','text':'Working'}])), [])
    def test_unrelated_user_message_preserves_question(self):
        self.assertEqual(len(b.pending(self.state([self.question(), {'type':'userMessage','content':[{'type':'text','text':'Continue'}]}]))), 1)
    def test_answer_to_one_question_preserves_other(self):
        one, two = self.question(), self.question()
        two['id'] = 'second-call'
        qid=b.pending(self.state([one]))[0]['requestID']
        text='<send_user_message_question_reply>'+json.dumps([{'questionItemId':qid,'question':'Pick','answer':'A'}])+'</send_user_message_question_reply>'
        reply={'type':'steeringUserMessage','status':'accepted','input':[{'type':'text','text':text}]}
        pending=b.pending(self.state([one,two,reply]))
        self.assertEqual(len(pending),1)
        self.assertIn('second-call',pending[0]['requestID'])
    def test_numeric_server_id_preserved(self):
        r=b.pending({'requests':[{'id':42,'method':'item/commandExecution/requestApproval','params':{'command':'echo test'}}]})[0]
        self.assertEqual(r['rawID'],42)
    def test_fragmented_frame(self):
        left,right=socket.socketpair()
        try:
            client=b.Bridge.__new__(b.Bridge);client.sock=left;client.thread='x'
            payload=json.dumps({'type':'response','requestId':'r'}).encode()
            for byte in struct.pack('<I',len(payload))+payload:right.sendall(bytes([byte]))
            self.assertEqual(client.receive()['requestId'],'r')
        finally:left.close();right.close()
    def test_oversized_frame_rejected(self):
        left,right=socket.socketpair()
        try:
            client=b.Bridge.__new__(b.Bridge);client.sock=left;right.sendall(struct.pack('<I',40*1024*1024))
            with self.assertRaises(ValueError):client.receive()
        finally:left.close();right.close()

class CodexResponseTests(unittest.TestCase):
    def test_async_reply_uses_follower_steer_and_actual_question_id(self):
        from unittest.mock import patch
        state={'turns':[{'status':'inProgress','items':[{'type':'agentMessage','delivery':'async','id':'actual-call','questions':[{'title':'Pick','options':['A','B']}]}]}]}
        request=b.pending(state)[0]
        class FakeBridge:
            def __init__(self, thread): self.thread=thread; self.state=state
            def request(self,method,params):
                self.sent=(method,params); sent.append(self.sent);return {'ok':True}
        sent=[]
        with patch.object(b,'Bridge',FakeBridge):
            result=b.run({'action':'reply','sessionID':'thread','requestID':request['requestID'],'answers':{request['requestID']:'B'}})
        self.assertTrue(result['ok']);self.assertEqual(sent[0][0],'thread-follower-steer-turn')
        self.assertIn('actual-call',sent[0][1]['input'][0]['text'])
        self.assertIn('cwd',sent[0][1]['restoreMessage'])
        self.assertEqual(sent[0][1]['restoreMessage']['context']['commentAttachments'], [])
        self.assertIn('"answer": "B"',sent[0][1]['input'][0]['text'])
    def test_stale_request_sends_nothing(self):
        from unittest.mock import patch
        class FakeBridge:
            def __init__(self, thread):self.thread=thread;self.state={'requests':[]}
            def request(self,*args):raise AssertionError('must not send')
        with patch.object(b,'Bridge',FakeBridge):
            with self.assertRaises(ValueError):b.run({'action':'reply','sessionID':'thread','requestID':'stale','answers':{}})

class CodexExecutionStateTests(unittest.TestCase):
    def test_running_without_pending_requests(self):
        state={'requests':[], 'threadRuntimeStatus':{'type':'active'}}
        self.assertEqual(b.pending(state),[])
        self.assertEqual(b.execution_state(state),'running')
    def test_unloaded_is_unknown_not_idle(self):
        self.assertEqual(b.execution_state({'threadRuntimeStatus':{'type':'notLoaded'}}),'unknown')
    def test_idle_preserves_latest_turn_failure(self):
        state={'threadRuntimeStatus':{'type':'idle'},'turns':[
            {'turnId':'old','turnStartedAtMs':1,'status':'completed'},
            {'turnId':'new','turnStartedAtMs':2,'status':'failed'}]}
        self.assertEqual(b.execution_state(state),'failed')

    def test_new_completion_supersedes_old_failure_in_canonical_history(self):
        from unittest.mock import patch
        state = {'threadRuntimeStatus': {'type': 'idle'}, 'turnHistory': {'kind': 'canonical', 'history': {'entitiesByKey': {
            'new': {'turnId': 'new', 'turnStartedAtMs': 2000, 'status': 'completed'},
            'old': {'turnId': 'old', 'turnStartedAtMs': 1000, 'status': 'failed'}
        }}}}
        self.assertEqual(b.execution_state(state), 'completed')
        self.assertEqual(b.latest_turn(state)['turnId'], 'new')
        with patch.object(b, 'Bridge') as bridge:
            bridge.return_value.state = state
            reply = b.run({'sessionID': 'session'})
        self.assertEqual(reply['turnStartedAtMs'], 2000)
        self.assertEqual(reply['turnID'], 'new')
