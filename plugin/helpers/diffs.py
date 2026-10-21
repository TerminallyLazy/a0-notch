"""Best-effort actual local editor changes; no contents or absolute paths on wire.

Snapshots belong to one tool invocation, not the agent's persistent data. Reads
and exact line-LCS counting run off-thread, with two global in-flight jobs and a
50 ms hook deadline. Saturation/timeouts drop metadata, never queue retries.
"""
import asyncio
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import stat
from threading import BoundedSemaphore

MAX_BYTES = 64 * 1024
MAX_LINES = 512
MAX_PATH = 240
TIMEOUT = 0.05
_SLOTS = BoundedSemaphore(2)
_SNAPSHOT = '_a0_notch_diff_snapshot'
_COMPONENT = re.compile(r'[A-Za-z0-9_.-]{1,80}\Z')
_SENSITIVE = re.compile(r'(^|[_.-])(env|secret|secrets|token|tokens|credential|credentials|password|passwords|private|id_rsa|id_ed25519)($|[_.-])', re.I)


@dataclass(frozen=True, repr=False)
class Snapshot:
    root: str
    path: str
    action: str
    lines: tuple


def safe_path(path):
    """Only bounded plain relative names; omit private/hidden/control paths."""
    if type(path) is not str or not 0 < len(path) <= MAX_PATH:
        return False
    parts = path.split('/')
    return all(_COMPONENT.fullmatch(p) and not p.startswith('.')
               and not _SENSITIVE.search(p) and not p.lower().endswith(('.pem', '.key', '.p12', '.pfx'))
               for p in parts)


def _target(root, path):
    if type(path) is not str or not path or len(path) > 4096:
        return None
    if '..' in Path(path).parts:
        return None
    root = os.path.realpath(root)
    # The native editor resolves relative paths against process cwd, not project.
    absolute = os.path.abspath(os.path.expanduser(path))
    relative = os.path.relpath(absolute, root).replace(os.sep, '/')
    return (root, relative) if safe_path(relative) else None


def _read(root, relative, missing=False):
    """Open beneath a trusted workspace without following symlinks, even on races."""
    parts = relative.split('/')
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            except FileNotFoundError:
                if missing:
                    return ()
                raise
            os.close(directory)
            directory = child
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except FileNotFoundError:
            if missing:
                return ()
            raise
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
                return None
            data = stream.read(MAX_BYTES + 1)
            after = os.fstat(stream.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                return None
        if len(data) > MAX_BYTES or b'\0' in data:
            return None
        # Strict UTF-8 and no binary controls. No lossy decoding or partial stats.
        text = data.decode('utf-8')
        if any(ord(c) < 32 and c not in '\t\r\n' for c in text):
            return None
        lines = text.splitlines(keepends=True)
        if len(lines) > MAX_LINES:
            return None
        # Retain fixed-size line fingerprints rather than source/secret contents.
        return tuple(hashlib.sha256(line.encode('utf-8')).digest() for line in lines)
    finally:
        os.close(directory)


def _workspace(agent):
    from helpers import projects, settings
    name = projects.get_context_project_name(agent.context)
    return projects.get_project_folder(name) if name else settings.get_settings().get('workdir_path')


def display_path_allowed(context, path):
    # Fail closed on secret-manager failure; never use a masked value for I/O.
    try:
        from helpers.secrets import get_secrets_manager
        return get_secrets_manager(context).mask_values(path, placeholder='[redacted]') == path
    except Exception:
        return False


def _before(agent, action, path):
    root = _workspace(agent)
    if not root:
        return None
    target = _target(root, path)
    if target is None:
        return None
    root, relative = target
    if not display_path_allowed(agent.context, relative):
        return None
    lines = _read(root, relative, missing=action == 'write')
    return Snapshot(root, relative, action, lines) if lines is not None else None


def _counts(old, new):
    """Exact insertion/deletion line counts via bounded O(512²) LCS, O(512) RAM."""
    if old == new:
        return 0, 0
    row = [0] * (len(new) + 1)
    for a in old:
        diagonal = 0
        for j, b in enumerate(new, 1):
            previous = row[j]
            row[j] = diagonal + 1 if a == b else max(row[j], row[j - 1])
            diagonal = previous
    common = row[-1]
    return len(new) - common, len(old) - common


def _after(snapshot, additional):
    # Only native successful write/patch responses have this metadata. Never
    # infer success from response text or intended replacement/patch arguments.
    if (type(additional) is not dict or additional.get('_tool_name') != 'text_editor'
            or additional.get('action') != snapshot.action):
        return None
    if _target(snapshot.root, additional.get('path')) != (snapshot.root, snapshot.path):
        return None
    lines = _read(snapshot.root, snapshot.path)
    if lines is None:
        return None
    added, removed = _counts(snapshot.lines, lines)
    if not added and not removed:
        return None
    return {'path': snapshot.path, 'added': added, 'removed': removed}


async def _bounded(function, *args):
    slots = _SLOTS
    if not slots.acquire(blocking=False):
        return None

    def run():
        try:
            return function(*args)
        except Exception:
            return None
        finally:
            slots.release()

    # Keep the worker slot until actual completion, even after timeout/cancel.
    # run_in_executor submits immediately, so cancellation cannot leak a slot
    # between semaphore acquisition and coroutine startup.
    try:
        future = asyncio.get_running_loop().run_in_executor(None, run)
    except Exception:
        slots.release()
        return None
    try:
        return await asyncio.wait_for(asyncio.shield(future), TIMEOUT)
    except TimeoutError:
        return None


def _tool(agent, tool_name):
    if tool_name != 'text_editor' or agent is None:
        return None
    tool = getattr(getattr(agent, 'loop_data', None), 'current_tool', None)
    # Exclude overridden/remote editor implementations and development RFC I/O.
    from helpers import runtime, files
    execute = getattr(type(tool), 'execute', None)
    code = getattr(execute, '__code__', None)
    # Core's dynamic loader names this module simply "text_editor"; verify the
    # defining source filename rather than depending on an import spelling.
    expected = files.get_abs_path('plugins/_text_editor/tools/text_editor.py')
    if runtime.is_development() or code is None or code.co_filename != expected:
        return None
    return tool


async def before(agent, tool_name, tool_args):
    try:
        tool = _tool(agent, tool_name)
        if tool is None:
            return
        setattr(tool, _SNAPSHOT, None)
        from usr.plugins.a0_notch.helpers.relay import relay
        if not relay.client or getattr(agent.context, 'id', None) not in relay.allowed:
            return
        if type(tool_args) is not dict:
            return
        action = str(tool_args.get('action') or '').strip().lower().replace('-', '_')
        if action not in ('write', 'patch'):
            return
        snapshot = await _bounded(_before, agent, action, tool_args.get('path'))
        setattr(tool, _SNAPSHOT, snapshot)
    except Exception:
        pass


async def after(agent, tool_name, response):
    try:
        tool = _tool(agent, tool_name)
        if tool is None:
            return None
        snapshot = getattr(tool, _SNAPSHOT, None)
        setattr(tool, _SNAPSHOT, None)
        if snapshot is None or not display_path_allowed(agent.context, snapshot.path):
            return None
        return await _bounded(_after, snapshot, getattr(response, 'additional', None))
    except Exception:
        return None
