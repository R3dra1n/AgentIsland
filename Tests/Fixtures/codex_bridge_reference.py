#!/usr/bin/env python3
"""Versioned, same-user Codex Desktop IPC adapter. Never injects UI input."""
import json, os, signal, socket, stat, struct, sys, time, uuid

class Bridge:
    def __init__(self, thread):
        path = os.path.join(os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex')), 'ipc/ipc.sock')
        metadata = os.lstat(path)
        parent = os.stat(os.path.dirname(path))
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid() or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            raise ValueError('Untrusted Codex socket')
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(3)
        self.sock.connect(path)
        self.client = 'initializing-client'
        self.thread = thread
        self.owner = None
        self.state = None
        result = self.request('initialize', {'clientType': 'agent-island'}, 0)
        self.client = result['clientId']
        self.send(dict(type='broadcast', sourceClientId=self.client, version=1,
                       method='thread-stream-following-changed', params=dict(conversationId=thread, hostId='local', following=True)))
        deadline = time.monotonic() + 4
        while self.state is None and time.monotonic() < deadline:
            self.receive()
        if self.state is None:
            raise ValueError('Codex 未提供任务快照，请先在 Codex 中打开该任务')

    def send(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.sock.sendall(struct.pack('<I', len(body)) + body)

    def exact(self, length):
        data = bytearray()
        while len(data) < length:
            chunk = self.sock.recv(length - len(data))
            if not chunk:
                raise ConnectionError('Codex connection closed')
            data.extend(chunk)
        return bytes(data)

    def receive(self):
        length, = struct.unpack('<I', self.exact(4))
        if length > 32 * 1024 * 1024:
            raise ValueError('Codex frame too large')
        obj = json.loads(self.exact(length))
        if obj.get('type') == 'client-discovery-request':
            self.send(dict(type='client-discovery-response', requestId=obj['requestId'], response=dict(canHandle=False)))
        if obj.get('method') == 'thread-stream-state-changed':
            p = obj.get('params', {})
            change = p.get('change', {})
            if p.get('conversationId') == self.thread and p.get('hostId', 'local') == 'local' and change.get('type') == 'snapshot':
                self.state = change['conversationState']
                self.owner = obj.get('sourceClientId')
        return obj

    def request(self, method, params, version=1):
        request_id = str(uuid.uuid4())
        msg = dict(type='request', requestId=request_id, sourceClientId=self.client,
                   method=method, params=params, version=version, timeoutMs=4000)
        if self.owner:
            msg['targetClientId'] = self.owner
        self.send(msg)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            obj = self.receive()
            if obj.get('type') == 'response' and obj.get('requestId') == request_id:
                if obj.get('resultType') != 'success':
                    raise ValueError(obj.get('error', 'Codex rejected response'))
                return obj.get('result', {})
        raise TimeoutError('Codex response timeout')


def items_in(state, active_only=False):
    """Read only turn items, never parse quoted JSON in message text."""
    turns = state.get('turns', [])
    history = state.get('turnHistory', {})
    if history.get('kind') == 'canonical':
        turns = list(history.get('history', {}).get('entitiesByKey', {}).values())
    items = []
    for turn in turns:
        if active_only and turn.get('status') != 'inProgress': continue
        items.extend(turn.get('items', []))
    return items


def pending(state):
    out = []
    for req in state.get('requests', []):
        method, p = req.get('method'), req.get('params', {})
        if method not in ('item/tool/requestUserInput', 'item/commandExecution/requestApproval', 'item/fileChange/requestApproval'):
            continue
        if method == 'item/commandExecution/requestApproval' and p.get('availableDecisions') is not None:
            if not all(d in p['availableDecisions'] for d in ('accept', 'decline')): continue
        questions = p.get('questions', []) if method == 'item/tool/requestUserInput' else []
        out.append(dict(requestID=str(req['id']), rawID=req['id'], method=method,
                        context=p.get('reason') or str(p.get('command', 'Codex 请求确认')),
                        questions=[dict(id=q['id'], title=q['question'], options=[o['label'] for o in q.get('options') or []]) for q in questions]))
    items = items_in(state)
    answered = set()
    for item in items:
        if item.get('type') not in ('userMessage', 'steeringUserMessage'):
            continue
        if item.get('type') == 'steeringUserMessage' and item.get('status') != 'accepted':
            continue
        content = item.get('content', item.get('input', []))
        if len(content) != 1 or content[0].get('type') != 'text':
            continue
        text = content[0].get('text', '').strip()
        prefix, suffix = '<send_user_message_question_reply>', '</send_user_message_question_reply>'
        if text.startswith(prefix) and text.endswith(suffix):
            try:
                replies = json.loads(text[len(prefix):-len(suffix)])
                if isinstance(replies, dict): replies = [replies]
                answered.update(r['questionItemId'] for r in replies)
            except (ValueError, KeyError, TypeError): pass
    # Only an accepted, identity-matched answer resolves a question. A pending
    # steer or unrelated user message must not clear other unanswered questions.
    for item in items_in(state, active_only=True):
        if item.get('type') != 'agentMessage' or item.get('delivery') != 'async':
            continue
        questions = item.get('questions')
        if not questions:
            continue  # Ordinary async messages are not interactive requests.
        for index, q in enumerate(questions):
            qid = json.dumps(['request_user_input_async', item['id'], index], separators=(',', ':'), ensure_ascii=False)
            if qid in answered: continue
            out.append(dict(requestID=qid, rawID=qid, method='async-question', context=q['title'],
                            questions=[dict(id=qid, title=q['title'], options=q.get('options') or [])]))
    return out


def latest_turn(state):
    turns = state.get('turns', [])
    history = state.get('turnHistory', {})
    if history.get('kind') == 'canonical':
        turns = list(history.get('history', {}).get('entitiesByKey', {}).values())
    turns = [t for t in turns if t.get('turnId')]
    return max(turns, key=lambda t: t.get('turnStartedAtMs') or 0) if turns else {}


def execution_state(state):
    runtime = state.get('threadRuntimeStatus', {}).get('type')
    if runtime == 'active': return 'running'
    if runtime not in ('idle',): return 'unknown'
    latest = latest_turn(state)
    return {'completed':'completed', 'failed':'failed', 'interrupted':'interrupted'}.get(latest.get('status'), 'idle')


def run(command):
    bridge = Bridge(command['sessionID'])
    requests = pending(bridge.state)
    if command.get('action') == 'reply':
        matches = [r for r in requests if r['requestID'] == command['requestID']]
        if len(matches) != 1: raise ValueError('请求已过期或无法唯一识别')
        req = matches[0]
        params = dict(conversationId=bridge.thread, requestId=req['rawID'])
        method = req['method']
        if req['questions']:
            answers = command.get('answers', {})
            if set(answers) != {q['id'] for q in req['questions']} or any(not isinstance(a, str) or not a.strip() for a in answers.values()):
                raise ValueError('请回答全部问题')
            if method == 'async-question':
                replies = [dict(questionItemId=q['id'], question=q['title'], answer=answers[q['id']]) for q in req['questions']]
                text = '<send_user_message_question_reply>\n' + json.dumps(replies, ensure_ascii=False) + '\n</send_user_message_question_reply>'
                # Same follower route and structured input as the desktop question UI.
                method = 'thread-follower-steer-turn'
                client_id = str(uuid.uuid4())
                restore = dict(id=client_id, cwd=bridge.state.get('cwd'), context=dict(
                    prompt=text, turnTrigger='send_user_message_async_question',
                    addedFiles=[], fileAttachments=[], imageAttachments=[], commentAttachments=[], ideContext=None))
                params = dict(conversationId=bridge.thread, input=[dict(type='text', text=text, text_elements=[])],
                              clientUserMessageId=client_id, restoreMessage=restore)
            else:
                method = 'thread-follower-submit-user-input'
                params['response'] = dict(answers={k:dict(answers=[v]) for k,v in answers.items()})
        else:
            decision = command.get('decision')
            if decision not in ('accept','decline'): raise ValueError('Invalid decision')
            method = 'thread-follower-command-approval-decision' if method == 'item/commandExecution/requestApproval' else 'thread-follower-file-approval-decision'
            params['decision'] = decision
        bridge.request(method, params)
        return dict(ok=True, message='Codex 已接收操作；等待状态更新')
    latest = latest_turn(bridge.state)
    return dict(ok=True, requests=requests, runtime=bridge.state.get('threadRuntimeStatus', {}).get('type', 'unknown'),
                activity=execution_state(bridge.state), turnID=latest.get('turnId'), turnStartedAtMs=latest.get('turnStartedAtMs'))

if __name__ == '__main__':
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('Codex 通信超时，请重试或在原应用处理')))
    signal.alarm(12)
    try:
        print(json.dumps(run(json.load(sys.stdin)), ensure_ascii=False))
    except Exception as exc:
        print(json.dumps(dict(ok=False, error=str(exc)), ensure_ascii=False))
        sys.exit(1)
