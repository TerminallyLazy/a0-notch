"""Process-local identity, deliberately never serialized into saved chats."""
import uuid
from agent import AgentContext


def token(context):
    with AgentContext._contexts_lock:
        value = getattr(context, '_a0_notch_incarnation', None)
        if value is None:
            value = str(uuid.uuid4())
            context._a0_notch_incarnation = value
        return value


def valid(value):
    if type(value) is not str or len(value) != 36:
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False
