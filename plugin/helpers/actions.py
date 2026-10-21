"""Exact-target adapter for the normal WebUI text-message/control paths.

No context creation, attachment saving, retries, or agent-result waiting here.
The short commit section shares the registry lock with context removal; it is
not a transaction over plugin settings, scheduler state, or extension effects.
"""
import json
from usr.plugins.a0_notch.helpers.incarnation import token, valid

from agent import AgentContext, UserMessage
from api.stop import stop_context
from helpers import extension, message_queue as mq
from helpers.task_scheduler import TaskScheduler
from usr.plugins.a0_notch.helpers import http
from usr.plugins.a0_notch.helpers.relay import valid_id

MAX_REQUEST_BYTES = 400 * 1024  # Allows JSON escaping of a 64 KiB text message.


class TargetUnavailable(Exception):
    pass


def resolve(id, expected=None, incarnation=None):
    if 'a0_notch' not in http.plugins.get_enabled_plugins(None):
        raise TargetUnavailable()
    registry = {c.id: c for c in AgentContext.all() if valid_id(c.id)}
    context = registry.get(id)
    if (context is None or (expected is not None and context is not expected)
            or (incarnation is not None and token(context) != incarnation.lower())
            or not http._visible_contexts(registry, TaskScheduler.get()).get(id)):
        raise TargetUnavailable()
    return context


def validate(data):
    if type(data) is not dict:
        raise ValueError()
    action = data.get('action')
    if action not in ('send', 'pause', 'resume', 'stop'):
        raise ValueError()
    keys = {'action', 'context', 'text', 'message_id'} if action == 'send' else {'action', 'context'}
    keys.add('incarnation')
    if not valid(data.get('incarnation')):
        raise ValueError()
    if set(data) != keys or not valid_id(data['context']) or not data['context'].strip():
        raise ValueError()
    if action == 'send':
        if (type(data['text']) is not str or not data['text'].strip()
                or len(data['text'].encode('utf-8')) > 64 * 1024
                or not valid_id(data['message_id'])):
            raise ValueError()


async def dispatch(data):
    """Mirror Message.communicate's hook/log/UserMessage order; reuse Stop helper."""
    validate(data)
    with AgentContext._contexts_lock:
        context = resolve(data['context'], incarnation=data['incarnation'])
    AgentContext.set_current(context.id)
    payload = {'message': data.get('text', ''), 'attachment_paths': []}
    if data['action'] == 'send':
        await extension.call_extensions_async('user_message_ui', agent=context.get_agent(), data=payload)
    # There must be no await between this identity check and synchronous dispatch.
    with AgentContext._contexts_lock:
        resolve(context.id, expected=context, incarnation=data['incarnation'])
        if data['action'] == 'send':
            message, attachments = payload.get('message', ''), payload.get('attachment_paths', [])
            mq.log_user_message(context, message, attachments, data['message_id'])
            context.communicate(UserMessage(message=message, attachments=attachments, id=data['message_id']))
            return {'message': 'Message received.', 'context': context.id}
        if data['action'] in ('pause', 'resume'):
            context.paused = data['action'] == 'pause'
            return {'context': context.id, 'pause': context.paused}
        return stop_context(context)


async def handle(request):
    try:
        credential_hash = http.login.get_credentials_hash()
        if not credential_hash or http.session.get('authentication') != credential_hash:
            return http.reply({'ok': False, 'error': 'authentication_required'}, 403)
        if 'a0_notch' not in http.plugins.get_enabled_plugins(None):
            return http.reply({'ok': False, 'error': 'plugin_disabled'}, 403)
        if request.content_length is None or request.content_length > MAX_REQUEST_BYTES or not request.is_json:
            return http.reply({'ok': False, 'error': 'invalid_request'}, 400)
        raw = request.stream.read(MAX_REQUEST_BYTES + 1)
        if len(raw) > MAX_REQUEST_BYTES:
            raise ValueError()
        data = json.loads(raw)
        validate(data)
        return http.reply(await dispatch(data))
    except TargetUnavailable:
        return http.reply({'ok': False, 'error': 'target_unavailable'}, 409)
    except (ValueError, TypeError, KeyError):
        return http.reply({'ok': False, 'error': 'invalid_request'}, 400)
    except Exception:
        return http.reply({'ok': False, 'error': 'unavailable'}, 503)
