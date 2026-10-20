import asyncio
from concurrent.futures import Future
import importlib.util
import json
from pathlib import Path
import threading
from types import SimpleNamespace as NS
import uuid
from unittest.mock import patch

import pytest
from flask import Flask
from helpers import api, cache
from usr.plugins.a0_notch.helpers import relay as mod, capture, http

CID = str(uuid.uuid4())
ROW = dict(id='root', name='Context 1', running=True, state='working', tool='')

@pytest.fixture
def relay():
    r = mod.Relay()
    r.configure(['root'])
    r.exchange(dict(action='connect', client_id=CID), [ROW])
    return r

def poll(r, cursor=0):
    return r.exchange(dict(action='poll', client_id=CID, server_epoch=r.epoch, cursor=cursor), [ROW])

def test_no_consumer():
    r = mod.Relay(); r.configure(['root'])
    assert not r.capture('root', 'thinking', 'thinking')
    assert not r.ring and r.dropped['no_consumer'] == 1

def test_ring_slow_consumer(relay):
    for _ in range(10000): relay.capture('root', 'tool_start', 'working', 'browser')
    result = poll(relay)
    assert len(result['events']) == 64 and result['reset']
    assert result['events'][0]['sequence'] == 9937
    assert result['dropped']['overflow'] == 9936
    assert len(json.dumps(result)) < 131072
    assert len(relay.states) == 1

def test_contention_drops_without_waiting(relay):
    with relay.lock:
        assert not relay.capture('root', 'thinking', 'thinking')
    assert relay.dropped['contention'] == 1

def test_lease_expiry(relay):
    relay.clock = lambda: relay.deadline
    assert not relay.capture('root', 'thinking', 'thinking')
    assert not relay.ring and not relay.states
    with pytest.raises(mod.LeaseConflict): poll(relay)

def test_second_client(relay):
    with pytest.raises(mod.LeaseConflict):
        relay.exchange(dict(action='connect', client_id=str(uuid.uuid4())), [ROW])

def test_disconnect(relay):
    relay.capture('root', 'thinking', 'thinking')
    relay.exchange(dict(action='disconnect', client_id=CID, server_epoch=relay.epoch), [ROW])
    assert not relay.ring and not relay.client
    assert not relay.capture('root', 'thinking', 'thinking')

def test_reconnect_no_replay(relay):
    relay.capture('root', 'thinking', 'thinking')
    result = relay.exchange(dict(action='connect', client_id=CID), [ROW])
    assert result['events'] == [] and result['reset']

def test_discovery_removal_preserves_empty_lease(relay):
    relay.configure([])
    assert poll(relay)['contexts'] == []
    assert not relay.capture('root', 'thinking', 'thinking')

@pytest.mark.parametrize('kind,state', [('thinking','thinking'), ('finished','finished'), ('error','error'), ('idle','idle')])
def test_non_tool_event_preserves_empty_tool(relay, kind, state):
    assert relay.capture('root', kind, state)
    assert poll(relay)['events'][-1]['tool'] == ''


def test_unknown_tool_no_content(relay):
    relay.capture('root', 'tool_start', 'working', 'secret-like-fixture')
    assert poll(relay)['events'][0]['tool'] == 'tool'
    assert 'secret-like-fixture' not in json.dumps(poll(relay))

def test_unauthorized_context(relay):
    assert not relay.capture('other', 'thinking', 'thinking')
    assert not relay.ring

def test_old_run_completion(relay):
    old = relay.begin_run('root'); new = relay.begin_run('root')
    assert old != new
    assert not relay.capture('root', 'finished', 'finished', run=old)
    assert relay.capture('root', 'finished', 'finished', run=new)

def test_pause_reconciles(relay):
    relay.capture('root', 'thinking', 'thinking')
    result = relay.exchange(dict(action='poll', client_id=CID, server_epoch=relay.epoch, cursor=0), [dict(ROW, state='paused')])
    assert result['contexts'][0]['state'] == 'paused'

def test_idle_not_fabricated_finished(relay):
    relay.capture('root', 'thinking', 'thinking')
    result = relay.exchange(dict(action='poll', client_id=CID, server_epoch=relay.epoch, cursor=0), [dict(ROW, running=False, state='idle')])
    assert result['contexts'][0]['state'] == 'idle'

@pytest.mark.parametrize('value', [None, [], {}, {'action':'send'}, {'action':'connect','client_id':CID,'text':'x'}, {'action':'connect','client_id':'bad'}, {'action':'poll','client_id':CID,'server_epoch':CID,'cursor':True}, {'action':'poll','client_id':CID,'server_epoch':CID,'cursor':-1}, {'action':'poll','client_id':CID,'server_epoch':CID,'cursor':2**53}])
def test_invalid_request(value):
    with pytest.raises(ValueError): mod.validate_request(value)

@pytest.mark.parametrize('outcome', ['finished','error','cancel'])
def test_task_callback(relay, outcome):
    future = Future()
    context = NS(id='root', agent0=NS(number=0))
    with patch.object(capture, 'relay', relay), patch.object(capture, 'display_id', return_value='root'):
        capture.task_started(dict(args=(context,), result=future))
        if outcome == 'cancel': future.cancel()
        elif outcome == 'error': future.set_exception(ValueError('private fixture'))
        else: future.set_result('private fixture')
    result = poll(relay)
    assert result['events'][-1]['state'] == ('idle' if outcome == 'cancel' else outcome)
    assert 'private fixture' not in json.dumps(result)

def test_child_does_not_finish_parent(relay):
    future = Future()
    with patch.object(capture,'relay',relay), patch.object(capture,'display_id',return_value='root'):
        capture.task_started(dict(args=(NS(id='child', agent0=NS(number=1)),), result=future))
        future.set_result('private fixture')
    assert not relay.ring

def test_observer_fail_closed():
    with patch.object(capture, 'display_id', side_effect=RuntimeError('private')):
        capture.observe(NS(context=NS(), number=0), 'thinking')
    capture.exception({}); capture.task_started({})

@pytest.fixture
def app(monkeypatch):
    app = Flask('notch-test'); app.secret_key = 'test-only-not-a-credential'
    app.add_url_rule('/login', 'login_handler', lambda: 'login')
    app.add_url_rule('/', 'serve_index', lambda: 'index')
    cache.clear(api.CACHE_AREA)
    root = str(Path(__file__).resolve().parents[1] / 'plugin')
    monkeypatch.setattr(http.login, 'get_credentials_hash', lambda: 'fixture-hash')
    monkeypatch.setattr(http.plugins, 'find_plugin_dir', lambda name: root if name == 'a0_notch' else None)
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: ['a0_notch'])
    monkeypatch.setattr(http.plugins, 'get_plugin_config', lambda *a, **kw: dict(allowed_context_ids=['root']))
    monkeypatch.setattr(http, 'contexts', lambda: [ROW])
    monkeypatch.setattr(http, 'relay', mod.Relay())
    api.register_api_route(app, threading.RLock())
    yield app
    cache.clear(api.CACHE_AREA)

@pytest.fixture
def client(app):
    c = app.test_client()
    with c.session_transaction() as s:
        s['authentication'] = 'fixture-hash'; s['csrf_token'] = 'fixture-csrf'
    return c

PATH = '/api/plugins/a0_notch/status'
HEADERS = {'X-CSRF-Token':'fixture-csrf'}

def test_http_authenticated(client):
    response = client.post(PATH, json={}, headers=HEADERS)
    assert response.status_code == 200
    assert response.json['contexts'][0]['id'] == 'root'
    assert response.headers['Cache-Control'] == 'no-store'
    assert response.json['schema_version'] == 1
    assert response.json['plugin_version'] == '0.6.1'
    assert response.json['capabilities'] == ['discovery', 'metadata', 'poll', 'exact_target_actions']
    assert response.json['auth'] == 'session_csrf'


def test_http_legacy_config_not_read(client, monkeypatch):
    def obsolete(*args, **kwargs):
        raise AssertionError('obsolete allowlist/name config must not be read')
    monkeypatch.setattr(http.plugins, 'get_plugin_config', obsolete)
    assert client.post(PATH, json={}, headers=HEADERS).status_code == 200


def test_http_oversized_snapshot_revokes_lease(client, monkeypatch):
    path = '/api/plugins/a0_notch/events'
    response = client.post(path, json=dict(action='connect', client_id=CID), headers=HEADERS)
    assert response.status_code == 200 and http.relay.client == CID
    monkeypatch.setattr(http, 'contexts', lambda: [dict(ROW, id=f'c{i}', name='z' * 80) for i in range(16000)])
    response = client.post(PATH, json={}, headers=HEADERS)
    assert response.status_code == 503
    assert response.json == {'ok': False, 'error': 'snapshot_too_large'}
    assert http.relay.client is None and not http.relay.allowed


def test_http_discovery_failure_does_not_return_partial_data(client, monkeypatch):
    monkeypatch.setattr(http, 'contexts', lambda: (_ for _ in ()).throw(RuntimeError('private-fixture')))
    response = client.post(PATH, json={}, headers=HEADERS)
    assert response.status_code == 503
    assert response.json == {'ok': False, 'error': 'unavailable'}

def test_http_missing_auth(app):
    response = app.test_client().post(PATH,json={},headers=HEADERS)
    assert response.status_code in (302,403)

def test_http_missing_csrf(client):
    assert client.post(PATH,json={}).status_code == 403

def test_http_bad_auth(client):
    with client.session_transaction() as s: s['authentication'] = 'wrong'
    assert client.post(PATH,json={},headers=HEADERS).status_code in (302,403)

def test_http_no_login(client,monkeypatch):
    monkeypatch.setattr(http.login,'get_credentials_hash',lambda: '')
    assert client.post(PATH,json={},headers=HEADERS).status_code == 403

def test_http_disabled(client,monkeypatch):
    monkeypatch.setattr(http.plugins,'get_enabled_plugins',lambda agent: [])
    assert client.post(PATH,json={},headers=HEADERS).status_code == 403

@pytest.mark.parametrize('body', ['{', '[]', '{"unknown":true}', ' '*4097])
def test_http_malformed(client,body):
    assert client.post(PATH,data=body,content_type='application/json',headers=HEADERS).status_code == 400

def test_http_exchange(client):
    path = '/api/plugins/a0_notch/events'
    result = client.post(path,json=dict(action='connect',client_id=CID),headers=HEADERS)
    assert result.status_code == 200
    assert result.json['events'] == []
    assert client.post(path,json=dict(action='poll',client_id=CID,server_epoch=CID,cursor=0),headers=HEADERS).status_code == 409

def test_http_internal_failure_redacted(client,monkeypatch):
    monkeypatch.setattr(http,'contexts',lambda *a: (_ for _ in ()).throw(RuntimeError('private-fixture')))
    response = client.post(PATH,json={},headers=HEADERS)
    assert response.status_code == 503 and b'private-fixture' not in response.data
