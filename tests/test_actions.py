"""Plugin-owned exact-target boundary; no model calls or persistent chats."""
import asyncio
from types import SimpleNamespace as NS
from unittest.mock import Mock

import pytest
from agent import AgentContext, AgentContextType
from usr.plugins.a0_notch.helpers import actions, http
from test_m5 import app, client, HEADERS
from usr.plugins.a0_notch.helpers.incarnation import token

def bound(data):
    context = next((c for c in AgentContext.all() if c.id == data["context"]), None)
    return dict(data, incarnation=token(context) if context is not None else "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

PATH = '/api/plugins/a0_notch/action'


@pytest.fixture
def targets(monkeypatch):
    def make(id):
        ctx = NS(id=id, type=AgentContextType.USER, output_data={}, paused=False,
                 agent0=NS(enabled=True), communicate=Mock(), get_agent=lambda: None)
        return ctx
    rows = [make('target'), make('other')]
    monkeypatch.setattr(AgentContext, 'all', lambda: list(rows))
    monkeypatch.setattr(AgentContext, 'set_current', lambda id: None)
    monkeypatch.setattr(actions.TaskScheduler, 'get', lambda: NS(get_task_by_uuid=lambda id: None))
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: ['a0_notch'] if agent is None or agent.enabled else [])
    async def hook(*args, **kwargs):
        kwargs['data']['message'] += ' transformed'
    monkeypatch.setattr(actions.extension, 'call_extensions_async', hook)
    monkeypatch.setattr(actions.mq, 'log_user_message', Mock())
    monkeypatch.setattr(actions, 'stop_context', Mock(side_effect=lambda c: {'context': c.id, 'stopped': False}))
    return rows, make


def send(id='target'):
    return bound(dict(action='send', context=id, text='hello', message_id='message-1'))


@pytest.mark.parametrize('action', ['send', 'pause', 'resume', 'stop'])
def test_missing_never_creates_or_mutates(targets, action):
    rows, _ = targets
    data = send('absent') if action == 'send' else bound(dict(action=action, context='absent'))
    with pytest.raises(actions.TargetUnavailable):
        asyncio.run(actions.dispatch(data))
    assert len(rows) == 2
    assert not any(c.communicate.called for c in rows)
    actions.mq.log_user_message.assert_not_called()
    actions.stop_context.assert_not_called()


def test_normal_transformed_message_and_controls(targets):
    rows, _ = targets
    assert asyncio.run(actions.dispatch(send()))['context'] == 'target'
    message = rows[0].communicate.call_args.args[0]
    assert message.message == 'hello transformed'
    assert message.id == 'message-1'
    actions.mq.log_user_message.assert_called_once_with(rows[0], 'hello transformed', [], 'message-1')
    rows[1].communicate.assert_not_called()
    assert asyncio.run(actions.dispatch(bound(dict(action='pause', context='target')))) == {'context': 'target', 'pause': True}
    assert not rows[1].paused
    assert asyncio.run(actions.dispatch(bound(dict(action='resume', context='target'))))['pause'] is False
    assert asyncio.run(actions.dispatch(bound(dict(action='stop', context='target'))))['stopped'] is False
    actions.stop_context.assert_called_once_with(rows[0])


@pytest.mark.parametrize('change', ['delete', 'replace', 'scope', 'parent'])
def test_change_during_real_await_rejected(targets, monkeypatch, change):
    rows, make = targets
    original = rows[0]
    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()
        async def hook(*args, **kwargs):
            entered.set()
            await release.wait()
        monkeypatch.setattr(actions.extension, 'call_extensions_async', hook)
        task = asyncio.create_task(actions.dispatch(send()))
        await entered.wait()
        if change == 'delete': rows.pop(0)
        elif change == 'replace': rows[0] = make('target')
        elif change == 'scope': original.agent0.enabled = False
        else: original.output_data = dict(parent_context_id='missing', parent_context_kind='subordinate')
        release.set()
        with pytest.raises(actions.TargetUnavailable): await task
    asyncio.run(scenario())
    original.communicate.assert_not_called()
    actions.mq.log_user_message.assert_not_called()


@pytest.mark.parametrize('data', [{}, [], {'action': 'pause', 'context': ''},
    {'action': 'pause', 'context': ' '}, {'action': 'pause', 'context': 'target', 'paused': True},
    {'action': 'send', 'context': 'target', 'text': 'x', 'message_id': 'm', 'attachments': []},
    {'action': 'send', 'context': 'target', 'text': 'x' * 65537, 'message_id': 'm'}])
def test_strict_validation(data):
    with pytest.raises(ValueError): actions.validate(data)


def test_authenticated_route_and_missing_target(client, targets):
    assert client.post(PATH, json=bound(dict(action='pause', context='target')), headers=HEADERS).json == {'context': 'target', 'pause': True}
    response = client.post(PATH, json=send('absent'), headers=HEADERS)
    assert response.status_code == 409 and response.json['error'] == 'target_unavailable'
    assert response.headers['Cache-Control'] == 'no-store'


def test_route_auth_csrf_and_disabled(client, targets, monkeypatch):
    data = send()
    assert client.post(PATH, json=data).status_code == 403
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: [])
    assert client.post(PATH, json=data, headers=HEADERS).status_code == 403
    monkeypatch.setattr(http.login, 'get_credentials_hash', lambda: '')
    assert client.post(PATH, json=data, headers=HEADERS).status_code == 403
    actions.mq.log_user_message.assert_not_called()


def test_anonymous_route(app, targets):
    assert app.test_client().post(PATH, json=send(), headers=HEADERS).status_code in (302, 403)
    actions.mq.log_user_message.assert_not_called()


def test_route_rejects_multipart_and_oversize(client, targets):
    assert client.post(PATH, data={'context': 'target'}, headers=HEADERS).status_code == 400
    assert client.post(PATH, data=b'x' * (actions.MAX_REQUEST_BYTES + 1), content_type='application/json', headers=HEADERS).status_code == 400
    actions.mq.log_user_message.assert_not_called()


def test_route_errors_do_not_leak(client, targets, monkeypatch):
    async def fail(*args, **kwargs): raise RuntimeError('private fixture')
    monkeypatch.setattr(actions.extension, 'call_extensions_async', fail)
    response = client.post(PATH, json=send(), headers=HEADERS)
    assert response.status_code == 503
    assert 'private' not in response.get_data(as_text=True)


@pytest.mark.parametrize('removal_first', [True, False])
def test_real_registry_lock_orders_removal_and_dispatch(monkeypatch, removal_first):
    import threading
    import uuid
    from concurrent.futures import ThreadPoolExecutor

    id = 'notch-fixture-' + uuid.uuid4().hex
    entered, release, removed = threading.Event(), threading.Event(), threading.Event()
    context = NS(id=id, type=AgentContextType.USER, output_data={}, agent0=NS(),
                 task=None, get_agent=lambda: None, communicate=Mock())
    monkeypatch.setattr(actions.TaskScheduler, 'get', lambda: NS(get_task_by_uuid=lambda id: None))
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: ['a0_notch'])
    monkeypatch.setattr(actions.mq, 'log_user_message', Mock())
    monkeypatch.setattr(actions.extension, 'call_extensions_sync', lambda *a, **kw: None)
    async def hook(*args, **kwargs):
        if removal_first:
            entered.set()
            assert await asyncio.to_thread(release.wait, 3)
    monkeypatch.setattr(actions.extension, 'call_extensions_async', hook)
    def communicate(message):
        assert AgentContext.get(id) is context
        if not removal_first:
            entered.set()
            assert release.wait(3)
            assert not removed.is_set()
    context.communicate.side_effect = communicate
    def remove():
        AgentContext.remove(id)
        removed.set()
    with AgentContext._contexts_lock:
        AgentContext._contexts[id] = context
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            operation = pool.submit(asyncio.run, actions.dispatch(send(id)))
            assert entered.wait(3)
            deletion = pool.submit(remove)
            if removal_first:
                assert removed.wait(3)
            release.set()
            if removal_first:
                with pytest.raises(actions.TargetUnavailable): operation.result(timeout=3)
                context.communicate.assert_not_called()
                actions.mq.log_user_message.assert_not_called()
            else:
                assert operation.result(timeout=3)['context'] == id
                context.communicate.assert_called_once()
            deletion.result(timeout=3)
        assert AgentContext.get(id) is None
    finally:
        release.set()
        with AgentContext._contexts_lock:
            AgentContext._contexts.pop(id, None)
