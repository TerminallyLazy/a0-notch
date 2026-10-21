"""Incarnation-bound selected-chat snapshot without localization or collection side effects."""
import json
from agent import AgentContext
from usr.plugins.a0_notch.helpers import actions, http
from usr.plugins.a0_notch.helpers.incarnation import valid
from usr.plugins.a0_notch.helpers.relay import valid_id


MAX_UPDATES = 80
MAX_TEXT_WIRE = 8192


def bounded_text(value, budget=MAX_TEXT_WIRE):
    """Bound JSON-escaped UTF-8 bytes before serialization, including astral chars."""
    if type(value) is not str:
        return ''
    # Each Unicode scalar costs at least one wire byte. Never encode unbounded input.
    candidate = value[:budget]
    low, high = 0, len(candidate)
    while low < high:
        middle = (low + high + 1) // 2
        if len(json.dumps(candidate[:middle], ensure_ascii=True).encode('utf-8')) <= budget - 32:
            low = middle
        else:
            high = middle - 1
    return candidate[:low] + ('… [truncated]' if low < len(value) else '')


async def snapshot(context, start):
    # Log.output() copies the entire log list even for probes. Use its locking,
    # update-cursor and first-seen semantics on a server-enforced recent window.
    log = context.log
    with log._lock:
        end = len(log.updates)
        updates = log.updates[max(start, end - MAX_UPDATES):end]
        seen, rows = set(), []
        for index in updates:
            if index in seen or not 0 <= index < len(log.logs):
                continue
            seen.add(index)
            item = log.logs[index]
            rows.append(dict(no=item.no, type=bounded_text(item.type, 128),
                             heading=bounded_text(item.heading), content=bounded_text(item.content),
                             agentno=item.agentno))
        return dict(context=context.id, deselect_chat=False, logs=rows,
                    log_guid=log.guid, log_version=end, paused=bool(context.paused),
                    log_progress=bounded_text(log.progress), log_progress_active=bool(log.progress_active))


async def handle(request):
    try:
        credential = http.login.get_credentials_hash()
        if not credential or http.session.get('authentication') != credential:
            return http.reply({'ok': False, 'error': 'authentication_required'}, 403)
        if request.content_length is None or request.content_length > 4096 or not request.is_json:
            raise ValueError()
        raw = request.stream.read(4097)
        if len(raw) > 4096:
            raise ValueError()
        data = json.loads(raw)
        if (type(data) is not dict or set(data) != {'context', 'incarnation', 'log_from'}
                or not valid_id(data['context']) or data['context'] != data['context'].strip() or not valid(data['incarnation'])
                or type(data['log_from']) is not int or not 0 <= data['log_from'] <= 2**53 - 1):
            raise ValueError()
        with AgentContext._contexts_lock:
            context = actions.resolve(data['context'], incarnation=data['incarnation'])
        result = await snapshot(context, data['log_from'])
        # Never release another incarnation's content, even across builder await.
        with AgentContext._contexts_lock:
            actions.resolve(context.id, expected=context, incarnation=data['incarnation'])
            if result.get('context') != context.id or result.get('deselect_chat'):
                raise actions.TargetUnavailable()
            return http.reply({key: result[key] for key in (
                'context', 'deselect_chat', 'logs', 'log_guid', 'log_version',
                'paused', 'log_progress', 'log_progress_active')})
    except actions.TargetUnavailable:
        return http.reply({'ok': False, 'error': 'target_unavailable'}, 409)
    except (ValueError, TypeError, KeyError):
        return http.reply({'ok': False, 'error': 'invalid_request'}, 400)
    except Exception:
        return http.reply({'ok': False, 'error': 'unavailable'}, 503)
