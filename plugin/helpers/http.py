"""WebUI-authorized chat discovery. Session + CSRF only; no anonymous fallback."""
from datetime import datetime
import json
import math
from helpers.api import Response, session
from helpers import login, plugins
from usr.plugins.a0_notch.helpers.relay import relay, valid_id, validate_request, LeaseConflict

MAX_RESPONSE_BYTES = 2 * 1024 * 1024


def reply(data, status=200):
    # Iterative encoding bounds the accumulated wire buffer; no partial snapshot
    # is sent. All production strings were already bounded during projection.
    body = bytearray()
    for chunk in json.JSONEncoder(ensure_ascii=True, allow_nan=False, separators=(',', ':')).iterencode(data):
        encoded = chunk.encode('utf-8')
        if len(body) + len(encoded) > MAX_RESPONSE_BYTES:
            relay.reset()
            body = b'{"ok":false,"error":"snapshot_too_large"}'
            status = 503
            break
        body.extend(encoded)
    return Response(bytes(body), status=status, mimetype='application/json',
                    headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})


def _visible_contexts(registry, scheduler):
    """Match WebUI chat collection; retain scope restrictions through ancestry.

    Do not call context.output()/build_snapshot(): those project arbitrary
    output_data or transcript/task contents and can mutate/prune runtime state.
    Each registry node is checked at most once; no depth or chat-count cap.
    """
    visible = {}
    for id in registry:
        path, seen = [], set()
        current = id
        allowed = False
        while current not in visible:
            if current in seen or current not in registry:
                break
            seen.add(current)
            path.append(current)
            context = registry[current]
            from agent import AgentContextType
            task = scheduler.get_task_by_uuid(current)
            if (context.type == AgentContextType.BACKGROUND
                    or (task is not None and task.context_id == current)
                    or 'a0_notch' not in plugins.get_enabled_plugins(context.agent0)):
                break
            parent = context.output_data.get('parent_context_id')
            if parent is None or parent == '':
                allowed = True
                break
            if not valid_id(parent) or context.output_data.get('parent_context_kind') != 'subordinate':
                break
            current = parent
        else:
            allowed = visible[current]
        for item in path:
            visible[item] = allowed
    return visible


def _timestamp(value):
    if isinstance(value, datetime):
        timestamp = value.timestamp()
        if math.isfinite(timestamp) and timestamp >= 0:
            return timestamp
    return None


def contexts():
    from agent import AgentContext
    from helpers.secrets import get_secrets_manager
    from helpers.task_scheduler import TaskScheduler
    registry = {context.id: context for context in AgentContext.all() if valid_id(context.id)}
    visible = _visible_contexts(registry, TaskScheduler.get())
    result = []
    for id, context in registry.items():
        if not visible.get(id):
            continue
        name = 'Untitled chat'
        if type(context.name) is str and len(context.name) <= 4096:
            masked = get_secrets_manager(context).mask_values(context.name, placeholder='[redacted]')
            name = ''.join(c for c in masked if c.isprintable())[:80] or name
        running = bool(context.is_running())
        row = dict(id=id, name=name, running=running, tool='',
                   state='paused' if context.paused else 'working' if running else 'idle')
        parent = context.output_data.get('parent_context_id')
        if parent:
            row['parent_id'] = parent
        for key, value in (('last_activity_at', context.last_message), ('created_at', context.created_at)):
            timestamp = _timestamp(value)
            if timestamp is not None:
                row[key] = timestamp
        result.append(row)
    return result


async def handle(request, status=False):
    try:
        credential_hash = login.get_credentials_hash()
        if not credential_hash or session.get('authentication') != credential_hash:
            return reply({'ok': False, 'error': 'authentication_required'}, 403)
        if 'a0_notch' not in plugins.get_enabled_plugins(None):
            relay.reset()
            return reply({'ok': False, 'error': 'plugin_disabled'}, 403)
        # Read at most 4097 bytes, before the base handler's unbounded JSON parser.
        if request.content_length is None or request.content_length > 4096 or not request.is_json:
            return reply({'ok': False, 'error': 'invalid_request'}, 400)
        raw = request.stream.read(4097)
        if len(raw) > 4096:
            return reply({'ok': False, 'error': 'invalid_request'}, 400)
        data = json.loads(raw)
        validate_request(data, status)
        # Old allowed_context_ids/share_context_names are deliberately ignored.
        rows = contexts()
        relay.configure(r['id'] for r in rows)
        if status:
            payload = dict(ok=True, schema_version=1, plugin_version='0.6.1',
                           server_epoch=relay.epoch, capabilities=['discovery', 'metadata', 'poll', 'exact_target_actions'],
                           auth='session_csrf', contexts=rows)
        else:
            payload = relay.exchange(data, rows)
        return reply(payload)
    except LeaseConflict:
        return reply({'ok': False, 'error': 'lease_conflict'}, 409)
    except (ValueError, TypeError, KeyError):
        return reply({'ok': False, 'error': 'invalid_request_or_configuration'}, 400)
    except Exception:
        # Never leak framework exception text or locals through an API traceback.
        return reply({'ok': False, 'error': 'unavailable'}, 503)
