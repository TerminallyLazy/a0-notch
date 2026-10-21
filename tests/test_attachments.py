"""Secure attachment adapter tests; synthetic contexts, no model or live uploads."""
import asyncio
import io
import os
from pathlib import Path
import uuid
from types import SimpleNamespace as NS
from unittest.mock import Mock

import pytest
from werkzeug.datastructures import MultiDict, FileStorage
from werkzeug.exceptions import RequestEntityTooLarge
from agent import AgentContext, AgentContextType
from usr.plugins.a0_notch.helpers.incarnation import token

from usr.plugins.a0_notch.helpers import attachments as mod, actions, http

REAL_RESOLVE = actions.resolve
from test_m5 import app, client, HEADERS

PATH = '/api/plugins/a0_notch/attachment'
TOKEN = str(uuid.uuid4())
MESSAGE_ID = str(uuid.uuid4())


def fields(**changes):
    return dict(context='target', incarnation=TOKEN, text='inspect this', message_id=MESSAGE_ID, **changes)


def body(name='report.txt', content=b'hello\n', mime='text/plain', overrides=None):
    data = fields()
    data.update(overrides or {})
    data['attachments'] = (io.BytesIO(content), name, mime)
    return data


@pytest.fixture
def target(monkeypatch, tmp_path):
    upload_dir = tmp_path / 'uploads'
    original = mod.files.get_abs_path
    monkeypatch.setattr(mod.files, 'get_abs_path', lambda *args: str(upload_dir) if args == ('usr/uploads',) else original(*args))
    context = NS(id='target', get_agent=lambda: 'agent', communicate=Mock(return_value=NS(result=Mock(side_effect=AssertionError('must not wait')))))
    state = {'context': context, 'token': TOKEN, 'enabled': True, 'calls': []}
    def resolve(id, expected=None, incarnation=None):
        assert AgentContext._contexts_lock._is_owned()
        state['calls'].append((id, expected, incarnation))
        if (id != 'target' or state['context'] is None or not state['enabled']
                or incarnation != state['token']
                or (expected is not None and expected is not state['context'])):
            raise actions.TargetUnavailable()
        return state['context']
    monkeypatch.setattr(actions, 'resolve', resolve)
    monkeypatch.setattr(AgentContext, 'set_current', lambda id: None)
    async def hook(*args, **kwargs):
        assert args == ('user_message_ui',)
        assert kwargs['agent'] == 'agent'
        kwargs['data']['message'] += ' transformed'
    monkeypatch.setattr(mod.extension, 'call_extensions_async', hook)
    monkeypatch.setattr(mod.mq, 'log_user_message', Mock())
    return context, state, upload_dir


def assert_clean(target):
    context, _, directory = target
    context.communicate.assert_not_called()
    mod.mq.log_user_message.assert_not_called()
    assert not directory.exists() or not list(directory.iterdir())


def test_route_success_normal_message_no_wait(client, target):
    context, state, directory = target
    result = client.post(PATH, data=body(), headers=HEADERS)
    assert result.status_code == 200, result.data
    assert result.json['message'] == 'Message received.'
    assert result.json['context'] == 'target'
    assert result.json['attachment_count'] == 1
    assert result.json['attachments'] == [p.name for p in directory.iterdir()]
    assert result.headers['Cache-Control'] == 'no-store'
    assert len(state['calls']) == 3
    assert state['calls'][0] == ('target', None, TOKEN)
    assert state['calls'][1:] == [('target', context, TOKEN)] * 2
    message = context.communicate.call_args.args[0]
    assert message.message == 'inspect this transformed' and message.id == MESSAGE_ID
    assert len(message.attachments) == 1
    name = Path(message.attachments[0]).name
    assert name.startswith('notch-') and name.endswith('.txt') and name != 'report.txt'
    assert message.attachments == ['/a0/usr/uploads/' + name]
    assert (directory / name).read_bytes() == b'hello\n'
    assert (directory / name).stat().st_mode & 0o777 == 0o600
    mod.mq.log_user_message.assert_called_once_with(context, message.message, message.attachments, MESSAGE_ID)
    context.communicate.return_value.result.assert_not_called()
    assert 'uploads' not in result.get_data(as_text=True)


@pytest.mark.parametrize('name,mime,content', [
    ('doc.md', 'text/markdown', b'# Title'), ('data.json', 'application/json', b'{}'),
    ('note.txt', 'application/octet-stream', b'text'),
    ('doc.pdf', 'application/pdf', b'%PDF-1.7\nfixture'),
    ('image.png', 'image/png', b'\x89PNG\r\n\x1a\nfixture'),
    ('photo.jpeg', 'image/jpeg', b'\xff\xd8\xfffixture'),
])
def test_allowed_formats(client, target, name, mime, content):
    assert client.post(PATH, data=body(name, content, mime), headers=HEADERS).status_code == 200


@pytest.mark.parametrize('name,mime,content', [
    ('../escape.txt', 'text/plain', b'x'), ('/tmp/escape.txt', 'text/plain', b'x'),
    ('C:\\escape.txt', 'text/plain', b'x'), ('.env', 'text/plain', b'x'),
    ('bad\nname.txt', 'text/plain', b'x'), ('a' * 121 + '.txt', 'text/plain', b'x'),
    ('script.html', 'text/html', b'<script>'), ('vector.svg', 'image/svg+xml', b'<svg>'),
    ('app.exe', 'application/octet-stream', b'MZ'), ('image.png', 'image/png', b'not an image'),
    ('doc.pdf', 'application/pdf', b'not pdf'), ('photo.jpg', 'image/jpeg', b'not jpeg'),
    ('file.txt', 'image/png', b'text'), ('file.txt', 'text/plain', b'\x00binary'),
    ('file.txt', 'text/plain', b'\xff'), ('file.txt', 'text/plain', b'\x1bescape'),
])
def test_reject_unsafe_names_types_content(client, target, name, mime, content):
    result = client.post(PATH, data=body(name, content, mime), headers=HEADERS)
    assert result.status_code == 400, result.data
    assert_clean(target)


@pytest.mark.parametrize('change', [
    {'context': ''}, {'context': 'absent'}, {'incarnation': 'invalid'},
    {'incarnation': str(uuid.uuid4())}, {'message_id': 'bad'}, {'path': '/tmp/secret'},
    {'text': 'a' * (mod.MAX_TEXT_BYTES + 1)},
])
def test_field_validation_and_missing_target(client, target, change):
    result = client.post(PATH, data=body(overrides=change), headers=HEADERS)
    assert result.status_code in (400, 409)
    assert_clean(target)


def test_duplicate_and_missing_fields(client, target):
    data = MultiDict(body())
    data.add('context', 'other')
    assert client.post(PATH, data=data, headers=HEADERS).status_code == 400
    data = body(); del data['incarnation']
    assert client.post(PATH, data=data, headers=HEADERS).status_code == 400
    assert_clean(target)


def test_auth_csrf_disabled_and_json(client, app, target, monkeypatch):
    assert client.post(PATH, data=body()).status_code == 403
    assert app.test_client().post(PATH, data=body(), headers=HEADERS).status_code in (302, 403)
    assert client.post(PATH, json=fields(), headers=HEADERS).status_code == 400
    monkeypatch.setattr(http.plugins, 'get_enabled_plugins', lambda agent: [])
    assert client.post(PATH, data=body(), headers=HEADERS).status_code == 403
    monkeypatch.setattr(http.login, 'get_credentials_hash', lambda: '')
    assert client.post(PATH, data=body(), headers=HEADERS).status_code == 403
    assert_clean(target)


def test_count_limit_empty_wrong_field(client, target):
    assert client.post(PATH, data=fields(), content_type='multipart/form-data', headers=HEADERS).status_code == 400
    data = body(); data['wrong'] = data.pop('attachments')
    assert client.post(PATH, data=data, headers=HEADERS).status_code == 400
    data = fields(); data['attachments'] = [(io.BytesIO(b'x'), 'a.txt', 'text/plain') for _ in range(9)]
    assert client.post(PATH, data=data, headers=HEADERS).status_code == 413
    assert_clean(target)


def test_eight_files_unique_names(client, target):
    data = fields(); data['attachments'] = [(io.BytesIO(b'x'), 'same.txt', 'text/plain') for _ in range(8)]
    response = client.post(PATH, data=data, headers=HEADERS)
    assert response.status_code == 200 and response.json['attachment_count'] == 8
    assert len(list(target[2].iterdir())) == 8


def test_file_and_request_limits(client, target):
    assert client.post(PATH, data=body(content=b'x' * (mod.MAX_FILE_BYTES + 1)), headers=HEADERS).status_code == 413
    assert client.post(PATH, data=b'x' * (mod.MAX_REQUEST_BYTES + 1), content_type='multipart/form-data; boundary=abc', headers=HEADERS).status_code == 413
    assert_clean(target)
    assert client.post(PATH, data=body(content=b'x' * mod.MAX_FILE_BYTES), headers=HEADERS).status_code == 200


@pytest.mark.parametrize('change', ['delete', 'replace', 'scope', 'incarnation'])
def test_target_changed_during_await_rejects_and_cleans(target, monkeypatch, change):
    context, state, directory = target
    upload = FileStorage(io.BytesIO(b'content'), filename='file.txt', content_type='text/plain')
    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()
        async def hook(*args, **kwargs):
            entered.set()
            await release.wait()
        monkeypatch.setattr(mod.extension, 'call_extensions_async', hook)
        task = asyncio.create_task(mod.dispatch(fields(), [upload]))
        await entered.wait()
        assert len(list(directory.iterdir())) == 1
        if change == 'delete': state['context'] = None
        elif change == 'replace': state['context'] = NS(id='target')
        elif change == 'scope': state['enabled'] = False
        else: state['token'] = str(uuid.uuid4())
        release.set()
        with pytest.raises(actions.TargetUnavailable): await task
    asyncio.run(scenario())
    assert_clean(target)


def test_pre_hook_change_rejected(target, monkeypatch):
    _, state, _ = target
    original = mod.UploadBatch.save
    def save(batch, uploads):
        result = original(batch, uploads)
        state['context'] = None
        return result
    monkeypatch.setattr(mod.UploadBatch, 'save', save)
    hook = Mock()
    monkeypatch.setattr(mod.extension, 'call_extensions_async', hook)
    with pytest.raises(actions.TargetUnavailable):
        asyncio.run(mod.dispatch(fields(), [FileStorage(io.BytesIO(b'x'), filename='a.txt', content_type='text/plain')]))
    hook.assert_not_called()
    assert_clean(target)


def test_rejection_after_first_saved_file_cleans_all(client, target):
    data = fields(); data['attachments'] = [(io.BytesIO(b'good'), 'a.txt', 'text/plain'), (io.BytesIO(b'\x00'), 'b.txt', 'text/plain')]
    assert client.post(PATH, data=data, headers=HEADERS).status_code == 400
    assert_clean(target)


def test_symlink_upload_directory_rejected(client, target, tmp_path):
    directory = target[2]
    outside = tmp_path / 'outside'; outside.mkdir()
    directory.symlink_to(outside, target_is_directory=True)
    assert client.post(PATH, data=body(), headers=HEADERS).status_code == 503
    assert not list(outside.iterdir())
    assert_clean(target)


def test_generated_name_collision_never_overwrites(client, target, monkeypatch):
    fixed = uuid.uuid4()
    directory = target[2]; directory.mkdir()
    existing = directory / ('notch-' + fixed.hex + '.txt')
    existing.write_bytes(b'existing')
    monkeypatch.setattr(mod.uuid, 'uuid4', lambda: fixed)
    assert client.post(PATH, data=body(), headers=HEADERS).status_code == 503
    assert existing.read_bytes() == b'existing'
    target[0].communicate.assert_not_called()


def test_hook_exception_cleanup_and_redaction(client, target, monkeypatch):
    async def fail(*args, **kwargs):
        raise RuntimeError('private credentials here')
    monkeypatch.setattr(mod.extension, 'call_extensions_async', fail)
    result = client.post(PATH, data=body(), headers=HEADERS)
    assert result.status_code == 503 and result.json['error'] == 'unavailable'
    assert b'private' not in result.data
    assert_clean(target)


def test_cancel_cleanup(target, monkeypatch):
    async def cancel(*args, **kwargs):
        raise asyncio.CancelledError()
    monkeypatch.setattr(mod.extension, 'call_extensions_async', cancel)
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(mod.dispatch(fields(), [FileStorage(io.BytesIO(b'x'), filename='a.txt', content_type='text/plain')]))
    assert_clean(target)


def test_real_resolver_incarnation_and_scope(client, target, monkeypatch):
    context, _, directory = target
    context.type = AgentContextType.USER
    context.output_data = {}
    context.agent0 = NS(enabled=True)
    monkeypatch.setattr(actions, 'resolve', REAL_RESOLVE)
    monkeypatch.setattr(AgentContext, 'all', lambda: [context])
    monkeypatch.setattr(actions.TaskScheduler, 'get', lambda: NS(get_task_by_uuid=lambda id: None))
    correct = token(context)
    assert client.post(PATH, data=body(), headers=HEADERS).status_code == 409
    assert_clean(target)
    context.type = AgentContextType.BACKGROUND
    assert client.post(PATH, data=body(overrides={'incarnation': correct}), headers=HEADERS).status_code == 409
    assert_clean(target)
    context.type = AgentContextType.USER
    assert client.post(PATH, data=body(overrides={'incarnation': correct}), headers=HEADERS).status_code == 200
    assert len(list(directory.iterdir())) == 1


def test_missing_token_dispatch_rejected_before_resolution(target):
    data = fields(); data['incarnation'] = None
    with pytest.raises(ValueError):
        asyncio.run(mod.dispatch(data, [FileStorage(io.BytesIO(b'x'), filename='a.txt', content_type='text/plain')]))
    assert not target[1]['calls']
    assert_clean(target)


def test_parser_closes_spools_on_error(app, monkeypatch):
    instances = []
    original = mod._BoundedSpool
    def factory(*args, **kwargs):
        result = original(*args, **kwargs); instances.append(result); return result
    monkeypatch.setattr(mod, '_BoundedSpool', factory)
    with app.test_request_context(PATH, method='POST', data=body(content=b'x' * (mod.MAX_FILE_BYTES + 1))):
        from flask import request
        with pytest.raises(RequestEntityTooLarge):
            with mod.parse(request):
                pytest.fail('must reject')
    assert instances and all(s.closed for s in instances)

@pytest.mark.parametrize('suffix,invalid', [('.png', b'PNG'), ('.jpeg', b'not jpeg'), ('.txt', bytes([0, 1, 2]))])
def test_format_gate_direct_rejects_invalid_bytes(suffix, invalid):
    with pytest.raises(ValueError):
        mod._validate_content(invalid, suffix)

@pytest.mark.parametrize('suffix,signature', [('.png', '89504e470d0a1a0a'), ('.jpg', 'ffd8ff')])
def test_format_gate_accepts_standard_signatures(suffix, signature):
    mod._validate_content(bytes.fromhex(signature) + b'fixture', suffix)
