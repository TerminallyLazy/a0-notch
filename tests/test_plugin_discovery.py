"""0.6 discovery regressions; synthetic registry, actual framework API routing elsewhere."""
from concurrent.futures import Future
from datetime import datetime, timezone
from types import SimpleNamespace as NS
from unittest.mock import patch
import json
import uuid

import pytest
from agent import AgentContext, AgentContextType
from helpers import secrets
from helpers.task_scheduler import TaskScheduler
from usr.plugins.a0_notch.helpers import http, capture, relay as mod


def context(id, parent=None, enabled=True, number=0, **overrides):
    row = NS(id=id, name='Chat ' + id, type=AgentContextType.USER,
             output_data={} if parent is None else dict(parent_context_id=parent, parent_context_kind='subordinate'),
             agent0=NS(number=number, enabled=enabled), paused=False, is_running=lambda: False,
             created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
             last_message=datetime(2026, 10, 20, tzinfo=timezone.utc))
    row.agent0.context = row
    row.__dict__.update(overrides)
    return row


@pytest.fixture
def registry(monkeypatch):
    rows = []
    monkeypatch.setattr(AgentContext, 'all', lambda: list(rows))
    monkeypatch.setattr(TaskScheduler, 'get', lambda: NS(get_task_by_uuid=lambda id: None))
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: ['a0_notch'] if agent.enabled else [])
    monkeypatch.setattr(secrets, 'get_secrets_manager', lambda ctx: NS(mask_values=lambda text, **kw: text.replace('fixture-secret', '[redacted]')))
    return rows


def test_all_chats_discovered_with_parent_and_actual_dates(registry):
    registry.extend(context(f'c{i}') for i in range(27))
    registry.append(context('child', parent='c0', number=1))
    rows = http.contexts()
    assert len(rows) == 28
    child = next(r for r in rows if r['id'] == 'child')
    assert child['parent_id'] == 'c0'
    assert child['name'] == 'Chat child'
    assert child['last_activity_at'] == 1792454400.0
    assert child['created_at'] == 1767225600.0
    assert 'parent_id' not in next(r for r in rows if r['id'] == 'c0')


def test_scope_and_inherited_disablement(registry):
    registry.extend([context('off', enabled=False), context('child', parent='off'),
                     context('grandchild', parent='child'), context('on')])
    assert [r['id'] for r in http.contexts()] == ['on']


def test_malformed_relationships_fail_closed(registry):
    registry.extend([context('missing', parent='absent'), context('a', parent='b'),
                     context('b', parent='a'), context('self', parent='self'), context('on')])
    assert [r['id'] for r in http.contexts()] == ['on']


def test_deep_valid_hierarchy_has_no_product_cap(registry):
    registry.extend(context(f'c{i}', parent=f'c{i-1}' if i else None) for i in range(300))
    assert len(http.contexts()) == 300


def test_background_and_scheduler_tasks_are_not_chat_collection(registry, monkeypatch):
    registry.extend([context('background', type=AgentContextType.BACKGROUND), context('scheduled'), context('chat')])
    monkeypatch.setattr(TaskScheduler, 'get', lambda: NS(get_task_by_uuid=lambda id: NS(context_id=id) if id == 'scheduled' else None))
    assert [r['id'] for r in http.contexts()] == ['chat']


def test_names_mask_before_truncation_and_no_arbitrary_projection(registry):
    registry.append(context('chat', name='x' * 75 + 'fixture-secret\n',
                            output_data={'prompt': 'private-content', 'token': 'private-content'}))
    rows = http.contexts()
    assert len(rows[0]['name']) == 80
    wire = json.dumps(rows)
    assert 'fixture-secret' not in wire and 'private-content' not in wire
    assert '\\n' not in wire


def test_discovery_reconciles_without_revoking_lease():
    relay = mod.Relay()
    rows = [dict(id='a', name='A', state='working', running=True, tool='')]
    relay.configure(['a'])
    client = str(uuid.uuid4())
    relay.exchange(dict(action='connect', client_id=client), rows)
    token = relay.begin_run('a')
    relay.capture('a', 'thinking', 'thinking')
    relay.configure(['a', 'b'])
    rows.append(dict(rows[0], id='b'))
    result = relay.exchange(dict(action='poll', client_id=client, server_epoch=relay.epoch, cursor=0), rows)
    assert len(result['contexts']) == 2 and relay.runs['a'] == token
    relay.configure(['b'])
    result = relay.exchange(dict(action='poll', client_id=client, server_epoch=relay.epoch, cursor=result['cursor']), rows)
    assert [r['id'] for r in result['contexts']] == ['b']
    assert 'a' not in relay.states and 'a' not in relay.runs
    assert all(e['context_id'] != 'a' for e in relay.ring)


def test_separate_child_observation_and_completion_do_not_change_parent():
    relay = mod.Relay()
    relay.configure(['root', 'child'])
    relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [])
    child = context('child', parent='root', number=1)
    future = Future()
    with patch.object(capture, 'relay', relay):
        capture.observe(child.agent0, 'thinking')
        assert relay.ring[-1]['context_id'] == 'child'
        assert relay.ring[-1]['state'] == 'thinking'
        capture.task_started(dict(args=(child,), result=future))
        future.set_result('private-result')
    assert relay.ring[-1]['context_id'] == 'child'
    assert relay.ring[-1]['state'] == 'finished'
    assert 'root' not in relay.states
    assert 'private-result' not in json.dumps(list(relay.ring))


def test_in_context_subagent_is_activity_only():
    relay = mod.Relay()
    relay.configure(['root'])
    relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [])
    root = context('root')
    with patch.object(capture, 'relay', relay):
        capture.observe(NS(context=root, number=1), 'thinking')
    assert relay.ring[-1]['context_id'] == 'root'
    assert relay.ring[-1]['state'] == 'delegating'


def test_reply_limit_is_bytes_and_fails_closed():
    response = http.reply({'ok': True, 'contexts': [{'name': '😀' * 600000}]})
    assert response.status_code == 503
    assert json.loads(response.get_data()) == {'ok': False, 'error': 'snapshot_too_large'}
    assert len(response.get_data()) < 100


def test_large_snapshot_without_context_count_cap(registry):
    registry.extend(context(f'chat{i}') for i in range(2500))
    rows = http.contexts()
    response = http.reply({'ok': True, 'contexts': rows})
    assert response.status_code == 200
    assert len(response.json['contexts']) == 2500
    assert 128 * 1024 < len(response.get_data()) <= 2 * 1024 * 1024


def test_exact_wire_byte_boundary():
    # Compact JSON encoding of {"x":""} costs eight ASCII bytes.
    payload = {'x': 'a' * (http.MAX_RESPONSE_BYTES - 8)}
    response = http.reply(payload)
    assert response.status_code == 200
    assert len(response.get_data()) == http.MAX_RESPONSE_BYTES
    payload['x'] += 'a'
    response = http.reply(payload)
    assert response.status_code == 503
    assert response.json['error'] == 'snapshot_too_large'


def test_removed_then_rediscovered_run_cannot_accept_old_completion():
    relay = mod.Relay()
    relay.configure(['a'])
    relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [])
    old = relay.begin_run('a')
    relay.configure([])
    relay.configure(['a'])
    new = relay.begin_run('a')
    assert old != new
    assert not relay.capture('a', 'finished', 'finished', run=old)
    assert relay.capture('a', 'finished', 'finished', run=new)


def test_reverse_deep_hierarchy_is_linear(registry, monkeypatch):
    registry.extend(context(f'c{i}', parent=f'c{i-1}' if i else None) for i in reversed(range(300)))
    calls = []
    def enabled(agent):
        calls.append(agent)
        return ['a0_notch']
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', enabled)
    assert len(http.contexts()) == 300
    assert len(calls) == 300


def test_wrong_parent_kind_fails_closed(registry):
    registry.extend([context('root'), context('child', output_data={
        'parent_context_id': 'root', 'parent_context_kind': 'unknown'})])
    assert [r['id'] for r in http.contexts()] == ['root']


def test_invalid_timestamps_omitted_not_replaced_with_poll_time(registry):
    registry.append(context('a', last_message=None, created_at='untrusted-date'))
    row = http.contexts()[0]
    assert 'last_activity_at' not in row and 'created_at' not in row


def test_no_parent_number_assumption(registry):
    registry.append(context('standalone', number=4))
    assert http.contexts()[0]['id'] == 'standalone'


def test_lifecycle_invalidates_lease_without_external_side_effects():
    from usr.plugins.a0_notch import hooks
    for action in (hooks.install, hooks.pre_update, hooks.uninstall):
        mod.relay.configure(['a'])
        mod.relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [])
        mod.relay.capture('a', 'thinking', 'thinking')
        epoch = mod.relay.epoch
        action()
        assert not mod.relay.client and not mod.relay.ring and not mod.relay.allowed
        assert mod.relay.epoch != epoch
