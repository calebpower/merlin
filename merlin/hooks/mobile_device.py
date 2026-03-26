import time
import logging
from merlin.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        logger.info("hook 'mobile_device' loaded")

    async def on_message(self, topic: str, payload: str):
        logger.info(f"topic: {topic}")
        if topic == "http/mobile/ariia/state":
            await self.state.set("mobile_device_state", payload)
