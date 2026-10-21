"""Actual file-change telemetry: native editor integration and fail-closed edges."""
import asyncio
import json
import os
from pathlib import Path
import threading
from types import SimpleNamespace as NS

import pytest

from helpers import runtime, modules
from helpers.tool import Tool
from usr.plugins.a0_notch.helpers import diffs, relay as relay_module, capture

ROOT = Path(__file__).resolve().parents[1]


def run(coroutine):
    return asyncio.run(coroutine)


@pytest.fixture
def setup(tmp_path, monkeypatch):
    from helpers import secrets
    monkeypatch.setattr(secrets, "get_secrets_manager", lambda context: NS(mask_values=lambda value, **kw: value))
    monkeypatch.setattr(runtime, 'is_development', lambda: False)
    monkeypatch.setattr(diffs, '_workspace', lambda agent: str(tmp_path))
    monkeypatch.setattr(relay_module.relay, 'client', 'test-client')
    monkeypatch.setattr(relay_module.relay, 'allowed', frozenset({'ctx'}))
    cls = modules.load_classes_from_file('/a0/plugins/_text_editor/tools/text_editor.py', Tool)[0]
    agent = NS(context=NS(id='ctx'), loop_data=NS(current_tool=None), data={})
    agent.read_prompt = lambda *args, **kwargs: 'response not parsed by telemetry'
    agent.get_data = lambda key: agent.data.get(key)
    agent.set_data = lambda key, value: agent.data.__setitem__(key, value)
    tool = cls(agent, 'text_editor', None, {}, '', agent.loop_data)
    agent.loop_data.current_tool = tool
    namespace = tool.execute.__globals__
    async def no_extensions(*args, **kwargs):
        pass
    monkeypatch.setitem(namespace, 'call_extensions_async', no_extensions)
    monkeypatch.setitem(namespace, '_get_config', lambda agent: {
        'max_line_tokens': 500, 'default_line_count': 100, 'max_total_read_tokens': 4000})
    return tmp_path, agent, tool


async def execute(agent, tool, args):
    tool.args = args
    await diffs.before(agent, 'text_editor', args)
    response = await tool.execute(**args)
    return await diffs.after(agent, 'text_editor', response), response


@pytest.mark.parametrize('old,new,expected', [
    (None, 'alpha\nbeta\n', (2, 0)),
    ('alpha\nbeta\n', 'alpha\nother\nthird\n', (2, 1)),
    ('alpha\nbeta\n', '', (0, 2)),
    ('same\n', 'same\n', None),
    ('last', 'last\n', (1, 1)),
    ('a\nb\na\n', 'a\na\n', (0, 1)),
])
def test_actual_native_write(setup, old, new, expected):
    root, agent, tool = setup
    path = root / 'file.txt'
    if old is not None:
        path.write_text(old)
    metadata, response = run(execute(agent, tool, dict(action='write', path=str(path), content=new)))
    assert response.additional['_tool_name'] == 'text_editor'
    if expected is None:
        assert metadata is None
    else:
        assert metadata == dict(path='file.txt', added=expected[0], removed=expected[1])
    assert getattr(tool, diffs._SNAPSHOT) is None
    assert path.read_text() == new


@pytest.mark.parametrize('options', [
    {'old_text': 'old\n', 'new_text': 'new\nextra\n'},
    {'patch_text': '@@ top\n-old\n+new\n+extra\n bottom'},
    {'edits': [{'from': 2, 'to': 2, 'content': 'new\nextra\n'}]},
])
def test_actual_native_patch_modes(setup, options):
    root, agent, tool = setup
    path = root / 'file.txt'
    path.write_text('top\nold\nbottom\n')
    async def scenario():
        await tool.execute(action='read', path=str(path))
        return await execute(agent, tool, dict(action='patch', path=str(path), **options))
    metadata, response = run(scenario())
    assert path.read_text() == 'top\nnew\nextra\nbottom\n'
    assert metadata == dict(path='file.txt', added=2, removed=1)
    assert response.additional['action'] == 'patch'


def test_failed_patch_no_metadata_even_if_file_changes(setup):
    root, agent, tool = setup
    path = root / 'file.txt'
    path.write_text('old\n')
    async def scenario():
        args = dict(action='patch', path=str(path), old_text='absent', new_text='invented\n')
        await diffs.before(agent, 'text_editor', args)
        response = await tool.execute(**args)
        path.write_text('independent change\n')
        assert response.additional is None
        assert await diffs.after(agent, 'text_editor', response) is None
    run(scenario())


@pytest.mark.parametrize('path', ['../outside.txt', '/etc/passwd', '.env', 'src/.hidden/a.py',
    'secrets.txt', 'src/api-token.json', 'credentials/config.json', 'key.pem', 'a\nb.txt',
    'a\\b.txt', 'a b.txt', 'a' * 81 + '.py', 'src/../../x.py'])
def test_unsafe_path_omitted(setup, path):
    root, agent, tool = setup
    assert not diffs.safe_path(path)
    args = dict(action='write', path=str(root / path), content='must not read')
    run(diffs.before(agent, 'text_editor', args))
    assert getattr(tool, diffs._SNAPSHOT) is None


def test_relative_path_matches_native_cwd_not_workspace(setup, monkeypatch):
    root, agent, tool = setup
    monkeypatch.chdir(root)
    metadata, _ = run(execute(agent, tool, dict(action='write', path='file.txt', content='a\n')))
    assert metadata == dict(path='file.txt', added=1, removed=0)
    monkeypatch.chdir(root.parent)
    run(diffs.before(agent, 'text_editor', dict(action='write', path='other.txt')))
    assert getattr(tool, diffs._SNAPSHOT) is None


@pytest.mark.parametrize('kind', ['file', 'directory', 'fifo', 'swap'])
def test_symlinks_special_files_and_path_swap_rejected(setup, kind):
    root, agent, tool = setup
    outside = root.parent / (root.name + '-outside.txt')
    outside.write_text('do not read\n')
    path = root / 'file.txt'
    try:
        if kind == 'file':
            path.symlink_to(outside)
        elif kind == 'directory':
            (root / 'linked').symlink_to(root.parent, target_is_directory=True)
            path = root / 'linked' / outside.name
        elif kind == 'fifo':
            os.mkfifo(path)
        else:
            path.write_text('initial\n')
        async def scenario():
            await diffs.before(agent, 'text_editor', dict(action='write', path=str(path)))
            if kind == 'swap':
                assert getattr(tool, diffs._SNAPSHOT) is not None
                path.unlink()
                path.symlink_to(outside)
                response = NS(additional=dict(_tool_name='text_editor', action='write', path=str(path)))
                assert await diffs.after(agent, 'text_editor', response) is None
            else:
                assert getattr(tool, diffs._SNAPSHOT) is None
        run(scenario())
    finally:
        outside.unlink()


@pytest.mark.parametrize('data', [b'a' * (diffs.MAX_BYTES + 1), b'a\n' * (diffs.MAX_LINES + 1),
    b'abc\0def', b'abc\xff', b'abc\x01'])
@pytest.mark.parametrize('stage', ['before', 'after'])
def test_bounds_and_binary_omit_not_truncate(setup, data, stage):
    root, agent, tool = setup
    path = root / 'file.txt'
    path.write_bytes(data if stage == 'before' else b'valid\n')
    async def scenario():
        await diffs.before(agent, 'text_editor', dict(action='write', path=str(path)))
        path.write_bytes(data if stage == 'after' else b'valid\n')
        response = NS(additional=dict(_tool_name='text_editor', action='write', path=str(path)))
        assert await diffs.after(agent, 'text_editor', response) is None
    run(scenario())


def test_no_consumer_or_remote_or_read_does_no_io(setup, monkeypatch):
    root, agent, tool = setup
    calls = []
    monkeypatch.setattr(diffs, '_before', lambda *args: calls.append(args))
    args = dict(action='write', path=str(root / 'file.txt'))
    async def scenario():
        await diffs.before(agent, 'text_editor_remote', args)
        await diffs.before(agent, 'text_editor', dict(args, action='read'))
        monkeypatch.setattr(runtime, 'is_development', lambda: True)
        await diffs.before(agent, 'text_editor', args)
        monkeypatch.setattr(runtime, 'is_development', lambda: False)
        monkeypatch.setattr(relay_module.relay, 'client', None)
        await diffs.before(agent, 'text_editor', args)
    run(scenario())
    assert not calls


def test_only_actual_after_and_no_contents_stream(setup):
    root, agent, tool = setup
    path = root / 'file.txt'
    path.write_text('sensitive original body\n')
    async def scenario():
        await diffs.before(agent, 'text_editor', dict(action='write', path=str(path), content='fake\nfake\nfake\n'))
        snapshot = getattr(tool, diffs._SNAPSHOT)
        assert all(type(line) is bytes and len(line) == 32 for line in snapshot.lines)
        path.write_text('actual private body\n')
        return await diffs.after(agent, 'text_editor', NS(additional=dict(_tool_name='text_editor', action='write', path=str(path))))
    result = run(scenario())
    assert result == dict(path='file.txt', added=1, removed=1)
    wire = json.dumps(result)
    assert 'sensitive' not in wire and 'private' not in wire and str(root) not in wire


def test_failed_path_metadata_and_missing_before_ignored(setup):
    root, agent, tool = setup
    path = root / 'file.txt'
    async def scenario():
        response = NS(additional=dict(_tool_name='text_editor', action='write', path=str(path)))
        assert await diffs.after(agent, 'text_editor', response) is None
        await diffs.before(agent, 'text_editor', dict(action='write', path=str(path)))
        response.additional['path'] = str(root / 'other.txt')
        assert await diffs.after(agent, 'text_editor', response) is None
        assert getattr(tool, diffs._SNAPSHOT) is None
    run(scenario())


def test_worker_deadline_capacity_and_event_loop_liveness(monkeypatch):
    gate = threading.Event()
    started = threading.Event()
    threads = []
    monkeypatch.setattr(diffs, 'TIMEOUT', 0.01)
    monkeypatch.setattr(diffs, '_SLOTS', threading.BoundedSemaphore(2))
    def slow():
        threads.append(threading.get_ident())
        started.set()
        gate.wait(2)
        return 'late'
    async def scenario():
        main = threading.get_ident()
        first = asyncio.create_task(diffs._bounded(slow))
        while not started.is_set():
            await asyncio.sleep(0.001)
        assert await first is None
        assert await diffs._bounded(slow) is None
        assert await diffs._bounded(lambda: pytest.fail('must not queue third job')) is None
        assert threads and all(t != main for t in threads)
        gate.set()
    try:
        run(scenario())
    finally:
        gate.set()
    # Core may supply a shared executor; asyncio.run need not join its workers.
    # Wait for actual completion, then prove both capacity slots were returned.
    assert diffs._SLOTS.acquire(timeout=1)
    assert diffs._SLOTS.acquire(timeout=1)
    diffs._SLOTS.release()
    diffs._SLOTS.release()


def test_cancellation_retains_slot_until_worker_finishes(monkeypatch):
    gate = threading.Event()
    started = threading.Event()
    slots = threading.BoundedSemaphore(1)
    monkeypatch.setattr(diffs, '_SLOTS', slots)
    def slow():
        started.set()
        gate.wait(2)
    async def scenario():
        task = asyncio.create_task(diffs._bounded(slow))
        while not started.is_set():
            await asyncio.sleep(0.001)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert not slots.acquire(blocking=False)
        gate.set()
    try:
        run(scenario())
    finally:
        gate.set()
    assert slots.acquire(timeout=1)
    slots.release()


def test_concurrent_tool_instances_do_not_share_snapshots(setup):
    root, agent, tool = setup
    other_agent = NS(context=NS(id='ctx'), loop_data=NS(current_tool=None))
    other_tool = type(tool)(other_agent, 'text_editor', None, {}, '', other_agent.loop_data)
    other_agent.loop_data.current_tool = other_tool
    first, second = root / 'first.txt', root / 'second.txt'
    first.write_text('one\n')
    second.write_text('one\ntwo\nthree\n')
    async def scenario():
        await asyncio.gather(
            diffs.before(agent, 'text_editor', dict(action='write', path=str(first))),
            diffs.before(other_agent, 'text_editor', dict(action='write', path=str(second))))
        first.write_text('one\nnew\n')
        second.write_text('one\n')
        response = lambda path: NS(additional=dict(_tool_name='text_editor', action='write', path=str(path)))
        return await asyncio.gather(diffs.after(agent, 'text_editor', response(first)),
                                    diffs.after(other_agent, 'text_editor', response(second)))
    assert run(scenario()) == [dict(path='first.txt', added=1, removed=0),
                               dict(path='second.txt', added=0, removed=2)]


def test_exact_resource_boundaries(setup):
    root, agent, tool = setup
    path = root / 'file.txt'
    for old, new, expected in [
        ('a' * diffs.MAX_BYTES, 'b' * diffs.MAX_BYTES, (1, 1)),
        ('a\n' * diffs.MAX_LINES, 'a\n' * (diffs.MAX_LINES - 1) + 'b\n', (1, 1)),
    ]:
        path.write_text(old)
        result, _ = run(execute(agent, tool, dict(action='write', path=str(path), content=new)))
        assert result == dict(path='file.txt', added=expected[0], removed=expected[1])


def test_hook_end_passes_optional_metadata_and_retains_other_events(setup, monkeypatch):
    root, agent, tool = setup
    events = []
    monkeypatch.setattr(capture, 'observe', lambda *args, **kwargs: events.append((args, kwargs)))
    before = modules.import_module(str(ROOT / 'plugin/extensions/python/tool_execute_before/_95_a0_notch_observe.py')).NotchObserve(agent)
    after = modules.import_module(str(ROOT / 'plugin/extensions/python/tool_execute_after/_95_a0_notch_observe.py')).NotchObserve(agent)
    async def scenario():
        args = dict(action='write', path=str(root / 'file.txt'), content='hello\n')
        await before.execute(tool_name='text_editor', tool_args=args)
        response = await tool.execute(**args)
        await after.execute(tool_name='text_editor', response=response)
        await after.execute(tool_name='browser', response=NS(additional=None))
    run(scenario())
    assert events[0][0][1:] == ('tool_start', 'text_editor')
    assert events[1][1] == {'diff': dict(path='file.txt', added=1, removed=0)}
    assert events[2][0][1:] == ('tool_end', 'browser')
    assert events[2][1] == {'diff': None}
