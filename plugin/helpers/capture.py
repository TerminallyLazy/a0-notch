"""Read-only adapters for verified core hook payloads. Never format exceptions."""
from usr.plugins.a0_notch.helpers.relay import relay, TOOLS, valid_id


def display_id(context):
    # API discovery owns ancestry/scope checks. Hot hooks never walk the registry.
    id = getattr(context, 'id', None)
    return id if valid_id(id) else None


def observe(agent, kind, tool_name=''):
    try:
        if agent is None or not relay.client:
            return
        root = display_id(agent.context)
        if root is None:
            return
        tool = tool_name if type(tool_name) is str and tool_name in TOOLS else 'tool'
        if kind == 'thinking':
            state, tool = 'thinking', ''
        elif kind == 'error':
            state, tool = 'error', ''
        else:
            state = 'browsing' if tool in ('browser', 'search_engine') else 'delegating' if tool in ('call_subordinate', 'delegate_parallel') else 'working'
        if kind != 'error' and agent is not agent.context.agent0:
            state = 'delegating'
        relay.capture(root, kind, state, tool)
    except Exception:
        pass


def exception(data):
    try:
        from helpers.errors import InterventionException
        import asyncio
        from concurrent.futures import CancelledError
        args, kwargs = data.get('args', ()), data.get('kwargs', {})
        error = kwargs.get('exception', args[2] if len(args) > 2 else None)
        if error is None or isinstance(error, (InterventionException, asyncio.CancelledError, CancelledError)):
            return
        owner = args[0] if args else None
        agent = owner if hasattr(owner, 'context') else getattr(owner, 'agent0', None)
        observe(agent, 'error')
    except Exception:
        pass


def task_started(data):
    try:
        if not relay.client:
            return
        args = data.get('args', ())
        context = args[0] if args else None
        task = data.get('result')
        root = display_id(context)
        # A separately created child owns its completion, regardless of number.
        if context is None or root != context.id:
            return
        token = relay.begin_run(root)
        if token is None:
            return
        def done(future):
            try:
                if future.cancelled():
                    kind, state = 'idle', 'idle'
                elif future.exception() is not None:
                    kind, state = 'error', 'error'
                else:
                    kind, state = 'finished', 'finished'
                relay.capture(root, kind, state, run=token)
            except Exception:
                pass
        task.add_done_callback(done)
    except Exception:
        pass
