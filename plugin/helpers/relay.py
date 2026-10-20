"""Bounded scalar-only telemetry. No workers, disk spool, or network in capture."""
from collections import deque
from threading import Lock
import time
import uuid

STATES = frozenset(('idle', 'working', 'thinking', 'browsing', 'delegating', 'finished', 'error', 'paused'))
KINDS = frozenset(('thinking', 'tool_start', 'tool_end', 'finished', 'error', 'idle'))
TOOLS = frozenset(('code_execution_tool', 'code_execution_remote', 'browser', 'search_engine',
    'document_query', 'call_subordinate', 'delegate_parallel', 'response', 'text_editor',
    'text_editor_remote', 'skills_tool', 'memory_load', 'memory_save', 'notify_user',
    'office_artifact', 'vision_load', 'parallel', 'wait', 'scheduler', 'tool'))


def valid_id(value):
    return type(value) is str and 0 < len(value) <= 128 and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def validate_request(data, status=False):
    if type(data) is not dict:
        raise ValueError('invalid_request')
    if status:
        if data:
            raise ValueError('invalid_request')
        return
    action = data.get('action')
    keys = {'action', 'client_id'}
    if action in ('poll', 'disconnect'):
        keys.add('server_epoch')
    if action == 'poll':
        keys.add('cursor')
        if type(data.get('cursor')) is not int or not 0 <= data['cursor'] <= 2**53 - 1:
            raise ValueError('invalid_cursor')
    if action not in ('connect', 'poll', 'disconnect') or set(data) != keys:
        raise ValueError('invalid_request')
    for key in keys & {'client_id', 'server_epoch'}:
        if type(data[key]) is not str or len(data[key]) != 36:
            raise ValueError('invalid_identifier')
        try:
            uuid.UUID(data[key])
        except ValueError:
            raise ValueError('invalid_identifier') from None


class LeaseConflict(Exception):
    pass


class Relay:
    def __init__(self, clock=time.monotonic):
        self.lock = Lock()
        self.clock = clock
        self.epoch = str(uuid.uuid4())
        self.allowed = frozenset()
        self.client = None
        self.deadline = 0
        self.sequence = 0
        self.generation = 0
        self.run_sequence = 0
        self.ring = deque(maxlen=64)
        self.states = {}
        self.runs = {}
        self.dropped = dict(overflow=0, contention=0, no_consumer=0, invalid=0)

    def _clear(self):
        self.client = None
        self.deadline = 0
        self.generation += 1
        self.ring.clear()
        self.states.clear()
        self.runs.clear()

    def reset(self):
        with self.lock:
            self._clear()
            self.allowed = frozenset()
            self.epoch = str(uuid.uuid4())

    def configure(self, ids):
        # Registry discovery is API-only. Preserve the consumer and retained
        # runs across additions; remove revoked/deleted contexts immediately.
        discovered = frozenset(ids)
        with self.lock:
            if self.allowed != discovered:
                self.allowed = discovered
                self.states = {k: v for k, v in self.states.items() if k in discovered}
                self.runs = {k: v for k, v in self.runs.items() if k in discovered}
                self.ring = deque((e for e in self.ring if e['context_id'] in discovered), maxlen=64)

    def _alive(self):
        if self.client and self.clock() < self.deadline:
            return True
        self._clear()
        return False

    def capture(self, context_id, kind, state, tool='', run=None):
        if not self.lock.acquire(blocking=False):
            self.dropped['contention'] += 1
            return False
        try:
            if not self._alive():
                self.dropped['no_consumer'] += 1
                return False
            if context_id not in self.allowed or kind not in KINDS or state not in STATES:
                self.dropped['invalid'] += 1
                return False
            if run is not None and self.runs.get(context_id) != run:
                return False
            tool = tool if type(tool) is str and (tool == '' or tool in TOOLS) else 'tool'
            self.sequence += 1
            event = dict(sequence=self.sequence, context_id=context_id, kind=kind,
                         state=state, tool=tool, observed_at=time.time())
            if len(self.ring) == 64:
                self.dropped['overflow'] += 1
            self.ring.append(event)
            self.states[context_id] = (state, tool)
            return True
        finally:
            self.lock.release()

    def begin_run(self, context_id):
        if not self.lock.acquire(blocking=False):
            return None
        try:
            if not self._alive() or context_id not in self.allowed:
                return None
            self.run_sequence += 1
            token = (self.generation, self.run_sequence)
            self.runs[context_id] = token
            self.states[context_id] = ('working', '')
            return token
        finally:
            self.lock.release()

    def exchange(self, data, contexts):
        """Only API threads call this; contexts are pre-sanitized scalar snapshots."""
        with self.lock:
            alive = self._alive()
            action, client = data['action'], data['client_id']
            if action == 'connect':
                if alive and self.client != client:
                    raise LeaseConflict()
                self._clear()
                self.client = client
                cursor = self.sequence
                reset = True
            else:
                if not alive or self.client != client or data['server_epoch'] != self.epoch:
                    raise LeaseConflict()
                cursor = data.get('cursor', self.sequence)
                if cursor > self.sequence:
                    raise LeaseConflict()
                reset = bool(self.ring and cursor < self.ring[0]['sequence'] - 1)
            if action == 'disconnect':
                self._clear()
            else:
                self.deadline = self.clock() + 15
            rows = []
            for row in contexts:
                if row['id'] not in self.allowed:
                    continue
                row = dict(row)
                state, tool = self.states.get(row['id'], (row['state'], ''))
                if row['state'] == 'paused':
                    state, tool = 'paused', ''
                elif row['running'] and state in ('idle', 'finished', 'paused'):
                    state, tool = 'working', ''
                elif not row['running'] and state not in ('finished', 'error'):
                    state, tool = 'idle', ''
                row.update(state=state, tool=tool)
                rows.append(row)
            visible_ids = {r['id'] for r in rows}
            return dict(ok=True, schema_version=1, server_epoch=self.epoch,
                        cursor=self.sequence, reset=reset, contexts=rows,
                        events=[dict(e) for e in self.ring if e['sequence'] > cursor
                                and e['context_id'] in visible_ids],
                        dropped=dict(self.dropped))


relay = Relay()
