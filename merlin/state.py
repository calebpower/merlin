import asyncio
from enum import Enum

class StateKey(str, Enum):
    VEHICLE_SAFE = "vehicle:safe"
    USER_AT_HOME = "user:at_home"
    LIVINGROOM_BUTTON_SINGLE_TS = "livingroom_button_single_ts"
    LIVINGROOM_BUTTON_DOUBLE_TS = "livingroom_button_double_ts"
    HAPN_DEVICE_STATE = "hapn_device_state"
    MOBILE_DEVICE_STATE = "mobile_device_state"
    LAST_MESSAGE = "last_message"
    WEATHER_TEMP = "weather_temp"

class GlobalState:
    def __init__(self):
        self._state = {}     # global kv pairs
        self._callbacks = [] # hook callback fns
        self._bg_tasks = set()

    def register_callback(self, callback):
        self._callbacks.append(callback)

    def get(self, key: StateKey | str, default=None):
        return self._state.get(key, default)

    async def set(self, key: StateKey | str, value):
        old_value = self._state.get(key)
        if old_value != value:
            self._state[key] = value
            for cb in self._callbacks:
                task = asyncio.create_task(cb(key, old_value, value))
                self._bg_tasks.add(task)
                task.add_done_callback(self._bg_tasks.discard)
