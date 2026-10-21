"""Bounded multipart uploads through the normal WebUI user-message primitives.

Message.communicate cannot be safely reused via use_context alone: it saves
caller filenames before context resolution and never rechecks after its await.
This adapter preserves its hook -> log -> communicate ordering, with generated
upload names and identity/incarnation checks. No result waiting or retries.
"""
from contextlib import contextmanager
import os
from pathlib import PurePosixPath
import re
import tempfile
import uuid

from agent import AgentContext, UserMessage
from helpers import extension, files, message_queue as mq
from werkzeug.exceptions import BadRequest, RequestEntityTooLarge
from werkzeug.formparser import FormDataParser
from usr.plugins.a0_notch.helpers import actions, http
from usr.plugins.a0_notch.helpers.relay import valid_id

MAX_FILES = 8
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_REQUEST_BYTES = 16 * 1024 * 1024
MAX_TEXT_BYTES = 64 * 1024
_FIELDS = frozenset(('context', 'incarnation', 'text', 'message_id'))
_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}\Z')
_TYPES = {
    '.txt': ('text/plain',), '.md': ('text/plain', 'text/markdown'),
    '.csv': ('text/plain', 'text/csv'), '.json': ('text/plain', 'application/json'),
    '.log': ('text/plain',), '.yaml': ('text/plain', 'application/yaml', 'text/yaml'),
    '.yml': ('text/plain', 'application/yaml', 'text/yaml'),
    '.pdf': ('application/pdf',), '.png': ('image/png',),
    '.jpg': ('image/jpeg',), '.jpeg': ('image/jpeg',),
}


def _uuid(value):
    if type(value) is not str or len(value) != 36:
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


class _BoundedInput:
    """Count actual parser bytes even with terminated/chunked WSGI framing."""
    def __init__(self, stream):
        self.stream = stream
        self.remaining = MAX_REQUEST_BYTES

    def read(self, size=-1):
        amount = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        data = self.stream.read(amount)
        self.remaining -= len(data)
        if self.remaining < 0:
            raise RequestEntityTooLarge()
        return data


class _BoundedSpool(tempfile.SpooledTemporaryFile):
    """Reject a file while multipart parsing, not after spooling arbitrary bytes."""
    def write(self, data):
        if self.tell() + len(data) > MAX_FILE_BYTES:
            raise RequestEntityTooLarge()
        return super().write(data)


def _validate_fields(form):
    if set(form) != _FIELDS or any(len(form.getlist(key)) != 1 for key in _FIELDS):
        raise ValueError()
    data = form.to_dict()
    if (not valid_id(data['context']) or not data['context'].strip()
            or not _uuid(data['incarnation']) or not _uuid(data['message_id'])
            or len(data['text'].encode('utf-8')) > MAX_TEXT_BYTES):
        raise ValueError()
    return data


def _suffix(upload):
    name = upload.filename
    if type(name) is not str or not _NAME.fullmatch(name) or name.endswith((' ', '.')):
        raise ValueError()
    suffix = PurePosixPath(name).suffix.lower()
    if suffix not in _TYPES or upload.mimetype not in (*_TYPES[suffix], 'application/octet-stream'):
        raise ValueError()
    return suffix


def _validate_content(data, suffix):
    # This is format gating, not a malware scan or full PDF/image decoder. Files
    # remain attachments, never executable assets or inline HTML/SVG.
    if suffix == '.pdf':
        valid = data.startswith(b'%PDF-')
    elif suffix == '.png':
        valid = data.startswith(b'\x89PNG\r\n\x1a\n')
    elif suffix in ('.jpg', '.jpeg'):
        valid = data.startswith(b'\xff\xd8\xff')
    else:
        text = data.decode('utf-8')
        valid = not any(ord(c) < 32 and c not in '\n\r\t' for c in text)
    if not valid:
        raise ValueError()


@contextmanager
def parse(request):
    """Strict schema and bounded parser, closing every spool on all exit paths."""
    if (request.mimetype != 'multipart/form-data' or request.content_length is None
            or request.content_length <= 0):
        raise ValueError()
    if request.content_length > MAX_REQUEST_BYTES:
        raise RequestEntityTooLarge()
    spools = []
    def factory(total_content_length, content_type, filename, content_length=None):
        if len(spools) >= MAX_FILES:
            raise RequestEntityTooLarge()
        if content_length is not None and content_length > MAX_FILE_BYTES:
            raise RequestEntityTooLarge()
        spool = _BoundedSpool(max_size=256 * 1024, mode='w+b')
        spools.append(spool)
        return spool
    try:
        parser = FormDataParser(stream_factory=factory, max_form_memory_size=128 * 1024,
                                max_content_length=MAX_REQUEST_BYTES,
                                max_form_parts=MAX_FILES + len(_FIELDS), silent=False)
        _, form, uploads = parser.parse(_BoundedInput(request.stream), request.mimetype,
                                        request.content_length, request.mimetype_params)
        data = _validate_fields(form)
        if set(uploads) != {'attachments'}:
            raise ValueError()
        attachments = uploads.getlist('attachments')
        if not 1 <= len(attachments) <= MAX_FILES:
            raise ValueError()
        # Validate every name/type before creating any persistent upload.
        for upload in attachments:
            _suffix(upload)
        yield data, attachments
    finally:
        for spool in spools:
            spool.close()


def _upload_directory():
    """Walk absolute configured core upload location via no-follow dirfds."""
    path = files.get_abs_path('usr/uploads')
    parts = PurePosixPath(path).parts
    if not parts or parts[0] != '/':
        raise ValueError()
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(parts[1:], 1):
            if part in ('.', '..'):
                raise ValueError()
            if index == len(parts) - 1:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


class UploadBatch:
    """Keep directory capability for cleanup; never unlink caller-supplied paths."""
    def __init__(self):
        self.fd = None
        self.names = []
        self.committed = False

    def __enter__(self):
        self.fd = _upload_directory()
        return self

    def save(self, uploads):
        paths = []
        for upload in uploads:
            suffix = _suffix(upload)
            data = upload.stream.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise RequestEntityTooLarge()
            _validate_content(data, suffix)
            name = 'notch-' + uuid.uuid4().hex + suffix
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=self.fd)
            self.names.append(name)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
            paths.append('/a0/usr/uploads/' + name)
        return paths

    def __exit__(self, exc_type, exc, traceback):
        try:
            if not self.committed:
                for name in self.names:
                    try:
                        os.unlink(name, dir_fd=self.fd)
                    except FileNotFoundError:
                        pass
        finally:
            os.close(self.fd)


async def dispatch(data, uploads):
    """Resolve before uploads/hooks, then recheck exact object/token after await."""
    if (type(data) is not dict or set(data) != _FIELDS
            or not valid_id(data['context']) or not data['context'].strip()
            or not _uuid(data['incarnation']) or not _uuid(data['message_id'])
            or type(data['text']) is not str
            or len(data['text'].encode('utf-8')) > MAX_TEXT_BYTES
            or not 1 <= len(uploads) <= MAX_FILES):
        raise ValueError()
    with AgentContext._contexts_lock:
        context = actions.resolve(data['context'], incarnation=data['incarnation'])
    with UploadBatch() as batch:
        paths = batch.save(uploads)
        # Storage can take time; reject revoked/replaced targets before hooks too.
        with AgentContext._contexts_lock:
            actions.resolve(context.id, expected=context, incarnation=data['incarnation'])
            AgentContext.set_current(context.id)
            agent = context.get_agent()
        payload = {'message': data['text'], 'attachment_paths': list(paths)}
        await extension.call_extensions_async('user_message_ui', agent=agent, data=payload)
        with AgentContext._contexts_lock:
            actions.resolve(context.id, expected=context, incarnation=data['incarnation'])
            message = payload.get('message', '')
            attachment_paths = payload.get('attachment_paths', [])
            if type(attachment_paths) is not list or attachment_paths != paths:
                raise ValueError('Attachment preprocessing changed the saved batch')
            mq.log_user_message(context, message, attachment_paths, data['message_id'])
            # From this point delivery may have happened even if communicate
            # throws. Preserve attachments rather than delete delivered data.
            batch.committed = True
            context.communicate(UserMessage(message=message, attachments=attachment_paths,
                                            id=data['message_id']))
            return {'message': 'Message received.', 'context': context.id,
                    'attachment_count': len(paths), 'attachments': batch.names}


async def handle(request):
    try:
        credential_hash = http.login.get_credentials_hash()
        if not credential_hash or http.session.get('authentication') != credential_hash:
            return http.reply({'ok': False, 'error': 'authentication_required'}, 403)
        if 'a0_notch' not in http.plugins.get_enabled_plugins(None):
            return http.reply({'ok': False, 'error': 'plugin_disabled'}, 403)
        with parse(request) as (data, uploads):
            return http.reply(await dispatch(data, uploads))
    except actions.TargetUnavailable:
        return http.reply({'ok': False, 'error': 'target_unavailable'}, 409)
    except RequestEntityTooLarge:
        return http.reply({'ok': False, 'error': 'upload_too_large'}, 413)
    except (ValueError, TypeError, KeyError, BadRequest):
        return http.reply({'ok': False, 'error': 'invalid_request'}, 400)
    except Exception:
        return http.reply({'ok': False, 'error': 'unavailable'}, 503)
