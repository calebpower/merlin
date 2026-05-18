import json
import asyncio
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.set_topic = self.config.get("set_topic", "home/office/plug/3d_printer/set")
        logger.info("hook '3dprinter_kobra_neo' loaded")

    async def _set_power(self, target_state: str):
        logger.info("3d printer power set to %s", target_state)
        await self.mqtt.publish(
            self.set_topic, payload=json.dumps({"state": target_state})
        )

    async def on_state_change(self, key: str, old_value, new_value):
        if key == StateKey.DEV_3DPRNT_REQ:
            if new_value == "OFF":
                await self._set_power("OFF")
                await self.state.set(StateKey.DEV_3DPRNT_REQ, None)
            elif new_value == "ON":
                await self._set_power("ON")
                await self.state.set(StateKey.DEV_3DPRNT_REQ, None)
            elif new_value == "REBOOT":
                await self._set_power("OFF")
                await asyncio.sleep(10)
                await self._set_power("ON")
                await self.state.set(StateKey.DEV_3DPRNT_REQ, None)
