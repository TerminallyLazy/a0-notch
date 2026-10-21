"""Exact incarnation binding, atomic complete catalogs, FIFO and scalar diffs."""
import asyncio
import uuid
import pytest
from usr.plugins.a0_notch.helpers import actions, capture, http, pagination
from usr.plugins.a0_notch.helpers.incarnation import token
from usr.plugins.a0_notch.helpers.relay import Relay
from test_actions import targets, send
from test_m5 import app, client, HEADERS, ROW


def test_pre_request_replacement_rejected(targets):
    rows, make = targets
    request = send()
    original = rows[0]
    rows[0] = make('target')
    with pytest.raises(actions.TargetUnavailable):
        asyncio.run(actions.dispatch(request))
    original.communicate.assert_not_called()
    rows[0].communicate.assert_not_called()


def test_missing_incarnation_fails_closed(targets):
    data = send(); del data['incarnation']
    with pytest.raises(ValueError): asyncio.run(actions.dispatch(data))
    targets[0][0].communicate.assert_not_called()


def test_incarnation_stable_only_for_object(targets):
    rows, make = targets
    assert token(rows[0]) == token(rows[0])
    assert token(rows[0]) != token(make('target'))


def test_complete_large_catalog_via_real_api(client, monkeypatch):
    rows = [dict(ROW, id=f'c{i}', name='x' * 80) for i in range(12000)]
    monkeypatch.setattr(http, 'contexts', lambda: rows)
    result = client.post('/api/plugins/a0_notch/status', json={}, headers=HEADERS)
    assert result.status_code == 200
    assert len(result.data) < 2 * 1024 * 1024
    first = result.json
    found = first['contexts'][:]
    while result.json['next_offset'] is not None:
        result = client.post('/api/plugins/a0_notch/status', json={
            'page_token': first['page_token'], 'offset': result.json['next_offset']}, headers=HEADERS)
        assert result.status_code == 200
        found.extend(result.json['contexts'])
    assert found == rows


@pytest.mark.parametrize('change', ['remove', 'replace', 'add'])
def test_page_transaction_fails_on_catalog_change(change):
    pages = pagination.Pages()
    rows = [dict(ROW, id=f'c{i}') for i in range(129)]
    first = pages.first(dict(contexts=rows, server_epoch='epoch'), True)
    current = rows[:]
    if change == 'remove': current.pop()
    if change == 'replace': current[0] = dict(current[0], incarnation=str(uuid.uuid4()))
    if change == 'add': current.append(dict(ROW, id='extra'))
    with pytest.raises(pagination.PageExpired):
        pages.next(dict(page_token=first['page_token'], offset=128), current, True, 'epoch')


def test_pages_expire_and_bad_offsets_fail(monkeypatch):
    pages = pagination.Pages()
    rows = [dict(ROW, id=f'c{i}') for i in range(129)]
    first = pages.first(dict(contexts=rows, server_epoch='epoch'), True)
    with pytest.raises(ValueError): pages.next(dict(page_token=first['page_token'], offset=True), rows, True, 'epoch')
    monkeypatch.setattr(pagination.time, 'monotonic', lambda: float('inf'))
    with pytest.raises(pagination.PageExpired): pages.next(dict(page_token=first['page_token'], offset=128), rows, True, 'epoch')


def test_replacement_purges_old_events_and_completion():
    relay = Relay(); relay.configure({'root': 'old'})
    client = str(uuid.uuid4()); relay.exchange(dict(action='connect', client_id=client), [dict(ROW, incarnation='old')])
    run = relay.begin_run('root')
    relay.capture('root', 'error', 'error', incarnation='old')
    relay.configure({'root': 'new'})
    assert not relay.ring and not relay.runs
    assert not relay.capture('root', 'finished', 'finished', run=run)
    assert not relay.capture('root', 'error', 'error', incarnation='old')


def test_error_pause_fifo_and_no_question_inference():
    relay = Relay(); relay.configure({'root': ROW['incarnation']})
    client = str(uuid.uuid4()); relay.exchange(dict(action='connect', client_id=client), [ROW])
    relay.capture('root', 'error', 'error')
    poll = dict(action='poll', client_id=client, server_epoch=relay.epoch, cursor=0)
    result = relay.exchange(poll, [dict(ROW, state='paused')])
    assert [e['kind'] for e in result['events']] == ['error', 'intervention']
    result = relay.exchange(dict(poll, cursor=result['cursor']), [dict(ROW, state='paused')])
    assert result['events'] == []
    relay.exchange(dict(poll, cursor=result['cursor']), [ROW])
    result = relay.exchange(dict(poll, cursor=result['cursor']), [dict(ROW, state='paused')])
    assert [e['kind'] for e in result['events']] == ['intervention']


def test_diff_metadata_never_forwards_arbitrary_fields():
    relay = Relay(); relay.configure(['root'])
    relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [ROW])
    good = dict(path='src/test.py', added=2, removed=1)
    assert relay.capture('root', 'tool_end', 'working', diff=good)
    assert relay.ring[-1]['diff'] == good
    for bad in [dict(good, contents='private'), dict(good, path='/etc/passwd'), dict(good, path='.env'), dict(good, added=True)]:
        relay.capture('root', 'tool_end', 'working', diff=bad)
        assert 'diff' not in relay.ring[-1]


@pytest.mark.parametrize('replace', [False, True])
def test_selected_snapshot_incarnation_and_no_other_collections(client, targets, monkeypatch, replace):
    from usr.plugins.a0_notch.helpers import selected
    rows, make = targets
    data = dict(context='target', incarnation=token(rows[0]), log_from=0)
    async def snapshot(context, start):
        assert context.id == 'target'
        if replace: rows[0] = make('target')
        return dict(context='target', deselect_chat=False, logs=[], log_guid='g', log_version=0,
                    paused=False, log_progress='', log_progress_active=False,
                    contexts=['private-other-chat'], notifications=['private'])
    monkeypatch.setattr(selected, 'snapshot', snapshot)
    response = client.post('/api/plugins/a0_notch/selected', json=data, headers=HEADERS)
    assert response.status_code == (409 if replace else 200)
    assert 'private' not in response.get_data(as_text=True)


def test_invalid_selected_token_never_calls_snapshot(client, targets, monkeypatch):
    from usr.plugins.a0_notch.helpers import selected
    monkeypatch.setattr(selected, 'snapshot', lambda **kw: pytest.fail('must not call'))
    response = client.post('/api/plugins/a0_notch/selected', json=dict(context='target', log_from=0), headers=HEADERS)
    assert response.status_code == 400


def test_paged_schema_breaks_old_partial_catalog_clients(client):
    response = client.post('/api/plugins/a0_notch/status', json={}, headers=HEADERS)
    assert response.json['schema_version'] == 2
    assert response.json['catalog_count'] == len(response.json['contexts'])


def test_new_undiscovered_object_cannot_poison_old_incarnation(monkeypatch):
    from test_plugin_discovery import context
    from concurrent.futures import Future
    relay = Relay(); old = context('root'); old_token = token(old)
    relay.configure({'root': old_token})
    relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [dict(ROW, incarnation=old_token)])
    replacement = context('root')
    monkeypatch.setattr(capture, 'relay', relay)
    capture.observe(replacement.agent0, 'error')
    future = Future()
    capture.task_started(dict(args=(replacement,), result=future))
    future.set_result(None)
    assert not relay.ring and not relay.runs


def test_selected_padded_id_never_aliases_other_context(client, targets, monkeypatch):
    from usr.plugins.a0_notch.helpers import selected
    rows, make = targets; rows.append(make(' target '))
    monkeypatch.setattr(selected, 'snapshot', lambda **kw: pytest.fail('no normalized lookup'))
    response = client.post('/api/plugins/a0_notch/selected', json=dict(context=' target ', incarnation=token(rows[-1]), log_from=0), headers=HEADERS)
    assert response.status_code == 400


def test_event_pages_renew_only_original_live_lease():
    clock = [0]
    relay = Relay(clock=lambda: clock[0])
    rows = [dict(ROW, id=f'c{i}') for i in range(400)]
    relay.configure(r['id'] for r in rows)
    client = str(uuid.uuid4())
    payload = relay.exchange(dict(action='connect', client_id=client), rows)
    pages = pagination.Pages(); first = pages.first(payload, False, relay=relay)
    clock[0] = 12
    pages.next(dict(page_token=first['page_token'], offset=128), rows, False, relay.epoch, relay=relay)
    clock[0] = 24
    pages.next(dict(page_token=first['page_token'], offset=256), rows, False, relay.epoch, relay=relay)
    assert relay.client == client and relay.deadline == 39


def test_mixed_incarnation_catalog_rejected():
    from usr.plugins.a0_notch.helpers.relay import LeaseConflict
    relay = Relay(); relay.configure({'root': 'new'})
    with pytest.raises(LeaseConflict):
        relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [dict(ROW, incarnation='old')])


def test_disconnect_paused_catalog_does_not_recreate_telemetry():
    relay = Relay(); relay.configure(['root'])
    client = str(uuid.uuid4())
    relay.exchange(dict(action='connect', client_id=client), [ROW])
    relay.exchange(dict(action='disconnect', client_id=client, server_epoch=relay.epoch), [dict(ROW, state='paused')])
    assert not relay.client and not relay.ring and not relay.states
