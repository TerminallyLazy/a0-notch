"""Self-check the isolated HTTP test peer; these are NOT native-client tests."""
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import http.client
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode, urlsplit

import pytest

PATH = Path(__file__).resolve().parents[1] / 'scripts/m5_http_fixture.py'
spec = importlib.util.spec_from_file_location('m5_http_fixture', PATH)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@contextmanager
def server(scenario='normal'):
    peer = fixture.Fixture(scenario)
    trap = fixture.Fixture()
    peer.trap_origin = trap.origin
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (peer, trap)]
    for thread in threads:
        thread.start()
    try:
        yield peer, trap
    finally:
        peer.released.set()
        for s in (peer, trap):
            s.shutdown()
            s.server_close()
        for thread in threads:
            thread.join(timeout=2)
            assert not thread.is_alive()


def request(origin, path, body=None, headers=None):
    conn = http.client.HTTPConnection(urlsplit(origin).hostname, urlsplit(origin).port, timeout=3)
    try:
        conn.request('GET' if body is None else 'POST', path, body=body, headers=headers or {})
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def login(peer):
    status, headers, _ = request(peer.origin, '/login', urlencode(dict(username=fixture.USERNAME, password=fixture.PASSWORD)),
                                 {'Origin': peer.origin, 'Content-Type': 'application/x-www-form-urlencoded'})
    assert status == 302 and headers['Location'] == '/'
    cookie = headers['Set-Cookie'].split(';')[0]
    status, _, data = request(peer.origin, '/api/csrf_token', headers={'Origin': peer.origin, 'Cookie': cookie})
    assert status == 200 and json.loads(data)['token'] == fixture.TOKEN
    return {'Origin': peer.origin, 'Cookie': cookie, 'X-CSRF-Token': fixture.TOKEN, 'Content-Type': 'application/json'}


def exchange(peer, headers, action, **extra):
    return request(peer.origin, '/api/plugins/a0_notch/events',
                   json.dumps(dict(action=action, client_id='fixture-client', **extra)), headers)


def test_fixture_complete_flow_and_disconnect():
    with server() as (peer, _):
        headers = login(peer)
        status, _, data = request(peer.origin, '/api/plugins/a0_notch/status', '{}', headers)
        assert status == 200 and json.loads(data)['auth'] == 'session_csrf'
        assert exchange(peer, headers, 'connect')[0] == 200
        status, _, data = exchange(peer, headers, 'poll', server_epoch=fixture.EPOCH, cursor=0)
        assert status == 200 and json.loads(data)['events'][0]['kind'] == 'finished'
        assert exchange(peer, headers, 'disconnect', server_epoch=fixture.EPOCH)[0] == 200
        assert peer.lease is None
        assert peer.counts == dict(login=1, csrf=1, status=1, connect=1, poll=1, disconnect=1)


@pytest.mark.parametrize('missing', ['Cookie', 'Origin', 'X-CSRF-Token'])
def test_fixture_guards_each_protected_header(missing):
    with server() as (peer, _):
        headers = login(peer)
        del headers[missing]
        assert request(peer.origin, '/api/plugins/a0_notch/status', '{}', headers)[0] == 403
        assert exchange(peer, headers, 'connect')[0] == 403
        assert peer.lease is None


@pytest.mark.parametrize('scenario,code', [('status_unauthorized', 401), ('status_forbidden', 403),
                                          ('status_redirect', 307), ('status_cross_redirect', 307)])
def test_fixture_status_failures(scenario, code):
    with server(scenario) as (peer, trap):
        headers = login(peer)
        status, response_headers, _ = request(peer.origin, '/api/plugins/a0_notch/status', '{}', headers)
        assert status == code
        if code == 307:
            assert response_headers['Location'] == ('/capture' if scenario == 'status_redirect' else trap.origin + '/capture')
        assert not trap.counts


@pytest.mark.parametrize('scenario', ['status_oversized', 'status_stream_oversized'])
def test_fixture_oversized_framing(scenario):
    with server(scenario) as (peer, _):
        status, headers, data = request(peer.origin, '/api/plugins/a0_notch/status', '{}', login(peer))
        assert status == 200 and len(data) == 2097153
        if scenario == 'status_oversized':
            assert headers['Content-Length'] == '2097153'
        else:
            assert headers['Transfer-Encoding'] == 'chunked' and 'Content-Length' not in headers


@pytest.mark.parametrize('scenario', ['status_html', 'status_malformed'])
def test_fixture_malformed_responses(scenario):
    with server(scenario) as (peer, _):
        status, headers, data = request(peer.origin, '/api/plugins/a0_notch/status', '{}', login(peer))
        assert status == 200
        assert headers['Content-Type'] == ('text/html' if scenario == 'status_html' else 'application/json')
        with pytest.raises(json.JSONDecodeError):
            json.loads(data)


def test_fixture_held_poll_barrier():
    with server('held_poll') as (peer, _):
        headers = login(peer)
        exchange(peer, headers, 'connect')
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(exchange, peer, headers, 'poll', server_epoch=fixture.EPOCH, cursor=0)
            try:
                deadline = time.monotonic() + 2
                while peer.counts.get('poll', 0) == 0 and time.monotonic() < deadline:
                    time.sleep(.01)
                assert peer.counts.get('poll') == 1 and not pending.done()
            finally:
                request(peer.origin, '/__fixture/release', '')
            assert pending.result(timeout=2)[0] == 200


def test_fixture_empty_contexts():
    with server('empty') as (peer, _):
        headers = login(peer)
        _, _, data = request(peer.origin, '/api/plugins/a0_notch/status', '{}', headers)
        assert json.loads(data)['contexts'] == []


def test_fixture_process_ready_and_cleanup(tmp_path):
    ready = tmp_path / 'ready.json'
    process = subprocess.Popen([sys.executable, str(PATH), '--ready-file', str(ready)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while not ready.exists() and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(.02)
        value = json.loads(ready.read_text())
        assert request(value['origin'], '/__fixture')[0] == 200
        assert request(value['trap_origin'], '/__fixture')[0] == 200
    finally:
        process.terminate()
        process.wait(timeout=3)
        ready.unlink(missing_ok=True)
    assert process.poll() is not None
    with pytest.raises(ConnectionError):
        request(value['origin'], '/__fixture')


def test_native_action_contracts_and_discovery():
    with server('many') as (peer, _):
        headers = login(peer)
        def api(name, **body):
            code, _, data = request(peer.origin, '/api/' + name, json.dumps(body), headers)
            assert code == 200
            return json.loads(data)
        status = api('plugins/a0_notch/status')
        assert len(status['contexts']) == 251
        assert status['capabilities'] == ['discovery', 'metadata', 'poll', 'exact_target_actions']
        assert api('message_async', context='fixture-root', text='Synthetic', message_id='id')['context'] == 'fixture-root'
        assert api('pause', context='fixture-root', paused=True)['pause'] is True
        snapshot = api('poll', context='fixture-root', log_from=0, notifications_from=9007199254740991, timezone='UTC')
        assert snapshot['paused'] and snapshot['logs'][1]['content'] == 'Synthetic answer'
        assert api('stop', context='fixture-root')['stopped']
        assert api('chat_create', new_context='created', project_name='')['ctxid'] == 'created'
        assert len(api('plugins/a0_notch/status')['contexts']) == 252
