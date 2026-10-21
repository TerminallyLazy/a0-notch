"""Bounded wire pages; one immutable catalog transaction per route, 30s TTL.

All pages must be collected before replacing the displayed catalog. Registry
identity/scope changes invalidate the transaction, never yield partial success.
"""
from threading import Lock
import time
import uuid

PAGE_SIZE = 128
MAX_CONTEXTS = PAGE_SIZE * 512


class PageExpired(Exception):
    pass


class Pages:
    def __init__(self):
        self.lock = Lock()
        self.snapshots = {}

    def clear(self):
        with self.lock:
            self.snapshots.clear()

    @staticmethod
    def identities(rows):
        return {(r['id'], r.get('incarnation')) for r in rows}

    def first(self, payload, status, relay=None):
        if len(payload['contexts']) > MAX_CONTEXTS:
            raise ValueError('Catalog exceeds transaction budget')
        with self.lock:
            self._prune()
            key = str(uuid.uuid4())
            self.snapshots[status] = (key, time.monotonic() + 30, payload, None if status or relay is None else relay.client, self.identities(payload['contexts']))
            return self.slice(payload, key, 0)

    def _prune(self):
        now = time.monotonic()
        self.snapshots = {key: value for key, value in self.snapshots.items() if value[1] > now}

    def slice(self, payload, key, offset):
        rows = payload['contexts']
        end = min(offset + PAGE_SIZE, len(rows))
        result = dict(payload, contexts=rows[offset:end], page_token=key,
                      page_offset=offset, catalog_count=len(rows),
                      next_offset=end if end < len(rows) else None)
        # Events belong to the immutable transaction, and are carried only once.
        if offset and 'events' in result:
            result['events'] = []
        return result

    def next(self, data, rows, status, epoch, relay=None):
        if (set(data) != {'page_token', 'offset'} or type(data['offset']) is not int
                or data['offset'] < PAGE_SIZE or data['offset'] % PAGE_SIZE):
            raise ValueError()
        with self.lock:
            self._prune()
            saved = self.snapshots.get(status)
            if saved is None:
                raise PageExpired()
            key, deadline, payload, owner, identities = saved
            if (data['page_token'] != key or time.monotonic() >= deadline
                    or payload['server_epoch'] != epoch
                    or self.identities(rows) != identities
                    or data['offset'] >= len(payload['contexts'])):
                raise PageExpired()
            if owner is not None:
                if relay is None:
                    raise PageExpired()
                relay.renew(owner, epoch)
            return self.slice(payload, key, data['offset'])


pages = Pages()
