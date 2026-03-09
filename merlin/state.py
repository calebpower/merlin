import asyncio

class GlobalState:
    def __init__(self):
        self._state = {}     # global kv pairs
        self._callbacks = [] # hook callback fns

    def register_callback(self, callback):
        self._callbacks.append(callback)

    def get(self, key: str, default=None):
        return self._state.get(key, default)

    async def set(self, key: str, value):
        old_value = self._state.get(key)
        if old_value != value:
            self._state[key] = value
            for cb in self._callbacks:
                asyncio.create_task(cb(key, old_value, value))
