#!/usr/bin/env python3
"""Isolated native-client test peer, NOT Agent Zero or a deployment tool.

Binds ephemeral loopback ports, uses only disposable synthetic credentials,
keeps all state in memory, and never reads A0 settings, chats or secrets.
Control routes are test-only and must never be deployed with the plugin.
"""
import argparse
import json
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
from urllib.parse import parse_qs

USERNAME = 'fixture+user &=' 
PASSWORD = 'synthetic+password &= café'
COOKIE = 'synthetic-session'
TOKEN = 'synthetic-csrf-token-0123456789'
EPOCH = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
SCENARIOS = (
    'normal', 'empty', 'bad_login', 'login_without_cookie', 'login_redirect',
    'csrf_malformed', 'csrf_invalid', 'status_unauthorized', 'status_forbidden',
    'status_redirect', 'status_cross_redirect', 'status_html', 'status_malformed',
    'status_oversized', 'status_stream_oversized', 'lease_conflict', 'poll_unauthorized',
    'legacy_actions', 'held_poll', 'many', 'wrong_chat', 'missing_chat', 'ambiguous_send', 'mutation_forbidden',
)


class Fixture(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, scenario='normal'):
        super().__init__(('127.0.0.1', 0), Handler)
        self.scenario = scenario
        self.lock = threading.Lock()
        self.counts = {}
        self.lease = None
        self.released = threading.Event()
        self.trap_origin = ''
        self.created = []
        self.paused = False

    @property
    def origin(self):
        return f'http://127.0.0.1:{self.server_port}'

    def record(self, name):
        with self.lock:
            self.counts[name] = self.counts.get(name, 0) + 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Never log headers, bodies, cookies or credentials.

    def send(self, status=200, value=None, *, raw=None, mime='application/json', headers=None, chunked=False):
        body = raw if raw is not None else json.dumps(value).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', mime)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            if chunked:
                self.send_header('Transfer-Encoding', 'chunked')
            else:
                self.send_header('Content-Length', str(len(body)))
            for key, val in (headers or {}).items():
                self.send_header(key, val)
            self.end_headers()
            if chunked:
                for start in range(0, len(body), 4096):
                    block = body[start:start + 4096]
                    self.wfile.write(f'{len(block):x}\r\n'.encode() + block + b'\r\n')
                self.wfile.write(b'0\r\n\r\n')
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected for cancellation/oversize tests.
        finally:
            self.close_connection = True

    def cookie_valid(self):
        cookie = SimpleCookie()
        cookie.load(self.headers.get('Cookie', ''))
        return cookie.get('fixture_session') is not None and cookie['fixture_session'].value == COOKIE

    def contexts(self, finished=False):
        if self.server.scenario == 'empty':
            return []
        rows = [dict(id='fixture-root', name='Context 1', state='finished' if finished else 'working',
                     tool='', running=not finished, last_activity_at=100, created_at=1)]
        if self.server.scenario == 'many':
            rows += [dict(id=f'chat-{i}', name=f'Chat {i}', state='idle', tool='', running=False,
                          parent_id='fixture-root' if i % 2 else None) for i in range(250)]
        rows += [dict(id=ctx, name='Created chat', state='idle', tool='', running=False) for ctx in self.server.created]
        return rows

    def envelope(self, action):
        finished = action == 'poll'
        return dict(ok=True, schema_version=1, server_epoch=EPOCH,
                    cursor=1 if finished else 0, reset=action == 'connect',
                    contexts=self.contexts(finished),
                    events=[dict(sequence=1, context_id='fixture-root', state='finished', tool='',
                                 kind='finished', observed_at=1)] if finished and self.contexts() else [],
                    dropped=dict(overflow=0, contention=0, no_consumer=0, invalid=0))

    def do_GET(self):
        if self.path == '/__fixture':
            with self.server.lock:
                counts = dict(self.server.counts)
                active = self.server.lease is not None
            self.send(value=dict(counts=counts, lease_active=active))
            return
        if self.path in ('/', '/capture'):
            self.server.record('redirect_target')
            self.send(value={'unexpected': True})
            return
        if self.path != '/api/csrf_token':
            self.send(404, {'ok': False})
            return
        self.server.record('csrf')
        if self.headers.get('Origin') != self.server.origin or not self.cookie_valid():
            self.send(403, {'ok': False})
        elif self.server.scenario == 'csrf_malformed':
            self.send(raw=b'{')
        elif self.server.scenario == 'csrf_invalid':
            self.send(value={'ok': True, 'token': 'short'})
        else:
            self.send(value={'ok': True, 'token': TOKEN})

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 4096:
            self.send(413, {'ok': False})
            return
        raw = self.rfile.read(size)
        if self.path == '/__fixture/release':
            self.server.released.set()
            self.send(value={'ok': True})
            return
        if self.path in ('/', '/capture'):
            self.server.record('redirect_target')
            self.send(value={'unexpected': True})
            return
        scenario = self.server.scenario
        if self.path == '/login':
            self.server.record('login')
            form = parse_qs(raw.decode())
            if (scenario == 'bad_login' or form != {'username': [USERNAME], 'password': [PASSWORD]}
                    or self.headers.get('Content-Type') != 'application/x-www-form-urlencoded'
                    or self.headers.get('Origin') != self.server.origin):
                self.send(raw=b'<html>Invalid credentials</html>', mime='text/html')
                return
            headers = {'Location': self.server.trap_origin + '/capture' if scenario == 'login_redirect' else '/'}
            if scenario != 'login_without_cookie':
                headers['Set-Cookie'] = f'fixture_session={COOKIE}; Path=/; HttpOnly; SameSite=Strict'
            self.send(302, raw=b'', headers=headers)
            return
        if self.cookie_valid() and not self.headers.get('X-CSRF-Token'):
            self.server.record('cookie_without_csrf')
        if not self.cookie_valid() or self.headers.get('X-CSRF-Token') != TOKEN or self.headers.get('Origin') != self.server.origin:
            self.server.record('guard_rejection')
            self.send(403, {'ok': False, 'error': 'authentication_required'})
            return
        if self.path == '/api/plugins/a0_notch/status':
            self.server.record('status')
            if scenario in ('status_unauthorized', 'status_forbidden'):
                self.send(401 if scenario == 'status_unauthorized' else 403, {'ok': False})
            elif scenario in ('status_redirect', 'status_cross_redirect'):
                location = '/capture' if scenario == 'status_redirect' else self.server.trap_origin + '/capture'
                self.send(307, raw=b'', headers={'Location': location})
            elif scenario == 'status_html':
                self.send(raw=b'<html>login</html>', mime='text/html')
            elif scenario == 'status_malformed':
                self.send(raw=b'{')
            elif scenario in ('status_oversized', 'status_stream_oversized'):
                self.send(raw=b' ' * 2097153, chunked=scenario == 'status_stream_oversized')
            else:
                self.send(value=dict(ok=True, schema_version=1, server_epoch=EPOCH, plugin_version='0.6.0',
                                     capabilities=['discovery', 'metadata', 'poll'] + ([] if scenario == 'legacy_actions' else ['exact_target_actions']), auth='session_csrf', contexts=self.contexts()))
            return
        if self.path in ('/api/plugins/a0_notch/action', '/api/poll', '/api/message_async', '/api/pause', '/api/stop', '/api/chat_create'):
            try:
                data = json.loads(raw)
            except ValueError:
                self.send(400, {'error': 'invalid_json'})
                return
            name = self.path.rsplit('/', 1)[-1]
            if name == 'action':
                action = data.get('action')
                name = {'send': 'message_async', 'pause': 'pause', 'resume': 'pause', 'stop': 'stop'}.get(action)
                if name is None:
                    self.send(400, {'error': 'contract'})
                    return
                if name == 'pause': data['paused'] = action == 'pause'
            self.server.record('chat_' + name)
            if scenario == 'mutation_forbidden' and name != 'poll':
                self.send(403, {'error': 'unauthorized'})
                return
            context = data.get('context')
            if name == 'chat_create':
                context = data.get('new_context')
                if not context or data.get('project_name') != '':
                    self.send(400, {'error': 'contract'})
                    return
                self.server.created.append(context)
                self.send(value=dict(ok=True, ctxid=context, message='Context created.'))
                return
            if context not in [row['id'] for row in self.contexts()]:
                self.send(404, {'error': 'unknown_context'})
                return
            if name == 'poll':
                if data.get('timezone') != 'UTC' or data.get('notifications_from') != 9007199254740991:
                    self.send(400, {'error': 'contract'})
                    return
                logs = [] if data.get('log_from', 0) > 100 else [
                    dict(no=1, type='user', heading='User message', content='Synthetic question', agentno=0),
                    dict(no=2, type='response', heading='Response', content='Synthetic answer', agentno=0),
                    dict(no=3, type='response', heading='Subordinate', content='Synthetic subordinate answer', agentno=1)]
                self.send(value=dict(context='wrong' if scenario == 'wrong_chat' else context,
                                     deselect_chat=scenario == 'missing_chat', logs=logs,
                                     log_guid='synthetic-log-guid', log_version=100, paused=self.server.paused,
                                     log_progress='Synthetic activity', log_progress_active=not self.server.paused))
            elif name == 'message_async':
                if not data.get('text') or not data.get('message_id'):
                    self.send(400, {'error': 'contract'})
                elif scenario == 'ambiguous_send':
                    self.send(raw=b'{')  # accepted by peer, acknowledgement lost/malformed
                else:
                    self.send(value=dict(context=context, message='Message received.'))
            elif name == 'pause':
                if not isinstance(data.get('paused'), bool):
                    self.send(400, {'error': 'contract'})
                    return
                self.server.paused = data['paused']
                self.send(value=dict(context=context, pause=self.server.paused, message='State updated.'))
            else:
                self.send(value=dict(context=context, stopped=True, message='Agent process stopped.'))
            return
        if self.path != '/api/plugins/a0_notch/events':
            self.send(404, {'ok': False})
            return
        try:
            data = json.loads(raw)
            action, client = data['action'], data['client_id']
        except (ValueError, KeyError, TypeError):
            self.send(400, {'ok': False})
            return
        self.server.record(action)
        with self.server.lock:
            if action == 'connect':
                valid = scenario != 'lease_conflict' and self.server.lease in (None, client)
                if valid:
                    self.server.lease = client
            else:
                valid = self.server.lease == client and data.get('server_epoch') == EPOCH
                if action == 'disconnect' and valid:
                    self.server.lease = None
        if not valid:
            self.send(409, {'ok': False, 'error': 'lease_conflict'})
        elif action == 'poll' and scenario == 'poll_unauthorized':
            self.send(403, {'ok': False})
        elif action == 'poll' and data.get('cursor') != 0:
            self.send(400, {'ok': False})
        elif action in ('connect', 'poll', 'disconnect'):
            if action == 'poll' and scenario == 'held_poll':
                self.server.released.wait(timeout=10)
            self.send(value=self.envelope(action))
        else:
            self.send(400, {'ok': False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=SCENARIOS, default='normal')
    parser.add_argument('--ready-file', type=Path, required=True)
    args = parser.parse_args()
    trap = Fixture()
    fixture = Fixture(args.scenario)
    fixture.trap_origin = trap.origin
    threading.Thread(target=trap.serve_forever, daemon=True).start()
    args.ready_file.write_text(json.dumps({'origin': fixture.origin, 'trap_origin': trap.origin}))
    try:
        fixture.serve_forever()
    finally:
        fixture.released.set()
        trap.shutdown()
        trap.server_close()
        fixture.server_close()


if __name__ == '__main__':
    main()
