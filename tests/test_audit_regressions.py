"""Synthetic release-blocking audit reproductions; no live private data."""
import asyncio
import io
import json
from types import SimpleNamespace as NS
from unittest.mock import Mock
import pytest
from werkzeug.datastructures import FileStorage
from werkzeug.exceptions import RequestEntityTooLarge
from werkzeug.test import EnvironBuilder
from werkzeug.wrappers import Request
from usr.plugins.a0_notch.helpers import http, attachments, diffs
from test_attachments import target, fields, assert_clean


def test_encoder_overflow_does_not_reset_shared_relay(monkeypatch):
    reset = Mock()
    monkeypatch.setattr(http.relay, 'reset', reset)
    result = http.reply({'logs': ['😀' * 250000]})
    assert result.status_code == 503
    reset.assert_not_called()


@pytest.mark.parametrize('change', ['empty', 'remove', 'reverse', 'substitute', 'inplace'])
def test_hook_attachment_changes_rejected_and_cleaned(target, monkeypatch, change):
    async def hook(*args, data, **kwargs):
        paths = data['attachment_paths']
        if change == 'empty': data['attachment_paths'] = []
        elif change == 'remove': data['attachment_paths'] = paths[:1]
        elif change == 'reverse': data['attachment_paths'] = paths[::-1]
        elif change == 'inplace': paths.pop()
        else: data['attachment_paths'] = ['/synthetic/other.txt']
    monkeypatch.setattr(attachments.extension, 'call_extensions_async', hook)
    uploads = [FileStorage(io.BytesIO(b'ok'), filename=f'{i}.txt', content_type='text/plain') for i in range(2)]
    with pytest.raises(ValueError): asyncio.run(attachments.dispatch(fields(), uploads))
    assert_clean(target)


def test_terminated_stream_understated_length_actual_cap_closes_spools(monkeypatch):
    data = fields()
    data['attachments'] = [(io.BytesIO(b'x' * (6 * 1024 * 1024)), f'{i}.txt') for i in range(3)]
    builder = EnvironBuilder(method='POST', data=data)
    env = builder.get_environ()
    env['CONTENT_LENGTH'] = '100'
    env['wsgi.input_terminated'] = True
    request = Request(env)
    spools = []
    original = attachments._BoundedSpool
    def factory(*a, **kw):
        spool = original(*a, **kw); spools.append(spool); return spool
    monkeypatch.setattr(attachments, '_BoundedSpool', factory)
    try:
        with pytest.raises(RequestEntityTooLarge):
            with attachments.parse(request): pass
        assert spools and all(s.closed for s in spools)
    finally: builder.close()


@pytest.mark.parametrize('failure', [False, True])
def test_diff_path_known_secret_masking_fails_closed(tmp_path, monkeypatch, failure):
    from helpers import secrets
    synthetic = 'SyntheticValueABC123'
    path = tmp_path / (synthetic + '.txt')
    path.write_text('before')
    agent = NS(context=NS(id='synthetic'))
    monkeypatch.setattr(diffs, '_workspace', lambda a: str(tmp_path))
    def mask(value, **kw):
        if failure: raise RuntimeError('synthetic masking failure')
        return value.replace(synthetic, '[redacted]')
    monkeypatch.setattr(secrets, 'get_secrets_manager', lambda c: NS(mask_values=mask))
    assert diffs._before(agent, 'write', str(path)) is None


def test_selected_read_is_localization_free_and_wire_bounded(monkeypatch):
    from helpers.log import Log
    from helpers.localization import Localization
    from usr.plugins.a0_notch.helpers import selected
    monkeypatch.setattr(Localization, 'get', lambda: pytest.fail('read must not access localization'))
    log = Log()
    # Do not invoke core logging extensions or use any live context.
    log.logs = [NS(no=i, type='response', heading='"\\😀' * 10000,
                   content='😀' * 250000, agentno=0) for i in range(100)]
    log.updates = list(range(100)) + [99]
    context = NS(id='synthetic', log=log, paused=False)
    result = asyncio.run(selected.snapshot(context, 0))
    assert result['log_version'] == 101 and len(result['logs']) <= 80
    assert len(json.dumps(result, ensure_ascii=True).encode()) < http.MAX_RESPONSE_BYTES
    assert result['logs'][-1]['no'] == 99
    probe = asyncio.run(selected.snapshot(context, 2**53-1))
    assert probe['logs'] == [] and probe['log_version'] == 101
    for row in result['logs']:
        for field in ('heading', 'content'):
            assert len(json.dumps(row[field], ensure_ascii=True).encode()) <= selected.MAX_TEXT_WIRE
