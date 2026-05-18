import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.power_topic = self.config.get(
            "power_topic", "bubbles/anycubic_kobra_neo/power"
        )
        logger.info("hook 'klipper_monitor' loaded")

    async def on_message(self, topic: str, payload: str):
        if topic == self.power_topic:
            if payload in ("REBOOT", "OFF", "ON"):
                logger.info("klipper monitor received %s request", payload)
                await self.state.set(StateKey.DEV_3DPRNT_REQ, payload)
