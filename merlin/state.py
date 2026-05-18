import asyncio
from enum import Enum


class StateKey(str, Enum):
    DEV_MOBILE_STATE = "mobile:state"
    DEV_VEHICLE_STATE = "vehicle:state"
    DEV_VEHICLE_FLAG_SAFE = "vehicle:is_safe"
    DEV_3DPRNT_REQ = "3d_printer:kobra_neo:request"
    DEV_OFFICE_AIRCOND_STATE = "office_aircond:state"
    USR_LOCATION_FLAG_HOME = "user:at_home"
    BTN_LVNGRM_SGLCLK = "livingroom_button:single_ts"
    BTN_LVNGRM_DBLCLK = "livingroom_button:double_ts"
    SYS_LAST_MESSAGE = "system:last_message"
    SNS_EXT_CLIMATE_TEMP = "exterior:climate_temp"


class GlobalState:
    def __init__(self):
        self._state = {}  # global kv pairs
        self._callbacks = []  # hook callback fns
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
