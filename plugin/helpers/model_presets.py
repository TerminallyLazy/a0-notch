"""Narrow per-chat preset projection; never export model configs or global writes."""
import asyncio
import hashlib
import json
from agent import AgentContext
from helpers.secrets import get_secrets_manager
from plugins._model_config.helpers import model_config
from plugins._model_config.api.model_override import ModelOverride
from usr.plugins.a0_notch.helpers import actions, http
from usr.plugins.a0_notch.helpers.incarnation import valid
from usr.plugins.a0_notch.helpers.relay import valid_id


def preset_id(name):
    return hashlib.sha256(name.encode('utf-8')).hexdigest()


def label(context, value):
    if type(value) is not str or len(value) > 4096:
        return 'Unavailable'
    masked = get_secrets_manager(context).mask_values(value, placeholder='[redacted]')
    return ''.join(c for c in masked if c.isprintable())[:120] or 'Unnamed preset'


def catalog(context):
    presets = model_config.get_presets()
    if len(presets) > 256:
        raise ValueError('Preset catalog exceeds bound')
    rows, names = [], {}
    for preset in presets:
        name = preset.get('name')
        if type(name) is not str or not name or len(name) > 4096:
            raise ValueError()
        id = preset_id(name)
        names[id] = name
        main = preset.get('chat', {})
        # Only public model name, never provider kwargs, base URLs, keys or configs.
        model = main.get('name', '') if type(main) is dict else ''
        rows.append(dict(id=id, label=label(context, name), model=label(context, model)))
    return rows, names


def invoke_core(context, action, name=None):
    data = dict(context_id=context.id, action='set_preset' if action == 'set' else 'clear')
    if name is not None:
        data['preset_name'] = name
    # Core process currently has no suspension points. Refuse a future yielding
    # implementation rather than releasing the registry lock with a stale target.
    coroutine = ModelOverride.__new__(ModelOverride).process(data, None)
    try:
        coroutine.send(None)
    except StopIteration as done:
        result = done.value
        if type(result) is not dict or not result.get('ok'):
            raise actions.TargetUnavailable()
        return
    finally:
        coroutine.close()
    raise RuntimeError('Upstream preset API unexpectedly suspended')


async def dispatch(data):
    action = data.get('action')
    expected = {'context', 'incarnation', 'action'} | ({'preset_id'} if action == 'set' else set())
    if (action not in ('list', 'set', 'clear') or set(data) != expected
            or not valid_id(data.get('context')) or data['context'] != data['context'].strip()
            or not valid(data.get('incarnation'))):
        raise ValueError()
    with AgentContext._contexts_lock:
        context = actions.resolve(data['context'], incarnation=data['incarnation'])
    rows, names = await asyncio.to_thread(catalog, context)
    with AgentContext._contexts_lock:
        actions.resolve(context.id, expected=context, incarnation=data['incarnation'])
        allowed = bool(model_config.is_chat_override_allowed(context.agent0))
        if action != 'list':
            if not allowed:
                raise actions.TargetUnavailable()
            if action == 'set':
                id = data['preset_id']
                if type(id) is not str or id not in names:
                    raise ValueError()
                # Core rechecks preset existence and applies its own persistence,
                # dirty notification and embedding-change behavior.
                invoke_core(context, action, names[id])
            else:
                invoke_core(context, action)
        current = model_config.get_effective_preset_name(context.agent0)
        return dict(ok=True, context=context.id, incarnation=data['incarnation'], allowed=allowed,
                    current_id=preset_id(current), current_label=label(context, current), presets=rows)


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
        if type(data) is not dict:
            raise ValueError()
        return http.reply(await dispatch(data))
    except actions.TargetUnavailable:
        return http.reply({'ok': False, 'error': 'target_unavailable'}, 409)
    except (ValueError, TypeError, KeyError):
        return http.reply({'ok': False, 'error': 'invalid_request'}, 400)
    except Exception:
        return http.reply({'ok': False, 'error': 'unavailable'}, 503)
